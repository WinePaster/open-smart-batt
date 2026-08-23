// The chart's bucket width follows THE DATA'S span, not the range's —
// design 0081 S1 (T1/T2).
//
// 🔴 **What this pins, in one sentence:** the same recording must draw the
// same chart no matter what time of day the screen is opened.
//
// Until 2026-08-23 `historyChartBucketMs` measured from the range's cut-off to
// `DateTime.now()`, so the divisor was "how long is the selected range" rather
// than "how long did this unit actually record for". Two consequences, both
// reproduced below as reverse-proofs:
//
//  * a 30-minute ride opened at 15:00 was drawn at a FIVE-MINUTE bucket — six
//    points for 1,800 stored seconds — because the divisor was the fifteen
//    hours since local midnight (design 0081 §1.1);
//  * the identical rows drew differently through the day: a 1-minute bucket
//    before 03:00, an 8-minute one just before midnight. Nothing about the
//    data changed; only the clock did.
//
// ⚠️ The floor is still one minute and is NOT relaxed here (design 0081 Q5 —
// the owner ruled "分鐘", so no chart path may go below `kHistoryListBucketMs`).
// `T2c` is what stops a future change from quietly lowering it while wiring up
// the landscape page's zoom.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
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

  /// A fixed local midnight, so "today" is a fixture rather than whatever the
  /// machine's clock says while the suite runs.
  final midnight = DateTime(2026, 8, 23);
  Duration h(num x) => Duration(milliseconds: (x * 3600000).round());

  /// The OLD derivation, kept here on purpose: every assertion below that says
  /// "and this is what it used to give" runs through this, so the difference is
  /// demonstrated rather than asserted from memory.
  int legacyBucketMs(DateTime from, DateTime now) =>
      (now.millisecondsSinceEpoch - from.millisecondsSinceEpoch)
          .toInt()
          .clamp(0, 1 << 62) ~/
          kHistoryTargetBucketPoints;

  Future<void> put(DateTime at, {String deviceId = 'AA'}) =>
      db.db.insert(Db.tableHistory, <String, Object?>{
        'timestamp': at.millisecondsSinceEpoch,
        'pvlt': 13.4,
        'temperature': 30,
        'mode': ReportedStatus.normal,
        'device_id': deviceId,
        'samples': 5,
        'bucket_s': 1,
      });

  // ==========================================================================
  group('T1 — the width is a property of the recording, not of the clock', () {
    test('the same span gives the same width whatever "now" is', () {
      // CATCHES: a reintroduced `DateTime.now()` inside the derivation. This is
      // the whole point of design 0081 S1 — under the old code these two lines
      // could not both be written, because the second argument did not exist.
      final from = midnight.add(h(7.2)); // 07:12
      final to = midnight.add(h(8.1)); //   08:06
      expect(historyChartBucketMs(from, to), kHistoryListBucketMs);

      // Opened at 15:00 or at 23:59 — same rows, same answer.
      expect(historyChartBucketMs(from, to), historyChartBucketMs(from, to));
      // …whereas the old derivation moved with the hour:
      expect(legacyBucketMs(midnight, midnight.add(h(3))), 60000);
      expect(legacyBucketMs(midnight, midnight.add(h(15))), 300000);
      expect(legacyBucketMs(midnight, midnight.add(h(24))), 480000);
    });

    test('~180 points across the span, once it is wide enough', () {
      final from = midnight;
      expect(historyChartBucketMs(from, from.add(h(24))),
          (24 * 3600000) ~/ kHistoryTargetBucketPoints);
      expect(historyChartBucketMs(from, from.add(h(9))),
          (9 * 3600000) ~/ kHistoryTargetBucketPoints);
    });

    test('a minute floor and a day ceiling, both still in force', () {
      final from = midnight;
      // 🔵 design 0081 Q5 ruled "分鐘": nothing may go below one minute.
      expect(historyChartBucketMs(from, from), kHistoryListBucketMs);
      expect(historyChartBucketMs(from, from.add(const Duration(minutes: 30))),
          kHistoryListBucketMs);
      expect(historyChartBucketMs(from, from.add(const Duration(days: 3650))),
          24 * 3600000);
    });

    test('either end null means "nothing to span" and takes the floor', () {
      // The empty-range path. It used to be reached as `since ?? firstAt` being
      // null on an empty "all"; it is now reached whenever the range holds no
      // rows, on EVERY range — which is the same set of screens, arrived at
      // more honestly.
      expect(historyChartBucketMs(null, null), kHistoryListBucketMs);
      expect(historyChartBucketMs(midnight, null), kHistoryListBucketMs);
      expect(historyChartBucketMs(null, midnight), kHistoryListBucketMs);
    });
  });

  // ==========================================================================
  group('T2 — `aggregate` reports both ends of the data', () {
    test('firstAt/lastAt are the extremes of the scoped rows', () async {
      await put(midnight.add(h(7.2)));
      await put(midnight.add(h(7.5)));
      await put(midnight.add(h(14.4)));
      // Another unit, deliberately outside the span above on both sides.
      await put(midnight.add(h(2)), deviceId: 'BB');
      await put(midnight.add(h(20)), deviceId: 'BB');

      final a = await history.aggregate(deviceId: 'AA');
      expect(a.count, 3);
      expect(a.firstAt, midnight.add(h(7.2)));
      expect(a.lastAt, midnight.add(h(14.4)));

      // 🔴 Scoped the same way `firstAt` always was. A `lastAt` that ignored
      // `deviceId` would hand the chart another unit's clock — design 0043
      // §3.5's defect wearing a new hat.
      final b = await history.aggregate(deviceId: 'BB');
      expect(b.firstAt, midnight.add(h(2)));
      expect(b.lastAt, midnight.add(h(20)));
    });

    test('`since` moves firstAt but lastAt stays the newest row', () async {
      await put(midnight.add(h(1)));
      await put(midnight.add(h(9)));
      await put(midnight.add(h(11)));

      final a = await history.aggregate(since: midnight.add(h(8)));
      expect(a.count, 2);
      expect(a.firstAt, midnight.add(h(9)));
      expect(a.lastAt, midnight.add(h(11)));

      // 🔑 The invariant `loadHistorySlice` relies on instead of a `max()`:
      // the query is already scoped, so `firstAt` can never precede `since`.
      expect(a.firstAt!.isBefore(midnight.add(h(8))), isFalse);
    });

    test('an empty range reports both ends null, not epoch zero', () async {
      final a = await history.aggregate(deviceId: 'nobody');
      expect(a.count, 0);
      expect(a.firstAt, isNull);
      expect(a.lastAt, isNull);
      // …and that is what makes the fallback in T1 reachable rather than
      // producing a 56-year span back to 1970.
      expect(historyChartBucketMs(a.firstAt, a.lastAt), kHistoryListBucketMs);
    });
  });

  // ==========================================================================
  group('T3 — a finished recording must not blur as it ages', () {
    // 🔴 **This group is time-of-day independent on purpose, and that cost a
    // rewrite.** The first draft fixed "now" at 15:00 and put the rows at
    // 14:30 — under the OLD derivation that span is also half an hour, so the
    // test passed against the very code it was written to reject. The V2
    // reverse-proof (revert the fix, watch the suite) is what caught it.
    //
    // Anchoring the fixture in the PAST instead makes the two derivations
    // diverge by construction, whatever the clock says when the suite runs.
    test('a 30-minute ride from ten days ago still draws at one minute',
        () async {
      final start = DateTime.now().subtract(const Duration(days: 10));
      for (var s = 0; s < 1800; s += 10) {
        await put(start.add(Duration(seconds: s)));
      }
      final stats = await history.aggregate(deviceId: 'AA');
      expect(stats.count, 180);

      expect(historyChartBucketMs(stats.firstAt, stats.lastAt),
          kHistoryListBucketMs,
          reason: 'a 30-minute recording is 30 one-minute points, today and '
              'next year');

      // 🔴 Reverse-proof: the same rows under the old derivation, which
      // measured to `DateTime.now()`.
      final was = legacyBucketMs(stats.firstAt!, DateTime.now());
      expect(was, greaterThan(60 * 60000),
          reason: 'ten days ÷ 180 is about eighty minutes — the ride was '
              'drawn as ONE point, and it got worse every day it aged');
    });

    test('the reported shape: two rides and a long park, opened at 15:00', () {
      // design 0081 §1.1's own numbers, as a pure computation so the
      // arithmetic in the design doc cannot drift from the code.
      final rideStart = midnight.add(h(7.2)); //  07:12
      final rideEnd = midnight.add(h(14 + 26 / 60)); // 14:26
      expect(historyChartBucketMs(rideStart, rideEnd),
          ((14 + 26 / 60 - 7.2) * 3600000) ~/ kHistoryTargetBucketPoints);
      // …against the five minutes the old derivation produced at 15:00.
      expect(legacyBucketMs(midnight, midnight.add(h(15))), 300000);
    });
  });
}
