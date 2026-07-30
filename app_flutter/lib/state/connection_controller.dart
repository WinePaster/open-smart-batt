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
  }) {
    _settings = settings;
    _devices = devices;
    _logs = logs;
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
  /// [_updateMonitor]'s job; the two were conflated under one setting until
  /// design 0008 split them.
  void _updateWakelock() {
    final shouldKeep = isOnline && _settings.keepScreenAwake;
    // Fire-and-forget; ignore platform errors (e.g. in unit tests / unsupported
    // platforms where the plugin channel is absent).
    WakelockPlus.toggle(enable: shouldKeep).catchError((_) {});
  }

  /// Start/stop the foreground service that keeps this process at foreground
  /// importance while connected (design 0008). Without it the OS freezes the
  /// process once the screen goes off and the 1 Hz keep-alive stops firing.
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

  /// True while the foreground service is up (design 0008). Exposed so the UI
  /// can explain a stall differently depending on whether it was even enabled.
  bool get monitorRunning => _monitorRunning;
  late final SettingsController _settings;
  late final DeviceController? _devices;
  LogRepo? _logs;
  late final SessionContext _session;

  /// Which unit/connection recorded rows are attributed to (design 0006).
  /// Shared with [TelemetryController] so both stamp the same identity.
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
  void _event(String message, {String? deviceId}) {
    final logs = _logs;
    if (logs == null) return;
    unawaited(logs.insertLog(
      LogEntry.event(
        message,
        deviceId: deviceId ?? _session.deviceId,
        sessionId: _session.sessionId,
        appBuild: _appBuild,
      ),
      maxBytes: _settings.logMaxBytes,
    ));
  }

  /// Build that is recording, stamped on every row (design 0010). Null in
  /// tests and on hosts where the plugin channel is unavailable.
  String? _appBuild;

  StreamSubscription<BleLinkState>? _linkSub;
  StreamSubscription<List<DiscoveredDevice>>? _scanSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<TelemetrySample>? _telemetrySub;
  StreamSubscription<void>? _monitorStopSub;

  /// Product-class resolver (design 0007). Reads the class off the wire
  /// device-type byte; holds the user's choice only for unrecognised bytes.
  final PackClassResolver _packResolver = PackClassResolver();
  ProductClass _packLabel = ProductClass.unknown;

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

  // ---- product class / cosmetic pack label (design 0001 §3.1 / §3.4) ----

  /// The DETERMINISTIC routing class from the device-type byte: power bank, or
  /// [ProductClass.unknown] for any pack. This is the ONLY class allowed to pick
  /// a layout (design 0001 §3.1), and the SINGLE source of truth shared by
  /// routing ([DashboardRouter]), persistence ([_recomputePackLabel]) and
  /// capability gating ([capabilities]) — no controller derives the class
  /// independently.
  ProductClass get resolvedClass => _packResolver.deviceClass;

  /// True only for a confirmed power bank (device-type 0x22) — the sole
  /// deterministic routing signal. Read straight off the resolver so routing can
  /// never disagree with persistence.
  bool get isPowerBank => _packResolver.deviceClass.isPowerBank;

  /// Per-class capabilities that gate the pack dashboard controls (檢測電容 /
  /// 解除斷電 / 防盜), design 0004 §3.2. This is GATING, never routing.
  ///
  /// All three classes now come off the wire (design 0007), so [packLabel] is
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
  Future<void> connect(String deviceId, {Duration? timeout}) async {
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0; // fresh manual connect resets the backoff
    _manualDisconnect = false;
    _desiredDeviceId = deviceId;
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
      await connect(targetId);
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
    _reconnectTimer?.cancel();
    await _ble.disconnect();
  }

  // ---- commands (UI gates which modes are sent) ------------------------

  /// Raw write (Write-Without-Response).
  Future<void> writeCommand(List<int> bytes) => _ble.writeCommand(bytes);

  /// Release: mode 0x00 (normal) + auth in one 15-byte write.
  ///
  /// 🔴 **Was 0x06 until 2026-07-30 (design 0024).** Labelled captures of two
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
  /// is why callers verify the result against 0x23 rather than reporting
  /// success (design 0024 §2.2).
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

  void _onLinkState(BleLinkState s) {
    final wasOnline = _link == BleLinkState.ready;
    _link = s;
    // design 0006: open the recording session BEFORE logging this transition, so
    // the `link: ready` line itself is already attributed to the unit. The
    // session is closed further down, AFTER the disconnect line is written.
    //
    // design 0019: start at `connecting`, not at `ready`. Notifications are
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
    if (s == BleLinkState.connecting ||
        s == BleLinkState.connected ||
        s == BleLinkState.ready) {
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
      // Stamp last-seen on the saved entry (if any). This is only the OPENING
      // stamp; [_onTelemetrySample] keeps it moving while the link lives and
      // the disconnect branch below closes it out — see [_touchLastSeen].
      final id = _ble.connectedDeviceId;
      if (id != null) {
        _touchLastSeen(id, force: true);
        // Seed from the saved record so the chip is right immediately, before
        // the first device-type frame lands. It is only a SEED: the wire byte
        // overrides it a moment later (design 0007 §3.3), which is what heals a
        // record saved wrong while the old fingerprint was guessing.
        final savedLabel = _devices?.deviceFor(id)?.productClass;
        if (savedLabel != null && savedLabel != ProductClass.unknown) {
          _packResolver.setOverride(savedLabel);
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
    _packResolver.observe(s);
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
    unawaited(_devices?.touch(id, lastSeen: now));
  }

  /// Recompute the cosmetic pack label; notify + persist only on a real change
  /// (the settling window and fingerprint each flip at most once per session).
  void _recomputePackLabel() {
    final next = _packResolver.label;
    if (next == _packLabel) return;
    _packLabel = next;
    // Persist the class onto the saved record (design 0001 §5 Phase 5). This is
    // also the SELF-HEAL for design 0007: a unit stored as the wrong class while
    // the fingerprint was guessing gets corrected the moment its wire byte
    // arrives — the user does not have to fix it by hand.
    if (next != ProductClass.unknown) {
      final id = _ble.connectedDeviceId;
      if (id != null) {
        unawaited(_devices?.setProductClass(id, next));
      }
    }
    notifyListeners();
  }

  void _onScanResults(List<DiscoveredDevice> results) {
    _scanResults = results;
    notifyListeners();
  }

  /// Record a capture state mark (design 0013).
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
  /// start (design 0013 Phase 2).
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
      // design 0015: the roster is written BEFORE any UI filtering, which is
      // the whole point — it has to contain the entries the list hides. Without
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
