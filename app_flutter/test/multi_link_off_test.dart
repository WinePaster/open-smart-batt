// design 0103 §3.1.2 — 🔴 switch OFF ⇒ the single-link path, unchanged.
//
// `flutter test` builds without `--dart-define=OSB_MULTILINK=true`, which is
// exactly the build every normal user gets. These tests pin that, in the three
// shapes 0103 asks for:
//   1. the experiment does not exist: no controller, no hook bound;
//   2. connecting a second unit still tears the first down — one link, ever;
//   3. the bytes on the wire are the ones the seam golden recorded before the
//      experiment was written (design 0099's `tx_battery.txt`).
// plus the transport hooks the experiment added, proven inert until called.
import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/config/multi_link_config.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/demo/demo.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

class _FakePrimary extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  String? connectedId;
  @override
  String? get connectedDeviceId => connectedId;
  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
  void emitLink(BleLinkState s) => _linkOut.add(s);
  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('1. the default build has no multi-link experiment at all', () async {
    expect(kMultiLinkBuild, isFalse,
        reason: 'flutter test must build what normal users get');
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    final ble = _FakePrimary();
    final s = await AppServices.create(appDatabase: db, ble: ble);
    expect(s.multiLink, isNull);
    expect(s.connection.multiLink, isNull);
    await s.pending.drain();
    await s.dispose();
  });

  test('1b. isOnlineFor is the old `isOnline && connectedDeviceId == id`',
      () async {
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    final ble = _FakePrimary();
    final s = await AppServices.create(appDatabase: db, ble: ble);
    final conn = s.connection;
    bool old(String id) => conn.isOnline && conn.connectedDeviceId == id;
    Future<void> check() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      for (final id in ['A', 'B']) {
        expect(conn.isOnlineFor(id), old(id), reason: 'id=$id');
      }
    }

    await check(); // nothing connected
    ble.connectedId = 'A';
    ble.emitLink(BleLinkState.connecting);
    await check(); // connecting: not online
    ble.emitLink(BleLinkState.ready);
    await check(); // A online, B not
    expect(conn.isOnlineFor('A'), isTrue);
    ble.emitLink(BleLinkState.disconnected);
    await check();
    await s.pending.drain();
    await s.dispose();
  });

  group('over the real transport (demo links)', () {
    const channel = MethodChannel('flutter_blue_plus/methods');
    late Duration savedConnect;
    late Duration savedReply;

    setUp(() {
      savedConnect = BleService.demoConnectDelay;
      savedReply = BleService.demoReplyDelay;
      BleService.demoConnectDelay = Duration.zero;
      BleService.demoReplyDelay = Duration.zero;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
    });

    tearDown(() {
      BleService.demoConnectDelay = savedConnect;
      BleService.demoReplyDelay = savedReply;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('2. connecting a second unit tears the first one down', () {
      final txBy = <String, int>{};
      fakeAsync((async) {
        final ble = BleService();
        final sub = ble.packets.listen((e) {
          if (e.direction == LogDirection.tx) {
            txBy[e.deviceId ?? '?'] = (txBy[e.deviceId ?? '?'] ?? 0) + 1;
          }
        });
        ble.connect(DemoKind.battery.id);
        async.elapse(const Duration(seconds: 5));
        final before = txBy[DemoKind.battery.id] ?? 0;
        expect(before, greaterThan(3));
        ble.connect(DemoKind.capacitor.id);
        async.elapse(const Duration(seconds: 10));
        expect(ble.connectedDeviceId, DemoKind.capacitor.id);
        expect(txBy[DemoKind.battery.id], before,
            reason: 'the first link wrote nothing after being displaced');
        expect(txBy[DemoKind.capacitor.id], greaterThan(5));
        ble.disconnect();
        async.elapse(const Duration(seconds: 1));
        sub.cancel();
        ble.dispose();
        async.flushMicrotasks();
      });
    });

    test('3. TX bytes equal the pre-experiment seam golden (battery demo)', () {
      // Same script as seam_golden_test.dart b., on a BleService built the way
      // AppServices builds the primary when the flag is off.
      final tx = <String>[];
      fakeAsync((async) {
        final ble = BleService();
        final sub = ble.packets.listen((e) {
          if (e.direction == LogDirection.tx) tx.add(_hex(e.bytes));
        });
        ble.connect(DemoKind.battery.id);
        async.elapse(const Duration(seconds: 3));
        ble.sendAuth(cb: 0x0168, pwSum: 0x01E4);
        async.elapse(const Duration(milliseconds: 100));
        ble.switchMode(ModeArg.cutOff, cb: 0x0168, pwSum: 0x01E4);
        async.elapse(const Duration(milliseconds: 100));
        ble.writeCommand(const CommandBuilder().modeSet(ModeArg.unlock));
        async.elapse(const Duration(milliseconds: 100));
        ble.writeCommand(const CommandBuilder().modeReadBack());
        async.elapse(const Duration(seconds: 57));
        ble.disconnect();
        async.elapse(const Duration(seconds: 2));
        sub.cancel();
        ble.dispose();
        async.flushMicrotasks();
      });
      final want = File('test/goldens/seam_0099/tx_battery.txt')
          .readAsStringSync()
          .trimRight()
          .split('\n');
      expect(tx, want);
    });

    test('the experiment hooks are inert until called', () {
      fakeAsync((async) {
        final ble = BleService();
        expect(ble.trackWriteWindow, isFalse);
        ble.connect(DemoKind.battery.id);
        async.elapse(const Duration(seconds: 70));
        expect(ble.pollPausedAt, isNull);
        expect(ble.recentWriteAvgMs, isNull,
            reason: 'no window is kept unless the experiment asks');
        ble.disconnect();
        async.elapse(const Duration(seconds: 1));
        ble.dispose();
        async.flushMicrotasks();
      });
    });

    test('on-path: pause stops the poll, keeps the push; resume writes at once',
        () {
      final tx = <int>[];
      final notes = <String>[];
      var rx = 0;
      fakeAsync((async) {
        final ble = BleService()..trackWriteWindow = true;
        final sub = ble.packets.listen((e) {
          if (e.direction == LogDirection.tx) tx.add(1);
          if (e.direction == LogDirection.rx) rx++;
          if (e.direction == LogDirection.event && e.note != null) {
            notes.add(e.note!);
          }
        });
        ble.connect(DemoKind.battery.id);
        async.elapse(const Duration(seconds: 65));
        expect(ble.recentWriteAvgMs, isNotNull, reason: '60 writes recorded');
        expect(ble.pausePolling(reason: 'test'), isTrue);
        expect(ble.pausePolling(reason: 'test'), isFalse, reason: 'once');
        final txAtPause = tx.length;
        async.elapse(const Duration(seconds: 10));
        expect(tx.length, txAtPause, reason: 'no poll while paused');
        ble.resumePolling();
        async.flushMicrotasks();
        expect(tx.length, txAtPause + 1, reason: 'first poll goes out at once');
        async.elapse(const Duration(seconds: 3));
        expect(tx.length, greaterThan(txAtPause + 2));
        expect(notes.any((n) => n.startsWith('link paused')), isTrue);
        expect(notes.any((n) => n.startsWith('link resumed')), isTrue);
        expect(rx, greaterThan(0));
        ble.disconnect();
        async.elapse(const Duration(seconds: 1));
        sub.cancel();
        ble.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
