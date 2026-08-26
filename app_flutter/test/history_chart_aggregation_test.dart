// FB-74 — the CHART half of the defect `history_list_aggregation_test.dart`
// pins for the list.
//
// 🔴 The failure guarded here: the trend chart draws one point per bucket, a
// bucket is 1 minute to 24 hours wide, and the point is the bucket's MEAN. One
// second at 15.5 V inside a one-hour bucket moves that mean by about four
// millivolts — so on the line alone, an over-voltage event and a completely
// ordinary hour are the same picture. The user paid 60× the storage (design
// 0061) for exactly that second, and the read path was averaging it back out of
// existence, with a `CustomPainter` that looked entirely ordinary while doing
// it. The stats strip directly below the chart reports the range-wide raw MAX,
// so the screen was also putting a number on display (15.5 V) that the picture
// above it contradicted, with no way to locate it in time.
//
// Three rules, one per group below:
//
//  1. `queryBuckets` means are `samples`-WEIGHTED, like the list's. The chart
//     used a bare `AVG(col)`, which is the construction `HistoryRepo._wavg`
//     exists to forbid and which the corpus has measured wrong four times.
//  2. The axis window is scaled over the buckets' MIN/MAX, never their means —
//     an averaged axis clips the band off the top of the plot, silently.
//  3. The min–max band is actually painted, and actually reaches above the
//     mean line.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
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

  // UTC fixtures; every query pins `tzOffsetMs`, so the machine's zone is out
  // of it.
  final minute = DateTime.utc(2026, 8, 14, 9, 50);

  Future<void> put({
    required DateTime at,
    required int bucketS,
    double? pvlt,
    int? temperature,
    double? ampere,
    int samples = 5,
    String deviceId = 'AA',
  }) async {
    await db.db.insert(Db.tableHistory, <String, Object?>{
      'timestamp': at.millisecondsSinceEpoch,
      'pvlt': pvlt,
      'temperature': temperature,
      'ampere': ampere,
      'device_id': deviceId,
      'samples': samples,
      'bucket_s': bucketS,
    });
  }

  group('queryBuckets — what the chart is given', () {
    test('a one-second spike reaches the chart as maxPvlt, not as the mean',
        () async {
      for (var s = 0; s < 60; s++) {
        await put(
          at: minute.add(Duration(seconds: s)),
          bucketS: 1,
          pvlt: s == 37 ? 15.5 : 13.2,
          temperature: s == 37 ? 61 : 28,
        );
      }

      final b = (await history.queryBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;

      // The mean is unremarkable — this is the number the LINE draws, and it
      // crosses no threshold anyone would set.
      expect(b.avgPvlt, closeTo(13.238, 1e-3));
      expect(b.avgPvlt! > 15.0, isFalse);

      // The extremes are what carry the event onto the screen.
      expect(b.maxPvlt, 15.5);
      expect(b.minPvlt, 13.2);
      expect(b.maxTemp, 61);
      expect(b.minTemp, 28);
      expect(b.count, 60);
    });

    test('the means are weighted by `samples`, exactly as the list\'s are',
        () async {
      // One minute stored as two segments with wildly different sample counts —
      // design 0048 G2 leaves old segments alone, and `conventions.md` records
      // real minutes split 405 / 69 / 3 / 56. The unweighted mean of these two
      // is 13.00 V; the honest, `samples`-weighted mean is 12.60 V.
      await put(at: minute, bucketS: 60, pvlt: 12.5, samples: 400);
      await put(
          at: minute.add(const Duration(seconds: 30)),
          bucketS: 60,
          pvlt: 14.5,
          samples: 100);

      final b = (await history.queryBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;

      expect(b.avgPvlt, closeTo(12.9, 1e-9),
          reason: '(12.5*400 + 14.5*100) / 500 — NOT the unweighted 13.5');
      expect(b.avgPvlt, isNot(closeTo(13.5, 1e-6)),
          reason: 'a bare AVG(pvlt) would land here');
    });

    test('the chart mean agrees with the list mean for the same minute',
        () async {
      // The two aggregations sit one above the other on the same screen. Before
      // FB-74 they could report different numbers for the same minute, and
      // nothing on screen said which was right.
      await put(at: minute, bucketS: 60, pvlt: 12.5, samples: 400);
      await put(
          at: minute.add(const Duration(seconds: 30)),
          bucketS: 60,
          pvlt: 14.5,
          samples: 100);

      final chart = (await history.queryBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;
      final list = (await history.queryListBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;
      expect(chart.avgPvlt, closeTo(list.sample.pvlt!, 1e-9));
    });
  });

  // ---- current (design 0085 S1, FB-101) --------------------------------
  //
  // 🔴 Why current gets its own group when pvlt and temperature share one: it
  // is the only quantity in the corpus whose SIGN flips between the weighted
  // and the unweighted mean, and the sign is the whole reading — it is the
  // difference between "this battery is charging" and "this battery is
  // draining". A bare `AVG(ampere)` throws nothing, blanks nothing and draws a
  // perfectly smooth line pointing the wrong way.
  group('queryBuckets — the current series', () {
    test('the ampere mean is `samples`-weighted, sign and all', () async {
      // 🔴 THE reason design 0085 S1 exists. This is the real `19:26:00` minute
      // from `feedback_log/2026.08.07/007`, transcribed from
      // `docs/feedback-analysis/2026.08.07-007.md` §N5 — a single battery, one
      // minute, stored as FOUR rows because a disconnect + reconnect
      // (session 56→57→58) flushed the bucket three extra times. The sample
      // counts are 405 / 69 / 3 / 56, so the four rows are nothing like four
      // equal observations:
      //
      //   weighted   (405·−1.699 + 69·2.839 + 3·4.000 + 56·2.071) / 533
      //              = −0.68 A  ⇒ DISCHARGING   ← the truth
      //   unweighted (−1.699 + 2.839 + 4.000 + 2.071) / 4
      //              = +1.80 A  ⇒ CHARGING      ← what a bare AVG() answers
      //
      // Four separate log batches have each re-discovered this independently
      // (08.01/017, 08.04/004, 08.08/001, 08.07/007), which is why
      // `HistoryRepo._wavg` exists and why it is not optional here.
      //
      // ⚠️ design 0085 §1.7 prints these two columns THE OTHER WAY ROUND
      // (weighted +1.80, unweighted −0.68). The doc's own source —
      // `docs/feedback-index/conventions/stats-and-evt.md:63`, the analysis it
      // cites, and the `_wavg` doc comment ("the unweighted mean ... comes out
      // with THE WRONG SIGN") — all agree with the arithmetic above. This test
      // pins the arithmetic.
      const amps = <double>[-1.699, 2.839, 4.000, 2.071];
      const counts = <int>[405, 69, 3, 56];
      for (var i = 0; i < amps.length; i++) {
        await put(
          at: minute.add(Duration(seconds: i * 15)),
          bucketS: 60,
          pvlt: 13.2,
          ampere: amps[i],
          samples: counts[i],
        );
      }

      final b = (await history.queryBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;

      expect(b.avgAmpere, isNotNull);
      expect(b.avgAmpere, closeTo(-0.6834, 1e-3),
          reason: 'the `samples`-weighted mean of the real 19:26 minute');
      expect(b.avgAmpere, lessThan(0),
          reason: 'the sign IS the reading — this minute was discharging, and '
              'a chart drawn from the unweighted mean would show it charging');
      expect(b.avgAmpere, isNot(closeTo(1.8028, 1e-2)),
          reason: 'a bare AVG(ampere) would land here, on the wrong side of 0');
    });

    test('the ampere extremes are the raw readings, never weighted', () async {
      // Same construction as the mean test, but the interesting rows are the
      // ones with almost no weight: a 1-sample row at +9.0 A is a reading that
      // HAPPENED, and MIN/MAX must report it at full height even though it
      // contributes ~0.2 % of the mean. Weighting an extreme by how many
      // snapshots the row folded would be meaningless — the same rule pvlt and
      // temperature already follow.
      await put(
          at: minute, bucketS: 60, pvlt: 13.2, ampere: -0.5, samples: 500);
      await put(
          at: minute.add(const Duration(seconds: 20)),
          bucketS: 60,
          pvlt: 13.2,
          ampere: 9.0,
          samples: 1);
      await put(
          at: minute.add(const Duration(seconds: 40)),
          bucketS: 60,
          pvlt: 13.2,
          ampere: -7.0,
          samples: 1);

      final b = (await history.queryBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;

      expect(b.maxAmpere, 9.0);
      expect(b.minAmpere, -7.0);
      // The mean sits nowhere near either extreme — that gap is exactly what
      // the min–max band is for (design 0085 §3.3).
      expect(b.avgAmpere, closeTo((-0.5 * 500 + 9.0 - 7.0) / 502, 1e-9));
      expect(b.avgAmpere!, greaterThan(b.minAmpere!));
      expect(b.avgAmpere!, lessThan(b.maxAmpere!));
    });

    test('a bucket whose rows never read the current reports null, not 0.0',
        () async {
      // Rows written before the register was read — or a class that does not
      // report it — must arrive as ABSENT, so the chart breaks the line. 0.0 A
      // is a legitimate reading ("idle"), so collapsing null into it would
      // invent a flat run at exactly the value a user reads as "nothing is
      // happening". Matches `_wavg`: a NULL contributes no weight, and a bucket
      // with no weight at all divides by NULLIF(0) → NULL.
      await put(at: minute, bucketS: 60, pvlt: 13.2, temperature: 28);
      await put(
          at: minute.add(const Duration(seconds: 30)),
          bucketS: 60,
          pvlt: 13.4,
          temperature: 29);

      final b = (await history.queryBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;

      expect(b.avgAmpere, isNull);
      expect(b.minAmpere, isNull);
      expect(b.maxAmpere, isNull);
      // ...and the rest of the bucket is untouched by the absence.
      expect(b.avgPvlt, closeTo(13.3, 1e-9));
      expect(b.count, 2);
    });

    test('a NULL ampere row does not dilute the rows that did read it',
        () async {
      // The half-covered bucket: one row read the register, one did not. The
      // mean must be the reading, not the reading halved.
      await put(
          at: minute, bucketS: 60, pvlt: 13.2, ampere: -4.0, samples: 100);
      await put(
          at: minute.add(const Duration(seconds: 30)),
          bucketS: 60,
          pvlt: 13.2,
          samples: 100);

      final b = (await history.queryBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;

      expect(b.avgAmpere, closeTo(-4.0, 1e-9),
          reason: 'the NULL row carries no weight — halving this to -2.0 A '
              'would be an invented reading');
      expect(b.minAmpere, -4.0);
      expect(b.maxAmpere, -4.0);
    });

    test('adding the current series leaves pvlt and temperature exactly as '
        'they were', () async {
      // Regression for the SELECT edit itself. Same two-segment minute as the
      // weighting test above, now with current alongside: the voltage and
      // temperature answers must be bit-for-bit the ones FB-74 pinned, and the
      // chart must still agree with the list for the same minute
      // (design 0065 §6 R5).
      await put(
          at: minute,
          bucketS: 60,
          pvlt: 12.5,
          temperature: 20,
          ampere: -3.0,
          samples: 400);
      await put(
          at: minute.add(const Duration(seconds: 30)),
          bucketS: 60,
          pvlt: 14.5,
          temperature: 40,
          ampere: 5.0,
          samples: 100);

      final b = (await history.queryBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;

      expect(b.avgPvlt, closeTo(12.9, 1e-9));
      expect(b.minPvlt, 12.5);
      expect(b.maxPvlt, 14.5);
      expect(b.avgTemp, closeTo(24.0, 1e-9));
      expect(b.minTemp, 20);
      expect(b.maxTemp, 40);
      expect(b.count, 2);

      // And the new column agrees with the list's, which has had a weighted
      // `avgAmpere` since design 0061 T3a — two read paths, one minute, one
      // number.
      final list = (await history.queryListBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;
      expect(b.avgAmpere, closeTo(-1.4, 1e-9));
      expect(b.avgAmpere, closeTo(list.sample.current!, 1e-9));
    });
  });

  // ---- the axis --------------------------------------------------------

  /// A flat run of ordinary buckets with ONE bucket holding a spike. Every
  /// bucket's MEAN is identical, so anything scaled from the means alone cannot
  /// tell this apart from an entirely uneventful hour.
  List<HistoryBucket> spikeRun({
    double calm = 13.2,
    double spike = 15.5,
    int at = 3,
    int n = 8,
  }) =>
      [
        for (var i = 0; i < n; i++)
          HistoryBucket(
            at: minute.add(Duration(minutes: i)),
            avgPvlt: calm,
            minPvlt: calm,
            maxPvlt: i == at ? spike : calm,
            avgTemp: 28,
            minTemp: 28,
            maxTemp: i == at ? 61 : 28,
            count: 60,
          ),
      ];

  group('the axis window is scaled over the extremes', () {
    test('the voltage axis reaches the spike, not just the means', () {
      final r = historyChartVoltageRange(spikeRun());
      expect(r.hi, greaterThanOrEqualTo(15.5),
          reason: 'an axis scaled from the means tops out near 13.4 V and '
              'clips the band off the top of the plot');
      expect(r.lo, lessThanOrEqualTo(13.2));
    });

    test('the temperature axis does the same', () {
      final r = historyChartTempRange(spikeRun(), TempUnit.celsius);
      expect(r.hi, greaterThanOrEqualTo(61));
      expect(r.lo, lessThanOrEqualTo(28));
    });

    test('a chart with no data at all keeps its old placeholder window', () {
      // Guards the fallback: no buckets must not become a degenerate axis.
      final r = historyChartVoltageRange(const []);
      expect(r.lo, -0.2);
      expect(r.hi, 1.2);
      final t = historyChartTempRange(const [], TempUnit.celsius);
      expect(t.lo, -1);
      expect(t.hi, 2);
    });
  });

  // ---- the paint -------------------------------------------------------

  group('the min-max band is on the canvas', () {
    const size = Size(320, 160);

    _Recording paint(List<HistoryBucket> buckets, {bool hasTemp = false}) {
      final c = _Recording();
      historyTrendPainterForTest(buckets: buckets, hasTemp: hasTemp)
          .paint(c, size);
      return c;
    }

    test('a spike is drawn well above the mean line', () {
      final rec = paint(spikeRun());

      final fills = rec.paths
          .where((p) => p.$2.style == PaintingStyle.fill)
          .toList(growable: false);
      expect(fills, isNotEmpty,
          reason: 'no filled band means the spike is nowhere on the chart');

      final strokes = rec.paths
          .where((p) => p.$2.style == PaintingStyle.stroke)
          .toList(growable: false);
      expect(strokes, isNotEmpty, reason: 'the mean polyline should still draw');

      final bandTop =
          fills.map((p) => p.$1.getBounds().top).reduce((a, b) => a < b ? a : b);
      final lineTop = strokes
          .map((p) => p.$1.getBounds().top)
          .reduce((a, b) => a < b ? a : b);

      // Canvas y grows downward, so "higher on the chart" is a SMALLER y. The
      // band must reach visibly above the flat mean line — that gap IS the
      // spike being visible.
      expect(bandTop, lessThan(lineTop - 20),
          reason: 'the band must reach above the mean line by more than a '
              'stroke width, or the event is invisible');

      // And it must stay inside the plot: an axis scaled from the means would
      // put the band's top above the top padding, i.e. clipped away.
      expect(bandTop, greaterThanOrEqualTo(0.0));
    });

    test('a flat run draws a band with no bulge', () {
      final rec = paint([
        for (var i = 0; i < 6; i++)
          HistoryBucket(
            at: minute.add(Duration(minutes: i)),
            avgPvlt: 13.2,
            minPvlt: 13.2,
            maxPvlt: 13.2,
            count: 60,
          ),
      ]);
      final fills =
          rec.paths.where((p) => p.$2.style == PaintingStyle.fill).toList();
      expect(fills, isNotEmpty);
      expect(fills.first.$1.getBounds().height, closeTo(0, 0.5),
          reason: 'min == max everywhere, so the band is a flat ribbon');
    });

    test('the band breaks across a gap instead of spanning it', () {
      final b = spikeRun(n: 6).toList();
      // Bucket 2 has no voltage at all — a disconnect. The band must not draw
      // a shape straight through it.
      b[2] = HistoryBucket(at: b[2].at, count: 0);
      final rec = paint(b);
      final fills =
          rec.paths.where((p) => p.$2.style == PaintingStyle.fill).toList();
      expect(fills.length, 2,
          reason: 'one run before the gap, one after — never one path across');
    });

    test('a lone bucket after a gap is stroked as a whisker, not dropped', () {
      // A single bucket surrounded by nulls has no horizontal width, so a
      // filled path would have zero area and its spike would be the one thing
      // on the chart nobody could see.
      final b = <HistoryBucket>[
        HistoryBucket(at: minute, count: 0),
        HistoryBucket(
          at: minute.add(const Duration(minutes: 1)),
          avgPvlt: 13.2,
          minPvlt: 13.2,
          maxPvlt: 15.5,
          count: 60,
        ),
        HistoryBucket(at: minute.add(const Duration(minutes: 2)), count: 0),
        HistoryBucket(
          at: minute.add(const Duration(minutes: 3)),
          avgPvlt: 13.2,
          minPvlt: 13.2,
          maxPvlt: 13.2,
          count: 60,
        ),
      ];
      final rec = paint(b);
      final tall = rec.lines.where((l) => (l.$1.dy - l.$2.dy).abs() > 20);
      expect(tall, isNotEmpty,
          reason: 'the isolated spike bucket must leave a vertical whisker');
    });

    test('temperature gets a band too when the chart has temperature', () {
      final withTemp = paint(spikeRun(), hasTemp: true);
      final withoutTemp = paint(spikeRun());
      final fillsWith =
          withTemp.paths.where((p) => p.$2.style == PaintingStyle.fill).length;
      final fillsWithout = withoutTemp.paths
          .where((p) => p.$2.style == PaintingStyle.fill)
          .length;
      expect(fillsWith, greaterThan(fillsWithout),
          reason: 'the temperature band is an extra filled path');
    });
  });
}

/// A [Canvas] that keeps what it was asked to draw.
///
/// The chart is a bare `CustomPainter` with no chart dependency, so the only
/// way to assert that a spike reaches the screen is to look at the draw calls.
/// Everything not overridden (text, clips, transforms) is swallowed by
/// [noSuchMethod] — this records shapes, not a rendering.
class _Recording implements Canvas {
  final List<(Path, Paint)> paths = <(Path, Paint)>[];
  final List<(Offset, Offset, Paint)> lines = <(Offset, Offset, Paint)>[];

  @override
  void drawPath(Path path, Paint paint) => paths.add((path, paint));

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      lines.add((p1, p2, paint));

  @override
  void drawCircle(Offset c, double radius, Paint paint) {}

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
