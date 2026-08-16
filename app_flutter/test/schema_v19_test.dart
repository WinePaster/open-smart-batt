// Schema v19 — `settings.accent_theme`, the user's accent set (design 0064).
//
// WHY THIS FILE EXISTS. Another single nullable TEXT column, and the reason it
// gets its own file is the same as v18's: what the column DECIDES. This one
// repaints the app. Get the migration wrong and an existing user launches the
// new build to find every accent surface — the gauge arc, the nav bar, the
// filled buttons, the chart's voltage trace — in a colour they never picked,
// with nothing they did to explain it.
//
// 🔴 The claim under test is therefore "upgrading changes nothing" (design 0064
// G3), and it has to be checked at BOTH ends:
//
//   * the stored value is NULL, not `theme:amber` — a DEFAULT would make the
//     visual test pass while asserting something false about every upgraded
//     phone (that its owner chose amber). It also destroys the one fact that
//     decides whether a future re-tune of the six sets reaches somebody.
//   * `AppSettings.accentThemeId` reads NULL, and `AccentTheme.byId(null)`
//     resolves to amber — the two halves are separate, and a DEFAULT would hide
//     a broken decoder behind a correct-looking screen.
//
// Plus the two failure modes that only exist because the column stores a
// STRING chosen from a shipping list: a value this build does not know (a
// downgrade, or a withdrawn set), and a value in a format this build does not
// know (Phase 2's `custom:` triples). Both must land on amber without throwing
// — a settings decoder that can throw turns one cosmetic field into an app
// that will not start.
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
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

  /// Build a real v11 file on disk, seed a used phone's settings row, then open
  /// it with the current app. Identical to `schema_v18_test`'s helper and
  /// deliberately not shared: a fixture that the code under test could change
  /// out from under the assertions is not a fixture.
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

  group('v19: settings learns which accent set the user picked', () {
    test('the column exists after an upgrade', () async {
      final db = await upgradeFromV11('v19_col');
      expect(await _columnsOf(db.db, 'settings'), contains('accent_theme'));
    });

    test('🔑 a row written before the upgrade still renders AMBER', () async {
      // G3 in one assertion. Both halves: the decoder answers "no choice", and
      // the resolver turns that into the palette the phone already had.
      final db = await upgradeFromV11('v19_upgrade_amber');
      final settings = await SettingsRepo(db.db).loadSettings();
      expect(settings.accentThemeId, isNull);
      expect(AccentTheme.byId(settings.accentThemeId) ?? AccentTheme.amber,
          AccentTheme.amber);
      // …and the rest of the row survived, so this is a real settings row and
      // not a fall-through to `AppSettings.defaults`, which would report the
      // right answer for the wrong reason.
      expect(settings.themeMode, AppThemeMode.dark);
      expect(settings.pollIntervalMs, 500);
    });

    test('🔴 the stored value is NULL, not a default', () async {
      // `dflt_value` is checked as well as the row: a DEFAULT added later would
      // not show up in the row of a database that had already been upgraded.
      final db = await upgradeFromV11('v19_null');
      final row = (await db.db.query('settings', limit: 1)).single;
      expect(row['accent_theme'], isNull);
      expect(await _columnInfo(db.db, 'settings', 'accent_theme'),
          containsPair('dflt_value', isNull));
    });

    test('a withdrawn or unknown set falls back to amber, without throwing',
        () async {
      // What a phone reads after being downgraded from a build with a seventh
      // set. The fallback is silent and that is a deliberate, documented trade
      // (`AppSettings._accentThemeFromMap`) — the alternative, storing the
      // colours, would strand the user on a palette we had already replaced.
      final db = await upgradeFromV11('v19_unknown');
      for (final stored in ['theme:chartreuse', 'theme:', 'zzz', '']) {
        await db.db.update('settings', {'accent_theme': stored},
            where: 'id = ?', whereArgs: [1]);
        final s = await SettingsRepo(db.db).loadSettings();
        expect(AccentTheme.byId(s.accentThemeId) ?? AccentTheme.amber,
            AccentTheme.amber,
            reason: stored);
      }

      // 🔑 An unrecognised id is KEPT, not erased. The decoder validates the
      // FORMAT and leaves the vocabulary to `AccentTheme.byId`, so a phone that
      // is downgraded and then upgraded again finds its choice still there —
      // whereas a decoder that normalised the unknown value to null would have
      // silently spent the user's setting on its way past.
      await db.db.update('settings', {'accent_theme': 'theme:chartreuse'},
          where: 'id = ?', whereArgs: [1]);
      expect(
          (await SettingsRepo(db.db).loadSettings()).accentThemeId,
          'chartreuse');
    });

    test("Phase 2's custom: format does not decode as a set id", () async {
      // The reason the prefix exists. Without it the decoder would have to read
      // meaning out of a string's SHAPE — and `F6A821` is simultaneously a
      // legal set id. Same class of mistake as FB-32's optional header lines.
      final db = await upgradeFromV11('v19_custom');
      await db.db.update('settings', {'accent_theme': 'custom:2E7DF7/6FD8FF'},
          where: 'id = ?', whereArgs: [1]);
      final s = await SettingsRepo(db.db).loadSettings();
      expect(s.accentThemeId, isNull);
      // A bare hex string must not be mistaken for a set either.
      await db.db.update('settings', {'accent_theme': 'F6A821'},
          where: 'id = ?', whereArgs: [1]);
      expect((await SettingsRepo(db.db).loadSettings()).accentThemeId, isNull);
    });

    test('a chosen set survives a save/load round trip', () async {
      // `toMap` is an INSERT OR REPLACE of the whole row, so a column missing
      // from it does not merely fail to save — it erases itself later, on the
      // next unrelated settings change. Hence the second write.
      final db = await freshDatabase('v19_roundtrip');
      final repo = SettingsRepo(db.db);
      await repo.saveSettings(
          AppSettings.defaults.copyWith(accentThemeId: 'azure'));
      expect((await repo.loadSettings()).accentThemeId, 'azure');
      await repo.saveSettings(
          (await repo.loadSettings()).copyWith(pollIntervalMs: 2000));
      final after = await repo.loadSettings();
      expect(after.accentThemeId, 'azure',
          reason: 'a column absent from toMap() is wiped by the NEXT unrelated '
              'settings change, not by its own');
      expect(after.pollIntervalMs, 2000);
      // The wire format, asserted once: the field is a bare id, the column is
      // prefixed. Getting this backwards round-trips fine and breaks only when
      // Phase 2 adds a second prefix.
      final row = (await db.db.query('settings', limit: 1)).single;
      expect(row['accent_theme'], 'theme:azure');
    });

    test('clearing goes back to NULL, not to the string "amber"', () async {
      // `copyWith` cannot express a nullable field returning to null, which is
      // the trap `gCalibration` documents. "Never chose" has to stay reachable
      // or the re-tune argument above quietly stops working.
      final db = await freshDatabase('v19_clear');
      final repo = SettingsRepo(db.db);
      await repo.saveSettings(
          AppSettings.defaults.copyWith(accentThemeId: 'teal'));
      await repo.saveSettings((await repo.loadSettings())
          .copyWith(clearAccentTheme: true));
      expect((await repo.loadSettings()).accentThemeId, isNull);
      final row = (await db.db.query('settings', limit: 1)).single;
      expect(row['accent_theme'], isNull);
    });
  });

  group('a fresh database and an upgraded one are the same schema', () {
    test('settings: identical columns', () async {
      // The CREATE list and the migration chain are two independent
      // descriptions of one schema, and every migration this project has
      // shipped had to touch both.
      final upgraded = await upgradeFromV11('v19_parity');
      final fresh = await freshDatabase('v19_parity_new');
      expect(
        await _columnsOf(upgraded.db, 'settings'),
        await _columnsOf(fresh.db, 'settings'),
      );
    });

    test('both report the current schema version', () async {
      final upgraded = await upgradeFromV11('v19_ver');
      final fresh = await freshDatabase('v19_ver_new');
      for (final db in <AppDatabase>[upgraded, fresh]) {
        final v = (await db.db.rawQuery('PRAGMA user_version')).single;
        expect(v['user_version'], Db.schemaVersion);
        // 🔴 A FLOOR, not a pin — the exact pin moved on to `schema_v20_test`
        // when design 0066 landed, exactly as the note here instructed. What
        // this file still has to prove is that a v11 phone reaching v19's
        // column does not stop reaching it once later versions are appended.
        expect(Db.schemaVersion, greaterThanOrEqualTo(19));
      }
    });
  });
}
