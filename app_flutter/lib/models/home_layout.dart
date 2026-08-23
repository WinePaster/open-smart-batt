/// OpenSmartBatt — the home page's stored layout (design 0046 P2/P3).
///
/// PURE Dart (no Flutter imports), same discipline as `display_layout.dart`.
///
/// ## What it is, and how it differs from a watchface
///
/// | | design 0034 watchface | this |
/// |---|---|---|
/// | stored in | `saved_devices.display_layout` | `settings.home_layout` |
/// | bound to | one DEVICE (0034 Q3) | the APP |
/// | contents | that unit's module order | a grid of tiles, each optionally
/// |          |                          | naming a device |
///
/// [HomeTile.deviceId] is the one field design 0034's model does not have: a
/// home tile may show "THAT unit's voltage gauge", or a module that belongs to
/// no unit at all (design 0042's `speed` reads the phone's own GNSS).
///
/// ## 🔴 Why a tile's module is a [DisplayModule] and nothing else
///
/// Design 0034 §6 makes "controls are last, always, and never customisable" an
/// INVARIANT, enforced structurally: there is no `DisplayModule` for the
/// protection card, so no layout can name it. Reusing that same type here is
/// what makes design 0046 R4 ("controls only inside one device's page") true by
/// construction — the home page CANNOT hold a cut-off button, and no check
/// anywhere has to say so. That is T-new-1, and it is a type, not a test.
///
/// The device card is therefore [HomeTileKind.deviceCard] rather than a new
/// `DisplayModule` member. Adding one would have been cheaper to write and much
/// more expensive to own: `DisplayModule`'s names are WIRE VALUES printed into
/// every export preamble's `modules=` list, and a member no watchface can ever
/// name would pollute a vocabulary the analysis side reads.
///
/// ## Flat list, not rows
///
/// Design 0046 §3.3 describes `rows[] = { span, module, deviceId? }`. This
/// stores a FLAT tile list with a span per tile and pairs them greedily when
/// rendering. The rendered result is identical (two consecutive halves share a
/// row; a full owns one; an orphan half keeps the left of its own row), and the
/// reason is [HomeSpan]-independent: the editor is a `ReorderableListView`
/// (design 0046 R19), which takes a one-dimensional list. Nesting would mean
/// splitting and rejoining rows on every drag.
///
/// ## Unknown content is not an error, it is "never set"
///
/// [HomeLayout.decode] NEVER throws — a hand-edited database, a module retired
/// in a later build, a truncated write. It returns null, which every caller
/// reads as "this user has not customised the home page", and then
/// [HomeLayout.defaultFor] runs. That is deliberately the SAME outcome as a NULL
/// column: `defaultFor` reflects the devices the user has TODAY, so falling back
/// to it keeps a newly-added unit visible, which a stored snapshot would not.
library;

import 'dart:convert';

import 'app_settings.dart';
import 'card_shell.dart';
import 'card_view.dart';
import 'display_module.dart';
import 'product_class.dart';
import 'saved_device.dart';

/// A tile's width. `full` is the owner's "1×2", `half` their "1×1"
/// (design 0046 §1.2).
enum HomeSpan {
  full,
  half;

  /// Stable storage identifier — the enum name, so adding a span cannot
  /// silently renumber the others (contrast an ordinal).
  String get slug => name;

  static HomeSpan? fromSlug(String? s) {
    for (final v in HomeSpan.values) {
      if (v.slug == s) return v;
    }
    return null;
  }
}

/// Which of a segment's two columns a half-width tile lives in
/// (design 0084 §4.1, stage S1).
///
/// ## 🔴 Stored, never computed — that is the whole point of the type
///
/// Design 0084 Q1 chose "the user says which column" over "the layout works it
/// out from the heights". The rejected option (a masonry) decides placement
/// from what the cards currently measure, which means the same layout draws
/// differently when a unit connects — and means the editor, which draws SAMPLE
/// data by owner's ruling (design 0051 §5), cannot show where a card will
/// actually land. A stored side has neither problem.
///
/// 🔵 **Authoritative since design 0084 S2/S4.** It began (S1) as a copy of the
/// tile's position, written alongside it so the field could land before
/// anything read it; S2 made the home page read it; S4 removed the stored
/// placeholder that was the other half of the old representation. A stored
/// column is now honoured and never recomputed — see [HomeLayout.seated].
enum HomeColumn {
  left,
  right;

  /// Stable storage identifier — the enum name, same rule as [HomeSpan.slug].
  String get slug => name;

  static HomeColumn? fromSlug(String? s) {
    for (final v in HomeColumn.values) {
      if (v.slug == s) return v;
    }
    return null;
  }
}

/// What a tile draws.
enum HomeTileKind {
  /// The zero-device empty state: "add your first device".
  addDevice,

  /// One unit's summary card — alias, status, and either a live reading or the
  /// last one WITH its age (T-new-3).
  deviceCard,

  /// One [DisplayModule], optionally bound to a device.
  ///
  /// ⚠️ There used to be a fourth member, `empty` — a STORED placeholder for
  /// the unoccupied half of a row (design 0049 §3.8). Design 0084 S4 removed
  /// it: once a half carries its own [HomeColumn], "this column ends here"
  /// needs nothing to say it, and a second way to express one fact is the
  /// hazard this project keeps a discipline file about.
  ///
  /// 🔴 [HomeLayout.decode] still READS the old slug, because a layout stored
  /// before S4 uses the placeholder's POSITION to say which side its neighbour
  /// was on. Dropping it before seating the columns would repack the halves and
  /// silently rearrange somebody's page.
  module;

  String get slug => name;

  static HomeTileKind? fromSlug(String? s) {
    for (final v in HomeTileKind.values) {
      if (v.slug == s) return v;
    }
    return null;
  }
}

/// One cell of the home grid.
class HomeTile {
  const HomeTile({
    required this.kind,
    this.module,
    this.deviceId,
    this.span = HomeSpan.full,
    this.shell = CardShell.standard,
    this.view,
    this.column,
  });

  /// A [DisplayModule] tile.
  const HomeTile.module(DisplayModule module,
      {String? deviceId,
      HomeSpan span = HomeSpan.full,
      CardShell shell = CardShell.standard,
      String? view,
      HomeColumn? column})
      : this(
            kind: HomeTileKind.module,
            module: module,
            deviceId: deviceId,
            span: span,
            shell: shell,
            view: view,
            column: column);

  /// One unit's summary card.
  const HomeTile.device(String deviceId,
      {HomeSpan span = HomeSpan.full,
      CardShell shell = CardShell.standard,
      HomeColumn? column})
      : this(
            kind: HomeTileKind.deviceCard,
            deviceId: deviceId,
            span: span,
            shell: shell,
            column: column);

  /// The zero-device empty state.
  const HomeTile.addDevice() : this(kind: HomeTileKind.addDevice);

  final HomeTileKind kind;

  /// Required when [kind] is [HomeTileKind.module], null otherwise.
  ///
  /// 🔴 The type is [DisplayModule] and must stay that way — see the library
  /// comment. It is what makes "no controls on the home page" structural.
  final DisplayModule? module;

  /// Which unit this tile is about, or null for a module that belongs to no
  /// device (design 0042's `speed` reads the phone's own receiver).
  final String? deviceId;

  final HomeSpan span;

  /// The card's SHELL — frame, fill, spacing (design 0054). A GLOBAL vocabulary:
  /// every card understands every member.
  final CardShell shell;

  /// The card's CONTENT VARIANT, or null for that card's default.
  ///
  /// 🔴 A raw slug, and its meaning is scoped to [module] — `card_view.dart` is
  /// where that is argued. It is deliberately not typed as a global `CardView`
  /// enum: there is no such type, so "what does `analog` mean on the readouts
  /// card" is a question this codebase cannot be asked.
  ///
  /// Always null when [module] is null (a device card has no variants), and
  /// always null for a module's own default, so the default round-trips as
  /// absence rather than as a written-out name.
  final String? view;

  /// Which column this tile sits in, or null for a `full` tile (which owns the
  /// whole width and has no side to be on).
  ///
  /// 🔴 Non-null for EVERY `half` after [HomeLayout.seated] has run, which both
  /// [HomeLayout.decode] and `HomeGridOps.normalise` do — so no stored layout
  /// and no edited layout can leave one unset. A `half` with a null column
  /// reaching a renderer means one of those two paths was bypassed, not that
  /// "no side" is a value.
  ///
  /// 🔑 Since design 0084 S4 this is the AUTHORITY, not a copy of the position:
  /// three cards in the left column and one in the right is a layout no
  /// ordering could express, and it is the arrangement Q2 exists to allow.
  final HomeColumn? column;

  /// [view] resolved against [module] — null for "this card's default".
  ///
  /// [HomeTile.fromJson] and [withStyle] already normalise, so this is only ever
  /// different from [view] for a tile some code CONSTRUCTED with an explicit
  /// default (`HomeTile.module(readouts, view: 'grid')`). Both writers go
  /// through it anyway: storage and the export preamble are the two places where
  /// "the default, spelled out" and "the default, absent" would look like two
  /// different layouts to a reader.
  String? get storedView => normaliseCardView(module, view);

  /// 🔴 [shell] and [view] are carried THROUGH, not defaulted.
  ///
  /// This method's only callers are `HomeGridOps` (span toggles, moves), and a
  /// version that dropped them would silently reset a card's appearance every
  /// time it was dragged — an edit performing a second edit nobody asked for.
  HomeTile copyWith({HomeSpan? span, String? deviceId, HomeColumn? column}) =>
      HomeTile(
        kind: kind,
        module: module,
        deviceId: deviceId ?? this.deviceId,
        span: span ?? this.span,
        shell: shell,
        view: view,
        // ⚠️ Carried through like shell and view, and for the same reason: a
        // span toggle or a move must not silently reseat a card in the other
        // column. Since S4 nothing re-derives it afterwards, so carrying it is
        // the difference between keeping the user's arrangement and losing it.
        column: column ?? this.column,
      );

  /// This tile, seated in [column] — and `null` IS a value here (a full tile
  /// has no side), which is why this is not an optional parameter on
  /// [copyWith]. Same reasoning as [withStyle] one method down.
  HomeTile withColumn(HomeColumn? column) => HomeTile(
        kind: kind,
        module: module,
        deviceId: deviceId,
        span: span,
        shell: shell,
        view: view,
        column: column,
      );

  /// Both style axes at once — the editor's style sheet writes them together.
  ///
  /// Separate from [copyWith] because "no view" is a VALUE here (it means the
  /// card's default), and an optional named parameter cannot tell that apart
  /// from "leave it alone". A sentinel object would; two methods are cheaper to
  /// read.
  HomeTile withStyle({required CardShell shell, required String? view}) =>
      HomeTile(
        kind: kind,
        module: module,
        deviceId: deviceId,
        span: span,
        column: column,
        shell: shell,
        view: normaliseCardView(module, view),
      );

  Map<String, Object?> toJson() => {
        'kind': kind.slug,
        if (module != null) 'module': module!.name,
        if (deviceId != null) 'device': deviceId,
        'span': span.slug,
        // Defaults are written as ABSENCE, both of them. Writing `standard` into
        // every row would have to be told apart from never set
        // (`display_layout.dart`), and it would grow every stored layout for a
        // value that is already the answer.
        if (shell != CardShell.standard) 'shell': shell.slug,
        if (storedView != null) 'view': storedView,
        // Written for `half` only. A `full` has no side, and an absent key is
        // how "this build had not heard of columns yet" reads on the way back
        // in — [HomeLayout.seated] fills it from the position, so absence is a
        // migration, not a loss (design 0084 §4.2).
        if (column != null) 'column': column!.slug,
      };

  /// Read one stored tile. Returns null for anything this build cannot make
  /// sense of, so [HomeLayout.decode] can drop it rather than throw.
  static HomeTile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = HomeTileKind.fromSlug(raw['kind'] as String?);
    if (kind == null) return null;
    final span = HomeSpan.fromSlug(raw['span'] as String?) ?? HomeSpan.full;
    final device = raw['device'] is String ? raw['device'] as String : null;
    // 🔴 Unknown shell / view ⇒ THE DEFAULT, and the tile survives. That is the
    // opposite of the `module` rule twenty lines down, which drops the tile, and
    // the asymmetry is deliberate: a module is what the card SAYS, a shell and a
    // view are only how it looks. Losing a card because a later build retired a
    // frame style would be a blank space where a reading used to be.
    final shell = CardShell.fromSlug(raw['shell'] as String?) ??
        CardShell.standard;
    final storedView = raw['view'] is String ? raw['view'] as String : null;
    // 🔴 Unknown / missing / garbage ⇒ null, and [HomeLayout.seated] decides.
    // Same rule as shell and view one line up: a value this build cannot read
    // must not cost the user a card.
    final column = HomeColumn.fromSlug(raw['column'] as String?);
    switch (kind) {
      case HomeTileKind.addDevice:
        return const HomeTile.addDevice();
      case HomeTileKind.deviceCard:
        // A device card with no device is not a tile, it is a corrupt row.
        if (device == null) return null;
        return HomeTile.device(device,
            span: span, shell: shell, column: column);
      case HomeTileKind.module:
        final name = raw['module'];
        for (final m in DisplayModule.values) {
          if (m.name == name) {
            return HomeTile.module(m,
                deviceId: device,
                span: span,
                shell: shell,
                column: column,
                // Resolved against THIS module's vocabulary. A slug belonging to
                // another card ("analog" on a readouts tile) is not an error and
                // not a dropped tile — it is simply not a word this card knows,
                // so the card draws its default.
                view: normaliseCardView(m, storedView));
          }
        }
        // A module this build does not know: a layout written by a newer
        // version, or one whose member was retired. Dropping the tile is the
        // same choice `DisplayLayout.decode` makes for an unknown face slug.
        return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is HomeTile &&
      other.kind == kind &&
      other.module == module &&
      other.deviceId == deviceId &&
      other.span == span &&
      other.shell == shell &&
      other.view == view &&
      other.column == column;

  @override
  int get hashCode =>
      Object.hash(kind, module, deviceId, span, shell, view, column);

  @override
  String toString() =>
      'HomeTile(${kind.slug}${module == null ? '' : ':${module!.name}'}'
      '${deviceId == null ? '' : '@$deviceId'}, ${span.slug}'
      '${shell == CardShell.standard ? '' : ', ${shell.slug}'}'
      '${view == null ? '' : ', $view'}'
      '${column == null ? '' : ', ${column!.slug}'})';
}

/// One horizontal band of the home grid: either a single full-width tile, or a
/// pair of columns (design 0084 S2).
///
/// 🔑 Two lists rather than a list of rows, and that IS the design: rows force
/// the two sides to advance together, which is what leaves a hole under the
/// shorter card. Columns advance independently, and their bottoms are allowed
/// to disagree — owner ruled 2026-08-23「可以不等長」.
class HomeBlock {
  const HomeBlock.full(int index)
      : full = index,
        left = const [],
        right = const [];

  const HomeBlock.columns(this.left, this.right) : full = null;

  /// FLAT INDEX of the full-width tile, or null for a two-column band.
  ///
  /// 🔑 Indices rather than tiles, because the editor needs to say "this one"
  /// back to [HomeGridOps] and a tile is not an identity — two units can hold
  /// the same module with the same style, and `==` cannot tell them apart. The
  /// home page simply looks each one up. One segmentation rule, two callers;
  /// the alternative is two implementations of it, which is the shape of defect
  /// this file's history is made of.
  final int? full;

  /// Flat indices, in the order they stack.
  final List<int> left;
  final List<int> right;

  /// This band's first flat index — where a drop line ABOVE it inserts.
  int get start =>
      full ?? [...left, ...right].reduce((a, b) => a < b ? a : b);

  /// One past this band's last flat index — where the foot of one of its
  /// columns inserts, so the card lands inside the band rather than after
  /// whatever ends it.
  int get end =>
      full != null ? full! + 1 : [...left, ...right].reduce((a, b) => a > b ? a : b) + 1;
}

/// The home page's grid.
class HomeLayout {
  const HomeLayout(this.tiles);

  final List<HomeTile> tiles;

  /// JSON key for the tile list. Also the token the export preamble uses, so
  /// the two cannot drift apart.
  static const String tilesKey = 'tiles';

  /// The layout a user who has never opened the editor gets (design 0046 R5 /
  /// §4.6).
  ///
  /// 🔴 NEVER returns an empty list (T-new-2). The home page is the app's
  /// default entry point since R3; an empty one is a blank screen on launch,
  /// which is the worst possible outcome of a feature whose whole purpose is
  /// "there is always something to look at".
  /// The phone's own modules, appended to every generated layout.
  ///
  /// 🔴 Added unconditionally, and [renderedFor] is what removes them again
  /// when their switch is off. That split is deliberate: `defaultFor` stays a
  /// pure function of the device list, and there is exactly ONE place that
  /// decides whether a phone module may be drawn.
  ///
  /// They are here at all because of a field report (2026-08-07): a user who
  /// had turned on speed detection and calibrated the G meter found neither on
  /// the home page, because the generated layout only ever contained device
  /// cards. The only way to add them was the editor, which the same report
  /// could not find. Somebody who enables a phone module has said what they
  /// want to see; making them go and say it a second time is the app not
  /// listening.
  ///
  /// Half width: two phone readouts fit one row, and they belong together
  /// visually — neither is about the battery above them.
  /// 🔴 FULL span, not a half pair — changed 2026-08-08.
  ///
  /// They were a 1x1 pair, which reads well only when both survive. They do
  /// not: `speed_detection` defaults OFF, so [renderedFor] drops the speed tile
  /// on almost every phone and the G meter is left as an orphaned half. That
  /// orphan is what made the home page look broken, and it is a layout no user
  /// ever chose.
  ///
  /// Full span removes the pair, so there is nothing to be orphaned FROM. A
  /// lone 1x1 now only exists when someone made one in the editor — where it
  /// is drawn at half width, because that is what they asked for.
  static const List<HomeTile> _phoneTiles = [
    HomeTile.module(DisplayModule.speed),
    HomeTile.module(DisplayModule.gForce),
  ];

  static HomeLayout defaultFor(List<SavedDevice> devices) {
    if (devices.isEmpty) {
      return const HomeLayout([HomeTile.addDevice(), ..._phoneTiles]);
    }
    if (devices.length == 1) {
      final d = devices.single;
      // The SAME rule `watchfaces.dart` uses, copied rather than re-invented: a
      // power bank's instrument reads state of charge, everything else reads
      // the rail. Re-deriving it here from, say, the alias would be a second
      // opinion about what a device is — which is exactly the class of guess
      // FB-43 came from.
      final gauge = d.productClass == ProductClass.powerBank
          ? DisplayModule.gaugeSoc
          : DisplayModule.gaugeVoltage;
      return HomeLayout([
        // 🔴 The device card comes FIRST, added 2026-08-07.
        //
        // The module tiles below read LIVE telemetry, so with the unit not
        // connected — which is how the app is opened most of the time — they
        // both fall back to `_WaitingTile` and the whole page says `--` twice.
        // `_WaitingTile`'s own doc comment excused that on the grounds that
        // "the device card says when that unit was last seen"; for the
        // single-device default there was no device card, so the excuse was
        // never true here.
        //
        // This tile reads `saved_devices`, not the link, so it has something
        // honest to say whether or not anything is connected: the unit's name,
        // its last voltage, and how long ago that was.
        HomeTile.device(d.id),
        HomeTile.module(gauge, deviceId: d.id),
        HomeTile.module(DisplayModule.readouts, deviceId: d.id),
        ..._phoneTiles,
      ]);
    }
    return HomeLayout([
      for (final d in devices) HomeTile.device(d.id),
      ..._phoneTiles,
    ]);
  }

  Map<String, Object?> toJson() => {
        tilesKey: [for (final t in tiles) t.toJson()],
      };

  /// The exact string stored in `settings.home_layout`.
  /// What the home page ACTUALLY draws, given the devices and the switches.
  ///
  /// 🔑 The home surface's own resolver — the twin of `renderedModules`, not a
  /// user of it.
  ///
  /// Ruled 2026-08-07: **the home grid and the watchface layer are two separate
  /// systems and stay separate.** The watchface layer resolves a stored
  /// `Watchface` into a module list; the home grid has no watchface at all, so
  /// forcing it through that path would mean inventing a fake face for it. What
  /// the two share is exactly one thing — [phoneModuleAvailable], a fact about
  /// the PHONE rather than about either surface.
  ///
  /// This function is the single place that answers "what is on the home page",
  /// and it exists as a named function rather than as checks inside widget
  /// builds for the reason this project keeps rediscovering: a decision buried
  /// in `build` is a decision no test can reach. Two separate filters used to
  /// live here — one pruning ghosts, one gating phone modules, added a day
  /// apart — and merging them is what makes "the home page draws X" a single
  /// question with a single answer.
  ///
  /// It removes two kinds of tile:
  ///
  /// 1. **Ghosts** — a tile naming a device that no longer exists. Pruning
  ///    happens at RENDER time and never touches storage: rewriting the stored
  ///    layout would lose the user's arrangement the moment a unit is removed
  ///    and re-paired, which an iOS NSUUID rotation (design 0027 D.3) does
  ///    without anybody asking. Filter the view and both hold — the ghost is
  ///    gone now, and if the unit returns its card returns where it was.
  /// 2. 🔴 **Phone modules whose switch is off.** This is link 1 of design
  ///    0042's privacy chain on this surface. A stored `speed` tile with
  ///    detection OFF used to mount a `SpeedCard`, which opens the GNSS stream
  ///    — while the export preamble said `speed detection: off` and the consent
  ///    dialog had never been shown. `watchfaces.dart` claimed "every render
  ///    path reads this" of its own resolver; that was true when written, and
  ///    design 0046 added this surface without anyone checking the seam.
  ///
  /// `addDevice` and device-less tiles are never pruned for reason 1 — they
  /// belong to the phone, not to any unit.
  HomeLayout renderedFor(
    List<SavedDevice> devices,
    AppSettings settings, {
    required bool gForceAvailable,
  }) {
    // 🔴 A device with no product class is not shown AT ALL — not its module
    // tiles and not even its device card (design 0050 D4).
    //
    // The class is what says which instrument a number belongs on, and FB-43
    // is what happens when a page asserts one nobody established: a power
    // bank's single-cell 3.79 V drawn under「PVLT 主電壓」on a gauge that pins
    // it to the bottom of the sweep. Every number was real; the screen was
    // false. So the home surface waits rather than guessing — the class is
    // written back to `saved_devices` off every telemetry sample of a
    // connection that has read `0x10`
    // (`ConnectionController._persistProductClass`), and the tiles appear then.
    //
    // ⚠️ "every sample", not "the first connect": the write used to be attempted
    // exactly once per class change, which on a first connect happened while
    // the naming dialog was still up — i.e. onto a record that did not exist —
    // so a unit the user had just saved stayed invisible here until the SECOND
    // connect. The retry is what makes this comment true.
    //
    // ⚠️ `known` is the CLASSIFIED ids, not all of them. Both filters below
    // read it, including the empty-fallback path — see the note there.
    final known = {
      for (final d in devices)
        if (d.productClass != ProductClass.unknown) d.id,
    };
    final kept = tiles.where((t) {
      if (t.deviceId != null && !known.contains(t.deviceId)) return false;
      final m = t.module;
      if (m != null && m.isPhoneModule) {
        return phoneModuleAvailable(m, settings,
            gForceAvailable: gForceAvailable);
      }
      return true;
    }).toList(growable: false);
    // An empty page is forbidden outright (T-new-2), and "every card you had
    // names a deleted device" is a real path to one. Falling back to the
    // generated default is the same answer `decode` gives for unusable content.
    if (kept.isEmpty) {
      // Filter the fallback too — `defaultFor` now offers phone modules, and
      // handing back an unavailable one here would walk straight past the gate
      // this method exists to be.
      // ⚠️ `defaultFor` is given the CLASSIFIED devices only. Handing it the
      // full list here would regenerate tiles for exactly the units the filter
      // above just removed — the fallback walking straight past the gate it
      // exists behind. (Design 0050 R3 named this hazard before it was written;
      // this is the line it was about.)
      final classified = [
        for (final d in devices)
          if (d.productClass != ProductClass.unknown) d,
      ];
      final fallback = HomeLayout.defaultFor(classified).tiles.where((t) {
        final m = t.module;
        return m == null ||
            !m.isPhoneModule ||
            phoneModuleAvailable(m, settings, gForceAvailable: gForceAvailable);
      }).toList(growable: false);
      return HomeLayout(
          fallback.isEmpty ? const [HomeTile.addDevice()] : fallback);
    }
    // 🔵 design 0084 S4: NOT re-seated. In S1 filtering had to re-derive,
    // because the column was a copy of the position and filtering moves
    // positions. Now the column is the user's own answer, and a filtered card
    // must not drag its neighbour to the other side of the page — the tiles
    // that survive keep the side they were given.
    return HomeLayout(kept);
  }

  String encode() => jsonEncode(toJson());

  /// Read a stored column value. NEVER throws — see the library comment.
  ///
  /// Returns null for "not customised", which is what a NULL column means and
  /// what unparseable content is treated as. A layout whose tiles are ALL
  /// unreadable is also null rather than an empty grid: an empty grid is a
  /// blank home screen, and nobody chose that.
  static HomeLayout? decode(Object? stored) {
    if (stored is! String || stored.isEmpty) return null;
    Object? parsed;
    try {
      parsed = jsonDecode(stored);
    } on FormatException {
      return null;
    }
    if (parsed is! Map) return null;
    final raw = parsed[tilesKey];
    if (raw is! List) return null;
    // 🔴 The pre-S4 placeholder is READ, then dropped — and the order matters.
    //
    // A layout written before design 0084 S4 stores a tile whose kind is
    // `empty` for the unoccupied half of a row (design 0049 §3.8). It is not a
    // tile any more, but its POSITION is the only record of which side its
    // neighbour was on. Dropping it first and seating afterwards would repack
    // the halves — `[A, gap, B, C]` would come back as `A|B` then `C` instead
    // of `A` then `B|C` — which is somebody's home page rearranging itself on
    // an update. So a gap is carried through the walk as a null and removed
    // after the seating.
    final walked = <HomeTile?>[
      for (final t in raw)
        if (t is Map && t['kind'] == legacyGapSlug)
          null
        else
          ?HomeTile.fromJson(t),
    ];
    final tiles = seated(walked);
    if (tiles.isEmpty) return null;
    // 🔴 THE MIGRATION (design 0084 §4.2 / Q3, ruled "無損轉換").
    //
    // A layout stored before columns existed carries none, and one stored by a
    // later build carries values this build must not simply trust either — a
    // hand-edited database can say `left, left` for one row. Deriving from the
    // POSITION every time makes both cases the same case, and makes the ruling
    // literally true: the three layouts real users are known to have
    // (`export_header.dart`'s `home: tiles=` line, 124 captures) come back out
    // drawing pixel-for-pixel what they drew before.
    //
    // ⚠️ Read-only. This does NOT write back to `settings.home_layout` — a
    // migration that rewrote storage on first read would spend the user's only
    // copy of the old value before anything had been shown to them.
    return HomeLayout(tiles);
  }

  /// The stored slug of the pre-S4 placeholder (design 0049 §3.8), kept so
  /// [decode] can still read a layout written before design 0084 S4.
  ///
  /// ⚠️ READ-only. Nothing writes it any more, and `exportHomeValue` no longer
  /// emits it — a capture from an older build may still contain it, which is
  /// correct: it describes what that build drew.
  static const String legacyGapSlug = 'empty';

  /// Give every `half` a column and every `full` none.
  ///
  /// 🔴 A STORED column is honoured, never recomputed — that is the whole of
  /// design 0084 Q1. Only a half that has none gets one derived from its
  /// position, which is exactly the pre-S4 case: alternate sides within a run
  /// of halves, and a `full` ends the run because it owns the whole width.
  ///
  /// A null element is a pre-S4 gap: it takes a side (so the tile after it
  /// lands where that build drew it) and is then dropped.
  ///
  /// ⚠️ The derivation is the MIGRATION, not the model. After S4 a layout can
  /// hold three cards in the left column and one in the right, which no
  /// position could have expressed — so re-deriving a seated layout would
  /// flatten exactly the arrangement the user was given the ability to make.
  static List<HomeTile> seated(List<HomeTile?> tiles) {
    final out = <HomeTile>[];
    var slot = 0;
    for (final t in tiles) {
      if (t == null) {
        slot += 1; // a gap holds a side without being a card
        continue;
      }
      if (t.span == HomeSpan.full) {
        slot = 0;
        out.add(t.column == null ? t : t.withColumn(null));
        continue;
      }
      final side = t.column ?? (slot.isEven ? HomeColumn.left : HomeColumn.right);
      slot += 1;
      out.add(t.column == side ? t : t.withColumn(side));
    }
    return out;
  }

  /// The grid as the home page draws it since design 0084 S2: a run of
  /// full-width tiles and two-column blocks, in order.
  ///
  /// ## 🔴 This is where the authority moves
  ///
  /// [rowsOf] packs by POSITION — pairs of adjacent halves. This packs by
  /// [HomeTile.column], and the difference is the feature: a column keeps
  /// stacking, so the card under a short one starts where that short one ENDS
  /// rather than where the tallest card of its row ends. That gap is the thing
  /// design 0084 was opened about.
  ///
  /// Both are correct in S2 and give the same grouping, because S1's
  /// [withDerivedColumns] seats every half at the side its position already
  /// implied. They stop agreeing in S4, when the editor can put two cards in
  /// one column — and at that point [rowsOf] is what goes, not this.
  ///
  /// ⚠️ A `full` tile ENDS a block. Two columns cannot span it (it is the whole
  /// width), so consecutive halves either side of a full are two separate
  /// blocks — which is also what makes the default layout, every tile of which
  /// is full, cost nothing here.
  static List<HomeBlock> blocksOf(List<HomeTile> tiles) {
    final out = <HomeBlock>[];
    var left = <int>[];
    var right = <int>[];
    void flush() {
      if (left.isEmpty && right.isEmpty) return;
      out.add(HomeBlock.columns(left, right));
      left = <int>[];
      right = <int>[];
    }

    for (var i = 0; i < tiles.length; i++) {
      final t = tiles[i];
      if (t.span == HomeSpan.full) {
        flush();
        out.add(HomeBlock.full(i));
        continue;
      }
      // ⚠️ A half with no column can only reach here if something bypassed
      // [seated] (decode and `HomeGridOps.normalise` both run it). Treating it
      // as LEFT keeps the card on screen rather than dropping it — the same
      // choice `fromJson` makes for an unreadable shell.
      (t.column == HomeColumn.right ? right : left).add(i);
    }
    flush();
    return out;
  }

  /// ⚠️ `rows` / `rowsOf` were removed by design 0084 S4.
  ///
  /// They packed by POSITION — pairs of adjacent halves — which is the model
  /// the stored placeholder existed to hold together. [blocksOf] replaces both,
  /// and the difference is not a refactor: a column can hold three cards while
  /// the other holds one, and no ordering expresses that.

  @override
  bool operator ==(Object other) =>
      other is HomeLayout &&
      other.tiles.length == tiles.length &&
      () {
        for (var i = 0; i < tiles.length; i++) {
          if (tiles[i] != other.tiles[i]) return false;
        }
        return true;
      }();

  @override
  int get hashCode => Object.hashAll(tiles);

  @override
  String toString() => 'HomeLayout(${tiles.join(', ')})';
}
