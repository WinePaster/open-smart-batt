// Schema v12 — nine columns, four of which nothing writes yet.
//
// WHY THIS FILE EXISTS AT ALL. `AppDatabase._onUpgrade` is a cumulative
// `if (from < N)` chain, so the set of columns v12 adds is decided ONCE and is
// then unreachable: a user who has upgraded never runs a rewritten v12 again.
// Design 0044 Q2 additionally ruled there will be no v13 for this family of
// columns. Between them, a column forgotten here does not cost a follow-up
// migration — it overturns a ruling that has already been made, in a way that
// only shows up months later on somebody else's phone.
//
// So the pivotal test in this file is not "does `speed` exist". It is
// `PRAGMA table_info` of a FRESHLY CREATED database compared against an
// UPGRADED one, column set for column set, on both tables. Those two schemas
// come from two different pieces of code — `_createStatements` and
// `_onUpgrade` — that no compiler relates to each other, and every migration
// this project has shipped had to touch both. That comparison is the only
// thing standing between "we added the column" and "we added the column for
// new installs only".
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The v11 shape, written out BY HAND. Sharing `_createStatements` with the
/// code under test would make this pass no matter what the migration did.
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
    lang TEXT NOT NULL DEFAULT 'zhHant',
    temp_unit TEXT NOT NULL DEFAULT 'celsius',
    auto_log INTEGER NOT NULL DEFAULT 1,
    raw_packet_log INTEGER NOT NULL DEFAULT 0,
    retention TEXT NOT NULL DEFAULT 'forever',
    log_max_bytes INTEGER NOT NULL DEFAULT 20971520
  )''';

const String _v11DiagLog = '''
  CREATE TABLE diag_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL, direction TEXT NOT NULL, hex TEXT NOT NULL,
    note TEXT, device_id TEXT, session_id INTEGER, app_build TEXT
  )''';

/// Column NAMES only. Kept because several assertions read better as a set
/// difference; [_columnSpecsOf] is what actually guards the migration.
Future<Set<String>> _columnsOf(dynamic db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return {for (final row in info) row['name'] as String};
}

/// Column name **plus its full declaration** — type, NOT NULL and DEFAULT.
///
/// 🔴 Comparing names alone is not enough, and that gap was found by review
/// rather than by this file failing (2026-08-07). `ALTER TABLE ... ADD COLUMN
/// g_meter_enabled INTEGER` and `... INTEGER NOT NULL DEFAULT 0` produce the
/// same NAME, and a name-only comparison calls the two schemas equal. The
/// constraints on these nine columns were themselves a ruling — `g_meter_enabled`
/// NOT NULL DEFAULT 0 because a boolean has two meaningful states, `g_calibration`
/// nullable because "never calibrated" has no sensible default — and SQLite
/// cannot alter a column's constraints afterwards. So a constraint that lands
/// wrong in v12 lands wrong permanently, and only this comparison can say so
/// before it ships.
Future<Set<String>> _columnSpecsOf(dynamic db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return {
    for (final row in info)
      '${row['name']} ${row['type']} '
          'notnull=${row['notnull']} default=${row['dflt_value']} pk=${row['pk']}'
  };
}

void main() {
  setUpAll(sqfliteFfiInit);

  /// Build a real v11 file (an in-memory DB is discarded on close, so the
  /// upgrade path would never see the old data), seed one row per table, then
  /// open it with the current app and hand back the upgraded handle.
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
        },
      ),
    );
    await legacy.insert('history', {'timestamp': 60000, 'pvlt': 12.5});
    await legacy.insert('saved_devices', {'id': 'AA:BB', 'alias': '電池 #1'});
    await legacy.insert('settings', {'id': 1, 'poll_interval_ms': 2000});
    await legacy.close();
    final upgraded =
        await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    addTearDown(upgraded.close);
    return upgraded;
  }

  group('v11 → v12: the columns that had to land together', () {
    test('history gains speed, accel, g_long and g_lat', () async {
      final db = await upgradeFromV11('v12_hist');
      expect(
        await _columnsOf(db.db, 'history'),
        containsAll(<String>['speed', 'accel', 'g_long', 'g_lat']),
      );
    });

    test('settings gains all five, and the reserved three read back NULL',
        () async {
      final db = await upgradeFromV11('v12_set');
      expect(
        await _columnsOf(db.db, 'settings'),
        containsAll(<String>[
          'speed_detection',
          'speed_unit',
          'home_layout',
          'g_meter_enabled',
          'g_calibration',
        ]),
      );
      final row = (await db.db.query('settings')).single;
      // The two design 0042 owns get their ruled defaults. `speed_detection`
      // defaulting to 0 is the load-bearing one: an upgrade must not switch on
      // a feature whose consent dialog the user has never been shown.
      expect(row['speed_detection'], 0);
      expect(row['speed_unit'], 'kmh');
      expect(row['g_meter_enabled'], 0,
          reason: 'a boolean with a NOT NULL default, so there is no third '
              'state for design 0045 to have to interpret');
      // The two nullable ones. NULL is the whole point: it says "never chosen /
      // never calibrated", which a written-in placeholder would contradict by
      // claiming every existing user had made a choice (the v10
      // `display_layout` precedent).
      expect(row['home_layout'], isNull);
      expect(row['g_calibration'], isNull);
      // And the pre-existing value is not collateral damage.
      expect(row['poll_interval_ms'], 2000);
    });

    test('the reserved columns are writable, not just present', () async {
      // An ALTER that landed with the wrong affinity or a stray constraint
      // shows up here and nowhere else — the owning designs are months away,
      // and by then v12 cannot be changed.
      final db = await upgradeFromV11('v12_write');
      await db.db.update(
        'settings',
        {
          'home_layout': '{"tiles":[]}',
          'g_meter_enabled': 1,
          'g_calibration': '{"m":[1,0,0,0,1,0,0,0,1],"at":0}',
        },
        where: 'id = 1',
      );
      await db.db.insert('history', {
        'timestamp': 120000,
        'speed': 12.5,
        'accel': -0.25,
        'g_long': 0.1,
        'g_lat': -0.05,
      });
      final s = (await db.db.query('settings')).single;
      expect(s['home_layout'], '{"tiles":[]}');
      expect(s['g_meter_enabled'], 1);
      expect(s['g_calibration'], isNotNull);
      final h = (await db.db
              .query('history', where: 'timestamp = ?', whereArgs: [120000]))
          .single;
      expect(h['speed'], 12.5);
      expect(h['accel'], -0.25);
      expect(h['g_long'], 0.1);
      expect(h['g_lat'], -0.05);
    });

    test('existing rows survive, and their speed columns are NULL not 0',
        () async {
      final db = await upgradeFromV11('v12_keep');
      final rows = await db.db.query('history');
      expect(rows, hasLength(1), reason: 'the upgrade must not drop data');
      expect(rows.single['pvlt'], 12.5);
      // A backfilled 0.0 would claim the phone was measured standing still
      // during a minute that predates the feature — the same fabricated-fact
      // failure the v5/v6/v7 attribution rules exist to prevent.
      expect(rows.single['speed'], isNull);
      expect(rows.single['accel'], isNull);
      expect((await db.db.query('saved_devices')).single['alias'], '電池 #1');
    });
  });

  // =========================================================================
  // The one that actually guards the ratchet
  // =========================================================================
  group('a fresh database and an upgraded one are the same schema', () {
    /// `_createStatements` and `_onUpgrade` are two independent descriptions of
    /// the same schema, related by nothing the compiler can check. Every
    /// migration this project has shipped had to edit both, and the failure of
    /// editing only one is invisible: new installs and upgraded installs simply
    /// diverge, and the first symptom is a query that works for some users.
    Future<void> expectSameColumns(String table) async {
      final upgraded = await upgradeFromV11('v12_cmp_$table');
      final dir = await Directory.systemTemp.createTemp('osb_v12_fresh_$table');
      addTearDown(() => dir.delete(recursive: true));
      final fresh = await AppDatabase.open(
          path: p.join(dir.path, 'fresh.db'), factory: databaseFactoryFfi);
      addTearDown(fresh.close);
      // Names first, because a missing column reads far better as a set
      // difference than as a diff of declaration strings.
      expect(
        await _columnsOf(upgraded.db, table),
        await _columnsOf(fresh.db, table),
        reason: '$table differs between a new install and an upgraded one — '
            'one of _createStatements / _onUpgrade was edited without the '
            'other',
      );
      // Then the declarations. This is the half that catches
      // `ADD COLUMN x INTEGER` vs `x INTEGER NOT NULL DEFAULT 0` — same name,
      // different column, and SQLite cannot fix it after v12 ships.
      expect(
        await _columnSpecsOf(upgraded.db, table),
        await _columnSpecsOf(fresh.db, table),
        reason: '$table has a column whose TYPE / NOT NULL / DEFAULT differs '
            'between a new install and an upgraded one. The names match, so '
            'somebody added the column to both paths but declared it '
            'differently in one of them.',
      );
    }

    test('settings', () => expectSameColumns('settings'));
    test('history', () => expectSameColumns('history'));
    test('saved_devices', () => expectSameColumns('saved_devices'));
    test('diag_log', () => expectSameColumns('diag_log'));
  });

  group('the settings row survives a save', () {
    test('AppSettings.toMap covers every column design 0042 owns', () async {
      // `SettingsRepo.saveSettings` is INSERT OR REPLACE — SQLite deletes the
      // row and inserts a new one — so a column present in the schema but
      // ABSENT from `toMap()` is reset to its default on the next change to any
      // OTHER setting. This pins that `speed_detection`/`speed_unit` are not
      // in that position: they are written, and they survive an unrelated
      // write. (The four reserved columns deliberately ARE in that position
      // while nothing writes them; their designs must add them to `toMap()` in
      // the same change that starts writing them.)
      final dir = await Directory.systemTemp.createTemp('osb_v12_toMap');
      addTearDown(() => dir.delete(recursive: true));
      final db = await AppDatabase.open(
          path: p.join(dir.path, 'db'), factory: databaseFactoryFfi);
      addTearDown(db.close);
      final repo = SettingsRepo(db.db);

      await repo.saveSettings(const AppSettings(
        speedDetection: true,
        speedUnit: SpeedUnit.mph,
      ));
      expect((await repo.loadSettings()).speedDetection, isTrue);
      expect((await repo.loadSettings()).speedUnit, SpeedUnit.mph);

      // Now change something else entirely, the way the settings screen does.
      final after = (await repo.loadSettings()).copyWith(pollIntervalMs: 2000);
      await repo.saveSettings(after);
      final reloaded = await repo.loadSettings();
      expect(reloaded.speedDetection, isTrue,
          reason: 'changing the poll interval must not silently turn the '
              'speed feature back off');
      expect(reloaded.speedUnit, SpeedUnit.mph);
    });

    test('a pre-v12 row reads back as off, not on', () async {
      // `!= 0` — the shape the two neighbouring boolean settings use — would
      // read a missing column as ON. For this switch that means an upgrade
      // granting itself a location feature the user never consented to.
      expect(AppSettings.fromMap(const {}).speedDetection, isFalse);
      expect(AppSettings.fromMap(const {}).speedUnit, SpeedUnit.kmh);
      expect(
        AppSettings.fromMap(const {'speed_unit': 'not-a-unit'}).speedUnit,
        SpeedUnit.kmh,
        reason: 'an unreadable stored value lands on the default, the same '
            'rule _normaliseLogMaxBytes follows',
      );
    });
  });
}
