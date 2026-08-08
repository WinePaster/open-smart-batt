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

/// What a tile draws.
enum HomeTileKind {
  /// The zero-device empty state: "add your first device".
  addDevice,

  /// One unit's summary card — alias, status, and either a live reading or the
  /// last one WITH its age (T-new-3).
  deviceCard,

  /// One [DisplayModule], optionally bound to a device.
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
  });

  /// A [DisplayModule] tile.
  const HomeTile.module(DisplayModule module,
      {String? deviceId, HomeSpan span = HomeSpan.full})
      : this(
            kind: HomeTileKind.module,
            module: module,
            deviceId: deviceId,
            span: span);

  /// One unit's summary card.
  const HomeTile.device(String deviceId, {HomeSpan span = HomeSpan.full})
      : this(
            kind: HomeTileKind.deviceCard, deviceId: deviceId, span: span);

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

  HomeTile copyWith({HomeSpan? span, String? deviceId}) => HomeTile(
        kind: kind,
        module: module,
        deviceId: deviceId ?? this.deviceId,
        span: span ?? this.span,
      );

  Map<String, Object?> toJson() => {
        'kind': kind.slug,
        if (module != null) 'module': module!.name,
        if (deviceId != null) 'device': deviceId,
        'span': span.slug,
      };

  /// Read one stored tile. Returns null for anything this build cannot make
  /// sense of, so [HomeLayout.decode] can drop it rather than throw.
  static HomeTile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = HomeTileKind.fromSlug(raw['kind'] as String?);
    if (kind == null) return null;
    final span = HomeSpan.fromSlug(raw['span'] as String?) ?? HomeSpan.full;
    final device = raw['device'] is String ? raw['device'] as String : null;
    switch (kind) {
      case HomeTileKind.addDevice:
        return const HomeTile.addDevice();
      case HomeTileKind.deviceCard:
        // A device card with no device is not a tile, it is a corrupt row.
        if (device == null) return null;
        return HomeTile.device(device, span: span);
      case HomeTileKind.module:
        final name = raw['module'];
        for (final m in DisplayModule.values) {
          if (m.name == name) {
            return HomeTile.module(m, deviceId: device, span: span);
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
      other.span == span;

  @override
  int get hashCode => Object.hash(kind, module, deviceId, span);

  @override
  String toString() =>
      'HomeTile(${kind.slug}${module == null ? '' : ':${module!.name}'}'
      '${deviceId == null ? '' : '@$deviceId'}, ${span.slug})';
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
    // written back to `saved_devices` on the first connect that reads `0x10`
    // (`connection_controller.dart`), and the tiles appear then.
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
    final tiles = <HomeTile>[
      for (final t in raw) ?HomeTile.fromJson(t),
    ];
    if (tiles.isEmpty) return null;
    return HomeLayout(tiles);
  }

  /// Greedy row packing: two consecutive halves share a row, a full owns one,
  /// and an orphan half keeps the left of its own row. This is the whole of
  /// what design 0046 §3.3's `rows[]` would have stored — derived instead of
  /// persisted, so the editor can keep a flat list to drag.
  List<List<HomeTile>> get rows {
    final out = <List<HomeTile>>[];
    var i = 0;
    while (i < tiles.length) {
      final t = tiles[i];
      if (t.span == HomeSpan.half &&
          i + 1 < tiles.length &&
          tiles[i + 1].span == HomeSpan.half) {
        out.add([t, tiles[i + 1]]);
        i += 2;
      } else {
        out.add([t]);
        i += 1;
      }
    }
    return out;
  }

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
