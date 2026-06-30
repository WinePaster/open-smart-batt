/// Open-RCE-Batt — connection controller (mockup screens 1-3 connection flow).
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
import '../protocol/protocol.dart';
import 'device_controller.dart';
import 'settings_controller.dart';

/// Live BLE connection + scan state for the UI.
class ConnectionController extends ChangeNotifier {
  ConnectionController(
    this._ble, {
    required SettingsController settings,
    DeviceController? devices,
    LogRepo? logs,
  }) {
    _settings = settings;
    _devices = devices;
    _logs = logs;
    _linkSub = _ble.linkState.listen(_onLinkState);
    _scanSub = _ble.scanResults.listen(_onScanResults);
    _scanningSub = _ble.scanning.listen(_onScanning);
    _adapterSub = _ble.adapterState.listen(_onAdapterState);
    _settings.addListener(_updateWakelock);
  }

  /// Keep the screen awake while connected, when the user enabled the option
  /// (consumes SettingsController.backgroundKeepAlive). Re-evaluated on link
  /// state changes and whenever the setting toggles.
  void _updateWakelock() {
    final shouldKeep = isOnline && _settings.backgroundKeepAlive;
    // Fire-and-forget; ignore platform errors (e.g. in unit tests / unsupported
    // platforms where the plugin channel is absent).
    WakelockPlus.toggle(enable: shouldKeep).catchError((_) {});
  }

  final BleService _ble;
  late final SettingsController _settings;
  late final DeviceController? _devices;
  LogRepo? _logs;

  /// Record a connection/scan/error event to the diagnostic log (always on —
  /// these are cheap and are what users export when something fails).
  void _event(String message) {
    final logs = _logs;
    if (logs == null) return;
    unawaited(
        logs.insertLog(LogEntry.event(message), maxBytes: _settings.logMaxBytes));
  }

  StreamSubscription<BleLinkState>? _linkSub;
  StreamSubscription<List<DiscoveredDevice>>? _scanSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

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

    _event('connect → $deviceId');
    final ok = await _ble.ensurePermissions();
    if (!ok) {
      _lastError = 'permission_denied';
      _event('connect aborted: permission denied');
      notifyListeners();
      return;
    }
    try {
      await _ble.connect(deviceId, timeout: timeout);
    } catch (e) {
      _lastError = e.toString();
      _event('connect error: $e');
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
      _event('rebound saved id ${device.id} → $targetId (name=${device.name})');
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

  /// Documented-safe release: mode 0x06 + auth in one 15-byte write.
  /// This is the "解除斷電 / 檢測電容" action on the dashboard.
  Future<void> releaseCutOff({required int cb, required int pwSum}) =>
      _ble.switchMode(ModeArg.release, cb: cb, pwSum: pwSum);

  /// Generic mode switch — caller MUST gate which [mode] codes it sends.
  Future<void> switchMode(int mode,
          {required int cb, required int pwSum}) =>
      _ble.switchMode(mode, cb: cb, pwSum: pwSum);

  /// EXPERIMENTAL — send ONLY the mode sub-frame, skipping the auth frame.
  /// Unproven: the device MAY ignore commands without auth. Provided as a
  /// car-side fallback to test whether auth is actually required.
  Future<void> switchModeOnly(int mode) =>
      writeCommand(const CommandBuilder().modeSet(mode));

  /// EXPERIMENTAL release with no auth (mode 0x06 only). See [switchModeOnly].
  Future<void> releaseCutOffModeOnly() => switchModeOnly(ModeArg.release);

  /// Standalone verify-auth (9-byte auth frame).
  Future<void> sendAuth({required int cb, required int pwSum}) =>
      _ble.sendAuth(cb: cb, pwSum: pwSum);

  /// Set warning thresholds in physical units.
  Future<void> setThresholds({
    required double ovVolts,
    required double uvVolts,
    required double otCelsius,
    int trailing = 0x00,
  }) =>
      _ble.setThresholds(
        ovVolts: ovVolts,
        uvVolts: uvVolts,
        otCelsius: otCelsius,
        trailing: trailing,
      );

  /// Set warning thresholds from raw register bytes.
  Future<void> setThresholdsRaw(int ovByte, int uvByte, int otByte,
          {int trailing = 0x00}) =>
      _ble.setThresholdsRaw(ovByte, uvByte, otByte, trailing: trailing);

  /// Send one keep-alive byte on demand.
  Future<void> pokeKeepAlive() => _ble.pokeKeepAlive();

  // ---- stream handlers --------------------------------------------------

  void _onLinkState(BleLinkState s) {
    final wasOnline = _link == BleLinkState.ready;
    _link = s;
    _event('link: ${s.name}');

    if (s == BleLinkState.ready) {
      _lastError = null;
      _reconnectAttempts = 0; // healthy link clears the backoff counter
      // Stamp last-seen on the saved entry (if any).
      final id = _ble.connectedDeviceId;
      if (id != null) {
        unawaited(_devices?.touch(id, lastSeen: DateTime.now()));
      }
    } else if (s == BleLinkState.disconnected) {
      // Unexpected drop while we still want this device → try to reconnect.
      if (!_manualDisconnect &&
          _settings.autoReconnect &&
          _desiredDeviceId != null &&
          (wasOnline || _link == BleLinkState.disconnected)) {
        _scheduleReconnect();
      }
    }
    _updateWakelock();
    notifyListeners();
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

  void _onScanResults(List<DiscoveredDevice> results) {
    _scanResults = results;
    notifyListeners();
  }

  void _onScanning(bool scanning) {
    if (_scanning == scanning) return;
    _scanning = scanning;
    if (!scanning) _event('scan done: ${_scanResults.length} device(s)');
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
    _settings.removeListener(_updateWakelock);
    WakelockPlus.toggle(enable: false).catchError((_) {});
    _reconnectTimer?.cancel();
    _linkSub?.cancel();
    _scanSub?.cancel();
    _scanningSub?.cancel();
    _adapterSub?.cancel();
    super.dispose();
  }
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
