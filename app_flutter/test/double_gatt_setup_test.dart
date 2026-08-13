// Two GATT setups on one link — the invariant `BleService` claims, tested.
//
// WHAT THIS IS ABOUT. A field capture (batch 2026.08.13/001) holds eighteen
// minutes in which ONE connection to ONE unit behaved as if it were two:
//
//   * every RX line written twice, byte for byte — 17,030 pairs;
//   * `GATT dump:` printed twice, 2 ms apart, on the same connection (the only
//     one of 28 dumps in that capture that did so);
//   * `conn-state: connected … sub=129ms decision=setup` printed twice, in the
//     same millisecond and with the SAME subscription age;
//   * and the decisive one, at teardown: TWO keep-alive write histograms with
//     DIFFERENT counts, `n=1075 avg=87 max=222` and `n=1078 avg=110 max=609`,
//     at one timestamp. Two counters that had each been accumulating for
//     eighteen minutes without knowing about the other.
//   * downstream: CSV `samples` per minute 2.48x the same unit's own baseline,
//     because two decoders were feeding one telemetry stream.
//
// `ble_service.dart` said this could not happen: "`_links` holds 0 or 1 entry —
// `connect()` still awaits `disconnect()` first, and no caller can ask for a
// second concurrent link". The map really does hold one entry. The claim that
// does not follow is the behavioural one, and this file is where it is decided
// rather than argued.
//
// WHAT IS PINNED HERE.
//
//   G1  the guards that DO hold: a second `connected` on a link already
//       setting up, and a second `connected` after `ready`, both start nothing.
//       A sequential second `connect()` really does tear the first link down.
//   G2  the hole: two `connect()` calls for the same id, issued before either
//       has created its link, leave TWO live `_LinkState`s. `_links.clear()`
//       drops the first entry without cancelling anything it owns, and
//       `disconnect()` only ever tears down `_current`. Every one of the five
//       field symptoms above follows, and is asserted here one by one.
//
// ⚠️ These are CHARACTERIZATION tests for G2: green means the defect is still
// present. They are deliberately not a fix — the repair belongs to whoever owns
// the decision about what `connect()` should do when it is called twice.
//
// HOW IT IS DRIVEN. `BleService` talks to flutter_blue_plus, so the fake goes
// in one layer lower: `FlutterBluePlusPlatform.instance` is settable, and every
// call the service makes (connect / discover / CCCD enable / write) plus every
// event it listens for (connection state, discovered services, notifications)
// crosses that one interface. So the REAL `BleService.connect`, the REAL
// `_setupConnection` and the REAL keep-alive run here; only the radio is
// standing in. The harness is file-private, per this project's habit — see the
// header of `autoconnect_watchdog_background_test.dart`.
//
// CLEAN-ROOM: every expectation derives from this project's own source, the
// published flutter_blue_plus sources, and this project's own field captures.

// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show FlutterBluePlus, Guid;
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

// ---------------------------------------------------------------------------
// The stand-in radio
// ---------------------------------------------------------------------------

/// One fake peripheral behind `FlutterBluePlusPlatform`.
///
/// ONE instance for the whole file, on purpose: `_initFlutterBluePlus()` is a
/// static one-shot that subscribes to whatever instance is installed the first
/// time any platform call is made, and those subscriptions are what maintain
/// `FlutterBluePlus._connectionStates` (which `discoverServices` consults
/// before it will run). A per-test instance would leave that bookkeeping wired
/// to a dead object. [reset] clears the counters instead.
final class _FakeRadio extends FlutterBluePlusPlatform {
  final _conn = StreamController<BmConnectionStateResponse>.broadcast();
  final _disc = StreamController<BmDiscoverServicesResult>.broadcast();
  final _rx = StreamController<BmCharacteristicData>.broadcast();
  final _written = StreamController<BmCharacteristicData>.broadcast();
  final _adapter = StreamController<BmBluetoothAdapterState>.broadcast();

  /// Never emits and never closes, which is the point. The base class returns
  /// `Stream.empty()`, and `setNotifyValue` takes `.first` of this stream
  /// BEFORE it learns whether there is a CCCD to wait for — on a closed stream
  /// that future completes with a "No element" error nobody is listening for.
  final _desc = StreamController<BmDescriptorData>.broadcast();

  /// Held open to keep a GATT setup suspended mid-discovery, so a second
  /// `connected` event can be delivered while the first setup is still in
  /// flight — the window `_LinkState.settingUp` exists to close.
  Completer<void>? discoverGate;

  /// Held open to keep a teardown of a PREVIOUS link suspended, which is how
  /// wide the window in G2 really is: `disconnect()` on a live handle waits for
  /// the platform, and the capture's two `connect →` lines are 1.9 s apart.
  Completer<void>? disconnectGate;

  int discoverCalls = 0;
  int notifyEnables = 0;
  final List<List<int>> writes = <List<int>>[];

  void reset() {
    discoverGate = null;
    disconnectGate = null;
    discoverCalls = 0;
    notifyEnables = 0;
    writes.clear();
  }

  // ---- events the app listens to ----

  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged => _conn.stream;

  @override
  Stream<BmDiscoverServicesResult> get onDiscoveredServices => _disc.stream;

  @override
  Stream<BmCharacteristicData> get onCharacteristicReceived => _rx.stream;

  @override
  Stream<BmCharacteristicData> get onCharacteristicWritten => _written.stream;

  @override
  Stream<BmBluetoothAdapterState> get onAdapterStateChanged => _adapter.stream;

  @override
  Stream<BmDescriptorData> get onDescriptorWritten => _desc.stream;

  @override
  Stream<BmDescriptorData> get onDescriptorRead => _desc.stream;

  // ---- calls the app makes ----

  @override
  Future<bool> isSupported(BmIsSupportedRequest request) async => true;

  @override
  Future<BmBluetoothAdapterState> getAdapterState(
          BmBluetoothAdapterStateRequest request) async =>
      BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on);

  /// `false` means "the connection state did not change", which is what stops
  /// `BluetoothDevice.connect` from blocking on a state event. The test decides
  /// when the radio reports `connected`, via [reportConnected] — that is what
  /// lets two setups be released at the same instant, the way one radio event
  /// delivered to two subscriptions does in the field.
  @override
  Future<bool> connect(BmConnectRequest request) async => false;

  @override
  Future<bool> disconnect(BmDisconnectRequest request) async {
    await disconnectGate?.future;
    return false;
  }

  @override
  Future<bool> discoverServices(BmDiscoverServicesRequest request) async {
    discoverCalls++;
    await discoverGate?.future;
    _disc.add(_gattTable(request.remoteId));
    return true;
  }

  /// `false` = "this characteristic has no CCCD", which is the plugin's own
  /// signal that there is no descriptor write to wait for. The app's CCCD
  /// timeout/retry policy is not what this file is about.
  @override
  Future<bool> setNotifyValue(BmSetNotifyValueRequest request) async {
    notifyEnables++;
    return false;
  }

  @override
  Future<bool> writeCharacteristic(
      BmWriteCharacteristicRequest request) async {
    writes.add(List<int>.unmodifiable(request.value));
    _written.add(BmCharacteristicData(
      remoteId: request.remoteId,
      primaryServiceUuid: request.primaryServiceUuid,
      serviceUuid: request.serviceUuid,
      characteristicUuid: request.characteristicUuid,
      instanceId: request.instanceId,
      value: request.value,
      success: true,
      errorCode: 0,
      errorString: '',
    ));
    return true;
  }

  // ---- what the radio says ----

  void reportConnected(String id) => _conn.add(BmConnectionStateResponse(
        remoteId: DeviceIdentifier(id),
        connectionState: BmConnectionStateEnum.connected,
        disconnectReasonCode: null,
        disconnectReasonString: null,
      ));

  void reportDisconnected(String id) => _conn.add(BmConnectionStateResponse(
        remoteId: DeviceIdentifier(id),
        connectionState: BmConnectionStateEnum.disconnected,
        disconnectReasonCode: 19,
        disconnectReasonString: 'peripheral closed the connection',
      ));

  /// One notification chunk on the notify characteristic — the event whose
  /// duplication is symptom #1 in the capture.
  void notify(String id, List<int> chunk) {
    final rid = DeviceIdentifier(id);
    _rx.add(BmCharacteristicData(
      remoteId: rid,
      primaryServiceUuid: null,
      serviceUuid: Guid(Gatt.serviceUuid),
      characteristicUuid: Guid(Gatt.notifyCharUuid),
      instanceId: 0,
      value: chunk,
      success: true,
      errorCode: 0,
      errorString: '',
    ));
  }
}

/// The unit's real GATT table, as `PROTOCOL.md` §3.1 describes it: one primary
/// service, a write characteristic that is Write-WITH-response only (the
/// without-response bit is genuinely absent on this hardware), and one notify
/// characteristic. Both under the vendor service, so `_setupConnection` takes
/// its preferred branch rather than the fallback sweep.
BmDiscoverServicesResult _gattTable(DeviceIdentifier rid) {
  BmCharacteristicProperties props({bool write = false, bool notify = false}) =>
      BmCharacteristicProperties(
        broadcast: false,
        read: false,
        writeWithoutResponse: false,
        write: write,
        notify: notify,
        indicate: false,
        authenticatedSignedWrites: false,
        extendedProperties: false,
        notifyEncryptionRequired: false,
        indicateEncryptionRequired: false,
      );

  final svc = Guid(Gatt.serviceUuid);
  return BmDiscoverServicesResult(
    remoteId: rid,
    services: <BmBluetoothService>[
      BmBluetoothService(
        remoteId: rid,
        primaryServiceUuid: null, // primary
        serviceUuid: svc,
        characteristics: <BmBluetoothCharacteristic>[
          BmBluetoothCharacteristic(
            remoteId: rid,
            primaryServiceUuid: null,
            serviceUuid: svc,
            characteristicUuid: Guid(Gatt.writeCharUuid),
            instanceId: 0,
            descriptors: <BmBluetoothDescriptor>[],
            properties: props(write: true),
          ),
          BmBluetoothCharacteristic(
            remoteId: rid,
            primaryServiceUuid: null,
            serviceUuid: svc,
            characteristicUuid: Guid(Gatt.notifyCharUuid),
            instanceId: 0,
            descriptors: <BmBluetoothDescriptor>[],
            properties: props(notify: true),
          ),
        ],
      ),
    ],
    success: true,
    errorCode: 0,
    errorString: '',
  );
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// A real [BleService] plus a recording of everything it emitted.
class _Rig {
  _Rig(this.radio) {
    ble = BleService();
    _packets = ble.packets.listen(packets.add);
    _diags = ble.diagnostics.listen(diagnostics.add);
  }

  static const String deviceId = 'unit-under-test';

  final _FakeRadio radio;
  late final BleService ble;
  late final StreamSubscription<BlePacketEvent> _packets;
  late final StreamSubscription<String> _diags;

  final List<BlePacketEvent> packets = <BlePacketEvent>[];
  final List<String> diagnostics = <String>[];

  Iterable<String> get notes =>
      packets.map((p) => p.note).whereType<String>();

  int countNotes(String prefix) =>
      notes.where((n) => n.startsWith(prefix)).length;

  int get rxEvents =>
      packets.where((p) => p.direction == LogDirection.rx).length;

  int get txEvents =>
      packets.where((p) => p.direction == LogDirection.tx).length;

  /// Let every pending microtask and zero-duration future run. The plugin's
  /// mutexes, its `newStreamWithInitialValue` replay and the service's own
  /// awaits are all microtask-scheduled, so this is the only clock most of
  /// these tests need.
  Future<void> settle() => pumpEventQueue(times: 60);

  /// Ends every test the same way: the peripheral goes away, which is what
  /// tears down whatever links are still live (including any the service has
  /// lost track of) and returns the plugin's static connection-state cache to
  /// `disconnected` for the next test.
  Future<void> shutdown() async {
    radio.reportDisconnected(deviceId);
    await settle();
    await _packets.cancel();
    await _diags.cancel();
    await ble.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final radio = _FakeRadio();

  setUpAll(() async {
    FlutterBluePlusPlatform.instance = radio;
    // Force `_initFlutterBluePlus()` now. It is a static one-shot, and it is
    // what keeps `FlutterBluePlus._connectionStates` current; running it here
    // also makes its connection-state listener the FIRST subscriber on the
    // fake's broadcast stream, so the cache is already updated by the time the
    // service's own link subscriptions see the same event. On a real device
    // the same ordering holds — the plugin initialises before any app code can
    // subscribe to a device.
    await FlutterBluePlus.isSupported;
  });

  setUp(radio.reset);

  // -------------------------------------------------------------------------
  group('G1 — the guards that do hold', () {
    test('a second `connected` while setup is in flight starts nothing',
        () async {
      final rig = _Rig(radio);
      radio.discoverGate = Completer<void>();

      await rig.ble.connect(_Rig.deviceId);
      radio.reportConnected(_Rig.deviceId);
      await rig.settle();
      expect(radio.discoverCalls, 1, reason: 'setup one is under way');

      // The event that arrives while `_setupConnection` is suspended on
      // discovery. `_LinkState.settingUp` is written synchronously, BEFORE the
      // first await in that method (ble_service.dart:962-970), which is the
      // only reason this second entry cannot get past the guard.
      radio.reportConnected(_Rig.deviceId);
      await rig.settle();
      expect(radio.discoverCalls, 1,
          reason: 'settingUp is set before the first await, so the re-entry '
              'has nothing to race');

      radio.discoverGate!.complete();
      await rig.settle();
      expect(rig.countNotes('GATT dump:'), 1);
      await rig.shutdown();
    });

    test('a second `connected` after ready starts nothing', () async {
      final rig = _Rig(radio);
      await rig.ble.connect(_Rig.deviceId);
      radio.reportConnected(_Rig.deviceId);
      await rig.settle();
      expect(rig.ble.currentState, BleLinkState.ready);

      // The other half of the same guard: `_state == BleLinkState.ready`. By
      // now `settingUp` is back to false, so this is the term doing the work.
      radio.reportConnected(_Rig.deviceId);
      await rig.settle();
      expect(radio.discoverCalls, 1);
      expect(rig.countNotes('GATT dump:'), 1);
      await rig.shutdown();
    });

    test('a SEQUENTIAL second connect() really does tear the first link down',
        () async {
      // This is the case the class doc describes correctly, and it is worth
      // pinning separately from the concurrent one below: the difference
      // between them is the whole finding.
      final rig = _Rig(radio);
      await rig.ble.connect(_Rig.deviceId);
      radio.reportConnected(_Rig.deviceId);
      await rig.settle();

      await rig.ble.connect(_Rig.deviceId); // awaited — the first link is gone
      radio.reportConnected(_Rig.deviceId);
      await rig.settle();

      expect(rig.countNotes('GATT dump:'), 2,
          reason: 'two connections, one at a time');

      final before = rig.rxEvents;
      radio.notify(_Rig.deviceId, const [0xB8, 0x00]);
      await rig.settle();
      expect(rig.rxEvents - before, 1,
          reason: 'the first link\'s notify subscription was cancelled by the '
              'teardown inside the second connect()');
      await rig.shutdown();
    });
  });

  // -------------------------------------------------------------------------
  group('G2 — two concurrent connect() calls leave two live links', () {
    /// Both calls issued in the same turn, before either has created its link.
    ///
    /// The two are then in lockstep across the identical prelude
    /// (`_invalidateAllLinks(); await disconnect(); await stopScan();`,
    /// ble_service.dart:772-774), so call 1 creates its `_LinkState` and
    /// subscribes to `connectionState` — and only THEN does call 2 reach
    /// `_links.clear()` (:780). That line drops the entry; it cancels nothing.
    /// `disconnect()` (:1162-1164) would have, but it only ever looks at
    /// `_current`, and at the moment call 2 ran it there was no link at all.
    ///
    /// The result is one `_links` entry, as advertised, and two live links.
    Future<_Rig> twoInFlightConnects() async {
      final rig = _Rig(radio);
      final first = rig.ble.connect(_Rig.deviceId);
      final second = rig.ble.connect(_Rig.deviceId);
      await Future.wait<void>([first, second]);
      radio.reportConnected(_Rig.deviceId);
      await rig.settle();
      return rig;
    }

    test('symptom 1 — the GATT setup runs twice on one connection', () async {
      final rig = await twoInFlightConnects();
      // The capture: `GATT dump: 1 service(s)` at 18:04:35.974 and again at
      // .976, one connection, 2 ms apart — the only such pair in 28 dumps.
      expect(radio.discoverCalls, 2);
      expect(radio.notifyEnables, 2,
          reason: 'each setup enables notifications for itself');
      expect(rig.countNotes('GATT dump:'), 2);
      await rig.shutdown();
    });

    test('symptom 2 — one connection-state event is decided on twice',
        () async {
      final rig = await twoInFlightConnects();
      // The capture: two `conn-state: connected reason=null sub=129ms
      // decision=setup` lines at the same millisecond, with the SAME
      // subscription age — two subscriptions created in the same millisecond,
      // both handed the same radio event.
      final setups = rig.diagnostics
          .where((d) => d.startsWith('conn-state: connected'))
          .where((d) => d.endsWith('decision=setup'))
          .length;
      expect(setups, 2);
      await rig.shutdown();
    });

    test('symptom 3 — every inbound chunk is processed twice', () async {
      final rig = await twoInFlightConnects();
      final before = rig.rxEvents;
      radio.notify(_Rig.deviceId, const [0xB8, 0x01, 0x02, 0x03]);
      await rig.settle();
      // The capture: 17,030 consecutive RX pairs, byte for byte identical,
      // across 19 minute buckets.
      expect(rig.rxEvents - before, 2,
          reason: 'two notify subscriptions, two _onNotify calls, two log '
              'rows for one chunk on the wire');
      await rig.shutdown();
    });

    test('symptom 4 — two keep-alive loops write to the same unit', () async {
      final rig = await twoInFlightConnects();
      // `_startKeepAlive` ticks immediately before arming its Timer, so the
      // tick-1 `!#` is observable without waiting out a real second.
      const extendedPoll = [0x21, 0x23];
      final firstTicks =
          radio.writes.where((w) => _sameBytes(w, extendedPoll)).length;
      expect(firstTicks, 2,
          reason: 'two independent tick counters, each starting at 1');
      expect(rig.txEvents, greaterThanOrEqualTo(2));
      await rig.shutdown();
    });

    test('symptom 5 — teardown reports two independent write histograms',
        () async {
      // THE DECISIVE ONE. From the capture, at a single timestamp:
      //   keep-alive write ms: n=1075 avg=87  max=222
      //   keep-alive write ms: n=1078 avg=110 max=609
      // Two totals that had each been accumulating for eighteen minutes. A
      // single link cannot produce that line twice with two different counts:
      // `_emitWriteStats` short-circuits on `writeOkCount == writeStatsReported`
      // (ble_service.dart:1195-1198), so a second call on ONE link is silent.
      final rig = await twoInFlightConnects();
      final before = rig.countNotes('keep-alive write ms:');
      expect(before, 0, reason: 'nothing has torn down yet');

      radio.reportDisconnected(_Rig.deviceId);
      await rig.settle();

      expect(rig.countNotes('keep-alive write ms:'), 2,
          reason: 'one histogram per live link — this is the field evidence '
              'that no amount of map-cardinality reasoning explains away');
      // …and the same doubling on the way out, which the capture also shows.
      expect(
          rig.diagnostics
              .where((d) => d.startsWith('conn-state: disconnected'))
              .where((d) => d.endsWith('decision=teardown'))
              .length,
          2);
      await rig.shutdown();
    });

    test('the window is SECONDS wide when a previous link is being torn down',
        () async {
      // The shape the capture actually has, and the answer to "why did the
      // other five sub-5-second connect pairs not do this". The two calls do
      // NOT have to arrive in the same turn.
      //
      //   18:04:31.504  connect → …      ← call 1
      //   18:04:33.420  connect → …      ← call 2, 1.916 s later
      //
      // `connect()`'s first real step is `await disconnect()`, and on a link
      // that is still up that awaits the platform (flutter_blue_plus waits for
      // the disconnect confirmation, default 35 s). Call 1 parks there. Call 2
      // arrives, reads the SAME `_current` — whose handle call 1 has not
      // cleared yet, because `_teardown` runs only after the await returns —
      // and parks behind it on the plugin's `"disconnect"` mutex. When the
      // platform finally answers, the two resume nose to tail, and call 2's
      // `_links.clear()` lands after call 1 has already built its link.
      //
      // So the precondition is not "two taps in the same millisecond". It is
      // "a second connect arrives while the first is still tearing the old
      // link down" — anywhere in a window as long as the platform takes.
      final rig = _Rig(radio);
      await rig.ble.connect(_Rig.deviceId);
      radio.reportConnected(_Rig.deviceId);
      await rig.settle();
      expect(rig.ble.currentState, BleLinkState.ready, reason: 'the old link');

      radio.disconnectGate = Completer<void>();
      final first = rig.ble.connect(_Rig.deviceId);
      await rig.settle(); // call 1 is parked inside the platform disconnect
      final second = rig.ble.connect(_Rig.deviceId); // …seconds later
      await rig.settle();
      expect(radio.discoverCalls, 1, reason: 'still only the old link\'s');

      radio.disconnectGate!.complete();
      await Future.wait<void>([first, second]);
      radio.reportConnected(_Rig.deviceId);
      await rig.settle();

      expect(radio.discoverCalls, 3,
          reason: 'the old link once, then two setups on the new connection');
      final before = rig.rxEvents;
      radio.notify(_Rig.deviceId, const [0xB8, 0x09]);
      await rig.settle();
      expect(rig.rxEvents - before, 2);

      radio.reportDisconnected(_Rig.deviceId);
      await rig.settle();
      expect(rig.countNotes('keep-alive write ms:'), greaterThanOrEqualTo(2),
          reason: 'two live links on the new connection, each with its own '
              'write counter');
      await rig.shutdown();
    });

    test('the map really does hold one entry — that was never the question',
        () async {
      // Stated so the finding is not mistaken for "the class doc lied about
      // `_links`". It did not. `connectedDeviceId` reports the single current
      // link throughout, and the second link is invisible to every
      // single-connection getter the service exposes. That invisibility is
      // precisely why eighteen minutes of doubled data reached the CSV before
      // anybody noticed.
      final rig = await twoInFlightConnects();
      expect(rig.ble.connectedDeviceId, _Rig.deviceId);
      expect(rig.ble.currentState, BleLinkState.ready);
      await rig.shutdown();
    });
  });
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
