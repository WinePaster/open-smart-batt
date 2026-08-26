// FB-101 / design 0085 S2 — the history chart's LEFT axis can carry current.
//
// 🔵 The ruling is 案 B: the left axis SWITCHES between voltage and current,
// temperature keeps the right axis in both modes, and nothing gains a colour
// (§3.1/§3.2). So the things worth pinning here are the ones that would fail
// silently — a chart that still draws, still looks ordinary, and is wrong:
//
//  1. **The current axis always contains zero.** A run that never changed sign
//     would otherwise be drawn on a window fitted to it, and +8…10 A charging
//     would be pixel-for-pixel identical to −8…−10 A discharging.
//  2. **No `abs()`.** design 0030 §3.2 Q5 ruled it out on 2026-08-03: the sign
//     flip is the one thing the curve can say that the list cannot. Flattening
//     it draws a plausible line with the meaning deleted.
//  3. **The min–max band is there in current mode.** Q2① / Q3 ruled out the
//     "these are averages" sentence, so per §3.3 the band is the ONLY honesty
//     mechanism this feature ships. §9 item 10: it does not pass, it does not
//     ship.
//  4. **The temperature half does not move.** It is on the other axis and must
//     behave identically under both series — a regression net, not a feature.
//  5. **Gaps still break the line and the band** (design 0081 S2), in current
//     mode too.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';

void main() {
  const size = Size(320, 160);
  final t0 = DateTime(2026, 8, 27, 9, 50);

  final vColor = AccentTheme.amber.accent;
  final tColor = AccentTheme.amber.accentSecondary;

  /// `n` minute buckets whose current is `amps(i)`, with a ±0.5 A min–max
  /// spread and a temperature series that every test here expects to be
  /// unaffected by the left axis.
  List<HistoryBucket> run(
    int n,
    double Function(int) amps, {
    double spread = 0.5,
    bool withTemp = true,
  }) =>
      [
        for (var i = 0; i < n; i++)
          HistoryBucket(
            at: t0.add(Duration(minutes: i)),
            avgPvlt: 13.2,
            minPvlt: 13.1,
            maxPvlt: 13.3,
            avgTemp: withTemp ? 28 + i.toDouble() : null,
            minTemp: withTemp ? 27 + i.toDouble() : null,
            maxTemp: withTemp ? 29 + i.toDouble() : null,
            avgAmpere: amps(i),
            minAmpere: amps(i) - spread,
            maxAmpere: amps(i) + spread,
            count: 60,
          ),
      ];

  _Recording paint(
    List<HistoryBucket> buckets, {
    HistoryChartSeries series = HistoryChartSeries.current,
    bool hasTemp = true,
    String? direction,
  }) {
    final c = _Recording();
    historyTrendPainterForTest(
      buckets: buckets,
      hasTemp: hasTemp,
      series: series,
      currentDirectionLabel: direction,
    ).paint(c, size);
    return c;
  }

  // ---- the axis ---------------------------------------------------------

  group('the current axis always straddles zero', () {
    test('a run that only ever charged still shows the zero line', () {
      // +8…+10 A throughout. An axis fitted to the data would start near 7.5 A
      // and this would be indistinguishable from the discharging case below.
      final r = historyChartCurrentRange(run(6, (i) => 8.0 + i * 0.4));
      expect(r.lo, lessThanOrEqualTo(0));
      expect(r.hi, greaterThanOrEqualTo(10.5));
    });

    test('a run that only ever discharged does too', () {
      final r = historyChartCurrentRange(run(6, (i) => -8.0 - i * 0.4));
      expect(r.hi, greaterThanOrEqualTo(0));
      expect(r.lo, lessThanOrEqualTo(-10.5));
    });

    test('a run that crosses keeps both extremes inside the window', () {
      final r = historyChartCurrentRange(run(6, (i) => -3.0 + i.toDouble()));
      expect(r.lo, lessThanOrEqualTo(-3.5));
      expect(r.hi, greaterThanOrEqualTo(2.5));
      expect(r.lo, lessThan(0));
      expect(r.hi, greaterThan(0));
    });

    test('an idle run does not collapse onto the zero line', () {
      // A whole window at exactly 0.0 A. The floor is two counts of the 1 A
      // wire quantum, so the line has somewhere to be.
      final r = historyChartCurrentRange(run(6, (_) => 0, spread: 0));
      expect(r.hi - r.lo, greaterThanOrEqualTo(2));
      expect(r.lo, lessThan(0));
      expect(r.hi, greaterThan(0));
    });

    test('no buckets at all still gives a zero-centred window', () {
      final r = historyChartCurrentRange(const []);
      expect(r.lo, lessThan(0));
      expect(r.hi, greaterThan(0));
    });

    test('the axis is scaled over the extremes, not the means alone', () {
      // FB-74's rule, restated on the new axis: one minute of the run spent a
      // second at −12 A. The mean barely moves; the band must still fit.
      final b = run(6, (_) => -1.0, spread: 0.2).toList();
      b[3] = HistoryBucket(
        at: b[3].at,
        avgAmpere: -1.0,
        minAmpere: -12.0,
        maxAmpere: -0.8,
        count: 60,
      );
      final r = historyChartCurrentRange(b);
      expect(r.lo, lessThanOrEqualTo(-12),
          reason: 'an axis from the means alone clips the spike off the plot');
    });
  });

  // ---- the sign ---------------------------------------------------------

  group('the sign survives to the canvas — no abs()', () {
    test('discharge is drawn BELOW the zero line and charge above it', () {
      // Three minutes charging then three discharging, symmetric about zero.
      final rec =
          paint(run(6, (i) => i < 3 ? 4.0 : -4.0, spread: 0), hasTemp: false);
      final zero = rec.horizontals
          .where((l) => _sameHue(l.$3.color, vColor) && l.$3.color.a < 0.99)
          .map((l) => l.$1.dy)
          .toList();
      expect(zero, isNotEmpty, reason: 'the zero line must be drawn');
      final zy = zero.first;

      final line = rec.paths
          .where((p) =>
              p.$2.style == PaintingStyle.stroke && _sameHue(p.$2.color, vColor))
          .map((p) => p.$1.getBounds())
          .toList();
      expect(line, isNotEmpty);
      final top = line.map((r) => r.top).reduce((a, b) => a < b ? a : b);
      final bottom = line.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);

      // Canvas y grows downward. With abs() applied, +4 and −4 would land on
      // the SAME y and the whole series would sit on one side of the line.
      expect(top, lessThan(zy - 5),
          reason: 'the charging half must be above zero');
      expect(bottom, greaterThan(zy + 5),
          reason: 'the discharging half must be below zero — abs() would fold '
              'it on top of the charging half');
    });

    test('an all-negative run is drawn entirely below the zero line', () {
      final rec = paint(run(6, (_) => -4.0, spread: 0), hasTemp: false);
      final zy = rec.horizontals
          .where((l) => _sameHue(l.$3.color, vColor) && l.$3.color.a < 0.99)
          .map((l) => l.$1.dy)
          .first;
      final strokes = rec.paths
          .where((p) =>
              p.$2.style == PaintingStyle.stroke && _sameHue(p.$2.color, vColor))
          .map((p) => p.$1.getBounds());
      expect(strokes.every((r) => r.top > zy), isTrue,
          reason: 'a discharging unit must never be drawn as charging');
    });

  });

  // ---- the band ---------------------------------------------------------

  group('the min-max band is present in current mode (§9 item 10)', () {
    test('current draws a filled band, exactly as voltage does', () {
      final b = run(6, (i) => -3.0 + i.toDouble());
      final cur = paint(b, hasTemp: false);
      final volt = paint(b, series: HistoryChartSeries.voltage, hasTemp: false);
      int fills(_Recording r) => r.paths
          .where((p) =>
              p.$2.style == PaintingStyle.fill && _sameHue(p.$2.color, vColor))
          .length;
      expect(fills(cur), greaterThan(0),
          reason: 'design 0085 §3.3 — with the wording ruled out, the band is '
              'the only thing saying the line is a mean');
      expect(fills(cur), fills(volt));
    });

    test('the band widens with the spread — the 1 A quantum made visible', () {
      // A minute that sat at 0 A the whole time has no spread; a minute that
      // bounced between −4 and 0 has four counts of it.
      Rect bandOf(double spread) {
        final rec = paint(run(6, (_) => -2.0, spread: spread), hasTemp: false);
        final fills = rec.paths
            .where((p) =>
                p.$2.style == PaintingStyle.fill && _sameHue(p.$2.color, vColor))
            .map((p) => p.$1.getBounds())
            .toList();
        expect(fills, isNotEmpty);
        return fills.first;
      }

      expect(bandOf(0).height, lessThan(bandOf(2).height),
          reason: 'the band IS "how many integer counts this minute jumped '
              'between" (design 0085 §3.3)');
    });

    test('a lone bucket after a gap leaves a whisker, not a zero-area path',
        () {
      final b = <HistoryBucket>[
        HistoryBucket(at: t0, count: 0),
        HistoryBucket(
          at: t0.add(const Duration(minutes: 1)),
          avgAmpere: -1.0,
          minAmpere: -6.0,
          maxAmpere: 0.0,
          count: 60,
        ),
        HistoryBucket(at: t0.add(const Duration(minutes: 2)), count: 0),
        HistoryBucket(
          at: t0.add(const Duration(minutes: 3)),
          avgAmpere: -1.0,
          minAmpere: -1.2,
          maxAmpere: -0.8,
          count: 60,
        ),
      ];
      final rec = paint(b, hasTemp: false);
      expect(rec.lines.where((l) => (l.$1.dy - l.$2.dy).abs() > 20), isNotEmpty,
          reason: 'the isolated bucket must leave a vertical whisker');
    });
  });

  // ---- gaps -------------------------------------------------------------

  group('a hole in the recording still breaks the current series', () {
    /// Six minutes with an hour missing after the third — design 0081 S2's
    /// threshold is 1.5 buckets.
    List<HistoryBucket> gapped() => [
          for (var i = 0; i < 6; i++)
            HistoryBucket(
              at: t0.add(Duration(minutes: i < 3 ? i : i + 60)),
              avgAmpere: -2.0 + i,
              minAmpere: -2.5 + i,
              maxAmpere: -1.5 + i,
              count: 60,
            ),
        ];

    test('the band is two runs, never one path across the gap', () {
      final rec = paint(gapped(), hasTemp: false);
      final fills = rec.paths
          .where((p) =>
              p.$2.style == PaintingStyle.fill && _sameHue(p.$2.color, vColor))
          .toList();
      expect(fills.length, 2,
          reason: 'a filled shape spanning the hole looks like measured spread');
    });

    test('the line is two strokes too', () {
      final rec = paint(gapped(), hasTemp: false);
      final strokes = rec.paths
          .where((p) =>
              p.$2.style == PaintingStyle.stroke && _sameHue(p.$2.color, vColor))
          .toList();
      expect(strokes.length, 2,
          reason: 'a line across the hatch draws a reading nobody measured');
    });
  });

  // ---- the right axis does not move ------------------------------------

  group('temperature is untouched by the switch (regression)', () {
    List<Rect> tempShapes(_Recording r) => r.paths
        .where((p) => _sameHue(p.$2.color, tColor))
        .map((p) => p.$1.getBounds())
        .toList(growable: false);

    test('the temperature band and line are drawn identically in both modes',
        () {
      final b = run(6, (i) => -3.0 + i.toDouble());
      final volt = tempShapes(paint(b, series: HistoryChartSeries.voltage));
      final cur = tempShapes(paint(b, series: HistoryChartSeries.current));
      expect(cur, isNotEmpty, reason: 'temperature must still be drawn');
      expect(cur.length, volt.length);
      for (var i = 0; i < cur.length; i++) {
        expect(cur[i].top, closeTo(volt[i].top, 1e-9));
        expect(cur[i].bottom, closeTo(volt[i].bottom, 1e-9));
        expect(cur[i].left, closeTo(volt[i].left, 1e-9));
        expect(cur[i].right, closeTo(volt[i].right, 1e-9));
      }
    });

    test('the temperature axis window is computed from the same rule', () {
      final b = run(6, (i) => -3.0 + i.toDouble());
      final r = historyChartTempRange(b, TempUnit.celsius);
      expect(r.lo, lessThanOrEqualTo(27));
      expect(r.hi, greaterThanOrEqualTo(34));
    });

    test('hasTemp still decides the right margin, in current mode too', () {
      final b = run(6, (i) => -3.0 + i.toDouble());
      double rightEdge(_Recording r) => r.lines
          .where((l) => (l.$1.dy - l.$2.dy).abs() < 1e-9)
          .map((l) => l.$2.dx)
          .reduce((a, b) => a > b ? a : b);
      expect(rightEdge(paint(b, hasTemp: true)),
          lessThan(rightEdge(paint(b, hasTemp: false))),
          reason: 'the 40 px temperature gutter is unchanged by design 0085');
    });
  });

  // ---- the zero line and its direction key -----------------------------

  group('the zero line', () {
    test('is drawn in current mode and absent in voltage mode', () {
      final b = run(6, (i) => -3.0 + i.toDouble());
      bool hasZero(_Recording r) => r.horizontals
          .any((l) => _sameHue(l.$3.color, vColor) && l.$3.color.a < 0.99);
      expect(hasZero(paint(b, series: HistoryChartSeries.current)), isTrue);
      expect(hasZero(paint(b, series: HistoryChartSeries.voltage)), isFalse,
          reason: 'voltage does not cross zero and has no such reference');
    });

    test('sits exactly where 0 A maps, not at the middle of the plot', () {
      // Asymmetric window: −1…+9 A, so zero is well off centre.
      final rec = paint(run(6, (i) => i.toDouble() * 2 - 1), hasTemp: false);
      final zy = rec.horizontals
          .where((l) => _sameHue(l.$3.color, vColor) && l.$3.color.a < 0.99)
          .map((l) => l.$1.dy)
          .first;
      final r = historyChartCurrentRange(run(6, (i) => i.toDouble() * 2 - 1));
      const top = 8.0, bottom = 18.0;
      final plotH = size.height - top - bottom;
      expect(zy, closeTo(top + plotH * (1 - (0 - r.lo) / (r.hi - r.lo)), 1e-6));
    });

    test('carries the direction key when one is supplied', () {
      final b = run(6, (i) => -3.0 + i.toDouble());
      // The painter knows no locales, so the wording arrives as a string —
      // 🔵 which family's wording it is, is S3's decision.
      final rec = paint(b, direction: '+ charge · − discharge');
      expect(rec.paragraphs, greaterThan(paint(b).paragraphs),
          reason: 'the axis has to say which half is which (design 0056)');
    });
  });

  // ---- repaint ----------------------------------------------------------

  test('switching series repaints', () {
    final b = run(4, (i) => i.toDouble());
    HistoryTrendPainter make(HistoryChartSeries s, {String? dir}) =>
        HistoryTrendPainter(
          buckets: b,
          tempUnit: TempUnit.celsius,
          hasTemp: false,
          multiDay: false,
          bucketMs: 60000,
          selected: null,
          series: s,
          currentDirectionLabel: dir,
          vColor: vColor,
          tColor: tColor,
          grid: const Color(0xFF333333),
          text: const Color(0xFF888888),
        );
    expect(
        make(HistoryChartSeries.current)
            .shouldRepaint(make(HistoryChartSeries.voltage)),
        isTrue,
        reason: 'a switch that does not repaint leaves the old quantity on '
            'screen under the new axis labels');
    expect(
        make(HistoryChartSeries.current, dir: 'a')
            .shouldRepaint(make(HistoryChartSeries.current, dir: 'b')),
        isTrue);
    expect(
        make(HistoryChartSeries.current)
            .shouldRepaint(make(HistoryChartSeries.current)),
        isFalse);
  });
}

/// Same hue, ignoring the alpha the band and the zero line apply.
bool _sameHue(Color a, Color b) =>
    (a.r - b.r).abs() < 1e-6 &&
    (a.g - b.g).abs() < 1e-6 &&
    (a.b - b.b).abs() < 1e-6;

/// A [Canvas] that keeps what it was asked to draw — the same recorder
/// `history_chart_aggregation_test.dart` uses, plus a paragraph count so the
/// direction key is observable (text goes through `drawParagraph`).
class _Recording implements Canvas {
  final List<(Path, Paint)> paths = <(Path, Paint)>[];
  final List<(Offset, Offset, Paint)> lines = <(Offset, Offset, Paint)>[];
  int paragraphs = 0;

  /// Horizontal rules only — grid lines, and the zero line.
  Iterable<(Offset, Offset, Paint)> get horizontals =>
      lines.where((l) => (l.$1.dy - l.$2.dy).abs() < 1e-9);

  @override
  void drawPath(Path path, Paint paint) => paths.add((path, paint));

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      lines.add((p1, p2, paint));

  @override
  void drawCircle(Offset c, double radius, Paint paint) {}

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) => paragraphs++;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
