// The trend chart's x axis is TIME, and a hole in the recording is drawn as a
// hole — design 0081 S2 (T3/T4/T5/T6).
//
// 🔴 **The defect this closes.** `xAt(i)` used to be `left + plotW * i /
// (n - 1)`: one equal step per point, whatever the clock said. `queryBuckets`
// is a `GROUP BY`, so a bucket with no rows is never emitted at all. Put those
// two together and a unit that rode 07:12–08:05, parked for five and a half
// hours, then rode again 13:40–14:26 drew **the park as one ordinary step**,
// with a straight line across it that no reading supports (design 0081 §1.2).
//
// It was not a cosmetic problem: the line is the only thing on that screen a
// user reads as "what the voltage did", and between those two points it was
// drawing an average of two rides an afternoon apart.
//
// ⚠️ **The gap LABEL ("未連線 5 小時 35 分") is deliberately not here.** Design
// 0081 Q6 ruled 內嵌 B (hatch only) / 橫向 C (hatch + label), and the landscape
// page is S3 — a label with no surface to live on would be untested furniture.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';

void main() {
  const size = Size(320, 160);
  const bucketMs = 60000;
  final t0 = DateTime(2026, 8, 23, 7, 12);

  /// Ten minutes, one bucket each — the shape every existing chart test uses,
  /// and the one that must keep drawing exactly as it did.
  List<HistoryBucket> even() => List<HistoryBucket>.generate(
        10,
        (i) => HistoryBucket(
          at: t0.add(Duration(minutes: i)),
          avgPvlt: 13.0 + i * 0.05,
          minPvlt: 12.9 + i * 0.05,
          maxPvlt: 13.1 + i * 0.05,
          count: 60,
        ),
      );

  /// Five minutes, **three hours of nothing**, five more minutes.
  List<HistoryBucket> withGap() => [
        for (var i = 0; i < 5; i++)
          HistoryBucket(
            at: t0.add(Duration(minutes: i)),
            avgPvlt: 13.0,
            minPvlt: 12.9,
            maxPvlt: 13.1,
            count: 60,
          ),
        for (var i = 0; i < 5; i++)
          HistoryBucket(
            at: t0.add(Duration(hours: 3, minutes: i)),
            avgPvlt: 14.0,
            minPvlt: 13.9,
            maxPvlt: 14.1,
            count: 60,
          ),
      ];

  HistoryChartGeometry geom(List<HistoryBucket> b) => HistoryChartGeometry(
      width: size.width, hasTemp: false, buckets: b, bucketMs: bucketMs);

  _Recording paint(List<HistoryBucket> b) {
    final c = _Recording();
    historyTrendPainterForTest(buckets: b, bucketMs: bucketMs).paint(c, size);
    return c;
  }

  // ==========================================================================
  group('T3 — x is a time, not a position in a list', () {
    test('evenly spaced buckets land exactly where they always did', () {
      // 🔑 The regression guard for design 0076's scrub feel: for the shape
      // every other test uses, time-proportional and index-proportional are
      // the same number. If this ever fails, the refactor moved the points
      // under a gesture that was tuned on them.
      final g = geom(even());
      for (var i = 0; i < 10; i++) {
        expect(g.xAt(i),
            closeTo(HistoryChartGeometry.left + g.plotW * i / 9, 0.001));
      }
    });

    test('a three-hour hole takes three hours of width', () {
      final g = geom(withGap());
      final withinRun = g.xAt(1) - g.xAt(0);
      final acrossGap = g.xAt(5) - g.xAt(4);
      // 176 minutes of hole against 1 minute of step. Under the old mapping
      // these two were IDENTICAL, which is the whole defect in one line.
      expect(acrossGap / withinRun, closeTo(176, 1));
    });

    test('a single bucket is centred, as before', () {
      final g = geom(even().take(1).toList());
      expect(g.xAt(0), closeTo(HistoryChartGeometry.left + g.plotW / 2, 0.001));
    });
  });

  // ==========================================================================
  group('T4 — the line and the band break at the same place', () {
    test('nothing drawn spans the gap', () {
      final g = geom(withGap());
      final gapL = g.xAt(4), gapR = g.xAt(5);
      final rec = paint(withGap());
      final shapes = rec.paths.map((p) => p.$1.getBounds()).toList();
      expect(shapes, isNotEmpty);
      for (final b in shapes) {
        final spans = b.left < gapL - 0.5 && b.right > gapR + 0.5;
        expect(spans, isFalse,
            reason: 'a shape from ${b.left} to ${b.right} crosses the hole '
                '($gapL … $gapR). A band that spans a gap the line breaks at '
                'is worse than the old straight line — it looks like measured '
                'spread over hours nobody measured.');
      }
    });

    test('two runs give two mean strokes, one run gives one', () {
      int strokes(List<HistoryBucket> b) => paint(b)
          .paths
          .where((p) => p.$2.style == PaintingStyle.stroke)
          .length;
      // 🔴 Not `greaterThan(1)`: an off-by-one in the break condition would
      // shatter the line into ten one-point strokes and still "pass" a loose
      // assertion, while looking like a dotted line on screen.
      expect(strokes(even()), 1);
      expect(strokes(withGap()), 2);
    });
  });

  // ==========================================================================
  group('T5 — the hole is hatched, so it reads as deliberate', () {
    // The hatch is the only mark on the chart that says "nothing was recorded
    // here". Without it a break in the line is indistinguishable from a
    // rendering fault.
    int hatchStripes(List<HistoryBucket> b) => paint(b)
        .lines
        .where((l) => (l.$3.color.a - 0.13).abs() < 0.02)
        .length;

    test('a gap gets stripes; an unbroken chart gets none', () {
      expect(hatchStripes(withGap()), greaterThan(3));
      expect(hatchStripes(even()), 0);
    });
  });

  // ==========================================================================
  group('T6 — the finger picks the nearest point IN TIME', () {
    test('evenly spaced: the same point the old arithmetic picked', () {
      final g = geom(even());
      for (var i = 0; i < 10; i++) {
        expect(g.indexAt(g.xAt(i)), i);
      }
    });

    test('over a hole it snaps to the closer side, never to nothing', () {
      // 🔑 design 0076 §3.2 spent its entire ruling on not letting the detail
      // panel blink out mid-scrub. "Finger over a gap ⇒ select nothing" would
      // reintroduce exactly that, three hours wide.
      final g = geom(withGap());
      final gapL = g.xAt(4), gapR = g.xAt(5);
      expect(g.indexAt(gapL + (gapR - gapL) * 0.1), 4);
      expect(g.indexAt(gapR - (gapR - gapL) * 0.1), 5);
      expect(g.indexAt((gapL + gapR) / 2), anyOf(4, 5));
    });

    test('past either edge holds the end point', () {
      final g = geom(withGap());
      expect(g.indexAt(-40), 0);
      expect(g.indexAt(size.width + 40), 9);
    });

    test('fewer than two buckets is not hittable', () {
      expect(geom(const []).indexAt(10), isNull);
      expect(geom(even().take(1).toList()).indexAt(10), isNull);
    });
  });
}

/// A [Canvas] that keeps what it was asked to draw — the same recorder
/// `history_chart_aggregation_test.dart` uses, for the same reason: the chart
/// is a bare `CustomPainter` with no chart dependency, so draw calls are the
/// only observable.
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
