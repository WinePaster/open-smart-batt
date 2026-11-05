// design 0097 P2 — a demo session must leave no trace in what users send us.
//
// Runs a REAL demo link (real BleService, real controllers, in-memory DB) with
// the raw packet log on, so every writer that could leak is actually writing.
//
// T3: during a demo session, demo ids exist in `history` and nowhere else.
// T4: CSV and diagnostic-log exports carry zero demo rows, all real rows.
// T5: the demo's rows are purged when the link ends, and again at startup.
// T6: a cut-off round-trip works on the demo battery and logs nothing.
//
// Plus: the demo connects with no Bluetooth permission plugin available at
// all — a real connect would throw on the missing channel.
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/demo/demo.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _realId = 'AA:BB:CC:DD:EE:01';

/// The REAL [BleService] — connect, the demo link, writes and teardown are all
/// the production code. Only the adapter/scan streams are stubbed, because the
/// plugin behind them does not exist on a test host.
class _HostBle extends BleService {
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;
}

Future<int> _demoRows(AppServices s, String table) async {
  final r = await s.appDb.db.rawQuery(
      'SELECT COUNT(*) AS n FROM $table WHERE $kDemoRowSql');
  return (r.first['n'] as num).toInt();
}

Future<int> _demoIdRows(AppServices s, String table, String column) async {
  final r = await s.appDb.db.rawQuery(
      "SELECT COUNT(*) AS n FROM $table WHERE $column LIKE 'DEMO-%'");
  return (r.first['n'] as num).toInt();
}

Future<void> _waitFor(bool Function() ok, {int ms = 5000}) async {
  final sw = Stopwatch()..start();
  while (!ok()) {
    if (sw.elapsedMilliseconds > ms) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  setUp(() {
    BleService.demoConnectDelay = Duration.zero;
    BleService.demoReplyDelay = Duration.zero;
  });

  Future<AppServices> open(AppDatabase db) async {
    final s = await AppServices.create(appDatabase: db, ble: _HostBle());
    await s.settings.setRawPacketLog(true);
    return s;
  }

  // A file per test: `inMemoryDatabasePath` is ONE database shared by every
  // open in the process, so rows would leak from one case into the next.
  Future<AppDatabase> newDb() async {
    final dir = await Directory.systemTemp.createTemp('osb_demo_');
    addTearDown(() => dir.delete(recursive: true));
    return AppDatabase.open(
        path: '${dir.path}/app.db', factory: databaseFactoryFfi);
  }

  /// Some REAL data, so exports have something that must survive.
  Future<void> seedReal(AppServices s) async {
    await s.historyRepo.insertSample(
      TelemetrySample.empty().copyWith(
          timestamp: DateTime.now().subtract(const Duration(hours: 1)),
          pvlt: 12.9,
          deviceType: 0x02),
      deviceId: _realId,
    );
    await s.logRepo.insertLog(LogEntry.event('real unit line', deviceId: _realId));
  }

  for (final kind in DemoKind.values) {
    test('${kind.id}: T3/T4/T5 — isolated while running, gone after', () async {
      final db = await newDb();
      final s = await open(db);
      await seedReal(s);

      await s.connection.connect(kind.id);
      await _waitFor(() => s.ble.currentState == BleLinkState.ready);
      // ≥ 2 keep-alive answers, then let the seed and live rows commit.
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      s.telemetry.flushPendingHistory();
      await s.pending.drain();

      // T3 — history holds the demo (seed + live) …
      final seeded = await _demoRows(s, Db.tableHistory);
      expect(seeded, greaterThanOrEqualTo(demoHistorySpan.inMinutes),
          reason: 'the 24 h seed should be in history');
      // … and nothing else does.
      expect(await _demoRows(s, Db.tableDiagLog), 0, reason: 'diagnostic log');
      expect(await _demoIdRows(s, Db.tableSavedDevices, 'id'), 0,
          reason: 'saved devices');
      expect(await _demoIdRows(s, Db.tableDeviceFacts, 'id'), 0,
          reason: 'device facts');
      expect(await _demoIdRows(s, Db.tableAutoConnectArm, 'device_id'), 0,
          reason: 'auto-connect arm');
      expect(s.devices.deviceFor(kind.id), isNull);

      // T4 — exports, all devices and scoped to the demo unit.
      final all = await s.historyRepo
          .exportCsv(header: const ['h'], labelFor: (id) => id ?? '-');
      expect(all.text, isNot(contains(kDemoIdPrefix)));
      expect(all.text, contains(_realId));
      expect(all.text, isNot(contains('rows from other devices')),
          reason: 'demo rows must not be reported as dropped');
      final scoped = await s.historyRepo.exportCsv(deviceId: kind.id);
      expect(scoped.rows, 0);
      final real = await s.historyRepo.exportCsv(
          deviceId: _realId, header: const ['h'], labelFor: (id) => id ?? '-');
      expect(real.text, contains(_realId));
      expect(real.text, isNot(contains('rows from other devices')));
      final log = await s.logRepo.exportLog(labelFor: (id) => id ?? '-');
      expect(log, isNot(contains(kDemoIdPrefix)));
      expect(log, contains('real unit line'));

      // T5 — the purge on disconnect.
      await s.connection.disconnect();
      await _waitFor(() => s.ble.currentState == BleLinkState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await s.pending.drain();
      expect(await _demoRows(s, Db.tableHistory), 0);
      final after =
          await s.historyRepo.exportCsv(labelFor: (id) => id ?? '-');
      expect(after.text, contains(_realId), reason: 'real rows untouched');

      await s.dispose();
    });
  }

  test('T5 — demo rows left behind are purged at startup', () async {
    final db = await newDb();
    final s1 = await open(db);
    await s1.historyRepo.insertSamples(
        demoHistorySeed(DemoKind.battery, DateTime.now()).take(5));
    await s1.historyRepo.insertSample(
        TelemetrySample.empty().copyWith(timestamp: DateTime.now(), pvlt: 12.8),
        deviceId: _realId);
    expect(await _demoRows(s1, Db.tableHistory), 5);
    // A second composition root over the SAME database = the next launch.
    final s2 = await AppServices.create(appDatabase: db, ble: _HostBle());
    expect(await _demoRows(s2, Db.tableHistory), 0);
    final real = await s2.appDb.db.rawQuery(
        'SELECT COUNT(*) AS n FROM ${Db.tableHistory} WHERE device_id = ?',
        [_realId]);
    expect((real.first['n'] as num).toInt(), 1);
    await s2.dispose();
  });

  test('T6 — demo battery cut-off and release, nothing logged', () async {
    final db = await newDb();
    final s = await open(db);
    await s.connection.connect(DemoKind.battery.id);
    await _waitFor(() => s.ble.currentState == BleLinkState.ready);

    await s.connection.switchMode(ModeArg.cutOff, cb: 1, pwSum: 2);
    await _waitFor(
        () => s.ble.currentSample.mode == ReportedStatus.cutOffActive);
    await s.connection.releaseCutOff(cb: 1, pwSum: 2);
    await _waitFor(() => s.ble.currentSample.mode == ReportedStatus.normal);

    await s.pending.drain();
    expect(await _demoRows(s, Db.tableDiagLog), 0);
    await s.connection.disconnect();
    await s.dispose();
  });

  test('T4 — the log export drops a demo row even if one got in', () async {
    final db = await newDb();
    final s = await open(db);
    await seedReal(s);
    // Bypass insertLog's gate, to prove the export's own filter.
    await s.appDb.db.insert(Db.tableDiagLog, {
      ...LogEntry.event('demo line', deviceId: DemoKind.battery.id).toMap(),
    }..remove('id'));
    final log = await s.logRepo.exportLog();
    expect(log, isNot(contains('demo line')));
    expect(log, contains('real unit line'));
    await s.dispose();
  });

  test('ending demo A purges only A; bucket widths ignore demo rows', () async {
    final db = await newDb();
    final s = await open(db);
    // A 1 s row, so it differs from the demo seed's 60 s.
    await s.historyRepo.insertSamples([
      HistoryWrite(
          sample: TelemetrySample.empty()
              .copyWith(timestamp: DateTime.now(), pvlt: 12.8),
          deviceId: _realId),
    ]);
    await s.historyRepo.insertSamples(
        demoHistorySeed(DemoKind.battery, DateTime.now()).take(3));
    await s.historyRepo.insertSamples(
        demoHistorySeed(DemoKind.capacitor, DateTime.now()).take(4));
    expect(await s.historyRepo.distinctBucketWidths(), [1],
        reason: 'the 60 s demo seed must not show up in an export header');
    await s.historyRepo.purgeDemoRows(deviceId: DemoKind.battery.id);
    expect(await _demoRows(s, Db.tableHistory), 4,
        reason: 'demo B\'s rows survive the end of demo A');
    expect(() => s.historyRepo.purgeDemoRows(deviceId: _realId),
        throwsArgumentError);
    await s.dispose();
  });

  test('a demo unit cannot be saved', () async {
    final db = await newDb();
    final s = await open(db);
    await expectLater(
        s.devices.saveNew(DemoKind.capacitor.id, 'x'), throwsArgumentError);
    await s.dispose();
  });
}
