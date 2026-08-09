/// OpenSmartBatt — the dashed outline that means "something can go here".
///
/// One painter, two callers, and that is deliberate. It draws the home
/// editor's empty half-slot (`home_editor_page.dart`, design 0049 Q2) and the
/// same slot inside the editor's tutorial diagram (`home_editor_tutorial.dart`,
/// design 0053).
///
/// The project already has the rule and the reason: [GForceBallPainter] is
/// shared between the G card and the calibration wizard because "a preview
/// drawn by a second implementation could agree with the card today and drift
/// tomorrow". A tutorial is exactly that kind of preview — a picture claiming
/// to be the screen — so a second dash pattern here would be a picture that
/// slowly stops being true.
library;

import 'package:flutter/material.dart';

/// A rounded-rect outline drawn as 5 px dashes with 5 px gaps.
class DashedBorderPainter extends CustomPainter {
  const DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
            metric.extractPath(d, (d + 5).clamp(0, metric.length)), paint);
        d += 10;
      }
    }
  }

  @override
  bool shouldRepaint(DashedBorderPainter old) => old.color != color;
}
