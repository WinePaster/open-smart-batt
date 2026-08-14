/// OpenSmartBatt — industrial panel card (mockup `.card`).
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
    this.headingTrailing,
    required this.child,
    this.padding = AppTheme.cardPadding,
  });

  /// Uppercase section title (mockup `.card h3`). Null hides the header.
  final String? heading;

  /// Amber leading icon for the header.
  final IconData? headingIcon;

  /// Control parked at the right end of the header rule, after the fade.
  ///
  /// For a control that switches how THIS card presents its own contents. A
  /// control that acts on the device belongs in the body, where it reads as an
  /// action rather than a view option.
  ///
  /// ⚠️ No caller passes one today. Its only user was the readouts card's
  /// numbers/chart toggle, retired by design 0034 Phase 1 (design 0040 §3.4):
  /// once the chart became a card of its own, a per-card view switch was a
  /// second, weaker mechanism for a question the watchface already answers.
  /// The slot is kept because [CardHeading] still renders it and the layout
  /// (fade rule, then the control) is the part that would be hard to
  /// reconstruct — not because a new one is expected.
  final Widget? headingTrailing;

  /// Card body.
  final Widget child;

  /// Inner padding (mockup default 15px).
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // 🔴 Read from a SCOPE, not from the theme (design 0054). With no scope this
    // is `standard`, which is what every card outside the home grid gets — the
    // settings screen must not lose its frames because somebody chose `minimal`
    // for their home page. See `card_style.dart`.
    final shell = context.cardShellTokens;
    return Container(
      margin: EdgeInsets.only(bottom: shell.gapBelow),
      child: CustomPaint(
        foregroundPainter: shell.cornerTicks
            ? CornerTicksPainter(colors.line2, shell.radius)
            : null,
        child: Container(
          decoration: BoxDecoration(
            color: shell.filled ? colors.panel : null,
            borderRadius: BorderRadius.circular(shell.radius),
            border: shell.bordered
                ? Border.all(color: colors.line)
                : (shell.underlined
                    ? Border(bottom: BorderSide(color: colors.line))
                    : null),
          ),
          padding: context.scaleCardPadding(padding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (heading != null) ...[
                CardHeading(
                  text: heading!,
                  icon: headingIcon,
                  trailing: headingTrailing,
                  rule: shell.headingRule,
                ),
                SizedBox(height: shell.headingGap),
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
  const CardHeading({
    super.key,
    required this.text,
    this.icon,
    this.trailing,
    this.rule = true,
  });

  final String text;
  final IconData? icon;

  /// Optional control after the fade rule (see [IndustrialCard.headingTrailing]).
  final Widget? trailing;

  /// Whether to draw the fading rule after the label (design 0054: the `dense`
  /// shell drops it). The label KEEPS its `Flexible`/ellipsis either way — the
  /// rule going away must not turn an overlong heading into an overflow bar.
  final bool rule;

  /// How much of the row the fade rule reserves, drawn or not.
  ///
  /// A FIXED width, and that is the whole point — see [build]. Held the same
  /// with and without the rule so that dropping it cannot re-flow the row or
  /// move [trailing].
  static const double ruleWidth = 28;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: AppColors.amber),
          const SizedBox(width: 7),
        ],
        // 🔴 Flexible + ellipsis. A heading is a LABEL, so losing its tail is
        // the correct failure — losing the card to a striped overflow bar is
        // not. At 1x1 on a 320 dp phone a tile is ~150 px and
        // "PER-CELL VOLTAGE DVOL" needs ~210, so this overflowed by 62 px on
        // every such card, waiting tiles included. Surfaced by design 0051's
        // editor preview, which is the first screen that renders these cards
        // at 1x1 with nothing connected; the same shape as the `Flexible` the
        // readout tile's own label has carried since design 0037.
        //
        // 🔑 And it is the ONLY flexible child of this row, deliberately. The
        // rule used to be an `Expanded` beside it, both at flex 1, which capped
        // the label at HALF the space left over: `RenderFlex` divides the free
        // space by the flex factors before it lays a flexible child out, and
        // what a `loose` child leaves unused is not handed back to a `tight`
        // one. On a 320 dp phone that was ~44 dp of label on a 1x1 tile —
        // "PER-CELL VOLTAGE DVOL" reduced to about four characters — and it
        // truncated even on a full-width card. So the label is measured against
        // everything that is left, and the rule takes a fixed slice instead.
        Flexible(
          child: Text(
            text.toUpperCase(),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.cardHeading(context),
          ),
        ),
        const SizedBox(width: 7),
        // Same width either way, so the heading row is the same width and the
        // trailing slot lands in the same place with or without the rule.
        SizedBox(
          width: ruleWidth,
          child: rule ? const _FadeRule() : null,
        ),
        if (trailing != null) ...[
          const SizedBox(width: 7),
          trailing!,
        ],
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
///
/// Public only so [tickSegments] can be tested; treat it as internal to
/// [IndustrialCard].
class CornerTicksPainter extends CustomPainter {
  const CornerTicksPainter(this.tickColor, this.cornerRadius);

  /// Corner-tick stroke color (neutral `line2`).
  final Color tickColor;

  /// The card's corner radius. The ticks start where the curve ENDS.
  ///
  /// These came from the CSS mockup's `.card::before/::after`, which drew them
  /// at the raw rect corners. Ported literally they landed at (0,0) and
  /// (w,h) — outside a 12px rounded edge — so every card showed a stray square
  /// bracket floating past its own curve. That is the "some blocks still have
  /// square corners" reported after v0.6.9: the card was round, the decoration
  /// on top of it was not.
  final double cornerRadius;

  static const double _len = 8;

  /// The four tick segments, as `(from, to)` pairs.
  ///
  /// Pulled out of [paint] so the geometry is testable: the bug this fixes was
  /// invisible to both grep (the ticks are drawn, not styled) and to the test
  /// suite (nothing asserted where they land). A pure function can be pinned.
  @visibleForTesting
  static List<(Offset, Offset)> tickSegments(Size size, double radius) {
    final r = radius;
    return [
      // Top-left: each tick starts tangent to the corner arc and runs along
      // the straight edge, so it reads as part of the outline, not an overhang.
      (Offset(r, 0), Offset(r + _len, 0)),
      (Offset(0, r), Offset(0, r + _len)),
      // Bottom-right: mirrored.
      (Offset(size.width - r, size.height),
          Offset(size.width - r - _len, size.height)),
      (Offset(size.width, size.height - r),
          Offset(size.width, size.height - r - _len)),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = tickColor.withValues(alpha: 0.7)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final (from, to) in tickSegments(size, cornerRadius)) {
      canvas.drawLine(from, to, p);
    }
  }

  @override
  bool shouldRepaint(covariant CornerTicksPainter oldDelegate) =>
      oldDelegate.tickColor != tickColor ||
      oldDelegate.cornerRadius != cornerRadius;
}
