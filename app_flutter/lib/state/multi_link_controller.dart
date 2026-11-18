/// OpenSmartBatt — multi-link experiment (design 0103, 0046 delivery 2 MVP).
///
/// ## Shape: secondary links are separate BleService instances
///
/// The PRIMARY link — the one the device page, the controls, the session, the
/// history attribution and every existing test are built around — is untouched:
/// it is still `ConnectionController` driving the app's one `BleService`. This
/// controller adds up to [MultiLinkConfig.maxConcurrentLinks] − 1 SECONDARY
/// links beside it, each on a `BleService` instance of its own, so that none of
/// the single-link invariants in `ble_service.dart` (`_links` holds 0 or 1
/// entry, `_current` is "the" link) had to change. flutter_blue_plus is a
/// process-wide singleton underneath either way — the global GATT mutex is
/// shared whatever we do (0046a §5.4), which is exactly what the demotion rule
/// (D5) exists to manage.
///
/// What the secondaries feed:
///   * the home grid's live tiles ([isOnlineFor] / [telemetryFor]);
///   * history rows and alert evaluation, keyed by the LINK's id
///     ([TelemetryController.recordExtraSample]) — never by the primary's
///     session (FB-41);
///   * the diagnostic log, same keying ([TelemetryController.logExtraPacket]);
///   * the Android monitor and its reading line (D7).
///
/// ## Rulings implemented (0103 §0.1)
///   * D1 — a power bank is exclusive: while it is the primary link the others
///     PAUSE polling ([MultiLinkConfig.powerBankOthers]; one constant flips it
///     to disconnect). Leaving its page disconnects it and resumes the rest.
///   * D2 — the pre-entry prompt is the UI's ([shouldPromptForPowerBank]).
///   * D5 — slow-writer demotion: mean of the last 60 writes ≥ 500 ms pauses
///     that link for 5 min; the third demotion leaves it out for the session;
///     never with a single link online; never while the primary is just as
///     slow (2026.11.16/006 — the phone, not the unit). A paused link still
///     writes one poll a minute ([MultiLinkConfig.pausedKeepAliveEvery]).
///   * D6 — at most 3 links, primary included.
///   * D7 — 「監看中 N 台」, alerts for every link, all links kept in background.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble.dart';
import '../config/multi_link_config.dart';
import '../data/ack_marker.dart';
import '../demo/demo.dart';
import '../models/models.dart';
import 'card_telemetry.dart';
import 'connection_controller.dart';
import 'device_controller.dart';
import 'device_live_source.dart';
import 'live_trend_buffer.dart';
import 'settings_controller.dart';
import 'telemetry_controller.dart';
import 'vehicle_controller.dart';

/// Formats the notification's reading line for N live links.
typedef MultiLinkBodyFormat = String Function(int count, String reading);

class _Secondary {
  _Secondary(this.id, this.ble);

  final String id;
  final BleService ble;
  final List<StreamSubscription<Object?>> subs = <StreamSubscription<Object?>>[];
  final LiveTrendBuffer trend = LiveTrendBuffer();

  BleLinkState state = BleLinkState.disconnected;
  TelemetrySample? last;
  DateTime? lastTouchAt;

  /// Paused because a power bank holds the primary link (D1).
  bool pausedForPowerBank = false;

  /// Paused by the slow-writer rule (D5), until [demoteTimer] fires.
  bool demoted = false;
  int demotions = 0;
  Timer? demoteTimer;

  /// D5 phone-slow guard: whether the current run of "slow, but the primary
  /// is just as slow" has already been logged. Dedupes the 10 s evaluation.
  bool demoteSkipLogged = false;

  Timer? retryTimer;
  int retryAttempts = 0;

  /// Set while [MultiLinkController] is taking this link down on purpose, so
  /// the `disconnected` it causes does not schedule a retry.
  bool releasing = false;

  // design 0106 Phase 1 — what the device page needs to draw this unit from
  // its own link rather than switching the primary over to it.
  DateTime? readyAt;
  DateTime? lastSampleAt;
  int samples = 0;
  bool stalled = false;
  String? liveMac;

  bool get online => state == BleLinkState.ready;
  bool get paused => pausedForPowerBank || demoted;
}

class MultiLinkController extends ChangeNotifier {
  MultiLinkController({
    required ConnectionController connection,
    required DeviceController devices,
    required TelemetryController telemetry,
    required SettingsController settings,
    required BleService Function() bleFactory,
    AckMarker enabledMarker = const AckMarker(MultiLinkConfig.enabledMarker),
    AckMarker skipPromptMarker =
        const AckMarker(MultiLinkConfig.skipPowerBankPromptMarker),
    this.maxLinks = MultiLinkConfig.maxConcurrentLinks,
    this.powerBankOthers = MultiLinkConfig.powerBankOthers,
    this.demoteCheckEvery = MultiLinkConfig.demoteCheckEvery,
    this.demoteRetryAfter = MultiLinkConfig.demoteRetryAfter,
    this.retryBase = MultiLinkConfig.secondaryRetryBase,
    this.retryCap = MultiLinkConfig.secondaryRetryCap,
    this.presenceWindow = MultiLinkConfig.presenceWindow,
    this.presenceScanEvery = MultiLinkConfig.presenceScanEvery,
    this.presenceScanTimeout = MultiLinkConfig.presenceScanTimeout,
    this.stallThreshold = BleService.telemetryStallThreshold,
    this.stallCheckEvery = const Duration(seconds: 2),
    this.personalRetryEvery = const Duration(seconds: 30),
    DateTime Function()? clock,
    VehicleController? vehicles,
    BleService? primaryBle,
  // Private fields from public named parameters: the `this._x` form the lint
  // suggests does not compile for named parameters (see SettingsController).
  })  : _conn = connection,
        // ignore: prefer_initializing_formals
        _devices = devices,
        _tele = telemetry,
        // ignore: prefer_initializing_formals
        _settings = settings,
        // ignore: prefer_initializing_formals
        _bleFactory = bleFactory,
        // ignore: prefer_initializing_formals
        _enabledMarker = enabledMarker,
        // ignore: prefer_initializing_formals
        _skipPromptMarker = skipPromptMarker,
        _now = clock ?? DateTime.now,
        // ignore: prefer_initializing_formals
        _vehicles = vehicles,
        // ignore: prefer_initializing_formals
        _primaryBle = primaryBle {
    _conn.addListener(_onPrimaryChanged);
    _devices.addListener(_reconcile);
    _vehicles?.addListener(_onVehiclesChanged);
    _settings.addListener(_onSettingsChanged);
    _lastPrimary = _conn.connectedDeviceId;
    _lastVehicleId = _vehicleIdNow();
  }

  final ConnectionController _conn;
  final DeviceController _devices;
  final TelemetryController _tele;
  final SettingsController _settings;
  final BleService Function() _bleFactory;
  final AckMarker _enabledMarker;
  final AckMarker _skipPromptMarker;

  final int maxLinks;
  final PowerBankOthersMode powerBankOthers;
  final Duration demoteCheckEvery;
  final Duration demoteRetryAfter;
  final Duration retryBase;
  final Duration retryCap;
  final Duration presenceWindow;
  final Duration presenceScanEvery;
  final Duration presenceScanTimeout;

  /// design 0106 Phase 1: a secondary link counts as stalled after this long
  /// without a frame — the primary's threshold, so both pages say 「暫停」 for
  /// the same silence.
  final Duration stallThreshold;
  final Duration stallCheckEvery;

  /// design 0106 Phase 3: how long the personal group waits before trying its
  /// power bank again after a connect that did not take.
  final Duration personalRetryEvery;
  final DateTime Function() _now;

  /// design 0106 Phase 3 — the vehicles, or null (tests that predate them). A
  /// vehicle narrows who may be a candidate; with no car it changes nothing.
  final VehicleController? _vehicles;

  /// The primary link's transport, for the D5 phone-slow guard only: while the
  /// experiment runs it keeps a write window too ([BleService.trackWriteWindow];
  /// the primary is never paused, so the window is all that changes for it).
  /// Null in tests that predate the guard ⇒ the 0103 rule exactly.
  final BleService? _primaryBle;

  /// The vehicle the last [_onVehiclesChanged] saw as current (null = none,
  /// or no car exists).
  String? _lastVehicleId;

  /// The primary this controller is letting go of for a vehicle switch. Its
  /// A → null is NOT the user letting go, so [_trackPrimary] must not put it in
  /// [_released] — otherwise picking that group again could never reconnect it.
  String? _vehicleDropped;

  /// When the personal group last asked the primary to connect a power bank.
  DateTime? _personalAttemptAt;

  /// When each unit was last known to be in range: seen in a scan, or live on
  /// the primary or a secondary link (2026.11.12/004, option a). Only a unit
  /// seen within [presenceWindow] is a candidate — see [_isPresent].
  final Map<String, DateTime> _seenAt = <String, DateTime>{};

  /// Per primary: the units that have been live on a secondary link while it
  /// was the live primary — its "companions" (2026.11.15/003).
  ///
  /// The presence rule (2026.11.12/004) releases a secondary not seen for
  /// [presenceWindow], and presence scans never run in the background. So
  /// when the user walked away from the car and came back with the app in the
  /// background, the primary reconnected by itself and the other unit — which
  /// had been released meanwhile — stayed down for two hours, until the app
  /// was next opened. When the primary comes back, its companions are taken
  /// as present again ([_bringBackCompanions]); one that really is not there
  /// gives its slot back after [presenceWindow], exactly as before.
  final Map<String, Set<String>> _companions = <String, Set<String>>{};

  /// Whether the primary was live at the last [_notePresence] — the edge
  /// that [_bringBackCompanions] fires on.
  bool _primaryWasOnline = false;

  /// The scan list last harvested into [_seenAt]. A finished scan's list stays
  /// on the controller; comparing identity keeps it from re-stamping forever.
  List<DiscoveredDevice>? _lastScan;

  /// When [presenceTick] last asked for a scan of its own.
  DateTime? _lastPresenceScanAt;

  final Map<String, _Secondary> _links = <String, _Secondary>{};

  /// Demoted [MultiLinkConfig.demoteMaxPerSession] times — left out until the
  /// user connects the unit by hand (D5 ⑤).
  final Set<String> _leftOut = <String>{};

  /// Units the user disconnected as the primary link: not adopted as a
  /// secondary behind their back. Cleared when they connect it again.
  final Set<String> _released = <String>{};

  /// Units the user asked for, by picking their car in the home picker, while
  /// [_autoAllowed] is false — each may be adopted ONCE, within
  /// [presenceWindow] of the pick. See [_autoAllowed].
  final Map<String, DateTime> _grantedAt = <String, DateTime>{};

  /// The unit the primary link is being handed to, from [beforePrimaryConnect]
  /// until the primary actually names it. Never a candidate in that window.
  ///
  /// 🔴 2026.11.12/001: without this, the primary still reports the OLD unit
  /// while it tears that one down, so [_reconcile] saw the target as an
  /// ordinary saved unit and adopted it again — a second Dart link on the one
  /// physical connection. As soon as the primary named the target, that link
  /// was released as `not-wanted`, and its disconnect cancelled the primary's
  /// fresh connection too (`gatt setup failed: device is disconnected`). Each
  /// tap onto another unit cost 3.8–5.0 s against 1.8–2.1 s with the switch
  /// off, 4 of 4 hand-offs in that batch.
  String? _handoffTarget;

  bool _enabled = false;
  bool _skipPrompt = false;
  bool _stoppedByUser = false;
  bool _notifyDriven = false;
  bool _disposed = false;
  String? _lastPrimary;
  bool _powerBankHeld = false;
  Timer? _demoteTimer;
  Timer? _stallTimer;
  String _lastReadyLine = '';
  MultiLinkBodyFormat _bodyFormat = (n, r) => '$n · $r';

  /// Serialises secondary connects: each one takes the plugin's global mutex
  /// through discovery, and a queue keeps them from stacking up behind it.
  Future<void> _connectChain = Future<void>.value();

  /// The user's 「自動重連」 setting, read as the one switch that governs "the
  /// app may connect on its own" — the reading the device page already gives
  /// it (`autoConnectBlocker`).
  ///
  /// 🔴 2026-11-18 user report: with the setting off, the home tab still
  /// connected a car battery every time it was in range — this controller
  /// never read the setting. The user parks the car for a month and wanted
  /// the phone to leave the battery alone. Off now means:
  ///
  ///   * no adoption on presence (scan, saved list change, switch-on) — only a
  ///     unit the user asked for by picking its car in the home picker
  ///     ([_grantedAt]), and only once;
  ///   * a secondary that drops is let go, not retried;
  ///   * the personal group connects its power bank only on that same pick,
  ///     never on its 30 s retry or when a page closes.
  ///
  /// A link already up when the setting goes off stays up: the setting is
  /// about what the app starts, not about cutting what the user is watching.
  bool get _autoAllowed => _settings.autoReconnect;

  bool _granted(String id) {
    final at = _grantedAt[id];
    return at != null && _now().difference(at) <= presenceWindow;
  }

  // ---- public surface ----------------------------------------------------

  /// The experiment switch (default OFF, persisted as a marker file) — what
  /// the USER chose, which the settings row shows (design 0063 Q9). Whether
  /// the experiment actually runs is [active].
  bool get enabled => _enabled;

  /// design 0107: the switch is on AND the app is in personal mode. Simple
  /// mode (`AppMode.advanced`) withholds multi-link and vehicles the way it
  /// withholds speed detection and the G meter (design 0063 §3.0.3):
  /// effective off, the stored switch untouched, restored on the way back.
  bool get active => _active;

  bool get _personalMode => _settings.mode == AppMode.personal;
  bool get _active => _enabled && _personalMode;

  /// [_active] as the last [_onSettingsChanged] / [load] / [setEnabled] left
  /// it — the edge [_onSettingsChanged] acts on.
  bool _wasActive = false;

  /// `on max=<n>` for the export header's `multilink:` line, or null when the
  /// switch is off (0103 §3.6 — the line is absent rather than `off`).
  String? get exportHeaderValue => _active ? 'on max=$maxLinks' : null;

  /// Secondary links with live telemetry.
  int get onlineCount => _links.values.where((l) => l.online).length;

  /// Ids of the secondary links currently up (for tests and the log line).
  Set<String> get onlineIds =>
      {for (final l in _links.values) if (l.online) l.id};

  /// Ids this controller is holding a secondary link for, up or not.
  Set<String> get heldIds => _links.keys.toSet();

  /// design 0106: the vehicle that decides who is a candidate, or null when
  /// vehicle mode is not in force (switch off, no car, or nothing selected) —
  /// in which case everything behaves exactly as before 0106.
  Vehicle? get activeVehicle {
    if (!_active) return null;
    final v = _vehicles;
    if (v == null || !v.hasCars) return null;
    return v.current;
  }

  /// Whether [deviceId] is live on a SECONDARY link.
  bool isOnlineFor(String deviceId) => _links[deviceId]?.online ?? false;

  /// design 0106 Phase 4: in range by the same rule auto-connect uses — live on
  /// a secondary link, or seen within [presenceWindow]. Drives the vehicle
  /// picker's "nearby" dot and the offline-car banner (Q3).
  bool isNearby(String deviceId) => _isPresent(deviceId);

  /// design 0106 Phase 5: the export header's `vehicle:` value, or null (no
  /// line) while the switch is off — the same rule as `multilink:`.
  /// `current=<car n|personal|none>/<cars> devices=<k>`. ⛔ Never a name: a car
  /// name may be a plate number (§4.3).
  String? get vehicleHeaderValue {
    if (!_active) return null;
    final cars = _vehicles?.cars.length ?? 0;
    final cur = activeVehicle;
    if (cur == null) return 'current=none/$cars devices=0';
    return 'current=${_vehicleLabel(cur.id)}/$cars '
        'devices=${cur.deviceIds.length}';
  }

  /// Whether [deviceId]'s secondary link is paused (power bank or demotion).
  bool isPausedFor(String deviceId) => _links[deviceId]?.paused ?? false;

  /// The card data for a live secondary link, or null.
  CardTelemetry? telemetryFor(String deviceId) {
    final l = _links[deviceId];
    if (l == null || !l.online) return null;
    return StaticCardTelemetry(
      sample: l.last ?? TelemetrySample.empty(),
      trend: l.trend,
      tempUnit: _settings.settings.tempUnit,
    );
  }

  /// The class a secondary link's cards draw with: its saved class (only
  /// non-power-bank units are ever adopted, see [_candidates]).
  /// design 0106 Phase 1: the device page's view of a unit live on a
  /// SECONDARY link, or null when it is not (offline, releasing, or a class
  /// the secondary dashboard cannot draw from the saved record alone).
  ///
  /// Only a battery or capacitor gets one: those are the only classes a
  /// secondary link ever carries (power banks are never adopted, D1), and a
  /// unit saved without a class has no record to route its dashboard by —
  /// that page keeps the pre-Phase-1 behaviour of connecting it as the
  /// primary, where the wire byte resolves the class.
  DeviceLiveSource? liveSourceFor(String deviceId) {
    final l = _links[deviceId];
    if (l == null || !l.online || l.releasing) return null;
    final cls = classFor(deviceId);
    if (cls != ProductClass.smartBattery && cls != ProductClass.supercapacitor) {
      return null;
    }
    return _SecondaryLiveSource(this, l, cls);
  }

  ProductClass classFor(String deviceId) =>
      _devices.deviceFor(deviceId)?.productClass ?? ProductClass.unknown;

  /// Read the persisted switch and start if it is on.
  Future<void> load() async {
    _enabled = await _enabledMarker.acknowledged();
    _skipPrompt = await _skipPromptMarker.acknowledged();
    if (_disposed) return;
    // design 0107: `settings.load()` has already run (`AppServices.create`),
    // so the mode read here is the stored one.
    _wasActive = _active;
    if (_active) _start();
    notifyListeners();
  }

  /// Turn the experiment on or off. Off releases every secondary link.
  Future<void> setEnabled(bool v) async {
    if (v == _enabled) return;
    _enabled = v;
    if (v) {
      await _enabledMarker.markAcknowledged();
      _stoppedByUser = false;
      if (_active) _start();
    } else {
      await _enabledMarker.clear();
      _stop();
    }
    _wasActive = _active;
    _tele.logExtraPacket(BlePacketEvent(LogDirection.event, const [],
        note: 'multilink: switch ${v ? 'on' : 'off'} max=$maxLinks'));
    _conn.refreshMultiLinkMonitor(null);
    notifyListeners();
  }

  /// The localized reading-line template, from the UI (see `main.dart`).
  void setBodyFormat(MultiLinkBodyFormat f) => _bodyFormat = f;

  /// D7: the notification's reading line, or null when no secondary is up
  /// (the primary's own line is then the right one).
  String? notificationBody(TelemetrySample latest) {
    final n = onlineCount;
    if (n == 0) return null;
    return _bodyFormat(n + (_conn.isOnline ? 1 : 0), formatMonitorBody(latest));
  }

  /// D2: whether opening [deviceId]'s page should ask first — only for a power
  /// bank, only while other links are live, and not after "don't show again".
  bool shouldPromptForPowerBank(String deviceId) =>
      _active &&
      !_skipPrompt &&
      classFor(deviceId) == ProductClass.powerBank &&
      onlineCount > 0;

  /// "Don't show again" on the D2 prompt.
  Future<void> skipPowerBankPromptFromNowOn() async {
    _skipPrompt = true;
    await _skipPromptMarker.markAcknowledged();
  }

  // ---- hooks called by ConnectionController / the detail page -------------

  /// The primary link is about to connect to [deviceId].
  Future<void> beforePrimaryConnect(String deviceId) async {
    _handoffTarget = deviceId;
    // The unit being handed AWAY from was live a moment ago, so it is in range
    // — and a connected unit does not advertise, so no scan would say so.
    final cur = _conn.connectedDeviceId;
    if (cur != null && _conn.isOnline) _seenAt[cur] = _now();
    _stoppedByUser = false;
    _leftOut.remove(deviceId);
    _released.remove(deviceId);
    if (_links.containsKey(deviceId)) {
      await _release(deviceId, reason: 'handoff-to-primary');
    }
    // D1: exclusivity starts BEFORE the power bank connects — its connect and
    // discovery take the same global lock the others' polls would.
    if (classFor(deviceId) == ProductClass.powerBank) _holdForPowerBank();
  }

  /// The device page for [deviceId] was closed. Leaving a power bank's page
  /// disconnects it and gives the others their polling back (D1 / 0046a
  /// §5.6.3's navigation rule) — but only when there ARE others: a lone power
  /// bank keeps today's behaviour exactly (0103 G4).
  ///
  /// design 0106 §4.1: with a vehicle in force, a primary that is not a member
  /// of it — left alone by the switch itself (Q4: picking a vehicle never takes
  /// away the unit being looked at) — is let go when its page closes.
  void onDetailClosed(String deviceId) {
    if (!_active) return;
    if (_conn.connectedDeviceId != deviceId) return;
    final vehicle = activeVehicle;
    if (vehicle != null && !vehicle.contains(deviceId)) {
      unawaited(_dropPrimaryForVehicle(deviceId).then((_) {
        // Closing a page is not asking for a power bank: with 自動重連 off
        // the personal group waits for the user (see [_autoAllowed]).
        if (vehicle.isPersonal && _autoAllowed) {
          _connectPersonalIfNeeded(force: true);
        }
      }));
      return;
    }
    if (_links.isEmpty) return;
    if (!_primaryIsPowerBank()) return;
    unawaited(_conn.disconnect());
  }

  /// The user pressed 中斷 on a unit that is live on a SECONDARY link
  /// (feedback 2026.11.16/009, owner ruling (a)): let go of that one link and
  /// nothing else — the primary and the other secondaries stay up.
  ///
  /// Recorded in [_released] exactly like a primary the user disconnected, so
  /// [_reconcile] does not adopt it again behind their back (PR #43's rule).
  /// Cleared the same way too: connecting it by hand ([beforePrimaryConnect])
  /// or picking a vehicle that holds it.
  Future<void> releaseByUser(String deviceId) async {
    if (!_links.containsKey(deviceId)) return;
    _released.add(deviceId);
    await _release(deviceId, reason: 'user');
  }

  /// [BleService.connectionPriority] changed: apply it to every secondary now
  /// (each also applies it by itself on its next `ready`).
  Future<void> applyConnectionPriorityNow() async {
    for (final l in _links.values.toList()) {
      await l.ble.applyConnectionPriorityNow();
    }
  }

  /// The user pressed "stop" on the ongoing notification.
  void onMonitorStopped() {
    _stoppedByUser = true;
    for (final id in _links.keys.toList()) {
      unawaited(_release(id, reason: 'monitor-stopped'));
    }
  }

  /// Mirror the primary's keep-alive regime onto the secondaries (iOS
  /// background window, design 0047).
  void setNotifyDrivenKeepAlive(bool active) {
    _notifyDriven = active;
    for (final l in _links.values) {
      l.ble.setNotifyDrivenKeepAlive(active);
    }
  }

  // ---- lifecycle -----------------------------------------------------------

  void _start() {
    _primaryBle?.trackWriteWindow = true;
    _demoteTimer?.cancel();
    _demoteTimer = Timer.periodic(demoteCheckEvery, (_) {
      checkDemotions();
      presenceTick();
    });
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(stallCheckEvery, (_) => checkStalls());
    _reconcile();
    presenceTick();
  }

  /// design 0107: [_active] flipped because the app MODE changed (the stored
  /// switch cannot change from here — its row is disabled in simple mode).
  /// Acts in the same frame, like `GForceController.applySettings`: going to
  /// simple mode lets every secondary go at once (the primary is untouched);
  /// coming back starts again under the usual rules, 自動連線 included.
  void _onSettingsChanged() {
    if (_disposed) return;
    final now = _active;
    if (now == _wasActive) return;
    _wasActive = now;
    if (now) {
      _start();
    } else {
      _stop(reason: 'simple-mode');
    }
    notifyListeners();
  }

  void _stop({String reason = 'switch-off'}) {
    _primaryBle?.trackWriteWindow = false;
    _handoffTarget = null;
    _lastPresenceScanAt = null;
    _demoteTimer?.cancel();
    _demoteTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _powerBankHeld = false;
    for (final id in _links.keys.toList()) {
      unawaited(_release(id, reason: reason));
    }
  }

  bool _primaryIsPowerBank() {
    final p = _conn.connectedDeviceId;
    if (p == null) return false;
    return _conn.displayClass == ProductClass.powerBank ||
        classFor(p) == ProductClass.powerBank;
  }

  void _onPrimaryChanged() {
    if (_disposed) return;
    _notePresence();
    _trackPrimary();
    if (!_active) return;
    if (_primaryIsPowerBank()) {
      _holdForPowerBank();
    } else if (_powerBankHeld) {
      _releasePowerBankHold();
    }
    _reconcile();
    _logReadyIfChanged();
  }

  /// Fold a change of primary into [_released] / [_seenAt] / [_handoffTarget].
  ///
  /// Called from the primary's listener AND at the top of [_reconcile]. The
  /// listener alone is not enough (2026.11.13/016): the primary's handle is
  /// cleared during teardown a few awaits before its `disconnected` event
  /// reaches [ConnectionController], so `connectedDeviceId` already reads null
  /// while no notification has fired. A reconcile entered from another path in
  /// that window — the presence tick, or a saved-device update — saw the unit
  /// as an ordinary nearby candidate and adopted it as a secondary 10 ms after
  /// the user pressed disconnect.
  void _trackPrimary() {
    final p = _conn.connectedDeviceId;
    // The hand-off has landed: from here on the target is excluded as the
    // primary itself, which is the rule that should hold it.
    if (p != null && p == _handoffTarget) _handoffTarget = null;
    if (p == _lastPrimary) return;
    final gone = _lastPrimary;
    // A → null is the user letting go (only `disconnect()` clears the desired
    // id; a radio drop keeps it while the ladder runs). A → B is a hand-off,
    // and A becomes eligible as a secondary.
    if (gone != null && p == null) {
      // …unless WE let it go for a vehicle switch (design 0106 §4.1).
      if (gone == _vehicleDropped) {
        _vehicleDropped = null;
      } else {
        _released.add(gone);
      }
    }
    // A → B: A was the live primary until just now.
    if (gone != null && p != null) _seenAt[gone] = _now();
    // design 0106 PQ2: a power bank on the primary becomes the personal
    // group's default (ignored unless it is a member).
    if (p != null && classFor(p) == ProductClass.powerBank) {
      _vehicles?.notePowerBank(p);
    }
    _lastPrimary = p;
  }

  void _holdForPowerBank() {
    if (_powerBankHeld) return;
    _powerBankHeld = true;
    for (final l in _links.values.toList()) {
      if (powerBankOthers == PowerBankOthersMode.pause) {
        if (!l.pausedForPowerBank) {
          l.pausedForPowerBank = true;
          if (!l.demoted) l.ble.pausePolling(reason: 'power-bank');
        }
      } else {
        unawaited(_release(l.id, reason: 'power-bank'));
      }
    }
    notifyListeners();
  }

  void _releasePowerBankHold() {
    _powerBankHeld = false;
    for (final l in _links.values) {
      if (!l.pausedForPowerBank) continue;
      l.pausedForPowerBank = false;
      if (!l.demoted) l.ble.resumePolling();
    }
    notifyListeners();
  }

  /// Fold what the primary controller knows into [_seenAt]: a new scan list,
  /// and the primary itself while it is live.
  void _notePresence() {
    final now = _now();
    final scan = _conn.scanResults;
    if (!identical(scan, _lastScan)) {
      _lastScan = scan;
      for (final r in scan) {
        _seenAt[r.id] = now;
      }
    }
    final p = _conn.connectedDeviceId;
    final online = p != null && _conn.isOnline;
    if (online) {
      _seenAt[p] = now;
      if (!_primaryWasOnline) _bringBackCompanions(p);
    }
    _primaryWasOnline = online;
  }

  /// The primary [p] has just come (back) online: the units that belong with
  /// it are taken as in range now. With a car in force those are the car's
  /// other units (design 0106 — a car holds at most [Vehicle.maxDevicesPerCar]
  /// = the link budget, so they never crowd out anyone); otherwise the units
  /// seen live beside it before ([_companions]). See [_companions] for the
  /// report this answers.
  void _bringBackCompanions(String p) {
    final vehicle = activeVehicle;
    final ids = <String>{
      if (vehicle != null && vehicle.isCar && vehicle.contains(p))
        ...vehicle.deviceIds
      else
        ...?_companions[p],
    }..remove(p);
    final now = _now();
    final back = <String>[
      for (final id in ids)
        if (!_isPresent(id)) id,
    ];
    if (back.isEmpty) return;
    for (final id in back) {
      _seenAt[id] = now;
    }
    _tele.logExtraPacket(BlePacketEvent(LogDirection.event, const [],
        note: 'multilink: companions back with=${shortDeviceHash(p)} '
            'ids=${back.map(shortDeviceHash).join(',')}'));
  }

  /// In range: live on a secondary link, or seen within [presenceWindow].
  bool _isPresent(String id) {
    if (_links[id]?.online ?? false) return true;
    final at = _seenAt[id];
    return at != null && _now().difference(at) <= presenceWindow;
  }

  /// Which saved units should hold a secondary link right now, in saved order
  /// — and in range (2026.11.12/004: an absent unit no longer takes a slot).
  List<String> _candidates() =>
      [for (final id in _eligible()) if (_isPresent(id)) id];

  /// Saved units that could hold a secondary link, in range or not.
  List<String> _eligible() {
    final primary = _conn.connectedDeviceId;
    // design 0106 §4.1: a car narrows the candidates to its own units; the
    // personal group has no secondaries at all (its power bank is the
    // primary). No vehicle ⇒ null ⇒ the 0103 rule, unchanged.
    final vehicle = activeVehicle;
    final scope = vehicle == null
        ? null
        : (vehicle.isCar ? vehicle.deviceIds.toSet() : const <String>{});
    return [
      for (final d in _devices.devices)
        if ((scope == null || scope.contains(d.id)) &&
            d.id != primary &&
            d.id != _handoffTarget &&
            d.productClass != ProductClass.powerBank &&
            !isDemoDeviceId(d.id) &&
            !d.stale &&
            !_leftOut.contains(d.id) &&
            !_released.contains(d.id))
          d.id,
    ];
  }

  void _reconcile() {
    if (_disposed) return;
    _trackPrimary();
    if (!_active || _stoppedByUser) {
      if (_links.isNotEmpty) {
        final reason = !_enabled
            ? 'switch-off'
            : (!_personalMode ? 'simple-mode' : 'stopped');
        for (final id in _links.keys.toList()) {
          unawaited(_release(id, reason: reason));
        }
      }
      return;
    }
    final primary = _conn.connectedDeviceId;
    final budget = maxLinks - (primary != null ? 1 : 0);
    // 自動重連 off: only what is already held, or what the user just asked for
    // (see [_autoAllowed]).
    final auto = _autoAllowed;
    final want = [
      for (final id in _candidates())
        if (auto || _links.containsKey(id) || _granted(id)) id
    ].take(budget < 0 ? 0 : budget).toSet();
    for (final id in _links.keys.toList()) {
      if (id == primary || !want.contains(id)) {
        // While a power bank is held (pause mode) the paused links stay: the
        // whole point of pausing is to come back without a reconnect.
        final keepPaused = _powerBankHeld &&
            powerBankOthers == PowerBankOthersMode.pause &&
            id != primary &&
            _candidates().contains(id);
        if (!keepPaused) unawaited(_release(id, reason: 'not-wanted'));
      }
    }
    // A power bank's cost is the whole budget (0046a §5.5): no new links
    // while it holds the primary.
    if (_powerBankHeld) return;
    for (final id in want) {
      if (!_links.containsKey(id)) {
        _grantedAt.remove(id); // one adoption per pick
        _adopt(id);
      }
    }
  }

  void _adopt(String id) {
    final ble = _bleFactory()..trackWriteWindow = true;
    ble.setNotifyDrivenKeepAlive(_notifyDriven);
    final l = _Secondary(id, ble);
    _links[id] = l;
    l.subs
      ..add(ble.linkState.listen((s) => _onLinkState(l, s)))
      ..add(ble.telemetry.listen((s) => _onSample(l, s)))
      ..add(ble.packets
          .listen((e) => _tele.logExtraPacket(e, fallbackDeviceId: id)))
      ..add(ble.diagnostics.listen((line) => _tele.logExtraPacket(
          BlePacketEvent(LogDirection.event, const [],
              note: line, deviceId: id))));
    _connect(l);
  }

  void _connect(_Secondary l) {
    _connectChain = _connectChain.then((_) async {
      if (_disposed || _links[l.id] != l || l.releasing) return;
      try {
        await l.ble.connect(l.id);
      } catch (_) {
        // The `disconnected` it publishes schedules the retry (_onLinkState).
      }
    });
  }

  void _onLinkState(_Secondary l, BleLinkState s) {
    if (_links[l.id] != l) return;
    final wasOnline = l.online;
    l.state = s;
    if (s == BleLinkState.ready) {
      l.retryAttempts = 0;
      l.readyAt = _now();
      // Seeded like the primary's stall watch: the first frame gets the full
      // threshold as grace, while [samples] still says nothing has arrived.
      l.lastSampleAt = l.readyAt;
      l.samples = 0;
      l.stalled = false;
      // A link that comes up while a power bank holds the primary joins the
      // pause straight away.
      if (_powerBankHeld && powerBankOthers == PowerBankOthersMode.pause) {
        l.pausedForPowerBank = true;
        l.ble.pausePolling(reason: 'power-bank');
      }
    }
    if (s == BleLinkState.disconnected) {
      if (wasOnline) _tele.flushHistoryFor(l.id);
      l.pausedForPowerBank = false;
      l.demoted = false;
      l.demoteTimer?.cancel();
      if (!l.releasing) {
        // 自動重連 off: a dropped secondary is let go, not retried.
        if (_autoAllowed) {
          _scheduleRetry(l);
        } else {
          unawaited(_release(l.id, reason: 'auto-off'));
        }
      }
    }
    if (wasOnline != l.online) {
      _logReadyIfChanged();
      _conn.refreshMultiLinkMonitor(l.last);
      notifyListeners();
    }
  }

  void _scheduleRetry(_Secondary l) {
    if (l.retryTimer?.isActive ?? false) return;
    final shift = l.retryAttempts.clamp(0, 10);
    final ms = retryBase.inMilliseconds * (1 << shift);
    final delay = Duration(
        milliseconds: ms > retryCap.inMilliseconds ? retryCap.inMilliseconds : ms);
    l.retryAttempts++;
    l.retryTimer = Timer(delay, () {
      if (_disposed || _links[l.id] != l || l.releasing || !_active) return;
      // The setting went off while this retry was waiting.
      if (!_autoAllowed) {
        unawaited(_release(l.id, reason: 'auto-off'));
        return;
      }
      _connect(l);
    });
  }

  void _onSample(_Secondary l, TelemetrySample s) {
    if (_links[l.id] != l) return;
    // A unit saved without a class can still turn out to be a power bank. It
    // must not be a secondary (D1), so it is let go for the session.
    if (s.isPowerBank) {
      _leftOut.add(l.id);
      unawaited(_release(l.id, reason: 'is-power-bank'));
      // design 0106 §3.2: and out of every car, into the personal group.
      final v = _vehicles;
      if (v != null && v.vehiclesOf(l.id).any((x) => x.isCar)) {
        _tele.logExtraPacket(BlePacketEvent(LogDirection.event, const [],
            note: 'vehicle: moved power bank to personal '
                'id=${shortDeviceHash(l.id)}',
            deviceId: l.id));
        unawaited(v.movePowerBankToPersonal(l.id));
      }
      return;
    }
    _seenAt[l.id] = _now();
    l.last = s;
    l.lastSampleAt = _now();
    l.samples++;
    l.stalled = false;
    final mac = s.mac;
    if (mac != null && mac.isNotEmpty) l.liveMac = mac;
    l.trend.add(s);
    _tele.recordExtraSample(l.id, s);
    final now = DateTime.now();
    final touched = l.lastTouchAt;
    if (touched == null || now.difference(touched) >= const Duration(minutes: 1)) {
      l.lastTouchAt = now;
      unawaited(_devices.touch(l.id,
          lastSeen: now, lastValue: s.pvlt, lastSoc: s.socPercent));
    }
    _conn.refreshMultiLinkMonitor(s);
    notifyListeners();
  }

  /// 2026.11.12/004: re-evaluate presence, and look for nearby units when a
  /// slot is free. Public for tests; the periodic timer started by [_start]
  /// (and [_start] itself) are the production callers.
  ///
  /// The reconcile is what frees a slot: a held unit that is offline and has
  /// not been seen for [presenceWindow] is no longer a candidate, so it is
  /// released instead of retrying in a slot a nearby unit could use.
  ///
  /// Scans run only where the user is looking at the app and not at one
  /// unit's page — the same window the devices tab scans in — and only when a
  /// slot is free AND some saved unit's presence is unknown. The devices tab
  /// only scans while it is open, so without this a cold start on the home
  /// tab would know of no unit at all.
  @visibleForTesting
  void presenceTick() {
    if (_disposed || !_active || _stoppedByUser) return;
    _reconcile();
    if (_powerBankHeld) return;
    final vehicle = activeVehicle;
    final personal = vehicle != null && vehicle.isPersonal;
    if (personal) _connectPersonalIfNeeded();
    final budget = maxLinks - (_conn.connectedDeviceId != null ? 1 : 0);
    if (_links.length >= budget) return;
    final now = _now();
    final last = _lastPresenceScanAt;
    if (last != null && now.difference(last) < presenceScanEvery) return;
    if (_conn.inBackground || _conn.detailVisible || _conn.isScanning) return;
    // The personal group looks for its power banks; everyone else for the
    // units that could take a secondary slot.
    final auto = _autoAllowed;
    final lookFor = personal
        ? [
            for (final id in vehicle.deviceIds)
              if (!_released.contains(id) && auto) id
          ]
        // 自動重連 off: scan only for the units the user just asked for.
        : [for (final id in _eligible()) if (auto || _granted(id)) id];
    if (personal && _conn.connectedDeviceId != null) return;
    if (!lookFor.any((id) => !_isPresent(id))) return;
    _lastPresenceScanAt = now;
    unawaited(_conn.startPresenceScan(timeout: presenceScanTimeout));
  }

  // ---- design 0106 Phase 3: vehicles ---------------------------------------

  String? _vehicleIdNow() {
    final v = _vehicles;
    if (v == null || !v.hasCars) return null;
    return v.current?.id;
  }

  /// `none` / `personal` / `car<n>` (1-based, in the user's order). ⛔ Never
  /// the name — it may be a plate number (design 0106 §4.3).
  String _vehicleLabel(String? id) {
    final v = _vehicles;
    if (id == null || v == null) return 'none';
    final veh = v.vehicleFor(id);
    if (veh == null) return 'none';
    if (veh.isPersonal) return 'personal';
    final i = v.cars.indexWhere((c) => c.id == id);
    return 'car${i + 1}';
  }

  void _onVehiclesChanged() {
    if (_disposed) return;
    final id = _vehicleIdNow();
    final prev = _lastVehicleId;
    _lastVehicleId = id;
    if (!_active || _stoppedByUser) return;
    if (id != prev) _applyVehicleSwitch(prev, _vehicles?.vehicleFor(id));
    _reconcile();
    _logReadyIfChanged();
  }

  /// §4.1: the user picked another group.
  void _applyVehicleSwitch(String? prevId, Vehicle? next) {
    final source = _vehicles?.takeSelectSource() ?? 'other';
    _tele.logExtraPacket(BlePacketEvent(LogDirection.event, const [],
        note: 'vehicle: switch ${_vehicleLabel(prevId)}'
            '→${_vehicleLabel(next?.id)}'
            ' source=$source'));
    if (next == null) return; // no vehicle any more ⇒ the 0103 rule
    // 自動重連 off: only the home picker is the user asking for a group's
    // units — `device-page` follows a unit the user opened, `editor` and a
    // first car becoming current ask for nothing (see [_autoAllowed]).
    final mayConnect = _autoAllowed || source == 'home';
    final primary = _conn.connectedDeviceId;
    if (next.isCar) {
      // V1 (owner 2026-11-14 「V1: OK」): choosing this car means wanting its
      // units, including one the user disconnected earlier.
      _released.removeAll(next.deviceIds);
      if (!_autoAllowed && mayConnect) {
        final at = _now();
        for (final id in next.deviceIds) {
          _grantedAt[id] = at;
        }
      }
      for (final id in _links.keys.toList()) {
        if (!next.contains(id)) {
          unawaited(_release(id, reason: 'vehicle-switch'));
        }
      }
      // A power bank never stays beside a car's units (R6). Any other
      // non-member primary is left until its page closes (Q4).
      if (primary != null && _primaryIsPowerBank()) {
        unawaited(_dropPrimaryForVehicle(primary));
      }
      presenceTick();
      return;
    }
    // Personal: every secondary goes; the power bank comes in as the primary.
    for (final id in _links.keys.toList()) {
      unawaited(_release(id, reason: 'vehicle-switch'));
    }
    _personalAttemptAt = null;
    if (primary != null && !next.contains(primary)) {
      // Q4's spirit: not out from under an open page — that is let go when
      // the page closes (onDetailClosed). Otherwise make room now.
      if (_conn.detailVisible) return;
      unawaited(_dropPrimaryForVehicle(primary).then((_) {
        if (mayConnect) _connectPersonalIfNeeded(force: true);
      }));
      return;
    }
    if (mayConnect) _connectPersonalIfNeeded(force: true);
    presenceTick();
  }

  /// Let the primary go because of a vehicle switch: logged as such and kept
  /// OUT of [_released] (see [_vehicleDropped]).
  Future<void> _dropPrimaryForVehicle(String id) async {
    _vehicleDropped = id;
    _tele.logExtraPacket(BlePacketEvent(LogDirection.event, const [],
        note: 'multilink: release-primary id=${shortDeviceHash(id)} '
            'reason=vehicle-switch',
        deviceId: id));
    try {
      await _conn.disconnect();
    } catch (_) {
      // Nothing to undo: the link is going either way.
    }
  }

  /// PQ2: the personal group connects ONE power bank, as the primary — the
  /// last one used if it is in range, else the first member in range. None in
  /// range ⇒ stay offline (no switching groups behind the user's back, Q3).
  void _connectPersonalIfNeeded({bool force = false}) {
    final vehicle = activeVehicle;
    if (_disposed || vehicle == null || !vehicle.isPersonal) return;
    // 自動重連 off: only a forced call — the user's own pick — connects.
    if (!force && !_autoAllowed) return;
    if (_conn.connectedDeviceId != null) return; // already on, or coming up
    if (!force && _conn.inBackground) return;
    final now = _now();
    final lastTry = _personalAttemptAt;
    if (!force &&
        lastTry != null &&
        now.difference(lastTry) < personalRetryEvery) {
      return;
    }
    final ids = [
      for (final id in vehicle.deviceIds)
        if (!_released.contains(id) && !isDemoDeviceId(id)) id
    ];
    String? target;
    final lastPb = vehicle.lastPowerBankId;
    if (lastPb != null && ids.contains(lastPb) && _isPresent(lastPb)) {
      target = lastPb;
    }
    if (target == null) {
      for (final id in ids) {
        if (_isPresent(id)) {
          target = id;
          break;
        }
      }
    }
    if (target == null) return;
    _personalAttemptAt = now;
    unawaited(_conn
        .connect(target,
            seedClass: ProductClass.powerBank, autoTrigger: 'vehicle-personal')
        .catchError((Object _) {}));
  }

  /// design 0106 Phase 1: re-evaluate each secondary link's stall flag, and
  /// notify only when one changes. Public for tests; the periodic timer started
  /// by [_start] is the only production caller.
  @visibleForTesting
  void checkStalls() {
    final now = _now();
    var changed = false;
    for (final l in _links.values) {
      final at = l.lastSampleAt;
      final next = l.online && at != null && now.difference(at) > stallThreshold;
      if (next == l.stalled) continue;
      l.stalled = next;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// D5: evaluate the slow-writer rule once. Public for tests; the periodic
  /// timer started by [_start] is the only production caller.
  @visibleForTesting
  void checkDemotions() {
    if (!_active) return;
    final active = _links.values.where((l) => l.online && !l.paused).toList();
    final total = active.length + (_conn.isOnline ? 1 : 0);
    // D5 ⑥: one link online has nobody to protect.
    if (total < 2) return;
    // 2026.11.16/006 §3.2 (owner ruling 2026-11-16, 「先保守處理」): all three
    // field demotions came while the PRIMARY was as slow or slower (3–5 s
    // writes, 5 s timeouts) — the phone was slow, and D5, which only ever
    // judged the secondaries, punished the unit that happened to be one. So:
    // if the primary's own window is also over the line, nobody is demoted.
    // Known cost, accepted as the conservative side: flutter_blue_plus holds
    // ONE global GATT mutex, so a truly slow secondary can drag the primary's
    // measured writes over the line too and then escapes demotion. With the
    // sparse paused keep-alive a wrong pause no longer drops a link, but a
    // wrong skip only costs what D5 cost before it existed.
    final primaryAvg = _conn.isOnline ? _primaryBle?.recentWriteAvgMs : null;
    final phoneSlow =
        primaryAvg != null && primaryAvg >= MultiLinkConfig.demoteAvgMs;
    for (final l in active) {
      final avg = l.ble.recentWriteAvgMs;
      if (avg == null || avg < MultiLinkConfig.demoteAvgMs) {
        l.demoteSkipLogged = false;
        continue;
      }
      if (phoneSlow) {
        if (!l.demoteSkipLogged) {
          l.demoteSkipLogged = true;
          _tele.logExtraPacket(BlePacketEvent(LogDirection.event, const [],
              note: 'link demote skipped id=${shortDeviceHash(l.id)} '
                  'reason=phone-slow avg=$avg primaryAvg=$primaryAvg '
                  'n=${BleService.writeWindowSize}',
              deviceId: l.id));
        }
        continue;
      }
      l.demoteSkipLogged = false;
      l.demoted = true;
      l.demotions++;
      l.ble.pausePolling(reason: 'slow-writer');
      _tele.logExtraPacket(BlePacketEvent(LogDirection.event, const [],
          note: 'link demoted id=${shortDeviceHash(l.id)} reason=slow-writer '
              'avg=$avg n=${BleService.writeWindowSize} '
              'demotions=${l.demotions}',
          deviceId: l.id));
      if (l.demotions >= MultiLinkConfig.demoteMaxPerSession) {
        _leftOut.add(l.id);
        unawaited(_release(l.id, reason: 'demoted-${l.demotions}x'));
        continue;
      }
      l.demoteTimer?.cancel();
      l.demoteTimer = Timer(demoteRetryAfter, () {
        if (_links[l.id] != l) return;
        l.demoted = false;
        l.ble.resetWriteWindow();
        if (!l.pausedForPowerBank) l.ble.resumePolling();
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> _release(String id, {required String reason}) async {
    final l = _links.remove(id);
    if (l == null) return;
    l.releasing = true;
    l.retryTimer?.cancel();
    l.demoteTimer?.cancel();
    final wasOnline = l.online;
    _tele.logExtraPacket(BlePacketEvent(LogDirection.event, const [],
        note: 'multilink: release id=${shortDeviceHash(id)} reason=$reason',
        deviceId: id));
    if (wasOnline) _tele.flushHistoryFor(id);
    try {
      await l.ble.disconnect();
    } catch (_) {
      // Teardown proceeds through dispose below either way.
    }
    for (final sub in l.subs) {
      await sub.cancel();
    }
    await l.ble.dispose();
    if (_disposed) return;
    _logReadyIfChanged();
    if (wasOnline) _conn.refreshMultiLinkMonitor(null);
    notifyListeners();
  }

  /// `multilink: ready=<n> ids=<hashes>` whenever the set of live links
  /// (primary included) changes — 0103 §4 ①.
  void _logReadyIfChanged() {
    if (!_active) return;
    final primary = _conn.isOnline ? _conn.connectedDeviceId : null;
    final ids = <String>[
      ?primary,
      ...onlineIds,
    ];
    // Remember who was live beside the primary (see [_companions]).
    if (primary != null && onlineIds.isNotEmpty) {
      (_companions[primary] ??= <String>{}).addAll(onlineIds);
    }
    final line = 'multilink: ready=${ids.length} '
        'ids=${ids.map(shortDeviceHash).join(',')}';
    if (line == _lastReadyLine) return;
    _lastReadyLine = line;
    _tele.logExtraPacket(BlePacketEvent(LogDirection.event, const [], note: line));
  }

  @override
  void dispose() {
    _disposed = true;
    _conn.removeListener(_onPrimaryChanged);
    _devices.removeListener(_reconcile);
    _vehicles?.removeListener(_onVehiclesChanged);
    _settings.removeListener(_onSettingsChanged);
    _demoteTimer?.cancel();
    _stallTimer?.cancel();
    for (final l in _links.values) {
      l.releasing = true;
      l.retryTimer?.cancel();
      l.demoteTimer?.cancel();
      for (final sub in l.subs) {
        unawaited(sub.cancel());
      }
      unawaited(l.ble.disconnect().then((_) => l.ble.dispose(),
          onError: (Object _) => l.ble.dispose()));
    }
    _links.clear();
    super.dispose();
  }
}

/// design 0106 Phase 1 — a live SECONDARY link as a [DeviceLiveSource].
///
/// A view, not a copy: every getter reads the link's current state, and the
/// controller's own notifications are the change signal (it notifies on every
/// sample, on link state changes and on stall transitions).
class _SecondaryLiveSource implements DeviceLiveSource {
  _SecondaryLiveSource(this._ml, this._l, this._cls);

  final MultiLinkController _ml;
  final _Secondary _l;
  final ProductClass _cls;

  @override
  bool operator ==(Object other) =>
      other is _SecondaryLiveSource && identical(other._l, _l);

  @override
  int get hashCode => identityHashCode(_l);

  TelemetrySample get _s => _l.last ?? TelemetrySample.empty();
  TempUnit get _unit => _ml._settings.settings.tempUnit;

  @override
  void addListener(VoidCallback listener) => _ml.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => _ml.removeListener(listener);

  @override
  String get deviceId => _l.id;
  @override
  bool get isOnline => _l.online && !_l.releasing;
  @override
  bool get isPrimary => false;
  @override
  bool get paused => _l.paused;
  @override
  bool get handingOff => false;
  @override
  bool get hasTelemetry => _l.samples > 0;
  @override
  bool get telemetryStalled => _l.stalled;
  @override
  DateTime? get lastTelemetryAt => _l.lastSampleAt;
  @override
  Duration? get telemetryAge {
    final at = _l.lastSampleAt;
    return at == null ? null : _ml._now().difference(at);
  }

  @override
  Duration? get onlineFor {
    final at = _l.readyAt;
    return at == null ? null : _ml._now().difference(at);
  }

  @override
  ProductClass get packLabel => _cls;
  @override
  RoutingDecision get routing => routingForClass(_cls);
  @override
  DeviceCapabilities get capabilities => capabilitiesForClass(_cls);
  @override
  String? get liveMac => _l.liveMac;

  // ---- CardTelemetry / PackReadings: the link's latest sample ------------

  @override
  TelemetrySample get sample => _s;
  @override
  LiveTrendBuffer get trend => _l.trend;
  @override
  double? get pvlt => _s.pvlt;
  @override
  double? get svlt => _s.svlt;
  @override
  double? get current => _s.current;
  @override
  List<double>? get dvol => _s.dvol;
  @override
  bool get dvolPending => _s.dvolPending;
  @override
  int? get sohBucket => _s.sohBucket;
  @override
  int? get socPercent => _s.socPercent;
  @override
  double? get temperatureDisplay => displayTemperature(_s.temperatureC, _unit);
  @override
  String get temperatureUnitLabel => temperatureUnitLabelOf(_unit);
  @override
  UsbPort? get usbPort => _s.usbPort;
  @override
  bool? get isRailOff => _s.isRailOff;
  @override
  bool? get isPdIn => _s.isPdIn;
  @override
  bool? get isPdOut => _s.isPdOut;
  @override
  int? get portFlagsRaw => _s.portFlagsRaw;
  @override
  int? get mode => _s.mode;
  @override
  String? get dealerCode => _s.dealerCode;
  @override
  String? get serial => _s.serial;
  @override
  String? get fullSerial => _s.fullSerial;
  @override
  int? get temperatureC => _s.temperatureC;
}
