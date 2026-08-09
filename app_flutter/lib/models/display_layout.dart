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

/// The named watchfaces (design 0034 §7 Q2: interface A — pick one).
///
/// 🔴 **NOTHING PICKS ONE ANY MORE (design 0051, owner ruling 2026-08-09).**
/// The picker is gone from the device page and the Settings signpost with it;
/// [effectiveWatchface] resolves every stored value to [fixed]. The enum, the
/// slugs, [DisplayLayout.decode]'s round-trip and the `display_layout` column
/// all stay — the ruling was "砍入口留骨架", on the reasoning that the feature
/// shipped on 2026-08-04 and was still being changed on 2026-08-08, so the cost
/// of keeping the storage shape is small and the cost of having thrown it away
/// is not.
///
/// The slug is the enum NAME and is a WIRE VALUE: it is written to the
/// database and printed into export preambles, so it must not be renamed
/// casually and must never be localized.
enum Watchface {
  /// Today's dashboard, card for card. Was the default and the implementation
  /// of design 0034 G4 — a user who never opened the setting saw no change.
  ///
  /// Superseded as the default by [fixed] (design 0051). Still parsed, still
  /// stored, no longer drawn.
  standard,

  /// Instrument + numbers only. Drops the per-cell / port card.
  compact,

  /// Numbers and the per-cell detail first, instrument last.
  diagnostic,

  /// Speed on top, then the compact shell (design 0042 §3.3).
  ///
  /// The one face carrying `speed`, which is what keeps design 0034's G4
  /// literal: nobody who has not chosen this face sees a pixel change.
  ///
  /// ⚠️ Unlike the other three, this face is CONDITIONAL. It is offered only
  /// while the speed master switch is on, and — the part that is easy to leave
  /// out — a stored `riding` also RENDERS as `standard` while the switch is
  /// off. That is not the same rule twice: without the render half, `riding`
  /// with the switch off draws `[gauge, extra]`, which is `compact` card for
  /// card, and the two faces collapse into one page. Design 0041 was written
  /// about exactly that collapse on `standard`/`compact`; accepting it here
  /// would be redoing a defect that was fixed two days earlier in a new place.
  /// Both halves go through the single decision point `ridingSelectable`.
  ///
  /// The stored slug is untouched by the fallback, so turning the switch back
  /// on brings the face back with no migration and no lost setting.
  ///
  /// 🔴 Since design 0051 this face carries NEITHER phone module: the speed
  /// card and the G ball live on the home grid only. What is left of it is
  /// `[gauge, extra]` — the same list as [compact] — which is fine precisely
  /// because nothing can select it any more.
  riding,

  /// 🔑 **The one face that is drawn** (design 0051).
  ///
  /// `圓錶 → 趨勢圖 → 數字格 → 類別卡`, and the ordering is a ruling rather
  /// than an inheritance. It is deliberately NOT [diagnostic]'s order
  /// (chart first, instrument last): that order was chosen in design 0041 Q4
  /// on the premise that "anyone who goes out of their way to select this face
  /// came for the curve". A face nobody selects has no such population, and
  /// `watchfaces.dart` already records the cost that premise was paying —
  /// for the first seconds of a link the chart has no points, so the TOP of
  /// the page is a waiting card. Acceptable for an opt-in; not acceptable for
  /// the only page there is.
  ///
  /// So the instrument leads (it is the one thing readable at a glance and it
  /// draws from the first frame), the chart follows it, the numbers grid comes
  /// third and the class's own card — per-cell voltages on a pack, the
  /// energy-path row on a power bank — closes.
  ///
  /// The protection card is still NOT in this list and cannot be: design 0034
  /// §6 makes "controls last, always, never customisable" structural by having
  /// no [DisplayModule] for it.
  fixed;

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
  const DisplayLayout({this.watchface = Watchface.fixed});

  /// The layout every device has, full stop (design 0051): nothing writes this
  /// column from the UI any more, and [effectiveWatchface] ignores whatever a
  /// pre-0051 build left in it.
  ///
  /// ⚠️ A device that stored `compact` still DECODES as `compact` — the
  /// round-trip is part of the skeleton being kept — it simply does not RENDER
  /// as one. No migration is needed and none is run: [decode] never throws
  /// (see the library comment), so an old row is read, ignored and left alone.
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
