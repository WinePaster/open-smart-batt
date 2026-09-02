/// OpenSmartBatt — what the live chart IS, shared by both of its shells.
///
/// 📦 EXTRACTED, NOT REWRITTEN (design 0093 §3.1). Every line below was private
/// to `live_trend_chart.dart` until 2026-09-02, when the full-screen shell
/// (`live_trend_chart_page.dart`) needed the same picture. It is here rather
/// than duplicated because FB-74 / design 0065 §6 R5 is the standing rule: one
/// unit drawn two ways is one unit nobody can check.
///
/// 🔑 The extraction covers BOTH halves of "the same picture":
///
///  * **how a track is drawn** — [TrendTrackPainter], its insets and its range
///    derivation;
///  * **what a track IS** — [chartTracksFor], the per-class list of series,
///    legends, colours and axis keys. That half was inside `dashboard_cards.dart`
///    and would have frozen the moment a second surface took a copy of it: a
///    power bank's secondary-voltage legend switches between 輸入 and 輸出 with
///    the live flow (design 0093 §4 Q6).
///
/// [TrendTrack.height] is the one value that is NOT shared verbatim: on a card
/// it is the track's height, on the full-screen shell it is its WEIGHT — see
/// [allocateTrackHeights].
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';

import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'display_modules.dart';
import 'power_flow.dart';

/// One stacked track: which series, how to label it, how to format its value.
class TrendTrack {
  const TrendTrack({
    required this.field,
    required this.label,
    required this.unit,
    required this.color,
    this.decimals = 0,
    this.spanZero = false,
    this.height = 74,
    this.minSpan = 1,
    this.directionKey,
  });

  final TrendField field;
  final String label;
  final String unit;
  final Color color;

  /// Decimal places for the axis and the live value.
  final int decimals;

  /// Force the Y range to include 0 and draw a zero rule.
  ///
  /// Set for signed current. A current axis that does not cross zero hides the
  /// one feature worth seeing — the moment the sign flips — by pushing it off
  /// the bottom of the plot.
  final bool spanZero;

  final double height;

  /// Smallest Y span to show. Without it, a reading that is flat to the
  /// millivolt fills the track with amplified noise.
  final double minSpan;

  /// What the two halves of a signed axis MEAN, e.g. 「＋充電 · −放電」.
  ///
  /// Only for a [spanZero] track, and only where the direction is established:
  /// it is a claim about the hardware, not decoration. Drawn under the plot
  /// rather than in the header row, because the header already holds a legend
  /// and a live value that fight for width on a 1x1 home tile (see
  /// [_TrackHeader]) — a third element there would ellipsise one of them.
  ///
  /// 🔴 It does NOT change the data. The 2026-08-03 ruling that the current
  /// track stays signed and zero-crossing (design 0030 §3.2 / §7 Q5) is
  /// untouched; that ruling's companion clause — "axis text says only 電流 A,
  /// never 充電／放電" — rested on the direction being unverified, which stopped
  /// being true on 2026-08-11 (`telemetry-decoding.md` §8.2). Design 0056 is
  /// the ruling that replaces it. `abs()` remains forbidden.
  final String? directionKey;
}


/// Each track's share of a height budget, as `Expanded` flex weights.
///
/// 🔵 design 0093 §4 Q3 (owner, 2026-09-02, 逐字「Q3:ok」). On a card each track
/// is [TrendTrack.height] pixels tall and that is the end of it; full screen in
/// landscape has a height budget instead, and dividing it EQUALLY would flatten
/// the one track that has a reason to be taller. The pack current track is 92
/// against everyone else's 74 because it is the only one that crosses zero —
/// its axis has to hold a sign change, not just a wiggle. So the ratio travels
/// and the total is what changes.
///
/// ⚠️ **Weights, not pixels — and that is a correction, not a preference.** The
/// first implementation computed pixel heights by subtracting the chrome (a
/// header row, its gaps, the direction key) from the available height using
/// measured-by-hand constants. Those constants were 16 px short and the column
/// overflowed on the first test that pumped it. `Expanded` asks the framework
/// what is actually left instead of predicting it, so the failure mode is gone
/// rather than tuned.
List<int> trackFlexWeights(List<TrendTrack> tracks) =>
    [for (final t in tracks) t.height.round()];

/// The tracks a class's live chart draws, resolved against the CURRENT sample.
///
/// 📦 EXTRACTED, NOT REWRITTEN (design 0093 §4 Q6). This was the body of
/// `dashboardCardFor`'s `chart` case, value for value; the judgement of that
/// claim is `watchface_ui_test.dart` and `product_ui_test.dart` passing without
/// modification.
///
/// 🔴 Called on every build, and it must be: a power bank's secondary-voltage
/// legend is derived from the live flow, so a caller that resolves this once and
/// keeps the list would end up with a chart labelled 輸入 while the unit
/// discharges. The full-screen shell therefore holds [tele], not a list.
List<TrendTrack> chartTracksFor(
  BuildContext context, {
  required DisplayModules modules,
  required bool isPowerBank,
  required CardTelemetry tele,
}) {
  final l10n = AppLocalizations.of(context);
  if (isPowerBank) {
    final flow = powerFlowOf(tele.current, portFlagsRaw: tele.portFlagsRaw);
    // A power bank's current has its direction spread over two registers —
    // 0x49 while charging, 0x4A while discharging — and since FB-46 both reach
    // `current` as one signed number. The track stays signed and zero-crossing,
    // and MUST: a sign flip mid-window is how a start-up load is recognised at
    // a glance, which no magnitude plot can show. Nothing here is
    // direction-switched.
    return [
      if (modules.hasTrack(TrendField.current))
        TrendTrack(
          field: TrendField.current,
          label: l10n.powerBankTrackCurrent,
          unit: 'A',
          color: context.accent.accentSecondary,
          decimals: 2,
          spanZero: true,
          // 🔵 design 0056 §9 Q1 ① (ruled 2026-08-27). This track was the LAST
          // signed current on screen with nothing saying which half is which —
          // and unexplained signs on a power bank are literally what FB-47 was
          // filed for.
          //
          // 🔴 Its OWN key, never `dashboardTrackCurrentDirectionKey`: a power
          // bank derives current from `0x4A − 0x49` where POSITIVE is
          // discharging, a pack from `0x2E` where negative is
          // (`power_flow.dart`: "THE SIGN IS THE OPPOSITE"). The pack key here
          // would be a precise, confident lie.
          directionKey: l10n.powerBankTrackCurrentDirectionKey,
          minSpan: 1,
          height: 92,
        ),
      if (modules.hasTrack(TrendField.svlt))
        TrendTrack(
          field: TrendField.svlt,
          // Direction-aware, exactly like the energy-path row's own voltage
          // label. The two are separate CARDS on the same page (design 0040
          // split the chart out of the readouts card), which makes this matter
          // more, not less: a legend reading "output voltage" a few centimetres
          // below a row reading "input" is self-contradictory on one screen.
          label: flow == PowerFlow.charging
              ? l10n.powerBankTrackInput
              : l10n.powerBankTrackOutput,
          unit: 'V',
          color: context.accent.accent,
          decimals: 2,
          minSpan: 0.5,
        ),
      if (modules.hasTrack(TrendField.soc))
        TrendTrack(
          field: TrendField.soc,
          label: l10n.powerBankTrackSoc,
          unit: '%',
          color: AppSemantics.good,
          minSpan: 5,
        ),
    ];
  }
  // Same class gate as the current readout: a capacitor streams 0x2E as a
  // constant 0.0 A, so a current track would draw a flat line at zero and read
  // as "measured 0 A" — worse than leaving it out. Voltage and temperature do
  // move on a capacitor, so the chart is still offered, just without that track.
  return [
    if (modules.hasTrack(TrendField.current))
      TrendTrack(
        field: TrendField.current,
        label: l10n.dashboardTrackCurrent,
        unit: 'A',
        color: context.accent.accentSecondary,
        // Signed, and the axis must cross zero (2026-08-03 ruling, design 0030
        // §3.2: `abs()` was explicitly rejected — flattening the track would
        // erase the reversal that makes a cranking load recognisable, which is
        // the one thing a curve shows that a number cannot).
        //
        // 🔴 What DID change (design 0056): the axis now says which half is
        // which. Until 2026-08-11 it deliberately did not, because 0x2E's
        // direction was unverified and a label would have smuggled out an
        // unsettled conclusion. `telemetry-decoding.md` §8.2 now states it —
        // negative = discharge, positive = charge — so the silence has lost its
        // reason, and an unexplained sign is exactly what FB-47 was reported for.
        spanZero: true,
        directionKey: l10n.dashboardTrackCurrentDirectionKey,
        minSpan: 10,
        height: 92,
      ),
    if (modules.hasTrack(TrendField.pvlt))
      TrendTrack(
        field: TrendField.pvlt,
        label: l10n.dashboardTrackPvlt,
        unit: 'V',
        color: context.accent.accent,
        decimals: 2,
        minSpan: 0.5,
      ),
    // A capacitor has one track MORE than a battery, not fewer.
    if (modules.hasTrack(TrendField.svlt))
      TrendTrack(
        field: TrendField.svlt,
        label: l10n.capacitorTrackSvlt,
        unit: 'V',
        color: context.accent.accentSecondary,
        decimals: 2,
        minSpan: 0.5,
      ),
    if (modules.hasTrack(TrendField.temperature))
      TrendTrack(
        field: TrendField.temperature,
        label: l10n.dashboardTrackTemperature,
        unit: '°C',
        color: AppSemantics.good,
        minSpan: 4,
      ),
  ];
}

/// Track label on the left, latest value on the right.
class TrendTrackHeader extends StatelessWidget {
  const TrendTrackHeader({super.key, required this.track, required this.buffer});

  final TrendTrack track;
  final TrendSource buffer;

  @override
  Widget build(BuildContext context) {
    double? latest;
    for (var i = buffer.length - 1; i >= 0; i--) {
      final v = buffer.valueAt(track.field, i);
      if (v.isFinite) {
        latest = v;
        break;
      }
    }
    // 🔴 Both sides `Flexible`, the LABEL ellipsising first.
    //
    // A legend and its latest value at opposite ends of a row need ~200 px on
    // a pack ("MAIN CURRENT" + "-29.00 A"); a 1x1 home tile on a 320 dp phone
    // gives ~120, and the difference was a striped RenderFlex bar across the
    // top of the chart. Surfaced by design 0051's editor preview — the first
    // screen that draws a real chart at 1x1 — but reachable on the live home
    // page since design 0046 put the chart on the grid.
    //
    // The value is `flex: 0` so it is never the one that loses characters: a
    // truncated NUMBER is a wrong reading, while a truncated legend is still
    // recognisable from the track's colour and position.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            track.label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.label(context),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          flex: 0,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              latest == null
                  ? '--'
                  : '${latest.toStringAsFixed(track.decimals)} ${track.unit}',
              maxLines: 1,
              softWrap: false,
              style: AppTextStyles.mono(context).copyWith(color: track.color),
            ),
          ),
        ),
      ],
    );
  }
}

class TrendTrackPainter extends CustomPainter {
  TrendTrackPainter({
    required this.buffer,
    required this.track,
    required this.revision,
    required this.gridColor,
    required this.axisColor,
  });

  final TrendSource buffer;
  final TrendTrack track;
  final int revision;
  final Color gridColor;
  final Color axisColor;

  /// Plot insets. Shared so the two shells cannot drift apart by a pixel —
  /// design 0093 §3.1 (FB-74 / design 0065 §6 R5: one unit, two pictures).
  static const double padLeft = 38, padRight = 8, padTop = 8, padBottom = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final range = buffer.rangeOf(track.field);
    final firstMs = buffer.firstMs, lastMs = buffer.lastMs;
    if (range == null || firstMs == null || lastMs == null) return;

    var lo = range.min, hi = range.max;
    if (track.spanZero) {
      lo = math.min(lo, 0);
      hi = math.max(hi, 0);
    }
    if (hi - lo < track.minSpan) {
      final mid = (hi + lo) / 2;
      lo = mid - track.minSpan / 2;
      hi = mid + track.minSpan / 2;
    }
    final pad = (hi - lo) * 0.12;
    lo -= pad;
    hi += pad;

    // A parked link makes lastMs == firstMs; a zero denominator would put every
    // point at the same x and draw nothing.
    final tSpan = math.max(lastMs - firstMs, 1.0);
    final plotW = size.width - padLeft - padRight;
    final plotH = size.height - padTop - padBottom;
    double x(double ms) => padLeft + (ms - firstMs) / tSpan * plotW;
    double y(double v) => padTop + (1 - (v - lo) / (hi - lo)) * plotH;

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final value = lo + (hi - lo) * i / 2;
      final gy = y(value).roundToDouble() + 0.5;
      canvas.drawLine(Offset(padLeft, gy), Offset(size.width - padRight, gy), grid);
      _label(canvas, value.toStringAsFixed(track.decimals), padLeft - 4, gy);
    }
    if (track.spanZero && lo < 0 && hi > 0) {
      _dashedZero(canvas, size, y(0).roundToDouble() + 0.5);
    }

    final path = Path();
    var started = false;
    Offset? last;
    for (var i = 0; i < buffer.length; i++) {
      final v = buffer.valueAt(track.field, i);
      if (!v.isFinite) continue; // a gap, not a zero
      final p = Offset(x(buffer.timeAt(i)), y(v));
      started ? path.lineTo(p.dx, p.dy) : path.moveTo(p.dx, p.dy);
      started = true;
      last = p;
    }
    if (!started || last == null) return;

    final fill = Path.from(path)
      ..lineTo(last.dx, size.height - padBottom)
      ..lineTo(padLeft, size.height - padBottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [track.color.withValues(alpha: 0.30), track.color.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, padTop, size.width, plotH)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = track.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(last, 3.2, Paint()..color = track.color);
  }

  void _dashedZero(Canvas canvas, Size size, double gy) {
    final paint = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    for (var dx = padLeft; dx < size.width - padRight; dx += 6) {
      canvas.drawLine(
          Offset(dx, gy), Offset(math.min(dx + 3, size.width - padRight), gy), paint);
    }
  }

  void _label(Canvas canvas, String text, double right, double centerY) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: axisColor,
          fontSize: 10,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(right - tp.width, centerY - tp.height / 2));
  }

  @override
  bool shouldRepaint(TrendTrackPainter old) =>
      old.revision != revision ||
      old.track != track ||
      old.gridColor != gridColor;
}
