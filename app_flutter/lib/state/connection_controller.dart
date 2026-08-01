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
    show BluetoothAdapterState, FlutterBluePlusException;
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
  StreamSubscription<void>? _monitorStopSub;

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
  String? _lastError;
  bool _wantScan = false; // user asked to scan; re-fire when adapter turns on
  int _reconnectAttempts = 0;

  /// Cap on consecutive auto-reconnect attempts before giving up (D.4). Without
  /// a cap a stale iOS NSUUID would re-arm forever; capping lets the error
  /// surface within seconds instead of an endless reconnect loop.
  static const int maxReconnectAttempts = 5;

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
  Future<void> connect(String deviceId,
      {Duration? timeout, ProductClass? seedClass}) async {
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0; // fresh manual connect resets the backoff
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
    try {
      await _ble.connect(deviceId, timeout: timeout);
    } catch (e) {
      _lastError = e.toString();
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
      if (Platform.isIOS) _lastError = 'device_stale';
      _event('saved connect failed${Platform.isIOS ? ' (stale?)' : ''}: $e');
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
      _readyAt = null;
      // Drop the settling window + label so the next unit starts clean.
      _packResolver.reset();
      _packLabel = ProductClass.unknown;
      _loggedUnknownStatus.clear();
      // Stop attributing rows to this unit (the disconnect line above is still
      // attributed — it belongs to the connection that just ended).
      _session.end();
      // Unexpected drop while we still want this device → try to reconnect.
      if (!_manualDisconnect &&
          _settings.autoReconnect &&
          _desiredDeviceId != null) {
        if (wasOnline && Platform.isIOS) {
          // B: iOS hands a dropped HEALTHY link to CoreBluetooth autoConnect for
          // seamless OS-level recovery (no app-level backoff loop). A failed
          // *initial* connect (not wasOnline) still uses the capped backoff path
          // so a stale NSUUID surfaces fast (D.4).
          _armAutoConnect();
        } else {
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
    _event('auto-reconnect: autoConnect armed (iOS)');
    unawaited(_ble.connect(id, autoConnect: true).catchError((Object _) {}));
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final id = _desiredDeviceId;
    if (id == null) return;
    // D.4: cap the auto-reconnect loop. A stale (iOS) id never resolves, so an
    // uncapped loop would re-arm forever; after [maxReconnectAttempts] we give
    // up and surface a real error within seconds.
    if (_reconnectAttempts >= maxReconnectAttempts) {
      _lastError = 'reconnect_exhausted';
      _event('auto-reconnect gave up after $_reconnectAttempts attempts '
          '(stale device?)');
      notifyListeners();
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
    _linkSub?.cancel();
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
