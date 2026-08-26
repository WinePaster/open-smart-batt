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
import 'package:open_smart_batt/l10n/app_localizations.dart';

import '../../theme/accent_theme.dart';
import 'history_query.dart';

double historyDisplayTemp(double c, TempUnit u) =>
    u == TempUnit.fahrenheit ? c * 9 / 5 + 32 : c;

String historyTempUnitLabel(TempUnit u) => u == TempUnit.fahrenheit ? '°F' : '°C';

/// "Each point on the chart averages N minutes / hours" — design 0061 T10.
///
/// 🔵 In the core since design 0081 S3: the landscape page states the same
/// sentence in its top bar, and two spellings of "how much time is one point"
/// is precisely the drift design 0065 §6 R5 is about.
///
/// Hours once the width reaches one, because "each point averages 1440 minutes"
/// is a number nobody converts. Rounded to whole units: the width is derived
/// from a span divided by a target point count, so it lands on values like
/// 3.7 minutes, and a note reading "3.7 minutes" would be answering a precision
/// question nobody asked.
String historyBucketWidthNote(AppLocalizations l10n, int bucketMs) {
  final minutes = (bucketMs / 60000).round().clamp(1, 1 << 30);
  if (minutes < 60) return l10n.historyChartBucketMinutes(minutes);
  return l10n.historyChartBucketHours((minutes / 60).round().clamp(1, 1 << 30));
}

/// The landscape chart's visible window, and the arithmetic that moves it —
/// design 0081 S3.
///
/// 🔑 **A plain value with a pure transform, deliberately.** Pan and zoom are
/// the two things on that page a user can get wrong in a way that is hard to
/// describe ("it jumped", "it will not go back"), and a widget test that has to
/// synthesise pointer events to reach the arithmetic tests the gesture
/// recogniser as much as the maths. Everything below is reachable from a plain
/// `test()`.
@immutable
class HistoryChartWindow {
  const HistoryChartWindow(this.from, this.to);

  final DateTime from;
  final DateTime to;

  int get spanMs => to.millisecondsSinceEpoch - from.millisecondsSinceEpoch;

  /// The window after a scale gesture that started at [start].
  ///
  /// [scale] is the pinch factor (1.0 while merely panning), [startFocalFrac]
  /// where the gesture began across the plot (0…1) and [focalFrac] where the
  /// fingers are now. Holding the instant under the finger still is what makes
  /// a pinch feel anchored rather than centred.
  ///
  /// 🔴 Two clamps, and they are not interchangeable:
  ///
  ///  * **[kHistoryMinVisibleSpanMs]** (Q5a) stops the zoom where extra depth
  ///    stops buying detail — the bucket floor is a minute, so a narrower
  ///    window is the same points further apart;
  ///  * **the data's own range** stops the pan, so the chart cannot be dragged
  ///    into an empty century. A window WIDER than the data is allowed and
  ///    simply shows all of it — refusing that would make "zoom back out" fail
  ///    at the last step.
  static HistoryChartWindow apply({
    required HistoryChartWindow start,
    required double scale,
    required double startFocalFrac,
    required double focalFrac,
    required DateTime dataFrom,
    required DateTime dataTo,
  }) {
    final fullMs = dataTo.millisecondsSinceEpoch - dataFrom.millisecondsSinceEpoch;
    final maxSpan = fullMs <= 0 ? kHistoryMinVisibleSpanMs : fullMs;
    final s = scale <= 0 ? 1.0 : scale;
    final span = (start.spanMs / s)
        .round()
        .clamp(kHistoryMinVisibleSpanMs, maxSpan.clamp(kHistoryMinVisibleSpanMs, 1 << 62));

    final anchorMs = start.from.millisecondsSinceEpoch +
        (start.spanMs * startFocalFrac).round();
    var fromMs = anchorMs - (span * focalFrac).round();

    // Pan bounds. When the window is as wide as the data there is exactly one
    // legal position, and this arithmetic lands on it rather than fighting.
    final lo = dataFrom.millisecondsSinceEpoch;
    final hi = dataTo.millisecondsSinceEpoch - span;
    fromMs = hi <= lo ? lo : fromMs.clamp(lo, hi);

    return HistoryChartWindow(
      DateTime.fromMillisecondsSinceEpoch(fromMs),
      DateTime.fromMillisecondsSinceEpoch(fromMs + span),
    );
  }

  /// The window centred on [t], keeping its width — what dragging the overview
  /// strip does.
  HistoryChartWindow centredOn(DateTime t,
      {required DateTime dataFrom, required DateTime dataTo}) {
    final span = spanMs;
    final lo = dataFrom.millisecondsSinceEpoch;
    final hi = dataTo.millisecondsSinceEpoch - span;
    var fromMs = t.millisecondsSinceEpoch - span ~/ 2;
    fromMs = hi <= lo ? lo : fromMs.clamp(lo, hi);
    return HistoryChartWindow(
      DateTime.fromMillisecondsSinceEpoch(fromMs),
      DateTime.fromMillisecondsSinceEpoch(fromMs + span),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HistoryChartWindow && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'HistoryChartWindow($from … $to)';
}

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

/// Which quantity the LEFT axis is showing — design 0085 §3.1 案 B (FB-101).
///
/// 🔵 **A switch, not a third series.** Temperature keeps the right axis in
/// both modes; current REPLACES voltage on the left and reuses its colour
/// ([HistoryTrendPainter.vColor], the theme's `accent`). That is the whole
/// point of the ruling: 案 A wanted a third trace, and a third trace needs a
/// third line colour, which means re-running all seven checks in
/// `accent_theme.dart:28-60` across six themes in two brightnesses, by hand,
/// at line width. Swapping the left series costs nothing of the sort.
///
/// 🔴 The price, recorded rather than hidden (design 0085 §3.2): one series at
/// a time means "what was the current doing while the voltage sagged" is NOT
/// answerable from one picture. That was accepted knowingly; it is not a bug
/// to be fixed by quietly drawing both.
enum HistoryChartSeries { voltage, current }

/// The chart's left-axis window, in amperes — design 0085 §3.1 案 B (FB-101).
///
/// Same rule as [historyChartVoltageRange] — scaled over the buckets' EXTREMES
/// and not their means alone (FB-74) — plus one this axis alone has:
///
/// 🔴 **The window ALWAYS contains zero.** Current is the only plotted quantity
/// whose sign carries meaning: `packFlowOf` reads negative as discharging and
/// positive as charging (`power_flow.dart:159`), and the moment the sign FLIPS
/// is the one thing a curve can say that a column of numbers cannot. An axis
/// fitted to the data would push that crossing off the plot entirely on any run
/// that stayed on one side — a unit charging at 8…10 A would be drawn on a
/// window starting at 7.5 A, and the picture would be indistinguishable from
/// the same unit discharging at 8…10 A.
///
/// ⛔ And it is why `abs()` is not an option here (design 0030 §3.2 Q5, ruled
/// 2026-08-03): flattening the sign to dodge the crossing deletes exactly the
/// event the series exists to show. Nothing in this file calls `abs()` on a
/// current; keep it that way.
///
/// The 2 A floor is the wire quantum doubled — `0x2E` is 1 A per count
/// (`telemetry_decoder.current`, no division), so a window narrower than two
/// counts would magnify quantisation steps into apparent structure.
({double lo, double hi}) historyChartCurrentRange(List<HistoryBucket> buckets) {
  double? lo, hi;
  void see(double? v) {
    if (v == null) return;
    if (lo == null || v < lo!) lo = v;
    if (hi == null || v > hi!) hi = v;
  }

  for (final b in buckets) {
    see(b.avgAmpere);
    see(b.minAmpere);
    see(b.maxAmpere);
  }
  var alo = (lo ?? 0) - 0.5, ahi = (hi ?? 0) + 0.5;
  // 🔴 Straddle zero unconditionally — see the doc above. A run that never
  // changed sign still has to be drawn against the line it never crossed.
  if (alo > 0) alo = 0;
  if (ahi < 0) ahi = 0;
  if (ahi - alo < 2) {
    // Symmetric expansion about the midpoint. Because the window already
    // contains zero, widening it about its own centre can only widen it
    // FURTHER past zero on both sides — the straddle survives this branch.
    final m = (alo + ahi) / 2;
    alo = m - 1;
    ahi = m + 1;
  }
  return (lo: alo, hi: ahi);
}

/// Whether the left axis MAY carry current at all, and if not, why not —
/// design 0085 §3.4 / §1.5 (FB-101, S3).
///
/// 🔴 **Two different refusals, and they must not be collapsed into one
/// "no current" branch.** The ruling (Q4 ③) is that the toggle is disabled AND
/// the reason is stated, and the two reasons say opposite things about the
/// data:
///
///  * [capacitor] — the unit reports a constant `0.0 A` on `0x2E` that it
///    cannot actually measure. Already refused in three other places (the list
///    row via `historyCurrentBit`, the CSV column via `history_repo`, the live
///    track via `dashboard_cards`); this is the fourth, worded from the SAME
///    string so the four cannot drift.
///  * [mixedScope] — the scope is "all devices", so there is no single family
///    to ask. `queryBuckets` groups by TIME and not by `device_id`, and the two
///    families sign current the opposite way round (§1.6): a battery
///    discharging at −3 A and a power bank discharging at +3 A average to 0 A,
///    which would be drawn as "at rest". That is not an error bar — it is two
///    contradictory conventions added together.
///
/// ⛔ Neither may be drawn as a flat line at zero, and neither may be silent:
/// a toggle that does nothing reads as broken (design 0074 Q3's shape).
enum HistoryChartCurrentGate {
  /// Current may be plotted, and its direction wording comes from
  /// [historyChartCurrentDirectionLabel].
  available,

  /// A super-capacitor: `0x2E` is a placeholder, not a measurement.
  capacitor,

  /// "All devices": no single family, and the families disagree about sign.
  mixedScope,
}

/// May this chart show current, for a scope whose class is [cls]?
///
/// 🔑 **`null` is the "all devices" scope, and it is NOT the same as
/// [ProductClass.unknown].** `deviceClassFor` answers `unknown` for a single
/// saved unit nobody has classified yet — one family, merely unnamed, whose
/// stored amperes are still one convention and are still worth plotting (the
/// list row does exactly this: `historyCurrentBit` prints the signed number
/// with no direction word). A null class is the structurally different case:
/// several units at once, and no answer that could be true for all of them.
HistoryChartCurrentGate historyChartCurrentGate(ProductClass? cls) =>
    switch (cls) {
      null => HistoryChartCurrentGate.mixedScope,
      ProductClass.supercapacitor => HistoryChartCurrentGate.capacitor,
      _ => HistoryChartCurrentGate.available,
    };

/// The sentence shown beside a disabled toggle, or null when there is nothing
/// to explain — design 0085 §0.3.
///
/// 🔴 **§0.3 is a three-way split that is very easy to get wrong**, so it is
/// resolved once, here:
///
///  * "the history page shows averages" — ⛔ **NOT SHOWN**. Q2 ① / Q3 ruled it
///    out of this case entirely; the min–max band is what carries it now. Do
///    not add it back here because it "would fit".
///  * "all devices, so no current" — ✅ shown, and it is the ONLY string this
///    design adds. It has to say the SCOPE caused it: a reader told merely
///    "no current" concludes the app failed to record any, which is a second
///    falsehood on top of the one being avoided.
///  * "this class reports a constant 0 A" — ✅ shown, from the EXISTING
///    `capacitorChartNoCurrentNote`. Nothing new is coined for it.
String? historyChartCurrentGateNote(
  AppLocalizations l10n,
  HistoryChartCurrentGate gate,
) =>
    switch (gate) {
      HistoryChartCurrentGate.available => null,
      HistoryChartCurrentGate.capacitor => l10n.capacitorChartNoCurrentNote,
      HistoryChartCurrentGate.mixedScope =>
        l10n.historyChartAllDevicesNoCurrentNote,
    };

/// How to word which half of the current axis is which — design 0056, and the
/// 🔵 **S3 seam** for design 0085, now threaded.
///
/// 🔴 **Direction is per FAMILY, and the two families are OPPOSITE.** Pack
/// units (battery / capacitor) decode `512 - u16` on `0x2E`, where negative is
/// discharging; power banks decode `0x4A − 0x49`, where POSITIVE is
/// discharging (`power_flow.dart:146` — "THE SIGN IS THE OPPOSITE"). Passing a
/// power bank the pack wording labels every charge as a discharge — silently,
/// on a picture that otherwise looks perfectly normal.
///
/// ⛔ **Two keys, not one with the words swapped at the call site**, for the
/// reason `power_flow.dart` gives for having two functions instead of one with
/// an `if (isPack)`: a wording change made for a car battery must not reach a
/// power bank. `historyCurrentBit` already keeps `packDirection*` and
/// `powerBankDirection*` apart for the same reason; this is the axis-key pair
/// beside them.
///
/// Null for [ProductClass.unknown] — the zero line is then drawn UNLABELLED.
/// A unit with no family has no convention to name, and naming one anyway is
/// FB-43's shape; it is also exactly what the list row does with an unknown
/// class (a signed number, no direction word). ⛔ Null is not "pick the pack
/// wording as a default": on a misfiled power bank that default is backwards.
String? historyChartCurrentDirectionLabel(
  AppLocalizations l10n,
  ProductClass? cls,
) =>
    switch (cls) {
      ProductClass.powerBank => l10n.powerBankTrackCurrentDirectionKey,
      ProductClass.smartBattery ||
      ProductClass.supercapacitor =>
        l10n.dashboardTrackCurrentDirectionKey,
      ProductClass.unknown || null => null,
    };

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
  // 🔵 design 0085 S2: which quantity the LEFT axis carries. Defaulted to
  // voltage so every test written before FB-101 keeps driving exactly the
  // painter it was written against.
  HistoryChartSeries series = HistoryChartSeries.voltage,
  String? currentDirectionLabel,
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
      series: series,
      currentDirectionLabel: currentDirectionLabel,
      vColor: accent.accent,
      tColor: accent.accentSecondary,
      grid: const Color(0xFF333333),
      text: const Color(0xFF888888),
    );

class HistoryTrendPainter extends CustomPainter {
  HistoryTrendPainter({
    required this.buckets,
    this.from,
    this.to,
    this.gapLabel,
    required this.tempUnit,
    required this.hasTemp,
    required this.multiDay,
    required this.bucketMs,
    required this.selected,
    this.series = HistoryChartSeries.voltage,
    this.currentDirectionLabel,
    required this.vColor,
    required this.tColor,
    required this.grid,
    required this.text,
  });

  final List<HistoryBucket> buckets;

  /// 🔵 The plotted WINDOW (design 0081 S3). Null ⇒ first/last bucket, which is
  /// what the embedded card wants; the landscape page passes what the user has
  /// panned to, so points can sit off both edges.
  final DateTime? from;
  final DateTime? to;

  /// 🔵 How to word a hole in the recording — design 0081 Q6 = C, landscape
  /// only. Null ⇒ hatch with no text (Q6 = B, the embedded card: 244 px of
  /// plot cannot hold the sentence).
  ///
  /// A callback rather than an [AppLocalizations]: this file draws, it does not
  /// know about locales, and keeping it that way is what lets the painter be
  /// tested without pumping anything.
  final String Function(Duration)? gapLabel;

  final TempUnit tempUnit;
  final bool hasTemp;
  final bool multiDay;
  final int bucketMs;
  final int? selected;

  /// 🔵 Which quantity the LEFT axis draws — design 0085 §3.1 案 B (FB-101).
  ///
  /// Temperature is untouched by this in both directions: it keeps the right
  /// axis, [hasTemp] still decides whether the right margin opens up, and its
  /// band and line are drawn from the same selectors as before. Only the left
  /// half switches, and it switches WHOLE — window, band, line, selected
  /// marker and the trailing value read-out all follow this one field, so
  /// there is no state in which the axis labels describe one quantity and the
  /// line plots another.
  final HistoryChartSeries series;

  /// Which half of the current axis is charge and which is discharge — null ⇒
  /// draw the zero line unlabelled.
  ///
  /// A plain string rather than an [AppLocalizations], for the same reason
  /// [gapLabel] is a callback: this file draws, it does not know about locales,
  /// and that is what keeps the painter testable without pumping a screen. The
  /// wording comes from [historyChartCurrentDirectionLabel] — 🔵 see there for
  /// why S3, not S2, is where it becomes per-family.
  final String? currentDirectionLabel;

  final Color vColor, tColor, grid, text;

  @override
  void paint(Canvas canvas, Size size) {
    final n = buckets.length;
    final g = HistoryChartGeometry(
        width: size.width,
        hasTemp: hasTemp,
        buckets: buckets,
        bucketMs: bucketMs,
        from: from,
        to: to);
    const left = HistoryChartGeometry.left,
        top = HistoryChartGeometry.top,
        bottom = HistoryChartGeometry.bottom;
    final right = g.right;
    final plotH = size.height - top - bottom;

    // Axis windows. FB-74: both are scaled to include the buckets' MIN/MAX, not
    // just their means — see [historyChartVoltageRange] for why an averaged
    // axis would clip the very thing the band below exists to show.
    //
    // 🔵 design 0085 S2: the LEFT window follows [series]; the right one does
    // not move, in either mode.
    final isCurrent = series == HistoryChartSeries.current;
    final vr = isCurrent
        ? historyChartCurrentRange(buckets)
        : historyChartVoltageRange(buckets);
    final vlo = vr.lo, vhi = vr.hi;
    final tr = historyChartTempRange(hasTemp ? buckets : const [], tempUnit);
    final tlo = tr.lo, thi = tr.hi;

    double xAt(int i) => g.xAt(i);
    double yV(double v) => top + plotH * (1 - (v - vlo) / (vhi - vlo));
    double yT(double v) => top + plotH * (1 - (v - tlo) / (thi - tlo));

    // 🔵 The left series in one place — design 0085 §1.3: `drawLine`/`drawBand`
    // were already generic over a selector, so switching quantity is a matter
    // of handing them different ones. ⛔ No `abs()` on the current: the sign is
    // the reading (design 0030 §3.2 Q5).
    double? leftAvg(HistoryBucket b) => isCurrent ? b.avgAmpere : b.avgPvlt;
    double? leftMin(HistoryBucket b) => isCurrent ? b.minAmpere : b.minPvlt;
    double? leftMax(HistoryBucket b) => isCurrent ? b.maxAmpere : b.maxPvlt;

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
      if (!g.gapAfter(i)) continue;
      final r = Rect.fromLTRB(xAt(i), top, xAt(i + 1), top + plotH);
      hatch(r);
      final label = gapLabel;
      if (label == null) continue;
      final tpx = TextPainter(
        text: TextSpan(
            text: label(Duration(
                milliseconds: buckets[i + 1].at.millisecondsSinceEpoch -
                    buckets[i].at.millisecondsSinceEpoch)),
            style: TextStyle(color: text, fontSize: 9.5)),
        textDirection: TextDirection.ltr,
      )..layout();
      // 🔴 **Auto-retreat, and it is not decoration** (design 0081 §3.2.3): a
      // label wider than its gap either overflows into the data on both sides
      // or gets clipped mid-word. Below the threshold the hatch alone says the
      // same thing, less precisely — which is the right trade when there is no
      // room to say it properly.
      if (tpx.width + 16 > r.width) continue;
      tpx.paint(canvas,
          Offset(r.center.dx - tpx.width / 2, top + plotH / 2 - 6));
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

    // 🔴 **The zero line, and only in current mode** — design 0085 §3.1 案 B.
    //
    // [historyChartCurrentRange] guarantees the window contains zero, so this
    // line is always inside the plot. It is what turns a curve into a reading:
    // without it, "the line went from up here to down there" says nothing about
    // whether the unit started charging, and the axis numbers alone make the
    // reader do the arithmetic. Drawn over the grid but under the series, in
    // the series' own colour at half strength, so it belongs to the left axis
    // rather than reading as a fourth trace (⛔ design 0085 §2: no new colours).
    if (isCurrent) {
      final zy = yV(0);
      canvas.drawLine(
          Offset(left, zy),
          Offset(size.width - right, zy),
          Paint()
            ..color = vColor.withValues(alpha: 0.55)
            ..strokeWidth = 1);
      // The direction key sits immediately above the line it describes —
      // design 0056 asked for "which half is which", and a legend parked in a
      // corner answers a different question. Clamped into the plot for the
      // case where zero lands against the top edge.
      final dir = currentDirectionLabel;
      if (dir != null) {
        tp(dir, left + 3, (zy - 11).clamp(top, top + plotH - 11));
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
    // 🔴 **The band is not optional, and least of all here** — design 0085
    // §3.3. Q2① / Q3 ruled out the "these are averages" sentence, so once the
    // left axis is showing current the band is the ONLY thing on screen saying
    // the line is a mean. On current it also carries a meaning voltage's band
    // does not: the wire quantum is 1 A per count, so the band's width IS "how
    // many integer counts this minute jumped between". ⛔ Do not make it a
    // setting, and do not drop it to unclutter the card.
    drawBand(leftMin, leftMax, yV, vColor);

    if (hasTemp) {
      drawLine((b) => b.avgTemp == null
          ? null
          : historyDisplayTemp(b.avgTemp!, tempUnit), yT, tColor);
    }
    drawLine(leftAvg, yV, vColor);

    // Emphasized markers at the selected bucket (over the series).
    if (sel != null && sel >= 0 && sel < n) {
      final b = buckets[sel];
      final sx = xAt(sel);
      final selAvg = leftAvg(b);
      if (selAvg != null) {
        final c = Offset(sx, yV(selAvg));
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

    // Latest left-series marker + value.
    //
    // 🔵 One decimal and an `A` in current mode — the same precision the list
    // row prints (`historyCurrentBit`), because design 0065 §6 R5 is that two
    // surfaces must not put different numbers on the same minute. ⛔ Not two
    // decimals: `0x2E` has no division, so the digits past the first come from
    // averaging, not from the instrument (design 0085 §1.8).
    for (var i = n - 1; i >= 0; i--) {
      final a = leftAvg(buckets[i]);
      if (a == null) continue;
      final lx = xAt(i), ly = yV(a);
      canvas.drawCircle(Offset(lx, ly), 3, Paint()..color = vColor);
      tp(isCurrent ? '${a.toStringAsFixed(1)}A' : '${a.toStringAsFixed(2)}V',
          lx - 2, ly - 16,
          rightAlign: true, c: vColor);
      break;
    }
  }

  @override
  bool shouldRepaint(covariant HistoryTrendPainter old) =>
      old.series != series ||
      old.currentDirectionLabel != currentDirectionLabel ||
      old.selected != selected ||
      old.buckets.length != buckets.length ||
      old.hasTemp != hasTemp ||
      old.tempUnit != tempUnit ||
      (buckets.isNotEmpty &&
          old.buckets.isNotEmpty &&
          old.buckets.last.at != buckets.last.at ||
      old.from != from ||
      old.to != to);
}
