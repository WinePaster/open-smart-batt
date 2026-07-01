/// OpenSmartBatt — PVLT instrument gauge (mockup `buildGauge()` + `.ring`).
///
/// A 270° tick-ring dial with an amber value arc and pointer, faithfully
/// reproducing the mockup's hand-built SVG gauge in a [CustomPainter]. The
/// centre stack overlays the live PVLT value, the "PVLT · 主電壓" label, an
/// SOH sub-line and the 8.0–16.0 V range caption.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Animated amber-tick gauge for the primary voltage (PVLT).
///
/// The gauge's localized centre-stack strings ([pvltLabel], [sohText]) are
/// resolved by the host (see [DashboardPage]/`_LiveDashboard`) and passed in,
/// since the dial itself is drawn by a context-free [CustomPainter].
class PvltGauge extends StatelessWidget {
  const PvltGauge({
    super.key,
    required this.pvlt,
    required this.fraction,
    required this.pvltLabel,
    required this.sohText,
    this.size = 206,
  });

  /// Primary voltage in volts, or null when unknown (gauge reads `--`).
  final double? pvlt;

  /// Gauge fill fraction 0..1 across the 8.0–16.0 V display range.
  final double fraction;

  /// Localized "PVLT · Primary Voltage" caption (resolved in the host).
  final String pvltLabel;

  /// Localized SOH sub-line (e.g. "SOH 92% · Health Good" or "SOH --"),
  /// resolved in the host where a [BuildContext] is available.
  final String sohText;

  /// Dial diameter (mockup 206px).
  final double size;

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
            pvlt: pvlt,
            pvltLabel: pvltLabel,
            sohText: sohText,
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
    required this.pvlt,
    required this.pvltLabel,
    required this.sohText,
    required this.maxWidth,
  });

  final double? pvlt;
  final String pvltLabel;
  final String sohText;

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
                text: pvlt == null ? '--' : pvlt!.toStringAsFixed(2),
                style: AppTextStyles.gaugeValue(context),
                children: const [
                  TextSpan(
                    text: ' V',
                    style: TextStyle(
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
            pvltLabel,
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
            sohText,
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
