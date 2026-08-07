// design 0045 — the two settings columns, and the trap they were laid in.
//
// 🔴 `SettingsRepo.saveSettings` writes with `ConflictAlgorithm.replace`, which
// is `INSERT OR REPLACE`: SQLite DELETEs the whole row and inserts a new one.
// A column missing from `AppSettings.toMap()` is therefore not merely
// unpersisted — it is ERASED, later, by an unrelated write. Turn the G meter on,
// calibrate it, then change the theme, and the calibration is gone.
//
// `g_meter_enabled` and `g_calibration` shipped in v12 (design 0042 built them
// on 0045's behalf) with no writer at all, and both plans wrote down that they
// must join `toMap` in the same change that starts writing them. This file is
// that instruction, made executable.
//
// The last test is the general form and is the one worth keeping: EVERY column
// the settings table has must appear in the map. It would have caught this
// class of defect without anybody having to remember which feature is next.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<AppDatabase> openDb() => AppDatabase.open(
      path: inMemoryDatabasePath, factory: databaseFactoryFfi);

  test('defaults: off, and never calibrated', () {
    // Off is the promise made to everyone who never opens the setting, and
    // "never calibrated" is NULL rather than an identity matrix — see the field
    // doc for why an identity default would be actively wrong.
    expect(AppSettings.defaults.gMeterEnabled, isFalse);
    expect(AppSettings.defaults.gCalibration, isNull);
  });

  test('a calibration survives an unrelated settings change', () {
    // The exact defect the INSERT OR REPLACE note warns about, at the model
    // layer where it starts.
    const stored = '{"m":[1,0,0,0,1,0,0,0,1],"at":0}';
    const s = AppSettings(gMeterEnabled: true, gCalibration: stored);
    final after = s.copyWith(themeMode: AppThemeMode.dark);
    expect(after.gMeterEnabled, isTrue);
    expect(after.gCalibration, stored);
    expect(after.toMap()['g_calibration'], stored);
    expect(after.toMap()['g_meter_enabled'], 1);
  });

  test('and survives a real round trip through the database', () async {
    final db = await openDb();
    addTearDown(db.close);
    final repo = SettingsRepo(db.db);
    const stored = '{"m":[0,1,0,-1,0,0,0,0,1],"at":1754524800000}';

    await repo.saveSettings(
        const AppSettings(gMeterEnabled: true, gCalibration: stored));
    // Something completely unrelated writes next — this is the step that
    // erased the column before it was in the map.
    final loaded = await repo.loadSettings();
    await repo.saveSettings(loaded.copyWith(pollIntervalMs: 2000));

    final back = await repo.loadSettings();
    expect(back.gMeterEnabled, isTrue);
    expect(back.gCalibration, stored);
    expect(GForceCalibration.decode(back.gCalibration), isNotNull);
  });

  test('an unreadable stored matrix reads as "not calibrated", not as axes',
      () async {
    // Storage keeps the string; the DECODER is what refuses. Splitting it this
    // way means a corrupt value cannot be silently rewritten over the user's
    // real one, and cannot be used either.
    final db = await openDb();
    addTearDown(db.close);
    final repo = SettingsRepo(db.db);
    await repo.saveSettings(const AppSettings(
        gMeterEnabled: true, gCalibration: 'not json at all'));
    final back = await repo.loadSettings();
    expect(back.gCalibration, 'not json at all');
    expect(GForceCalibration.decode(back.gCalibration), isNull);

    final c = GForceController()..applySettings(back);
    expect(c.calibrated, isFalse);
    expect(c.available, isFalse, reason: 'the switch alone is not enough');
    c.dispose();
  });

  test('an empty string is normalised to null, not kept as a third state',
      () {
    expect(
      AppSettings.fromMap(const {'g_calibration': ''}).gCalibration,
      isNull,
    );
  });

  test('a pre-v12 row reads as OFF, not as ON', () {
    // `!= 0` on a missing column would read NULL as "on", which for a switch
    // gated by a consent dialog means an upgrade granting itself a feature the
    // user was never shown. Same shape, same reason, as speed_detection.
    expect(AppSettings.fromMap(const {}).gMeterEnabled, isFalse);
    expect(AppSettings.fromMap(const {'g_meter_enabled': null}).gMeterEnabled,
        isFalse);
    expect(AppSettings.fromMap(const {'g_meter_enabled': 1}).gMeterEnabled,
        isTrue);
  });

  test('clearing the calibration is expressible, and clears it', () async {
    // "校準歸零" (design 0045 §3.5). `copyWith(gCalibration: null)` cannot mean
    // this — null is how copyWith says "leave it alone" — so there is an
    // explicit flag, exactly as home_layout has.
    const s = AppSettings(gCalibration: '{"m":[1,0,0,0,1,0,0,0,1],"at":0}');
    expect(s.copyWith(gCalibration: null).gCalibration, isNotNull);
    expect(s.copyWith(clearGCalibration: true).gCalibration, isNull);
    expect(s.copyWith(clearGCalibration: true).toMap()['g_calibration'],
        isNull);
  });

  test('the settings controller is the only writer, and it round trips',
      () async {
    final db = await openDb();
    addTearDown(db.close);
    final c = SettingsController(SettingsRepo(db.db), history: HistoryRepo(db.db));
    await c.load();
    await c.setGMeterEnabled(true);
    await c.setGCalibration('{"m":[1,0,0,0,1,0,0,0,1],"at":0}');
    await c.setThemeMode(AppThemeMode.dark);
    final reloaded = await SettingsRepo(db.db).loadSettings();
    expect(reloaded.gMeterEnabled, isTrue);
    expect(reloaded.gCalibration, isNotNull);

    await c.setGCalibration(null);
    expect((await SettingsRepo(db.db).loadSettings()).gCalibration, isNull);
    expect((await SettingsRepo(db.db).loadSettings()).gMeterEnabled, isTrue,
        reason: 'zeroing the calibration is not switching the feature off');
  });

  test('🔴 EVERY settings column appears in AppSettings.toMap()', () async {
    // The general form, and the reason this file exists rather than three
    // feature-specific assertions. A column added to the schema without an
    // entry in the map does not fail to persist — it erases itself later, at a
    // moment unrelated to whatever wrote it. This catches the NEXT one.
    final db = await openDb();
    addTearDown(db.close);
    final info = await db.db.rawQuery('PRAGMA table_info(settings)');
    // Two exemptions, both RETIRED columns rather than oversights. Being reset
    // by a later write is the desired outcome for them, which is the opposite
    // of the defect this test is about — so they are named individually here
    // rather than the rule being loosened.
    const retired = {
      // Superseded by `theme_mode` (a string). Still READ by
      // `AppSettings._themeModeFromMap` so a user who last set a theme before
      // that change keeps it; never written again.
      'dark_theme',
      // The auto-log switch, removed when retention replaced it — the people
      // who turned it off were the people who later had no data to send.
      'auto_log',
    };
    final columns = info.map((r) => r['name'] as String).toSet()
      // The primary key is the repo's, not the model's: it is a fixed
      // single-row id, supplied by SettingsRepo.saveSettings.
      ..remove('id')
      ..removeAll(retired);
    final mapped = AppSettings.defaults.toMap().keys.toSet();
    expect(columns.difference(mapped), isEmpty,
        reason: 'these columns are in the table but not in toMap(), so '
            'INSERT OR REPLACE will erase them on the next settings write');
    expect(mapped.difference(columns), isEmpty,
        reason: 'toMap() names columns the table does not have');
  });
}
