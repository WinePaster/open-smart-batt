// The export gains an upper bound — design 0083 S4 (T12/T13).
//
// 🔴 **What this pins, in one sentence:** everything the CSV says about itself
// is scoped to the same window as the rows inside it.
//
// The export button sits next to the range picker, and until 2026-08-23 it
// asked the database five separate questions with only a lower bound: the rows,
// the row count, the two omission counts in the header, and the granularities
// behind `resolution: contains=`. On the three presets that was harmless —
// every one of them runs to now, so there was no far end to miss. A custom
// range has one, and any of those five left unbounded puts a sentence in the
// preamble that the rows below it contradict.
//
// That is worse than an ordinary bug, because the file OUTLIVES the app: a CSV
// is what gets sent to whoever is diagnosing something, months later, with no
// way to re-run the query and check.
//
// ⚠️ Design §3.4's table listed four of the five. `distinctBucketWidths` was
// found while wiring it and added on the same argument — T12d is its test.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
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

  // The window under test: 2026-08-01 .. 2026-08-16 exclusive, i.e. what
  // `historyCustomRange(Aug 1, Aug 15)` produces.
  final from = DateTime(2026, 8, 1);
  final to = DateTime(2026, 8, 16);

  Future<void> put(
    DateTime at, {
    String? deviceId = 'AA',
    int bucketS = 1,
    double pvlt = 13.4,
  }) =>
      db.db.insert(Db.tableHistory, <String, Object?>{
        'timestamp': at.millisecondsSinceEpoch,
        'pvlt': pvlt,
        'temperature': 25,
        'device_id': deviceId,
        'samples': 1,
        'bucket_s': bucketS,
      });

  /// Three rows inside the window, and one on each side of it.
  Future<void> seed() async {
    await put(DateTime(2026, 7, 31, 23, 59, 59)); // just before
    await put(DateTime(2026, 8, 2, 10, 0));
    await put(DateTime(2026, 8, 9, 10, 0));
    await put(DateTime(2026, 8, 15, 23, 59, 59)); // the last second, INSIDE
    await put(DateTime(2026, 8, 16, 0, 0, 0)); // exactly `until`, outside
    await put(DateTime(2026, 8, 20, 10, 0)); // well after
  }

  List<String> dataRows(String csv) => csv
      .split('\n')
      .where((l) => l.isNotEmpty && !l.startsWith('#') && !l.startsWith('time'))
      .toList();

  // ==========================================================================
  group('T12 — the file, and everything it says about itself', () {
    test('T12a: no row reaches `until`, and the boundary is half-open',
        () async {
      // CATCHES: a closed upper bound, and an upper bound applied to the count
      // but not to the rows. The 23:59:59 row must be IN; the midnight row that
      // IS `until` must be OUT.
      await seed();
      final out = await history.exportCsv(
          since: from, until: to, granularity: HistoryGranularity.second);
      expect(out.rows, 3);
      final rows = dataRows(out.text);
      expect(rows.length, 3);
      // Newest first, as every export path here orders.
      expect(rows.first, contains('2026-08-15T23:59:59'));
      expect(rows.last, contains('2026-08-02'));
      expect(out.text, isNot(contains('2026-08-16')));
      expect(out.text, isNot(contains('2026-07-31')));
      expect(out.text, isNot(contains('2026-08-20')));
    });

    test('T12b: the two omission counts move with the window', () async {
      // CATCHES: a header line describing rows the file was never going to
      // contain. A reader seeing "12,400 recorded before the unit was
      // identified" against a two-week export cannot tell which number is wrong.
      await put(DateTime(2026, 8, 2, 10, 0)); // AA, inside
      await put(DateTime(2026, 8, 5, 10, 0), deviceId: null); // unattributed, inside
      await put(DateTime(2026, 8, 20, 10, 0), deviceId: null); // unattributed, OUTSIDE
      await put(DateTime(2026, 8, 6, 10, 0), deviceId: 'BB'); // other unit, inside
      await put(DateTime(2026, 8, 21, 10, 0), deviceId: 'BB'); // other unit, OUTSIDE

      expect(await history.countUnattributed(since: from, until: to), 1);
      expect(await history.countOtherDevices('AA', since: from, until: to), 1);

      // …and unbounded they are the pre-0083 answers, so this is a bound being
      // applied rather than a fixture that happens to agree.
      expect(await history.countUnattributed(since: from), 2);
      expect(await history.countOtherDevices('AA', since: from), 2);
    });

    test('T12c: those counts reach the preamble of a per-device export',
        () async {
      await put(DateTime(2026, 8, 2, 10, 0));
      await put(DateTime(2026, 8, 5, 10, 0), deviceId: null);
      await put(DateTime(2026, 8, 20, 10, 0), deviceId: null);

      final out = await history.exportCsv(
          since: from,
          until: to,
          deviceId: 'AA',
          // The summary lines are emitted only under a preamble — an export
          // with no header block has nothing to attach them to.
          header: const ['OpenSmartBatt history export'],
          granularity: HistoryGranularity.second);
      // One inside, not the two the whole table holds.
      expect(out.text, contains('# excluded: 1 unattributed rows'));

      final unbounded = await history.exportCsv(
          since: from,
          deviceId: 'AA',
          header: const ['OpenSmartBatt history export'],
          granularity: HistoryGranularity.second);
      expect(unbounded.text, contains('# excluded: 2 unattributed rows'));
    });

    test('T12d: `resolution: contains=` describes the window, not the table',
        () async {
      // Not in design §3.4's list — found while wiring S4. A granularity that
      // exists only outside the window would be announced in a file that has
      // none of it.
      await put(DateTime(2026, 8, 2, 10, 0), bucketS: 1);
      await put(DateTime(2026, 8, 20, 10, 0), bucketS: 60); // outside

      expect(await history.distinctBucketWidths(since: from, until: to), [1]);
      expect(await history.distinctBucketWidths(since: from), [1, 60]);
    });

    test('T12e: `until: null` is the old behaviour, byte for byte', () async {
      // The three presets all pass null, so "unchanged" can only be shown as
      // "identical to the query that had no upper bound at all".
      await seed();
      final bounded = await history.exportCsv(
          since: from, until: null, granularity: HistoryGranularity.second);
      final legacy = await history.exportCsv(
          since: from, granularity: HistoryGranularity.second);
      expect(bounded.rows, legacy.rows);
      expect(dataRows(bounded.text), dataRows(legacy.text));
      expect(bounded.rows, 5);
    });

    test('T12f: the bound composes with the minute granularity too', () async {
      // The per-minute path groups before it counts, so it is a different query
      // and needs its own assertion.
      await seed();
      final out = await history.exportCsv(
          since: from, until: to, granularity: HistoryGranularity.minute);
      expect(out.rows, 3);
      expect(out.text, isNot(contains('2026-08-20')));
    });
  });

  // ==========================================================================
  group('T13 — the size estimate is scoped like the export', () {
    test('T13a: bounded estimates are smaller, and equal the row count',
        () async {
      // CATCHES: an estimate computed over a wider scope than the file. It is
      // shown BEFORE the user commits, so overstating it is at its most
      // expensive exactly when they are deciding whether to proceed.
      await seed();
      for (final g in HistoryGranularity.values) {
        final bounded = await history.countExportRows(
            since: from, until: to, granularity: g);
        final unbounded =
            await history.countExportRows(since: from, granularity: g);
        expect(bounded, lessThan(unbounded), reason: '$g');

        final written = await history.exportCsv(
            since: from, until: to, granularity: g);
        expect(bounded, written.rows,
            reason: '$g: the estimate must count what the export writes');
      }
    });

    test('T13b: `until: null` leaves the estimate exactly as it was', () async {
      await seed();
      for (final g in HistoryGranularity.values) {
        expect(
            await history.countExportRows(
                since: from, until: null, granularity: g),
            await history.countExportRows(since: from, granularity: g),
            reason: '$g');
      }
    });
  });
}
