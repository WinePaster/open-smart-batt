/// OpenSmartBatt — the history chart's DRAWING core: geometry, axis windows
/// and the painter, with no gestures and no widgets.
///
/// ## Why this file exists (design 0081 S2)
///
/// 🔴 **Because the landscape page is about to become a second caller, and a
/// second caller is exactly how FB-74 happened.** The chart is drawn from
/// bucket means with a min–max band, on axes scaled to the extremes; get any
/// one of those subtly different in a second implementation and the two
/// surfaces report different numbers for the same minute, with nothing on
/// screen to say which is right (design 0065 §6 R5).
///
/// So the split is not "tidying up". It is the precondition for design 0081 S3:
/// the full-screen chart gets to choose its own VIEWPORT and its own GESTURES,
/// and nothing else.
///
/// ## What changed on the way out (2026-08-23)
///
/// 🔵 **The x axis is TIME now, not bucket index.** It used to be
/// `xAt(i) = left + plotW * i / (n - 1)` — equal steps per point — while
/// `queryBuckets` is a `GROUP BY` that never emits an empty bucket. Together
/// those two meant a unit that rode 07:12–08:05, parked, and rode again
/// 13:40–14:26 had **five and a half hours of nothing drawn as one ordinary
/// step**, with a line across it that no reading supports (design 0081 §1.2).
///
/// The line and the band now BREAK across a gap and the gap is hatched, so
/// "nothing was recorded here" is visible rather than interpolated. See
/// [HistoryChartGeometry.gapAfter] for what counts as a gap and why the
/// threshold is 1.5 buckets.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../data/history_repo.dart';
import '../../models/models.dart';
import '../../theme/accent_theme.dart';

double historyDisplayTemp(double c, TempUnit u) =>
    u == TempUnit.fahrenheit ? c * 9 / 5 + 32 : c;

String historyTempUnitLabel(TempUnit u) => u == TempUnit.fahrenheit ? '°F' : '°C';

/// Plot geometry for the trend chart — the ONE place the paddings live, and
/// (since design 0081 S2) the ONE place time becomes an x coordinate.
///
/// 🔴 The paddings used to be written twice: once in [HistoryTrendPainter.paint]
/// and once in the tap handler that has to invert the mapping to turn a touch
/// into a bucket index. The two agreed only because somebody kept them
/// agreeing, and design 0076 §1.3 was about to add a THIRD copy (the scrub
/// handler). A padding that drifts here does not crash — it silently selects
/// the wrong bucket, which is the failure mode this file can least afford
/// (FB-74 was about the chart and the list disagreeing over the same minute).
///
/// 🔵 **[from] / [to] are the plotted WINDOW, not the data.** For the embedded
/// card they are the first and last bucket; design 0081 S3's landscape page
/// will pass whatever the user has panned to. Everything below is written in
/// terms of them so that the second caller changes nothing else.
class HistoryChartGeometry {
  HistoryChartGeometry({
    required this.width,
    required this.hasTemp,
    required this.buckets,
    required this.bucketMs,
    DateTime? from,
    DateTime? to,
  })  : from = from ?? (buckets.isEmpty ? null : buckets.first.at),
        to = to ?? (buckets.isEmpty ? null : buckets.last.at);

  /// Right padding is wider when a temperature axis has to be labelled there.
  static const double left = 40, top = 8, bottom = 18;

  final double width;
  final bool hasTemp;
  final List<HistoryBucket> buckets;
  final int bucketMs;

  /// The plotted window's ends. Null only when there is nothing to plot.
  final DateTime? from;
  final DateTime? to;

  int get n => buckets.length;
  double get right => hasTemp ? 40 : 8;
  double get plotW => width - left - right;

  /// Milliseconds across the plot. Never zero: a window with no width would
  /// divide by zero below, and a single-point chart is a real (if boring) case.
  int get spanMs {
    final a = from, b = to;
    if (a == null || b == null) return 1;
    final d = b.millisecondsSinceEpoch - a.millisecondsSinceEpoch;
    return d <= 0 ? 1 : d;
  }

  /// Where [t] sits on the plot. **Not clamped** — the landscape page will pan
  /// points off both edges on purpose, and clipping is the canvas's job.
  double xAtTime(DateTime t) {
    if (from == null) return left + plotW / 2;
    return left +
        plotW * (t.millisecondsSinceEpoch - from!.millisecondsSinceEpoch) /
            spanMs;
  }

  /// Where bucket [i] sits. A single-bucket chart is centred, as before.
  double xAt(int i) => n == 1 ? left + plotW / 2 : xAtTime(buckets[i].at);

  /// 🔵 **Is the step from [i] to [i + 1] a hole in the recording?**
  ///
  /// `queryBuckets` emits nothing for a bucket with no rows, so two adjacent
  /// entries can be minutes or MONTHS apart and the list gives no hint. The
  /// threshold is one and a half buckets: consecutive buckets are exactly one
  /// apart, so anything past 1.5 is a missing bucket rather than rounding, and
  /// staying below 2.0 means a SINGLE dropped minute already shows as a gap —
  /// which is the honest reading of "the app was not recording then".
  bool gapAfter(int i) {
    if (i < 0 || i + 1 >= n) return false;
    final d = buckets[i + 1].at.millisecondsSinceEpoch -
        buckets[i].at.millisecondsSinceEpoch;
    return d > bucketMs * 1.5;
  }

  /// Which bucket a touch at [dx] lands on — 🔵 **nearest IN TIME**, clamped to
  /// the ends so a finger dragged past either edge holds the first/last point
  /// rather than dropping the selection.
  ///
  /// 🔵 Rewritten for the time axis (design 0081 S2). The index version could
  /// invert its own arithmetic; this one has to search, because the points are
  /// no longer evenly spaced. Over a GAP the finger snaps to whichever side is
  /// closer in time — the alternative (select nothing) would make the panel
  /// blink out mid-scrub, which design 0076 §3.2 spent its whole ruling
  /// avoiding.
  ///
  /// Null when there is nothing to hit — fewer than two buckets (the chart is
  /// not drawn at all, see [HistoryTrendCard.build]) or a plot too narrow to
  /// divide.
  int? indexAt(double dx) {
    if (n < 2 || plotW <= 0) return null;
    final frac = ((dx - left) / plotW).clamp(0.0, 1.0);
    final t = from!.millisecondsSinceEpoch + (spanMs * frac).round();
    var best = 0, bestD = -1;
    for (var i = 0; i < n; i++) {
      final d = (buckets[i].at.millisecondsSinceEpoch - t).abs();
      if (bestD < 0 || d < bestD) {
        best = i;
        bestD = d;
      }
    }
    return best;
  }
}

/// The chart's left-axis window, in volts — FB-74.
///
/// 🔴 **Computed over the buckets' EXTREMES, never over their means alone.**
/// This is the chart-side half of the defect design 0061 §6.0 pinned for the
/// list: one second at 15.5 V inside a one-hour bucket moves `avgPvlt` by about
/// four millivolts, so an axis scaled from the means tops out just above the
/// ordinary running voltage — and the min–max band drawn below would then be
/// clipped off the top of the plot, silently. The stats strip immediately under
/// the chart reports the range-wide `MAX` from raw rows, so an averaged axis
/// also puts a number on screen (15.5 V) that the picture above it flatly
/// contradicts and gives the reader no way to locate in time.
///
/// PUBLIC-ish (used by `history_chart_aggregation_test.dart`) for the same
/// reason [historyWindowIsFlagged] is: the rule is worth pinning without
/// pumping a screen.
({double lo, double hi}) historyChartVoltageRange(List<HistoryBucket> buckets) {
  double? lo, hi;
  void see(double? v) {
    if (v == null) return;
    if (lo == null || v < lo!) lo = v;
    if (hi == null || v > hi!) hi = v;
  }

  for (final b in buckets) {
    see(b.avgPvlt);
    see(b.minPvlt);
    see(b.maxPvlt);
  }
  var vlo = (lo ?? 0) - 0.2, vhi = (hi ?? 1) + 0.2;
  if (vhi - vlo < 0.5) {
    final m = (vlo + vhi) / 2;
    vlo = m - 0.25;
    vhi = m + 0.25;
  }
  return (lo: vlo, hi: vhi);
}

/// The chart's right-axis window, in DISPLAY temperature units — FB-74.
///
/// Same rule and same reason as [historyChartVoltageRange]: a bucket's hottest
/// second is the one worth seeing, and it is not in the mean.
({double lo, double hi}) historyChartTempRange(
    List<HistoryBucket> buckets, TempUnit unit) {
  double? lo, hi;
  void see(double? c) {
    if (c == null) return;
    final d = historyDisplayTemp(c, unit);
    if (lo == null || d < lo!) lo = d;
    if (hi == null || d > hi!) hi = d;
  }

  for (final b in buckets) {
    see(b.avgTemp);
    see(b.minTemp);
    see(b.maxTemp);
  }
  // No temperature anywhere in range: the same placeholder window the axis has
  // always fallen back to, kept identical so a chart with no temperature draws
  // exactly as it did before.
  var tlo = (lo ?? 0) - 1, thi = (hi ?? 1) + 1;
  if (thi - tlo < 2) {
    final m = (tlo + thi) / 2;
    tlo = m - 1;
    thi = m + 1;
  }
  return (lo: tlo, hi: thi);
}

/// Build the chart's painter outside the screen, for `history_chart_aggregation_test.dart`.
///
/// The test drives [CustomPainter.paint] against a recording canvas and asserts
/// that the min–max band is actually on the canvas and actually reaches above
/// the mean line. Reaching that through a pumped History screen would mean
/// standing up a controller, a database and a device picker to assert one thing
/// about one `drawPath`.
CustomPainter historyTrendPainterForTest({
  required List<HistoryBucket> buckets,
  TempUnit tempUnit = TempUnit.celsius,
  bool hasTemp = false,
  bool multiDay = false,
  int bucketMs = 60000,
  int? selected,
  // The test asserts geometry, not hue, so the DEFAULT set is the honest
  // stand-in — but it is a parameter rather than a literal so a colour test
  // can drive the painter with a non-amber set, which is the only way the
  // "voltage series still follows the theme" regression is visible at all
  // (in amber, every one of these colours is what it always was).
  AccentTheme accent = AccentTheme.amber,
}) =>
    HistoryTrendPainter(
      buckets: buckets,
      tempUnit: tempUnit,
      hasTemp: hasTemp,
      multiDay: multiDay,
      bucketMs: bucketMs,
      selected: selected,
      vColor: accent.accent,
      tColor: accent.accentSecondary,
      grid: const Color(0xFF333333),
      text: const Color(0xFF888888),
    );

class HistoryTrendPainter extends CustomPainter {
  HistoryTrendPainter({
    required this.buckets,
    required this.tempUnit,
    required this.hasTemp,
    required this.multiDay,
    required this.bucketMs,
    required this.selected,
    required this.vColor,
    required this.tColor,
    required this.grid,
    required this.text,
  });

  final List<HistoryBucket> buckets;
  final TempUnit tempUnit;
  final bool hasTemp;
  final bool multiDay;
  final int bucketMs;
  final int? selected;
  final Color vColor, tColor, grid, text;

  @override
  void paint(Canvas canvas, Size size) {
    final n = buckets.length;
    final g = HistoryChartGeometry(
        width: size.width,
        hasTemp: hasTemp,
        buckets: buckets,
        bucketMs: bucketMs);
    const left = HistoryChartGeometry.left,
        top = HistoryChartGeometry.top,
        bottom = HistoryChartGeometry.bottom;
    final right = g.right;
    final plotH = size.height - top - bottom;

    // Axis windows. FB-74: both are scaled to include the buckets' MIN/MAX, not
    // just their means — see [historyChartVoltageRange] for why an averaged
    // axis would clip the very thing the band below exists to show.
    final vr = historyChartVoltageRange(buckets);
    final vlo = vr.lo, vhi = vr.hi;
    final tr = historyChartTempRange(hasTemp ? buckets : const [], tempUnit);
    final tlo = tr.lo, thi = tr.hi;

    double xAt(int i) => g.xAt(i);
    double yV(double v) => top + plotH * (1 - (v - vlo) / (vhi - vlo));
    double yT(double v) => top + plotH * (1 - (v - tlo) / (thi - tlo));

    void tp(String s, double x, double y,
        {bool rightAlign = false, Color? c}) {
      final p = TextPainter(
        text: TextSpan(
            text: s, style: TextStyle(color: c ?? text, fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(canvas, Offset(rightAlign ? x - p.width : x, y));
    }

    // 🔵 **Gaps first, under everything** — design 0081 S2 / Q6 (內嵌採 B：
    // 斜線，不放文字). Drawn before the grid so the hatch reads as background
    // rather than as another series.
    //
    // 🔴 It is the only thing on the chart that says "nothing was recorded
    // here". Without it a break in the line is indistinguishable from a
    // rendering fault, which is exactly the reading design 0081 §8's owner
    // review was worried about.
    void hatch(Rect r) {
      if (r.width <= 0.5) return;
      canvas.save();
      canvas.clipRect(r);
      final p = Paint()
        ..color = text.withValues(alpha: 0.13)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      // 45°, spaced 9 px. The sweep starts one plot-height to the left so the
      // first stripes actually cross the rect instead of missing its corner.
      for (var x = r.left - r.height; x < r.right + r.height; x += 9) {
        canvas.drawLine(Offset(x, r.bottom), Offset(x + r.height, r.top), p);
      }
      canvas.restore();
    }

    for (var i = 0; i < n - 1; i++) {
      if (g.gapAfter(i)) {
        hatch(Rect.fromLTRB(xAt(i), top, xAt(i + 1), top + plotH));
      }
    }

    final gridPaint = Paint()
      ..color = grid.withValues(alpha: 0.5)
      ..strokeWidth = 1;

    // Horizontal grid + left (V) / right (T) axis labels at lo/mid/hi.
    for (final f in [0.0, 0.5, 1.0]) {
      final y = top + plotH * (1 - f);
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), gridPaint);
      tp((vlo + (vhi - vlo) * f).toStringAsFixed(1), left - 4, y - 6,
          rightAlign: true, c: vColor);
      if (hasTemp) {
        tp((tlo + (thi - tlo) * f).toStringAsFixed(0), size.width - right + 4,
            y - 6, c: tColor);
      }
    }

    // X time labels (start / end).
    //
    // 🔴 The format follows the BUCKET WIDTH, not just `multiDay` (design 0061
    // T13b). A bare `MM/dd` only tells the truth when a point IS a day: "last
    // 7 days" buckets at ~56 minutes, so two adjacent points would carry the
    // identical date and the axis would claim a resolution it does not have.
    // Since T13 the day boundary is the viewer's local midnight, so `MM/dd` is
    // finally correct in the one case it applies to.
    final fmt = DateFormat(
        multiDay ? (bucketMs >= 24 * 3600000 ? 'MM/dd' : 'MM/dd HH:mm') : 'HH:mm');
    // The WINDOW's ends, which for the embedded card are the first and last
    // bucket and for design 0081 S3's landscape page will be wherever the user
    // panned to.
    tp(fmt.format(g.from ?? buckets.first.at), left, size.height - 12);
    tp(fmt.format(g.to ?? buckets.last.at), size.width - right,
        size.height - 12,
        rightAlign: true);

    // Selection crosshair (vertical guide), drawn under the series.
    final sel = selected;
    if (sel != null && sel >= 0 && sel < n) {
      final sx = xAt(sel);
      canvas.drawLine(
          Offset(sx, top),
          Offset(sx, top + plotH),
          Paint()
            ..color = text.withValues(alpha: 0.55)
            ..strokeWidth = 1);
    }

    // Polyline helper that breaks across nulls.
    void drawLine(double? Function(HistoryBucket) sel, double Function(double) y,
        Color color) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      Path? path;
      for (var i = 0; i < n; i++) {
        final raw = sel(buckets[i]);
        if (raw == null) {
          if (path != null) {
            canvas.drawPath(path, paint);
            path = null;
          }
          continue;
        }
        final pt = Offset(xAt(i), y(raw));
        if (path == null) {
          path = Path()..moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
        // 🔵 design 0081 S2: a hole in the recording ends the stroke. Without
        // this the line runs straight across the hatched band — drawing a
        // reading for hours nobody measured.
        if (g.gapAfter(i)) {
          canvas.drawPath(path, paint);
          path = null;
        }
      }
      if (path != null) canvas.drawPath(path, paint);
    }

    /// The MIN–MAX band for one series, filled under its mean line — FB-74.
    ///
    /// 🔴 This is the only thing on the chart that can show an INSTANT. The
    /// line is the bucket's mean, and a bucket is 1 minute to 24 hours wide: a
    /// single second at 15.5 V inside an hour moves the mean by about four
    /// millivolts and is, on the line alone, indistinguishable from nothing
    /// having happened. The user paid 60× the storage for that second (design
    /// 0061); averaging it back out at read time is the same defect §6.0
    /// pinned for the list, wearing different clothes.
    ///
    /// Bands break across nulls exactly where the line does, so a gap in the
    /// data cannot be filled in by a shape that spans it. A run of ONE bucket
    /// has no width, so it is stroked as a vertical whisker instead of filled —
    /// otherwise an isolated bucket (a single minute after a long gap) would
    /// produce a degenerate zero-area path and its spike would be the one thing
    /// on the chart nobody could see.
    void drawBand(double? Function(HistoryBucket) loSel,
        double? Function(HistoryBucket) hiSel, double Function(double) y,
        Color color) {
      final fill = Paint()
        ..color = color.withValues(alpha: 0.22)
        ..style = PaintingStyle.fill;
      final whisker = Paint()
        ..color = color.withValues(alpha: 0.45)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      bool has(int i) => loSel(buckets[i]) != null && hiSel(buckets[i]) != null;
      var i = 0;
      while (i < n) {
        if (!has(i)) {
          i++;
          continue;
        }
        var j = i;
        // 🔵 `!g.gapAfter(j)` added by design 0081 S2 — the band must break
        // exactly where the line does. A band that spanned a gap the line
        // broke at would put a filled shape over hours with no data, which is
        // worse than the interpolated line: it looks like measured spread.
        while (j + 1 < n && has(j + 1) && !g.gapAfter(j)) {
          j++;
        }
        if (i == j) {
          canvas.drawLine(Offset(xAt(i), y(hiSel(buckets[i])!)),
              Offset(xAt(i), y(loSel(buckets[i])!)), whisker);
        } else {
          final path = Path()..moveTo(xAt(i), y(hiSel(buckets[i])!));
          for (var k = i + 1; k <= j; k++) {
            path.lineTo(xAt(k), y(hiSel(buckets[k])!));
          }
          for (var k = j; k >= i; k--) {
            path.lineTo(xAt(k), y(loSel(buckets[k])!));
          }
          canvas.drawPath(path..close(), fill);
        }
        i = j + 1;
      }
    }

    if (hasTemp) {
      double? t(double? c) => c == null ? null : historyDisplayTemp(c, tempUnit);
      drawBand((b) => t(b.minTemp), (b) => t(b.maxTemp), yT, tColor);
    }
    drawBand((b) => b.minPvlt, (b) => b.maxPvlt, yV, vColor);

    if (hasTemp) {
      drawLine((b) => b.avgTemp == null
          ? null
          : historyDisplayTemp(b.avgTemp!, tempUnit), yT, tColor);
    }
    drawLine((b) => b.avgPvlt, yV, vColor);

    // Emphasized markers at the selected bucket (over the series).
    if (sel != null && sel >= 0 && sel < n) {
      final b = buckets[sel];
      final sx = xAt(sel);
      if (b.avgPvlt != null) {
        final c = Offset(sx, yV(b.avgPvlt!));
        canvas.drawCircle(c, 4.5, Paint()..color = vColor);
        canvas.drawCircle(
            c,
            4.5,
            Paint()
              ..color = grid
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
      if (hasTemp && b.avgTemp != null) {
        canvas.drawCircle(
            Offset(sx, yT(historyDisplayTemp(b.avgTemp!, tempUnit))),
            4.5,
            Paint()..color = tColor);
      }
    }

    // Latest voltage marker + value.
    for (var i = n - 1; i >= 0; i--) {
      final a = buckets[i].avgPvlt;
      if (a == null) continue;
      final lx = xAt(i), ly = yV(a);
      canvas.drawCircle(Offset(lx, ly), 3, Paint()..color = vColor);
      tp('${a.toStringAsFixed(2)}V', lx - 2, ly - 16,
          rightAlign: true, c: vColor);
      break;
    }
  }

  @override
  bool shouldRepaint(covariant HistoryTrendPainter old) =>
      old.selected != selected ||
      old.buckets.length != buckets.length ||
      old.hasTemp != hasTemp ||
      old.tempUnit != tempUnit ||
      (buckets.isNotEmpty &&
          old.buckets.isNotEmpty &&
          old.buckets.last.at != buckets.last.at);
}
