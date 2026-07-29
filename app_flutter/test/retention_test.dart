// design 0011 — retention replaces the auto-log switch.
//
// The switch's only effect was whether history rows were written at all, so the
// people who turned it off were exactly the people who later could not produce
// data when asked. Recording is now unconditional and the user instead chooses
// how long it is KEPT.
//
// The properties worth pinning are the ones that could silently destroy data:
// the default must not prune, upgrading must not prune, and shortening the
// window must prune only what it claims to.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/settings_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  _logBudgetTests();

  setUpAll(sqfliteFfiInit);

  late AppDatabase appDb;
  setUp(() async {
    appDb = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async => appDb.close());

  TelemetrySample at(DateTime t) => TelemetrySample(timestamp: t, pvlt: 12.5);

  group('RetentionPolicy', () {
    test('defaults to forever, which never prunes', () {
      expect(AppSettings.defaults.retention, RetentionPolicy.forever);
      expect(RetentionPolicy.forever.maxAge, isNull);
    });

    test('windows match their names', () {
      expect(RetentionPolicy.days30.maxAge, const Duration(days: 30));
      expect(RetentionPolicy.days90.maxAge, const Duration(days: 90));
      expect(RetentionPolicy.days365.maxAge, const Duration(days: 365));
    });

    test('an unreadable stored value falls back to forever, not to pruning',
        () {
      // A corrupt or future value must never be interpreted as "delete things".
      final s = AppSettings.fromMap(const {'retention': 'not-a-policy'});
      expect(s.retention, RetentionPolicy.forever);
    });
  });

  group('pruning', () {
    Future<List<DateTime>> stamps(HistoryRepo r) async =>
        (await r.querySamples()).map((s) => s.timestamp).toList();

    test('forever keeps everything', () async {
      final history = HistoryRepo(appDb.db);
      final settings = SettingsController(SettingsRepo(appDb.db),
          history: history);
      await settings.load();
      final old = DateTime.now().subtract(const Duration(days: 400));
      await history.insertSample(at(old));
      await history.insertSample(at(DateTime.now()));

      await settings.pruneHistory();
      expect(await history.count(), 2);
    });

    test('a 30-day window drops older rows and keeps the ones inside it',
        () async {
      final history = HistoryRepo(appDb.db);
      final settings = SettingsController(SettingsRepo(appDb.db),
          history: history);
      await settings.load();

      final now = DateTime.now();
      final keep = now.subtract(const Duration(days: 29));
      final drop = now.subtract(const Duration(days: 31));
      await history.insertSample(at(keep));
      await history.insertSample(at(drop));

      await settings.setRetention(RetentionPolicy.days30);

      final left = await stamps(history);
      expect(left, hasLength(1));
      expect(left.single.millisecondsSinceEpoch, keep.millisecondsSinceEpoch,
          reason: 'the row inside the window must survive');
    });

    test('setRetention applies immediately, not at next launch', () async {
      // The user picked "30 days" expecting the old rows to be gone now.
      final history = HistoryRepo(appDb.db);
      final settings = SettingsController(SettingsRepo(appDb.db),
          history: history);
      await settings.load();
      await history
          .insertSample(at(DateTime.now().subtract(const Duration(days: 90))));

      await settings.setRetention(RetentionPolicy.days30);
      expect(await history.count(), 0);
    });
  });

  group('schema v9 migration (v8 → v9)', () {
    test('an upgrading user gets forever — including one who had auto-log off',
        () async {
      final dir = await Directory.systemTemp.createTemp('osb_v9');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'v8.db');
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 8,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                auto_reconnect INTEGER NOT NULL DEFAULT 1,
                poll_interval_ms INTEGER NOT NULL DEFAULT 1000,
                background_keep_alive INTEGER NOT NULL DEFAULT 0,
                background_monitoring INTEGER NOT NULL DEFAULT 1,
                dark_theme INTEGER NOT NULL DEFAULT 1, theme_mode TEXT,
                lang TEXT NOT NULL DEFAULT 'zhHant',
                temp_unit TEXT NOT NULL DEFAULT 'celsius',
                auto_log INTEGER NOT NULL DEFAULT 1,
                raw_packet_log INTEGER NOT NULL DEFAULT 0,
                log_max_bytes INTEGER NOT NULL DEFAULT ${5 * 1024 * 1024}
              )''');
            await db.execute('''
              CREATE TABLE history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL, pvlt REAL, svlt REAL, ampere REAL,
                temperature INTEGER, dvol1 REAL, dvol2 REAL, dvol3 REAL,
                dvol4 REAL, soh INTEGER, mode INTEGER, twf INTEGER,
                serial TEXT, soc INTEGER, device_id TEXT, samples INTEGER,
                app_build TEXT
              )''');
            await db.execute('''
              CREATE TABLE diag_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL, direction TEXT NOT NULL,
                hex TEXT NOT NULL, note TEXT, device_id TEXT,
                session_id INTEGER, app_build TEXT
              )''');
            await db.execute('''
              CREATE TABLE saved_devices (
                id TEXT PRIMARY KEY, alias TEXT, name TEXT NOT NULL DEFAULT '',
                stale INTEGER NOT NULL DEFAULT 0,
                product_class TEXT NOT NULL DEFAULT 'unknown'
              )''');
          },
        ),
      );
      // Someone who had deliberately switched recording OFF, with history from
      // before they did so.
      await legacy.insert('settings', {'id': 1, 'auto_log': 0});
      await legacy.insert('history',
          {'timestamp': DateTime.now().millisecondsSinceEpoch, 'pvlt': 12.5});
      await legacy.close();

      final upgraded =
          await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      addTearDown(upgraded.close);

      final row = (await upgraded.db.query('settings')).single;
      expect(row['retention'], 'forever',
          reason: 'upgrading must never start deleting history');
      expect(row['auto_log'], 0,
          reason: 'the dead column stays put — SQLite cannot drop it here');
      expect(await HistoryRepo(upgraded.db).count(), 1,
          reason: 'their existing rows survive the upgrade');
    });
  });
}

// ---------------------------------------------------------------------------
// Diagnostic-log budget (2026-07-29: 5/20 MB -> 20/100 MB)
// ---------------------------------------------------------------------------
//
// Raising the options is trivial; the part that can break silently is the
// EXISTING user. `SegmentedControl` matches on `==`, so a stored budget that is
// no longer offered leaves the control with nothing selected — which reads as a
// broken screen, not a stale preference. These pin the normalisation.
void _logBudgetTests() {
  group('log budget options (20 / 100 MB)', () {
    test('the offered set is exactly 20 and 100 MB', () {
      expect(AppSettings.logMaxBytesOptions,
          [20 * 1024 * 1024, 100 * 1024 * 1024]);
      expect(AppSettings.defaultLogMaxBytes, 20 * 1024 * 1024);
    });

    test('a legacy 5 MB row normalises to the new default', () {
      // Pre-2026-07-29 installs stored 5 MB. Left alone it would render an
      // unselected control.
      final s = AppSettings.fromMap({'log_max_bytes': 5 * 1024 * 1024});
      expect(s.logMaxBytes, AppSettings.defaultLogMaxBytes);
      expect(AppSettings.logMaxBytesOptions.contains(s.logMaxBytes), isTrue);
    });

    test('a stored 20 MB row is kept as-is', () {
      final s = AppSettings.fromMap({'log_max_bytes': 20 * 1024 * 1024});
      expect(s.logMaxBytes, 20 * 1024 * 1024);
    });

    test('100 MB round-trips', () {
      final s = AppSettings.fromMap({'log_max_bytes': 100 * 1024 * 1024});
      expect(s.logMaxBytes, 100 * 1024 * 1024);
    });

    test('a missing or nonsense value falls back to the default', () {
      expect(AppSettings.fromMap({}).logMaxBytes,
          AppSettings.defaultLogMaxBytes);
      expect(AppSettings.fromMap({'log_max_bytes': 7}).logMaxBytes,
          AppSettings.defaultLogMaxBytes);
    });

    test('every offered option is selectable without normalisation', () {
      // Guards the next person who edits the list but forgets fromMap.
      for (final v in AppSettings.logMaxBytesOptions) {
        expect(AppSettings.fromMap({'log_max_bytes': v}).logMaxBytes, v);
      }
    });
  });
}
