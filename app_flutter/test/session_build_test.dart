// Every row remembers the build that RECORDED it.
//
// The export preamble names the build that pressed export, which is a
// different thing: these tables accumulate across upgrades. The 2026-07-27
// field log proves the gap — its header says `app: 0.6.7+2109` while its first
// section is a 2026-07-06 connection, recorded weeks earlier by a much older
// build. Reading that file, you cannot tell which build produced which rows.
//
// The properties that must hold:
//   1. a row carries the build that wrote it,
//   2. a build change starts a new log section, so one file can be read
//      per-version,
//   3. rows that predate this field (NULL) render EXACTLY as before — the
//      whole point of making the field optional rather than backfilling it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase appDb;
  setUp(() async {
    appDb = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async => appDb.close());

  TelemetrySample sampleAt(int ms) => TelemetrySample(
        timestamp: DateTime.fromMillisecondsSinceEpoch(ms),
        pvlt: 12.5,
      );

  group('log section labels', () {
    test('carry the recording build', () async {
      final repo = LogRepo(appDb.db);
      await repo.insertLog(LogEntry.event('a',
          deviceId: 'AA', sessionId: 1, appBuild: '0.6.8+26072812'));
      final out = await repo.exportLog(labelFor: (_) => 'pack');
      expect(
        out.split('\n').where((l) => l.startsWith('# ----')),
        ['# ---- device=pack session=1 app=0.6.8+26072812 ----'],
      );
    });

    test('a build change splits one device+session into two sections', () async {
      // The case this design exists for: the user updated the app between two
      // recordings. Without the build in the section key, the later rows would
      // be filed under a label naming a build that did not write them.
      final repo = LogRepo(appDb.db);
      await repo.insertLog(LogEntry.event('old',
          deviceId: 'AA', sessionId: 1, appBuild: '0.6.7+2109'));
      await repo.insertLog(LogEntry.event('new',
          deviceId: 'AA', sessionId: 1, appBuild: '0.6.8+26072812'));
      final out = await repo.exportLog(labelFor: (_) => 'pack');
      expect(out.split('\n').where((l) => l.startsWith('# ----')), [
        '# ---- device=pack session=1 app=0.6.7+2109 ----',
        '# ---- device=pack session=1 app=0.6.8+26072812 ----',
      ]);
    });

    test('rows without a build render exactly as they did pre-0010', () async {
      // Backfilling a guess would be worse than a blank. The label must be
      // byte-identical so old exports and existing parsers keep working.
      final repo = LogRepo(appDb.db);
      await repo.insertLog(LogEntry.event('scan start'));
      await repo.insertLog(LogEntry.event('a', deviceId: 'AA', sessionId: 1));
      final out = await repo.exportLog(labelFor: (_) => 'pack');
      expect(out.split('\n').where((l) => l.startsWith('# ----')), [
        '# ---- device=unattributed ----',
        '# ---- device=pack session=1 ----',
      ]);
      expect(out, isNot(contains('app=')));
      expect(out, isNot(contains('null')));
    });

    test('the build round-trips through the DB', () async {
      final repo = LogRepo(appDb.db);
      await repo.insertLog(LogEntry.event('a', appBuild: '0.6.8+26072812'));
      expect((await repo.queryLog()).single.appBuild, '0.6.8+26072812');
    });
  });

  group('CSV app_build', () {
    test('is appended after samples and round-trips', () async {
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(sampleAt(60000),
          deviceId: 'AA', samples: 900, appBuild: '0.6.8+26072812');
      final cols = HistoryRepo.csvColumns;
      expect(cols.indexOf('app_build'), cols.indexOf('samples') + 1);
      final out = await repo.exportCsv();
      final row = out.text.split(RegExp(r'\r?\n'))[1].split(',');
      expect(row[cols.indexOf('app_build')], '0.6.8+26072812');
    });

    test('the summary lists every build the rows came from', () async {
      // A file spanning an upgrade must say so at the top, because the
      // preamble's own `app:` line names only the exporting build.
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(sampleAt(60000),
          deviceId: 'AA', appBuild: '0.6.8+26072812');
      await repo.insertSample(sampleAt(120000),
          deviceId: 'AA', appBuild: '0.6.7+2109');
      final out = await repo.exportCsv(header: const ['t']);
      final summary =
          out.text.split(RegExp(r'\r?\n')).firstWhere((l) => l.contains('rows:'));
      expect(summary, contains('builds: 0.6.7+2109, 0.6.8+26072812'));
    });

    test('no builds line at all when nothing is known', () async {
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(sampleAt(60000), deviceId: 'AA');
      final out = await repo.exportCsv(header: const ['t']);
      final summary =
          out.text.split(RegExp(r'\r?\n')).firstWhere((l) => l.contains('rows:'));
      expect(summary, isNot(contains('builds:')),
          reason: 'an empty "builds:" would imply we looked and found nothing');
    });
  });

  group('schema v7 migration (v6 → v7)', () {
    test('adds app_build to both tables, leaving pre-v7 rows null', () async {
      // A real file: an in-memory DB is discarded on close, so the upgrade path
      // would never see the v6 data.
      final dir = await Directory.systemTemp.createTemp('osb_v7');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'v6.db');
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 6,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL, pvlt REAL, svlt REAL, ampere REAL,
                temperature INTEGER, dvol1 REAL, dvol2 REAL, dvol3 REAL,
                dvol4 REAL, soh INTEGER, mode INTEGER, twf INTEGER,
                serial TEXT, soc INTEGER, device_id TEXT, samples INTEGER
              )''');
            await db.execute('''
              CREATE TABLE diag_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL, direction TEXT NOT NULL,
                hex TEXT NOT NULL, note TEXT, device_id TEXT, session_id INTEGER
              )''');
            await db.execute('''
              CREATE TABLE saved_devices (
                id TEXT PRIMARY KEY, alias TEXT, name TEXT NOT NULL DEFAULT '',
                stale INTEGER NOT NULL DEFAULT 0,
                product_class TEXT NOT NULL DEFAULT 'unknown'
              )''');
            await db.execute(
                'CREATE TABLE settings (id INTEGER PRIMARY KEY, theme_mode TEXT)');
          },
        ),
      );
      await legacy.insert('history',
          {'timestamp': 60000, 'pvlt': 12.5, 'device_id': 'AA', 'samples': 900});
      await legacy.insert('diag_log',
          {'timestamp': 60000, 'direction': 'rx', 'hex': 'b820', 'session_id': 1});
      await legacy.close();

      final upgraded =
          await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      addTearDown(upgraded.close);

      final hist = await upgraded.db.query('history');
      final logs = await upgraded.db.query('diag_log');
      expect(hist, hasLength(1), reason: 'the upgrade must not drop data');
      expect(logs, hasLength(1));
      expect(hist.single['pvlt'], 12.5, reason: 'old values survive untouched');
      expect(hist.single['samples'], 900);
      expect(hist.single['app_build'], isNull);
      expect(logs.single['app_build'], isNull);
    });
  });
}
