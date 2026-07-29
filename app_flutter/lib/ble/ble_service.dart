/// OpenSmartBatt — BLE transport service (flutter_blue_plus).
///
/// The single object that talks to the battery over BLE. Everything above it
/// (the State controllers) consumes only its streams + methods; everything
/// below it (wire encode/decode) is the pure-Dart `protocol/` layer.
///
/// Responsibilities (live HCI capture, PROTOCOL.md §2/§3):
///   * Scan filtered on the vendor service UUID 07b9fff0-… (no name filter).
///   * Connect, discover the write char 07b9ace3-… and notify char 07b9ace4-…
///   * Enable notifications (write 01 00 to the CCCD via `setNotifyValue`).
///   * Reassemble every notification chunk into ONE byte stream
///     ([FrameReassembler]) and decode telemetry ([TelemetryDecoder]).
///   * Drive a ~1 Hz keep-alive on a tick-counted schedule (PROTOCOL.md §2):
///     `!#` on tick 1 (+ every 5th tick for a power bank), `@` every 25th tick,
///     `#` otherwise — this is what makes the battery stream telemetry (and a
///     power bank stream SOC / port state).
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
  BleService({
    CommandBuilder commands = const CommandBuilder(),
    MetadataParser parser = const NoopMetadataParser(),
  }) {
    _commands = commands;
    _decoder = TelemetryDecoder(parser: parser);
    // One persistent listener turns plugin scan results into [DiscoveredDevice].
    _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
  }

  late final CommandBuilder _commands;

  // ---- wire codec (pure Dart) ----
  final FrameReassembler _reassembler = FrameReassembler();
  late final TelemetryDecoder _decoder;

  // ---- plugin handles for the live connection ----
  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _keepAlive;
  int _keepAliveTick = 0;
  bool _settingUp = false;
  bool _retryingConnect = false;

  /// Human-readable reason for the most recent disconnect (flutter_blue_plus
  /// [DisconnectReason]: code + description), or null if none/unknown. Surfaced
  /// so the controller can log WHY a link dropped (supervision timeout vs a
  /// peripheral-initiated close), which is what on-device disconnect debugging
  /// needs. Cross-platform.
  String? _lastDisconnect;

  /// The most recent disconnect reason (see [_lastDisconnect]).
  String? get lastDisconnect => _lastDisconnect;

  // Cached guids (cheap, but build once).
  static final Guid _serviceGuid = Guid(Gatt.serviceUuid);
  static final Guid _writeGuid = Guid(Gatt.writeCharUuid);
  static final Guid _notifyGuid = Guid(Gatt.notifyCharUuid);

  /// Keep-alive cadence (~1 Hz). The battery streams telemetry as long as it
  /// keeps receiving a poll token; exact cadence is not protocol-critical.
  static const Duration keepAliveInterval = Duration(seconds: 1);

  /// Write timeout for a keep-alive poke.
  ///
  /// flutter_blue_plus defaults to 15 s, which is 15 poll periods — a stalled
  /// write sat there long past the point the tick was useful, and the error
  /// only surfaced once the app resumed. A few periods is enough to tell
  /// "this write is not coming back" without being trigger-happy.
  static const Duration keepAliveWriteTimeout = Duration(seconds: 5);

  /// No inbound frame for this long, while the link still reports ready, means
  /// telemetry has stalled — the readouts on screen are stale even though the
  /// connection looks healthy. Observed cause: Android suspending the app
  /// (screen off / background), where RX and TX stop together for minutes and
  /// then flush a backlog. Deliberately several poll periods so a momentary gap
  /// does not flap the indicator.
  static const Duration telemetryStallThreshold = Duration(seconds: 8);

  /// Pure keep-alive scheduler (PROTOCOL.md §2). Selects which poll token to
  /// write for a given 1-based [tick] and whether the connected unit is a power
  /// bank (device-type 0x22, from decoded telemetry). Extracted as a static pure
  /// function so the schedule is unit-testable without a live connection.
  ///
  /// Order (per PROTOCOL.md §2 — the metadata poll is checked BEFORE the
  /// power-bank extended poll, so a tick that is both %25 and %5 sends `@`):
  ///   * tick == 1          -> `!#` (0x21 0x23) — every device, once.
  ///   * %25 == 0            -> `@`  (0x40) — slow metadata (all devices).
  ///   * power bank & %5==0  -> `!#` — continuous SOC / port refresh.
  ///   * otherwise           -> `#`  (0x23).
  static List<int> keepAliveTokenFor(
    CommandBuilder commands, {
    required int tick,
    required bool isPowerBank,
  }) {
    if (tick <= 1) return commands.extendedPoll();
    if (tick % 25 == 0) return commands.slowMetadataPoll();
    if (isPowerBank && tick % 5 == 0) return commands.extendedPoll();
    return commands.keepAlive();
  }

  /// Per-platform connect tuning (D.4). Android's `connectGatt` fails fast on a
  /// stale handle and frequently bounces on the FIRST attempt, so a few retries
  /// at a generous timeout are appropriate. iOS's `connectPeripheral` has NO
  /// native timeout (it waits forever) and a stale/uncached NSUUID never
  /// resolves, so we use a SINGLE attempt at a SHORT timeout — that way a stale
  /// saved id surfaces an error in seconds instead of 3×20s = 60s of frozen
  /// spinner. Both are pure functions of the platform for unit-testing.
  static const Duration androidConnectTimeout = Duration(seconds: 20);
  static const Duration iosConnectTimeout = Duration(seconds: 8);

  /// Number of connect attempts to make on [isIOS]. iOS = 1 (no native
  /// timeout, retrying only multiplies the freeze); Android = 3 (connect-bounce
  /// recovery).
  static int connectAttemptsFor({required bool isIOS}) => isIOS ? 1 : 3;

  /// Connect timeout to use on [isIOS].
  static Duration connectTimeoutFor({required bool isIOS}) =>
      isIOS ? iosConnectTimeout : androidConnectTimeout;

  // ---- outbound streams ----
  final StreamController<TelemetrySample> _telemetry =
      StreamController<TelemetrySample>.broadcast();
  final StreamController<DeviceMetadata> _deviceMetadata =
      StreamController<DeviceMetadata>.broadcast();
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

  /// Device-metadata snapshots. On the open build the
  /// injected parser is [NoopMetadataParser], so this stream never emits and the
  /// value stays [EmptyDeviceMetadata]. A closed build injects a real parser.
  Stream<DeviceMetadata> get deviceMetadata => _deviceMetadata.stream;

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

  /// Latest accumulated engineering metadata (opaque; empty on the open build).
  DeviceMetadata get currentDeviceInfo => _decoder.deviceMetadata;

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

  /// Request POST_NOTIFICATIONS (Android 13+) for the background-monitor
  /// notification (design 0008).
  ///
  /// Deliberately returns void and never throws: the caller must not gate the
  /// foreground service on the outcome. Denying it hides the notification but
  /// leaves monitoring — and the BLE link — running.
  Future<void> ensureNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await Permission.notification.request();
    } catch (_) {
      // No plugin channel (tests) or an OEM that rejects the request.
    }
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
    // D.1: on iOS the CBCentralManager transitions `.unknown` → `.poweredOn`
    // asynchronously (a few hundred ms after first init, and only once the
    // permission dialog is resolved). Calling startScan before the adapter is
    // on throws a FlutterBluePlusException — so wait (bounded) for `on` first.
    await _awaitAdapterOn(const Duration(seconds: 6));
    _scanSeen.clear();
    _scan.add(const []);
    // D.1: do NOT swallow the "Bluetooth must be turned on" / unauthorized
    // failure — let it propagate so the controller can surface a real UI error
    // (and distinguish off vs unauthorized via the adapter state).
    await FlutterBluePlus.startScan(
      timeout: timeout,
      androidScanMode: AndroidScanMode.lowLatency,
    );
  }

  /// Wait until the Bluetooth adapter reports `on`, bounded by [timeout]. On
  /// timeout we fall through (the subsequent startScan will throw the
  /// FlutterBluePlusException the caller surfaces).
  Future<void> _awaitAdapterOn(Duration timeout) async {
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on) return;
    try {
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(timeout);
    } on TimeoutException {
      // Fall through — startScan will throw and the controller reports it.
    }
  }

  /// Deep-link to the OS app-settings page (D.2): used when Bluetooth
  /// permission is `unauthorized` so the user can grant it. Returns true if the
  /// settings page was opened.
  Future<bool> openBluetoothSettings() => openAppSettings();

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
      // Vendor if it advertises our service UUID (most precise) OR its name
      // carries a vendor token. See [looksLikeVendorName] for why this is a
      // token-prefix match rather than `startsWith` or `contains`.
      final isVendor =
          r.advertisementData.serviceUuids.contains(_serviceGuid) ||
              looksLikeVendorName(name);
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
      {Duration? timeout, bool autoConnect = false}) async {
    await disconnect();
    await stopScan();

    _reassembler.reset();
    _decoder.reset();
    _settingUp = false;

    final device = BluetoothDevice.fromId(deviceId);
    _device = device;
    _setState(BleLinkState.connecting);

    _connSub = device.connectionState.listen(_onConnectionState);

    if (autoConnect) {
      // Seamless reconnect: register a PENDING connection and let the OS
      // (CoreBluetooth on iOS) reconnect the moment the peripheral reappears.
      // connect() returns immediately here — the connectionState listener above
      // drives setup once actually connected. mtu must be null with autoConnect;
      // there is no timeout and no app-level retry loop (the OS holds it). Used
      // only for re-connecting a link that was previously healthy (a dropped,
      // known-good device), never for a first connect to a possibly-stale id.
      _retryingConnect = false;
      try {
        await device.connect(mtu: null, autoConnect: true);
      } catch (e) {
        await _teardown(emitDisconnected: true);
        rethrow;
      }
      return;
    }

    // D.4: platform-gate the retry. Android BLE frequently fails the FIRST
    // connect attempt (connects then immediately disconnects) and fails fast on
    // a stale handle, so retrying a few times lets the user tap only once. iOS
    // has no native connect timeout and a stale NSUUID never resolves, so a
    // single short-timeout attempt surfaces the error in seconds instead of
    // multiplying the freeze. Suppress teardown on transient drops during the
    // (Android) retry window.
    final isIOS = Platform.isIOS;
    final attempts = connectAttemptsFor(isIOS: isIOS);
    final effTimeout = timeout ?? connectTimeoutFor(isIOS: isIOS);
    _retryingConnect = attempts > 1;
    Object? lastErr;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        // mtu:null => no MTU negotiation (work within the default ATT MTU 23).
        await device.connect(mtu: null, timeout: effTimeout);
        lastErr = null;
        break;
      } catch (e) {
        lastErr = e;
        if (attempt < attempts) {
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
      // Capture WHY the link dropped (A: cross-platform disconnect diagnostics)
      // before teardown clears the device handle.
      final r = _device?.disconnectReason;
      _lastDisconnect =
          r == null ? null : 'code=${r.code} ${r.description ?? ''}'.trim();
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

      // Diagnostic: dump the full GATT table (svc/char UUID + properties) to the
      // capture log. Confirmed the metadata burst (VADJ 0x30 / dealer 0x27) rides
      // the single notify char ace4 — there is NO second notify channel
      // (PROTOCOL.md §8.5), so we subscribe to ace4 only.
      _dumpGatt(services);

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

  /// Handle a notification chunk from a characteristic.
  void _onNotify(List<int> chunk) {
    _packets.add(BlePacketEvent(LogDirection.rx, List<int>.unmodifiable(chunk)));
    final frames = _reassembler.addBytes(chunk);
    final now = DateTime.now();
    final infoBefore = _decoder.deviceMetadata;
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
    // Device-metadata side-channel. On the open build
    // the Noop parser never changes it, so this never fires.
    if (!identical(infoBefore, _decoder.deviceMetadata)) {
      _deviceMetadata.add(_decoder.deviceMetadata);
    }
  }

  /// Emit a diagnostic note line into the packet log (an EVT row).
  void _emitEvent(String message) {
    _packets.add(BlePacketEvent(LogDirection.event, const [], note: message));
  }

  /// Dump every service/characteristic (UUID + property flags) to the log, so a
  /// second notify channel is visible. Diagnostic only.
  void _dumpGatt(List<BluetoothService> services) {
    _emitEvent('GATT dump: ${services.length} service(s)');
    for (final svc in services) {
      for (final c in svc.characteristics) {
        final p = c.properties;
        final flags = [
          if (p.read) 'R',
          if (p.write) 'W',
          if (p.writeWithoutResponse) 'w',
          if (p.notify) 'N',
          if (p.indicate) 'I',
        ].join();
        _emitEvent('GATT svc=${svc.uuid.str} char=${c.uuid.str} [$flags]');
      }
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
    _keepAliveTick = 0;
    await _notifySub?.cancel();
    _notifySub = null;
    _keepAliveWriteFailed = false;
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
    _keepAliveTick = 0;
    // Tick immediately so telemetry starts without waiting a full second. The
    // first tick sends `!#`, which every device answers with device-type/SOC.
    unawaited(_sendKeepAlive());
    _keepAlive = Timer.periodic(keepAliveInterval, (_) {
      unawaited(_sendKeepAlive());
    });
  }

  Future<void> _sendKeepAlive() async {
    if (_writeChar == null) return;
    // Re-entrancy guard. The timer fires every second but a write can hang far
    // longer — when Android suspends the app (screen off / background) BOTH
    // directions stall for minutes, then everything resumes at once. Without
    // this guard each stalled second queued another write, so a 2.5-minute
    // freeze piled up ~150 of them and they all landed on resume.
    if (_keepAliveInFlight) return;
    _keepAliveInFlight = true;
    _keepAliveTick++;
    // Whether the connected unit is a power bank is read from the LATEST decoded
    // telemetry (device-type 0x22); it flips true once the tick-1 `!#` elicits
    // the 0x10 frame, after which the every-5th `!#` schedule kicks in.
    final token = keepAliveTokenFor(
      _commands,
      tick: _keepAliveTick,
      isPowerBank: _decoder.sample.isPowerBank,
    );
    final sw = Stopwatch()..start();
    try {
      await writeCommand(token, timeout: keepAliveWriteTimeout);
      // Recovery is as diagnostic as the failure: it bounds how long the app
      // was actually unable to poll, which a lone failure line cannot.
      if (_keepAliveWriteFailed) {
        _emitEvent('keep-alive write recovered after '
            '$_keepAliveFailures consecutive failure(s)');
        _keepAliveWriteFailed = false;
        _keepAliveFailures = 0;
      }
    } catch (e) {
      // A failed keep-alive usually means the link dropped; the connectionState
      // callback handles teardown. Surface it once to the diagnostic log — a
      // silent catch here previously hid a write-mode bug that suppressed the
      // metadata burst.
      _keepAliveFailures++;
      if (!_keepAliveWriteFailed) {
        _keepAliveWriteFailed = true;
        // The elapsed time separates "the device rejected it" (fails fast) from
        // "nothing came back" (runs to the timeout) — the 2026-07-27 stalls were
        // the latter, and only the duration says so.
        _emitEvent(
            'keep-alive write failed after ${sw.elapsedMilliseconds}ms: $e');
      }
    } finally {
      _keepAliveInFlight = false;
    }
  }

  bool _keepAliveWriteFailed = false;
  bool _keepAliveInFlight = false;
  int _keepAliveFailures = 0;

  // ---------------------------------------------------------------------------
  // Outbound commands
  // ---------------------------------------------------------------------------

  /// Write raw bytes to the write characteristic. Throws [StateError] if not
  /// connected.
  ///
  /// The write char (ace3) advertises **Write (with response, 0x08)** but NOT
  /// Write-Without-Response (0x04). Forcing `withoutResponse: true` throws on
  /// flutter_blue_plus, which silently killed every keep-alive `#` (so the
  /// device never got the poke that triggers the connect metadata burst — VADJ /
  /// serial). Pick the mode from the characteristic's actual properties.
  Future<void> writeCommand(List<int> bytes, {Duration? timeout}) async {
    final c = _writeChar;
    if (c == null) {
      throw StateError('writeCommand: not connected / write char unresolved');
    }
    // Use Write-Without-Response only when the char actually supports it;
    // ace3 does not, so fall back to Write (with response).
    final woResp = c.properties.writeWithoutResponse;
    await c.write(
      bytes,
      withoutResponse: woResp,
      timeout: (timeout ?? const Duration(seconds: 15)).inSeconds,
    );
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

  /// Verify-auth standalone (live HCI capture): the 9-byte auth frame
  /// the reference app sends ~2 s before a bundled mode+auth.
  Future<void> sendAuth({required int cb, required int pwSum}) async {
    final creds = AuthCredentials(cb: cb, pwSum: pwSum);
    await writeCommand(_commands.auth(creds));
  }

  /// Set warning thresholds in physical units (PROTOCOL.md §8.3 write inverse).
  ///
  /// [trailing] is the frame's 4th byte (observed UT / under-temp). When
  /// null (the default) we **preserve the last-read UT byte** from telemetry
  /// (selector 0x2B, §8.5) instead of forcing 0x00 — so a user editing OV/UV/OT
  /// does not silently clobber the device's under-temp setting.
  Future<void> setThresholds({
    required double ovVolts,
    required double uvVolts,
    required double otCelsius,
    int? trailing,
  }) async {
    await writeCommand(_commands.thresholds(
      ovVolts: ovVolts,
      uvVolts: uvVolts,
      otCelsius: otCelsius,
      trailing: trailing ?? _decoder.sample.warnUtByte ?? 0x00,
    ));
  }

  /// Set warning thresholds from raw register bytes. [trailing] null preserves
  /// the last-read UT byte (see [setThresholds]).
  Future<void> setThresholdsRaw(int ovByte, int uvByte, int otByte,
      {int? trailing}) async {
    await writeCommand(_commands.thresholdsRaw(ovByte, uvByte, otByte,
        trailing: trailing ?? _decoder.sample.warnUtByte ?? 0x00));
  }

  /// Send one scheduled keep-alive token on demand (advances the tick counter).
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
    await _deviceMetadata.close();
    await _link.close();
    await _scan.close();
    await _packets.close();
  }
}
