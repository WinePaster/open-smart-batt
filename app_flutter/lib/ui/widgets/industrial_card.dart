/// OpenSmartBatt — industrial panel card (mockup `.card`).
///
/// Flat panel, thin frame, with the mockup's L-shaped corner ticks
/// (`.card::before` / `.card::after`) and an optional section header
/// (`.card h3`: amber icon, uppercase muted label, fading rule line).
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'card_device_scope.dart';

/// A bordered panel with corner ticks and an optional heading.
class IndustrialCard extends StatelessWidget {
  const IndustrialCard({
    super.key,
    this.heading,
    this.headingIcon,
    this.headingTrailing,
    this.onHeadingTap,
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

  /// Makes the whole heading row a button — design 0089 (FB-103).
  ///
  /// 🔑 **The heading, not an icon beside it.** FB-103 is what happens when a
  /// chart that can draw two things is titled after one of them: the title
  /// answers the reader's question before they ever look for a control. Making
  /// the title itself the control means it can never name something the card is
  /// not drawing, and it is the largest text on the card, so it cannot be the
  /// thing nobody found (FB-70).
  ///
  /// Null ⇒ an ordinary, inert heading. ⛔ **Pass null rather than a no-op
  /// callback** when the switch is unavailable: a control that is visibly a
  /// control and does nothing is FB-64.
  final VoidCallback? onHeadingTap;

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
    // Which unit this card is about, when the surface said so (home grid only —
    // `card_device_scope.dart`). Read only when there IS a heading: the device
    // line lives inside the heading block, so a headingless card has nowhere to
    // put it and must not take a dependency on the scope either.
    final device = heading == null ? null : context.cardDeviceLabel;
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
          // Consumed ONCE. Republishing null means a card nested inside a card
          // cannot repeat the unit's name — see `card_device_scope.dart`.
          child: CardDeviceScope(
            deviceLabel: null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (heading != null) ...[
                  CardHeading(
                    text: heading!,
                    icon: headingIcon,
                    trailing: headingTrailing,
                    onTap: onHeadingTap,
                    rule: shell.headingRule,
                    device: device,
                  ),
                  SizedBox(height: shell.headingGap),
                ],
                child,
              ],
            ),
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
    this.device,
    this.onTap,
  });

  final String text;
  final IconData? icon;

  /// design 0089 — see [IndustrialCard.onHeadingTap]. Null keeps the heading
  /// inert, which is every surface but the history chart card.
  final VoidCallback? onTap;

  /// The unit this card is about, drawn ABOVE [text] (owner ruling 2026-08-15).
  /// Null — every surface but the home grid — keeps the single-row heading.
  ///
  /// ## 🔴 Why the device goes on top and the module underneath
  ///
  /// It looks arbitrary and it is not; the reverse order does not work. The
  /// heading row spends a FIXED 55 px before the label gets a pixel — icon 13,
  /// two 7 px gaps, and [ruleWidth] 28 — so on a 320 dp phone a 1x1 tile leaves
  /// the label **60 px**. 「分串電壓 DVOL」 needs ~90, which is why [build]'s
  /// ellipsis was already firing on that tile BEFORE this feature existed.
  ///
  /// 🔵 FB-99 (2026-08-24) dropped the trailing 「 DVOL」 from that heading, and
  /// the Chinese label now clears the 60 px row: measured with
  /// `card_heading_width_test.dart`'s own `labelWidth()`, 「分串電壓」 lays out at
  /// **50.0 px** natural against a **60 px** budget, where 「分串電壓 DVOL」 needed
  /// **112.5 px** and was ellipsised to 58.0. ⚠️ Those are TEST-FONT numbers —
  /// the fixed-advance test font is wider per character than the proportional
  /// font a phone resolves, so this says the budget stopped being the binding
  /// constraint in that harness, NOT that a real device never truncates.
  /// English is unchanged in kind: 'Per-Cell Voltage' still needs 200.0 px and
  /// is still cut on a 1x1 tile — but it now fits the full-width 1x2 card
  /// whole (200.0 vs a 205 px budget; 'Per-Cell Voltage DVOL' needed 262.5).
  /// ⛔ The reasoning above is NOT retracted: the second line is still what
  /// makes the module name fit in English, and on a 1x1 tile it still is.
  ///
  /// The second line is a plain [Text]: no icon, no rule, so it takes the whole
  /// 115 px inner width. Putting the MODULE there is what makes the module name
  /// fit — for the first time. Putting the device there instead would leave the
  /// module name in the 60 px row and change nothing.
  ///
  /// That is also the answer to 「單行加前綴」, which is what was originally
  /// asked for: the ellipsis eats the TAIL, so 「1328 分串電壓 DVOL」 truncates to
  /// 「1328 分串電…」 — the request was to tell two units apart and the cost would
  /// have been not being able to tell two CARDS apart. `mockups/
  /// fb-20260814-001-r1-module-card-device-name.html` renders all five forms at
  /// true device widths and measures each one.
  ///
  /// ⚠️ NOT `toUpperCase()`d, unlike [text]. This is a name the user typed
  /// (FB-61 makes it free-form, empty included); shouting it back is how
  /// `MY CAR BATTERY` happens to someone who wrote `My car battery`.
  final String? device;

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
    final row = _tappable(context, _row(context));
    final d = device;
    if (d == null) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        const SizedBox(height: 3),
        // The module name, with the FULL inner width — see [device]. No
        // `Flexible` needed: this is the only child of its row, so the ellipsis
        // fires against everything the card has rather than against what the
        // icon and the rule left over.
        Text(
          text.toUpperCase(),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.cardHeading(context),
        ),
      ],
    );
  }

  /// Wraps [child] in a button when [onTap] is set, and leaves it untouched
  /// otherwise.
  ///
  /// ⚠️ The `InkWell` goes around the ROW, not around the text: the tap target
  /// then covers the icon, the label, the fade rule and the trailing glyph —
  /// the whole thing the user reads as one title. A target the size of the
  /// text alone would re-create FB-70 at a different scale.
  Widget _tappable(BuildContext context, Widget child) {
    final t = onTap;
    if (t == null) return child;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: t,
        borderRadius: BorderRadius.circular(6),
        // A little breathing room so the ripple does not clip against the
        // card's own padding, and so the row clears the 40 px floor FB-70 set.
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: child,
        ),
      ),
    );
  }

  Widget _row(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: context.accent.accent),
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
        //
        // When [device] is set this row carries the UNIT and the module name
        // moves to the line below — amber, and not upper-cased, because it is a
        // name somebody typed rather than a label this app chose.
        Flexible(
          child: Text(
            device ?? text.toUpperCase(),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: device == null
                ? AppTextStyles.cardHeading(context)
                : AppTextStyles.cardHeading(context)
                    .copyWith(color: context.accent.accent),
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
