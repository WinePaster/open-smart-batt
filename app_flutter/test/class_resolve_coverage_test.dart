// The `class-resolve:` line must cover the attempts that FAILED.
//
// THE DEFECT THIS PINS DOWN. The line is the only entry that makes class
// resolution measurable in a field log, and its own comment said so: "if the
// byte never arrived, say so on the way out — otherwise the connections that
// FAILED to resolve are exactly the ones absent from the measurement, and the
// distribution reads clean." The emitter then opened with a guard that returned
// when `ready` had never been reached, which is precisely the failing case. In
// one build's field logs more than half the connection attempts never reached
// `ready`, so the collected sample was conditioned on the link having come up —
// the one condition under which nothing is wrong.
//
// A second, quieter half of the same defect: the "already logged" flag was
// cleared at `ready`. An attempt that never got there could not clear it, so
// after one logged connection a whole run of failed retries stayed silent even
// once the guard was gone.
//
// CLEAN-ROOM: expectations derive from our own source and our own captures.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Minimal BLE stand-in: no radio, the test drives link transitions directly.
class _StubBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  String? held;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  String? get connectedDeviceId => held;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {}

  @override
  Future<void> disconnect() async {}

  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

/// Let the unawaited `_event` inserts land — `insertLog` is a two-step round
/// trip, so a microtask hop is not enough.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  Future<AppServices> makeServices(_StubBle ble) async {
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    return AppServices.create(appDatabase: db, ble: ble);
  }

  Future<List<String>> resolveLines(AppServices s) async =>
      (await s.logRepo.queryLog())
          .map((e) => e.note ?? '')
          .where((n) => n.startsWith('class-resolve:'))
          .toList();

  test('an attempt that never reaches ready still reports', () async {
    final ble = _StubBle();
    final s = await makeServices(ble);
    addTearDown(s.dispose);
    ble.held = 'AA';

    ble.emitLink(BleLinkState.connecting);
    ble.emitLink(BleLinkState.disconnected);
    await settle();

    final lines = await resolveLines(s);
    expect(lines, hasLength(1),
        reason: 'the failing attempt is the one worth measuring');
    expect(lines.single, contains('ready=never'),
        reason: 'no interval to state, but the attempt still happened');
    expect(lines.single, contains('class=none'));
  });

  test('every failed retry gets its own line, not just the first', () async {
    // The flag used to be cleared at `ready`; a run of attempts that never got
    // there would clear it never, and only the first could ever be reported.
    final ble = _StubBle();
    final s = await makeServices(ble);
    addTearDown(s.dispose);
    ble.held = 'AA';

    for (var i = 0; i < 3; i++) {
      ble.emitLink(BleLinkState.connecting);
      ble.emitLink(BleLinkState.disconnected);
      await settle();
    }

    expect(await resolveLines(s), hasLength(3));
  });

  test('reaching ready without a byte keeps saying so', () async {
    // Unchanged behaviour, pinned because the fix touches the same emitter.
    final ble = _StubBle();
    final s = await makeServices(ble);
    addTearDown(s.dispose);
    ble.held = 'AA';

    ble.emitLink(BleLinkState.connecting);
    ble.emitLink(BleLinkState.ready);
    await settle();
    ble.emitLink(BleLinkState.disconnected);
    await settle();

    final lines = await resolveLines(s);
    expect(lines, hasLength(1));
    expect(lines.single, contains('ready→0x10 never'),
        reason: 'the link came up, so the interval is the thing that is absent');
  });

  test('a link that surfaces straight at ready is still measured', () async {
    // An OS-level autoConnect recovery can arrive with no `connecting` first.
    // Keying the line off `connecting` alone would silently drop these.
    final ble = _StubBle();
    final s = await makeServices(ble);
    addTearDown(s.dispose);
    ble.held = 'AA';

    ble.emitLink(BleLinkState.ready);
    await settle();
    ble.emitLink(BleLinkState.disconnected);
    await settle();

    expect(await resolveLines(s), hasLength(1));
  });

  test('an idle disconnect reports nothing', () async {
    // Nothing was attempted, so there is nothing to describe. A line here would
    // be a measurement of no connection at all.
    final ble = _StubBle();
    final s = await makeServices(ble);
    addTearDown(s.dispose);

    ble.emitLink(BleLinkState.disconnected);
    await settle();

    expect(await resolveLines(s), isEmpty);
  });
}
