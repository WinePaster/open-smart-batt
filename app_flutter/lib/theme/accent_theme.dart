/// OpenSmartBatt — the user-selectable accent THEME (design 0064 Phase 1).
///
/// 🔑 The unit here is a THEME, not "a colour". The app has always had a PAIR:
/// amber for the primary emphasis and cyan for the secondary one (the gauge
/// sub-line, the temperature series, the settings link rows). Letting the user
/// replace only the first is what produced design 0064's original dilemma —
/// change the gauge and it clashes with the cyan sub-line beside it; leave the
/// gauge alone and the user says the setting did nothing. Ruled 2026-08-15:
/// 「所以簡單來說是換主題的概念」— so both move, together, as a set.
///
/// Status colours are NOT in here. `AppSemantics.good` / `.danger` / `.warn` /
/// `.event` are fixed for everyone: green-is-healthy and red-is-fault are the
/// shared vocabulary that every field report is read in, and a hue rotation
/// would retroactively invalidate every screenshot we have ever judged.
///
/// ## Phase 1 ships SIX pre-verified themes, not a colour picker
///
/// The arbitrary-colour picker is Phase 2. Six fixed sets buy one specific
/// thing: `onAccent` and `accentMuted` are LOOKED UP rather than computed, so
/// none of design 0064's estimated thresholds (the 0.45 luminance split, the
/// 0.15 clash distance) has to be trusted yet. Every value below was checked by
/// hand against the criteria in the table, and a human signed them off. That is
/// a stronger guarantee than an uncalibrated formula — and it is also the
/// reason the formulas are deliberately absent from this file. Do not add them
/// here "while you are at it": the moment they exist, somebody will re-derive
/// these constants from them and quietly replace a checked value with a guess.
///
/// ## What every set was checked against (design 0064 §5.1, V1–V7)
///
/// Distances use the HSV-weighted metric from design 0064 §3.4(b)
/// (`Δhue/180*0.7 + Δsat*0.15 + Δval*0.15`); contrast ratios are sRGB relative
/// luminance. The floor for each column is the value the SHIPPED amber set
/// already scores, because a rule that fails our own default is not a rule:
///
/// * **V1/V5** `accent` vs `accentSecondary` ≥ 0.35 (amber/cyan = 0.582). The
///   two are the voltage and temperature traces on the history chart, drawn
///   1–1.5 px wide over the grid, so this is the tightest of the criteria and
///   was checked at line width, not as swatches.
/// * **V2** each colour vs `AppSemantics.good` ≥ 0.16 and vs `.danger` ≥ 0.19.
///   0.16 is not a round number — it is exactly what today's cyan scores
///   against green, and cyan has shipped beside green in the same chart legend
///   since the first build.
/// * **V3** one `onAccent` is readable on BOTH colours (≥ 4.5:1 on each). This
///   is what keeps the set a TRIPLE instead of a quadruple: design 0064 §0.7 ②
///   warned that a set whose two colours needed opposite foregrounds would
///   force a fourth token. None of the six does; the worst case is 5.9:1.
/// * **V4** each colour against both backgrounds — ≥ 1.65:1 on light
///   (`#F4F6FA`) and ≥ 5:1 on dark (`#0B0D11`). Again 1.65 is not arbitrary:
///   today's cyan scores 1.69 on light and has always been legible enough.
/// * **V6/V7** `accent` vs `AppPalette.muted` ≥ 0.22. Design 0064 Q4 rules that
///   the device name in a two-line card heading follows the accent, and the
///   line under it is `muted` — so an accent that reads as grey would merge the
///   two. `azure` is the tightest at 0.226 (it is the only set whose accent
///   shares a hue family with `muted`'s blue-grey); it clears on chroma, not on
///   lightness.
///
/// 🔴 A seventh set is not a matter of taste. Run all seven checks, at chart
/// line width, in both brightnesses, or do not add it. Nothing in CI enforces
/// them — `accent_theme_test.dart` only catches a copy-paste that forgot to
/// change a value.
library;

import 'package:flutter/material.dart';

/// One accent set: what the user is choosing when they pick a theme colour.
@immutable
class AccentTheme extends ThemeExtension<AccentTheme> {
  const AccentTheme({
    required this.id,
    required this.accent,
    required this.accentSecondary,
    required this.onAccent,
    required this.accentMuted,
  });

  /// Stable identifier — `'amber'`, `'azure'`, …
  ///
  /// 🔴 ONE string does three jobs: it is the value stored in the `settings`
  /// table, the suffix of the l10n key that names the swatch, and the value
  /// written into the export header's `theme:` line. That is deliberate (one
  /// id threads all three layers) and it means an id IS A COMPATIBILITY
  /// SURFACE the moment it ships. Renaming one because it reads badly would
  /// leave every phone that chose it unable to decode its own setting, and
  /// those users would silently fall back to amber. Change the COLOURS of a
  /// set freely; never its id.
  final String id;

  /// Primary emphasis: brand marks, selection, filled actions, the gauge arc,
  /// and the voltage series on the history chart.
  final Color accent;

  /// Secondary emphasis: the gauge sub-line, the temperature series, settings
  /// link rows. Was `AppColors.cyan`'s non-status half.
  final Color accentSecondary;

  /// Foreground on top of [accent] AND [accentSecondary] fills — one value for
  /// both; see V3 in the library comment.
  final Color onAccent;

  /// Low-value variant of [accent] (its RGB × 0.8). Used only by the DVOL bar
  /// gradient, which loses its depth entirely if the two stops are equal.
  final Color accentMuted;

  /// The default, and the only set that existed before design 0064.
  ///
  /// [accentMuted] is the historical `AppColors.amberDark` rather than a
  /// recomputed value: the × 0.8 rule reproduces it to within 3/255 on one
  /// channel, and the shipped gradient is the one that has been looked at.
  static const AccentTheme amber = AccentTheme(
    id: 'amber',
    accent: Color(0xFFF6A821),
    accentSecondary: Color(0xFF46D4C8),
    onAccent: Color(0xFF1A1205),
    accentMuted: Color(0xFFC8861A),
  );

  /// Sky blue + gold. The accent that sits closest to `muted`'s hue family, so
  /// it carries the most saturation of the six on purpose (V6 = 0.226).
  static const AccentTheme azure = AccentTheme(
    id: 'azure',
    accent: Color(0xFF17ABF5),
    accentSecondary: Color(0xFFE8A83C),
    onAccent: Color(0xFF05121A),
    accentMuted: Color(0xFF1289C4),
  );

  /// Violet + yellow-green.
  static const AccentTheme violet = AccentTheme(
    id: 'violet',
    accent: Color(0xFF9B6BF2),
    accentSecondary: Color(0xFFA8C63C),
    onAccent: Color(0xFF0D051A),
    accentMuted: Color(0xFF7C56C2),
  );

  /// Pink + sky. The accent is held at hue 310° rather than a truer magenta:
  /// at 320° it scored 0.137 against `danger`, below the 0.19 floor, and a
  /// "fault" chip that reads as a brand colour is the one confusion design
  /// 0064 exists to prevent.
  static const AccentTheme magenta = AccentTheme(
    id: 'magenta',
    accent: Color(0xFFE85BD0),
    accentSecondary: Color(0xFF3FBEE8),
    onAccent: Color(0xFF1A0516),
    accentMuted: Color(0xFFBA49A6),
  );

  /// Yellow-green + periwinkle. The secondary is held away from `muted`'s
  /// 216° — a periwinkle at 229° scored 0.143 against it.
  static const AccentTheme lime = AccentTheme(
    id: 'lime',
    accent: Color(0xFF8FC42B),
    accentSecondary: Color(0xFF9086F5),
    onAccent: Color(0xFF131A05),
    accentMuted: Color(0xFF729D22),
  );

  /// Teal + orchid.
  ///
  /// ⚠️ Its accent is nearly the same hue as `AppSemantics.event`, i.e. as the
  /// DEFAULT theme's secondary. That is allowed, and the amber set is the
  /// precedent: there, `accentSecondary` and `AppSemantics.event` are literally
  /// the same colour and have been since the first build. A theme colour is
  /// permitted to coincide with a status colour it never shares a group with.
  static const AccentTheme teal = AccentTheme(
    id: 'teal',
    accent: Color(0xFF17C4AE),
    accentSecondary: Color(0xFFD06BE8),
    onAccent: Color(0xFF051A17),
    accentMuted: Color(0xFF129D8B),
  );

  /// Every shipped set, in the order the swatches are drawn.
  ///
  /// 🔴 Order is part of the UI but NOT part of the stored value — that is why
  /// the setting stores [id] and the swatches carry names. A reporter who says
  /// "I picked the third one" is telling us nothing durable; one who says
  /// "天藍" is.
  static const List<AccentTheme> all = [
    amber,
    azure,
    violet,
    magenta,
    lime,
    teal,
  ];

  /// The set called [id], or null.
  ///
  /// Null rather than a throw or a fallback, because callers need to tell
  /// "unknown id" apart from "no choice stored" — see `AppSettings`, where both
  /// end at amber but only one of them is worth a decode path.
  /// The pair, spelled out for the export preamble (design 0064 §3.8).
  ///
  /// 🔴 **Hex, even though the database stores the ID.** The two answer
  /// different questions and the right answer differs:
  ///
  ///  * the DB records a CHOICE, so it must follow the palette — when a pair is
  ///    corrected (the §0.6 thin-line check is expected to move at least one),
  ///    changing the constant has to fix every user who picked it;
  ///  * this line records the PIXELS a reporter's screenshot actually had, so it
  ///    must never change afterwards. A file that said `azure` and nothing else
  ///    would silently re-point at the corrected colours years later, and the
  ///    screenshot it was paired with would stop matching it.
  ///
  /// The id is kept alongside because it is what a human says out loud, and
  /// because it is the only half that can be grepped across the corpus.
  String get exportValue => 'accent=$id '
      '${_hex(accent)}/${_hex(accentSecondary)}';

  /// RRGGBB, upper case, no alpha — the form the corpus already writes by hand
  /// (`our-app.md` quotes colours this way) and the form a reader can paste
  /// straight into a colour picker.
  static String _hex(Color c) => (c.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .toUpperCase()
      .padLeft(6, '0');

  static AccentTheme? byId(String? id) {
    for (final t in all) {
      if (t.id == id) return t;
    }
    return null;
  }

  @override
  AccentTheme copyWith({
    String? id,
    Color? accent,
    Color? accentSecondary,
    Color? onAccent,
    Color? accentMuted,
  }) =>
      AccentTheme(
        id: id ?? this.id,
        accent: accent ?? this.accent,
        accentSecondary: accentSecondary ?? this.accentSecondary,
        onAccent: onAccent ?? this.onAccent,
        accentMuted: accentMuted ?? this.accentMuted,
      );

  @override
  AccentTheme lerp(covariant AccentTheme? other, double t) {
    if (other == null) return this;
    return AccentTheme(
      // Ids do not interpolate; snap at the midpoint. A blended id would be a
      // value that no `byId` can resolve, handed to the export header while
      // the theme animates.
      id: t < 0.5 ? id : other.id,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSecondary: Color.lerp(accentSecondary, other.accentSecondary, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      accentMuted: Color.lerp(accentMuted, other.accentMuted, t)!,
    );
  }
}

/// `context.accent` → the active [AccentTheme].
///
/// Falls back to [AccentTheme.amber] rather than to a null check at every call
/// site, matching `context.colors`. The fallback fires in widget tests that
/// pump a bare `MaterialApp`, which is precisely where a hard failure would be
/// noise rather than signal.
extension BuildContextAccent on BuildContext {
  AccentTheme get accent =>
      Theme.of(this).extension<AccentTheme>() ?? AccentTheme.amber;
}
