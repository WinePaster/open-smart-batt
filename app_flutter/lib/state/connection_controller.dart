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

import 'package:clock/clock.dart';
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
import 'background_window_tracker.dart';
import 'device_controller.dart';
import 'device_facts_controller.dart';
import 'pack_class_resolver.dart';
import 'session_context.dart';
import 'settings_controller.dart';
import 'telemetry_health.dart';

/// Live BLE connection + scan state for the UI.
class ConnectionController extends ChangeNotifier {
  ConnectionController(
    this._ble, {
    required SettingsController settings,
    DeviceController? devices,
    DeviceFactsController? facts,
    LogRepo? logs,
    SessionContext? session,
    String? appBuild,
    MonitorService? monitor,
    PendingWrites? pending,
    AutoConnectArmRepo? autoConnectArm,
  }) {
    _settings = settings;
    _devices = devices;
    _facts = facts;
    _logs = logs;
    _armRepo = autoConnectArm;
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
      // Forget the previous connection's health, so this one's first real
      // transition always pushes rather than comparing equal to a state that
      // belonged to a link that is gone.
      _lastHealth = null;
      unawaited(_startMonitor());
    } else {
      unawaited(_monitor.stop());
    }
    // The monitor's engagement is one of the pacing gate's three inputs, so
    // every transition here re-evaluates it — this is what re-arms pacing when
    // an auto-reconnect brings the link back DURING a background window, and
    // what stands it down when the setting is toggled off mid-connection.
    _updateKeepAlivePacing();
  }

  /// Keep `BleService`'s keep-alive trigger in step with where execution
  /// actually comes from (design 0047 Phase 1).
  ///
  /// Three inputs, one writer: monitoring engaged ([_monitorRunning] — link
  /// online AND the setting on), a platform strategy that wants it
  /// ([MonitorService.pacesKeepAliveInBackground] — true ONLY for
  /// [IosMonitorService], which is hard condition 1's Android guarantee), and
  /// the app really being backgrounded ([BackgroundWindowTracker.inBackground]
  /// — the instrument Phase 0 landed, reused rather than duplicated). The
  /// setter is idempotent, so calling from every edge that can move an input
  /// costs nothing.
  ///
  /// Foreground iOS deliberately stays timer-driven: `resumed` closes the
  /// bg-window and this immediately hands the keep-alive back to the timer, so
  /// the FB-53-era foreground behaviour — including the resume probe's
  /// `pokeKeepAlive` — is untouched.
  void _updateKeepAlivePacing() {
    _ble.setNotifyDrivenKeepAlive(_monitorRunning &&
        _monitor.pacesKeepAliveInBackground &&
        _bgWindow.inBackground);
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
    _updateKeepAlivePacing();
    if (isOnline) unawaited(disconnect());
  }

  /// Watch the link's telemetry freshness so the notification can stop lying.
  ///
  /// Wired by [AppServices] once both controllers exist. Without it the
  /// notification says "monitoring" from `ready` until disconnect, whatever is
  /// or is not arriving — the state that made an orphaned service
  /// indistinguishable from a healthy one (design 0038 §1.2 e).
  void bindTelemetryHealth(TelemetryHealth health) {
    _health?.removeListener(_onHealthChanged);
    _health = health;
    _lastHealth = (health.hasTelemetry, health.telemetryStalled);
    health.addListener(_onHealthChanged);
  }

  /// Push the notification when — and only when — the health state CHANGES.
  ///
  /// [TelemetryController] notifies on every sample, so the early return is
  /// load-bearing, not tidiness: without it this would post at 1 Hz.
  ///
  /// Deliberately does NOT touch [_lastNotifyAt]. The throttle exists to stop
  /// 1 Hz posting; a state transition is rare (bounded below by the 2 s stall
  /// check) and the user is looking at the result right now — the same reason
  /// [setNotificationStrings] pushes straight through. Letting the next body
  /// update through immediately is also what you want on recovery: fresh
  /// numbers the moment they come back, not five seconds later.
  void _onHealthChanged() {
    final h = _health;
    if (h == null) return;
    final now = (h.hasTelemetry, h.telemetryStalled);
    if (now == _lastHealth) return;
    _lastHealth = now;
    if (_monitorRunning) unawaited(_monitor.update(_buildNotification()));
  }

  /// Which of the three titles the current health state calls for.
  ///
  /// ⚠️ [TelemetryHealth.hasTelemetry] is tested FIRST and the order is not
  /// interchangeable: `lastSampleAt` is seeded at `ready`, so a link that has
  /// never said a word also goes `stalled` after the threshold. Reading
  /// `telemetryStalled` first would label it "no data" and hang a
  /// last-updated clock on it for a reading that never existed.
  String get _stateTitle {
    final h = _health;
    if (h == null) return _notifyTitle; // nothing bound (iOS, tests)
    if (!h.hasTelemetry) return _notifyTitleConnecting;
    return h.telemetryStalled ? _notifyTitleStalled : _notifyTitle;
  }

  /// The reading line, stamped with its own clock time once it is stale.
  String get _stateBody {
    final h = _health;
    if (h == null || !h.hasTelemetry || !h.telemetryStalled) return _notifyBody;
    return formatStaleMonitorBody(_notifyBody, h.lastTelemetryAt);
  }

  MonitorNotification _buildNotification() => MonitorNotification(
        title: _stateTitle,
        body: _stateBody,
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
  ///
  /// Three titles, because one sentence cannot honestly cover three states:
  /// connected-and-flowing, connected-but-nothing-has-arrived-yet, and
  /// stalled. The reading line stays free of translated words (see
  /// [formatMonitorBody]), so the state has to ride the title.
  void setNotificationStrings({
    required String title,
    required String titleConnecting,
    required String titleStalled,
    required String stopLabel,
    required String channelName,
    required String channelDescription,
  }) {
    if (title == _notifyTitle &&
        titleConnecting == _notifyTitleConnecting &&
        titleStalled == _notifyTitleStalled &&
        stopLabel == _notifyStopLabel &&
        channelName == _notifyChannelName &&
        channelDescription == _notifyChannelDescription) {
      return;
    }
    _notifyTitle = title;
    _notifyTitleConnecting = titleConnecting;
    _notifyTitleStalled = titleStalled;
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
  String _notifyTitleConnecting = 'OpenSmartBatt';
  String _notifyTitleStalled = 'OpenSmartBatt';
  String _notifyBody = '';
  String _notifyStopLabel = '';
  String _notifyChannelName = '';
  String _notifyChannelDescription = '';
  TelemetryHealth? _health;
  (bool, bool)? _lastHealth;

  /// True while the background monitor is engaged.
  ///
  /// ⚠️ This is NOT "a foreground service is running". It tracks the SETTING
  /// plus the link, with no platform check: on Android it mirrors the
  /// foreground service, on iOS (since design 0047 Phase 1) it mirrors
  /// [IosMonitorService.engaged] — which starts no service and posts no
  /// notification — and on desktop/tests it reads true with nothing behind it
  /// at all. The stale banner used to branch on it and consequently told iOS
  /// users to go and change an Android battery setting; it no longer does, and
  /// no UI branches on this today. Do not reintroduce one without adding the
  /// platform check this flag lacks.
  bool get monitorRunning => _monitorRunning;
  late final SettingsController _settings;
  late final DeviceController? _devices;

  /// design 0057's identity cache — 🔴 **WRITE-ONLY from this controller.**
  ///
  /// Routing reads `saved_devices` and nothing else: [_seedClass], the lookup in
  /// [connect] that fills it, [resolvedClass] and [routing] are all untouched by
  /// this field, and must stay that way. The reason is the owner's, verbatim:
  /// deleting a device means「就是當一個陌生的裝置重新開始」— which is only true
  /// while the next connection has no memory to fall back on. A cache read here
  /// would give it one, and the first symptom would be that a unit the user
  /// deleted came back already classified, skipping the identification the
  /// deletion was meant to redo. T57-3 in `device_facts_test.dart` is the guard.
  late final DeviceFactsController? _facts;

  /// In-flight log/device writes, so teardown can wait for them before the
  /// database closes. See [PendingWrites] for the race this closes.
  late final PendingWrites _pending;

  /// The tracker, so a composition root can drain it (see `AppServices`).
  PendingWrites get pendingWrites => _pending;

  /// Where an armed autoConnect is persisted so it can outlive this process
  /// (design 0060 / FB-67), or null.
  ///
  /// Nullable on the design 0057 precedent: a controller built without one
  /// behaves exactly as it did before 0060 — the arm stays in memory, dies with
  /// the process, and no cold start reconciles anything. That keeps every test
  /// harness that does not care about the table out of it entirely, and it is
  /// what makes the "no row" path (§6 R4) provably free of side effects.
  late final AutoConnectArmRepo? _armRepo;
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
      maxBytes: _settings.logTrimBudget,
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
  ///
  /// FB-66: this timer is now only the FOREGROUND half of the deadline. It
  /// measures event-loop time, which iOS stops when it suspends the isolate, so
  /// the authority on whether the deadline has passed is [_autoConnectArmedAt]
  /// against the wall clock — see [_checkAutoConnectDeadline].
  Timer? _autoConnectTimer;

  /// Wall-clock instant the armed autoConnect started, or null when not armed.
  ///
  /// FB-66. The watchdog promises the USER 180 seconds; a `Timer` can only
  /// promise 180 seconds of ISOLATE time, and on a backgrounded iPhone those
  /// are different quantities by a measured factor of 1.5 to 23. This stamp is
  /// what makes the promise checkable: every verdict recomputes
  /// `clock.now() - armedAt` instead of trusting when the callback happened to
  /// run.
  ///
  /// CLOCK SOURCE — `package:clock`'s [clock], i.e. the wall clock, chosen over
  /// the two alternatives with eyes open:
  ///
  ///  * `Stopwatch` is monotonic and therefore immune to the user or NTP moving
  ///    the clock, but Dart's is backed by the platform's *uptime* counter,
  ///    which on Darwin does not advance while the device is asleep. That is
  ///    precisely the interval this fix exists to measure, so a monotonic clock
  ///    would reintroduce the same undercount in a quieter form. It is also
  ///    unfakeable, so none of this could be tested.
  ///  * an injected `DateTime Function()` would work but would have to be wired
  ///    through every construction site; [clock] is already substituted by
  ///    `fake_async` AND by `testWidgets`' binding, so the existing suites keep
  ///    exercising the real code path with no harness change.
  ///
  /// The residual risk is a wall-clock JUMP. Backwards: [_checkAutoConnectDeadline]
  /// re-arms for the remainder rather than firing, so the deadline is only ever
  /// extended. Forwards: the verdict lands early — the same outcome the user
  /// would have got by genuinely waiting, i.e. an honest failure plus a
  /// cancelled pending connect, and one tap undoes it. Both are strictly better
  /// than the current failure mode, which is no verdict at all.
  DateTime? _autoConnectArmedAt;

  /// Which device the armed autoConnect is for. The timer used to carry this in
  /// its closure; the resume checkpoint has no closure to read it from.
  String? _autoConnectArmedId;

  /// Set while a LATE verdict is being held back — see [autoConnectThawGrace].
  Timer? _autoConnectGraceTimer;

  /// The arm the PREVIOUS process left behind, from [restoreArm] until it is
  /// reconciled one way or the other. Null at every other moment, including on
  /// every launch that follows an ordinary shutdown.
  ///
  /// 🔴 Not a second kind of armed state. Nothing in the watchdog reads it, it
  /// never becomes `_autoConnectArmedAt`, and it cannot delay or extend a live
  /// deadline — it is a claim about an episode that is already over, held only
  /// long enough to find out whether this launch closes it (design 0060 §3.3).
  AutoConnectArm? _restoredArm;

  /// The window in which a restored arm may still be absorbed silently.
  Timer? _coldReconcileTimer;

  /// Deadline on the resume liveness probe ([onAppResumed]).
  Timer? _resumeProbeTimer;

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

  /// A device page is covering whatever asked for the scan ([setDetailVisible]).
  bool _detailVisible = false;
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
  /// ⚠️ FB-66: 180 s is what this app WAITS, not what a [Timer] delivers. The
  /// deadline is judged against the wall clock ([_autoConnectArmedAt]) and is
  /// re-checked at every resume, because a suspended isolate cannot notice its
  /// own deadline passing. See [_checkAutoConnectDeadline].
  static const Duration autoConnectWatchdog = Duration(seconds: 180);

  /// How long a LATE verdict waits before it acts (FB-66 acceptance criterion ②).
  ///
  /// A verdict is late when the isolate was frozen across the deadline, and the
  /// thing that thawed it is very often the hand-off ITSELF completing. The
  /// field case this exists to kill is `2026-08-12 10:10:38`: the overdue
  /// callback ran, dropped the link, and the `connected` it was waiting for
  /// arrived **4 ms later** — `link: disconnecting` → `link: connected`
  /// (`sub=502804ms`) → `connection canceled`. The watchdog cancelled the very
  /// reconnection it was armed to protect, after waiting 502 s to do it.
  ///
  /// [_onLinkState] already stands the watchdog down at `connected`, so this
  /// only covers the window where the platform event is in flight and has not
  /// reached the isolate yet — a window no in-process check can see. Two
  /// seconds is far more than the 4 ms observed and far less than the delay
  /// already incurred (263 s / 503 s / 936 s) — it cannot make a late verdict
  /// meaningfully later, and it is not applied at all when the verdict is
  /// punctual ([autoConnectPunctualitySlack]), so the foreground path keeps
  /// firing at exactly 180 s.
  static const Duration autoConnectThawGrace = Duration(seconds: 2);

  /// How much lateness still counts as "the event loop was running".
  ///
  /// Separates the punctual case (fire now, as documented) from the thawed case
  /// (hold for [autoConnectThawGrace]). One second is ordinary timer jitter;
  /// the smallest overshoot ever measured in the field is 83 s.
  static const Duration autoConnectPunctualitySlack = Duration(seconds: 1);

  /// How long a cold start waits before it declares the previous run's armed
  /// autoConnect unconverged (design 0060 §3.3, defence (b)).
  ///
  /// 🔴 This window exists to stop A from libelling B. CoreBluetooth state
  /// restoration hands the connection back AT the launch it caused, so without
  /// a window every single time restoration WORKS the reconciliation would
  /// report that it had not. Reporting is therefore held until either the link
  /// arrives (absorbed silently) or the window closes.
  ///
  /// 10 s, and the anchor is INDIRECT — said plainly because it is the weakest
  /// number in design 0060. FB-67 measured 8 of 9 overdue arms whose
  /// "reconnected" instant coincided with a cold return to within 0.1–2.7 s, so
  /// 2.7 s is the observed upper bound on cold-start → link, and 10 s is an
  /// order above it. That is the same style as [resumeProbeWindow] (5 s against
  /// a measured p50 of 0.34 s). What no capture in hand measures is the
  /// DISTRIBUTION of cold-start → `ready`, because until the `cold-start:` line
  /// shipped there was no record that a launch was cold at all — design 0060 Q4
  /// / Phase 3 R7 is the job of backfilling this value from the field.
  ///
  /// The cost of getting it wrong is bounded on purpose: the owner's 2026-08-13
  /// ruling removed the UI, so a window that is too short costs one extra line
  /// in a diagnostic log, not a false failure card in front of a user.
  static const Duration coldReconcileGrace = Duration(seconds: 10);

  /// Past this age a restored arm is logged and dropped rather than reconciled
  /// (design 0060 §3.2).
  ///
  /// A REASONED value, not a measured one: the longest background window in the
  /// FB-67 capture is 1,192.7 minutes (19.9 h), and 24 h clears it. The point is
  /// not precision, it is that an account of something that happened yesterday
  /// is noise rather than an account — and, with the reconciliation reduced to a
  /// log line, this bound is mostly what stops a phone left in a drawer from
  /// carrying one arm forward indefinitely.
  static const Duration coldReconcileMaxAge = Duration(hours: 24);

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

  /// True while an armed iOS autoConnect hand-off is still outstanding.
  ///
  /// This is the gap [isBusy] and [isRetrying] BOTH miss, and it is the widest
  /// one on this screen. The hand-off is the OS's, not ours: the link really is
  /// `disconnected` (so `isBusy` is false) and no retry timer of ours is
  /// pending (so `isRetrying` is false), for the whole of
  /// [autoConnectWatchdog]. The copy therefore fell through to the idle
  /// branch — "No device connected", the same words shown when nothing is
  /// happening at all. That is the exact complaint FB-53 fixed for the backoff
  /// ladder; this is the same hole, one path over.
  ///
  /// Field evidence (`2026.08.13/006`, FB-20's 2026-08-13 re-report): the link
  /// dropped at 21:42:54, the arm expired on time at 21:45:55, and the user
  /// exported a diagnostic capture 11 s later — three minutes of a screen that
  /// said nothing was going on, ending just before the failure card would have
  /// appeared.
  ///
  /// ⚠️ Deliberately a BOOL, not an elapsed count. Nothing calls
  /// `notifyListeners` during the wait, so a live counter would need a 1 s
  /// ticker and would sit there frozen without one — a wrong number is worse
  /// than none. The copy states the DEADLINE ([autoConnectWatchdog]) instead,
  /// which is the part the user is actually missing.
  bool get isAutoConnectArmed => _autoConnectArmedAt != null;

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

  String? _liveMac;

  /// The device's OWN BLE address, as reported by `0x38` on this link — or null
  /// until it has said so (design 0055 §7 Q2).
  ///
  /// 🔴 This belongs to the CONNECTED device, and it is a lie about any other
  /// one. Callers must gate it on `connectedDeviceId == <the unit they are
  /// drawing>`; the same rule as every other live reading, and the same rule
  /// FB-41/FB-42 were about. It is cleared on disconnect for that reason rather
  /// than kept as a "last known" — a stale MAC under a fresh unit's name is
  /// precisely the class of mistake this project keeps paying for.
  ///
  /// Why the wire and not the platform id: on Android those are the same string
  /// anyway, and on iOS the platform id is an install-scoped NSUUID, so `0x38`
  /// is the ONLY route to a real MAC there.
  ///
  /// 🔴 CLEAN-ROOM: raw, in memory, for display on this device only. Nothing
  /// exports it — the export path hashes the MAC (design 0027 §3.1).
  String? get liveMac => _liveMac;

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
    // 🔴 The「仍要顯示讀數（未分類）」override was REMOVED 2026-08-08
    // (design 0050 D3), along with the button that set it.
    //
    // It turned a PENDING link — no device-type byte at all — into
    // `RoutingDecision.unclassified`, which then drew the pack shell. Its own
    // comment argued it was "not a class assertion" because it named no class.
    // That was true about the code and false about the screen: the shell it
    // landed on carried a voltage gauge, a numbers grid and per-cell bars,
    // which asserts a pack as plainly as naming one would. FB-43 is what that
    // looks like when the unit is a power bank.
    //
    // What remains is the wire byte, and waiting for it.
    return d;
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

  /// How long the link has been [isOnline] (ready), or null when offline.
  ///
  /// Unlike [pendingFor] this holds for a unit whose class is already resolved —
  /// the energy-path row (design 0035 §4.6) uses it to say "connected N s" while
  /// a power bank's first `0x4B` is still on its way (up to ~10 s per connect),
  /// which must read differently from a decoded reading of zero.
  Duration? get onlineFor {
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
  ///
  /// Also feeds the `bg-window:` instrument (design 0047 Phase 0): one line at
  /// each foreground/background edge, stamping the link state the app carried
  /// into the window and how long the window lasted. The link snapshot reads
  /// [_link] — state this controller already holds — so the instrument adds no
  /// query and cannot change behaviour.
  void logAppLifecycle(String state) {
    _event('app $state');
    final line = _bgWindow.onLifecycle(state,
        link: BackgroundWindowTracker.linkToken(_link), now: DateTime.now());
    if (line != null) _event(line);
    // Phase 1: the bg-window edge is also the keep-alive pacing edge — enter
    // hands the keep-alive to the notify path (iOS only, see the gate), exit
    // hands it back to the timer. AFTER the tracker so both read one state.
    _updateKeepAlivePacing();
  }

  /// Foreground/background window pairing for the `bg-window:` lines.
  final BackgroundWindowTracker _bgWindow = BackgroundWindowTracker();

  /// How long the resume probe waits for telemetry before giving up on a link.
  ///
  /// 5 s against a measured p50 of 0.29 s (Android) / 0.34 s (iOS) from
  /// `app resumed` to the next inbound frame across the whole corpus — a
  /// healthy link answers an order of magnitude inside this. It is deliberately
  /// generous rather than tight: the cost of waiting is a few stale seconds,
  /// the cost of firing early is dropping a link that was about to answer.
  ///
  /// Compare the tail this exists to cut: p90 240 s, max 14.5 h (design 0039
  /// §1.3). Reconnecting takes seconds; waiting out that tail does not.
  static const Duration resumeProbeWindow = Duration(seconds: 5);

  /// The app came back to the foreground — find out whether the link survived.
  ///
  /// A suspension that ends in the OS reclaiming the link produces NO
  /// disconnect event, so on resume `ready` is a claim, not a fact. Ask, then
  /// hold the answer to a deadline.
  ///
  /// 🔑 The test is "did ANY telemetry arrive inside the window", NOT "is the
  /// rate back to normal". Thawing flushes a backlog all at once
  /// (`ble_service.dart`'s keep-alive re-entrancy note records both directions
  /// stalling for minutes and then resuming together), so a rate-based test
  /// would misread recovery as failure and tear down a link that is coming
  /// back. That is the same trap design 0038 §1.3 rejected the liveness
  /// watchdog for; do not reintroduce it here.
  /// [window] is injectable for the same reason `TelemetryController`'s stall
  /// threshold is: the policy is the thing worth testing, and a deadline that
  /// takes five real seconds to exercise is a deadline nobody tests.
  void onAppResumed({Duration? window}) {
    _resumeProbeTimer?.cancel();
    _resumeProbeTimer = null;
    // FB-66: BEFORE the `isOnline` gate, and deliberately so. Everything below
    // this line is about a link that survived; an armed autoConnect is a link
    // that has not come back, which `isOnline` reports as "nothing to do here".
    // That gate is why the app could sleep through its own deadline: resume is
    // the moment the isolate is guaranteed to run again, and it was the one
    // moment the watchdog could not use.
    _checkAutoConnectDeadline('resume');
    if (!isOnline) return;
    unawaited(_ble.pokeKeepAlive().catchError((Object _) {}));
    _resumeProbeTimer =
        Timer(window ?? resumeProbeWindow, _onResumeProbeExpired);
  }

  void _onResumeProbeExpired() {
    _resumeProbeTimer = null;
    if (!isOnline) return;
    _event('resume probe: no telemetry within '
        '${resumeProbeWindow.inSeconds}s of resuming — dropping a link the OS '
        'may already have taken');
    // `_ble.disconnect()`, NOT this controller's `disconnect()`: the latter
    // sets `_manualDisconnect` and clears `_desiredDeviceId`, which would
    // suppress the very reconnect this exists to trigger. Same reasoning, and
    // the same call, as `_onAutoConnectExpired`.
    unawaited(_ble.disconnect().catchError((Object _) {}));
  }

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

  /// W-3: a per-device page is on screen — from ANY entrance (ruled 2026-08-12).
  ///
  /// 🔴 This used to be `DevicesPage._openDetail`'s private business: it stopped
  /// the scan before pushing and started it again on the way back. That is a
  /// rule about a WINDOW ("somebody is looking at one unit") wearing the shape
  /// of a rule about a CALL SITE, and it only held while that call site was the
  /// only way in. The app-bar pill is a second entrance and the home tiles are a
  /// third — both push from the shell, which has no idea a list is scanning
  /// behind it — so the radio would have run for as long as the user read the
  /// page. That is the disagreement `_openDetail` warned about in so many words:
  /// the GNSS and G-force gates already call this window "somebody is looking",
  /// and one of them leaving a radio on only ever shows up as battery.
  ///
  /// So the page reports itself, exactly as it already does to those two gates,
  /// and the scan reads the same signal. Whoever pushes it is no longer a fact
  /// anyone has to know.
  void setDetailVisible(bool visible) {
    if (_detailVisible == visible) return;
    _detailVisible = visible;
    if (visible) {
      // 🔴 `_ble.stopScan()`, NOT `stopScan()`. The latter clears `_wantScan`,
      // and `_wantScan` is the record of the devices tab WANTING a scan — the
      // one thing that has to survive being covered up, or the list comes back
      // blind and the adapter-turned-on re-fire below never happens either.
      unawaited(_ble.stopScan());
    } else if (_wantScan) {
      unawaited(startScan());
    }
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
    // Any link transition answers the resume probe's question for it.
    _resumeProbeTimer?.cancel();
    _resumeProbeTimer = null;
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

    // design 0060 §3.3, defences (b) + (c). AFTER the line above so a capture
    // reads in order — `link: connected` and then what it settled. `connected`
    // counts as well as `ready`: the previous process's hand-off was waiting
    // for the OS to produce a link, which it now has, and whatever happens to
    // the GATT setup afterwards is FB-51/FB-52's episode, not that one's.
    if (s == BleLinkState.connected || s == BleLinkState.ready) {
      _absorbColdArm();
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
      // The 0x38 MAC dies with the link it described. Keeping it as a "last
      // known" would put one unit's address under the next unit's name the
      // moment the user switched devices — see [liveMac].
      _liveMac = null;
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
    // FB-66: the timer is the foreground half; the stamp is the deadline. Both
    // are set here so no path can arm one without the other.
    _cancelAutoConnectWatchdog();
    _autoConnectArmedAt = clock.now();
    _autoConnectArmedId = id;
    _autoConnectTimer = Timer(autoConnectWatchdog, _onAutoConnectTimerFired);
    // design 0060 §3.2 — the ONLY place a row is written, and it is written
    // BEFORE the hand-off, not after. `_ble.connect` below is `unawaited`, the
    // process can be reclaimed at any instant from here on, and the whole point
    // of the row is to be older than whatever kills us. Fire-and-forget through
    // [_pending], the same path `_event` uses, so teardown still drains it.
    final repo = _armRepo;
    if (repo != null) {
      _pending.add(repo.write(AutoConnectArm(
        deviceId: id,
        armedAt: _autoConnectArmedAt!,
        appBuild: _appBuild,
        sessionId: _session.sessionId,
      )));
    }
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

  /// The 180 s timer came due (FB-53). Whether the DEADLINE has passed is a
  /// separate question, and [_checkAutoConnectDeadline] is the one that answers
  /// it (FB-66).
  void _onAutoConnectTimerFired() {
    _autoConnectTimer = null;
    _checkAutoConnectDeadline('timer');
  }

  /// Is the armed autoConnect out of time? Ask the WALL CLOCK, not the timer.
  ///
  /// FB-66 acceptance criterion ①. Called from the two places that can know:
  /// the timer coming due, and the app returning to the foreground. Both go
  /// through here, and neither is trusted about the passage of time — the only
  /// input is `clock.now()` minus [_autoConnectArmedAt].
  ///
  /// [trigger] names the caller and is written into the log, because "the
  /// verdict arrived because the user came back" and "the verdict arrived
  /// because the OS finally ran our timer" are different events that used to be
  /// indistinguishable in a capture.
  void _checkAutoConnectDeadline(String trigger) {
    final armedAt = _autoConnectArmedAt;
    final id = _autoConnectArmedId;
    if (armedAt == null || id == null) return; // not armed / already resolved
    if (_autoConnectGraceTimer != null) return; // a verdict is already pending
    final waited = clock.now().difference(armedAt);
    final remaining = autoConnectWatchdog - waited;
    if (remaining > Duration.zero) {
      // Not due. The timer only ever disagrees with the wall clock when the
      // wall clock moved BACKWARDS under us (NTP, or the user). Re-arm for what
      // the wall clock says is left rather than firing on the timer's word: a
      // clock correction must not be able to shorten the user's 180 s.
      if (trigger == 'timer') {
        _autoConnectTimer?.cancel();
        _autoConnectTimer = Timer(remaining, _onAutoConnectTimerFired);
      }
      return;
    }
    final overshoot = waited - autoConnectWatchdog;
    // Two ways to know this verdict is being reached at a THAW rather than in a
    // running foreground: the timer came due far later than it was set for, or
    // the trigger is a resume, which by definition follows a background window
    // however short. Both mean platform events may be in flight behind us.
    final thawed =
        trigger != 'timer' || overshoot > autoConnectPunctualitySlack;
    if (thawed) {
      // We were frozen across the deadline. Do NOT act on the spot — see
      // [autoConnectThawGrace]. Cancel the timer first: once the grace is
      // running it is the only thing that may reach a verdict.
      _autoConnectTimer?.cancel();
      _autoConnectTimer = null;
      _event('auto-reconnect: autoConnect watchdog woke ${waited.inSeconds}s '
          'into a ${autoConnectWatchdog.inSeconds}s deadline (by $trigger) — '
          'holding ${autoConnectThawGrace.inSeconds}s in case the hand-off is '
          'landing');
      _autoConnectGraceTimer = Timer(autoConnectThawGrace, () {
        _autoConnectGraceTimer = null;
        _onAutoConnectExpired(id, clock.now().difference(armedAt));
      });
      return;
    }
    _autoConnectTimer?.cancel();
    _autoConnectTimer = null;
    _onAutoConnectExpired(id, waited);
  }

  /// The armed autoConnect ran out of time (FB-53 / [autoConnectWatchdog]).
  ///
  /// [waited] is the WALL time actually spent waiting, measured, not assumed —
  /// FB-66 acceptance criterion ③. It is >= [autoConnectWatchdog] and on a
  /// backgrounded iPhone can be several times it.
  void _onAutoConnectExpired(String id, Duration waited) {
    // Anything that made this stale answers for itself: the link came up, the
    // user disconnected, or the user pointed at a different unit.
    if (isOnline || _manualDisconnect || _desiredDeviceId != id) return;
    // FB-66 acceptance criterion ②: `connected` — the hand-off DELIVERED, and
    // the app has not finished setting the link up yet. [_onLinkState] already
    // stands the watchdog down at `connected`, so reaching here in that state
    // means the event landed while this verdict was in flight. Killing the link
    // now is the 10:10:38 field case, where a 502 s-late watchdog cancelled a
    // connection that had arrived 4 ms earlier.
    //
    // ⚠️ This does NOT re-open FB-52. "Came up and never said anything" is
    // still bounded, by a different instrument: `_setupFailuresSinceReady` /
    // [isSetupStalled], which counts connections that reached `connected` and
    // left without `ready` and stops the ladder at [maxSetupFailures]. Standing
    // down here hands the episode to that counter, which is exactly what the
    // `connected` branch of [_onLinkState] already does deliberately. What must
    // never happen is both instruments owning the same link at once.
    if (_link == BleLinkState.connected) {
      _event('auto-reconnect: autoConnect watchdog stood down after '
          '${waited.inSeconds}s — the hand-off landed while the verdict was in '
          'flight (link is `connected`; setup is FB-51/FB-52 territory)');
      _cancelAutoConnectWatchdog();
      return;
    }
    // Nothing beyond this point can be undone, so the arm is spent.
    _cancelAutoConnectWatchdog();
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
    // FB-66 acceptance criterion ③: the MEASURED wait, not the constant. This
    // line used to interpolate `autoConnectWatchdog.inSeconds` and so reported
    // `gave up after 180s` for a wait of 935 s — the only instrument this
    // failure has in the field, hard-coded to the answer it was supposed to be
    // measuring. The nominal value is kept alongside it so a capture states
    // both the promise and what was actually delivered.
    _event('auto-reconnect: autoConnect gave up after '
        '${waited.inSeconds}s (deadline ${autoConnectWatchdog.inSeconds}s) with '
        'no `ready` — pending connect cancelled');
    // The first place in this app that actually CANCELS a connect. Everywhere
    // else an abandoned `device.connect()` is simply forgotten: teardown nulls
    // the handle, so the `disconnect()` at the head of the next `connect()`
    // returns early and the old attempt stays in flight inside the plugin.
    // Two of them landing a millisecond apart is on record
    // (`2026-08-01T11:39:36.517/.519`, fbp-code 1 and 10).
    unawaited(_ble.disconnect().catchError((Object _) {}));
    notifyListeners();
  }

  /// Disarm every part of the watchdog at once.
  ///
  /// FB-66 turned "the watchdog" from one timer into three pieces of state, and
  /// they must go together — a stamp left behind would let the next resume
  /// deliver a verdict on an episode that is over, and a grace timer left
  /// behind would deliver one after the link came back. Every existing caller
  /// (`connected`, `ready`, `connect`, `disconnect`, arming failure, `dispose`)
  /// gets the whole disarm without changing.
  /// design 0060 §3.2 adds a fourth piece — the persisted row — and hangs its
  /// deletion here and NOWHERE else. FB-66 had already funnelled all six
  /// cancellation points (`connected`, `ready`, `connect`, `disconnect`, arming
  /// failure, `dispose`) through this one function, so one line covers all six
  /// and no seventh can be forgotten.
  ///
  /// ⚠️ `dispose()` deleting the row is DELIBERATE and is the owner's ruling (c)
  /// of 2026-08-13 in code form. `dispose` running at all means the app got a
  /// turn to converge — an ordinary close, a hot restart, a test teardown —
  /// whereas iOS reclaiming a suspended process calls nothing, which is exactly
  /// the case FB-67 is about. So a row that survives is a row nobody was given
  /// the chance to delete. The cost is that a user force-quitting by swipe gets
  /// no reconciliation IF that path runs `dispose`; we cannot tell a swipe from
  /// a reclaim, and this puts the ambiguity on the under-report side.
  void _cancelAutoConnectWatchdog() {
    _autoConnectTimer?.cancel();
    _autoConnectTimer = null;
    _autoConnectGraceTimer?.cancel();
    _autoConnectGraceTimer = null;
    // Read BEFORE the fields are cleared. Either half is a reason for a row to
    // exist: this process armed one, or the previous one did and this launch
    // has not finished reconciling it. Neither ⇒ there is nothing on disk and
    // the delete would be pure I/O on a path that runs on every connect,
    // disconnect and `ready`.
    final mayHaveRow = _autoConnectArmedId != null || _restoredArm != null;
    _autoConnectArmedAt = null;
    _autoConnectArmedId = null;
    if (mayHaveRow) _clearArmRow();
  }

  void _clearArmRow() {
    final repo = _armRepo;
    if (repo != null) _pending.add(repo.clear());
  }

  /// Hand this controller the armed autoConnect the PREVIOUS process left
  /// behind (design 0060 §3.3). Called once, by `AppServices.create`.
  ///
  /// 🔑 The judgement is simpler than it looks, and the simplification is the
  /// heart of design 0060: **a pending connect dies with the process that
  /// registered it**, so whether `armed_at` is older than the 180 s watchdog is
  /// irrelevant to "did it converge?". Any surviving row is an unconverged
  /// hand-off. The deadline only decides what number goes in the log line.
  ///
  /// Three defences keep a SUCCESS from being reported as a failure:
  ///
  ///  * **(a)** the previous process already deleted the row on every ordinary
  ///    convergence — [_cancelAutoConnectWatchdog] covers all six exits;
  ///  * **(b)** a row that IS here is not reported at once. It is held for
  ///    [coldReconcileGrace], because CoreBluetooth state restoration delivers
  ///    the link at the very launch it caused (design 0060 §3.7 #1) — without
  ///    this window, every time restoration works, this would say it had not;
  ///  * **(c)** and only the SAME unit absorbs it. A user who cold-starts and
  ///    connects to a different device has not closed the previous hand-off.
  ///
  /// [arm] null is the ordinary case and must stay completely free of side
  /// effects: it runs inside every `AppServices.create`, of which the suite has
  /// 37 (design 0060 §6 R4).
  void restoreArm(AutoConnectArm? arm) {
    if (arm == null) return;
    final waited = clock.now().difference(arm.armedAt);
    if (waited > coldReconcileMaxAge) {
      // Logged, then dropped. An account of yesterday is not an account.
      _event('cold-start: discarding an autoConnect armed ${waited.inSeconds}s '
          'ago for ${shortDeviceHash(arm.deviceId)} — older than the '
          '${coldReconcileMaxAge.inHours}h limit');
      _clearArmRow();
      return;
    }
    _restoredArm = arm;
    _coldReconcileTimer = Timer(coldReconcileGrace, _onColdReconcileExpired);
    _adoptRestoredArm(arm);
  }

  /// Take over the hand-off the reclaimed process registered (design 0060
  /// §3.7 #1) — the ONE exception to "a cold start does not connect on its own",
  /// and the thing that makes state restoration usable at all.
  ///
  /// 🔴 THE FAILURE THIS EXISTS TO PREVENT. Our `connectionState` subscription
  /// is created inside `BleService.connect()` and nowhere else
  /// (`ble_service.dart`, `device.connectionState.listen(...)` beside the
  /// `_LinkState` it belongs to). A link CoreBluetooth restores never goes
  /// through that call, so it would arrive with no subscriber: `_current` null,
  /// `linkState` never moving off `disconnected`, GATT setup never run — a
  /// connection that exists on the radio and carries no data, which is a worse
  /// outcome than not reconnecting at all. Re-issuing our own connect is what
  /// builds the subscription the restored link needs.
  ///
  /// It is an ADOPTION, not a new attempt: the OS has already been asked to
  /// reconnect this unit and may already have done it. `autoConnect: true` is
  /// therefore the right form — no timeout, no ladder, no MTU — and it is also
  /// the form that is harmless if the peripheral is nowhere near.
  ///
  /// ⚠️ Idempotency is ASSUMED, not verified. The plugin's `willRestoreState:`
  /// re-issues `connectPeripheral` for a restored-but-disconnected peripheral
  /// and replays `didConnect` for one already up; what a second `connect()` from
  /// us does on top of either is not answerable from the source, and no host
  /// test can raise the event. Design 0060 Q2 / Phase 3 R1 is the device check —
  /// look for duplicate `link: connected` or an odd `sub=` in `conn-state:`.
  ///
  /// No watchdog is armed here, deliberately. This is not a fresh 180 s promise;
  /// it is the tail of one made by a process that no longer exists, and
  /// [_coldReconcileTimer] is already the deadline on what THIS launch does
  /// about it.
  void _adoptRestoredArm(AutoConnectArm arm) {
    final id = arm.deviceId;
    // The target, so the ordinary machinery treats this as the unit we want:
    // without it a drop after a SUCCESSFUL adoption would find
    // `_desiredDeviceId == null` and re-arm nothing, quietly re-opening FB-67
    // for the very link restoration just gave back. It does not start a ladder
    // — that path additionally requires `reachedConnected` or an attempt count,
    // both zero here.
    _desiredDeviceId = id;
    _event('restore: adopting ${shortDeviceHash(id)} — re-registering the '
        'pending connect the previous process left behind');
    unawaited(_ble.connect(id, autoConnect: true).catchError((Object e) {
      // Nothing to escalate to. The reconciliation window is still running and
      // will report the episode unresolved on its own; a failure here only
      // means the OS would not take the hand-off back.
      _event('restore: adopting ${shortDeviceHash(id)} failed: $e');
    }));
  }

  /// Defences (b) + (c): this launch reached the very unit the last one was
  /// waiting for, so the hand-off converged after all. Silent by construction —
  /// the log says so and nothing else happens.
  void _absorbColdArm() {
    final arm = _restoredArm;
    if (arm == null) return;
    // `_ble.connectedDeviceId`, not `connectedDeviceId`: the getter falls back
    // to `_desiredDeviceId`, which is the unit we ASKED for. Absorbing an
    // episode requires the link we actually hold.
    if (_ble.connectedDeviceId != arm.deviceId) return;
    _restoredArm = null;
    _coldReconcileTimer?.cancel();
    _coldReconcileTimer = null;
    final waited = clock.now().difference(arm.armedAt);
    _event('cold-start: the autoConnect armed ${waited.inSeconds}s ago for '
        '${shortDeviceHash(arm.deviceId)} converged at `${_link.name}` after '
        'the restart — nothing to report');
    _clearArmRow();
  }

  /// The window closed with no link to the armed unit. Say so, once, in the
  /// diagnostic log — and NOWHERE else (owner's ruling 2026-08-13:
  /// 「只要寫log, 顯示在ui要幹麻？」). No gaveUp code, no `_lastError`, no
  /// `notifyListeners()`: the episode being reported is over, the user has
  /// nothing to do about it, and the connection they are looking at right now
  /// reports its own state through FB-52/FB-66 exactly as before.
  void _onColdReconcileExpired() {
    _coldReconcileTimer = null;
    final arm = _restoredArm;
    if (arm == null) return;
    _restoredArm = null;
    final waited = clock.now().difference(arm.armedAt);
    final by = arm.appBuild;
    final provenance =
        (by == null || by == _appBuild) ? '' : ' (armed by $by)';
    _event('cold-start: the autoConnect for ${shortDeviceHash(arm.deviceId)} '
        'did not converge — armed ${waited.inSeconds}s ago$provenance, and no '
        'link to it inside ${coldReconcileGrace.inSeconds}s of this launch');
    // Do NOT delete a row this episode no longer owns. A drop inside the window
    // can arm a FRESH hand-off (to another unit, or to this one after a
    // connect), and that row belongs to a live deadline — deleting it here
    // would recreate FB-67 for the very episode currently in flight.
    if (_autoConnectArmedId == null) _clearArmRow();
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
    // The link answered — whatever the resume probe was waiting for, it came.
    _resumeProbeTimer?.cancel();
    _resumeProbeTimer = null;
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
    _observeLiveMac(s);
    final id = _ble.connectedDeviceId;
    if (id != null) {
      // The sample is right here, so the stored value and the stored age come
      // from the same instant. See [_touchLastSeen].
      _touchLastSeen(id, value: s.pvlt);
      _persistIdentity(id, s);
      _persistFacts(id, s);
    }
  }

  /// Persist the unit's own BLE address (0x38 MAC) and full serial onto its
  /// saved record the first time each is seen (design 0027 §3.2). The MAC is
  /// the stable cross-platform identity; the serial is the human-readable one.
  ///
  /// [DeviceController.setIdentity] already no-ops when the values are unchanged
  /// or the device is not saved, so this can be called on every telemetry
  /// sample without spamming the DB.
  ///
  /// 🔴 CLEAN-ROOM: only the RAW values are stored, internally. Nothing here
  /// exports them — the export path hashes the MAC (design 0027 §3.1).
  void _persistIdentity(String id, TelemetrySample s) {
    final write = _devices?.setIdentity(id, mac: s.mac, serial: s.fullSerial);
    if (write != null) _pending.add(write);
  }

  /// Cache what this unit just said about itself, named or not (design 0057
  /// §4.2).
  ///
  /// The sibling of [_persistIdentity], and the difference between them is the
  /// whole point of design 0057: that one writes onto a SAVED record and quietly
  /// does nothing when there is none, which is how an unnamed capacitor's
  /// export came to state its permanent, unmeasurable `0.0 A` as a measurement.
  /// This one always writes. For a saved unit the two now record the same facts
  /// in two places, deliberately — §4.5 leaves the duplicate columns on
  /// `saved_devices` alone, because removing them would move a read that
  /// routing performs.
  ///
  /// 🔴 The class comes from [PackClassResolver.deviceClass] — the `0x10` byte
  /// and nothing else. NOT `label` (which includes the user's manual pick) and
  /// NOT [resolvedClass] (which includes the saved-record seed). A guess stored
  /// in a table called `device_facts` would be read back later as an
  /// observation, and on a rebound iOS id the seed belongs to another unit
  /// entirely — the FB-25 shape, which is why [_recomputePackLabel] guards its
  /// own write the same way.
  void _persistFacts(String id, TelemetrySample s) {
    final facts = _facts;
    if (facts == null) return;
    final advertised = _ble.connectedDeviceName;
    final wireClass = _packResolver.deviceClass;
    _pending.add(facts.record(
      id,
      name: advertised.isEmpty ? null : advertised,
      productClass: wireClass == ProductClass.unknown ? null : wireClass,
      mac: s.mac,
      serial: s.fullSerial,
    ));
  }

  /// Keep the `0x38` MAC in memory for the live link (design 0055 §7 Q2).
  ///
  /// Separate from [_persistIdentity] on purpose, and NOT behind its
  /// `connectedDeviceId != null` gate: that gate belongs to a database write
  /// keyed by the platform id, while this value describes the LINK that
  /// produced the sample. It also has to work where the write does not —
  /// `setIdentity` no-ops on a device with no saved record, which is exactly
  /// the device whose identity is hardest to show.
  ///
  /// A sample without `0x38` leaves it alone rather than clearing it: the
  /// selector is not on every frame, and clearing on absence would flicker the
  /// subtitle between the address and "no advertised name" at frame rate.
  void _observeLiveMac(TelemetrySample s) {
    final mac = s.mac;
    if (mac == null || mac.isEmpty || mac == _liveMac) return;
    _liveMac = mac;
    notifyListeners();
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
  ///
  /// [value] rides along on the telemetry-driven calls, and it has to.
  ///
  /// 🔴 `last_value` used to be written in exactly ONE place — `saveNew`, when
  /// the unit was first named — while `last_seen` advanced every minute of
  /// every session. The two are rendered as a single sentence
  /// ("12.6 V · 3 minutes ago"), so the pair drifted apart silently: the age
  /// was current and the number could be weeks old. Design 0046 promoted that
  /// sentence from an 11 pt meta line in a bottom sheet to the headline of the
  /// default home page, and then wrote an invariant on top of it (T-new-3, "a
  /// number never appears without its age") — which the code satisfied to the
  /// letter while telling the user something false.
  ///
  /// Writing both together costs nothing: this method is already throttled to
  /// [lastSeenInterval], so it is one extra column on a write that was
  /// happening anyway. The forced calls pass null, and `DeviceRepo.touch`
  /// omits a null rather than clearing the column — a disconnect must not
  /// erase the last thing we knew.
  void _touchLastSeen(String id, {bool force = false, double? value}) {
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
    final touch = _devices?.touch(id, lastSeen: now, lastValue: value);
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
    //
    // `!_detailVisible` closes the one hole the W-3 rewiring leaves: the user
    // can turn the radio on while a device page is up, and re-firing then would
    // start a scan behind a page that is supposed to have stopped it. The
    // intent is not lost — `_wantScan` still holds it, and [setDetailVisible]
    // starts the scan when the page closes.
    if (s == BluetoothAdapterState.on &&
        prev != BluetoothAdapterState.on &&
        _wantScan &&
        !_scanning &&
        !_detailVisible) {
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
    // design 0060: only the TIMER. `_restoredArm` is deliberately left set, so
    // the `_cancelAutoConnectWatchdog` below still sees a reason to delete the
    // row — a teardown inside the reconciliation window is an ordinary close
    // like any other (ruling (c)), and carrying the arm into a third launch
    // would report an episode two processes old.
    _coldReconcileTimer?.cancel();
    _coldReconcileTimer = null;
    _cancelAutoConnectWatchdog();
    _resumeProbeTimer?.cancel();
    // Safe after the notifier itself is disposed — AppServices tears telemetry
    // down first, and ChangeNotifier.removeListener documents that it "is
    // allowed to be called on disposed instances for usability reasons".
    _health?.removeListener(_onHealthChanged);
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

/// Stamp a frozen reading with the clock time it was actually taken.
///
/// Pure + unit-testable, and language-free for the same reason
/// [formatMonitorBody] is: `HH:mm` needs no translation.
///
/// An ABSOLUTE time, not "3 minutes ago". A relative age is wrong the moment
/// it is posted and only stays right if the notification is re-posted on a
/// timer — a battery cost, for a line nobody is watching second by second. A
/// clock time is posted once and remains true.
///
/// [at] null (nothing has ever arrived) leaves the body alone: there is no
/// moment to name, and inventing one is exactly the confusion
/// [TelemetryHealth.lastTelemetryAt] warns about.
String formatStaleMonitorBody(String body, DateTime? at) {
  if (at == null) return body;
  final hh = at.hour.toString().padLeft(2, '0');
  final mm = at.minute.toString().padLeft(2, '0');
  final stamp = '($hh:$mm)';
  return body.isEmpty ? stamp : '$body $stamp';
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
