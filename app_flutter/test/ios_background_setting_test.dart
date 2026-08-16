// design 0047 Phase 1 — the iOS background-monitoring setting and its column.
//
// The pivotal claim is the Q4 ruling: iOS DEFAULTS OFF, including for every
// existing install. That is not one fact but three, and each has its own
// failure mode:
//
//   * the model default ([AppSettings.backgroundMonitoringIos] = false) — a
//     fresh install must not opt itself in;
//   * the decoder shape (`== 1`, missing column reads OFF) — an UPGRADED
//     install must not opt itself in either, and this is the branch that
//     actually carries the ruling, because every iOS row already stores 1 in
//     the ANDROID column (`toMap` persisted the Android default on every
//     settings change while the iOS switch was disabled — FB-26), so reusing
//     that column would have granted background execution to every iOS user
//     silently;
//   * the platform dispatch (SettingsController) — the two columns must never
//     read or write each other, or one platform's default leaks into the
//     other's. Android's field, default and column are asserted UNCHANGED
//     (hard condition 1).
//
// Plus the v13 migration itself, in the schema_v12_test tradition: the
// upgraded table and the freshly-created table must agree, because
// `_createStatements` and `_onUpgrade` are two pieces of code no compiler
// relates to each other.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The v12 settings shape, written out BY HAND (sharing `_createStatements`
/// with the code under test would make the migration test pass no matter what
/// it did).
const String _v12Settings = '''
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
    log_max_bytes INTEGER NOT NULL DEFAULT 20971520,
    speed_detection INTEGER NOT NULL DEFAULT 0,
    speed_unit TEXT NOT NULL DEFAULT 'kmh',
    home_layout TEXT,
    g_meter_enabled INTEGER NOT NULL DEFAULT 0,
    g_calibration TEXT
  )''';

class _MemSettingsRepo implements SettingsRepo {
  AppSettings stored = AppSettings.defaults;

  @override
  Future<AppSettings> loadSettings() async => stored;

  @override
  Future<void> saveSettings(AppSettings settings) async => stored = settings;

  @override
  Future<void> resetToDefaults() async => stored = AppSettings.defaults;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('defaults (Q4 ruling)', () {
    test('iOS background monitoring defaults OFF; Android stays ON', () {
      const d = AppSettings.defaults;
      expect(d.backgroundMonitoringIos, isFalse,
          reason: 'Q4: the user opts in; battery cost and iOS scheduling '
              'limits are not something a default may sign them up for');
      expect(d.backgroundMonitoring, isTrue,
          reason: 'hard condition 1: the Android default is untouched '
              '(FB-26 — the stall is the out-of-box experience without it)');
    });
  });

  group('row decoding', () {
    test('a pre-v13 row (no column) reads OFF — upgrades cannot self-grant',
        () {
      final migrated = AppSettings.fromMap(const {
        // What every real iOS row looks like at upgrade time: the ANDROID
        // column holds 1, persisted by toMap while the iOS switch was
        // disabled. It was never a choice, and it must not read as one.
        'background_monitoring': 1,
      });
      expect(migrated.backgroundMonitoringIos, isFalse);
      expect(migrated.backgroundMonitoring, isTrue);
    });

    test('an explicit opt-in survives the round trip', () {
      final s = AppSettings.defaults.copyWith(backgroundMonitoringIos: true);
      expect(s.toMap()['background_monitoring_ios'], 1);
      expect(AppSettings.fromMap(s.toMap()).backgroundMonitoringIos, isTrue);
    });

    test('toMap carries the column — INSERT OR REPLACE must not erase it', () {
      // The 🔴 note on AppSettings.toMap: a column missing from the map is
      // silently reset the next time ANY setting changes.
      expect(AppSettings.defaults.toMap(),
          contains('background_monitoring_ios'));
    });
  });

  group('SettingsController platform dispatch', () {
    test('iOS: reads and writes the iOS field only', () async {
      final repo = _MemSettingsRepo();
      final c = SettingsController(repo, isIOS: true);
      await c.load();

      expect(c.backgroundMonitoring, isFalse, reason: 'iOS default off');

      await c.setBackgroundMonitoring(true);
      expect(c.backgroundMonitoring, isTrue);
      expect(repo.stored.backgroundMonitoringIos, isTrue);
      expect(repo.stored.backgroundMonitoring, isTrue,
          reason: 'the Android column is not this toggle\'s to write');
    });

    test('Android: reads and writes the Android field only', () async {
      final repo = _MemSettingsRepo();
      final c = SettingsController(repo, isIOS: false);
      await c.load();

      expect(c.backgroundMonitoring, isTrue, reason: 'Android default on');

      await c.setBackgroundMonitoring(false);
      expect(c.backgroundMonitoring, isFalse);
      expect(repo.stored.backgroundMonitoring, isFalse);
      expect(repo.stored.backgroundMonitoringIos, isFalse,
          reason: 'and the iOS column is not this toggle\'s to write');
    });
  });

  group('schema v13 migration (v12 → v13)', () {
    test('a v12 database gains background_monitoring_ios, defaulting OFF',
        () async {
      // A real file: an in-memory DB is discarded on close, so the upgrade
      // path would never see the v12 data.
      final dir = await Directory.systemTemp.createTemp('osb_v13');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'v12.db');
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 12,
          onCreate: (db, _) async {
            await db.execute(_v12Settings);
            // A stub `history`, because from v17 the upgrade chain ALTERs it
            // (design 0061 / FB-71 adds `bucket_s`) and a fixture without the
            // table cannot be opened at all. Only the two columns that
            // migration names — this file is about `settings`, and widening the
            // stub would invite the next person to assert history facts from a
            // shape nothing guarantees.
            await db.execute('CREATE TABLE history ('
                'id INTEGER PRIMARY KEY AUTOINCREMENT, '
                'timestamp INTEGER NOT NULL, device_id TEXT)');
            // …and a stub `saved_devices`, because from v20 the chain ALTERs
            // that one too (design 0066 adds the seven `declared_*` columns).
            // Same rule and same narrowness as the history stub above: only
            // what the migration needs, so nobody asserts device facts from a
            // shape nothing guarantees.
            await db.execute("CREATE TABLE saved_devices ("
                "id TEXT PRIMARY KEY, alias TEXT NOT NULL DEFAULT '')");
          },
        ),
      );
      // An iOS user's real row: the Android column carries the 1 that toMap
      // always persisted there. (Also a user who had turned the wakelock on,
      // so v13 provably leaves neighbouring choices alone.)
      await legacy.insert('settings', {
        'id': 1,
        'background_monitoring': 1,
        'background_keep_alive': 1,
      });
      await legacy.close();

      final upgraded =
          await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      addTearDown(upgraded.close);
      final row = (await upgraded.db.query('settings')).single;

      expect(row['background_monitoring_ios'], 0,
          reason: 'Q4: upgrading iOS users have never been asked, so the '
              'upgrade must not answer for them');
      expect(row['background_monitoring'], 1,
          reason: 'the Android column is untouched — its 1 stays exactly '
              'as misleading as it always was, which is why v13 could not '
              'reuse it');
      expect(row['background_keep_alive'], 1);

      // And the loaded settings agree end to end.
      final loaded = await SettingsRepo(upgraded.db).loadSettings();
      expect(loaded.backgroundMonitoringIos, isFalse);
      expect(loaded.backgroundMonitoring, isTrue);
    });

    test('an upgraded settings table matches a freshly created one', () async {
      // The schema_v12_test discipline: _createStatements and _onUpgrade are
      // two pieces of code no compiler relates to each other, and every
      // migration this project has shipped had to touch both.
      final dir = await Directory.systemTemp.createTemp('osb_v13_parity');
      addTearDown(() => dir.delete(recursive: true));

      final upgradedPath = p.join(dir.path, 'upgraded.db');
      final legacy = await databaseFactoryFfi.openDatabase(
        upgradedPath,
        options: OpenDatabaseOptions(
          version: 12,
          onCreate: (db, _) async {
            await db.execute(_v12Settings);
            // A stub `history`, because from v17 the upgrade chain ALTERs it
            // (design 0061 / FB-71 adds `bucket_s`) and a fixture without the
            // table cannot be opened at all. Only the two columns that
            // migration names — this file is about `settings`, and widening the
            // stub would invite the next person to assert history facts from a
            // shape nothing guarantees.
            await db.execute('CREATE TABLE history ('
                'id INTEGER PRIMARY KEY AUTOINCREMENT, '
                'timestamp INTEGER NOT NULL, device_id TEXT)');
            // …and a stub `saved_devices`, because from v20 the chain ALTERs
            // that one too (design 0066 adds the seven `declared_*` columns).
            // Same rule and same narrowness as the history stub above: only
            // what the migration needs, so nobody asserts device facts from a
            // shape nothing guarantees.
            await db.execute("CREATE TABLE saved_devices ("
                "id TEXT PRIMARY KEY, alias TEXT NOT NULL DEFAULT '')");
          },
        ),
      );
      await legacy.close();
      final upgraded = await AppDatabase.open(
          path: upgradedPath, factory: databaseFactoryFfi);
      addTearDown(upgraded.close);

      final fresh = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      addTearDown(fresh.close);

      Future<Set<String>> columnsOf(AppDatabase d) async {
        final info = await d.db.rawQuery('PRAGMA table_info(settings)');
        return {for (final r in info) r['name'] as String};
      }

      final upgradedCols = await columnsOf(upgraded);
      final freshCols = await columnsOf(fresh);
      // _createStatements still carries the dead legacy columns (dark_theme,
      // auto_log) precisely so the two shapes stay identical; the sets must
      // therefore match EXACTLY in both directions.
      expect(upgradedCols.difference(freshCols), isEmpty);
      expect(freshCols.difference(upgradedCols), isEmpty,
          reason: 'a column added for new installs only is the failure mode '
              'this comparison exists to catch');
      expect(freshCols, contains('background_monitoring_ios'));
    });
  });
}
