// Data-layer unit tests (sqflite repositories) using an in-memory database.
//
// Uses sqflite_common_ffi so the tests run headless on the host VM (no Android
// emulator / no platform channels). This exercises OUR app DB (not the
// vendor's): HistoryRepo, DeviceRepo, SettingsRepo, LogRepo.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_rce_batt/data/data.dart';
import 'package:open_rce_batt/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // Initialise the ffi sqlite implementation once for the whole suite.
  setUpAll(() {
    sqfliteFfiInit();
  });

  // Fresh in-memory DB per test for isolation.
  late AppDatabase appDb;
  setUp(() async {
    appDb = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await appDb.close();
  });

  group('HistoryRepo', () {
    test('insert + query round-trips a telemetry sample', () async {
      final repo = HistoryRepo(appDb.db);
      final at = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
      final sample = TelemetrySample(
        timestamp: at,
        pvlt: 12.36,
        svlt: 13.10,
        current: 1.5,
        temperatureC: 25,
        dvol: const [3.30, 3.31, 3.29, 3.32],
        sohBucket: 95,
        mode: 0x05,
        twfRaw: 0x00,
        serial: '0001234',
      );

      final id = await repo.insertSample(sample);
      expect(id, greaterThan(0));
      expect(await repo.count(), 1);

      final rows = await repo.querySamples();
      expect(rows, hasLength(1));
      final r = rows.single;
      expect(r.timestamp.millisecondsSinceEpoch, at.millisecondsSinceEpoch);
      expect(r.pvlt, closeTo(12.36, 1e-9));
      expect(r.svlt, closeTo(13.10, 1e-9));
      expect(r.current, closeTo(1.5, 1e-9));
      expect(r.temperatureC, 25);
      expect(r.dvol, [3.30, 3.31, 3.29, 3.32]);
      expect(r.sohBucket, 95);
      expect(r.mode, 0x05);
      expect(r.twfRaw, 0x00);
      expect(r.serial, '0001234');
    });

    test('querySamples returns newest-first', () async {
      final repo = HistoryRepo(appDb.db);
      final base = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
      await repo.insertSample(TelemetrySample(timestamp: base, pvlt: 11.0));
      await repo.insertSample(
        TelemetrySample(timestamp: base.add(const Duration(seconds: 1)), pvlt: 12.0),
      );
      await repo.insertSample(
        TelemetrySample(timestamp: base.add(const Duration(seconds: 2)), pvlt: 13.0),
      );

      final rows = await repo.querySamples();
      expect(rows.map((e) => e.pvlt).toList(), [13.0, 12.0, 11.0]);
    });

    test('querySamples respects since + limit', () async {
      final repo = HistoryRepo(appDb.db);
      final base = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
      for (var i = 0; i < 5; i++) {
        await repo.insertSample(
          TelemetrySample(
            timestamp: base.add(Duration(seconds: i)),
            pvlt: 10.0 + i,
          ),
        );
      }

      final since = base.add(const Duration(seconds: 2));
      final filtered = await repo.querySamples(since: since);
      expect(filtered, hasLength(3)); // seconds 2,3,4

      final limited = await repo.querySamples(limit: 2);
      expect(limited, hasLength(2));
      expect(limited.first.pvlt, 14.0); // newest first
    });

    test('clearHistory + deleteOlderThan', () async {
      final repo = HistoryRepo(appDb.db);
      final base = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
      for (var i = 0; i < 4; i++) {
        await repo.insertSample(
          TelemetrySample(timestamp: base.add(Duration(seconds: i))),
        );
      }
      expect(await repo.count(), 4);

      final removed =
          await repo.deleteOlderThan(base.add(const Duration(seconds: 2)));
      expect(removed, 2); // seconds 0,1
      expect(await repo.count(), 2);

      await repo.clearHistory();
      expect(await repo.count(), 0);
    });

    test('exportCsv emits header + ISO timestamp + values', () async {
      final repo = HistoryRepo(appDb.db);
      // Local DateTime: the row stores epoch-ms and re-hydrates as local time,
      // so the exported ISO string equals this value's toIso8601String().
      final at = DateTime(2026, 6, 29, 13, 9, 12);
      await repo.insertSample(
        TelemetrySample(
          timestamp: at,
          pvlt: 12.36,
          svlt: 13.10,
          current: 1.5,
          temperatureC: 25,
          dvol: const [3.30, 3.31, 3.29, 3.32],
          sohBucket: 95,
          mode: 5,
          twfRaw: 0,
          serial: '0001234',
        ),
      );

      final csv = await repo.exportCsv();
      final lines = csv.split('\r\n');
      // Header row matches the documented column order.
      expect(lines.first, HistoryRepo.csvColumns.join(','));
      // Data row: timestamp rendered ISO-8601, not epoch-ms.
      expect(lines[1], contains(at.toIso8601String()));
      expect(lines[1], contains('12.36'));
      expect(lines[1], contains('0001234'));
      expect(lines[1], isNot(contains('${at.millisecondsSinceEpoch}')));
    });

    test('exportCsv on empty history is header-only', () async {
      final repo = HistoryRepo(appDb.db);
      final csv = await repo.exportCsv();
      expect(csv, HistoryRepo.csvColumns.join(','));
    });

    test('insertSamples batch-inserts in one transaction', () async {
      final repo = HistoryRepo(appDb.db);
      final base = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
      await repo.insertSamples([
        TelemetrySample(timestamp: base, pvlt: 10),
        TelemetrySample(timestamp: base.add(const Duration(seconds: 1)), pvlt: 11),
        TelemetrySample(timestamp: base.add(const Duration(seconds: 2)), pvlt: 12),
      ]);
      expect(await repo.count(), 3);
    });
  });

  group('DeviceRepo (alias CRUD)', () {
    test('upsert + get round-trips a saved device', () async {
      final repo = DeviceRepo(appDb.db);
      final seen = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
      await repo.upsertSavedDevice(
        SavedDevice(
          id: 'AA:BB:CC:DD:EE:FF',
          alias: '電容 #1（前車）',
          lastSeen: seen,
          lastValue: 12.7,
        ),
      );

      final d = await repo.getDevice('AA:BB:CC:DD:EE:FF');
      expect(d, isNotNull);
      expect(d!.alias, '電容 #1（前車）');
      expect(d.lastSeen!.millisecondsSinceEpoch, seen.millisecondsSinceEpoch);
      expect(d.lastValue, closeTo(12.7, 1e-9));
      expect(await repo.isSaved('AA:BB:CC:DD:EE:FF'), isTrue);
      expect(await repo.isSaved('NOPE'), isFalse);
      expect(await repo.getDevice('NOPE'), isNull);
    });

    test('upsert replaces an existing device (same id)', () async {
      final repo = DeviceRepo(appDb.db);
      await repo.upsertSavedDevice(
        const SavedDevice(id: 'id-1', alias: 'first'),
      );
      await repo.upsertSavedDevice(
        const SavedDevice(id: 'id-1', alias: 'second'),
      );

      final all = await repo.getSavedDevices();
      expect(all, hasLength(1));
      expect(all.single.alias, 'second');
    });

    test('updateAlias edits only the alias', () async {
      final repo = DeviceRepo(appDb.db);
      final seen = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
      await repo.upsertSavedDevice(
        SavedDevice(id: 'id-1', alias: 'old', lastSeen: seen, lastValue: 5),
      );

      final affected = await repo.updateAlias('id-1', 'renamed');
      expect(affected, 1);

      final d = await repo.getDevice('id-1');
      expect(d!.alias, 'renamed');
      // Other fields untouched.
      expect(d.lastSeen!.millisecondsSinceEpoch, seen.millisecondsSinceEpoch);
      expect(d.lastValue, closeTo(5, 1e-9));
    });

    test('touch updates last_seen / last_value', () async {
      final repo = DeviceRepo(appDb.db);
      await repo.upsertSavedDevice(const SavedDevice(id: 'id-1', alias: 'a'));
      final when = DateTime.fromMillisecondsSinceEpoch(1_700_000_500_000);

      final affected =
          await repo.touch('id-1', lastSeen: when, lastValue: 13.4);
      expect(affected, 1);

      final d = await repo.getDevice('id-1');
      expect(d!.lastSeen!.millisecondsSinceEpoch, when.millisecondsSinceEpoch);
      expect(d.lastValue, closeTo(13.4, 1e-9));
    });

    test('deleteSavedDevice removes the row', () async {
      final repo = DeviceRepo(appDb.db);
      await repo.upsertSavedDevice(const SavedDevice(id: 'id-1', alias: 'a'));
      expect(await repo.deleteSavedDevice('id-1'), 1);
      expect(await repo.getSavedDevices(), isEmpty);
    });

    test('getSavedDevices orders most-recently-seen first, nulls last',
        () async {
      final repo = DeviceRepo(appDb.db);
      final base = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
      await repo.upsertSavedDevice(
        SavedDevice(id: 'old', alias: 'old', lastSeen: base),
      );
      await repo.upsertSavedDevice(
        SavedDevice(
          id: 'new',
          alias: 'new',
          lastSeen: base.add(const Duration(hours: 1)),
        ),
      );
      await repo.upsertSavedDevice(
        const SavedDevice(id: 'never', alias: 'never'), // lastSeen == null
      );

      final ids = (await repo.getSavedDevices()).map((e) => e.id).toList();
      expect(ids, ['new', 'old', 'never']);
    });
  });

  group('SettingsRepo (defaults + persistence)', () {
    test('loadSettings returns defaults when nothing is stored', () async {
      final repo = SettingsRepo(appDb.db);
      final s = await repo.loadSettings();
      // Diagnostics raw-packet log is OFF by default (the headline requirement).
      expect(s.rawPacketLog, isFalse);
      // And the rest of the documented defaults.
      expect(s.autoReconnect, isTrue);
      expect(s.pollIntervalMs, 1000);
      expect(s.backgroundKeepAlive, isFalse);
      expect(s.darkTheme, isTrue);
      expect(s.lang, AppLang.zhHant);
      expect(s.tempUnit, TempUnit.celsius);
      expect(s.autoLog, isTrue);
      expect(s.logMaxBytes, 5 * 1024 * 1024);
    });

    test('save then load round-trips a non-default config', () async {
      final repo = SettingsRepo(appDb.db);
      const custom = AppSettings(
        autoReconnect: false,
        pollIntervalMs: 500,
        backgroundKeepAlive: true,
        darkTheme: false,
        lang: AppLang.en,
        tempUnit: TempUnit.fahrenheit,
        autoLog: false,
        rawPacketLog: true,
        logMaxBytes: 20 * 1024 * 1024,
      );
      await repo.saveSettings(custom);

      final s = await repo.loadSettings();
      expect(s.autoReconnect, isFalse);
      expect(s.pollIntervalMs, 500);
      expect(s.backgroundKeepAlive, isTrue);
      expect(s.darkTheme, isFalse);
      expect(s.lang, AppLang.en);
      expect(s.tempUnit, TempUnit.fahrenheit);
      expect(s.autoLog, isFalse);
      expect(s.rawPacketLog, isTrue);
      expect(s.logMaxBytes, 20 * 1024 * 1024);
    });

    test('saveSettings stays a single row (insert-or-replace)', () async {
      final repo = SettingsRepo(appDb.db);
      await repo.saveSettings(AppSettings.defaults);
      await repo.saveSettings(
        AppSettings.defaults.copyWith(rawPacketLog: true),
      );
      final rows = await appDb.db.query(Db.tableSettings);
      expect(rows, hasLength(1));
      expect((await repo.loadSettings()).rawPacketLog, isTrue);
    });

    test('resetToDefaults turns diagnostics back OFF', () async {
      final repo = SettingsRepo(appDb.db);
      await repo.saveSettings(
        AppSettings.defaults.copyWith(rawPacketLog: true, pollIntervalMs: 2000),
      );
      expect((await repo.loadSettings()).rawPacketLog, isTrue);

      await repo.resetToDefaults();
      final s = await repo.loadSettings();
      expect(s.rawPacketLog, isFalse);
      expect(s.pollIntervalMs, 1000);
    });
  });

  group('LogRepo (diagnostic packet log)', () {
    test('insert + query newest-first and export oldest-first', () async {
      final repo = LogRepo(appDb.db);
      final t0 = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
      await repo.insertLog(
        LogEntry.fromBytes(LogDirection.tx, const [0x23], at: t0, note: 'keep-alive'),
      );
      await repo.insertLog(
        LogEntry.fromBytes(
          LogDirection.rx,
          const [0xB8, 0x19, 0x01, 0x02, 0x04, 0xD4],
          at: t0.add(const Duration(milliseconds: 1)),
        ),
      );
      expect(await repo.count(), 2);

      final newest = await repo.queryLog();
      expect(newest.first.direction, LogDirection.rx);
      expect(newest.first.hex, 'b8190102 04d4'.replaceAll(' ', ''));

      final exported = await repo.exportLog().then((s) => s.split('\n'));
      expect(exported.first, contains('TX'));
      expect(exported.first, contains('keep-alive'));
      expect(exported.last, contains('RX'));
    });

    test('clearLog empties the table', () async {
      final repo = LogRepo(appDb.db);
      await repo.insertLog(
        LogEntry.fromBytes(LogDirection.tx, const [0x23]),
      );
      await repo.clearLog();
      expect(await repo.count(), 0);
    });

    test('trimToBytes drops oldest rows to stay within budget', () async {
      final repo = LogRepo(appDb.db);
      final t0 = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
      // Insert 50 entries, then enforce a tiny byte budget.
      for (var i = 0; i < 50; i++) {
        await repo.insertLog(
          LogEntry.fromBytes(
            LogDirection.tx,
            const [0xB8, 0x19, 0x01, 0x02, 0x04, 0xD4],
            at: t0.add(Duration(milliseconds: i)),
          ),
        );
      }
      final before = await repo.count();
      expect(before, 50);

      await repo.trimToBytes(200);
      expect(await repo.approxBytes(), lessThanOrEqualTo(200));
      expect(await repo.count(), lessThan(before));
    });
  });
}
