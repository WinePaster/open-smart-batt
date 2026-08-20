/// OpenSmartBatt — WHICH SURFACE a card is being drawn on.
///
/// PURE Dart. Unlike `card_shell.dart` and `card_view.dart`, these names are
/// **NOT wire values**: nothing persists them and nothing prints them into an
/// export preamble. They live here anyway because `dashboardCardFor` takes one
/// as a parameter and the model layer is where its other vocabularies already
/// are — a UI-layer enum would drag `models/` → `ui/` the wrong way round.
///
/// ## Why this exists at all (owner ruling 2026-08-21)
///
/// The ruling was 「數字格 移除 10000mAh」 scoped to 裝置詳情 —— the device page
/// drops the 標示容量 tile, the HOME grid keeps it. Every other per-class
/// difference in this app is answered by [ProductClass] or by the watchface,
/// and neither can answer this one: it is the same module ([DisplayModule
/// .readouts]) on the same class (a power bank) rendering two different item
/// lists depending on where it is.
///
/// ## Why a PARAMETER and not a scope
///
/// `card_device_scope.dart` solved a surface-shaped problem the other way, and
/// the difference is worth stating because the next person will reach for it:
///
///  * that one carries a **heading decoration** (the unit's name) that no card
///    reads a decision from, so an unscoped card has a defined rendering and a
///    forgotten scope is invisible-but-harmless;
///  * this one decides **whether a measured number is printed at all**. A
///    default would let a new call site inherit an answer nobody chose — the
///    exact failure `DisplayModules.forClass` returning null was made to
///    prevent (design 0050 D3), and the one this codebase has shipped four
///    times in callers no test looked at.
///
/// So it is REQUIRED, with no default. A new surface that renders dashboard
/// cards fails to compile until it says which of these it is.
library;

/// Where a dashboard card is being drawn.
enum CardSurface {
  /// The per-unit page (`pack_view.dart` / `power_bank_view.dart`, reached
  /// through `DeviceDetailPage`). The layout here is OURS — a fixed watchface
  /// the user cannot rearrange — so a card that earns its room badly is simply
  /// removed, which is what the 08-16 / 08-17 / 08-21 rulings did to the three
  /// instruments and to the 標示容量 tile.
  deviceDetail,

  /// The home grid (`home_tiles.dart`), including the editor's preview.
  ///
  /// 🔑 The preview counts as `home` deliberately: it exists to show what the
  /// home grid will look like, so a card that rendered differently there would
  /// be lying about the thing it is previewing.
  ///
  /// 🔴 A layout the USER arranged. Nothing is taken off this surface because
  /// we changed our mind about it on ours — the standing rule quoted in
  /// `watchfaces.dart`'s `fixed` case.
  home,
}
