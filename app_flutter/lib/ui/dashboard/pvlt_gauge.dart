/// Open-RCE-Batt — PVLT instrument gauge (mockup `buildGauge()` + `.ring`).
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
class PvltGauge extends StatelessWidget {
  const PvltGauge({
    super.key,
    required this.pvlt,
    required this.fraction,
    this.sohBucket,
    this.size = 206,
  });

  /// Primary voltage in volts, or null when unknown (gauge reads `--`).
  final double? pvlt;

  /// Gauge fill fraction 0..1 across the 8.0–16.0 V display range.
  final double fraction;

  /// SOH percentage bucket for the cyan sub-line, or null.
  final int? sohBucket;

  /// Dial diameter (mockup 206px).
  final double size;

  @override
  Widget build(BuildContext context) {
    final f = fraction.clamp(0.0, 1.0);
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
              painter: _GaugePainter(value),
            ),
          ),
          _CenterReadout(pvlt: pvlt, sohBucket: sohBucket),
        ],
      ),
    );
  }
}

/// Centre value stack (mockup `.ring .val`).
class _CenterReadout extends StatelessWidget {
  const _CenterReadout({required this.pvlt, required this.sohBucket});

  final double? pvlt;
  final int? sohBucket;

  @override
  Widget build(BuildContext context) {
    final soh = sohBucket;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Big value + amber unit (mockup `.num` / `.num .u`).
        RichText(
          text: TextSpan(
            text: pvlt == null ? '--' : pvlt!.toStringAsFixed(2),
            style: AppTextStyles.gaugeValue,
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
        const SizedBox(height: 7),
        const Text(
          'PVLT · 主電壓',
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 3,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          soh == null ? 'SOH --' : 'SOH $soh% · 健康${_sohLabel(soh)}',
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 1,
            color: AppColors.cyan,
          ),
        ),
      ],
    );
  }

  static String _sohLabel(int soh) {
    if (soh >= 80) return '良好';
    if (soh >= 50) return '普通';
    return '衰退';
  }
}

/// Paints the tick ring, value arc, pointer and hub (mockup `buildGauge`).
class _GaugePainter extends CustomPainter {
  const _GaugePainter(this.fraction);

  /// 0..1 sweep fraction.
  final double fraction;

  // Geometry mirrors the mockup: 270° sweep starting at 135°.
  static const double _startDeg = 135;
  static const double _sweepDeg = 270;
  static const int _tickCount = 30;

  // Gauge-internal greys from the mockup SVG (not part of the shared palette).
  static const Color _trackColor = Color(0xFF222932);
  static const Color _tickMajor = Color(0xFF5A6678);
  static const Color _tickMinor = Color(0xFF333B46);

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
      Paint()..color = AppColors.panel2,
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
      oldDelegate.fraction != fraction;
}
