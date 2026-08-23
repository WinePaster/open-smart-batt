// The landscape chart's pan/zoom arithmetic and its two floors —
// design 0081 S3 (T8/T9), plus the gap label's auto-retreat (§3.2.3).
//
// 🔑 **Why the maths is a plain value with a pure transform.** Pan and zoom are
// the two things on that page a user can get wrong in a way that is hard to
// report ("it jumped", "it will not go back"), and a widget test that has to
// synthesise two-finger pointer streams ends up testing the gesture recogniser
// as much as the arithmetic. `HistoryChartWindow` is reachable from a bare
// `test()`, so the rules below are pinned at the level they were decided at.
//
// The two clamps are NOT interchangeable and each has its own group:
//
//  * **Q5a — 30 minutes.** The bucket floor is one minute (Q5 ruled 分鐘), so a
//    narrower window is the same points spread further apart: an 8-minute
//    window is eight dots on a 780 px screen, which is less legible than the
//    30-minute one it came from. The zoom stops where detail stops.
//  * **the data's own range.** The chart must not be draggable into an empty
//    century — but a window WIDER than the data has to stay legal, or "zoom
//    all the way back out" fails at its last step.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';

void main() {
  final dataFrom = DateTime(2026, 8, 23, 6);
  final dataTo = DateTime(2026, 8, 23, 18); // 12 hours of recording
  HistoryChartWindow full() => HistoryChartWindow(dataFrom, dataTo);

  HistoryChartWindow apply(HistoryChartWindow start,
          {double scale = 1, double from = 0.5, double to = 0.5}) =>
      HistoryChartWindow.apply(
        start: start,
        scale: scale,
        startFocalFrac: from,
        focalFrac: to,
        dataFrom: dataFrom,
        dataTo: dataTo,
      );

  // ==========================================================================
  group('T8a — zooming holds the instant under the fingers', () {
    test('a pinch about the middle keeps the middle where it was', () {
      final w = apply(full(), scale: 2);
      expect(w.spanMs, full().spanMs ~/ 2);
      // Same centre, half the width.
      final mid = (w.from.millisecondsSinceEpoch + w.to.millisecondsSinceEpoch) ~/ 2;
      final was = (dataFrom.millisecondsSinceEpoch + dataTo.millisecondsSinceEpoch) ~/ 2;
      expect((mid - was).abs(), lessThan(1000));
    });

    test('a pinch about the left edge keeps the left edge still', () {
      final w = apply(full(), scale: 4, from: 0, to: 0);
      expect(w.from, dataFrom);
      expect(w.spanMs, full().spanMs ~/ 4);
    });

    test('scale 1 with a moved focal point is a pure pan', () {
      // Fingers started at 25% and are now at 75% ⇒ the content moved right by
      // half a window, so the window moved LEFT by half.
      final start = apply(full(), scale: 4, from: 0.5, to: 0.5);
      final panned = apply(start, from: 0.25, to: 0.75);
      expect(panned.spanMs, start.spanMs, reason: 'a pan must not resize');
      expect(
          panned.from.millisecondsSinceEpoch -
              start.from.millisecondsSinceEpoch,
          closeTo(-start.spanMs * 0.5, 1000));
    });
  });

  // ==========================================================================
  group('T8b — Q5a: the zoom stops at 30 minutes', () {
    test('a huge pinch lands exactly on the floor, not past it', () {
      final w = apply(full(), scale: 10000);
      expect(w.spanMs, kHistoryMinVisibleSpanMs);
      expect(kHistoryMinVisibleSpanMs, 30 * 60000);
    });

    test('and the floor is not a suggestion — repeated pinches stay there', () {
      var w = full();
      for (var i = 0; i < 12; i++) {
        w = apply(w, scale: 3);
      }
      expect(w.spanMs, kHistoryMinVisibleSpanMs);
    });

    test('a recording shorter than the floor still opens', () {
      // 🔴 The edge that would otherwise divide by a negative: 10 minutes of
      // data with a 30-minute floor. The window is wider than the recording,
      // which is legal — it just shows all of it.
      final shortFrom = DateTime(2026, 8, 23, 6);
      final shortTo = shortFrom.add(const Duration(minutes: 10));
      final w = HistoryChartWindow.apply(
        start: HistoryChartWindow(shortFrom, shortTo),
        scale: 8,
        startFocalFrac: 0.5,
        focalFrac: 0.5,
        dataFrom: shortFrom,
        dataTo: shortTo,
      );
      expect(w.spanMs, kHistoryMinVisibleSpanMs);
      expect(w.from, shortFrom);
    });
  });

  // ==========================================================================
  group('T8c — the pan cannot leave the recording', () {
    test('repeated drags stop at the ends and never go past', () {
      // ⚠️ One gesture moves AT MOST one window width — the focal fraction is
      // 0…1 — so this loops the way a user flicks. The first draft asserted a
      // single drag reached the end and failed on exactly that arithmetic.
      var w = apply(full(), scale: 6);
      for (var i = 0; i < 10; i++) {
        w = apply(w, from: 0.0, to: 1.0); // content right ⇒ window left
      }
      expect(w.from, dataFrom, reason: 'stopped at the start of the recording');
      expect(w.to.isAfter(dataFrom), isTrue);
      for (var i = 0; i < 20; i++) {
        w = apply(w, from: 1.0, to: 0.0);
      }
      expect(w.to, dataTo, reason: 'stopped at the end of the recording');
    });

    test('zooming all the way out lands back on the whole recording', () {
      var w = apply(full(), scale: 20);
      w = apply(w, scale: 0.001);
      expect(w.from, dataFrom);
      expect(w.to, dataTo);
    });

    test('the overview strip centres without resizing', () {
      final zoomed = apply(full(), scale: 6);
      final moved = zoomed.centredOn(DateTime(2026, 8, 23, 9),
          dataFrom: dataFrom, dataTo: dataTo);
      expect(moved.spanMs, zoomed.spanMs);
      final mid = DateTime.fromMillisecondsSinceEpoch(
          (moved.from.millisecondsSinceEpoch +
                  moved.to.millisecondsSinceEpoch) ~/
              2);
      expect(mid, DateTime(2026, 8, 23, 9));
    });
  });

  // ==========================================================================
  group('T9 — the bucket floor survives the wider screen', () {
    test('the landscape target is a parameter, not a second derivation', () {
      final from = DateTime(2026, 8, 23, 6);
      final to = from.add(const Duration(hours: 12));
      expect(historyChartBucketMs(from, to), (12 * 3600000) ~/ 180);
      expect(
          historyChartBucketMs(from, to,
              targetPoints: kHistoryLandscapeTargetPoints),
          (12 * 3600000) ~/ 360);
      expect(kHistoryLandscapeTargetPoints, 360);
    });

    test('🔴 Q5 = 分鐘: nothing gets below one minute, at any target', () {
      final from = DateTime(2026, 8, 23, 6);
      // The narrowest window the page can reach, at the widest point target.
      final to = from.add(const Duration(milliseconds: kHistoryMinVisibleSpanMs));
      expect(
          historyChartBucketMs(from, to,
              targetPoints: kHistoryLandscapeTargetPoints),
          kHistoryListBucketMs);
      // …and even an absurd target cannot push it under.
      expect(historyChartBucketMs(from, to, targetPoints: 100000),
          kHistoryListBucketMs);
    });
  });

  // ==========================================================================
  group('T5 — the gap label retreats when it does not fit', () {
    // design 0081 §3.2.3 / Q6 = C. The landscape chart labels a hole; the
    // embedded card does not, because 244 px of plot cannot hold the sentence.
    // A label wider than its own gap would either overflow into the data on
    // both sides or be clipped mid-word, so it simply is not drawn.
    final t0 = DateTime(2026, 8, 23, 7);

    /// Three minutes, a hole of [gap], three more minutes.
    List<HistoryBucket> gapOf(Duration gap) => [
          for (var i = 0; i < 3; i++)
            HistoryBucket(
                at: t0.add(Duration(minutes: i)),
                avgPvlt: 13,
                minPvlt: 13,
                maxPvlt: 13,
                count: 60),
          for (var i = 0; i < 3; i++)
            HistoryBucket(
                at: t0.add(const Duration(minutes: 2)).add(gap).add(
                    Duration(minutes: i)),
                avgPvlt: 14,
                minPvlt: 14,
                maxPvlt: 14,
                count: 60),
        ];

    _Recording render(Duration gap, {required bool withLabel}) {
      final rec = _Recording();
      HistoryTrendPainter(
        buckets: gapOf(gap),
        gapLabel: withLabel ? (d) => 'Not connected for ${d.inHours} hours' : null,
        tempUnit: TempUnit.celsius,
        hasTemp: false,
        multiDay: false,
        bucketMs: 60000,
        selected: null,
        vColor: const Color(0xFFF6A821),
        tColor: const Color(0xFF46D4C8),
        grid: const Color(0xFF333333),
        text: const Color(0xFF888888),
      ).paint(rec, const Size(780, 200));
      return rec;
    }

    /// How many text runs the label itself adds — the axis labels are drawn
    /// either way, so the DIFFERENCE is the only honest observable.
    int extraText(Duration gap) =>
        render(gap, withLabel: true).paragraphs -
        render(gap, withLabel: false).paragraphs;

    test('a wide hole gets its sentence', () {
      expect(extraText(const Duration(hours: 6)), 1);
    });

    test('a hole too narrow for the words gets none', () {
      // Two minutes of hole inside a six-minute chart: about a third of the
      // plot, and still nowhere near wide enough for the sentence at 9.5 px.
      expect(extraText(const Duration(minutes: 2)), 0);
    });

    test('…but the hatch stays, so the hole is still visible', () {
      // 🔴 The retreat must lose the WORDS, not the mark. Losing both would
      // put the chart back to "a break in the line that looks like a bug".
      final rec = render(const Duration(minutes: 2), withLabel: true);
      expect(rec.lines.where((l) => (l.$3.color.a - 0.13).abs() < 0.02).length,
          greaterThan(0));
    });
  });
}

/// Records what it was asked to draw, including how many text runs reached it.
class _Recording implements Canvas {
  final List<(Offset, Offset, Paint)> lines = <(Offset, Offset, Paint)>[];
  int paragraphs = 0;

  @override
  void drawPath(Path path, Paint paint) {}

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      lines.add((p1, p2, paint));

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) => paragraphs++;

  @override
  void drawCircle(Offset c, double radius, Paint paint) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
