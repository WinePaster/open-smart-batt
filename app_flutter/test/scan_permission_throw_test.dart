// 2026-11-14 — ROG Phone 9 Pro (Android 16), 0.7.51+26111340: 重新掃描 did
// nothing. logcat showed no plugin call after the tap, and no app line either.
//
// The scan path's permission step sat outside every catch. Anything it threw
// (permission_handler reports "a request is already running" and "no Activity"
// as PlatformExceptions) escaped `startScan`, and `main.dart`'s
// platformDispatcher.onError swallowed it into the diagnostic log only. The
// screen kept the empty list; the button looked dead.
//
// What this pins: a throwing permission check is a reported scan failure —
// `startScan` completes, `lastError` is set, the log names it, and no scan
// intent is left behind.
//
// CLEAN-ROOM: expectations derive from our own source.
import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ThrowingPermissionBle extends BleService {
  final _adapterOut = StreamController<BluetoothAdapterState>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  int startScanCalls = 0;

  @override
  Stream<BluetoothAdapterState> get adapterState => _adapterOut.stream;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();

  @override
  Stream<BlePacketEvent> get packets => const Stream<BlePacketEvent>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => throw PlatformException(
        code: 'PermissionHandler.PermissionManager',
        message: 'A request for permissions is already running',
      );

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)}) async {
    startScanCalls++;
  }

  @override
  Future<void> stopScan() async {}

  void emitAdapter(BluetoothAdapterState s) => _adapterOut.add(s);

  @override
  Future<void> dispose() async {
    await _adapterOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('a permission check that throws is a reported scan failure', () {
    late AppDatabase db;
    late AppServices services;
    late _ThrowingPermissionBle ble;

    setUp(() async {
      db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _ThrowingPermissionBle();
      services = await AppServices.create(appDatabase: db, ble: ble);
      ble.emitAdapter(BluetoothAdapterState.on);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    tearDown(() async => services.dispose());

    test('startScan completes instead of throwing out of a tap handler',
        () async {
      await expectLater(services.connection.startScan(), completes);
      expect(ble.startScanCalls, 0,
          reason: 'no permission answer, no radio call');
    });

    test('the failure reaches lastError, so the screen can say something',
        () async {
      await services.connection.startScan();
      expect(services.connection.lastErrorUnattributed,
          contains('already running'));
    });

    test('and the diagnostic log names it as a scan abort', () async {
      await services.connection.startScan();
      await services.pending.drain();
      final notes = (await services.logRepo.queryLog())
          .map((e) => e.note)
          .whereType<String>()
          .toList();
      expect(
          notes.any((n) => n.startsWith('scan aborted: permission check failed')),
          isTrue);
      expect(notes, isNot(contains('scan start')),
          reason: 'a scan that never asked the radio did not start');
    });
  });
}
