// Schema v20 — the seven `saved_devices.declared_*` columns (design 0066), and
// M7 of §5.
//
// WHY THIS FILE EXISTS, and it is a different reason from v18's and v19's. Those
// two guard a SETTING: get the migration wrong and an existing user sees a
// screen they did not choose, which is visible and reversible. These columns are
// not read by any screen at all — nothing routes on them, nothing is gated on
// them, nothing displays them (§3.5) — so a migration defect here is INVISIBLE
// on the phone and only surfaces months later, in the corpus, as data that
// cannot be interpreted.
//
// Two ways that happens, and both are asserted below:
//
//   * 🔴 **`''` instead of NULL.** Two spellings of "no answer" in one column.
//     The day somebody counts non-answers with `WHERE declared_capacity IS NULL`
//     half of them go missing, and the shortfall reads as a signal — people
//     answered! — when it is an artefact of the write path. This is a sharper
//     version of v18/v19's "do not invent a choice": here the invented value is
//     not even wrong-looking.
//   * 🔴 **Seeding from `product_class`.** One line, obviously helpful, and it
//     would state that every existing owner had CONFIRMED what the byte said
//     when none of them was ever asked. Same discipline as v15's deliberately
//     empty table: an upgrade may add capability, never evidence. It would also
//     destroy the only thing these columns are for — being able to tell a
//     measurement from an opinion.
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The v11 shape, written out BY HAND — same reasoning as `schema_v17_test` and
/// `schema_v19_test`: a test that shares `_createStatements` with the code it is
/// checking passes whatever the migration did.
///
/// v11 rather than v19, and it costs nothing (the `if (from < N)` chain runs the
/// whole way up) while buying the stronger claim: not "a v19 phone keeps its
/// aliases" but "every phone that has ever had this app does", including one
/// that skipped nine versions between two launches.
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

const String _v11History = '''
  CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL, pvlt REAL, svlt REAL, ampere REAL,
    temperature INTEGER, dvol1 REAL, dvol2 REAL, dvol3 REAL, dvol4 REAL,
    soh INTEGER, mode INTEGER, twf INTEGER, serial TEXT, soc INTEGER,
    device_id TEXT, samples INTEGER, app_build TEXT
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
    lang TEXT NOT NULL DEFAULT 'zhHant',
    retention TEXT NOT NULL DEFAULT 'forever',
    temp_unit TEXT NOT NULL DEFAULT 'celsius',
    auto_log INTEGER NOT NULL DEFAULT 1,
    raw_packet_log INTEGER NOT NULL DEFAULT 0,
    log_max_bytes INTEGER
  )''';

const String _v11DiagLog = '''
  CREATE TABLE diag_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL, direction TEXT NOT NULL, hex TEXT NOT NULL,
    note TEXT, device_id TEXT, session_id INTEGER, app_build TEXT
  )''';

/// The seven columns v20 adds, in the order the migration adds them.
const List<String> _declaredColumns = <String>[
  'declared_category',
  'declared_model',
  'declared_region',
  'declared_label',
  'declared_capacity',
  'declared_note',
  'declared_at',
];

Future<Set<String>> _columnsOf(dynamic db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return {for (final row in info) row['name'] as String};
}

Future<Map<String, Object?>> _columnInfo(
    dynamic db, String table, String column) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return (info as List).cast<Map<String, Object?>>().firstWhere(
        (r) => r['name'] == column,
        orElse: () => throw StateError('$table has no column $column'),
      );
}

void main() {
  setUpAll(sqfliteFfiInit);

  /// Build a real v11 file on disk, seed one used phone's saved device, then
  /// open it with the current app.
  ///
  /// A real file rather than an in-memory database: an in-memory one is
  /// discarded on close, so the upgrade path would never see the v11 rows.
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
          await db.execute('CREATE INDEX idx_history_ts ON history (timestamp)');
          await db
              .execute('CREATE INDEX idx_history_device ON history (device_id)');
          await db.execute(
              'CREATE INDEX idx_diag_log_device ON diag_log (device_id)');
        },
      ),
    );
    // A real user's row, with a class the wire had already resolved — which is
    // what makes the "was it seeded from product_class?" assertion meaningful.
    await legacy.insert('saved_devices', {
      'id': 'AA:BB:CC:DD:EE:FF',
      'alias': '電容 #1（前車）',
      'name': 'RCE-SCAP_II',
      'last_seen': 1754200000000,
      'last_value': 13.4,
      'stale': 0,
      'product_class': 'supercapacitor',
      'mac': 'AA:BB:CC:DD:EE:FF',
      'serial': '145012340000001',
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

  group('M7: v19 → v20 leaves every old row saying nothing', () {
    test('all seven columns exist after an upgrade', () async {
      final db = await upgradeFromV11('v20_cols');
      final cols = await _columnsOf(db.db, 'saved_devices');
      for (final c in _declaredColumns) {
        expect(cols, contains(c), reason: c);
      }
    });

    test('🔴 M7 — every one of them is NULL, not the empty string', () async {
      // THE test of this file. `''` and NULL would be two spellings of "no
      // answer" in one column, and the count that goes wrong afterwards is the
      // exact count this feature exists to produce.
      final db = await upgradeFromV11('v20_null');
      final row = (await db.db.query('saved_devices')).single;
      for (final c in _declaredColumns) {
        expect(row[c], isNull, reason: '$c must be NULL');
        expect(row[c], isNot(''), reason: '$c must not be the empty string');
      }
      // And the model agrees end to end, so a decoder that manufactured a blank
      // could not hide behind a correct-looking row.
      final device = SavedDevice.fromMap(row);
      expect(device.declared, DeclaredModel.none);
      expect(device.declared.isEmpty, isTrue);
      expect(device.declared.category, isNull);
      expect(device.declared.declaredAt, isNull);
    });

    test('🔴 no DEFAULT on any of them', () async {
      // A DEFAULT added later would not show up in the row of a database that
      // had already been upgraded, so the row check above is not sufficient on
      // its own — the column definition has to be checked too.
      final db = await upgradeFromV11('v20_default');
      for (final c in _declaredColumns) {
        expect(await _columnInfo(db.db, 'saved_devices', c),
            containsPair('dflt_value', isNull),
            reason: '$c: a default would state that every pre-v20 owner '
                'answered a form they were never shown');
      }
    });

    test('🔴 nothing was seeded from product_class', () async {
      // The one-line "improvement" this test exists to stop. The seeded value
      // would even be RIGHT for this row — the unit really is a capacitor — and
      // that is what makes it dangerous: it would be indistinguishable from an
      // owner who looked at their unit and said so, which is the single
      // distinction the whole feature is built to preserve.
      final db = await upgradeFromV11('v20_seed');
      final row = (await db.db.query('saved_devices')).single;
      expect(row['product_class'], 'supercapacitor');
      expect(row['declared_category'], isNull);
    });

    test('every pre-existing column survives, value for value', () async {
      // A migration that rebuilt the table instead of ALTERing it would pass a
      // "column exists" check and quietly lose the alias — and an alias is the
      // one thing in this table the user typed by hand.
      final db = await upgradeFromV11('v20_survives');
      final d = SavedDevice.fromMap((await db.db.query('saved_devices')).single);
      expect(d.id, 'AA:BB:CC:DD:EE:FF');
      expect(d.alias, '電容 #1（前車）');
      expect(d.name, 'RCE-SCAP_II');
      expect(d.lastValue, 13.4);
      expect(d.productClass, ProductClass.supercapacitor);
      expect(d.mac, 'AA:BB:CC:DD:EE:FF');
      expect(d.serial, '145012340000001');
      expect(d.displayLayout, DisplayLayout.defaults);
    });

    test('the upgraded columns are writable, and blanks land as NULL', () async {
      // An ALTER that landed with the wrong type would only show up here. The
      // second half is `DeclaredModel.toMap`'s normalisation, checked against a
      // real column rather than in the abstract: the write path must not be able
      // to reintroduce the `''` the migration was careful to avoid.
      final db = await upgradeFromV11('v20_write');
      final repo = DeviceRepo(db.db);
      await repo.setDeclaredModel(
        'AA:BB:CC:DD:EE:FF',
        DeclaredModel(
          category: DeclaredCategory.motorcycleBattery,
          // 🔵 Was `kRetrofitLidModel` until design 0069 took the lid out of the
          // model list. A catalogue slug is what this column carries now, and
          // writing the retired sentinel here would assert the opposite.
          model: '7.5Ah-A',
          capacity: '', // a focused-but-untouched field
          note: '   ', // …and one holding only whitespace the UI trimmed away
          declaredAt: DateTime.fromMillisecondsSinceEpoch(1755300000000),
        ),
      );
      final row = (await db.db.query('saved_devices')).single;
      expect(row['declared_category'], 'motorcycle-battery');
      expect(row['declared_model'], '7.5Ah-A');
      expect(row['declared_capacity'], isNull);
      expect(row['declared_at'], 1755300000000);

      final back = (await repo.getDevice('AA:BB:CC:DD:EE:FF'))!.declared;
      expect(back.category, DeclaredCategory.motorcycleBattery);
      expect(back.model, '7.5Ah-A');
      expect(back.capacity, isNull);
      expect(back.declaredAt,
          DateTime.fromMillisecondsSinceEpoch(1755300000000));
    });

    test('a row this build cannot interpret does not take the list down',
        () async {
      // A downgrade, or a category withdrawn later. The decoder must answer
      // "not declared" without throwing: a saved-device list that cannot be read
      // is an app that will not start, and this column is cosmetic-grade data.
      final db = await upgradeFromV11('v20_unknown');
      await db.db.update(
          'saved_devices', {'declared_category': 'hovercraft', 'declared_model': 'x'},
          where: 'id = ?', whereArgs: ['AA:BB:CC:DD:EE:FF']);
      final d = (await DeviceRepo(db.db).getDevice('AA:BB:CC:DD:EE:FF'))!;
      expect(d.declared.category, isNull);
      // 🔑 The MODEL is kept even though the category could not be read. The
      // slug is free-form by construction (R1 accepts that the list goes stale),
      // so discarding it would spend a user's answer on its way past — the same
      // argument `schema_v19_test` makes for an unrecognised accent id.
      expect(d.declared.model, 'x');
      expect(d.alias, '電容 #1（前車）', reason: 'and the rest of the row is intact');
    });
  });

  group('a fresh database and an upgraded one are the same schema', () {
    test('saved_devices: identical columns', () async {
      // `_createStatements` and the `_onUpgrade` chain are two independent
      // descriptions of one schema that no compiler relates to each other, and
      // every migration this project has shipped had to touch both.
      final upgraded = await upgradeFromV11('v20_parity');
      final fresh = await freshDatabase('v20_parity_new');
      expect(
        await _columnsOf(upgraded.db, 'saved_devices'),
        await _columnsOf(fresh.db, 'saved_devices'),
      );
    });

    test('both report the current schema version', () async {
      final upgraded = await upgradeFromV11('v20_ver');
      final fresh = await freshDatabase('v20_ver_new');
      for (final db in <AppDatabase>[upgraded, fresh]) {
        final v = (await db.db.rawQuery('PRAGMA user_version')).single;
        expect(v['user_version'], Db.schemaVersion);
        // 🔴 A FLOOR, not a pin — the exact pin moved on to `schema_v21_test`
        // when design 0069 landed, exactly as the note here instructed. What
        // this file still has to prove is that a v11 phone reaching v20's seven
        // columns does not stop reaching them once later versions are appended.
        expect(Db.schemaVersion, greaterThanOrEqualTo(20));
      }
    });
  });
}
