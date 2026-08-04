/// OpenSmartBatt — connection controller (mockup screens 1-3 connection flow).
///
/// Adapts [BleService] (streams + futures) into a [ChangeNotifier] the UI can
/// `watch`. Owns: scan lifecycle, the single connection, derived online state,
/// the discovered-device list, adapter state, and best-effort auto-reconnect.
///
/// SAFETY: only the documented release (mode 0x06 + auth) is proven-safe; this
/// controller exposes [releaseCutOff] for that path and a generic [switchMode]
/// the UI must gate. It never auto-sends mode codes.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show
        BluetoothAdapterState,
        ErrorPlatform,
        FbpErrorCode,
        FlutterBluePlusException;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../ble/ble.dart';
import '../data/data.dart';
import '../models/models.dart';
import '../platform/platform.dart';
import '../protocol/protocol.dart';
import 'device_controller.dart';
import 'pack_class_resolver.dart';
import 'session_context.dart';
import 'settings_controller.dart';

/// Live BLE connection + scan state for the UI.
class ConnectionController extends ChangeNotifier {
  ConnectionController(
    this._ble, {
    required SettingsController settings,
    DeviceController? devices,
    LogRepo? logs,
    SessionContext? session,
    String? appBuild,
    MonitorService? monitor,
    PendingWrites? pending,
  }) {
    _settings = settings;
    _devices = devices;
    _logs = logs;
    _pending = pending ?? PendingWrites();
    _session = session ?? SessionContext();
    _appBuild = appBuild;
    _monitor = monitor ?? NoopMonitorService();
    _linkSub = _ble.linkState.listen(_onLinkState);
    _scanSub = _ble.scanResults.listen(_onScanResults);
    _scanningSub = _ble.scanning.listen(_onScanning);
    _adapterSub = _ble.adapterState.listen(_onAdapterState);
    _telemetrySub = _ble.telemetry.listen(_onTelemetrySample);
    // FB-53: the transport's own diagnostics, straight onto the always-on
    // event path. Subscribed unconditionally — see [_onDiagnostic].
    _diagnosticsSub = _ble.diagnostics.listen(_onDiagnostic);
    _monitorStopSub = _monitor.onStopRequested.listen((_) => _onMonitorStop());
    _settings.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    _updateWakelock();
    _updateMonitor();
  }

  /// Keep the screen awake while connected, when the user enabled the option.
  /// Re-evaluated on link state changes and whenever the setting toggles.
  ///
  /// Note this is only about the *display*. Background execution is
  /// [_updateMonitor]'s job. The two used to share a single setting named for
  /// background keep-alive that in fact did nothing but hold the screen on —
  /// the name promised something no line of code delivered. They are separate
  /// settings now because they cost the user different things (battery vs a lit
  /// screen) and only one of them actually keeps telemetry flowing.
  void _updateWakelock() {
    final shouldKeep = isOnline && _settings.keepScreenAwake;
    // Fire-and-forget; ignore platform errors (e.g. in unit tests / unsupported
    // platforms where the plugin channel is absent).
    WakelockPlus.toggle(enable: shouldKeep).catchError((_) {});
  }

  /// Start/stop the foreground service that keeps this process at foreground
  /// importance while connected. Without it the OS freezes the process once the
  /// screen goes off and the 1 Hz keep-alive stops firing — the GATT link stays
  /// up throughout, so nothing reports a disconnect and the readings simply
  /// stop, then arrive as a backlog burst when the process thaws.
  void _updateMonitor() {
    final shouldRun = isOnline && _settings.backgroundMonitoring;
    if (shouldRun == _monitorRunning) return;
    _monitorRunning = shouldRun;
    if (shouldRun) {
      _lastNotifyAt = null;
      unawaited(_startMonitor());
    } else {
      unawaited(_monitor.stop());
    }
  }

  Future<void> _startMonitor() async {
    // Ask for POST_NOTIFICATIONS (Android 13+) but do NOT gate on the answer.
    // A denied prompt hides the notification; the service — and therefore the
    // BLE loop — still runs. Treating it as a prerequisite would hand us a
    // "user declined notifications, background monitoring silently dead" bug.
    await _ble.ensureNotificationPermission();
    if (!_monitorRunning) return; // toggled off while the prompt was up
    await _monitor.start(_buildNotification());
  }

  /// User tapped "stop" on the ongoing notification (or the system reclaimed
  /// the service). Drop the link rather than leaving it running invisibly.
  void _onMonitorStop() {
    if (!_monitorRunning) return;
    _monitorRunning = false;
    if (isOnline) unawaited(disconnect());
  }

  MonitorNotification _buildNotification() => MonitorNotification(
        title: _notifyTitle,
        body: _notifyBody,
        stopLabel: _notifyStopLabel,
        channelName: _notifyChannelName,
        channelDescription: _notifyChannelDescription,
      );

  /// Hand the localized, non-numeric notification strings to the controller.
  ///
  /// Called once when the locale resolves (and again if the user switches
  /// language) — NOT per telemetry sample. The live reading is formatted from
  /// the samples this controller already receives, so the UI never has to push
  /// a notification update from a build method.
  void setNotificationStrings({
    required String title,
    required String stopLabel,
    required String channelName,
    required String channelDescription,
  }) {
    if (title == _notifyTitle &&
        stopLabel == _notifyStopLabel &&
        channelName == _notifyChannelName &&
        channelDescription == _notifyChannelDescription) {
      return;
    }
    _notifyTitle = title;
    _notifyStopLabel = stopLabel;
    _notifyChannelName = channelName;
    _notifyChannelDescription = channelDescription;
    // Push straight through (bypassing the throttle): a language change is
    // rare and the user is looking at the result right now.
    if (_monitorRunning) unawaited(_monitor.update(_buildNotification()));
  }

  /// Refresh the ongoing notification's reading line.
  ///
  /// THROTTLED to [notificationInterval]: telemetry is 1 Hz, but posting a
  /// notification that often is a measurable battery cost and the system
  /// rate-limits it anyway, so the extra posts would be dropped regardless.
  void _updateNotificationBody(TelemetrySample s) {
    if (!_monitorRunning) return;
    final body = formatMonitorBody(s);
    if (body == _notifyBody && _lastNotifyAt != null) return;
    final now = DateTime.now();
    final last = _lastNotifyAt;
    if (last != null && now.difference(last) < notificationInterval) return;
    _notifyBody = body;
    _lastNotifyAt = now;
    unawaited(_monitor.update(_buildNotification()));
  }

  /// Minimum gap between ongoing-notification updates.
  static const Duration notificationInterval = Duration(seconds: 5);

  final BleService _ble;
  late final MonitorService _monitor;
  bool _monitorRunning = false;
  DateTime? _lastNotifyAt;
  String _notifyTitle = 'OpenSmartBatt';
  String _notifyBody = '';
  String _notifyStopLabel = '';
  String _notifyChannelName = '';
  String _notifyChannelDescription = '';

  /// True while the background monitor is engaged.
  ///
  /// ⚠️ This is NOT "a foreground service is running". It tracks the SETTING
  /// plus the link, with no platform check, while [MonitorService.forPlatform]
  /// hands every non-Android platform a no-op implementation — so on iOS this
  /// reads true with nothing behind it. The stale banner used to branch on it
  /// and consequently told iOS users to go and change an Android battery
  /// setting; it no longer does, and no UI branches on this today. Do not
  /// reintroduce one without adding the platform check this flag lacks.
  bool get monitorRunning => _monitorRunning;
  late final SettingsController _settings;
  late final DeviceController? _devices;

  /// In-flight log/device writes, so teardown can wait for them before the
  /// database closes. See [PendingWrites] for the race this closes.
  late final PendingWrites _pending;

  /// The tracker, so a composition root can drain it (see `AppServices`).
  PendingWrites get pendingWrites => _pending;
  LogRepo? _logs;
  late final SessionContext _session;

  /// Which unit/connection recorded rows are attributed to — the `device_id` /
  /// `session_id` pair stamped on every diagnostic-log and history row so an
  /// export can be scoped to one unit. Shared with [TelemetryController]
  /// (rather than each deriving its own) so the two can never disagree about
  /// whose data a row is.
  SessionContext get session => _session;

  /// Record a connection/scan/error event to the diagnostic log (always on —
  /// these are cheap and are what users export when something fails).
  ///
  /// Scan-time events legitimately carry a null device id (no connection yet);
  /// they stay unattributed rather than being filed under the previous unit.
  /// [deviceId] overrides the session's attribution for lines that name a
  /// target before any session exists — `connect → X` and its failures. It does
  /// NOT open a session: the attempt has not started, and `sessionId` staying
  /// null says so honestly.
  ///
  /// 🔴 That last sentence was FALSE from `93e967a` (shipped in v0.6.12) until
  /// this fix. The override was applied to `deviceId` alone while
  /// `sessionId` kept reading `_session.sessionId` — and the case the override
  /// exists for is precisely the one where a session IS live: [connect] writes
  /// `connect → X` BEFORE tearing the previous link down, so while unit Y was
  /// connected the row went out as `device_id=X, session_id=<Y's session>`.
  ///
  /// `LogRepo.exportLog` sections on deviceId/sessionId/appBuild, so that single
  /// row minted a one-line section header claiming Y's connection number for X,
  /// and in an all-devices export the same session number appeared under two
  /// different device headings — the sort of thing a reader resolves by assuming
  /// the file is wrong about something else.
  ///
  /// The session id may only travel with a row that belongs to that session, so
  /// an override naming a DIFFERENT unit drops it. An override naming the unit
  /// already being recorded (a reconnect to the live device) keeps it: there the
  /// session really is that row's own.
  void _event(String message, {String? deviceId}) {
    final logs = _logs;
    if (logs == null) return;
    final foreign = deviceId != null && deviceId != _session.deviceId;
    _pending.add(logs.insertLog(
      LogEntry.event(
        message,
        deviceId: deviceId ?? _session.deviceId,
        sessionId: foreign ? null : _session.sessionId,
        appBuild: _appBuild,
      ),
      maxBytes: _settings.logMaxBytes,
    ));
  }

  /// Build that is RECORDING, stamped on every row.
  ///
  /// Per row, not per export: `diag_log` and `history` accumulate for months
  /// and get trimmed oldest-first, so a version recorded once at the start of a
  /// session would be the first thing deleted. The export preamble only knows
  /// which build pressed "export", which cannot answer the question that
  /// actually comes up — whether a missing register means the hardware does not
  /// send it or that the build which recorded it had a bug.
  ///
  /// Null in tests and on hosts where the plugin channel is unavailable.
  String? _appBuild;

  StreamSubscription<BleLinkState>? _linkSub;
  StreamSubscription<List<DiscoveredDevice>>? _scanSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<TelemetrySample>? _telemetrySub;
  StreamSubscription<String>? _diagnosticsSub;
  StreamSubscription<void>? _monitorStopSub;

  /// Forward one [BleService.diagnostics] line to the diagnostic log.
  ///
  /// Always on, deliberately, on the precedent of [_logUnrecognisedDeviceType]:
  /// the raw-packet log is off by default, and a capture that arrives with it
  /// off is precisely the one where these lines are the only account of what
  /// the transport did. The volume is a handful of lines per connection.
  void _onDiagnostic(String line) => _event(line);

  /// Product-class resolver. Reads the class off the wire device-type byte;
  /// holds the user's choice only for unrecognised bytes. It never guesses from
  /// telemetry — all three classes have a wire-verified byte, so the expected
  /// value of guessing is nil while the cost of guessing wrong is offering the
  /// wrong controls.
  final PackClassResolver _packResolver = PackClassResolver();
  ProductClass _packLabel = ProductClass.unknown;

  /// The class stored for [_desiredDeviceId], restored the moment we start
  /// connecting so routing has an answer before the device-type byte can
  /// possibly arrive (FB-43). Deliberately NOT held in [PackClassResolver]:
  /// that resolver resets on every disconnect, and the window this exists to
  /// cover is precisely the connect/disconnect churn of a retrying link.
  /// Cleared only when the target changes or the user disconnects.
  ProductClass _seedClass = ProductClass.unknown;

  /// Where [_seedClass] came from, for the `class-resolve:` diagnostic line.
  /// `none` / `saved` (looked up by id) / `explicit` (passed by
  /// [connectToSaved], which knows the record even when the id rebound).
  String _seedSource = 'none';

  /// When the link last reached `ready`, and whether the class-resolve line has
  /// already been emitted for this connection. Together they time `ready` →
  /// first device-type byte.
  ///
  /// `ready` is the RIGHT zero point and the only defensible one for
  /// [kClassPendingTimeout] / [kClassPendingGrace], because the placeholder is
  /// not mounted before `ready` at all — the dashboard shows the disconnected
  /// state until then. A threshold derived from an earlier anchor (say, from
  /// the user's tap on connect) would fold in connect/retry churn and end up
  /// too large to ever fire.
  ///
  /// It is also NOT the whole of what the user waits through, and this line
  /// must not be read as if it were: on a retrying link the connect phase
  /// dominates the wait by an order of magnitude, and that is a different
  /// problem with a different fix.
  DateTime? _readyAt;
  bool _classResolveLogged = false;

  /// True from `connecting` until the matching `disconnected` has been
  /// accounted for. It is what lets a failed attempt be measured: `_readyAt`
  /// cannot serve, because the attempts worth counting are exactly the ones
  /// that never set it.
  bool _attemptInFlight = false;

  BleLinkState _link = BleLinkState.disconnected;
  List<DiscoveredDevice> _scanResults = const [];
  bool _scanning = false;
  BluetoothAdapterState _adapter = BluetoothAdapterState.unknown;

  String? _desiredDeviceId; // device we want to stay connected to
  bool _manualDisconnect = false;
  Timer? _reconnectTimer;

  /// Deadline on an armed autoConnect (FB-53 / [autoConnectWatchdog]).
  Timer? _autoConnectTimer;

  /// True once the watchdog has given up on an armed autoConnect, until the
  /// user asks for something new.
  ///
  /// Giving up means dropping the link, and dropping the link emits
  /// `disconnected` — which is the event that starts the backoff ladder.
  /// Without this flag the act of giving up would immediately start trying
  /// again, which is the opposite of what it was for.
  bool _autoConnectGaveUp = false;
  String? _lastError;
  bool _wantScan = false; // user asked to scan; re-fire when adapter turns on
  int _reconnectAttempts = 0;

  /// Cap on consecutive auto-reconnect attempts before giving up (D.4). Without
  /// a cap a stale iOS NSUUID would re-arm forever; capping lets the error
  /// surface within seconds instead of an endless reconnect loop.
  static const int maxReconnectAttempts = 5;

  /// How long an armed OS-level autoConnect may stay pending before this app
  /// stops waiting for it.
  ///
  /// FB-53. [_armAutoConnect] hands a dropped healthy link to CoreBluetooth and
  /// returns; from that moment nothing in this app had a deadline. That was
  /// survivable only by accident — the phantom `disconnected` the plugin
  /// replayed into the fresh subscription tore the pending connect down within
  /// a millisecond, so the bug was also the terminator. With that value now
  /// correctly ignored, an autoConnect to a peripheral that never comes back
  /// would wait forever behind a UI that says "connecting…" and a log that says
  /// nothing at all.
  ///
  /// 180 s, and both constraints are stated rather than tuned. It must be
  /// LONGER than the app-level ladder it is preferred over — 2+4+8+16+30 s = 60 s
  /// — or the seamless path would give up sooner than the path it replaced. And
  /// it must be BOUNDED: "seamless" is a promise about a device that comes back,
  /// not a licence to wait out the afternoon with no way for the user to learn
  /// that nothing is happening. Three minutes is one comfortable order above the
  /// ladder and still inside what somebody will sit through. Adjustable — no
  /// field capture measures how long a real reappearance takes, because until
  /// this fix no armed autoConnect ever survived long enough to be measured.
  static const Duration autoConnectWatchdog = Duration(seconds: 180);

  /// Consecutive connections that reached `connected` and left without ever
  /// reaching `ready`. FB-52, design 0031 §3.1.
  ///
  /// [_reconnectAttempts] cannot answer this question and should not be made to.
  /// It counts how many times the AUTO-RECONNECT LOOP has gone round, which is
  /// why [connect] resets it: a fresh manual connect is the user restating their
  /// intent, and the backoff has no business carrying over. But nothing was
  /// counting the thing the user actually experiences — how many times this
  /// device has come up and then failed to say anything.
  ///
  /// `2026.08.03/003` is the whole argument. Fourteen minutes, thirteen
  /// connections, zero `ready`, and `auto-reconnect gave up` appears **zero
  /// times** — because the user tapped connect twelve times, and between any two
  /// taps the loop only ever got to three. The cap was real and never once had
  /// the chance to fire. So this counter is deliberately NOT reset by a manual
  /// connect to the same unit.
  int _setupFailuresSinceReady = 0;

  /// Whose run [_setupFailuresSinceReady] is counting.
  ///
  /// The counter belongs to a UNIT, so the question "does a new connect reset
  /// it?" is "is this a different unit?" — and that has to be asked of
  /// something that survives a disconnect. It used to be asked of
  /// [_desiredDeviceId], which [disconnect] sets to null, so every path that
  /// goes out through `disconnect()` and back in through `connect()` compared
  /// the target against null, found them different, and zeroed the run.
  ///
  /// [reconnectCurrent] is exactly such a path, and it is what the give-up
  /// card's "try again" button calls — so design 0031 G3 ("a manual reconnect
  /// to the same unit must not wash the count out") held everywhere EXCEPT on
  /// the button built to be pressed when the count is what put the card there.
  /// Three failures, tap, three more, tap: the give-up card could be dismissed
  /// forever and the run never reach [maxSetupFailures] again.
  ///
  /// Deliberately NOT cleared by [disconnect]: a unit's run of silent
  /// connections is a fact about that unit, and the user cycling the link is
  /// not evidence it has ended. Only `ready` is (see [_onLinkState]).
  String? _setupFailuresDeviceId;

  /// Consecutive failed setups before the app stops trying and says so.
  ///
  /// Three, not one. A single `gatt setup failed` happens on healthy hardware —
  /// across the corpus 5 of 51 were rescued by the next attempt — so firing on
  /// the first would cry wolf. Three puts the honest answer in front of the user
  /// inside the first minute, against the forty they actually waited.
  ///
  /// ⚠️ Calibrated on n=51 failures. If a capture ever shows a setup succeeding
  /// on the fourth consecutive try, this number is wrong and should move.
  static const int maxSetupFailures = 3;

  /// Whether this link has connected repeatedly without ever coming up.
  ///
  /// The UI uses this to draw a failure that STAYS, and [_scheduleReconnect]
  /// uses it to stop. Spinning for another forty minutes buys nothing: the field
  /// capture ran fourteen and never once recovered on its own.
  bool get isSetupStalled => _setupFailuresSinceReady >= maxSetupFailures;

  /// How many consecutive setups have failed — shown to the user, so that
  /// "we really did try" is a number and not a claim.
  int get setupFailures => _setupFailuresSinceReady;

  /// True once this attempt got as far as `connected`. Distinguishes a setup
  /// that failed from a connect that never landed — the latter is already
  /// handled by [maxReconnectAttempts] and must not be counted twice.
  bool _reachedConnected = false;

  // ---- exposed state ----------------------------------------------------

  /// Underlying link lifecycle.
  BleLinkState get linkState => _link;

  /// True once notify is enabled + keep-alive is running (telemetry flowing).
  bool get isOnline => _link == BleLinkState.ready;

  /// True while connecting / discovering / disconnecting (UI shows a spinner).
  bool get isBusy =>
      _link == BleLinkState.connecting ||
      _link == BleLinkState.connected ||
      _link == BleLinkState.disconnecting;

  /// True when fully disconnected (dashboard shows the empty state).
  bool get isDisconnected => _link == BleLinkState.disconnected;

  /// True while an auto-reconnect attempt is SCHEDULED but not yet running —
  /// i.e. during the backoff wait between two tries.
  ///
  /// This is the gap [isBusy] cannot see. Between attempts the link really is
  /// `disconnected`, so `isBusy` is false, and a UI driven by it alone shows a
  /// spinner that stops and restarts every couple of seconds. Field logs put
  /// that gap at 2 s on the first retry and doubling from there
  /// ([reconnectBackoff]), and a capture that spent 15.7 s of a 16.2 s wait in
  /// exactly this state is what prompted exposing it: the app was working the
  /// whole time and did not look like it.
  ///
  /// Pair with [reconnectAttempts] to say WHICH attempt is pending.
  bool get isRetrying => _reconnectTimer?.isActive ?? false;

  /// How many auto-reconnect attempts have been started for the current target
  /// (0 once a link goes healthy, or after a fresh manual connect). Capped at
  /// [maxReconnectAttempts].
  int get reconnectAttempts => _reconnectAttempts;

  /// Deduped, RSSI-sorted scan results (vendor-service filtered).
  List<DiscoveredDevice> get scanResults => _scanResults;

  /// True while a scan is in progress.
  bool get isScanning => _scanning;

  /// Bluetooth radio state.
  BluetoothAdapterState get adapterState => _adapter;

  /// True if the radio is on.
  bool get isAdapterOn => _adapter == BluetoothAdapterState.on;

  /// True when BLE is unavailable because the OS-level Bluetooth *permission*
  /// was denied (iOS `CBManagerAuthorization` / Android revoke), as opposed to
  /// the radio merely being switched off. Drives the D.2 distinction: this case
  /// needs a "go to Settings" deep-link, NOT a "turn on Bluetooth" prompt.
  bool get isAdapterUnauthorized =>
      _adapter == BluetoothAdapterState.unauthorized;

  /// Remote id of the connected/connecting device, or null.
  String? get connectedDeviceId => _ble.connectedDeviceId ?? _desiredDeviceId;

  /// Advertised name of the connected device (e.g. "RCE-SCAP_II"), or ''.
  String get connectedDeviceName => _ble.connectedDeviceName;

  /// Last connection error message (cleared on a successful connect).
  String? get lastError => _lastError;

  /// Saved devices for the quick-select list (delegates to [DeviceController]).
  List<SavedDevice> get savedDevices => _devices?.devices ?? const [];

  // ---- product class / cosmetic pack label ----

  /// The DETERMINISTIC routing class: the device-type byte when we have it,
  /// else [_seedClass] — the class already stored for the device we are
  /// connecting to. Still the ONLY class allowed to pick a layout — the standing
  /// invariant is that a layout may be chosen by wire-derived facts and by
  /// nothing else — and the SINGLE source of truth shared by routing
  /// ([DashboardRouter]), persistence ([_recomputePackLabel]) and capability
  /// gating ([capabilities]).
  ///
  /// FB-43: the seed was added because the byte cannot arrive before the link is
  /// up, so a saved power bank was routed to the pack layout for the whole
  /// connect — 10 s in the 2026-07-31 report, where a stale iOS NSUUID burned 8 s
  /// before the retry that worked. The invariant survives because the seed is
  /// itself wire-derived: [setPackLabelOverride] is the only other writer of a
  /// stored class and its picker offers pack classes ONLY, so a stored
  /// [ProductClass.powerBank] can have come from nowhere but a 0x22 byte. A user
  /// GUESS therefore still cannot pick a layout — that is why the seed is kept
  /// here and not folded into [PackClassResolver.label], which does include the
  /// guess.
  ProductClass get resolvedClass {
    final fromWire = _packResolver.deviceClass;
    if (fromWire != ProductClass.unknown) return fromWire;
    return _seedClass;
  }

  /// True only for a confirmed power bank (device-type 0x22, or a stored class
  /// that can only have come from one) — the sole deterministic routing signal.
  bool get isPowerBank => resolvedClass.isPowerBank;

  /// What the dashboard should draw. Supersedes reading
  /// [isPowerBank] as a bool: that collapsed "we do not know yet" into "pack",
  /// so a power bank's single-cell voltage was rendered as a 12 V pack
  /// terminal voltage for as long as the class stayed unknown.
  RoutingDecision get routing {
    final d = RoutingDecision.from(
      resolved: resolvedClass,
      sawDeviceType: _packResolver.sawDeviceType,
    );
    // The user has looked at the placeholder and asked for the readings anyway.
    // This is NOT a class assertion — it does not name a class, and the picker
    // it hands over to still refuses to route, because a guess never picks a
    // layout. It only
    // declines the withholding, landing on the same "unclassified" pack shell
    // whose own chip says the type is unknown. The wire byte still wins the
    // instant it arrives.
    if (d.isPending && _revealUnclassified) return RoutingDecision.unclassified;
    return d;
  }

  bool _revealUnclassified = false;

  /// Whether the user has opted to see readings while the class is unresolved.
  bool get revealUnclassified => _revealUnclassified;

  /// Opt in to the unclassified pack shell (see [routing]). Reset on every new
  /// connection: the next unit may be a different class, and a choice made
  /// about one device must not silently carry to another — that is FB-25's
  /// failure mode, and this flag would reintroduce it across a rebound id.
  void showUnclassifiedAnyway() {
    if (_revealUnclassified) return;
    _revealUnclassified = true;
    _event('class-resolve: user chose to view unclassified readings');
    notifyListeners();
  }

  /// How long the class has been [RoutingDecision.pending], or null when it is
  /// not pending. The placeholder uses this both to suppress itself on a fast
  /// resolve and to escalate once it is clear the byte is not coming.
  Duration? get pendingFor {
    if (!routing.isPending) return null;
    final since = _readyAt;
    if (since == null) return null;
    return DateTime.now().difference(since);
  }

  /// Consecutive keep-alive write failures currently outstanding, 0 when the
  /// write path is healthy.
  ///
  /// This is the honest explanation for a class that never resolves. `0x10`
  /// comes back in response to the 1 Hz `#` poll (PROTOCOL.md §2); if the poll
  /// cannot be written, the answer never comes — while notifications already
  /// subscribed keep streaming, so the link looks fine and the dashboard fills
  /// with numbers (PROTOCOL.md §10.2). [BleService] has tracked this all along
  /// and only ever wrote it to the diagnostic log; this getter is what finally
  /// hands it to the UI.
  int get keepAliveFailures => _ble.keepAliveFailures;

  /// Per-class capabilities that gate the pack dashboard controls (檢測電容 /
  /// 解除斷電 / 防盜).
  ///
  /// This is GATING — soft: show or hide a button — and never routing, which is
  /// hard: pick a layout. The two are deliberately held to different standards
  /// of evidence, because they fail differently: every control gated here is
  /// read-only or auth-gated, so gating the wrong set merely shows or hides a
  /// button, whereas routing the wrong way puts a power bank's single-cell
  /// voltage on a 12 V pack gauge.
  ///
  /// All three classes come off the wire, so [packLabel] is
  /// the single input: a recognised byte gates directly, a user's choice gates
  /// an unrecognised unit, and a still-unclassified unit keeps the bounded
  /// [DeviceCapabilities.unknown] fallback (union of pack controls except
  /// anti-theft).
  DeviceCapabilities get capabilities {
    final cls = _packLabel;
    if (cls == ProductClass.unknown) return DeviceCapabilities.unknown;
    return DeviceCapabilities.fromClass(cls);
  }

  /// The unit's class: wire device-type when recognised, else the user's choice,
  /// else [ProductClass.unknown] ("unclassified").
  ProductClass get packLabel => _packLabel;

  /// True when we have no class at all and the UI should ask the user.
  /// A unit whose device-type byte we recognise is NEVER unclassified.
  bool get isUnclassified =>
      isOnline && _packLabel == ProductClass.unknown;

  /// The class whose DISPLAY MODULES are in force on screen right now (design
  /// 0034). Not a fourth class signal — a projection of the two that exist.
  ///
  /// A confirmed power bank is drawn by [PowerBankView], so it answers
  /// [ProductClass.powerBank] regardless of the cosmetic label. Everything else
  /// is drawn by the pack shell, which resolves a stray `powerBank` LABEL to
  /// the unclassified module set (see `DisplayModules.forPackShell`), and this
  /// getter reports the same thing the shell will draw rather than the raw
  /// label — otherwise the export preamble would name a set that is not on the
  /// screen it is describing.
  ProductClass get displayClass {
    if (isPowerBank) return ProductClass.powerBank;
    return _packLabel == ProductClass.powerBank
        ? ProductClass.unknown
        : _packLabel;
  }

  /// The stored layout of the unit currently connected (design 0034 Q3).
  ///
  /// [DisplayLayout.defaults] when nothing is connected, when the unit is not
  /// in the saved list, or when the stored value cannot be parsed — all three
  /// draw today's screen, so the dashboard has one path, not four.
  ///
  /// Reads through [DeviceController] and does NOT notify on its own: the
  /// writer is that controller, and a widget that must repaint when the layout
  /// changes watches it directly. Duplicating the value here would give the two
  /// notifiers a chance to disagree.
  DisplayLayout get displayLayout =>
      _devices?.layoutFor(connectedDeviceId) ?? DisplayLayout.defaults;

  /// Record an app foreground/background transition (`resumed`, `paused`, …).
  ///
  /// Written through the same attributed path as link events, so a stall reads
  /// straight off the log: `app paused` … gap … `app resumed`. Diagnosing the
  /// 2026-07-27 reports otherwise meant reconstructing that from a hole in the
  /// per-minute frame counts and the 2× backlog burst on resume.
  void logAppLifecycle(String state) => _event('app $state');

  /// The user's explicit class choice for a unit whose device-type byte we do
  /// not recognise. Pass null to clear it. Ignored (harmlessly) when the wire
  /// byte is recognised — that always wins.
  void setPackLabelOverride(ProductClass? label) {
    _packResolver.setOverride(label);
    _recomputePackLabel();
  }

  // ---- permissions / adapter -------------------------------------------

  /// Request BLE runtime permissions. Returns true when scan+connect allowed.
  Future<bool> ensurePermissions() => _ble.ensurePermissions();

  /// Query the adapter state directly (true if the radio is on).
  Future<bool> checkAdapterOn() => _ble.isAdapterOn();

  /// Deep-link to the OS app-settings page so the user can grant Bluetooth
  /// permission (D.2 — only meaningful when [isAdapterUnauthorized]).
  Future<void> openBluetoothSettings() async {
    await _ble.openBluetoothSettings();
  }

  // ---- scanning ---------------------------------------------------------

  /// Start a vendor-service-filtered scan after ensuring permissions.
  ///
  /// D.1/D.2: a failed startScan (adapter off / unauthorized) is surfaced as a
  /// real error via [lastError] instead of being swallowed, distinguishing the
  /// `bluetooth_unauthorized` (needs Settings deep-link) and `bluetooth_off`
  /// (needs the radio toggled) cases.
  Future<void> startScan(
      {Duration timeout = const Duration(seconds: 15)}) async {
    final ok = await _ble.ensurePermissions();
    if (!ok) {
      _lastError = 'permission_denied';
      _event('scan aborted: permission denied');
      notifyListeners();
      return;
    }
    _wantScan = true;
    _event('scan start');
    try {
      await _ble.startScan(timeout: timeout);
      _lastError = null;
    } on FlutterBluePlusException catch (e) {
      _lastError = _adapter == BluetoothAdapterState.unauthorized
          ? 'bluetooth_unauthorized'
          : 'bluetooth_off';
      _event('scan failed ($_lastError): ${e.description ?? e.code}');
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      _event('scan failed: $e');
      notifyListeners();
    }
  }

  /// Stop the current scan.
  Future<void> stopScan() {
    _wantScan = false;
    return _ble.stopScan();
  }

  // ---- connection -------------------------------------------------------

  /// Connect to a device by BLE id. Cancels any pending auto-reconnect, ensures
  /// permissions, and remembers the id as the auto-reconnect target.
  /// True when the radio state is KNOWN to make a connect impossible.
  ///
  /// FB-44. Deliberately NOT `s != on`: on iOS the CBCentralManager starts at
  /// `.unknown` and transitions to `.poweredOn` a few hundred ms later (D.1), so
  /// treating "not yet on" as "off" would refuse every connect made in that
  /// window — including the auto-reconnect armed at cold start, which is the
  /// path a user never taps and therefore never learns to retry. Only the two
  /// states that positively assert the radio is unusable count.
  static bool adapterBlocksConnect(BluetoothAdapterState s) =>
      s == BluetoothAdapterState.off ||
      s == BluetoothAdapterState.unauthorized;

  /// The `lastError` a blocked or failed connect deserves, given the radio
  /// state. Pure + unit-testable (the Platform gate is a parameter).
  ///
  /// FB-44: `connectToSaved` used to label ANY caught error `device_stale` on
  /// iOS. A 40-hour capture (`2026.07.31/002`) holds ten rounds of
  /// `CBManagerStatePoweredOff` reaching the user as "this device may no longer
  /// exist, pick another" — wrong advice about hardware that was sitting right
  /// there — and, worse, writing `saved connect failed (stale?)` into the
  /// diagnostic log ten times. That line is the signal we count stale NSUUIDs
  /// with, so every Bluetooth-off episode was inflating the very statistic used
  /// to justify the rebind work. A radio that is off explains the failure
  /// completely; nothing about the saved id is implicated.
  ///
  /// FB-53: [error] narrows the iOS fallback. `device_stale` used to absorb
  /// every failure the adapter state did not explain, including the commonest
  /// one of all — a unit that is simply not in range. See [fbpErrorCodeOf] for
  /// why the plugin's exception is read by type and code and never by message.
  ///
  /// FB-53: and every remaining failure gets `connect_failed` rather than null.
  /// Null used to mean "a non-iOS failure with the radio up — say nothing", and
  /// what the caller then said instead was `e.toString()`, which no screen can
  /// render. An Android GATT 133 arrives as a `FlutterBluePlusException` the
  /// plugin merely relayed (`platform: _nativeError`, `bluetooth_device.dart`
  /// :169-172), so it is deliberately NOT decoded here — and with the ladder no
  /// longer wrapping a failed first connect in a minute of "Reconnecting…", a
  /// quick-pick tap that ended that way left the dashboard showing the words it
  /// shows before anybody has tapped anything. Vague and correct beats silent;
  /// the specific instructions stay with the codes that earned them.
  ///
  /// The one null left is the deliberate one: a connect WE cancelled.
  static String? connectFailureError({
    required BluetoothAdapterState adapter,
    required bool isIOS,
    Object? error,
  }) {
    if (adapter == BluetoothAdapterState.unauthorized) {
      return 'bluetooth_unauthorized';
    }
    if (adapter == BluetoothAdapterState.off) return 'bluetooth_off';
    switch (fbpErrorCodeOf(error)) {
      // The radio went down between the preflight above and the connect. Same
      // fact, later arrival — and the adapter-state stream will catch up.
      case FbpErrorCode.adapterIsOff:
        return 'bluetooth_off';
      // The connect ran out its budget with nothing on the other end. That is
      // an out-of-range or powered-off unit, not a saved id that no longer
      // resolves: on a stale iOS NSUUID CoreBluetooth never answers either, so
      // the two used to be indistinguishable here and the more alarming label
      // won. The remedy differs — one says "walk over to it", the other says
      // "scan again" — which is the whole reason to split them.
      case FbpErrorCode.timeout:
        return 'device_unreachable';
      // WE cancelled it: the FB-53 watchdog is the first thing in this app that
      // does. Blaming the device for our own decision would be a lie. Note
      // this branch is currently unreachable in practice — `connect()` cancels
      // both the retry timer and the watchdog before touching BLE, so by the
      // time a connect can fail there is no canceller left. It exists so that
      // whoever adds the next canceller does not inherit a lie by default.
      case FbpErrorCode.connectionCanceled:
        return null;
      case _:
        break;
    }
    return isIOS ? 'device_stale' : 'connect_failed';
  }

  /// The plugin's OWN error code behind [error], or null when the failure did
  /// not originate in flutter_blue_plus's own logic.
  ///
  /// FB-53 R6. `FlutterBluePlusException.code` is two different numbers wearing
  /// one field: on the paths the plugin raises itself it is an index into
  /// [FbpErrorCode] (`utils.dart:19`, `bluetooth_device.dart:157`), and on the
  /// paths that merely relay the platform it is the native disconnect reason
  /// carrying the same small integers with entirely different meanings
  /// (`bluetooth_device.dart:169-172`, thrown with `platform: _nativeError`).
  /// Reading the code without checking `platform` first would read an Android
  /// GATT status 1 as `timeout`. The range check covers a future plugin
  /// version growing the enum past what this build knows.
  ///
  /// Typed on purpose, and FB-44 is why: the classifier it replaces matched on
  /// message text, and ten `CBManagerStatePoweredOff` episodes in one 40-hour
  /// capture were shown to the user as hardware that no longer existed. A
  /// human-readable description is not an API.
  static FbpErrorCode? fbpErrorCodeOf(Object? error) {
    if (error is! FlutterBluePlusException) return null;
    if (error.platform != ErrorPlatform.fbp) return null;
    final code = error.code;
    if (code == null || code < 0 || code >= FbpErrorCode.values.length) {
      return null;
    }
    return FbpErrorCode.values[code];
  }

  Future<void> connect(String deviceId,
      {Duration? timeout, ProductClass? seedClass}) async {
    _reconnectTimer?.cancel();
    // FB-53: a manual connect supersedes an armed autoConnect and its deadline
    // — the user has just restated, by hand, what they want to be connected to.
    _cancelAutoConnectWatchdog();
    _autoConnectGaveUp = false;
    _reconnectAttempts = 0; // fresh manual connect resets the backoff
    // FB-52: but the SETUP-failure run only resets when the target changes.
    // Tapping connect again on the same unit is the user retrying the thing
    // that just failed three times; treating it as a clean slate is exactly how
    // `2026.08.03/003` kept the give-up path out of reach for fourteen minutes.
    //
    // Compared against [_setupFailuresDeviceId] and NOT against
    // `_desiredDeviceId`: the latter is nulled by [disconnect], so on every
    // path that leaves and re-enters through it — [reconnectCurrent], i.e. the
    // give-up card's own button — the comparison was against null and always
    // said "different unit".
    if (_setupFailuresDeviceId != deviceId) {
      _setupFailuresSinceReady = 0;
      _setupFailuresDeviceId = deviceId;
    }
    _manualDisconnect = false;
    _desiredDeviceId = deviceId;
    // FB-43: seed routing NOW, not at `ready`. The pack/power-bank layout is
    // chosen while the link is still coming up, and on a stale iOS NSUUID that
    // can take ~10 s. `seedClass` covers a rebound id whose record still lives
    // under the OLD id (connectToSaved); the lookup covers everything else.
    final looked = _devices?.deviceFor(deviceId)?.productClass;
    _seedClass = seedClass ?? looked ?? ProductClass.unknown;
    _seedSource = seedClass != null
        ? 'explicit'
        : (looked != null && looked != ProductClass.unknown ? 'saved' : 'none');
    _lastError = null;
    notifyListeners();

    // The id is hashed in the TEXT but kept raw in the `deviceId` column: the
    // column is the scoping key and is hashed on its way out (`_sectionLabel`),
    // whereas the note is rendered verbatim. On Android the raw id is a MAC.
    _event('connect → ${shortDeviceHash(deviceId)}', deviceId: deviceId);
    final ok = await _ble.ensurePermissions();
    if (!ok) {
      _lastError = 'permission_denied';
      _event('connect aborted: permission denied', deviceId: deviceId);
      notifyListeners();
      return;
    }
    // FB-44: refuse before touching BLE when the radio is known to be off or
    // unauthorized. Handled here rather than by decoding the platform error it
    // would otherwise throw, because the adapter state is a typed enum this
    // controller already tracks and already uses for exactly this distinction
    // in [startScan], whereas the error is a per-platform message string
    // ('CBManagerStatePoweredOff') with no documented Android counterpart we
    // have a capture for. Returning rather than throwing matches the
    // permission branch directly above; the device sheet already shows a
    // "Bluetooth is off" note driven by [isAdapterOn].
    if (adapterBlocksConnect(_adapter)) {
      _lastError = connectFailureError(adapter: _adapter, isIOS: Platform.isIOS);
      _event('connect aborted: $_lastError', deviceId: deviceId);
      notifyListeners();
      return;
    }
    try {
      await _ble.connect(deviceId, timeout: timeout);
    } catch (e) {
      // FB-53: classify on the way out. This used to store `e.toString()`, and
      // a raw exception string is a value no screen has a branch for — so the
      // give-up card, whose "try again" button lands right back here through
      // [reconnectCurrent], erased itself the moment the retry also failed.
      // The classifier returns null for exactly one case, a connect we
      // cancelled ourselves, and there the canceller's own reason stands.
      final reason = connectFailureError(
          adapter: _adapter, isIOS: Platform.isIOS, error: e);
      if (reason != null) _lastError = reason;
      _event('connect error: $e', deviceId: deviceId);
      notifyListeners();
      rethrow;
    }
  }

  /// Drop and re-establish the current link, keeping the same target and the
  /// same routing seed.
  ///
  /// Offered by [ClassPendingView] because it is the only action that actually
  /// addresses the cause: `0x10` answers the 1 Hz `#` poll, so a class that
  /// never resolves means the poll is not getting out, and a fresh link is what
  /// clears that. Re-sending the poll would not — the poll is the thing
  /// failing, so a resend is a no-op in exactly the case that needs it. That
  /// is why no automatic re-poll was built.
  Future<void> reconnectCurrent() async {
    final target = _desiredDeviceId ?? _ble.connectedDeviceId;
    if (target == null) return;
    final seed = _seedClass == ProductClass.unknown ? null : _seedClass;
    // Straight through disconnect(), which clears _desiredDeviceId and the
    // seed; re-supply both rather than reaching around it.
    await disconnect();
    await connect(target, seedClass: seed);
  }

  /// Connect to a previously-saved device.
  ///
  /// D.3: on iOS the saved NSUUID is install-scoped and may be stale, so we
  /// rebind it to a freshly-discovered device advertising the same name before
  /// connecting. If neither the saved id nor a name match is currently visible,
  /// the connect surfaces a `device_stale` error (no infinite retry — D.4 caps
  /// the reconnect loop). Android keeps using the stable MAC unchanged.
  Future<void> connectToSaved(SavedDevice device) async {
    final targetId = rebindSavedDeviceId(
      savedId: device.id,
      savedName: device.name,
      candidates: {for (final r in _scanResults) r.id: r.name},
      useNameKey: Platform.isIOS,
    );
    if (targetId != device.id) {
      _event('rebound saved id ${shortDeviceHash(device.id)} → '
          '${shortDeviceHash(targetId)} (name=${device.name})');
    }
    try {
      await connect(targetId, seedClass: device.productClass);
    } catch (e) {
      // iOS: a failed connect to a saved record usually means the NSUUID is
      // stale — flag it so the UI can prompt a re-pick instead of spinning.
      //
      // FB-44: "usually" is doing real work in that sentence, and the code used
      // to ignore it. The same classifier the preflight uses decides here too,
      // so a failure that arrives with the radio down is never labelled stale —
      // including the residual case the preflight cannot catch, where the
      // adapter state has not caught up with the radio yet. The `(stale?)`
      // marker travels with the label rather than with the platform, because
      // that marker is what the stale-NSUUID counts are grepped from.
      //
      // FB-53: and the exception itself now gets a vote. Passing it is what
      // keeps `(stale?)` off the line — and out of the counts — for a unit that
      // was merely out of range, which the timeout says in so many words.
      //
      // A count discontinuity comes with that: on iOS a stale NSUUID ALSO
      // surfaces as this same timeout (CoreBluetooth never answers either
      // way), so out-of-range and stale are indistinguishable here and both
      // now land in `device_unreachable`. `(stale?)` therefore all but
      // vanishes from field logs at this version — a falling count means the
      // label moved, not that stale ids stopped happening.
      final reason = connectFailureError(
          adapter: _adapter, isIOS: Platform.isIOS, error: e);
      final stale = reason == 'device_stale';
      if (reason != null) _lastError = reason;
      _event('saved connect failed${stale ? ' (stale?)' : ''}: $e');
      notifyListeners();
      rethrow;
    }
  }

  /// User-initiated disconnect (suppresses auto-reconnect).
  Future<void> disconnect() async {
    _manualDisconnect = true;
    _desiredDeviceId = null;
    _seedClass = ProductClass.unknown; // no target ⇒ nothing to route for
    _reconnectTimer?.cancel();
    // FB-53: an armed autoConnect outlives its target unless someone says so.
    _cancelAutoConnectWatchdog();
    _autoConnectGaveUp = false;
    await _ble.disconnect();
  }

  // ---- commands (UI gates which modes are sent) ------------------------

  /// Raw write (Write-Without-Response).
  Future<void> writeCommand(List<int> bytes) => _ble.writeCommand(bytes);

  /// Release: mode 0x00 (normal) + auth in one 15-byte write.
  ///
  /// 🔴 **Was 0x06 until 2026-07-30.** Labelled captures of two
  /// batteries actually sitting in cut-off show eight 0x06 writes — three
  /// cb/pwSum combinations across both derivation rules, plus bare mode frames
  /// with no auth at all — and `0x23` never moved once. Every real transition in
  /// those captures happened minutes away from any write of ours.
  ///
  /// That eliminates the auth value and the auth requirement as causes and
  /// leaves the mode code. The distributor states the write encoding as
  /// 0x00 normal / 0x01 anti-theft / 0x02 cut-off, so returning to normal means
  /// writing normal.
  ///
  /// ⚠️ 0x00 is **not yet proven** to work — no capture holds a successful
  /// write. The evidence is elimination plus the vendor's own numbering, which
  /// is why callers must not report success on a write returning. They poll the
  /// device's own reported mode (0x23, which streams at roughly 1 Hz) for a few
  /// seconds afterwards and say what actually happened: changed → report the
  /// state the device now claims; unchanged → say the command went out and the
  /// device did not move. That turns every attempt into evidence, which is the
  /// only way this value gets confirmed at all.
  Future<void> releaseCutOff({required int cb, required int pwSum}) =>
      _ble.switchMode(ModeArg.unlock, cb: cb, pwSum: pwSum);

  /// Generic mode switch — caller MUST gate which [mode] codes it sends.
  Future<void> switchMode(int mode,
          {required int cb, required int pwSum}) =>
      _ble.switchMode(mode, cb: cb, pwSum: pwSum);

  /// EXPERIMENTAL — send ONLY the mode sub-frame, skipping the auth frame.
  /// Unproven: the device MAY ignore commands without auth. Provided as a
  /// car-side fallback to test whether auth is actually required.
  Future<void> switchModeOnly(int mode) =>
      writeCommand(const CommandBuilder().modeSet(mode));

  /// EXPERIMENTAL release with no auth (mode 0x00 only). See [switchModeOnly].
  Future<void> releaseCutOffModeOnly() => switchModeOnly(ModeArg.unlock);

  /// Send the `0x23` read-back/poll frame (`b8 23 01 00 9a 26`).
  ///
  /// The engineering app emits this right after every mode write (live HCI
  /// capture); a lone mode+auth write was observed to be intermittent
  /// (FB 2026.08.04/003), so [releaseCutOff] now pairs each write with this poll
  /// to match the known-good sequence (design 0036 §10).
  Future<void> pollMode() =>
      writeCommand(const CommandBuilder().modeReadBack());

  /// Standalone verify-auth (9-byte auth frame).
  Future<void> sendAuth({required int cb, required int pwSum}) =>
      _ble.sendAuth(cb: cb, pwSum: pwSum);

  /// Set warning thresholds in physical units. [trailing] null preserves the
  /// device's last-read UT byte (see [BleService.setThresholds]).
  Future<void> setThresholds({
    required double ovVolts,
    required double uvVolts,
    required double otCelsius,
    int? trailing,
  }) =>
      _ble.setThresholds(
        ovVolts: ovVolts,
        uvVolts: uvVolts,
        otCelsius: otCelsius,
        trailing: trailing,
      );

  /// Set warning thresholds from raw register bytes.
  Future<void> setThresholdsRaw(int ovByte, int uvByte, int otByte,
          {int? trailing}) =>
      _ble.setThresholdsRaw(ovByte, uvByte, otByte, trailing: trailing);

  /// Send one keep-alive byte on demand.
  Future<void> pokeKeepAlive() => _ble.pokeKeepAlive();

  // ---- stream handlers --------------------------------------------------

  /// The `class-resolve:` line — the one entry that makes class resolution
  /// measurable in a field log. Emitted once per connection ATTEMPT: on the
  /// first device-type byte, or on disconnect if none ever came.
  ///
  /// ```
  /// class-resolve: ready→0x10 412ms | seed=saved | kaFail=0 | class=0x22
  /// class-resolve: ready→0x10 never | seed=none  | kaFail=3 | class=none
  /// class-resolve: ready=never      | seed=saved | kaFail=0 | class=none
  /// ```
  ///
  /// The third form is what makes the sample honest. An attempt that never
  /// reached `ready` has no interval to state, but it is still an attempt that
  /// failed to resolve a class — and those are common in field logs. Emitting
  /// nothing for them would condition every distribution drawn from this line
  /// on the link having come up at least once, which is precisely the case
  /// where nothing went wrong.
  ///
  /// The last three fields are the point of the line: they are app-internal
  /// state with NO substitute anywhere in a field log, whereas the interval
  /// itself can also be recovered after the fact from the link and frame
  /// timestamps.
  ///
  /// * `ready→0x10` — the interval behind [kClassPendingTimeout], stated
  ///   per connection so a live build can be checked against the corpus
  ///   distribution instead of only recomputed from it.
  /// * `seed=` — how often FB-43's seed fix (`7a0965c`) actually fires. That
  ///   fix has never shipped, so its real-world hit rate is unknown.
  /// * `kaFail=` — tests the §10.2 hypothesis directly: a class that never
  ///   resolves should be accompanied by a broken write path.
  /// * `class=` — separates "no byte" from "a byte we do not recognise", which
  ///   both present as [ProductClass.unknown] and want opposite responses.
  void _logClassResolve({required int? resolvedMs}) {
    if (_classResolveLogged) return;
    // Nothing was attempted, so there is nothing to report. Without this an
    // idle `disconnected` would emit a line describing no connection at all.
    if (!_attemptInFlight) return;
    _classResolveLogged = true;
    final dt = _packResolver.observedDeviceType;
    final cls = dt == null
        ? 'none'
        : '0x${dt.toRadixString(16).padLeft(2, '0').toUpperCase()}';
    // An attempt that never reached `ready` has no interval to state, but it
    // still has to produce a line — see the note on this method's contract.
    final interval = _readyAt == null
        ? 'ready=never'
        : 'ready→0x10 ${resolvedMs == null ? 'never' : '${resolvedMs}ms'}';
    _event('class-resolve: $interval'
        ' | seed=$_seedSource'
        ' | kaFail=${_ble.keepAliveFailures}'
        ' | class=$cls');
  }

  void _onLinkState(BleLinkState s) {
    final wasOnline = _link == BleLinkState.ready;
    _link = s;
    // Open the recording session BEFORE logging this transition, so the
    // `link: ready` line itself is already attributed to the unit. The session
    // is closed further down, AFTER the disconnect line is written.
    //
    // Start at `connecting`, not at `ready`. Notifications are
    // subscribed before `setNotifyValue` returns and that call can take up to
    // its 15 s timeout, so waiting for `ready` left every frame in between
    // unattributed — 11.3 % of history rows in one field capture, plus the
    // whole connect-time block (GATT dump, property flags) that a per-device
    // export then silently dropped.
    //
    // NOT earlier than this. `connect()` writes its `connect → X` line and only
    // afterwards tears the previous link down, and packets from the OLD device
    // are still arriving during that window (20 RX lines in one capture).
    // Attributing from `connect →` would file them under X. `connecting` is
    // safe because `connect()` awaits `disconnect()` — which cancels the notify
    // subscription — before entering this state.
    if (s == BleLinkState.connecting) {
      // Each attempt is measured on its own. Resetting here rather than only at
      // `ready` is the whole point: a retry that never comes up would otherwise
      // inherit the previous attempt's "already logged" flag and stay
      // invisible, which is how the failures went missing.
      _classResolveLogged = false;
      _readyAt = null;
      _reachedConnected = false;
    }
    if (s == BleLinkState.connected) {
      _reachedConnected = true;
      // FB-53: the hand-off has delivered — the OS produced a link. Whatever
      // happens to it next (a GATT setup that stalls, a drop before `ready`)
      // is FB-51/FB-52 territory and the ladder's to answer for. A deadline
      // that survives the reunion would drop a link mid-setup in the 179 s
      // window, or fire a second give-up after the ladder already reported
      // one — pairing `autoConnect gave up` with `auto-reconnect gave up` in
      // the very logs the FB-53 acceptance counts are grepped from.
      _cancelAutoConnectWatchdog();
      // And the give-up itself is spent, not just its deadline. The flag
      // exists to stop the drop that giving up CAUSES from restarting the
      // ladder; a `connected` afterwards is the device saying the premise was
      // wrong — it did come back. Cancelling the timer alone left the flag set
      // for good in the one ordering that matters: the watchdog fires at 180 s,
      // the OS hands the connection over a moment later, and it only reaches
      // `connected` (a stalled GATT setup, FB-51/FB-52). `ready` never arrives,
      // so the clear at `ready` never runs, and from then on every drop of that
      // device is refused a reconnect by the guard below — permanently, until
      // the user connects or disconnects by hand.
      _autoConnectGaveUp = false;
    }
    if (s == BleLinkState.connecting ||
        s == BleLinkState.connected ||
        s == BleLinkState.ready) {
      // Any of the three means an attempt exists and owes a measurement line.
      // Not `connecting` alone: an OS-level autoConnect recovery can surface
      // as `ready` with no preceding transition, and that connection used to
      // produce a line — it must keep producing one.
      _attemptInFlight = true;
      // The handle we actually hold beats the target we last asked for: a
      // capture with two interleaved connects showed the two disagree.
      final id = _ble.connectedDeviceId ?? _desiredDeviceId;
      if (id != null) _session.begin(id);
    }
    // A: log WHY on a drop (flutter_blue_plus disconnect reason), cross-platform.
    if (s == BleLinkState.disconnected && _ble.lastDisconnect != null) {
      _event('link: disconnected (${_ble.lastDisconnect})');
    } else {
      _event('link: ${s.name}');
    }

    if (s == BleLinkState.ready) {
      _lastError = null;
      _reconnectAttempts = 0; // healthy link clears the backoff counter
      // FB-53: the link came up, so whatever was waiting for it can stand down
      // — including an armed autoConnect's deadline, whose whole job was to
      // notice that this never happened.
      _cancelAutoConnectWatchdog();
      _autoConnectGaveUp = false;
      // FB-52: `ready` is the ONLY thing that clears this one. Not a manual
      // connect, not a new attempt — coming up is the only evidence that the
      // run of failures has actually ended.
      _setupFailuresSinceReady = 0;
      _packResolver.markConnected(DateTime.now());
      // `ready` is the zero point for the class-resolve measurement, because
      // it is the moment the placeholder can first be shown at all.
      // Anything earlier would fold in the connect/retry churn,
      // which is a different problem (FB-25) with a different fix.
      _readyAt = DateTime.now();
      _classResolveLogged = false;
      _revealUnclassified = false; // never carries across connections
      // Stamp last-seen on the saved entry (if any). This is only the OPENING
      // stamp; [_onTelemetrySample] keeps it moving while the link lives and
      // the disconnect branch below closes it out — see [_touchLastSeen].
      final id = _ble.connectedDeviceId;
      if (id != null) {
        _touchLastSeen(id, force: true);
        // Re-seed from the saved record. [connect] already did this for the id
        // the user picked; this covers the paths that never went through it —
        // an OS-level autoConnect recovery, or a rebound id whose record we
        // could not find then. It is only a SEED: a recognised wire byte
        // overrides a stored class every time, never the other way round, which
        // is what heals a record saved wrong while the old fingerprint was
        // guessing. A stored class is consulted ONLY when the byte is absent or
        // unrecognised — that is the case where it is the user's own answer.
        final savedLabel = _devices?.deviceFor(id)?.productClass;
        if (savedLabel != null && savedLabel != ProductClass.unknown) {
          _seedClass = savedLabel;
          if (_seedSource == 'none') _seedSource = 'saved';
        }
      }
      _recomputePackLabel();
    } else if (s == BleLinkState.disconnected) {
      // Read once, up here: the field is cleared further down, and BOTH the
      // FB-52 counter and the FB-53 backoff policy have to see what this
      // attempt actually achieved.
      final reachedConnected = _reachedConnected;
      // Close out last-seen at the moment the unit stopped being reachable.
      // Without this the stored value would be the moment we CONNECTED, so a
      // device monitored for six hours would report "last seen 6 hours ago"
      // the instant it dropped.
      final gone = _lastSeenDeviceId;
      if (gone != null) _touchLastSeen(gone, force: true);
      _lastSeenDeviceId = null;
      // If the byte never arrived, say so on the way out — otherwise the
      // connections that FAILED to resolve are exactly the ones absent from
      // the measurement, and the distribution reads clean. That includes an
      // attempt that never got as far as `ready`: it reports `ready=never`
      // rather than nothing, because those are a large share of the failures
      // in field logs and dropping them conditions the whole sample on the
      // link having come up at least once.
      _logClassResolve(resolvedMs: null);
      _attemptInFlight = false;
      // FB-52: count a connection that came up and said nothing. Read `_readyAt`
      // BEFORE the line below clears it — that field is the only record that
      // this particular attempt ever reached `ready`.
      if (reachedConnected && _readyAt == null) {
        _setupFailuresSinceReady++;
        if (isSetupStalled) {
          // Cancel the retry the PREVIOUS failure already armed. Refusing to
          // schedule a new one is not enough — the backoff timer from round two
          // is still pending when round three decides to stop, so without this
          // the app fires one more attempt after telling the user it had given
          // up, and `isRetrying` keeps the spinner on top of the message.
          _reconnectTimer?.cancel();
          _lastError = 'gatt_setup_stalled';
          // A greppable line, because the copy this drives is meant to become
          // rare: if the disconnect added by FB-51 (e) works, the user stops
          // seeing the message and we lose the only way to count how often the
          // fault still happens. The log has to keep saying it.
          _event('gatt setup stalled: $_setupFailuresSinceReady consecutive '
              'connections reached `connected` but never `ready` '
              '— auto-reconnect stopped');
        }
      }
      _reachedConnected = false;
      _readyAt = null;
      // Drop the settling window + label so the next unit starts clean.
      _packResolver.reset();
      _packLabel = ProductClass.unknown;
      _loggedUnknownStatus.clear();
      // Stop attributing rows to this unit (the disconnect line above is still
      // attributed — it belongs to the connection that just ended).
      _session.end();
      // Unexpected drop while we still want this device → try to reconnect.
      //
      // FB-52 (design 0031 Q3): unless the link has already come up several
      // times and said nothing. Retrying that is not recovery, it is the
      // fourteen-minute loop the field capture recorded — and it costs battery
      // and log volume to learn nothing. The user gets a button instead.
      if (!_manualDisconnect &&
          _settings.autoReconnect &&
          !isSetupStalled &&
          !_autoConnectGaveUp &&
          _desiredDeviceId != null) {
        if (wasOnline && Platform.isIOS) {
          // B: iOS hands a dropped HEALTHY link to CoreBluetooth autoConnect for
          // seamless OS-level recovery (no app-level backoff loop). A failed
          // *initial* connect (not wasOnline) still uses the capped backoff path
          // so a stale NSUUID surfaces fast (D.4).
          _armAutoConnect();
        } else if (reachedConnected || _reconnectAttempts > 0) {
          // FB-53: the ladder serves connections that EXISTED. A manual connect
          // that never once reached `connected` has failed at the first step,
          // and the exception path has already put a real reason in
          // `lastError`; wrapping that in 2+4+8+16+30 s of "Reconnecting…
          // (attempt N of 5)" replaces an honest answer in seconds with a
          // wrong-sounding one after a minute and a half. The out-of-range
          // device in `2026.08.03/004` is the case: today ~8 s to a message,
          // and with the reducer fix but no policy change it would have been
          // 108 s.
          //
          // The second term keeps a ladder ALREADY under way moving: a rung
          // that fails also never reaches `connected`, and stopping there would
          // strand the retry sequence after its first attempt.
          _scheduleReconnect();
        }
      }
    }
    _updateWakelock();
    _updateMonitor();
    notifyListeners();
  }

  /// B (iOS): hand reconnection of a dropped healthy link to CoreBluetooth.
  /// `connect(autoConnect: true)` registers a pending connection that the OS
  /// re-establishes the moment the peripheral reappears — seamless, no backoff
  /// loop. Returns immediately; the connectionState stream drives setup.
  void _armAutoConnect() {
    _reconnectTimer?.cancel();
    final id = _desiredDeviceId;
    if (id == null) return;
    _autoConnectGaveUp = false;
    _event('auto-reconnect: autoConnect armed (iOS)');
    // FB-53: and give it a deadline. See [autoConnectWatchdog] for why an
    // unbounded hand-off only looked safe while the phantom disconnect was
    // silently ending it.
    _autoConnectTimer?.cancel();
    _autoConnectTimer =
        Timer(autoConnectWatchdog, () => _onAutoConnectExpired(id));
    unawaited(_ble.connect(id, autoConnect: true)
        .catchError((Object e) => _onArmAutoConnectFailed(id, e)));
  }

  /// The hand-off could not even be armed.
  ///
  /// This used to be `.catchError((Object _) {})` — swallowed whole. The cost
  /// was 180 s of a blank screen: `_ble.connect` throwing means its own
  /// teardown emits `disconnected`, and by the time that event reaches
  /// [_onLinkState] the R3 condition is false on BOTH terms — `_reachedConnected`
  /// was cleared by the drop that got us here, and `_reconnectAttempts` is 0
  /// because the hand-off path never touches the ladder. So nothing was
  /// scheduled, nothing was recorded, and the only thing left with an opinion
  /// was a watchdog waiting on a connect that was never registered.
  ///
  /// POLICY: fall back to the ordinary backoff ladder rather than giving up on
  /// the spot. [_armAutoConnect] is reached only from `wasOnline && isIOS` — a
  /// link that was healthy and dropped — which is exactly the population R3
  /// reserves the ladder for, and the population the ladder served on every
  /// other platform all along. The hand-off is PREFERRED over the ladder (see
  /// [autoConnectWatchdog]); a hand-off that does not exist is not something to
  /// prefer. Giving up immediately would make an iOS device the only one that
  /// gets no recovery attempt at all after a drop, on the strength of an error
  /// raised before any attempt was made.
  ///
  /// The watchdog goes first, unconditionally: it is a deadline on a pending
  /// connect, and there is no pending connect. Leaving it armed would fire
  /// `autoconnect_timeout` three minutes into a ladder that has long since
  /// finished, and drop whatever link the ladder had by then established.
  void _onArmAutoConnectFailed(String id, Object error) {
    _cancelAutoConnectWatchdog();
    // Classify before anything else can overwrite it. A radio that went down
    // between the drop and this call explains everything and the ladder is
    // about to fail five times for that one reason; naming it now means the
    // give-up card at the end of the ladder has something true to show.
    final reason =
        connectFailureError(adapter: _adapter, isIOS: Platform.isIOS, error: error);
    if (reason != null) _lastError = reason;
    _event('auto-reconnect: autoConnect could not be armed '
        '(${reason ?? 'cancelled'}) — falling back to the backoff ladder: $error');
    // The same guards the call site applies, re-read: this runs a microtask
    // later and the user may have moved on.
    if (!_manualDisconnect &&
        _settings.autoReconnect &&
        !isSetupStalled &&
        !_autoConnectGaveUp &&
        _desiredDeviceId == id) {
      _scheduleReconnect();
    }
    notifyListeners();
  }

  /// Expose the iOS hand-off to tests.
  ///
  /// The only caller is gated on `Platform.isIOS`, which is false on every test
  /// host, so without this the watchdog — the one thing standing between an
  /// armed autoConnect and a permanently silent "connecting…" — could not be
  /// exercised at all.
  @visibleForTesting
  void armAutoConnect() => _armAutoConnect();

  /// The armed autoConnect ran out of time (FB-53 / [autoConnectWatchdog]).
  void _onAutoConnectExpired(String id) {
    // Anything that made this stale answers for itself: the link came up, the
    // user disconnected, or the user pointed at a different unit.
    if (isOnline || _manualDisconnect || _desiredDeviceId != id) return;
    // Set BEFORE dropping the link: the drop below emits `disconnected`, and
    // that is the event that starts the backoff ladder. Giving up must not be
    // the thing that starts trying again.
    _autoConnectGaveUp = true;
    // Its own code, not the ladder's. `reconnect_exhausted` is a count — "five
    // attempts went by without a connection", which is what
    // `disconnectedGaveUpBody` then says on screen. This is one 180 s hand-off
    // to the OS: no attempt of ours was made, none was counted, and reporting
    // it as several would be a claim about work nobody did. It also collapsed
    // two different diagnoses into one string in the field logs — the ladder
    // exhausting says the device refused five connects, the watchdog expiring
    // says the device never advertised at all.
    _lastError = 'autoconnect_timeout';
    _event('auto-reconnect: autoConnect gave up after '
        '${autoConnectWatchdog.inSeconds}s with no `ready` — pending connect '
        'cancelled');
    // The first place in this app that actually CANCELS a connect. Everywhere
    // else an abandoned `device.connect()` is simply forgotten: teardown nulls
    // the handle, so the `disconnect()` at the head of the next `connect()`
    // returns early and the old attempt stays in flight inside the plugin.
    // Two of them landing a millisecond apart is on record
    // (`2026-08-01T11:39:36.517/.519`, fbp-code 1 and 10).
    unawaited(_ble.disconnect().catchError((Object _) {}));
    notifyListeners();
  }

  void _cancelAutoConnectWatchdog() {
    _autoConnectTimer?.cancel();
    _autoConnectTimer = null;
  }

  void _scheduleReconnect() {
    // FB-53: idempotent. A failed rung used to schedule the next one from TWO
    // places — here, reached via the `disconnected` the failure emits, and the
    // timer callback's own `catch` — so one failure burned two rungs. Worse,
    // the second call arrived while the first had already armed the timer and
    // the old first line of this method was `_reconnectTimer?.cancel()`: the
    // reschedule silently killed the retry it was supposed to be adding.
    // `2026.08.03/004` has the ladder dying at rung 3 twice (20:33:14.28,
    // 20:33:49.95) and no `auto-reconnect gave up` line in either 08-03
    // episode — the file's only three are 08-01 rolling residue — while the
    // user was told "attempt 3 of 5".
    //
    // Returning rather than re-arming is the right way round: a pending retry
    // is already the answer to "come back later", and the caller that wants an
    // EARLIER one does not exist.
    if (_reconnectTimer?.isActive ?? false) return;
    final id = _desiredDeviceId;
    if (id == null) return;
    // D.4: cap the auto-reconnect loop. A stale (iOS) id never resolves, so an
    // uncapped loop would re-arm forever; after [maxReconnectAttempts] we give
    // up and surface a real error within seconds.
    if (_reconnectAttempts >= maxReconnectAttempts) {
      // The final failure reaches here TWICE — once via the `disconnected` it
      // emits, once via the timer callback's own catch — and unlike a mid-run
      // rung there is no armed timer for the guard above to see. One episode,
      // one line: `ready` and a manual connect are the only things that clear
      // `reconnect_exhausted`, so within an episode the sentinel is exact.
      if (_lastError != 'reconnect_exhausted') {
        _lastError = 'reconnect_exhausted';
        _event('auto-reconnect gave up after $_reconnectAttempts attempts '
            '(stale device?)');
        notifyListeners();
      }
      return;
    }
    final delay = reconnectBackoff(_reconnectAttempts);
    _reconnectAttempts++;
    _reconnectTimer = Timer(delay, () async {
      if (_manualDisconnect ||
          !_settings.autoReconnect ||
          _desiredDeviceId != id ||
          _link != BleLinkState.disconnected) {
        return;
      }
      try {
        await _ble.connect(id);
      } catch (_) {
        // Will surface another disconnected event; back off by rescheduling
        // (capped + exponentially delayed above).
        if (!_manualDisconnect && _settings.autoReconnect) {
          _scheduleReconnect();
        }
      }
    });
  }

  /// Status bytes already reported this connection, so an unrecognised one is
  /// logged once rather than every second.
  final Set<int> _loggedUnknownStatus = <int>{};

  void _onTelemetrySample(TelemetrySample s) {
    final sawBefore = _packResolver.sawDeviceType;
    _packResolver.observe(s);
    // The class-resolve line fires on the FIRST device-type byte of the
    // connection, and only then.
    if (!sawBefore && _packResolver.sawDeviceType) {
      _logUnrecognisedDeviceType();
      final since = _readyAt;
      _logClassResolve(
        resolvedMs:
            since == null ? null : DateTime.now().difference(since).inMilliseconds,
      );
    }
    _recomputePackLabel();
    _updateNotificationBody(s);
    _logUnknownCapacitorStatus(s);
    // Every frame proves the unit is still alive, so last-seen advances with
    // the data rather than sitting at the connect time.
    final id = _ble.connectedDeviceId;
    if (id != null) _touchLastSeen(id);
  }

  /// Name a device-type byte this build does not map, the moment it arrives.
  ///
  /// The class is read off the wire and never inferred, so a byte nobody has
  /// captured yet routes to "unclassified" by design. The cost is that we only
  /// find out a new generation exists when an owner describes the screen. That
  /// is how 0x18 was found: three units of a super-capacitor generation had
  /// been answering it for weeks, and what surfaced it was a person saying
  /// their capacitor was being offered 解除斷電.
  ///
  /// The disconnect-time `class-resolve:` line already carries the byte, but it
  /// renders `class=0x19` exactly like `class=0x17` — a reader has to know the
  /// mapped set by heart to spot which one is news. This says it in words, at
  /// the moment it happens, so a text search over any exported log finds it.
  ///
  /// On the always-on event path, deliberately: the raw-packet log is OFF by
  /// default and a capture that arrived with it off is precisely how one of
  /// these units produced zero decodable frames. Fires once per connection —
  /// it hangs off the first device-type byte, same trigger as `class-resolve:`.
  void _logUnrecognisedDeviceType() {
    final dt = _packResolver.observedDeviceType;
    if (dt == null) return;
    if (ProductClass.fromDeviceType(dt) != ProductClass.unknown) return;
    final hex = '0x${dt.toRadixString(16).toUpperCase().padLeft(2, '0')}';
    _event('device-type byte not recognised: $hex '
        '— shown as unclassified; this build maps '
        '0x02 (battery), 0x17/0x18 (capacitor), 0x22 (power bank)');
  }

  /// Record an unrecognised capacitor status byte to the diagnostic log.
  ///
  /// The dashboard deliberately shows plain language and NOT the raw byte (the
  /// app's readers are vehicle owners, not reverse engineers). But that byte is
  /// still the only lead we have on capacitor fault codes, so it has to survive
  /// somewhere — and it cannot rely on the raw-packet log, which is OFF by
  /// default. This uses the always-on event path instead, so the value reaches
  /// us from any user who exports a log.
  ///
  /// Logged once per distinct value per connection: the frame repeats every
  /// second and a flood would push the useful lines out of the 5 MB budget.
  void _logUnknownCapacitorStatus(TelemetrySample s) {
    if (_packLabel != ProductClass.supercapacitor) return;
    final mode = s.mode;
    if (mode == null || mode == CapacitorStatus.healthy) return;
    if (!_loggedUnknownStatus.add(mode)) return;
    _event('capacitor status byte not recognised: 0x'
        '${mode.toRadixString(16).toUpperCase().padLeft(2, '0')} '
        '(known healthy = 0x'
        '${CapacitorStatus.healthy.toRadixString(16).toUpperCase().padLeft(2, '0')})');
  }

  /// How often a live connection rewrites `last_seen`.
  ///
  /// Telemetry arrives at ~5 Hz; writing every frame would be ~18,000 DB
  /// updates an hour for a field that is only ever rendered as "x minutes ago".
  /// One minute is finer than the coarsest bucket that display uses.
  static const Duration lastSeenInterval = Duration(minutes: 1);

  DateTime? _lastSeenWrittenAt;
  String? _lastSeenDeviceId;

  /// Advance the saved unit's `last_seen`, at most once per
  /// [lastSeenInterval] unless [force]. The forced calls are the two that must
  /// not be dropped: the opening stamp, and the final one at disconnect.
  void _touchLastSeen(String id, {bool force = false}) {
    final now = DateTime.now();
    final last = _lastSeenWrittenAt;
    if (!force &&
        id == _lastSeenDeviceId &&
        last != null &&
        now.difference(last) < lastSeenInterval) {
      return;
    }
    _lastSeenWrittenAt = now;
    _lastSeenDeviceId = id;
    final touch = _devices?.touch(id, lastSeen: now);
    if (touch != null) _pending.add(touch);
  }

  /// Recompute the cosmetic pack label; notify + persist only on a real change
  /// (the settling window and fingerprint each flip at most once per session).
  void _recomputePackLabel() {
    // Wire byte, else the user's choice, else the saved-record seed. The seed
    // ranks LAST here on purpose: an explicit choice the user just made about
    // the unit in front of them beats a class we restored from storage.
    var next = _packResolver.label;
    final fromResolver = next != ProductClass.unknown;
    if (!fromResolver) next = _seedClass;
    if (next == _packLabel) return;
    _packLabel = next;
    // Persist the class onto the saved record, so the next connect to this unit
    // can route before its device-type byte has had time to arrive. This write
    // is also the SELF-HEAL: a unit stored as the wrong class back when the
    // fingerprint was guessing gets corrected the moment its wire byte arrives
    // — the user does not have to fix it by hand.
    //
    // Guarded on [fromResolver]: a label that came from the seed came out of
    // this very record, so writing it back is a pointless round-trip, and on a
    // REBOUND iOS id it would be worse than pointless — it would stamp one
    // device's class onto another's row (FB-25's failure mode, from the other
    // direction).
    if (fromResolver && next != ProductClass.unknown) {
      final id = _ble.connectedDeviceId;
      if (id != null) {
        final write = _devices?.setProductClass(id, next);
        if (write != null) _pending.add(write);
      }
    }
    notifyListeners();
  }

  void _onScanResults(List<DiscoveredDevice> results) {
    _scanResults = results;
    notifyListeners();
  }

  /// Record a capture state mark — the user declaring into the log what they
  /// just did to the hardware ("Type-C plugged in", "charging now").
  ///
  /// The log records what the device said; without this it records nothing
  /// about what was happening to it, and several byte→meaning questions have no
  /// second channel to check against, so they cannot be settled by more passive
  /// captures however many arrive. The code is a fixed ASCII token precisely so
  /// a hundred different reporters produce something a tool can compare.
  ///
  /// Writes through the always-on event path, the same one `link: ready` uses,
  /// so a mark cannot be lost to `rawPacketLog` being off. The UI only offers
  /// marking while raw logging is on — a mark with no packets beside it has
  /// nothing to correlate against — but if one is somehow requested anyway,
  /// silently discarding it would be the worst outcome: the user would believe
  /// their ground truth was recorded when it was not, and mislabelled ground
  /// truth is worse than none.
  void markCaptureState(CaptureMark mark, String label, {String? note}) {
    _event(mark.logLine(label, note: note));
  }

  /// Close a marked interval, so the analysis side gets a span rather than a
  /// start — without an end mark the next mark is the only bound, and a
  /// capture that simply stops leaves the last state running forever.
  void markCaptureEnd(CaptureMark mark) => _event(mark.endLogLine());

  /// Record that a guided step was deliberately passed over. Distinct from an
  /// absent mark: only one of the two is a reason to ask for a re-capture.
  void markCaptureSkipped(CaptureMark mark) =>
      _event(CaptureMark.skippedLogLine(mark));

  /// Cap on scan-roster lines per scan. A crowded site is real — one field
  /// capture saw 31 peripherals in a single pass — but the log budget is
  /// shared with telemetry, so the roster is bounded rather than unbounded.
  static const int kScanRosterLogLimit = 40;

  void _onScanning(bool scanning) {
    if (_scanning == scanning) return;
    _scanning = scanning;
    if (!scanning) {
      _event('scan done: ${_scanResults.length} device(s)');
      // The roster is written BEFORE any UI filtering, which is the whole
      // point — it has to contain the entries the list hides. Without
      // it, "I cannot find my device" is unanswerable: we cannot tell a
      // radio-level miss from a filter-level hide, and those need opposite
      // fixes. Logged in the controller, not BleService, because `_scanResults`
      // is already the de-duplicated final list here.
      // The roster is the ONE place that logs units the user does not own —
      // every nearby advertiser lands here, so on Android it would publish
      // bystanders' MACs into a file the user mails out. The hash keeps what
      // the roster is for: "same unit → same fragment" still correlates a scan
      // hit with the `connect →` line that follows it, and the diagnostic value
      // for FB-24 sits in name/rssi/vendor, not in the id.
      for (final r in _scanResults.take(kScanRosterLogLimit)) {
        _event("scan hit id=${shortDeviceHash(r.id)} name='${r.name}' "
            'rssi=${r.rssi} vendor=${r.isVendor}');
      }
      if (_scanResults.length > kScanRosterLogLimit) {
        _event('scan roster truncated at $kScanRosterLogLimit of '
            '${_scanResults.length} — say so rather than let the file imply '
            'the scan found only that many');
      }
    }
    notifyListeners();
  }

  void _onAdapterState(BluetoothAdapterState s) {
    final prev = _adapter;
    if (prev == s) return;
    _adapter = s;
    // D.2: when the radio / permission resolves to ON after having been
    // not-yet-on (iOS `.unknown`/`.unauthorized`/`.notDetermined` → `.on`, or
    // the user toggled the radio), automatically re-fire a scan the user had
    // asked for so they don't have to tap rescan again.
    if (s == BluetoothAdapterState.on &&
        prev != BluetoothAdapterState.on &&
        _wantScan &&
        !_scanning) {
      unawaited(startScan());
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    WakelockPlus.toggle(enable: false).catchError((_) {});
    // Never leave an ongoing notification behind claiming we are monitoring.
    if (_monitorRunning) {
      _monitorRunning = false;
      unawaited(_monitor.stop());
    }
    _reconnectTimer?.cancel();
    _cancelAutoConnectWatchdog();
    _linkSub?.cancel();
    _diagnosticsSub?.cancel();
    _scanSub?.cancel();
    _scanningSub?.cancel();
    _adapterSub?.cancel();
    _telemetrySub?.cancel();
    _monitorStopSub?.cancel();
    _monitor.dispose();
    super.dispose();
  }
}

/// Reading line for the ongoing monitor notification. Pure + unit-testable.
///
/// Units only (V / % / °C), no translated words, so it needs no l10n and stays
/// correct in any language. Absent fields are dropped rather than shown as a
/// placeholder — a capacitor sends no SOC, and "—%" reads as a fault.
String formatMonitorBody(TelemetrySample s) {
  final parts = <String>[
    if (s.pvlt != null) '${s.pvlt!.toStringAsFixed(1)} V',
    if (s.socPercent != null) '${s.socPercent}%',
    if (s.temperatureC != null) '${s.temperatureC}°C',
  ];
  return parts.join(' · ');
}

/// Exponential auto-reconnect backoff (D.4). Pure + unit-testable.
///
/// Returns `base * 2^attempt`, clamped to [cap]. `attempt` is the zero-based
/// retry index (0 → base, 1 → 2×base, …). Negative inputs are treated as 0.
Duration reconnectBackoff(
  int attempt, {
  Duration base = const Duration(seconds: 2),
  Duration cap = const Duration(seconds: 30),
}) {
  final n = attempt < 0 ? 0 : (attempt > 16 ? 16 : attempt);
  final ms = base.inMilliseconds * (1 << n);
  final capMs = cap.inMilliseconds;
  return Duration(milliseconds: ms > capMs ? capMs : ms);
}
