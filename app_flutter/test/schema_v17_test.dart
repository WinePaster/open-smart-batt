// Schema v17 — `history.bucket_s`, and the index the aggregating reads need.
//
// WHY THIS FILE EXISTS. design 0061 (FB-71) changes what a `history` row IS:
// today every row is a per-minute average, after Phase 4 new rows will be
// per-second ones, and BOTH will sit in the same table forever — v16 rows are
// not migrated (there is nothing to migrate them from). Everything downstream
// — the list, the chart, the CSV `resolution:` header, the export granularity
// picker — has to be able to ask a row which of the two it is.
//
// 🔴 That question has exactly one honest answer, and it is a stored column.
// design 0061 §3.2 rules out all three cheaper ways, and each is wrong in a way
// that would ship silently:
//
//   * `samples`: a minute cut into segments by a disconnect reaches down to 3
//     (`conventions.md` records 405/69/3/56 for the 19:26 minute) while a
//     second row sits near 5. The distributions OVERLAP — no threshold exists.
//   * a date cut-off: `timestamp` is the instant the row DESCRIBES, not when it
//     was written, and design 0047 back-fills old instants from new builds.
//   * "does it land on a whole minute": second-resolution rows land on `:00`
//     once every 60 rows. The most tempting one and the worst.
//
// So what this file pins is not "the column exists". It is that a row written
// BEFORE the upgrade answers 60 afterwards — the backfill — and that the two
// independent descriptions of the schema (`_createStatements` and `_onUpgrade`,
// which no compiler relates to each other) still agree. Every migration this
// project has shipped had to touch both.
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:open_smart_batt/data/data.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The v11 shape, written out BY HAND — same reasoning as `schema_v12_test`:
/// sharing `_createStatements` with the code under test would make this pass no
/// matter what the migration did.
///
/// v11 rather than v16 on purpose. It costs nothing (the `if (from < N)` chain
/// runs the whole way up) and it buys the stronger claim: not "a v16 user gets
/// `bucket_s`" but "EVERY user who has ever had this app gets it", including
/// the ones who skipped five versions between two launches.
const String _v11History = '''
  CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL, pvlt REAL, svlt REAL, ampere REAL,
    temperature INTEGER, dvol1 REAL, dvol2 REAL, dvol3 REAL, dvol4 REAL,
    soh INTEGER, mode INTEGER, twf INTEGER, serial TEXT, soc INTEGER,
    device_id TEXT, samples INTEGER, app_build TEXT
  )''';

const String _v11SavedDevices = '''
  CREATE TABLE saved_devices (
    id TEXT PRIMARY KEY,
    alias TEXT NOT NULL DEFAULT '',
    name TEXT NOT NULL DEFAULT '',
    last_seen INTEGER,
    last_value REAL,
    stale INTEGER NOT NULL DEFAULT 0,
    product_class TEXT NOT NULL DEFAULT 'unknown',
    display_layout TEXT,
    mac TEXT,
    serial TEXT
  )''';

const String _v11Settings = '''
  CREATE TABLE settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    auto_reconnect INTEGER NOT NULL DEFAULT 1,
    poll_interval_ms INTEGER NOT NULL DEFAULT 1000,
    background_keep_alive INTEGER NOT NULL DEFAULT 0,
    background_monitoring INTEGER NOT NULL DEFAULT 1,
    dark_theme INTEGER NOT NULL DEFAULT 1,
    theme_mode TEXT,
    retention TEXT NOT NULL DEFAULT 'forever',
    temp_unit TEXT NOT NULL DEFAULT 'celsius',
    raw_packet_log INTEGER NOT NULL DEFAULT 0,
    log_max_bytes INTEGER
  )''';

const String _v11DiagLog = '''
  CREATE TABLE diag_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL, direction TEXT NOT NULL, hex TEXT NOT NULL,
    note TEXT, device_id TEXT, session_id INTEGER, app_build TEXT
  )''';

Future<Set<String>> _columnsOf(dynamic db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return {for (final row in info) row['name'] as String};
}

Future<Set<String>> _indexesOf(dynamic db, String table) async {
  final info = await db.rawQuery('PRAGMA index_list($table)');
  return {for (final row in info) row['name'] as String};
}

void main() {
  setUpAll(sqfliteFfiInit);

  /// Build a real v11 file on disk (an in-memory DB is discarded on close, so
  /// the upgrade path would never see the old rows), seed history, then open it
  /// with the current app and hand back the upgraded handle.
  Future<AppDatabase> upgradeFromV11(String tag) async {
    final dir = await Directory.systemTemp.createTemp('osb_$tag');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'v11.db');
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 11,
        onCreate: (db, _) async {
          await db.execute(_v11History);
          await db.execute(_v11SavedDevices);
          await db.execute(_v11Settings);
          await db.execute(_v11DiagLog);
          // 🔴 The two indexes a REAL v11 file already carries. `idx_history_ts`
          // ships with the create; `idx_history_device` lands in the `from < 9`
          // branch — which, for a database opened at 11, never runs again.
          // Leaving them out of the fixture made the index-parity test below
          // fail on the FIXTURE's omission rather than on any drift in the
          // migration, i.e. a false alarm that reads exactly like a real one.
          // (`schema_v12_test`'s fixture omits them too; it only compares
          // columns, so it never noticed.)
          await db.execute('CREATE INDEX idx_history_ts ON history (timestamp)');
          await db
              .execute('CREATE INDEX idx_history_device ON history (device_id)');
          await db.execute(
              'CREATE INDEX idx_diag_log_device ON diag_log (device_id)');
        },
      ),
    );
    // Two rows a real install would have: one plain minute, and one that was
    // cut into segments so its `samples` is implausibly low. The second is the
    // whole point — it is the row an inference from `samples` would misread as
    // second-resolution data.
    await legacy.insert('history', {
      'timestamp': 1754000000000,
      'pvlt': 12.5,
      'device_id': 'DEV-A',
      'samples': 521,
    });
    await legacy.insert('history', {
      'timestamp': 1754000060000,
      'pvlt': 12.4,
      'device_id': 'DEV-A',
      'samples': 3,
    });
    await legacy.close();
    final upgraded =
        await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    addTearDown(upgraded.close);
    return upgraded;
  }

  Future<AppDatabase> freshDatabase(String tag) async {
    final dir = await Directory.systemTemp.createTemp('osb_$tag');
    addTearDown(() => dir.delete(recursive: true));
    final db = await AppDatabase.open(
      path: p.join(dir.path, 'fresh.db'),
      factory: databaseFactoryFfi,
    );
    addTearDown(db.close);
    return db;
  }

  group('v17: history learns to say what it summarises', () {
    test('the column exists after an upgrade', () async {
      final db = await upgradeFromV11('v17_col');
      expect(await _columnsOf(db.db, 'history'), contains('bucket_s'));
    });

    test('🔑 rows written before the upgrade answer 60, including the '
        'segmented one', () async {
      final db = await upgradeFromV11('v17_backfill');
      final rows = await db.db.query('history', orderBy: 'timestamp ASC');
      expect(rows, hasLength(2));
      // The backfill is the DEFAULT, applied by SQLite during ADD COLUMN. If
      // this ever reads null, the column has been made nullable and every
      // downstream reader has to start guessing again.
      expect(rows.map((r) => r['bucket_s']), everyElement(60));
      // Stated explicitly because it is the trap: this row folded THREE
      // samples, the same order of magnitude a per-second row will, and it is
      // still a minute. No `samples` threshold could have told them apart.
      expect(rows.last['samples'], 3);
      expect(rows.last['bucket_s'], 60);
    });

    test('a new row gets 60 without anyone passing it', () async {
      // Phase 1 changes no writer: the app still produces per-minute averages,
      // so the default has to be the correct answer for them too. When Phase 4
      // switches the writer to seconds it will pass 1 explicitly, and this test
      // is what says the default was never load-bearing for that path.
      final db = await freshDatabase('v17_default');
      await db.db.insert('history', {
        'timestamp': 1754000120000,
        'device_id': 'DEV-B',
        'samples': 288,
      });
      final row = (await db.db.query('history')).single;
      expect(row['bucket_s'], 60);
    });

    test('the composite index exists on both paths', () async {
      // design 0061 T5. Not a performance assertion — it is here because the
      // index is created in two places (`_createStatements` and `_onUpgrade`)
      // and nothing in the compiler relates them.
      final upgraded = await upgradeFromV11('v17_idx_up');
      final fresh = await freshDatabase('v17_idx_new');
      for (final db in <AppDatabase>[upgraded, fresh]) {
        expect(await _indexesOf(db.db, 'history'),
            contains('idx_history_device_ts'));
      }
    });
  });

  group('a fresh database and an upgraded one are the same schema', () {
    // The pivotal test. `_createStatements` and `_onUpgrade` are two
    // independent descriptions of the same schema, and every migration this
    // project has shipped had to touch both — this comparison is the only thing
    // standing between "we added the column" and "we added it for new installs
    // only".
    test('history: identical columns', () async {
      final upgraded = await upgradeFromV11('v17_parity_col');
      final fresh = await freshDatabase('v17_parity_col_new');
      expect(
        await _columnsOf(upgraded.db, 'history'),
        await _columnsOf(fresh.db, 'history'),
      );
    });

    test('history: identical indexes', () async {
      final upgraded = await upgradeFromV11('v17_parity_idx');
      final fresh = await freshDatabase('v17_parity_idx_new');
      expect(
        await _indexesOf(upgraded.db, 'history'),
        await _indexesOf(fresh.db, 'history'),
      );
    });

    test('both report the same schema version, and it is at least 17',
        () async {
      final upgraded = await upgradeFromV11('v17_ver');
      final fresh = await freshDatabase('v17_ver_new');
      for (final db in <AppDatabase>[upgraded, fresh]) {
        final v = (await db.db.rawQuery('PRAGMA user_version')).single;
        // The load-bearing half: an upgraded file and a fresh one must stamp
        // the SAME number, whatever the head happens to be.
        expect(v['user_version'], Db.schemaVersion);
        // 🔴 Was `expect(Db.schemaVersion, 17)` — an exact pin, changed when
        // design 0063 took v18 on 2026-08-15. A per-version file cannot pin the
        // HEAD without having to be edited by every later migration, which
        // makes it noise in exactly the diffs that need reading carefully. What
        // this file is about is that v17's column survives to the head, so the
        // floor is the honest assertion; `schema_v18_test.dart` holds the
        // current exact pin, as each new one will.
        expect(Db.schemaVersion, greaterThanOrEqualTo(17));
      }
    });
  });
}
