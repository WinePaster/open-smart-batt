// Design 0030 T4b / T4c, FB-59 and FB-60 — the history CSV export.
//
// Three properties, and each one is a defect that shipped:
//
//  * FB-59 / T4c — the export used to inherit the History LIST's `_rowCap =
//    1000`, so any range holding more than a thousand rows was silently cut to
//    its newest thousand. Nothing in the file said so. `more than 1,000 rows`
//    below is the acceptance test for that, and it is deliberately a direct,
//    boring row count rather than anything clever: the failure it guards
//    against looked exactly like success.
//
//  * T4b — the whole export existed in memory three times over (`List<Map>` →
//    `List<List>` → one `String`) and was built in one uninterrupted
//    synchronous block, so a large export both risked OOM and froze the event
//    loop the BLE link runs on. The 90,720-row case here is the design's own
//    yardstick: the busiest observed user's WEEK at one row per second.
//
//  * FB-60 — a file could not say which range had been ASKED for, only which
//    range its rows happened to span.
//
// The 90,720-row test is slow by nature; it inserts in batched transactions
// for that reason, and it is the only place the full size is exercised.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/theme/accent_theme.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase appDb;
  late Directory tmp;
  setUp(() async {
    appDb = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    tmp = await Directory.systemTemp.createTemp('osb-export-test');
  });
  tearDown(() async {
    await appDb.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// Insert [n] history rows in batched transactions, newest last.
  ///
  /// Raw column writes rather than [HistoryRepo.insertSample]: that one runs a
  /// read-modify-write per row to merge same-minute segments (design 0048),
  /// which is correct for the app and far too slow for ninety thousand rows.
  /// Every timestamp here is distinct anyway, so there is nothing to merge.
  Future<void> seed(
    int n, {
    required DateTime from,
    Duration step = const Duration(seconds: 1),
    String? deviceId,
    String? appBuild,
    int chunk = 10000,
  }) async {
    for (var i = 0; i < n; i += chunk) {
      final batch = appDb.db.batch();
      for (var j = i; j < i + chunk && j < n; j++) {
        batch.insert(Db.tableHistory, <String, Object?>{
          'timestamp': from.add(step * j).millisecondsSinceEpoch,
          'pvlt': 12.0 + j / 100000,
          'svlt': 13.0,
          'ampere': 1.5,
          'temperature': 25,
          'soh': 95,
          'mode': 0,
          'twf': 0,
          'serial': '0001234',
          'device_id': deviceId,
          'samples': 5,
          'app_build': appBuild,
        });
      }
      await batch.commit(noResult: true);
    }
  }

  /// Number of lines in [f], counted by streaming so the assertion does not
  /// itself need the file in memory.
  Future<int> lineCount(File f) => f
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .length;

  /// The `#` preamble of [f], `# ` stripped — the same thing `tools/fbparse.py`
  /// collects.
  Future<List<String>> preamble(File f) async {
    final out = <String>[];
    await for (final line in f
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!line.startsWith('#')) break;
      out.add(line.replaceFirst(RegExp(r'^#\s?'), ''));
    }
    return out;
  }

  group('T4c / FB-59: the export is no longer capped at 1,000 rows', () {
    test('more than 1,000 rows: every one of them is in the file', () async {
      final repo = HistoryRepo(appDb.db);
      const n = 1500;
      await seed(n, from: DateTime(2026, 8, 1));

      final file = File('${tmp.path}/over-cap.csv');
      // 🔴 At SECOND granularity, deliberately. `seed` steps one second at a
      // time, so a per-minute export of this fixture writes 25 rows — and that
      // is design 0061 T4d working, not the truncation this test exists to
      // forbid. The guarantee here is "the export has no row CAP", which is a
      // statement about the raw path; the aggregating path's honesty is pinned
      // separately below.
      final rows = await repo.exportCsvToFile(
        file,
        granularity: HistoryGranularity.second,
        header: const ['title', 'scope: all devices'],
      );

      expect(rows, n, reason: 'the return value is the acceptance point');
      // Counted off the file itself, not the return value: the defect was that
      // those two agreed with each other and disagreed with the data.
      final lines = await lineCount(file);
      final head = await preamble(file);
      expect(lines - head.length - 1, n); // -preamble, -column header
      expect(head, anyElement(startsWith('rows: $n  ')));
    });

    test('the row count in the header equals the rows written', () async {
      final repo = HistoryRepo(appDb.db);
      await seed(4321, from: DateTime(2026, 8, 1));
      final file = File('${tmp.path}/count.csv');
      final rows = await repo.exportCsvToFile(file, header: const ['t']);
      final head = await preamble(file);
      final summary = head.firstWhere((l) => l.startsWith('rows: '));
      expect(summary, startsWith('rows: $rows  range: '));
      expect(await lineCount(file), head.length + 1 + rows);
    });

    test('exportCsvToFile takes no row limit at all', () {
      // The compiler is the guard, not a reviewer: T4c's failure mode was a
      // call site passing a cap that happened to be in scope, so the parameter
      // is gone rather than defaulted. This test exists to make the intent
      // explicit — `exportCsvToFile(file, limit: 1000)` does not compile.
      expect(HistoryRepo(appDb.db).exportCsvToFile, isA<Function>());
    });
  });

  group('T4b: paging is invisible in the output', () {
    test('a page boundary neither duplicates nor drops a row', () async {
      // 10,001 rows over a 5,000-row page = two full pages and a remainder, so
      // both boundaries are crossed.
      final repo = HistoryRepo(appDb.db);
      const n = 10001;
      await seed(n, from: DateTime(2026, 8, 1));
      final file = File('${tmp.path}/pages.csv');
      // Second granularity: paging is a property of the raw path, and 10,001
      // one-second rows are 168 minutes — far too few to cross a page boundary.
      final rows = await repo.exportCsvToFile(file,
          granularity: HistoryGranularity.second, header: const ['t']);
      expect(rows, n);

      final seen = <String>{};
      var dupes = 0;
      var data = 0;
      await for (final line in file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.startsWith('#') || line.startsWith('timestamp,')) continue;
        data++;
        if (!seen.add(line.split(',').first)) dupes++;
      }
      expect(data, n);
      expect(dupes, 0);
      expect(seen, hasLength(n));
    });

    test('the streamed file and the in-memory export are byte-identical',
        () async {
      // The paged writer emits the row separator itself between pages; if it
      // ever disagreed with the converter's, every 5,000th row would join the
      // one before it. This pins the two together.
      final repo = HistoryRepo(appDb.db);
      await seed(6000, from: DateTime(2026, 8, 1), deviceId: 'AA', appBuild: '9');
      final file = File('${tmp.path}/identical.csv');
      await repo.exportCsvToFile(file,
          labelFor: (id) => 'pack-$id', header: const ['t']);
      final inMemory =
          await repo.exportCsv(labelFor: (id) => 'pack-$id', header: const ['t']);
      expect(await file.readAsString(), inMemory.text);
    });

    test('the file grows while the export is still running', () async {
      // What "streamed" means, observably: bytes reach the disk before the
      // future completes, which can only happen if the writer hands the event
      // loop back between pages (and is exactly what a single
      // `convert()`-then-write could not do).
      final repo = HistoryRepo(appDb.db);
      await seed(20000, from: DateTime(2026, 8, 1));
      final file = File('${tmp.path}/growing.csv');

      var polling = true;
      final sizes = <int>[];
      Future<void> poll() async {
        while (polling) {
          if (file.existsSync()) sizes.add(await file.length());
          await Future<void>.delayed(Duration.zero);
        }
      }

      final watcher = poll();
      await repo.exportCsvToFile(file, header: const ['t']);
      polling = false;
      await watcher;

      final finalSize = await file.length();
      final partial = sizes.where((s) => s > 0 && s < finalSize);
      expect(partial, isNotEmpty,
          reason: 'no intermediate size observed — the export was not streamed');
    });
  });

  group('FB-60: the preamble says which window was asked for', () {
    test('historyWindowLabel is machine-stable and carries the cut-off', () {
      final since = DateTime(2026, 8, 4);
      expect(historyWindowLabel(HistoryRange.today, since),
          'today  since=${since.toIso8601String()}');
      expect(historyWindowLabel(HistoryRange.week, since),
          '7d  since=${since.toIso8601String()}');
      // "all" has no cut-off, so it states none rather than inventing one.
      expect(historyWindowLabel(HistoryRange.all, null), 'all');
    });

    List<String> header({String? window}) => exportHeaderLines(
          title: 'OpenSmartBatt history export',
          exportedAt: DateTime(2026, 8, 11),
          appBuild: '0.7.11+26081001',
          platform: 'android',
          scope: 'all devices',
          window: window,
          layout: 'face=fixed modules=x',
          home: 'grid',
          // design 0063: a `required` param, so every direct caller has to name it. Personal is today's app.
          mode: AppMode.personal,
          themeMode: AppThemeMode.light,
          accent: AccentTheme.amber,
          speedDetection: false,
          gMeter: false,
          resolution: ExportResolution.forCsv(
              HistoryGranularity.minute, const [60]),
        );

    test('the window line is emitted when the caller supplies one', () {
      final lines = header(window: '7d  since=2026-08-04T00:00:00.000');
      expect(lines.where((l) => l.startsWith('window: ')), hasLength(1));
      expect(lines, contains('window: 7d  since=2026-08-04T00:00:00.000'));
    });

    test('it comes BEFORE the layout line, which stays last', () {
      // The same constraint every added line has had to satisfy since design
      // 0034: the ingest recipes anchor on `layout:` closing the preamble.
      final lines = header(window: 'all');
      expect(lines.last, startsWith('layout: '));
      expect(lines.indexOf('window: all'), lessThan(lines.length - 1));
    });

    test('it is omitted entirely when there is no window (the diag log)', () {
      // Not `window: -`: an empty field reads as a bug, and the diagnostic log
      // genuinely has no time range to declare.
      expect(header().any((l) => l.startsWith('window')), isFalse);
    });

    test('it reaches the exported file, and stays a # comment', () async {
      final repo = HistoryRepo(appDb.db);
      await seed(10, from: DateTime(2026, 8, 1));
      final file = File('${tmp.path}/window.csv');
      await repo.exportCsvToFile(file, header: header(window: 'all'));
      final head = await preamble(file);
      expect(head, contains('window: all'));
      // `tools/fbparse.py:csv_header` reads leading `#` lines and stops at the
      // first that is not one. The new line must therefore sit inside that
      // block, above the column header, or it would be read as data.
      final first = await file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .take(head.length + 1)
          .toList();
      expect(first.last, startsWith('timestamp,'));
      expect(first.where((l) => l.startsWith('window')), isEmpty,
          reason: 'the line must carry its # prefix like every other');
    });
  });

  group('T4-test: the busiest observed user, one week at 1 Hz', () {
    // 216 minutes/day × 60 rows/minute × 7 days = 90,720 (design 0030 §1.1).
    test('90,720 rows export completely, without a row cap', () async {
      final repo = HistoryRepo(appDb.db);
      const n = 90720;
      const capId = 'CAP-1';
      final seeded = Stopwatch()..start();
      await seed(n, from: DateTime(2026, 8, 1), deviceId: capId, appBuild: '26081001');
      seeded.stop();

      final file = File('${tmp.path}/busy-week.csv');
      final ran = Stopwatch()..start();
      final rows = await repo.exportCsvToFile(
        file,
        // The whole week AS RECORDED — see the note on the 1,500-row test.
        granularity: HistoryGranularity.second,
        labelFor: (id) => 'super-cap',
        // The super-capacitor rule (FB-21's neighbour): 0x2E is pinned at 0.0 A
        // on a unit that cannot measure current, so the column is left EMPTY
        // rather than exported as a zero the device never claimed. Paging must
        // not have quietly dropped the per-row class lookup.
        classFor: (id) => ProductClass.supercapacitor,
        header: const [
          'OpenSmartBatt history export',
          'scope: device=capacitor/1206',
          'window: all',
        ],
      );
      ran.stop();

      expect(rows, n, reason: 'the whole week, not the newest 1,000 rows');
      final head = await preamble(file);
      expect(head, anyElement(startsWith('rows: $n  ')));
      expect(head, contains('window: all'));
      expect(await lineCount(file), head.length + 1 + n);

      // Spot-check the capacitor rule on a row well past the first page.
      final ampereIdx = HistoryRepo.csvColumns.indexOf('ampere');
      final deviceIdx = HistoryRepo.csvColumns.indexOf('device');
      var checked = 0;
      var i = 0;
      await for (final line in file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.startsWith('#') || line.startsWith('timestamp,')) continue;
        i++;
        if (i == 1 || i == 5001 || i == 60000 || i == n) {
          final cells = line.split(',');
          // `null` is this exporter's empty cell, the same one the dvol
          // columns have always used (per_device_export_test.dart pins it).
          // The point here is that it is NOT `1.5` — the value the row
          // actually holds — on any page.
          expect(cells[ampereIdx], 'null',
              reason: 'a capacitor exports no current, on every page');
          expect(cells[deviceIdx], 'super-cap',
              reason: 'the human-readable identity, never the raw id');
          expect(line, isNot(contains(capId)));
          checked++;
        }
      }
      expect(checked, 4);

      // Not a performance assertion — a ceiling loose enough that only a
      // regression to whole-table-in-memory behaviour could trip it.
      // ignore: avoid_print
      print('90,720 rows: seeded in ${seeded.elapsed.inMilliseconds} ms, '
          'exported in ${ran.elapsed.inMilliseconds} ms, '
          '${await file.length()} bytes');
      expect(ran.elapsed, lessThan(const Duration(minutes: 5)));
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
