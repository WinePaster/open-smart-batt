/// OpenSmartBatt — instrument gauge (mockup `buildGauge()` + `.ring`).
///
/// A 270° tick-ring dial with an amber value arc and pointer, faithfully
/// reproducing the mockup's hand-built SVG gauge in a [CustomPainter]. The
/// centre stack overlays a live value, an injectable caption and a sub-line.
///
/// Design 0001 §3.5 generalises the dial to TWO modes via named constructors:
///   * [PvltGauge.voltage] — a voltage domain `[min,max]` (pack: 8–16 V), which
///     preserves the original PVLT behaviour exactly; and
///   * [PvltGauge.percent] — a 0–100 % domain (power-bank SOC).
/// The dial itself is domain-agnostic: callers map their value to a 0..1
/// [fraction] and supply the centre-stack strings + unit.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Animated amber-tick gauge (generalised over voltage / percent domains).
///
/// The gauge's localized centre-stack strings ([caption], [subText]) are
/// resolved by the host and passed in, since the dial itself is drawn by a
/// context-free [CustomPainter].
class PvltGauge extends StatelessWidget {
  const PvltGauge({
    super.key,
    required this.value,
    required this.fraction,
    required this.caption,
    required this.subText,
    this.unit = 'V',
    this.fractionDigits = 2,
    this.size = 206,
  });

  /// Voltage-domain gauge (pack): fills [volts] across [min]..[max] volts. This
  /// is the ORIGINAL PVLT behaviour (default 8–16 V, 2 decimals, unit "V").
  factory PvltGauge.voltage({
    Key? key,
    required double? volts,
    double min = 8.0,
    double max = 16.0,
    required String caption,
    required String subText,
    double size = 206,
  }) =>
      PvltGauge(
        key: key,
        value: volts,
        fraction: voltageFraction(volts, min: min, max: max),
        caption: caption,
        subText: subText,
        unit: 'V',
        fractionDigits: 2,
        size: size,
      );

  /// Percent-mode gauge (power-bank SOC): fills [percent] across 0..100 %.
  factory PvltGauge.percent({
    Key? key,
    required num? percent,
    required String caption,
    required String subText,
    double size = 206,
  }) =>
      PvltGauge(
        key: key,
        value: percent?.toDouble(),
        fraction: percentFraction(percent),
        caption: caption,
        subText: subText,
        unit: '%',
        fractionDigits: 0,
        size: size,
      );

  /// The value shown in the centre, or null when unknown (reads `--`).
  final double? value;

  /// Gauge fill fraction 0..1 (caller maps its domain onto this).
  final double fraction;

  /// Centre caption line (e.g. "PVLT · Primary Voltage" or "SOC · Charge").
  final String caption;

  /// Sub-line under the caption (e.g. SOH / health / cell-voltage text).
  final String subText;

  /// Unit suffix rendered beside the value ("V" or "%").
  final String unit;

  /// Decimal places for the centre value (2 for volts, 0 for percent).
  final int fractionDigits;

  /// Dial diameter (mockup 206px).
  final double size;

  /// Pure fraction for a voltage domain — clamped 0..1. Unit-testable.
  static double voltageFraction(double? volts,
      {double min = 8.0, double max = 16.0}) {
    if (volts == null || max <= min) return 0;
    return ((volts - min) / (max - min)).clamp(0.0, 1.0);
  }

  /// Pure fraction for a 0..100 percent value — clamped 0..1. Unit-testable.
  static double percentFraction(num? percent) {
    if (percent == null) return 0;
    return (percent / 100.0).clamp(0.0, 1.0).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final f = fraction.clamp(0.0, 1.0);
    final colors = context.colors;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Animated arc + pointer sweep when the value changes.
          TweenAnimationBuilder<double>(
            tween: Tween(begin: f, end: f),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOut,
            builder: (context, value, _) => CustomPaint(
              size: Size.square(size),
              painter: _GaugePainter(value, colors),
            ),
          ),
          _CenterReadout(
            value: value,
            unit: unit,
            fractionDigits: fractionDigits,
            caption: caption,
            subText: subText,
            maxWidth: size * 0.66,
          ),
        ],
      ),
    );
  }
}

/// Centre value stack (mockup `.ring .val`).
class _CenterReadout extends StatelessWidget {
  const _CenterReadout({
    required this.value,
    required this.unit,
    required this.fractionDigits,
    required this.caption,
    required this.subText,
    required this.maxWidth,
  });

  final double? value;
  final String unit;
  final int fractionDigits;
  final String caption;
  final String subText;

  /// Inner-ring width the centre stack must stay within (so the value never
  /// collides with the tick ring at large dial sizes / high text scale).
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: maxWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Big value + amber unit (mockup `.num` / `.num .u`). FittedBox keeps
          // it inside the ring regardless of text scale / value width.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: RichText(
              text: TextSpan(
                text: value == null
                    ? '--'
                    : value!.toStringAsFixed(fractionDigits),
                style: AppTextStyles.gaugeValue(context),
                children: [
                  TextSpan(
                    text: ' $unit',
                    style: const TextStyle(
                      fontSize: 16,
                      color: AppColors.amber,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            caption,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 3,
              color: context.colors.muted,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            subText,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 1,
              color: AppColors.cyan,
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints the tick ring, value arc, pointer and hub (mockup `buildGauge`).
class _GaugePainter extends CustomPainter {
  const _GaugePainter(this.fraction, this.colors);

  /// 0..1 sweep fraction.
  final double fraction;

  /// Active neutral palette (so the dial repaints per theme).
  final AppPalette colors;

  // Geometry mirrors the mockup: 270° sweep starting at 135°.
  static const double _startDeg = 135;
  static const double _sweepDeg = 270;
  static const int _tickCount = 30;

  // Gauge greys derived from the neutral palette so the dial recolors with the
  // theme (track = hairline, major ticks = muted, minor ticks = stronger line).
  Color get _trackColor => colors.line;
  Color get _tickMajor => colors.muted;
  Color get _tickMinor => colors.line2;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final center = Offset(cx, cy);
    final r = size.width * 84 / 206; // mockup r=84 at 206px

    // Base track ring.
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = _trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Tick marks.
    for (var i = 0; i <= _tickCount; i++) {
      final a = (_startDeg + _sweepDeg * i / _tickCount) * math.pi / 180;
      final major = i % 5 == 0;
      final rl = major ? 12.0 : 7.0;
      final cos = math.cos(a);
      final sin = math.sin(a);
      final p1 = Offset(cx + cos * (r - 2), cy + sin * (r - 2));
      final p2 = Offset(cx + cos * (r - 2 - rl), cy + sin * (r - 2 - rl));
      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = major ? _tickMajor : _tickMinor
          ..strokeWidth = major ? 1.6 : 1.0,
      );
    }

    // Amber value arc (radius r+9).
    final ar = r + 9;
    final a0 = _startDeg * math.pi / 180;
    final sweep = _sweepDeg * fraction * math.pi / 180;
    if (sweep > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: ar),
        a0,
        sweep,
        false,
        Paint()
          ..color = AppColors.amber
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }

    // Pointer.
    final a1 = a0 + sweep;
    final pr = r - 16;
    final tip = Offset(cx + math.cos(a1) * pr, cy + math.sin(a1) * pr);
    canvas.drawLine(
      center,
      tip,
      Paint()
        ..color = AppColors.amber
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );

    // Hub.
    canvas.drawCircle(
      center,
      4,
      Paint()..color = colors.panel2,
    );
    canvas.drawCircle(
      center,
      4,
      Paint()
        ..color = AppColors.amber
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) =>
      oldDelegate.fraction != fraction || oldDelegate.colors != colors;
}
