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

/// Everything that belongs to ONE BLE link, keyed by the unit it talks to.
///
/// Nothing here is new state: every field was a `BleService` field and is
/// reproduced verbatim. What changed is that they are no longer SHARED. Each
/// one has per-device semantics that a single shared instance silently
/// violates the moment a second link exists:
///
///   * [reassembler] — one byte stream per link. Feeding two peripherals'
///     notifications into one buffer splices a frame boundary from A into a
///     frame from B; the reassembler resyncs on the next 0xB8, so the damage is
///     silent dropped frames rather than an error.
///   * [decoder] — folds successive frames into ONE accumulated sample (DVOL
///     needs the last-seen VADJ). Two units share one snapshot otherwise.
///   * [keepAliveTick] — the poll schedule is per-device by definition
///     (PROTOCOL.md §2): `!#` on tick 1, `@` every 25th, and for a power bank
///     `!#` every 5th. `!#` is the only source of thirteen selectors, so a
///     shared counter does not merely skew the cadence — it means some unit
///     never gets asked.
///   * [keepAliveInFlight] — the re-entrancy guard that stops a 1 Hz timer
///     queueing a write per stalled second. Shared, one unit's hung write eats
///     another unit's tick.
///   * [epoch] / [settingUp] — the FB-39 guard is "has a NEWER connect taken
///     over the state I am about to write". With one link per unit, connecting
///     a third device must not abandon the setups of the other two.
///   * [keepAliveFailures] / [keepAliveWriteFailed] — "this link's writes are
///     not getting out". Shared, one unit's silence is reported as another's.
///
/// Deliberately private and deliberately not concurrent: today [BleService]
/// creates at most one of these at a time. This is the shape multi-device needs,
/// not multi-device itself.
class _LinkState {
  _LinkState({
    required this.deviceId,
    required this.device,
    required MetadataParser parser,
  }) : decoder = TelemetryDecoder(parser: parser);

  /// BLE remote id — the map key, and the attribution stamped on this link's
  /// packet events. Survives [device] being cleared by teardown, because a
  /// torn-down link still has to be able to say whose data it holds.
  final String deviceId;

  /// Plugin handle. Nulled by teardown (which is what "not connected" means to
  /// the single-link getters), while the rest of this object survives.
  BluetoothDevice? device;

  BluetoothCharacteristic? writeChar;
  BluetoothCharacteristic? notifyChar;
  StreamSubscription<BluetoothConnectionState>? connSub;
  StreamSubscription<List<int>>? notifySub;
  Timer? keepAlive;
  int keepAliveTick = 0;
  bool keepAliveInFlight = false;
  bool keepAliveWriteFailed = false;
  int keepAliveFailures = 0;

  /// FB-20 instrument: how long each SUCCESSFUL keep-alive write took.
  ///
  /// Only failures used to carry a duration, so the corpus could see the right
  /// tail (>=5 s) and nothing else — the body of the distribution was inferred
  /// from the tick quantisation instead of measured. That inference cannot tell
  /// "every write takes ~4.2 s" (a connection-parameter story) from "most take
  /// 1 s and one in five runs to 4.9 s" (a retransmission story), and the two
  /// call for different fixes. A histogram costs nine ints per link and settles
  /// it from field captures we already ask for.
  int writeOkCount = 0;
  int writeMsTotal = 0;
  int writeMsMax = 0;
  final List<int> writeMsBuckets =
      List<int>.filled(BleService.writeStatsBucketsMs.length + 1, 0);
  int writeStatsReported = 0;

  bool settingUp = false;
  bool retryingConnect = false;

  final FrameReassembler reassembler = FrameReassembler();
  final TelemetryDecoder decoder;

  /// FB-39: invalidates a connection setup that a newer connect/disconnect has
  /// superseded, so a slow unit cannot bring the app online under an identity
  /// the user has already moved away from. See [ConnectEpoch].
  final ConnectEpoch epoch = ConnectEpoch();
}

/// Owns the one BLE connection and exposes telemetry + control.
///
/// Single-connection model: connecting while already connected first tears the
/// previous link down. Not safe to share across isolates.
///
/// Per-link state lives in [_LinkState], keyed by device id, and [_links] holds
/// **0 or 1** entry — `connect()` still awaits `disconnect()` first, and no
/// caller can ask for a second concurrent link. The keying is structural
/// groundwork, not a capability: it is what stops the singleton assumptions
/// listed on [_LinkState] from having to be found again later, one silent
/// regression at a time.
class BleService {
  BleService({
    CommandBuilder commands = const CommandBuilder(),
    MetadataParser parser = const NoopMetadataParser(),
  }) {
    _commands = commands;
    _parser = parser;
    // One persistent listener turns plugin scan results into [DiscoveredDevice].
    _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
  }

  late final CommandBuilder _commands;

  /// Device-metadata parser handed to every link's decoder (stateless; the open
  /// build's is a no-op). Held rather than pre-applied because a decoder is now
  /// built per link instead of once per service.
  late final MetadataParser _parser;

  /// Live links by device id. **0 or 1 entry today** (see the class doc).
  ///
  /// An entry OUTLIVES its teardown, and that is deliberate: `disconnect()` has
  /// to be able to invalidate a setup that is mid-await even after the plugin
  /// handle was cleared — precisely the window the FB-39 guard exists for. The
  /// entry is dropped by the next `connect()` or by `dispose()`.
  final Map<String, _LinkState> _links = <String, _LinkState>{};

  /// The link the single-connection getters report on. Survives teardown for
  /// the same reason the decoder used to: `currentSample` must keep returning
  /// the last values after a drop, not go blank.
  _LinkState? _current;

  /// Reported by [currentSample] before any link has ever existed. Held rather
  /// than built per call so repeated reads keep returning the same instance,
  /// as a service-lifetime decoder used to.
  final TelemetrySample _noTelemetry = TelemetrySample.empty();

  StreamSubscription<List<ScanResult>>? _scanSub;

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

  /// Upper edges (ms) of the keep-alive write-duration histogram; a final
  /// open-ended bucket catches everything at or past the last edge. Chosen to
  /// straddle [keepAliveWriteTimeout]: the question FB-20 leaves open is where
  /// the body of the distribution sits, not how far the tail goes.
  static const List<int> writeStatsBucketsMs = [
    100, 250, 500, 1000, 2000, 3000, 4000, 5000
  ];

  /// Emit the histogram every N successful writes. 60 is about a minute on a
  /// healthy link and about five minutes on the slowest unit measured, so the
  /// line is rare enough not to crowd the packet log it shares.
  static const int writeStatsEvery = 60;

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

  /// Our own service-discovery timeout — deliberately SHORTER than the 15 s
  /// flutter_blue_plus applies internally.
  ///
  /// The point is to be the one who notices. With no timeout of our own, the
  /// plugin's fires first and arrives as an exception out of a stream listener,
  /// which is why a field capture holds 101 `Uncaught:` lines. Owning the
  /// timeout lets us retry once and write a readable line instead.
  ///
  /// ⚠️ 8 s is an ESTIMATE, not a measured optimum. Its whole basis is two
  /// facts: it has to be under the plugin's 15 s or it never fires, and one
  /// capture showed discovery succeeding on a later attempt. Nothing here has
  /// been calibrated against a distribution of real discovery times — treat it
  /// as provisional and revisit it once enough field captures exist to measure
  /// one, rather than quoting it as a verified number.
  static const Duration discoverTimeout = Duration(seconds: 8);

  /// Service-discovery attempts. Two, on every platform: the capture that
  /// motivated this showed discovery failing three times and then succeeding,
  /// so one shot throws away a link that was about to work. 2 × 8 s still
  /// bounds the wait tighter than the single 15 s it replaces.
  static int discoverAttemptsFor({required bool isIOS}) => 2;

  /// Our own CCCD-enable timeout — again SHORTER than the plugin's 15 s.
  ///
  /// FB-45. `b64c5b5` (v0.6.13) gave service discovery a timeout and a retry
  /// and left the line under it bare, so `setNotifyValue(true)` still inherited
  /// the plugin's 15 s. Two field captures show the same shape to the tenth of
  /// a second — `2026.07.31/005` session 66 on 0.6.12 and `2026.08.01/007`
  /// session 14 on 0.6.13: connected, GATT dump fine, frames ALREADY arriving
  /// (the peripheral was still notifying from the previous subscription), then
  /// exactly 15.0 s later the CCCD write gives up and the link is dropped.
  /// `ready` is never published, so the dashboard stays empty while history
  /// keeps filling — the user's words were "history shows connected, the main
  /// screen never comes up".
  ///
  /// 5 s, because this is a WRITE and not a discovery. Enabling notifications
  /// is one two-byte CCCD write — an ATT round trip on the order of a
  /// connection interval — whereas discovery walks the whole GATT table. The
  /// app already has a considered number for "a write that has not come back is
  /// not coming back": [keepAliveWriteTimeout], 5 s, several poll periods.
  /// Reusing that judgement is better than minting a second one.
  ///
  /// ⚠️ Like [discoverTimeout] this is an ESTIMATE, not a measured optimum. No
  /// capture holds a CCCD enable that was slow and then SUCCEEDED, so there is
  /// no distribution to fit — only the failures (15.0 s, twice) and two hard
  /// constraints: it must be under the plugin's 15 s or it never fires, and
  /// [notifyAttempts] × this must keep the whole setup budget under what it
  /// replaces. Revisit once a field capture can measure a successful one.
  static const Duration notifyTimeout = Duration(seconds: 5);

  /// CCCD-enable attempts. Two, for the same reason discovery gets two: the
  /// captures show a link that is otherwise healthy — services discovered,
  /// notifications flowing — thrown away on a single stuck write. 2 × 5 s is
  /// still a THIRD less wall clock than the single 15 s it replaces.
  static const int notifyAttempts = 2;

  /// Connect timeout to use on [isIOS].
  static Duration connectTimeoutFor({required bool isIOS}) =>
      isIOS ? iosConnectTimeout : androidConnectTimeout;

  /// Run [action] under [timeout], retrying up to [attempts] times, reporting
  /// each failure through [onFailure] and rethrowing the last one if none
  /// succeed.
  ///
  /// Extracted so the two GATT-setup steps share ONE policy rather than two
  /// copies that can drift, and so the policy itself is testable without a live
  /// peripheral — which is the whole reason FB-45 survived FB-23's fix: the
  /// retry lived inside `_discoverServices` and could not be applied to
  /// anything else without being written out again.
  ///
  /// Every failure is logged, including the ones a later attempt recovers from:
  /// a capture where setup fails once and then succeeds looks identical to one
  /// that succeeded first time unless the failures are written down.
  static Future<T> withTimeoutRetry<T>(
    Future<T> Function() action, {
    required Duration timeout,
    required int attempts,
    required void Function(int attempt, int of, Object error) onFailure,
  }) async {
    Object? lastErr;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        return await action().timeout(timeout);
      } catch (e) {
        lastErr = e;
        onFailure(attempt, attempts, e);
      }
    }
    throw lastErr!;
  }

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
  TelemetrySample get currentSample => _current?.decoder.sample ?? _noTelemetry;

  /// Latest accumulated engineering metadata (opaque; empty on the open build).
  DeviceMetadata get currentDeviceInfo =>
      _current?.decoder.deviceMetadata ?? const EmptyDeviceMetadata();

  /// Remote id of the connected/connecting device, or null.
  String? get connectedDeviceId => _current?.device?.remoteId.str;

  /// Advertised name of the connected device (e.g. "RCE-SCAP_II"), or ''.
  String get connectedDeviceName => _current?.device?.platformName ?? '';

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

  /// Request POST_NOTIFICATIONS (Android 13+) for the ongoing notification of
  /// the Android foreground service — the thing that stops the OS freezing this
  /// process (and with it the 1 Hz keep-alive) once the screen goes off.
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
    // FB-39: open a new epoch BEFORE anything else, so a setup already awaiting
    // for the previous device abandons itself instead of publishing `ready`
    // over the top of this one. `disconnect()` opens another; both invalidate
    // the same older work, and opening twice is harmless.
    //
    // Per-link now, so the sweep is over every link that exists. With one link
    // that is the same single bump it always was; with several it is still the
    // right rule for THIS call, because a manual connect is a request to be on
    // one unit — it is `disconnect()` below, not the epoch, that decides how
    // many links survive.
    _invalidateAllLinks();
    await disconnect();
    await stopScan();

    // A fresh connect starts from a clean slate. Dropping the entries is what
    // the old `_reassembler.reset(); _decoder.reset(); _settingUp = false;`
    // did — a new [_LinkState] simply cannot carry the previous unit's buffer,
    // accumulated sample or half-finished setup into this one.
    _links.clear();

    final device = BluetoothDevice.fromId(deviceId);
    final link = _LinkState(
        deviceId: deviceId, device: device, parser: _parser);
    _links[deviceId] = link;
    _current = link;
    _setState(BleLinkState.connecting);

    link.connSub =
        device.connectionState.listen((s) => _onConnectionState(link, s));

    if (autoConnect) {
      // Seamless reconnect: register a PENDING connection and let the OS
      // (CoreBluetooth on iOS) reconnect the moment the peripheral reappears.
      // connect() returns immediately here — the connectionState listener above
      // drives setup once actually connected. mtu must be null with autoConnect;
      // there is no timeout and no app-level retry loop (the OS holds it). Used
      // only for re-connecting a link that was previously healthy (a dropped,
      // known-good device), never for a first connect to a possibly-stale id.
      link.retryingConnect = false;
      try {
        await device.connect(mtu: null, autoConnect: true);
      } catch (e) {
        await _teardown(link, emitDisconnected: true);
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
    link.retryingConnect = attempts > 1;
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
    link.retryingConnect = false;
    if (lastErr != null) {
      await _teardown(link, emitDisconnected: true);
      throw lastErr;
    }
  }

  /// Open a new epoch on every link that exists, invalidating any setup already
  /// mid-await. See [ConnectEpoch] and the note in [_links] on why an entry
  /// outlives its own teardown.
  void _invalidateAllLinks() {
    for (final link in _links.values) {
      link.epoch.begin();
    }
  }

  Future<void> _onConnectionState(
      _LinkState link, BluetoothConnectionState s) async {
    if (s == BluetoothConnectionState.connected) {
      await _setupConnection(link);
    } else if (s == BluetoothConnectionState.disconnected) {
      // Capture WHY the link dropped (A: cross-platform disconnect diagnostics)
      // before teardown clears the device handle.
      final r = link.device?.disconnectReason;
      _lastDisconnect =
          r == null ? null : 'code=${r.code} ${r.description ?? ''}'.trim();
      // Ignore transient drops while still retrying the initial connect.
      if (link.retryingConnect) return;
      await _teardown(link, emitDisconnected: true);
    }
  }

  /// Discover services under [discoverTimeout], retrying once — two attempts of
  /// 8 s still bound the wait tighter than the single 15 s they replace.
  ///
  /// Each timeout is logged: a capture where discovery fails and then succeeds
  /// looks identical to one where it succeeded first time, unless the failures
  /// are written down.
  Future<List<BluetoothService>> _discoverServices(
          _LinkState link, BluetoothDevice device) =>
      withTimeoutRetry(
        device.discoverServices,
        timeout: discoverTimeout,
        attempts: discoverAttemptsFor(isIOS: Platform.isIOS),
        onFailure: (attempt, of, e) => _emitEvent(
            'service discovery attempt $attempt/$of failed: '
            '${gattSetupFailureReason(e)}',
            link: link),
      );

  /// Enable notifications under [notifyTimeout], retrying once — FB-45.
  ///
  /// The line this replaces was `await notify.setNotifyValue(true);`, bare, and
  /// it is the other half of the fault FB-23 fixed: an unowned timeout on a
  /// stream-listener code path, whose failure the app could only report after
  /// the plugin had already decided how long to wait.
  Future<void> _enableNotify(
          _LinkState link, BluetoothCharacteristic notify) =>
      withTimeoutRetry(
        () => notify.setNotifyValue(true),
        timeout: notifyTimeout,
        attempts: notifyAttempts,
        // The exception text is kept verbatim: `fbp-code: 1 | Timed out after
        // 15s` is the string eleven collected batches were grepped for, and the
        // prefix is what finally says WHICH setup step produced it.
        onFailure: (attempt, of, e) =>
            _emitEvent('notify enable attempt $attempt/$of failed: $e',
                link: link),
      );

  Future<void> _setupConnection(_LinkState link) async {
    final device = link.device;
    if (device == null || link.settingUp || _state == BleLinkState.ready) {
      return;
    }
    // FB-39: everything below this line writes state OTHER callers can also
    // reach, so it must not run if a newer connect has taken over while we were
    // awaiting. The epoch is this link's own, so a future third connect can
    // invalidate this setup without touching an unrelated link's.
    final epoch = link.epoch.current;
    link.settingUp = true;
    _setState(BleLinkState.connected);

    try {
      final services = await _discoverServices(link, device);
      // Superseded: a newer connection now owns the shared fields. Abandon
      // QUIETLY — no state change, and above all no teardown, which would tear
      // down the link the user actually asked for.
      if (!link.epoch.isCurrent(epoch)) return;
      link.writeChar = null;
      link.notifyChar = null;

      // Prefer characteristics under the vendor service, but fall back to a
      // full sweep — the service linkage is inferred, not byte-fixed.
      for (final svc in services) {
        final preferred = svc.uuid == _serviceGuid;
        for (final c in svc.characteristics) {
          if (c.uuid == _writeGuid && (link.writeChar == null || preferred)) {
            link.writeChar = c;
          }
          if (c.uuid == _notifyGuid && (link.notifyChar == null || preferred)) {
            link.notifyChar = c;
          }
        }
      }

      // Diagnostic: dump the full GATT table (svc/char UUID + properties) to the
      // capture log. Confirmed the metadata burst (VADJ 0x30 / dealer 0x27) rides
      // the single notify char ace4 — there is NO second notify channel
      // (PROTOCOL.md §10.2), so we subscribe to ace4 only.
      _dumpGatt(link, services);

      final notify = link.notifyChar;
      if (link.writeChar == null || notify == null) {
        throw StateError(
            'GATT characteristics not found (write=${link.writeChar != null}, '
            'notify=${notify != null})');
      }

      // Subscribe BEFORE the first write (PROTOCOL.md §2). setNotifyValue(true)
      // writes the CCCD enable value [0x01, 0x00].
      final mySub = notify.onValueReceived.listen((c) => _onNotify(link, c));
      link.notifySub = mySub;
      await _enableNotify(link, notify);

      // Second guard: the CCCD write is the other await this method spans.
      if (!link.epoch.isCurrent(epoch)) {
        // Reclaim only OUR subscription. If a newer setup has already replaced
        // the field, cancelling would silence the live device.
        if (identical(link.notifySub, mySub)) link.notifySub = null;
        await mySub.cancel();
        return;
      }

      _startKeepAlive(link);
      _setState(BleLinkState.ready);
    } catch (e) {
      // FB-23: do NOT rethrow. The only caller is a `connectionState` stream
      // listener, so a rethrow reaches no handler — it just becomes an
      // `Uncaught:` line, which is all the field capture ever showed. Write a
      // readable reason instead and let the disconnect drive the normal
      // reconnect path.
      _emitEvent('gatt setup failed: ${gattSetupFailureReason(e)}', link: link);
      if (link.epoch.isCurrent(epoch)) {
        await _teardown(link, emitDisconnected: true);
      }
    } finally {
      link.settingUp = false;
    }
  }

  /// Handle a notification chunk from [link]'s notify characteristic.
  void _onNotify(_LinkState link, List<int> chunk) {
    _packets.add(BlePacketEvent(LogDirection.rx, List<int>.unmodifiable(chunk),
        deviceId: link.deviceId));
    final frames = link.reassembler.addBytes(chunk);
    final now = DateTime.now();
    final infoBefore = link.decoder.deviceMetadata;
    var emitted = false;
    for (final f in frames) {
      if (!f.checksumOk) continue;
      final before = link.decoder.sample;
      final after = link.decoder.ingest(f, at: now);
      if (!identical(before, after)) {
        emitted = true;
      }
    }
    if (emitted) {
      _telemetry.add(link.decoder.sample);
    }
    // Device-metadata side-channel. On the open build
    // the Noop parser never changes it, so this never fires.
    if (!identical(infoBefore, link.decoder.deviceMetadata)) {
      _deviceMetadata.add(link.decoder.deviceMetadata);
    }
  }

  /// Emit a diagnostic note line into the packet log (an EVT row), attributed to
  /// [link] when there is one.
  void _emitEvent(String message, {_LinkState? link}) {
    _packets.add(BlePacketEvent(LogDirection.event, const [],
        note: message, deviceId: link?.deviceId));
  }

  /// Dump every service/characteristic (UUID + property flags) to the log, so a
  /// second notify channel is visible. Diagnostic only.
  void _dumpGatt(_LinkState link, List<BluetoothService> services) {
    _emitEvent('GATT dump: ${services.length} service(s)', link: link);
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
        _emitEvent('GATT svc=${svc.uuid.str} char=${c.uuid.str} [$flags]',
            link: link);
      }
    }
  }

  /// Disconnect the current device and reset state.
  Future<void> disconnect() async {
    // FB-39: bump before the early return too. A disconnect requested while a
    // setup is mid-await must invalidate it even when the plugin handle has
    // already been cleared — that is exactly the window the guard exists for,
    // and it is why a [_LinkState] outlives its own teardown.
    _invalidateAllLinks();
    final link = _current;
    final device = link?.device;
    if (link == null || device == null) return;
    _setState(BleLinkState.disconnecting);
    try {
      await device.disconnect();
    } catch (_) {
      // Ignore: teardown still proceeds via the connectionState callback.
    }
    await _teardown(link, emitDisconnected: true);
  }

  /// Fold one successful write's duration into [link]'s histogram, and emit the
  /// running summary every [writeStatsEvery] writes.
  ///
  /// Cumulative rather than per-window: the last line of a session is then the
  /// whole session, which is what an offline reader wants. Reading two lines
  /// and subtracting is still possible; reconstructing a total from windows
  /// that a disconnect may have truncated is not.
  void _recordWriteDuration(_LinkState link, int ms) {
    link.writeOkCount++;
    link.writeMsTotal += ms;
    if (ms > link.writeMsMax) link.writeMsMax = ms;
    var i = 0;
    while (i < writeStatsBucketsMs.length && ms >= writeStatsBucketsMs[i]) {
      i++;
    }
    link.writeMsBuckets[i]++;
    if (link.writeOkCount % writeStatsEvery == 0) _emitWriteStats(link);
  }

  /// One greppable line: `keep-alive write ms: n=… avg=… max=… [<100:0 …]`.
  void _emitWriteStats(_LinkState link) {
    if (link.writeOkCount == 0 ||
        link.writeOkCount == link.writeStatsReported) {
      return;
    }
    link.writeStatsReported = link.writeOkCount;
    final b = StringBuffer();
    for (var i = 0; i < link.writeMsBuckets.length; i++) {
      if (i > 0) b.write(' ');
      final edge = i < writeStatsBucketsMs.length
          ? '<${writeStatsBucketsMs[i]}'
          : '>=${writeStatsBucketsMs.last}';
      b.write('$edge:${link.writeMsBuckets[i]}');
    }
    final avg = (link.writeMsTotal / link.writeOkCount).round();
    _emitEvent(
        'keep-alive write ms: n=${link.writeOkCount} avg=$avg '
        'max=${link.writeMsMax} [$b]',
        link: link);
  }

  Future<void> _teardown(_LinkState link,
      {required bool emitDisconnected}) async {
    // Flush the histogram before the link goes quiet: a session shorter than
    // writeStatsEvery would otherwise report nothing at all, and short sessions
    // are exactly the ones a slow unit produces.
    _emitWriteStats(link);
    link.keepAlive?.cancel();
    link.keepAlive = null;
    link.keepAliveTick = 0;
    await link.notifySub?.cancel();
    link.notifySub = null;
    link.keepAliveWriteFailed = false;
    await link.connSub?.cancel();
    link.connSub = null;
    link.writeChar = null;
    link.notifyChar = null;
    // Clears "connected" for the getters, but keeps the object: the decoder
    // behind `currentSample` and the epoch behind `disconnect()` both have to
    // survive this, exactly as the service-level fields used to.
    link.device = null;
    link.settingUp = false;
    link.reassembler.reset();
    if (emitDisconnected) {
      _setState(BleLinkState.disconnected);
    }
  }

  // ---------------------------------------------------------------------------
  // Keep-alive
  // ---------------------------------------------------------------------------

  void _startKeepAlive(_LinkState link) {
    link.keepAlive?.cancel();
    link.keepAliveTick = 0;
    // Tick immediately so telemetry starts without waiting a full second. The
    // first tick sends `!#`, which every device answers with device-type/SOC.
    unawaited(_sendKeepAlive(link));
    link.keepAlive = Timer.periodic(keepAliveInterval, (_) {
      unawaited(_sendKeepAlive(link));
    });
  }

  Future<void> _sendKeepAlive(_LinkState link) async {
    if (link.writeChar == null) return;
    // Re-entrancy guard. The timer fires every second but a write can hang far
    // longer — when Android suspends the app (screen off / background) BOTH
    // directions stall for minutes, then everything resumes at once. Without
    // this guard each stalled second queued another write, so a 2.5-minute
    // freeze piled up ~150 of them and they all landed on resume.
    //
    // Per link: the guard means "THIS link already has a write out". Shared, a
    // hung write on one unit would swallow every other unit's tick, and the
    // tick schedule below is exactly the thing that must not be skipped.
    if (link.keepAliveInFlight) return;
    link.keepAliveInFlight = true;
    link.keepAliveTick++;
    // Whether the connected unit is a power bank is read from the LATEST decoded
    // telemetry (device-type 0x22); it flips true once the tick-1 `!#` elicits
    // the 0x10 frame, after which the every-5th `!#` schedule kicks in — so both
    // inputs to the schedule have to come from THIS link, not from whichever
    // unit answered most recently.
    final token = keepAliveTokenFor(
      _commands,
      tick: link.keepAliveTick,
      isPowerBank: link.decoder.sample.isPowerBank,
    );
    final sw = Stopwatch()..start();
    try {
      await _writeTo(link, token, timeout: keepAliveWriteTimeout);
      _recordWriteDuration(link, sw.elapsedMilliseconds);
      // Recovery is as diagnostic as the failure: it bounds how long the app
      // was actually unable to poll, which a lone failure line cannot.
      if (link.keepAliveWriteFailed) {
        _emitEvent(
            'keep-alive write recovered after '
            '${link.keepAliveFailures} consecutive failure(s)',
            link: link);
        link.keepAliveWriteFailed = false;
        link.keepAliveFailures = 0;
      }
    } catch (e) {
      // A failed keep-alive usually means the link dropped; the connectionState
      // callback handles teardown. Surface it once to the diagnostic log — a
      // silent catch here previously hid a write-mode bug that suppressed the
      // metadata burst.
      link.keepAliveFailures++;
      if (!link.keepAliveWriteFailed) {
        link.keepAliveWriteFailed = true;
        // The elapsed time separates "the device rejected it" (fails fast) from
        // "nothing came back" (runs to the timeout) — the 2026-07-27 stalls were
        // the latter, and only the duration says so.
        _emitEvent(
            'keep-alive write failed after ${sw.elapsedMilliseconds}ms: $e',
            link: link);
      }
    } finally {
      link.keepAliveInFlight = false;
    }
  }

  /// Consecutive keep-alive write failures outstanding; 0 when healthy.
  ///
  /// Exposed rather than invented: this counter already existed and was only
  /// ever written to the diagnostic log. It is the honest explanation for a
  /// device class
  /// that never resolves — `0x10` answers the 1 Hz `#` poll, so a poll that
  /// cannot be written is never answered, while notifications subscribed
  /// earlier keep streaming and the link still reports ready (PROTOCOL.md
  /// §10.2). Surfacing it lets the UI say "connection unstable, retrying"
  /// instead of the useless "cannot determine device type".
  ///
  /// It also settles what NOT to build: re-sending `!#` on a stall was the
  /// original proposal, but `!#` is itself a write, so in the only case that
  /// needs it the resend fails too.
  int get keepAliveFailures => _current?.keepAliveFailures ?? 0;

  /// True while the keep-alive write path is known to be broken.
  bool get keepAliveWriteFailed => _current?.keepAliveWriteFailed ?? false;

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
  Future<void> writeCommand(List<int> bytes, {Duration? timeout}) =>
      _writeTo(_current, bytes, timeout: timeout);

  /// Write to ONE link's write characteristic. [writeCommand] is this with the
  /// current link filled in; the keep-alive passes its own link so a tick can
  /// never be delivered to a unit other than the one it was scheduled for.
  Future<void> _writeTo(_LinkState? link, List<int> bytes,
      {Duration? timeout}) async {
    final c = link?.writeChar;
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
    _packets.add(BlePacketEvent(LogDirection.tx, List<int>.unmodifiable(bytes),
        deviceId: link!.deviceId));
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
  /// (selector 0x2B, §10.2) instead of forcing 0x00 — so a user editing OV/UV/OT
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
      trailing: trailing ?? currentSample.warnUtByte ?? 0x00,
    ));
  }

  /// Set warning thresholds from raw register bytes. [trailing] null preserves
  /// the last-read UT byte (see [setThresholds]).
  Future<void> setThresholdsRaw(int ovByte, int uvByte, int otByte,
      {int? trailing}) async {
    await writeCommand(_commands.thresholdsRaw(ovByte, uvByte, otByte,
        trailing: trailing ?? currentSample.warnUtByte ?? 0x00));
  }

  /// Send one scheduled keep-alive token on demand (advances the tick counter).
  /// No-op when nothing is connected, as it always was — the old body returned
  /// early on a null write characteristic.
  Future<void> pokeKeepAlive() async {
    final link = _current;
    if (link == null) return;
    await _sendKeepAlive(link);
  }

  // ---------------------------------------------------------------------------

  void _setState(BleLinkState s) {
    if (_state == s) return;
    _state = s;
    _link.add(s);
  }

  /// Release all resources. The service is unusable afterwards.
  Future<void> dispose() async {
    for (final link in _links.values.toList()) {
      await _teardown(link, emitDisconnected: false);
    }
    _links.clear();
    _current = null;
    await _scanSub?.cancel();
    _scanSub = null;
    await _telemetry.close();
    await _deviceMetadata.close();
    await _link.close();
    await _scan.close();
    await _packets.close();
  }
}
