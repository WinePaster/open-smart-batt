/// Open-RCE-Batt — BLE transport service (flutter_blue_plus).
///
/// The single object that talks to the battery over BLE. Everything above it
/// (the State controllers) consumes only its streams + methods; everything
/// below it (wire encode/decode) is the pure-Dart `protocol/` layer.
///
/// Responsibilities (CAPTURE_VERIFIED §1/§6, PROTOCOL.md §2/§3):
///   * Scan filtered on the vendor service UUID 07b9fff0-… (no name filter).
///   * Connect, discover the write char 07b9ace3-… and notify char 07b9ace4-…
///   * Enable notifications (write 01 00 to the CCCD via `setNotifyValue`).
///   * Reassemble every notification chunk into ONE byte stream
///     ([FrameReassembler]) and decode telemetry ([TelemetryDecoder]).
///   * Drive a ~1 Hz keep-alive writing the single byte 0x23 to make the
///     battery stream telemetry.
///   * No MTU negotiation (connect with `mtu: null`); Write-Without-Response
///     only for every write/keep-alive.
///
/// SAFETY: only the documented release (mode 0x06 + auth) is proven-safe.
/// [switchMode] is generic by design (the protocol layer builds any mode); the
/// caller (controller/UI) is responsible for gating which mode codes are sent.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/log_entry.dart' show LogDirection;
import '../models/telemetry_sample.dart';
import '../protocol/protocol.dart';
import 'ble_models.dart';

/// Owns the one BLE connection and exposes telemetry + control.
///
/// Single-connection model: connecting while already connected first tears the
/// previous link down. Not safe to share across isolates.
class BleService {
  BleService({CommandBuilder commands = const CommandBuilder()}) {
    _commands = commands;
    // One persistent listener turns plugin scan results into [DiscoveredDevice].
    _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
  }

  late final CommandBuilder _commands;

  // ---- wire codec (pure Dart) ----
  final FrameReassembler _reassembler = FrameReassembler();
  final TelemetryDecoder _decoder = TelemetryDecoder();

  // ---- plugin handles for the live connection ----
  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _keepAlive;
  bool _settingUp = false;
  bool _retryingConnect = false;

  // Cached guids (cheap, but build once).
  static final Guid _serviceGuid = Guid(Gatt.serviceUuid);
  static final Guid _writeGuid = Guid(Gatt.writeCharUuid);
  static final Guid _notifyGuid = Guid(Gatt.notifyCharUuid);

  /// Keep-alive cadence (~1 Hz). The battery streams telemetry as long as it
  /// keeps receiving the `#` byte; exact cadence is not protocol-critical.
  static const Duration keepAliveInterval = Duration(seconds: 1);

  // ---- outbound streams ----
  final StreamController<TelemetrySample> _telemetry =
      StreamController<TelemetrySample>.broadcast();
  final StreamController<BleLinkState> _link =
      StreamController<BleLinkState>.broadcast();
  final StreamController<List<DiscoveredDevice>> _scan =
      StreamController<List<DiscoveredDevice>>.broadcast();
  final StreamController<BlePacketEvent> _packets =
      StreamController<BlePacketEvent>.broadcast();

  BleLinkState _state = BleLinkState.disconnected;
  final Map<String, DiscoveredDevice> _scanSeen = {};

  /// Decoded telemetry snapshots — one per inbound register update.
  Stream<TelemetrySample> get telemetry => _telemetry.stream;

  /// Connection lifecycle.
  Stream<BleLinkState> get linkState => _link.stream;

  /// Deduplicated scan results (filtered on the vendor service).
  Stream<List<DiscoveredDevice>> get scanResults => _scan.stream;

  /// Raw TX/RX wire events for the diagnostics packet log (DEFAULT OFF — the
  /// controller decides whether to subscribe/persist).
  Stream<BlePacketEvent> get packets => _packets.stream;

  /// Adapter (radio) on/off/unauthorized state.
  Stream<BluetoothAdapterState> get adapterState =>
      FlutterBluePlus.adapterState;

  /// Current link state (latest value of [linkState]).
  BleLinkState get currentState => _state;

  /// Latest accumulated telemetry snapshot (folds prior frames).
  TelemetrySample get currentSample => _decoder.sample;

  /// Remote id of the connected/connecting device, or null.
  String? get connectedDeviceId => _device?.remoteId.str;

  /// Advertised name of the connected device (e.g. "RCE-SCAP_II"), or ''.
  String get connectedDeviceName => _device?.platformName ?? '';

  /// True while a scan is in progress.
  bool get isScanning => FlutterBluePlus.isScanningNow;

  /// Live scanning flag stream.
  Stream<bool> get scanning => FlutterBluePlus.isScanning;

  // ---------------------------------------------------------------------------
  // Permissions / adapter
  // ---------------------------------------------------------------------------

  /// Requests the runtime permissions BLE needs. On Android 12+ the critical
  /// pair is BLUETOOTH_SCAN + BLUETOOTH_CONNECT; pre-12 devices fall back to
  /// location for scanning. Returns true when scanning + connecting are allowed.
  Future<bool> ensurePermissions() async {
    if (!Platform.isAndroid) return true; // iOS prompts on first BLE use.

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectOk =
        statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    final locationOk =
        statuses[Permission.locationWhenInUse]?.isGranted ?? false;

    // On Android 12+, bluetoothScan/Connect are the source of truth. On <12 the
    // plugin reports those as granted and gates scanning on location instead.
    return (scanOk && connectOk) || locationOk;
  }

  /// True if the Bluetooth adapter is currently on.
  Future<bool> isAdapterOn() async {
    if (await FlutterBluePlus.isSupported == false) return false;
    return FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  /// Start scanning. We deliberately do NOT pass `withServices`: many devices
  /// (incl. this hardware) do not advertise their 128-bit service UUID in the
  /// advertisement packet, so an OS-level service filter would hide them. We
  /// scan everything and filter in [_onScanResults] (keep named devices and any
  /// that DO advertise the vendor service). Results arrive on [scanResults].
  Future<void> startScan(
      {Duration timeout = const Duration(seconds: 15)}) async {
    if (FlutterBluePlus.isScanningNow) return;
    _scanSeen.clear();
    _scan.add(const []);
    await FlutterBluePlus.startScan(
      timeout: timeout,
      androidScanMode: AndroidScanMode.lowLatency,
    );
  }

  /// Stop an in-progress scan.
  Future<void> stopScan() async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
  }

  void _onScanResults(List<ScanResult> results) {
    var changed = false;
    for (final r in results) {
      final id = r.device.remoteId.str;
      final name = r.device.platformName.isNotEmpty
          ? r.device.platformName
          : r.advertisementData.advName;
      // RCE if it advertises our service UUID (most precise) OR its name starts
      // with "RCE" (e.g. RCE-SCAP_II). Either signal flags it as a vendor device.
      final isVendor =
          r.advertisementData.serviceUuids.contains(_serviceGuid) ||
              name.toUpperCase().startsWith('RCE');
      final existing = _scanSeen[id];
      if (existing == null ||
          existing.rssi != r.rssi ||
          existing.name != name ||
          existing.isVendor != isVendor) {
        _scanSeen[id] = DiscoveredDevice(
          id: id,
          name: name,
          rssi: r.rssi,
          isVendor: isVendor,
        );
        changed = true;
      }
    }
    if (changed) {
      // RCE (vendor) devices first, then by signal strength.
      final list = _scanSeen.values.toList()
        ..sort((a, b) {
          if (a.isVendor != b.isVendor) return a.isVendor ? -1 : 1;
          return b.rssi.compareTo(a.rssi);
        });
      _scan.add(list);
    }
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  /// Connect to [deviceId], discover the GATT characteristics, enable notify,
  /// and begin streaming telemetry + keep-alives. Tears down any prior link
  /// first. Emits [BleLinkState] transitions on [linkState].
  Future<void> connect(String deviceId,
      {Duration timeout = const Duration(seconds: 20)}) async {
    await disconnect();
    await stopScan();

    _reassembler.reset();
    _decoder.reset();
    _settingUp = false;

    final device = BluetoothDevice.fromId(deviceId);
    _device = device;
    _setState(BleLinkState.connecting);

    _connSub = device.connectionState.listen(_onConnectionState);

    // Android BLE frequently fails the FIRST connect attempt (connects then
    // immediately disconnects). Retry a few times so the user taps only once;
    // suppress teardown on transient drops during the retry window.
    _retryingConnect = true;
    Object? lastErr;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        // mtu:null => no MTU negotiation (work within the default ATT MTU 23).
        await device.connect(mtu: null, timeout: timeout);
        lastErr = null;
        break;
      } catch (e) {
        lastErr = e;
        if (attempt < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
      }
    }
    _retryingConnect = false;
    if (lastErr != null) {
      await _teardown(emitDisconnected: true);
      throw lastErr;
    }
  }

  Future<void> _onConnectionState(BluetoothConnectionState s) async {
    if (s == BluetoothConnectionState.connected) {
      await _setupConnection();
    } else if (s == BluetoothConnectionState.disconnected) {
      // Ignore transient drops while still retrying the initial connect.
      if (_retryingConnect) return;
      await _teardown(emitDisconnected: true);
    }
  }

  Future<void> _setupConnection() async {
    final device = _device;
    if (device == null || _settingUp || _state == BleLinkState.ready) return;
    _settingUp = true;
    _setState(BleLinkState.connected);

    try {
      final services = await device.discoverServices();
      _writeChar = null;
      _notifyChar = null;

      // Prefer characteristics under the vendor service, but fall back to a
      // full sweep — the service linkage is inferred, not byte-fixed.
      for (final svc in services) {
        final preferred = svc.uuid == _serviceGuid;
        for (final c in svc.characteristics) {
          if (c.uuid == _writeGuid && (_writeChar == null || preferred)) {
            _writeChar = c;
          }
          if (c.uuid == _notifyGuid && (_notifyChar == null || preferred)) {
            _notifyChar = c;
          }
        }
      }

      final notify = _notifyChar;
      if (_writeChar == null || notify == null) {
        throw StateError(
            'GATT characteristics not found (write=${_writeChar != null}, '
            'notify=${notify != null})');
      }

      // Subscribe BEFORE the first write (PROTOCOL.md §2). setNotifyValue(true)
      // writes the CCCD enable value [0x01, 0x00].
      _notifySub = notify.onValueReceived.listen(_onNotify);
      await notify.setNotifyValue(true);

      _startKeepAlive();
      _setState(BleLinkState.ready);
    } catch (e) {
      await _teardown(emitDisconnected: true);
      rethrow;
    } finally {
      _settingUp = false;
    }
  }

  void _onNotify(List<int> chunk) {
    _packets.add(BlePacketEvent(LogDirection.rx, List<int>.unmodifiable(chunk)));
    final frames = _reassembler.addBytes(chunk);
    final now = DateTime.now();
    var emitted = false;
    for (final f in frames) {
      if (!f.checksumOk) continue;
      final before = _decoder.sample;
      final after = _decoder.ingest(f, at: now);
      if (!identical(before, after)) {
        emitted = true;
      }
    }
    if (emitted) {
      _telemetry.add(_decoder.sample);
    }
  }

  /// Disconnect the current device and reset state.
  Future<void> disconnect() async {
    final device = _device;
    if (device == null) return;
    _setState(BleLinkState.disconnecting);
    try {
      await device.disconnect();
    } catch (_) {
      // Ignore: teardown still proceeds via the connectionState callback.
    }
    await _teardown(emitDisconnected: true);
  }

  Future<void> _teardown({required bool emitDisconnected}) async {
    _keepAlive?.cancel();
    _keepAlive = null;
    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    _writeChar = null;
    _notifyChar = null;
    _device = null;
    _settingUp = false;
    _reassembler.reset();
    if (emitDisconnected) {
      _setState(BleLinkState.disconnected);
    }
  }

  // ---------------------------------------------------------------------------
  // Keep-alive
  // ---------------------------------------------------------------------------

  void _startKeepAlive() {
    _keepAlive?.cancel();
    // Tick immediately so telemetry starts without waiting a full second.
    unawaited(_sendKeepAlive());
    _keepAlive = Timer.periodic(keepAliveInterval, (_) {
      unawaited(_sendKeepAlive());
    });
  }

  Future<void> _sendKeepAlive() async {
    if (_writeChar == null) return;
    try {
      await writeCommand(_commands.keepAlive());
    } catch (_) {
      // A failed keep-alive usually means the link dropped; the
      // connectionState callback handles teardown.
    }
  }

  // ---------------------------------------------------------------------------
  // Outbound commands
  // ---------------------------------------------------------------------------

  /// Write raw bytes to the write characteristic (Write-Without-Response).
  /// Throws [StateError] if not connected.
  Future<void> writeCommand(List<int> bytes) async {
    final c = _writeChar;
    if (c == null) {
      throw StateError('writeCommand: not connected / write char unresolved');
    }
    await c.write(bytes, withoutResponse: true);
    _packets.add(BlePacketEvent(LogDirection.tx, List<int>.unmodifiable(bytes)));
  }

  /// Switch mode (PROTOCOL.md §6.2): writes the mode sub-frame ++ auth
  /// sub-frame in one 15-byte write. [cb] is the device's dealer-derived echo
  /// (selector 0x27) and [pwSum] the cut-off password char-code checksum — both
  /// per-device runtime inputs, never hardcoded.
  ///
  /// SAFETY: the caller must gate which [mode] values are sent; only the
  /// documented release (mode 0x06 + auth) is proven safe.
  Future<void> switchMode(int mode,
      {required int cb, required int pwSum}) async {
    final creds = AuthCredentials(cb: cb, pwSum: pwSum);
    await writeCommand(_commands.switchMode(mode, creds));
  }

  /// Verify-auth standalone (CAPTURE_VERIFIED §6 step 5): the 9-byte auth frame
  /// the reference app sends ~2 s before a bundled mode+auth.
  Future<void> sendAuth({required int cb, required int pwSum}) async {
    final creds = AuthCredentials(cb: cb, pwSum: pwSum);
    await writeCommand(_commands.auth(creds));
  }

  /// Set warning thresholds in physical units (PROTOCOL.md §8.3 write inverse).
  Future<void> setThresholds({
    required double ovVolts,
    required double uvVolts,
    required double otCelsius,
    int trailing = 0x00,
  }) async {
    await writeCommand(_commands.thresholds(
      ovVolts: ovVolts,
      uvVolts: uvVolts,
      otCelsius: otCelsius,
      trailing: trailing,
    ));
  }

  /// Set warning thresholds from raw register bytes.
  Future<void> setThresholdsRaw(int ovByte, int uvByte, int otByte,
      {int trailing = 0x00}) async {
    await writeCommand(
        _commands.thresholdsRaw(ovByte, uvByte, otByte, trailing: trailing));
  }

  /// Send one keep-alive byte (0x23) on demand.
  Future<void> pokeKeepAlive() => _sendKeepAlive();

  // ---------------------------------------------------------------------------

  void _setState(BleLinkState s) {
    if (_state == s) return;
    _state = s;
    _link.add(s);
  }

  /// Release all resources. The service is unusable afterwards.
  Future<void> dispose() async {
    await _teardown(emitDisconnected: false);
    await _scanSub?.cancel();
    _scanSub = null;
    await _telemetry.close();
    await _link.close();
    await _scan.close();
    await _packets.close();
  }
}
