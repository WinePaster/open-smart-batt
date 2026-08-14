// Export granularity — design 0061 T4 (FB-71), which also closes design 0030's
// T4d.
//
// Storage went to one row per second; a file made out of it does NOT have to be.
// The user picks, the default is per minute (byte for byte what every export
// produced before FB-71, and the only shape that stays sendable over LINE), and
// the preamble says both what was asked for and what the file actually holds.
//
// 🔴 The rule this file exists to keep: **a per-second export of a range that
// reaches back before FB-71 emits the old minute rows AS THEY ARE.** Skipping
// them would be silent data loss (FB-21's shape, and design 0030 K1b forbids
// it outright); expanding one into 60 identical seconds would be inventing
// measurements nobody took. So they come out unchanged, and the `bucket_s`
// column on every row says which is which.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';
import 'package:open_smart_batt/ui/util/export_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late HistoryRepo history;

  setUp(() async {
    db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    history = HistoryRepo(db.db);
  });

  tearDown(() async => db.close());

  // Local time, because the export renders local ISO-8601 and buckets on the
  // viewer's own boundaries.
  final legacyMinute = DateTime(2026, 8, 13, 9, 50);
  final newMinute = DateTime(2026, 8, 14, 9, 50);

  Future<void> put({
    required DateTime at,
    required int bucketS,
    double? pvlt,
    double? ampere,
    int samples = 5,
    String deviceId = 'AA',
  }) async {
    await db.db.insert(Db.tableHistory, <String, Object?>{
      'timestamp': at.millisecondsSinceEpoch,
      'pvlt': pvlt,
      'ampere': ampere,
      'temperature': 25,
      'device_id': deviceId,
      'samples': samples,
      'app_build': '0.7.17+26081400',
      'bucket_s': bucketS,
    });
  }

  /// One legacy minute average, and one later minute stored as 60 seconds.
  Future<void> seedMixed() async {
    await put(at: legacyMinute, bucketS: 60, pvlt: 13.0, ampere: -0.31, samples: 521);
    for (var s = 0; s < 60; s++) {
      await put(
        at: newMinute.add(Duration(seconds: s)),
        bucketS: 1,
        pvlt: 13.0,
        // The case the whole design exists for: a surge inside one minute.
        ampere: s == 30 ? -29.0 : 0.2,
        samples: 5,
      );
    }
  }

  List<List<String>> dataRows(String csv) => csv
      .split(RegExp(r'\r?\n'))
      .where((l) =>
          l.isNotEmpty && !l.startsWith('#') && !l.startsWith('timestamp,'))
      .map((l) => l.split(','))
      .toList();

  int col(String name) => HistoryRepo.csvColumns.indexOf(name);

  group('every row states its own granularity', () {
    test('`bucket_s` is the last column, appended under the standing rule', () {
      expect(HistoryRepo.csvColumns.last, 'bucket_s');
    });

    test('a per-second export reports what each row actually is', () async {
      await seedMixed();
      final out = await history.exportCsv(
          granularity: HistoryGranularity.second, header: const ['t']);
      expect(out.rows, 61, reason: '1 legacy minute row + 60 stored seconds');
      final rows = dataRows(out.text);
      final widths = rows.map((r) => r[col('bucket_s')]).toList();
      expect(widths.where((w) => w == '60'), hasLength(1));
      expect(widths.where((w) => w == '1'), hasLength(60));
    });

    test('a per-minute export says 60 on every row, whatever it was built from',
        () async {
      await seedMixed();
      final out = await history.exportCsv(header: const ['t']);
      expect(out.rows, 2, reason: 'two minutes, one row each');
      for (final r in dataRows(out.text)) {
        expect(r[col('bucket_s')], '60');
      }
    });
  });

  group('a legacy minute row survives a per-second export untouched', () {
    test('it is neither skipped nor expanded into sixty identical seconds',
        () async {
      await seedMixed();
      final rows = dataRows((await history.exportCsv(
              granularity: HistoryGranularity.second, header: const ['t']))
          .text);
      final legacy = rows
          .where((r) => r.first == legacyMinute.toIso8601String())
          .toList();
      expect(legacy, hasLength(1),
          reason: 'skipping it is silent loss; 60 copies is invented data');
      // Its own values, unchanged — including the `samples: 521` that says how
      // much telemetry is behind it.
      expect(legacy.single[col('ampere')], '-0.31');
      expect(legacy.single[col('samples')], '521');
      expect(legacy.single[col('bucket_s')], '60');
    });
  });

  group('the aggregating path is honest about what it wrote', () {
    test('`rows:` equals the rows in the file, and `range:` names them',
        () async {
      await seedMixed();
      final out = await history.exportCsv(header: const ['title']);
      final preamble = out.text
          .split(RegExp(r'\r?\n'))
          .where((l) => l.startsWith('#'))
          .map((l) => l.replaceFirst(RegExp(r'^#\s?'), ''))
          .toList();
      final summary = preamble.firstWhere((l) => l.startsWith('rows: '));
      expect(summary, startsWith('rows: ${out.rows}  range: '));
      // The range names the first and last row IN THE FILE — bucket starts —
      // rather than landing up to 59 s away from them.
      expect(summary, contains(legacyMinute.toIso8601String()));
      expect(summary, contains(newMinute.toIso8601String()));
    });

    test('the minute mean is weighted by `samples`, exactly as the list is',
        () async {
      // Two segments of one minute, 500 snapshots at 13.0 V and 5 at 3.0 V.
      // Unweighted that is 8.0 V — a number matching no physical unit.
      await put(at: newMinute, bucketS: 60, pvlt: 13.0, samples: 500);
      await put(at: newMinute, bucketS: 1, pvlt: 3.0, samples: 5);
      final rows =
          dataRows((await history.exportCsv(header: const ['t'])).text);
      expect(rows, hasLength(1));
      final pvlt = double.parse(rows.single[col('pvlt')]);
      expect(pvlt, closeTo((13.0 * 500 + 3.0 * 5) / 505, 1e-9));
      expect(rows.single[col('samples')], '505');
    });

    test('two units in one minute stay two rows', () async {
      await put(at: newMinute, bucketS: 1, pvlt: 13.6, deviceId: 'AA');
      await put(at: newMinute, bucketS: 1, pvlt: 3.9, deviceId: 'BB');
      final out = await history.exportCsv(header: const ['t']);
      expect(out.rows, 2);
    });
  });

  group('resolution: requested / contains (design 0030 T4d, closed)', () {
    test('a per-second export over mixed data declares both widths', () async {
      await seedMixed();
      final r = ExportResolution.forCsv(
        HistoryGranularity.second,
        await history.distinctBucketWidths(),
      );
      expect(r.lines, <String>[
        'resolution: requested=1s',
        'resolution: contains=1s,60s',
      ]);
    });

    test('an aggregated export contains minutes whatever it was built from',
        () async {
      await seedMixed();
      final r = ExportResolution.forCsv(
        HistoryGranularity.minute,
        await history.distinctBucketWidths(),
      );
      expect(r.lines, <String>[
        'resolution: requested=1min',
        'resolution: contains=1min',
      ]);
    });

    test('a scope with no rows says so, and does not invent a granularity',
        () async {
      final r = ExportResolution.forCsv(
        HistoryGranularity.second,
        await history.distinctBucketWidths(),
      );
      expect(r.lines, <String>['resolution: requested=n/a (no history rows)']);
      // 🔴 One line, not two: there is nothing to describe the contents of. An
      // empty `contains=` would read as a broken field (FB-32's rule).
      expect(r.contains, isNull);
    });

    test('an all-seconds file says so, which is what makes the pair useful',
        () async {
      for (var s = 0; s < 3; s++) {
        await put(at: newMinute.add(Duration(seconds: s)), bucketS: 1, pvlt: 13.0);
      }
      final r = ExportResolution.forCsv(
        HistoryGranularity.second,
        await history.distinctBucketWidths(),
      );
      expect(r.contains, '1s');
    });
  });

  group('the size estimate (T4c / Q4)', () {
    test('counts what each granularity would actually write', () async {
      await seedMixed();
      expect(
          await history.countExportRows(
              granularity: HistoryGranularity.second),
          61);
      expect(
          await history.countExportRows(
              granularity: HistoryGranularity.minute),
          2);
      // The number has to MOVE with the choice, or it is decoration.
      expect(
        await history.countExportRows(granularity: HistoryGranularity.second) >
            await history.countExportRows(
                granularity: HistoryGranularity.minute),
        isTrue,
      );
    });

    test('the estimate is never rendered as 0 MB', () async {
      // 🔴 Q4 condition 3. A field reading `0 MB` looks like a working field
      // that found nothing — worse than no field at all. One row is 134 bytes;
      // it renders as a bound, not as zero.
      expect(formatApproxBytes(kApproxCsvRowBytes), '< 0.1 MB');
      expect(formatApproxBytes(0), '< 0.1 MB');
      // FB-59's measured week: 90,720 rows, and the coefficient reproduces the
      // 11.6 MB that run actually wrote to within rounding.
      expect(formatApproxBytes(90720 * kApproxCsvRowBytes), '12 MB');
      // The 7-day-at-seconds case the copy warns about.
      expect(formatApproxBytes(90720 * 60 * kApproxCsvRowBytes), '729 MB');
    });
  });
}
