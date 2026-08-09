/// OpenSmartBatt — the card SHELL vocabulary (design 0054).
///
/// PURE Dart, and for the same reason `display_module.dart` is: these enum
/// NAMES are WIRE VALUES. They are written into `settings.home_layout` and
/// printed into the export preamble's `home: tiles=…` line, so the vocabulary
/// belongs beside the other storage shapes rather than inside a file that also
/// builds widgets.
///
/// ## Shell is one of TWO axes, and the asymmetry is the whole design
///
/// | | `shell` (this file) | `view` (`card_view.dart`) |
/// |---|---|---|
/// | vocabulary | **global** — every card understands all of them | 🔴 **scoped to one module** |
/// | governs | frame, fill, corner ticks, radius, padding, value type scale | what the card draws INSIDE itself |
/// | who implements it | [IndustrialCard], one file | that card's own widget |
///
/// A shell costs O(1) to add and nothing per card; a view costs O(1) and
/// touches exactly one card. Neither multiplies with the other, which is why
/// this is an addition rather than a Cartesian product — see design 0054 §1.
///
/// ## 🔴 Never a `ThemeData` extension
///
/// There are ~26 [IndustrialCard] call sites and 11 of them are in the settings
/// screen, the history screen and the G-calibration wizard. A theme extension
/// would mean picking "minimal" for your home page also unframed the settings
/// page. The shell is delivered by a scope widget the HOME GRID puts around its
/// own tiles (`CardStyleScope`), and everything outside that scope falls back to
/// [CardShell.standard].
library;

/// How a card's shell is drawn. Global vocabulary: every card understands every
/// member, so adding a card costs nothing here and adding a shell costs nothing
/// per card.
enum CardShell {
  /// The card as it has always been: 1 px frame, panel fill, corner ticks,
  /// 12 px radius, 15 px padding.
  standard,

  /// No frame and no fill — a hairline under the card is all that separates it
  /// from the next one.
  ///
  /// 🔴 The difference from [dense] is pinned on the FRAME and the FILL, never
  /// on spacing. Two shells whose only difference is padding read as the same
  /// shell rendered at two text sizes, and design 0041's defect ("換了都一樣")
  /// is exactly what happens when the one thing telling two choices apart is
  /// something a given screen might not draw. A border either is there or is
  /// not, on every card, in every data state.
  minimal,

  /// Frame and fill KEPT, everything else tightened: no corner ticks, no
  /// heading rule, 60 % of the vertical padding, and values at 0.84×.
  dense;

  /// Stable storage identifier — the enum name, so adding a shell cannot
  /// silently renumber the others (contrast an ordinal).
  String get slug => name;

  static CardShell? fromSlug(String? s) {
    for (final v in CardShell.values) {
      if (v.slug == s) return v;
    }
    return null;
  }

  /// The structural tokens this shell draws with.
  ///
  /// Exhaustive `switch`, no `default`: a new shell is a compile error here
  /// rather than a silent copy of `standard`. Same discipline as
  /// `DisplayModule.isPhoneModule`.
  CardShellTokens get tokens => switch (this) {
        CardShell.standard => const CardShellTokens(
            bordered: true,
            filled: true,
            underlined: false,
            cornerTicks: true,
            headingRule: true,
            radius: 12,
            padScaleH: 1,
            padScaleV: 1,
            gapBelow: 14,
            headingGap: 13,
            valueScale: 1,
          ),
        CardShell.minimal => const CardShellTokens(
            bordered: false,
            filled: false,
            // The one mark it keeps. Without it a column of unframed cards is
            // one undifferentiated wall of text, which is a different failure
            // from "quiet".
            underlined: true,
            cornerTicks: false,
            headingRule: true,
            radius: 0,
            // Side padding goes to zero because there is no frame to sit
            // inside; the vertical rhythm is untouched, so the page does not
            // also become dense. The two shells must not converge.
            padScaleH: 0,
            padScaleV: 1,
            gapBelow: 14,
            headingGap: 13,
            valueScale: 1,
          ),
        CardShell.dense => const CardShellTokens(
            bordered: true,
            filled: true,
            underlined: false,
            cornerTicks: false,
            headingRule: false,
            radius: 8,
            // The mockup's 11 × 9 padding, expressed as a SCALE of the card's
            // own padding rather than as an override. Cards that carry their
            // own (`HomeWaitingTile` is 15/11) then tighten too, instead of
            // being silently reset to a number chosen for a different card.
            padScaleH: 0.75,
            padScaleV: 0.6,
            gapBelow: 9,
            headingGap: 8,
            valueScale: 0.84,
          ),
      };
}

/// The structural tokens one [CardShell] is made of.
///
/// A value type rather than a bag of getters on the enum, because design 0054
/// T-S1 asserts that no two shells share a token bundle — a claim that needs
/// something with an `==` on it.
class CardShellTokens {
  const CardShellTokens({
    required this.bordered,
    required this.filled,
    required this.underlined,
    required this.cornerTicks,
    required this.headingRule,
    required this.radius,
    required this.padScaleH,
    required this.padScaleV,
    required this.gapBelow,
    required this.headingGap,
    required this.valueScale,
  });

  /// 1 px frame all the way round.
  final bool bordered;

  /// Panel fill behind the card (as opposed to the page showing through).
  final bool filled;

  /// A single hairline under the card, used when there is no frame.
  final bool underlined;

  /// The four L-shaped corner ticks.
  final bool cornerTicks;

  /// The fading rule that runs from the heading to the card's right edge.
  final bool headingRule;

  /// Corner radius, in logical pixels.
  final double radius;

  /// Multipliers applied to the card's OWN padding — see [CardShell.dense].
  final double padScaleH;
  final double padScaleV;

  /// Gap under the card, before the next one.
  final double gapBelow;

  /// Gap between the heading and the body.
  final double headingGap;

  /// Multiplier on the VALUE type sizes (`gaugeValue`, `statValue`, and the
  /// 32 px readings that set their size directly).
  ///
  /// 🔴 Deliberately NOT applied to `cardHeading` (10.5 px) or `label` (10 px).
  /// Those are already at the smallest size this app considers legible, so
  /// scaling them is not "dense", it is "unreadable" — and the identity floor
  /// F1 rides on the heading being readable. Dense earns its compactness from
  /// padding, the missing rule and the missing ticks instead.
  final double valueScale;

  @override
  bool operator ==(Object other) =>
      other is CardShellTokens &&
      other.bordered == bordered &&
      other.filled == filled &&
      other.underlined == underlined &&
      other.cornerTicks == cornerTicks &&
      other.headingRule == headingRule &&
      other.radius == radius &&
      other.padScaleH == padScaleH &&
      other.padScaleV == padScaleV &&
      other.gapBelow == gapBelow &&
      other.headingGap == headingGap &&
      other.valueScale == valueScale;

  @override
  int get hashCode => Object.hash(bordered, filled, underlined, cornerTicks,
      headingRule, radius, padScaleH, padScaleV, gapBelow, headingGap,
      valueScale);

  @override
  String toString() => 'CardShellTokens(bordered: $bordered, filled: $filled, '
      'underlined: $underlined, cornerTicks: $cornerTicks, '
      'headingRule: $headingRule, radius: $radius, padScaleH: $padScaleH, '
      'padScaleV: $padScaleV, gapBelow: $gapBelow, headingGap: $headingGap, '
      'valueScale: $valueScale)';
}
