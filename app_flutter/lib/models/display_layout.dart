/// OpenSmartBatt — the stored dashboard layout (design 0034 Phase 3).
///
/// PURE Dart (no Flutter imports). What a WATCHFACE is made of lives beside the
/// module registry in `ui/dashboard/watchfaces.dart`; this file is only the
/// storage shape and the rules for reading it back safely.
///
/// ## Why a JSON string and not a slug column
///
/// The first shipped interface is A ("pick one of three named watchfaces"), so
/// one slug would be enough TODAY. The ruled data model is C — a primary module
/// plus complications, each with a span — and the whole point of ruling C now
/// while shipping A is that opening the editor later must not need a schema
/// migration (design 0034 §3). A `TEXT` column holding a JSON object gets that:
/// `{"face":"compact"}` grows into
/// `{"face":"custom","primary":"gaugeVoltage","complications":[…]}` by adding
/// keys, and every build in between keeps reading the key it knows.
///
/// ## Unknown content is not an error, it is a default
///
/// A row can hold something this build cannot parse: a hand-edited database, a
/// slug retired in a later version, a truncated write. None of those is worth a
/// crash on the dashboard — the precedent is
/// `AppSettings._normaliseLogMaxBytes`, where a stored budget outside the
/// offered set silently lands on the default rather than leaving the control
/// blank. [DisplayLayout.decode] does the same: anything it cannot make sense
/// of becomes [DisplayLayout.defaults], which is by construction today's
/// screen.
///
/// Newer keys are deliberately NOT round-tripped. There is no reader that would
/// need them: `AppDatabase` refuses to open a database written by a newer
/// schema at all ([DatabaseDowngradeException]), so a build that cannot
/// understand a layout cannot have reached the row in the first place.
library;

import 'dart:convert';

/// The three named watchfaces offered per product class (design 0034 §7 Q2:
/// interface A — pick one, no free editing yet).
///
/// The slug is the enum NAME and is a WIRE VALUE: it is written to the
/// database and printed into export preambles, so it must not be renamed
/// casually and must never be localized.
enum Watchface {
  /// Today's dashboard, card for card. The default, and the implementation of
  /// design 0034 G4 — a user who never opens the setting sees no change.
  standard,

  /// Instrument + numbers only. Drops the per-cell / port card.
  compact,

  /// Numbers and the per-cell detail first, instrument last.
  diagnostic;

  /// Stable storage/export identifier. Deliberately the enum name, so adding a
  /// face cannot silently renumber the others (contrast an ordinal).
  String get slug => name;

  /// Parse a stored slug. Unknown / null → null, so callers can decide what a
  /// missing value means (it is [DisplayLayout.defaults] everywhere today).
  static Watchface? fromSlug(String? slug) {
    if (slug == null) return null;
    for (final f in Watchface.values) {
      if (f.slug == slug) return f;
    }
    return null;
  }
}

/// One device's stored dashboard layout.
///
/// Bound to a device, not to a class or to the app (design 0034 Q3): it lives
/// in `saved_devices.display_layout`.
class DisplayLayout {
  const DisplayLayout({this.watchface = Watchface.standard});

  /// The layout every device has until someone changes it — and, by
  /// construction, the one that draws exactly today's screen (G4).
  static const DisplayLayout defaults = DisplayLayout();

  /// JSON key for [watchface]. Also the token used in the export preamble, so
  /// the two cannot drift apart.
  static const String faceKey = 'face';

  /// Which named watchface this device shows.
  final Watchface watchface;

  // Reserved for interface C (design 0034 §3 / §12.1 #7), NOT yet stored:
  //   primary        — the single required main module,
  //   complications  — ordered secondary modules,
  //   span           — full / half width per entry, half-width being the
  //                    existing visual language (readout grid, USB dual port).
  // They are named here rather than added as unused fields because an empty
  // list written into every row would have to be told apart from "never set".

  DisplayLayout copyWith({Watchface? watchface}) =>
      DisplayLayout(watchface: watchface ?? this.watchface);

  Map<String, Object?> toJson() => {faceKey: watchface.slug};

  /// The exact string stored in the `display_layout` column.
  String encode() => jsonEncode(toJson());

  /// Read a stored column value. NEVER throws: see the library comment.
  ///
  /// `null` (a pre-v10 row, or a device whose layout was never set) and
  /// unparseable content land on the same value, and that is intended — both
  /// mean "this device has no layout of its own", and both must draw today's
  /// screen.
  static DisplayLayout decode(Object? stored) {
    if (stored is! String || stored.isEmpty) return defaults;
    Object? parsed;
    try {
      parsed = jsonDecode(stored);
    } on FormatException {
      return defaults;
    }
    if (parsed is! Map) return defaults;
    final face = parsed[faceKey];
    return DisplayLayout(
      watchface: Watchface.fromSlug(face is String ? face : null) ??
          defaults.watchface,
    );
  }

  /// True when nothing has been customised — used to decide whether "restore
  /// defaults" has anything to do.
  bool get isDefault => this == defaults;

  @override
  bool operator ==(Object other) =>
      other is DisplayLayout && other.watchface == watchface;

  @override
  int get hashCode => watchface.hashCode;

  @override
  String toString() => 'DisplayLayout(${watchface.slug})';
}
