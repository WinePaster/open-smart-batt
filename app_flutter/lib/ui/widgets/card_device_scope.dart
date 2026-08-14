/// OpenSmartBatt — which unit a card's heading is talking about.
///
/// Owner ruling 2026-08-15, from `2026.08.14-001.md` §1.3 建議 4 / R1:
/// 「主頁的各裝置卡片，在顯示的時候 如分串電壓 要不要改為 [裝置名]分串電壓 這樣的標題
/// (是指已經被擺放到主頁，而不是編輯卡片的時候)」— ruled 方案 D, two lines.
///
/// ## Why a scope and not a parameter
///
/// The obvious implementation threads a `deviceLabel` through
/// [dashboardCardFor] and out into every card widget that draws a heading.
/// That is ~7 files for a label that only ONE surface wants, and — the part
/// that matters — it makes 「只有主頁」 a rule somebody has to keep obeying at
/// each new call site rather than a property of the code.
///
/// As a scope it is structural instead. `_ModuleTile` places one around the
/// card it builds on the HOME grid and nowhere else, so:
///
///  * the dashboard (`pack_view.dart`, `power_bank_view.dart`) is outside every
///    scope and reads null — the owner asked for the home page only;
///  * the home EDITOR's preview is outside too, because `_ModuleTile` returns
///    from its `preview != null` branch before the scope is placed. That is the
///    same early-return that already keeps the editor from touching a
///    controller (design 0051 §5), so the two rules cannot drift apart;
///  * `HomeWaitingTile` needs no plumbing at all. It builds its own
///    [IndustrialCard] inside the scope, so an OFFLINE tile carries the unit's
///    name exactly like a live one — which is the point. A card that changed
///    shape when its unit went offline would make the layout unrecognisable
///    precisely when the user is trying to work out what happened.
///
/// This mirrors `CardStyleScope` (design 0054), including the reason: a
/// `ThemeExtension` would reach all ~26 [IndustrialCard] call sites, and the
/// settings / history / calibration cards must not sprout a device name.
///
/// ## Consumed once
///
/// [IndustrialCard] reads the label and then republishes null below itself, so
/// a card nested inside a card cannot repeat the unit's name. `readouts_card.dart`
/// builds two cards today and they are siblings, not nested — the republish is
/// there so that staying true is not a thing anyone has to remember.
library;

import 'package:flutter/widgets.dart';

/// Carries the display name of the unit whose data the cards below are showing.
///
/// A null [deviceLabel] means "do not say" — either there is no unit (a phone
/// module such as the clock or the G meter) or this surface is not the home
/// grid.
class CardDeviceScope extends InheritedWidget {
  const CardDeviceScope({
    super.key,
    required this.deviceLabel,
    required super.child,
  });

  /// The unit's alias, already resolved — an empty alias is a supported value
  /// (FB-61), so the caller substitutes 「未命名裝置」 rather than passing `''`
  /// and leaving this file to invent a fallback string it has no localizations
  /// for.
  final String? deviceLabel;

  @override
  bool updateShouldNotify(CardDeviceScope oldWidget) =>
      oldWidget.deviceLabel != deviceLabel;
}

/// `context.cardDeviceLabel` → the unit to name in a heading, or null.
///
/// Null with no scope present, the same way `context.cardShell` falls back to
/// `standard`: an unscoped card is a defined rendering (no device line), not an
/// error.
extension BuildContextCardDevice on BuildContext {
  String? get cardDeviceLabel =>
      dependOnInheritedWidgetOfExactType<CardDeviceScope>()?.deviceLabel;
}
