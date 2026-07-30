// `connect → X` must not carry the INCUMBENT connection's session id.
//
// Regression from `93e967a` (design 0019), shipped in v0.6.12 — confirmed with
// `git tag --contains 93e967a`. That commit gave `_event` a `deviceId` override
// so `connect → X` and its two failure lines could name their target before a
// session exists, and its doc comment stated the row "does NOT open a session:
// the attempt has not started, and `sessionId` staying null says so honestly".
// Only `deviceId` was actually overridden; `sessionId` kept reading
// `_session.sessionId`.
//
// The case the override exists for is exactly the case where a session IS live.
// `ConnectionController.connect()` writes its `connect →` line BEFORE tearing
// the previous link down, so while unit Y is connected the row went out as
// `device_id=X, session_id=<Y's session>` — a device/session pair that never
// existed. `LogRepo.exportLog` sections on deviceId/sessionId/appBuild, so that
// one row minted a one-line section header claiming Y's connection number for
// X, and an all-devices export showed the same session number under two
// different device headings.
//
// Nothing pinned this before, which is how it survived a release.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Minimal BLE stand-in: it never touches a radio, it only lets the test say
/// which device the controller currently HOLDS and drive link transitions.
class _StubBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  /// What `connectedDeviceId` reports — the handle we actually hold, which is
  /// what `_onLinkState` prefers when opening a session.
  String? held;

  /// Targets passed to [connect], in order.
  final List<String> connectCalls = [];

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
      {Duration? timeout, bool autoConnect = false}) async {
    connectCalls.add(deviceId);
    // Deliberately does NOT emit any link state: the window under test is the
    // one between `connect → X` being written and the old link being torn down,
    // so the incumbent must still be the live session when the row lands.
  }

  @override
  Future<void> disconnect() async {}

  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

/// Let the unawaited `_event` inserts land. A microtask hop is not enough —
/// `insertLog` is a two-step DB round trip.
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

  /// The `connect →` row, found by its message rather than by position (scan
  /// and link lines share the table).
  LogEntry connectLine(List<LogEntry> rows, String target) => rows.firstWhere(
        (e) => e.note == 'connect → ${shortDeviceHash(target)}',
      );

  test('while Y is live, `connect → X` carries X and NO session', () async {
    final ble = _StubBle();
    final s = await makeServices(ble);
    addTearDown(s.dispose);

    // Y is connected and recording: session 1 belongs to it.
    ble.held = 'YY';
    ble.emitLink(BleLinkState.ready);
    await settle();
    expect(s.connection.session.deviceId, 'YY');
    final ySession = s.connection.session.sessionId;
    expect(ySession, isNotNull);

    // The user picks a different unit. `connect()` logs before tearing Y down,
    // so the session context still reads Y at this instant.
    await s.connection.connect('XX');
    await settle();
    expect(ble.connectCalls, ['XX']);

    final row = connectLine(await s.logRepo.queryLog(), 'XX');
    expect(row.deviceId, 'XX', reason: 'the line names its target');
    expect(row.sessionId, isNull,
        reason: "Y's session id must not travel with a row about X");
  });

  test('the incumbent keeps its own rows attributed', () async {
    // The fix must not leak backwards: Y's own lines still carry Y's session.
    final ble = _StubBle();
    final s = await makeServices(ble);
    addTearDown(s.dispose);

    ble.held = 'YY';
    ble.emitLink(BleLinkState.ready);
    await settle();
    final ySession = s.connection.session.sessionId;

    await s.connection.connect('XX');
    await settle();

    final ready = (await s.logRepo.queryLog())
        .firstWhere((e) => e.note == 'link: ready');
    expect(ready.deviceId, 'YY');
    expect(ready.sessionId, ySession);
  });

  test('a reconnect to the LIVE device keeps that session', () async {
    // The override names the unit already being recorded, so the session really
    // is this row's own. Dropping it here would throw away good attribution.
    final ble = _StubBle();
    final s = await makeServices(ble);
    addTearDown(s.dispose);

    ble.held = 'YY';
    ble.emitLink(BleLinkState.ready);
    await settle();
    final ySession = s.connection.session.sessionId;

    await s.connection.connect('YY');
    await settle();

    final row = connectLine(await s.logRepo.queryLog(), 'YY');
    expect(row.deviceId, 'YY');
    expect(row.sessionId, ySession);
  });

  test('connecting from idle is unattributed to any session', () async {
    // The pre-existing intent, unchanged: no session is open, so none is
    // claimed. This held before the fix only because there was nothing to
    // borrow.
    final ble = _StubBle();
    final s = await makeServices(ble);
    addTearDown(s.dispose);

    await s.connection.connect('XX');
    await settle();

    final row = connectLine(await s.logRepo.queryLog(), 'XX');
    expect(row.deviceId, 'XX');
    expect(row.sessionId, isNull);
  });

  test('no session number appears under two devices in one export', () async {
    // The user-visible damage. `exportLog` sections on device/session/build, so
    // the borrowed id produced a one-line section header claiming Y's
    // connection for X.
    final ble = _StubBle();
    final s = await makeServices(ble);
    addTearDown(s.dispose);

    ble.held = 'YY';
    ble.emitLink(BleLinkState.ready);
    await settle();
    final ySession = s.connection.session.sessionId;

    await s.connection.connect('XX');
    await settle();

    final out = await s.logRepo.exportLog(
      labelFor: (id) => id == 'YY' ? 'rear-batt' : 'front-cap',
    );
    // Matched on substrings, not on whole lines: the label also carries
    // `app=<build>` (design 0010), which is `unknown` on a test host.
    final separators =
        out.split('\n').where((l) => l.startsWith('# ----')).toList();
    expect(separators, hasLength(2));
    expect(
      separators.where((l) => l.contains('session=$ySession')),
      hasLength(1),
      reason: 'one connection number belongs to exactly one device',
    );
    expect(
      separators.singleWhere((l) => l.contains('device=front-cap')),
      isNot(contains('session=')),
      reason: "X's section must not claim any connection, least of all Y's",
    );
    expect(
      separators.singleWhere((l) => l.contains('device=rear-batt')),
      contains('session=$ySession'),
    );
  });
}
