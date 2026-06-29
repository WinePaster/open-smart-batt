/// Open-RCE-Batt — industrial panel card (mockup `.card`).
///
/// Flat panel, thin frame, with the mockup's L-shaped corner ticks
/// (`.card::before` / `.card::after`) and an optional section header
/// (`.card h3`: amber icon, uppercase muted label, fading rule line).
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// A bordered panel with corner ticks and an optional heading.
class IndustrialCard extends StatelessWidget {
  const IndustrialCard({
    super.key,
    this.heading,
    this.headingIcon,
    required this.child,
    this.padding = AppTheme.cardPadding,
  });

  /// Uppercase section title (mockup `.card h3`). Null hides the header.
  final String? heading;

  /// Amber leading icon for the header.
  final IconData? headingIcon;

  /// Card body.
  final Widget child;

  /// Inner padding (mockup default 15px).
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      child: CustomPaint(
        foregroundPainter: _CornerTicksPainter(colors.line2),
        child: Container(
          decoration: BoxDecoration(
            color: colors.panel,
            borderRadius: BorderRadius.circular(AppTheme.radius),
            border: Border.all(color: colors.line),
          ),
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (heading != null) ...[
                CardHeading(text: heading!, icon: headingIcon),
                const SizedBox(height: 13),
              ],
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Section header row (mockup `.card h3` + `.hl` fading rule).
class CardHeading extends StatelessWidget {
  const CardHeading({super.key, required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: AppColors.amber),
          const SizedBox(width: 7),
        ],
        Text(text.toUpperCase(), style: AppTextStyles.cardHeading(context)),
        const SizedBox(width: 7),
        const Expanded(child: _FadeRule()),
      ],
    );
  }
}

/// The `.hl` gradient rule: 1px line fading from the neutral line color to
/// transparent.
class _FadeRule extends StatelessWidget {
  const _FadeRule();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [context.colors.line, Colors.transparent],
        ),
      ),
    );
  }
}

/// Draws the two L-shaped corner ticks (mockup `.card::before/::after`).
class _CornerTicksPainter extends CustomPainter {
  const _CornerTicksPainter(this.tickColor);

  /// Corner-tick stroke color (neutral `line2`).
  final Color tickColor;

  static const double _len = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = tickColor.withValues(alpha: 0.7)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    // Top-left: top + left edges.
    canvas.drawLine(Offset.zero, const Offset(_len, 0), p);
    canvas.drawLine(Offset.zero, const Offset(0, _len), p);

    // Bottom-right: bottom + right edges.
    final br = Offset(size.width, size.height);
    canvas.drawLine(br, Offset(size.width - _len, size.height), p);
    canvas.drawLine(br, Offset(size.width, size.height - _len), p);
  }

  @override
  bool shouldRepaint(covariant _CornerTicksPainter oldDelegate) =>
      oldDelegate.tickColor != tickColor;
}
