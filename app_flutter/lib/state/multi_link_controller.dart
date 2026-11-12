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
///     never with a single link online.
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
import 'live_trend_buffer.dart';
import 'settings_controller.dart';
import 'telemetry_controller.dart';

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

  Timer? retryTimer;
  int retryAttempts = 0;

  /// Set while [MultiLinkController] is taking this link down on purpose, so
  /// the `disconnected` it causes does not schedule a retry.
  bool releasing = false;

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
        _skipPromptMarker = skipPromptMarker {
    _conn.addListener(_onPrimaryChanged);
    _devices.addListener(_reconcile);
    _lastPrimary = _conn.connectedDeviceId;
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

  final Map<String, _Secondary> _links = <String, _Secondary>{};

  /// Demoted [MultiLinkConfig.demoteMaxPerSession] times — left out until the
  /// user connects the unit by hand (D5 ⑤).
  final Set<String> _leftOut = <String>{};

  /// Units the user disconnected as the primary link: not adopted as a
  /// secondary behind their back. Cleared when they connect it again.
  final Set<String> _released = <String>{};

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
  String _lastReadyLine = '';
  MultiLinkBodyFormat _bodyFormat = (n, r) => '$n · $r';

  /// Serialises secondary connects: each one takes the plugin's global mutex
  /// through discovery, and a queue keeps them from stacking up behind it.
  Future<void> _connectChain = Future<void>.value();

  // ---- public surface ----------------------------------------------------

  /// The experiment switch (default OFF, persisted as a marker file).
  bool get enabled => _enabled;

  /// `on max=<n>` for the export header's `multilink:` line, or null when the
  /// switch is off (0103 §3.6 — the line is absent rather than `off`).
  String? get exportHeaderValue => _enabled ? 'on max=$maxLinks' : null;

  /// Secondary links with live telemetry.
  int get onlineCount => _links.values.where((l) => l.online).length;

  /// Ids of the secondary links currently up (for tests and the log line).
  Set<String> get onlineIds =>
      {for (final l in _links.values) if (l.online) l.id};

  /// Ids this controller is holding a secondary link for, up or not.
  Set<String> get heldIds => _links.keys.toSet();

  /// Whether [deviceId] is live on a SECONDARY link.
  bool isOnlineFor(String deviceId) => _links[deviceId]?.online ?? false;

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
  ProductClass classFor(String deviceId) =>
      _devices.deviceFor(deviceId)?.productClass ?? ProductClass.unknown;

  /// Read the persisted switch and start if it is on.
  Future<void> load() async {
    _enabled = await _enabledMarker.acknowledged();
    _skipPrompt = await _skipPromptMarker.acknowledged();
    if (_disposed) return;
    if (_enabled) _start();
    notifyListeners();
  }

  /// Turn the experiment on or off. Off releases every secondary link.
  Future<void> setEnabled(bool v) async {
    if (v == _enabled) return;
    _enabled = v;
    if (v) {
      await _enabledMarker.markAcknowledged();
      _stoppedByUser = false;
      _start();
    } else {
      await _enabledMarker.clear();
      _stop();
    }
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
      _enabled &&
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
  void onDetailClosed(String deviceId) {
    if (!_enabled || _links.isEmpty) return;
    if (_conn.connectedDeviceId != deviceId) return;
    if (!_primaryIsPowerBank()) return;
    unawaited(_conn.disconnect());
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
    _demoteTimer?.cancel();
    _demoteTimer = Timer.periodic(demoteCheckEvery, (_) => checkDemotions());
    _reconcile();
  }

  void _stop() {
    _handoffTarget = null;
    _demoteTimer?.cancel();
    _demoteTimer = null;
    _powerBankHeld = false;
    for (final id in _links.keys.toList()) {
      unawaited(_release(id, reason: 'switch-off'));
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
    final p = _conn.connectedDeviceId;
    // The hand-off has landed: from here on the target is excluded as the
    // primary itself, which is the rule that should hold it.
    if (p != null && p == _handoffTarget) _handoffTarget = null;
    if (p != _lastPrimary) {
      final gone = _lastPrimary;
      // A → null is the user letting go (only `disconnect()` clears the
      // desired id; a radio drop keeps it while the ladder runs). A → B is a
      // hand-off, and A becomes eligible as a secondary.
      if (gone != null && p == null) _released.add(gone);
      _lastPrimary = p;
    }
    if (!_enabled) return;
    if (_primaryIsPowerBank()) {
      _holdForPowerBank();
    } else if (_powerBankHeld) {
      _releasePowerBankHold();
    }
    _reconcile();
    _logReadyIfChanged();
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

  /// Which saved units should hold a secondary link right now, in saved order.
  List<String> _candidates() {
    final primary = _conn.connectedDeviceId;
    return [
      for (final d in _devices.devices)
        if (d.id != primary &&
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
    if (!_enabled || _stoppedByUser) {
      if (_links.isNotEmpty && (!_enabled || _stoppedByUser)) {
        for (final id in _links.keys.toList()) {
          unawaited(_release(id, reason: _enabled ? 'stopped' : 'switch-off'));
        }
      }
      return;
    }
    final primary = _conn.connectedDeviceId;
    final budget = maxLinks - (primary != null ? 1 : 0);
    final want = _candidates().take(budget < 0 ? 0 : budget).toSet();
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
      if (!_links.containsKey(id)) _adopt(id);
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
      if (!l.releasing) _scheduleRetry(l);
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
      if (_disposed || _links[l.id] != l || l.releasing || !_enabled) return;
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
      return;
    }
    l.last = s;
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

  /// D5: evaluate the slow-writer rule once. Public for tests; the periodic
  /// timer started by [_start] is the only production caller.
  @visibleForTesting
  void checkDemotions() {
    if (!_enabled) return;
    final active = _links.values.where((l) => l.online && !l.paused).toList();
    final total = active.length + (_conn.isOnline ? 1 : 0);
    // D5 ⑥: one link online has nobody to protect.
    if (total < 2) return;
    for (final l in active) {
      final avg = l.ble.recentWriteAvgMs;
      if (avg == null || avg < MultiLinkConfig.demoteAvgMs) continue;
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
    if (!_enabled) return;
    final ids = <String>[
      if (_conn.isOnline && _conn.connectedDeviceId != null)
        _conn.connectedDeviceId!,
      ...onlineIds,
    ];
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
    _demoteTimer?.cancel();
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
