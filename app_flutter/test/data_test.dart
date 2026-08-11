// Data-layer unit tests (sqflite repositories) using an in-memory database.
//
// Uses sqflite_common_ffi so the tests run headless on the host VM (no Android
// emulator / no platform channels). This exercises OUR app DB (not the
// vendor's): HistoryRepo, DeviceRepo, SettingsRepo, LogRepo.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
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

      final csv = (await repo.exportCsv()).text;
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
      final csv = (await repo.exportCsv()).text;
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

    // D.3: the v3 schema persists `name` (stable advertised name) and `stale`
    // so the iOS NSUUID rebind can actually fire after a reinstall. Before the
    // fix toMap() dropped these columns and they always round-tripped empty.
    test('persists name + stale, enabling rebind after NSUUID rotation',
        () async {
      final repo = DeviceRepo(appDb.db);
      await repo.upsertSavedDevice(
        const SavedDevice(
          id: 'old-nsuuid',
          alias: '電容 #1',
          name: 'RCE-SCAP_II',
          stale: true,
        ),
      );

      final d = await repo.getDevice('old-nsuuid');
      expect(d, isNotNull);
      expect(d!.name, 'RCE-SCAP_II'); // column now exists + is written
      expect(d.stale, isTrue);

      // Simulate a reinstall: same physical battery now advertises a NEW
      // NSUUID. rebindSavedDeviceId must resolve to it via the persisted name.
      final rebound = rebindSavedDeviceId(
        savedId: d.id,
        savedName: d.name,
        candidates: const {'new-nsuuid': 'RCE-SCAP_II'},
        useNameKey: true, // iOS
      );
      expect(rebound, 'new-nsuuid');
    });

    // The v4 schema persists the resolved product class / cosmetic pack label,
    // so an identified unit does not have to be re-identified on every later
    // connection. Old rows default to unknown.
    test('persists product_class and setProductClass updates it', () async {
      final repo = DeviceRepo(appDb.db);
      // A device saved without a class defaults to unknown (pre-migration rows).
      await repo.upsertSavedDevice(const SavedDevice(id: 'pack-1', alias: 'p'));
      expect((await repo.getDevice('pack-1'))!.productClass,
          ProductClass.unknown);

      // Upsert with an explicit label round-trips.
      await repo.upsertSavedDevice(const SavedDevice(
        id: 'pb-1',
        alias: 'bank',
        productClass: ProductClass.powerBank,
      ));
      expect((await repo.getDevice('pb-1'))!.productClass,
          ProductClass.powerBank);

      // setProductClass updates just the class column.
      final affected =
          await repo.setProductClass('pack-1', ProductClass.smartBattery);
      expect(affected, 1);
      final d = await repo.getDevice('pack-1');
      expect(d!.productClass, ProductClass.smartBattery);
      expect(d.alias, 'p'); // untouched
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
      expect(s.keepScreenAwake, isFalse);
      // Background monitoring defaults ON — the stall it prevents is the
      // default experience without it.
      expect(s.backgroundMonitoring, isTrue);
      // Theme defaults to light (tri-state {light, dark, auto}).
      expect(s.themeMode, AppThemeMode.light);
      expect(s.lang, AppLang.zhHant);
      expect(s.tempUnit, TempUnit.celsius);
      expect(s.retention, RetentionPolicy.forever);
      // Reference the constant, not a literal: this assertion drifted once
      // already when the budget moved 5 MB -> 20 MB (2026-07-29).
      expect(s.logMaxBytes, AppSettings.defaultLogMaxBytes);
    });

    test('save then load round-trips a non-default config', () async {
      final repo = SettingsRepo(appDb.db);
      const custom = AppSettings(
        autoReconnect: false,
        pollIntervalMs: 500,
        backgroundMonitoring: false,
        keepScreenAwake: true,
        themeMode: AppThemeMode.auto,
        lang: AppLang.en,
        tempUnit: TempUnit.fahrenheit,
        retention: RetentionPolicy.days90,
        rawPacketLog: true,
        logMaxBytes: AppSettings.unlimitedLogBytes,
      );
      await repo.saveSettings(custom);

      final s = await repo.loadSettings();
      expect(s.autoReconnect, isFalse);
      expect(s.pollIntervalMs, 500);
      expect(s.keepScreenAwake, isTrue);
      expect(s.backgroundMonitoring, isFalse);
      expect(s.themeMode, AppThemeMode.auto);
      expect(s.lang, AppLang.en);
      expect(s.tempUnit, TempUnit.fahrenheit);
      expect(s.retention, RetentionPolicy.days90);
      expect(s.rawPacketLog, isTrue);
      // Unlimited is the interesting round-trip: it must survive storage as 0
      // rather than being normalised away as an unknown budget.
      expect(s.logMaxBytes, AppSettings.unlimitedLogBytes);
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
      // Rows are grouped under a `# ---- … ----` separator that names the unit
      // and connection they belong to; these predate attribution.
      expect(exported.first, '# ---- device=unattributed ----');
      final entries = exported.where((l) => !l.startsWith('#')).toList();
      expect(entries.first, contains('TX'));
      expect(entries.first, contains('keep-alive'));
      expect(entries.last, contains('RX'));
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

  // --- Rotation cost -------------------------------------------------------
  //
  // insertLog used to call trimToBytes on every insert, and trimToBytes opens
  // with a SUM(LENGTH(...)) over the whole table. Once the log reaches its cap
  // — the steady state, ~2 hours of capture at the measured median of 13
  // packets/s — that is two such scans plus a COUNT(*) per packet, over ~97,000
  // rows. These tests hold the cost down, not just the correctness: a comment
  // saying "O(1)" is not enforceable, a query count is.

  group('LogRepo rotation cost', () {
    late AppDatabase appDb;
    late _CountingDb db;

    setUp(() async {
      appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      db = _CountingDb(appDb.db);
    });
    tearDown(() async => appDb.close());

    // 6 payload bytes → 12 hex chars, no note ⇒ 12 + 40 = 52 bytes per row.
    LogEntry entry(int i) => LogEntry.fromBytes(
          LogDirection.rx,
          const [0xB8, 0x19, 0x01, 0x02, 0x04, 0xD4],
          at: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000)
              .add(Duration(milliseconds: i)),
        );

    test('steady-state inserts do not scan the table each time', () async {
      final repo = LogRepo(db);
      const cap = 20000; // ~385 rows; low water 18000 ⇒ ~38 rows of headroom.
      const inserts = 800;

      for (var i = 0; i < inserts; i++) {
        await repo.insertLog(entry(i), maxBytes: cap);
      }

      // The cap is still the contract.
      expect(await repo.approxBytes(), lessThanOrEqualTo(cap));

      // Before this change every insert scanned at least once, so scans >=
      // inserts. Headroom makes trims rare; the exact figure depends on row
      // size, hence a ratio rather than a magic number.
      expect(db.sumScans, lessThan(inserts ~/ 10),
          reason: 'insertLog should not scan the table on the hot path — '
              '${db.sumScans} scans for $inserts inserts');
    });

    test('a trim leaves headroom instead of stopping at the cap', () async {
      final repo = LogRepo(db);
      const cap = 20000;
      for (var i = 0; i < 500; i++) {
        await repo.insertLog(entry(i));
      }
      expect(await repo.approxBytes(), greaterThan(cap));

      await repo.trimToBytes(cap);

      // Under the cap — the caller's contract — and specifically under the low
      // water mark, which is what buys the headroom.
      final after = await repo.approxBytes();
      expect(after, lessThanOrEqualTo(cap));
      expect(after, lessThanOrEqualTo((cap * 0.9).floor()),
          reason: 'trimming to just under the cap re-trims on the next insert');
    });

    test('the running total survives an insert made without a budget',
        () async {
      final repo = LogRepo(db);
      const cap = 8000;
      // Budgeted inserts seed the running total...
      for (var i = 0; i < 50; i++) {
        await repo.insertLog(entry(i), maxBytes: cap);
      }
      // ...then a batch that bypasses it entirely. If the total were carried
      // forward unchanged it would now read low, and the cap would overrun.
      for (var i = 50; i < 400; i++) {
        await repo.insertLog(entry(i));
      }
      for (var i = 400; i < 450; i++) {
        await repo.insertLog(entry(i), maxBytes: cap);
      }

      expect(await repo.approxBytes(), lessThanOrEqualTo(cap));
    });

    test('clearLog resets the running total', () async {
      final repo = LogRepo(db);
      const cap = 8000;
      for (var i = 0; i < 300; i++) {
        await repo.insertLog(entry(i), maxBytes: cap);
      }
      await repo.clearLog();
      expect(await repo.count(), 0);

      // A stale non-zero total here would trim a nearly empty table.
      final scansBefore = db.sumScans;
      await repo.insertLog(entry(999), maxBytes: cap);
      expect(await repo.count(), 1);
      expect(db.sumScans, scansBefore,
          reason: 'a cleared log is known to be empty; no query needed');
    });
  });

  group('journal mode', () {
    // A real file, not `:memory:` — an in-memory database reports
    // `journal_mode = memory` whatever it is asked for, so it cannot show
    // whether _onConfigure did anything.
    late Directory dir;
    late AppDatabase fileDb;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('osb_wal');
      fileDb = await AppDatabase.open(
        path: p.join(dir.path, 'wal.db'),
        factory: databaseFactoryFfi,
      );
    });
    tearDown(() async {
      await fileDb.close();
      await dir.delete(recursive: true);
    });

    Future<String> pragma(String name) async {
      final r = await fileDb.db.rawQuery('PRAGMA $name');
      return '${r.first.values.first}'.toLowerCase();
    }

    test('WAL is on', () async {
      // ~3.5x on insert (390-412 us -> 112 us, measured on host). Android does
      // NOT come through this path: it is switched on by the manifest
      // meta-data `com.tekartik.sqflite.wal_enabled`, which sqflite reads at
      // open() before onConfigure runs. Nothing in Dart can assert that half —
      // if this test is ever the only thing guarding WAL, Android has silently
      // reverted to the rollback journal.
      expect(await pragma('journal_mode'), 'wal');
    });

    test('synchronous stays FULL', () async {
      // The usual WAL recipe drops this to NORMAL, which is where "WAL loses
      // the last few transactions on power loss" comes from. The measured gain
      // did not need it, and this app records evidence a user cannot re-capture
      // on request. 2 == SQLITE_SYNC_FULL.
      expect(await pragma('synchronous'), '2');
    });
  });
}

/// Counts the queries [LogRepo] issues, so the rotation tests can assert cost.
///
/// Implements only the five [Database] members [LogRepo] uses; anything else
/// throws via [noSuchMethod], which is the desired outcome — a new query path
/// should fail loudly here rather than go uncounted.
class _CountingDb implements Database {
  _CountingDb(this._inner);

  final Database _inner;

  /// `SUM(LENGTH(...))` full-table scans — the cost this change is about.
  int sumScans = 0;

  /// `COUNT(*)` queries, issued by trimToBytes alongside each scan.
  int countQueries = 0;

  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      _inner.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) {
    if (sql.contains('SUM(LENGTH')) sumScans++;
    if (sql.contains('COUNT(*)')) countQueries++;
    return _inner.rawQuery(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) =>
      _inner.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _inner.delete(table, where: where, whereArgs: whereArgs);

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      _inner.rawDelete(sql, arguments);

  /// Everything else throws. Declared so the class satisfies [Database] without
  /// stubbing 16 unused members — and so an uncounted query path is a loud
  /// failure rather than a silent one.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
