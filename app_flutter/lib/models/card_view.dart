/// OpenSmartBatt — the card CONTENT-VARIANT vocabularies (design 0054).
///
/// PURE Dart, same reason as `card_shell.dart` and `display_module.dart`: these
/// names are WIRE VALUES stored in `settings.home_layout` and printed into the
/// export preamble.
///
/// ## 🔴 The one decision this file exists to enforce
///
/// **A view's name space is scoped to ONE module. There is no global `CardView`
/// enum, and there must never be one.**
///
/// The readouts card understands `big`. The clock understands `analog` (later).
/// The question "what does `analog` mean on the readouts card" is one this
/// codebase can never be asked, because the readouts card's vocabulary does not
/// contain that word. Merge the two and every new variant has to answer "and
/// what does it look like on the other N cards" — the program does not break,
/// the person maintaining it does.
///
/// The cost of the scoping is stated in design 0054 §1.1: the editor's view
/// picker is per card, and for a module that declares fewer than two views it
/// does not appear at all. A control with one option is worse than no control.
///
/// ## Where the enums live, and why here rather than beside their cards
///
/// [ClockView] was declared in `ui/dashboard/clock_card.dart` by design 0052.
/// It moved here for the reason design 0046 Step 6 moved [DisplayModule] out of
/// `ui/dashboard/display_modules.dart`: a vocabulary that a PERSISTED FORMAT
/// depends on belongs in the model layer. `clock_card.dart` re-exports it, so
/// every existing import still resolves and design 0052's seam ① — the
/// exhaustive `switch` in `ClockCardBody` — is untouched.
library;

import 'display_module.dart';

/// How the readouts card lays its items out.
enum ReadoutsView {
  /// Default: the two-column hairline grid.
  grid,

  /// Hero layout — the FIRST item at gauge size, the rest compressed onto one
  /// line under a rule.
  ///
  /// 🔴 Zero information loss (design 0054 F4): every item's label, value, unit
  /// and badge is still printed. The variant is a change of EMPHASIS, not a
  /// shorter list — a view that only printed fewer fields would leave the user
  /// unable to find out what they had given up.
  ///
  /// ⚠️ Known cost, ruled 2026-08-09 (design 0054 Q1): the hero item is the
  /// card's first item and the user cannot choose it. On a battery that is the
  /// TEMPERATURE. Making it selectable is the free Cartesian product design
  /// 0040 Q4 already refused; changing the order is the registry's job
  /// (`display_modules.dart`), not a view's.
  big;

  String get slug => name;

  static ReadoutsView? fromSlug(String? s) {
    for (final v in ReadoutsView.values) {
      if (v.slug == s) return v;
    }
    return null;
  }
}

/// How a gauge card (`gaugeVoltage` / `gaugeSoc`) draws its instrument.
///
/// One vocabulary for both modules on purpose: they are the same widget
/// ([PvltGauge]) over two domains, so a variant that existed for one and not
/// the other would be a difference with no cause behind it.
enum GaugeView {
  /// Default: the 180–240 px tick-ring dial.
  dial,

  /// The dial removed, the centre stack left-aligned — about 78 px instead of
  /// 190.
  ///
  /// 🔴 The `caption` MUST survive here (design 0054 F1). A gauge card has no
  /// heading at all — `dashboardCardFor` passes only `child:` — so the caption
  /// is the entire identity of the card. Without it this view is an unlabelled
  /// number.
  ///
  /// F4 is satisfied by the trade, not by the subtraction: the tick ring is
  /// given up and what is bought is a card that fits a 1×1 tile.
  numeric;

  String get slug => name;

  static GaugeView? fromSlug(String? s) {
    for (final v in GaugeView.values) {
      if (v.slug == s) return v;
    }
    return null;
  }
}

/// How the clock card draws itself (design 0052 seam ①).
///
/// One member today. It is an enum rather than a bare widget because design
/// 0052 §3 seam ① wants the branch point to EXIST before there is a second
/// branch: the alternative — writing V1 as the only possible rendering and
/// adding an `if` when `analog` arrives — is how a variant ends up as a copy of
/// the card instead of a case of it.
///
/// ⚠️ `analog` is deliberately NOT here yet (design 0054 Phase 2). When it
/// lands it draws NO SECOND HAND — ruled 2026-08-09 (design 0054 Q2): a sweeping
/// hand makes a card that updates once a minute look live, and honesty about
/// refresh rate is the same floor F3 protects elsewhere.
enum ClockView {
  /// V1, ruled by the owner from four mockup variants: hours and minutes, no
  /// seconds, no date, no weekday (`design/mockups/0052-clock-card.html`).
  digital;

  String get slug => name;

  static ClockView? fromSlug(String? s) {
    for (final v in ClockView.values) {
      if (v.slug == s) return v;
    }
    return null;
  }

  /// How often this view has to be redrawn.
  ///
  /// 🔑 The VIEW declares it, not the card. `digital` shows no seconds, so a
  /// per-second rebuild would repaint an identical string 59 times out of 60;
  /// a future `analog` with a sweep hand, or a variant carrying seconds, says
  /// something different here and nothing else changes.
  ///
  /// Exhaustive, no `default` — see the library comment.
  Duration get tickPeriod => switch (this) {
        ClockView.digital => const Duration(minutes: 1),
      };
}

/// The view slugs one module declares, in order — the FIRST is that module's
/// default.
///
/// 🔑 This is the function design 0054 §1.1 mechanism ① is made of: the editor
/// offers exactly this list, so a user can never select a view the card does not
/// implement. Design 0041's defect was "the option exists and changes nothing";
/// here the option does not exist.
///
/// Exhaustive `switch`, no `default`. A new [DisplayModule] is a compile error
/// here rather than silently inheriting an empty vocabulary — the same shape
/// `isPhoneModule` is written in, and for the same reason: this project has
/// shipped the other shape four times.
List<String> cardViewSlugs(DisplayModule m) => switch (m) {
      DisplayModule.readouts => const ['grid', 'big'],
      DisplayModule.gaugeVoltage ||
      DisplayModule.gaugeSoc =>
        const ['dial', 'numeric'],
      DisplayModule.clock => const ['digital'],
      // Declared empty, each for a reason recorded in design 0054 §2 — these
      // are RULINGS, not gaps waiting to be filled:
      //  * `chart`   — a `numbers` view is the readouts card (design 0040's
      //                mirror violation); `sparkline` is Phase 2.
      //  * `cells`   — a numeric view loses the comparison the bars exist for
      //                and buys no emphasis (F4).
      //  * `energyPath` — design 0041 §3.3/§3.4 just cut it from four segments
      //                to two. A "detailed" view is that ruling re-entered
      //                through a side door. 🔴 A view is never a way round a
      //                ruling.
      //  * `speed`   — the card already has five STATES; views multiply with
      //                states, and the number of states is not ours to bound.
      DisplayModule.chart ||
      DisplayModule.cells ||
      DisplayModule.energyPath ||
      DisplayModule.speed ||
      DisplayModule.gForce =>
        const [],
    };

/// The view a module falls back to — its first declared slug, or null when it
/// declares none.
String? defaultCardView(DisplayModule m) {
  final slugs = cardViewSlugs(m);
  return slugs.isEmpty ? null : slugs.first;
}

/// Resolve a STORED view slug against the module that owns it.
///
/// Returns null — meaning "that card's default" — for an unknown slug, a slug
/// belonging to another module's vocabulary, a tile with no module at all, and
/// for the module's own default (so it is never written back out).
///
/// 🔴 Unknown ⇒ default, and the TILE SURVIVES. That is the opposite of the
/// rule for an unknown `module`, which drops the tile (`home_layout.dart`), and
/// the asymmetry is the point: a module is CONTENT, a view is only presentation.
/// Same choice `display_layout.dart` makes for an unknown watchface slug.
String? normaliseCardView(DisplayModule? m, String? slug) {
  if (m == null || slug == null) return null;
  final slugs = cardViewSlugs(m);
  if (!slugs.contains(slug)) return null;
  // The default is expressed as absence, so it round-trips as absence. An empty
  // list written into every row would have to be told apart from never set
  // (`display_layout.dart`).
  if (slug == slugs.first) return null;
  return slug;
}
