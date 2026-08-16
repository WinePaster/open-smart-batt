// Schema v18 — `settings.app_mode`, the personal/advanced split (design 0063).
//
// WHY THIS FILE EXISTS. v18 adds one nullable TEXT column, which sounds like
// the least interesting migration this project has shipped. It is not, because
// of what the column DECIDES: `app_mode = 'advanced'` removes the home tab from
// the bottom bar and withdraws the speed card, the G meter and full-screen mode
// with it. Every other setting this schema carries changes a detail of a screen;
// this one changes which screens exist.
//
// 🔴 So the thing under test is not "the column arrived". It is that a phone
// which upgrades into v18 lands on PERSONAL — that is, on exactly the app it
// had yesterday. Get that wrong and the failure is not subtle and not
// recoverable by the user's own reasoning: they launch the new build and their
// main screen is gone, with nothing they did to explain it, and the setting
// that would put it back is on a tab they have no reason to open. There is no
// error message for "a tab you were used to is missing".
//
// The mechanism is the ABSENCE of a DEFAULT plus `AppSettings.fromMap`'s
// fallback, and the two have to be checked separately: a DEFAULT of 'personal'
// would make these tests pass while destroying the only evidence that
// distinguishes "never asked" from "asked and chose personal".
//
// Three shapes, the same three `schema_v17_test.dart` uses:
//   * the column exists after an upgrade;
//   * a row written BEFORE the upgrade reads back as personal;
//   * a fresh database and an upgraded one have the identical settings table —
//     `_createStatements` and `_onUpgrade` are two independent descriptions of
//     one schema and no compiler relates them.
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The v11 shape, written out BY HAND — same reasoning as `schema_v17_test`:
/// sharing `_createStatements` with the code under test would make this pass
/// whatever the migration did.
///
/// v11 rather than v17, and it costs nothing (the `if (from < N)` chain runs
/// the whole way up) while buying the stronger claim: not "a v17 phone keeps
/// its home tab" but "EVERY phone that has ever had this app keeps it",
/// including one that skipped seven versions between two launches.
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

/// 🔴 `lang` and `auto_log` are here and are NOT optional detail. Both have
/// shipped in `_createStatements` since the first commit and neither has ever
/// had a migration branch, so a REAL v11 file carries them — and this is the
/// first test to compare the `settings` table across the two paths, so it is
/// the first one that would have failed on their absence. `schema_v17_test`'s
/// copy of this fixture omits them and never noticed, because it only compares
/// `history`. Left as a note rather than fixed over there: a fixture is only
/// wrong where something reads it.
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

  /// Build a real v11 file on disk (an in-memory database is discarded on
  /// close, so the upgrade path would never see the old row), seed the settings
  /// row a used phone would have, then open it with the current app.
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
          // The two indexes a REAL v11 file already carries — see the same
          // fixture in `schema_v17_test.dart` for why leaving them out produces
          // a parity failure that reads exactly like a real one.
          await db.execute('CREATE INDEX idx_history_ts ON history (timestamp)');
          await db
              .execute('CREATE INDEX idx_history_device ON history (device_id)');
          await db.execute(
              'CREATE INDEX idx_diag_log_device ON diag_log (device_id)');
        },
      ),
    );
    // A settings row belonging to somebody who has been using this app: they
    // picked a theme, so this is not the "no row at all" case that would fall
    // through to `AppSettings.defaults` and prove nothing about the migration.
    await legacy.insert('settings', {
      'id': 1,
      'theme_mode': 'dark',
      'poll_interval_ms': 500,
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

  group('v18: settings learns which shape of the app the user wants', () {
    test('the column exists after an upgrade', () async {
      final db = await upgradeFromV11('v18_col');
      expect(await _columnsOf(db.db, 'settings'), contains('app_mode'));
    });

    test('🔑 a row written before the upgrade reads back as PERSONAL',
        () async {
      // The whole feature in one assertion. If this ever goes red, every
      // existing user loses their home tab on the next launch — see the file
      // header for why that is not a cosmetic regression.
      final db = await upgradeFromV11('v18_upgrade_personal');
      final settings = await SettingsRepo(db.db).loadSettings();
      expect(settings.mode, AppMode.personal);
      // …and the rest of their row survived, so this is a real settings row and
      // not a silent fall-through to `AppSettings.defaults` (which would report
      // personal for the wrong reason and hide a broken migration).
      expect(settings.themeMode, AppThemeMode.dark);
      expect(settings.pollIntervalMs, 500);
    });

    test('🔴 the stored value is NULL, not a default', () async {
      // The distinction the migration deliberately preserves. A
      // `DEFAULT 'personal'` would make the test above pass while asserting
      // something false about every upgraded phone — that its owner chose
      // personal mode — and would destroy the only evidence separating "never
      // asked" from "asked and answered". `dflt_value` is checked as well as
      // the row, because a default added later would not show up in the row of
      // a database that had already been upgraded.
      final db = await upgradeFromV11('v18_null');
      final row = (await db.db.query('settings', limit: 1)).single;
      expect(row['app_mode'], isNull);
      expect(await _columnInfo(db.db, 'settings', 'app_mode'),
          containsPair('dflt_value', isNull));
    });

    test('an unreadable value also reads back as personal, without throwing',
        () async {
      // A downgrade after some future release adds a third mode, or a corrupted
      // row. Decoders in this file never throw (`_themeModeFromMap`'s standing
      // rule): one unreadable cosmetic field must not be able to stop the app
      // from starting, and the safe answer is always "the app they already had".
      final db = await upgradeFromV11('v18_garbage');
      await db.db.update('settings', {'app_mode': 'expert'},
          where: 'id = ?', whereArgs: [1]);
      expect((await SettingsRepo(db.db).loadSettings()).mode, AppMode.personal);
    });

    test('advanced survives a save/load round trip', () async {
      // `toMap` is an INSERT OR REPLACE of the whole row, so a column missing
      // from it does not merely fail to save — it erases itself later, the next
      // time any OTHER setting changes. That delay is what makes the defect
      // hard to attribute, so the round trip is done through a second write.
      final db = await freshDatabase('v18_roundtrip');
      final repo = SettingsRepo(db.db);
      await repo.saveSettings(
          AppSettings.defaults.copyWith(mode: AppMode.advanced));
      expect((await repo.loadSettings()).mode, AppMode.advanced);
      // The second write is the real test: change something unrelated and see
      // whether `app_mode` is still there afterwards.
      await repo.saveSettings(
          (await repo.loadSettings()).copyWith(pollIntervalMs: 2000));
      final after = await repo.loadSettings();
      expect(after.mode, AppMode.advanced,
          reason: 'a column absent from toMap() is wiped by the NEXT unrelated '
              'settings change, not by its own');
      expect(after.pollIntervalMs, 2000);
    });
  });

  group('a fresh database and an upgraded one are the same schema', () {
    test('settings: identical columns', () async {
      // The pivotal test, for the reason `schema_v17_test` states: the CREATE
      // list and the migration chain are two independent descriptions of one
      // schema, and every migration this project has shipped had to touch both.
      final upgraded = await upgradeFromV11('v18_parity');
      final fresh = await freshDatabase('v18_parity_new');
      expect(
        await _columnsOf(upgraded.db, 'settings'),
        await _columnsOf(fresh.db, 'settings'),
      );
    });

    test('both report schema version 18', () async {
      final upgraded = await upgradeFromV11('v18_ver');
      final fresh = await freshDatabase('v18_ver_new');
      for (final db in <AppDatabase>[upgraded, fresh]) {
        final v = (await db.db.rawQuery('PRAGMA user_version')).single;
        expect(v['user_version'], Db.schemaVersion);
        // A FLOOR, not a pin: v19 landed and took the exact pin with it, as
        // the note here said it should. A per-version file that pins the HEAD
        // has to be edited by every later migration, which turns it into noise
        // in exactly the diffs that need reading closely.
        expect(Db.schemaVersion, greaterThanOrEqualTo(18));
      }
    });
  });
}
