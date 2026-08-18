// Schema v21 — `saved_devices.declared_retrofit` (design 0069), and the one
// migration in this project that REWRITES existing rows.
//
// WHY THIS FILE EXISTS, and it is a third reason again. `schema_v18/19_test`
// guard a SETTING: get it wrong and a user sees a screen they did not choose —
// visible, reversible. `schema_v20_test` guards columns nothing displays, so a
// defect is invisible on the phone and only surfaces months later in the corpus.
// This one guards a **data rewrite**, which is both: invisible AND unrepeatable.
// The `UPDATE` runs exactly once per phone, when it crosses 20 → 21. If it is
// wrong, or if it runs when it should not, there is no second pass — the row it
// mangled is a real owner's answer and the original spelling is gone.
//
// Three things are asserted, and each of them is a way the rewrite goes wrong:
//
//   * 🔴 **The move is complete.** `declared_model = 'retrofit-lid'` must come
//     out as `declared_retrofit = 1` AND `declared_model = NULL`. Half-done
//     leaves one fact recorded twice, in two columns that will disagree the
//     first time somebody edits one of them — FB-23 / FB-33 / FB-32 are three
//     incidents of exactly that and are why `declared_*` exists at all.
//   * 🔴 **It touches nothing else.** A row that declared `7.5Ah-A` says nothing
//     about a lid. A `WHERE` that widened — to `LIKE`, to `IS NOT NULL` — would
//     silently relabel every declared unit on every phone in the field.
//   * 🔴 **The absent value is NULL, not 0.** `0` is a positive statement ("the
//     owner told us there is no lid") that no one made. Write it across the
//     table and `WHERE declared_retrofit IS NULL` counts nobody.
//
// The v20 schema below is written out BY HAND, same discipline as
// `schema_v11/v17/v20`: a fixture that borrows `_createStatements` from the code
// under test passes whatever that code does, including the bug.
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The v20 shape — what a phone running v0.7.22 … v0.7.24 has on disk.
///
/// Identical to today's DDL except for the one column v21 adds, which is the
/// point: anything else that drifts between this and `_createStatements` shows
/// up as a parity failure at the bottom of this file.
const List<String> _v20Schema = <String>[
  '''
  CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    pvlt REAL, svlt REAL, ampere REAL, temperature INTEGER,
    dvol1 REAL, dvol2 REAL, dvol3 REAL, dvol4 REAL,
    soh INTEGER, mode INTEGER, twf INTEGER, serial TEXT, soc INTEGER,
    device_id TEXT, samples INTEGER, app_build TEXT,
    speed REAL, accel REAL, g_long REAL, g_lat REAL,
    bucket_s INTEGER NOT NULL DEFAULT 60
  )''',
  'CREATE INDEX idx_history_ts ON history (timestamp)',
  'CREATE INDEX idx_history_device ON history (device_id)',
  'CREATE INDEX idx_history_device_ts ON history (device_id, timestamp)',
  '''
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
    serial TEXT,
    declared_category TEXT,
    declared_model TEXT,
    declared_region TEXT,
    declared_label TEXT,
    declared_capacity TEXT,
    declared_note TEXT,
    declared_at INTEGER
  )''',
  '''
  CREATE TABLE settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    auto_reconnect INTEGER NOT NULL DEFAULT 1,
    poll_interval_ms INTEGER NOT NULL DEFAULT 1000,
    background_keep_alive INTEGER NOT NULL DEFAULT 0,
    background_monitoring INTEGER NOT NULL DEFAULT 1,
    background_monitoring_ios INTEGER NOT NULL DEFAULT 0,
    dark_theme INTEGER NOT NULL DEFAULT 1,
    theme_mode TEXT,
    lang TEXT NOT NULL DEFAULT 'zhHant',
    temp_unit TEXT NOT NULL DEFAULT 'celsius',
    auto_log INTEGER NOT NULL DEFAULT 1,
    raw_packet_log INTEGER NOT NULL DEFAULT 0,
    retention TEXT NOT NULL DEFAULT 'forever',
    log_max_bytes INTEGER NOT NULL DEFAULT ${20 * 1024 * 1024},
    speed_detection INTEGER NOT NULL DEFAULT 0,
    speed_unit TEXT NOT NULL DEFAULT 'kmh',
    home_layout TEXT,
    g_meter_enabled INTEGER NOT NULL DEFAULT 0,
    g_calibration TEXT,
    app_mode TEXT,
    accent_theme TEXT
  )''',
  '''
  CREATE TABLE diag_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    direction TEXT NOT NULL,
    hex TEXT NOT NULL,
    note TEXT,
    device_id TEXT,
    session_id INTEGER,
    app_build TEXT
  )''',
  'CREATE INDEX idx_diag_log_ts ON diag_log (timestamp)',
  'CREATE INDEX idx_diag_log_device ON diag_log (device_id)',
  '''
  CREATE TABLE device_facts (
    id TEXT PRIMARY KEY,
    name TEXT,
    product_class TEXT,
    mac TEXT,
    serial TEXT,
    first_seen INTEGER NOT NULL,
    last_seen INTEGER NOT NULL
  )''',
  'CREATE INDEX idx_device_facts_mac ON device_facts (mac)',
  '''
  CREATE TABLE autoconnect_arm (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    device_id TEXT NOT NULL,
    armed_at INTEGER NOT NULL,
    app_build TEXT,
    session_id INTEGER
  )''',
];

/// The three units seeded into every fixture below.
///
/// One of each kind the `WHERE` has to tell apart: the answer that must MOVE,
/// the answer that must be LEFT ALONE, and the row that never answered.
const String _lidId = 'AA:BB:CC:DD:EE:01';
const String _modelId = 'AA:BB:CC:DD:EE:02';
const String _silentId = 'AA:BB:CC:DD:EE:03';

Future<Set<String>> _columnsOf(dynamic db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return {for (final row in info) row['name'] as String};
}

Future<Map<String, Object?>> _rowOf(dynamic db, String id) async =>
    (await db.query('saved_devices', where: 'id = ?', whereArgs: [id])).single;

void main() {
  setUpAll(sqfliteFfiInit);

  /// Build a real v20 file on disk, seed the three units, then open it with the
  /// current app so the 20 → 21 branch actually runs.
  ///
  /// A real file rather than an in-memory database: an in-memory one is
  /// discarded on close, so the upgrade path would never see the v20 rows.
  Future<AppDatabase> upgradeFromV20(String tag) async {
    final dir = await Directory.systemTemp.createTemp('osb_$tag');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'v20.db');
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 20,
        onCreate: (db, _) async {
          for (final stmt in _v20Schema) {
            await db.execute(stmt);
          }
        },
      ),
    );
    await legacy.insert('saved_devices', {
      'id': _lidId,
      'alias': '小綿羊',
      'name': 'RCE-BikeBatt',
      'last_seen': 1755300000000,
      'last_value': 12.9,
      'stale': 0,
      'product_class': 'smart_battery',
      'mac': _lidId,
      'serial': '145012340000051',
      'declared_category': 'motorcycle-battery',
      'declared_model': 'retrofit-lid',
      'declared_note': '底下是原廠 7Ah',
      'declared_at': 1755300000000,
    });
    await legacy.insert('saved_devices', {
      'id': _modelId,
      'alias': '通勤車',
      'name': 'RCE-BikeBatt',
      'stale': 0,
      'product_class': 'smart_battery',
      'declared_category': 'motorcycle-battery',
      'declared_model': '7.5Ah-A',
      'declared_at': 1755300000001,
    });
    await legacy.insert('saved_devices', {
      'id': _silentId,
      'alias': '電容 #1（前車）',
      'name': 'RCE-SCAP_II',
      'stale': 0,
      'product_class': 'supercapacitor',
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

  group('v20 → v21: the column', () {
    test('declared_retrofit exists and has no DEFAULT', () async {
      final db = await upgradeFromV20('v21_col');
      expect(await _columnsOf(db.db, 'saved_devices'),
          contains('declared_retrofit'));
      final info = (await db.db.rawQuery('PRAGMA table_info(saved_devices)'))
          .cast<Map<String, Object?>>()
          .firstWhere((r) => r['name'] == 'declared_retrofit');
      // A DEFAULT of 0 would be the fabricated answer this whole column is
      // careful not to make — see [Db.schemaVersion] v21.
      expect(info['dflt_value'], isNull);
      expect(info['notnull'], 0);
    });
  });

  group('v20 → v21: the rewrite', () {
    test('🔴 the retrofit answer MOVES — flag set and sentinel cleared',
        () async {
      final db = await upgradeFromV20('v21_move');
      final row = await _rowOf(db.db, _lidId);
      expect(row['declared_retrofit'], 1);
      expect(row['declared_model'], isNull,
          reason: 'left behind, the same fact lives in two columns and the '
              'first edit makes them disagree');
      // The rest of that owner's answer is untouched — the migration moves one
      // field, it does not rewrite the declaration.
      expect(row['declared_category'], 'motorcycle-battery');
      expect(row['declared_note'], '底下是原廠 7Ah');
      expect(row['declared_at'], 1755300000000);
      expect(row['alias'], '小綿羊');
      expect(row['serial'], '145012340000051');
    });

    test('🔴 it reads back as one declaration, not two', () async {
      final db = await upgradeFromV20('v21_read');
      final d = (await DeviceRepo(db.db).getDevice(_lidId))!;
      expect(d.declared.retrofitLid, isTrue);
      expect(d.declared.model, isNull);
      expect(d.declared.note, '底下是原廠 7Ah');
      // 🔑 The corpus-facing half: the export line must now say `retrofit=yes`
      // and must NOT say `model=retrofit-lid`, or the same fact is in the
      // published files under two spellings.
      expect(d.declared.exportValue, contains('retrofit=yes'));
      expect(d.declared.exportValue, isNot(contains('retrofit-lid')));
    });

    test('🔴 a declared MODEL is not touched', () async {
      // The `WHERE` is an equality on one sentinel. Widen it — `LIKE`, `IS NOT
      // NULL`, a category test — and every declared unit in the field is
      // relabelled a retrofit, once, irreversibly.
      final db = await upgradeFromV20('v21_untouched');
      final row = await _rowOf(db.db, _modelId);
      expect(row['declared_model'], '7.5Ah-A');
      expect(row['declared_retrofit'], isNull);
      expect(row['declared_category'], 'motorcycle-battery');
    });

    test('🔴 a row that never answered stays NULL, not 0', () async {
      final db = await upgradeFromV20('v21_null');
      final row = await _rowOf(db.db, _silentId);
      expect(row['declared_retrofit'], isNull);
      expect(row['declared_retrofit'], isNot(0),
          reason: '0 says "the owner told us there is no lid" — nobody did');
      expect((await DeviceRepo(db.db).getDevice(_silentId))!.declared,
          DeclaredModel.none);
    });

    test('🔴 nothing was seeded from product_class', () async {
      // v20's standing rule, restated because this is the first migration with
      // an UPDATE in it and that is exactly where the temptation lands.
      final db = await upgradeFromV20('v21_noseed');
      final row = await _rowOf(db.db, _silentId);
      expect(row['product_class'], 'supercapacitor');
      expect(row['declared_category'], isNull);
      expect(row['declared_retrofit'], isNull);
    });

    test('running the upgrade twice changes nothing', () async {
      // A migration is idempotent by being version-gated, not by luck; this
      // pins that reopening an already-migrated file leaves the rewritten row
      // alone (the `WHERE` no longer matches anything, which is the point).
      final db = await upgradeFromV20('v21_twice');
      final before = await _rowOf(db.db, _lidId);
      await db.close();
      final again = await AppDatabase.open(
          path: db.db.path, factory: databaseFactoryFfi);
      addTearDown(again.close);
      expect(await _rowOf(again.db, _lidId), before);
    });
  });

  group('the write path', () {
    test('🔴 false is stored as NULL, never 0', () async {
      // `DeclaredModel.toMap`'s half of the same rule. The migration can be
      // perfect and still be undone the first time a user opens the form on a
      // unit with no lid.
      final db = await upgradeFromV20('v21_write');
      final repo = DeviceRepo(db.db);
      await repo.setDeclaredModel(
        _modelId,
        const DeclaredModel(
          category: DeclaredCategory.motorcycleBattery,
          model: '7.5Ah-A',
        ),
      );
      expect((await _rowOf(db.db, _modelId))['declared_retrofit'], isNull);

      await repo.setDeclaredModel(
        _modelId,
        const DeclaredModel(
          category: DeclaredCategory.motorcycleBattery,
          model: '7.5Ah-A',
          retrofitLid: true,
        ),
      );
      final row = await _rowOf(db.db, _modelId);
      expect(row['declared_retrofit'], 1);
      expect(row['declared_model'], '7.5Ah-A',
          reason: 'design 0069: the lid and the model coexist by construction');
    });

    test('a stray 0 from anywhere reads as "no answer"', () async {
      // Belt and braces for a hand-edited row or a downgrade-then-upgrade: the
      // decoder must not treat 0 as true, and must not throw.
      final db = await upgradeFromV20('v21_zero');
      await db.db.update('saved_devices', {'declared_retrofit': 0},
          where: 'id = ?', whereArgs: [_silentId]);
      final d = (await DeviceRepo(db.db).getDevice(_silentId))!;
      expect(d.declared.retrofitLid, isFalse);
      expect(d.alias, '電容 #1（前車）');
    });
  });

  group('a fresh database and an upgraded one are the same schema', () {
    test('saved_devices: identical columns', () async {
      // `_createStatements` and the `_onUpgrade` chain are two independent
      // descriptions of one schema that no compiler relates to each other, and
      // every migration this project has shipped had to touch both.
      final upgraded = await upgradeFromV20('v21_parity');
      final fresh = await freshDatabase('v21_parity_new');
      expect(
        await _columnsOf(upgraded.db, 'saved_devices'),
        await _columnsOf(fresh.db, 'saved_devices'),
      );
    });

    test('both report schema version 21', () async {
      final upgraded = await upgradeFromV20('v21_ver');
      final fresh = await freshDatabase('v21_ver_new');
      for (final db in <AppDatabase>[upgraded, fresh]) {
        final v = (await db.db.rawQuery('PRAGMA user_version')).single;
        expect(v['user_version'], Db.schemaVersion);
        // The current EXACT pin — inherited from `schema_v20_test.dart`, which
        // now asserts a floor. Move it again when v22 lands; the registry in
        // `Db.schemaVersion`'s doc comment is the arbiter, and this line is what
        // makes two branches claiming one number collide here rather than on a
        // user's phone.
        expect(Db.schemaVersion, 21);
      }
    });
  });
}
