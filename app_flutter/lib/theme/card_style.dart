/// OpenSmartBatt — how a [CardShell] reaches the card that draws it
/// (design 0054).
///
/// ## 🔴 An `InheritedWidget`, deliberately NOT a `ThemeData` extension
///
/// The obvious implementation is a `ThemeExtension` beside [AppPalette]: one
/// place, every widget reads it through `Theme.of`, no plumbing. It is also
/// wrong, and measurably so — there are ~26 [IndustrialCard] call sites and 11
/// of them are in `settings_screen.dart`, `history_screen.dart` and
/// `g_calibration_wizard.dart`. A theme extension means choosing "minimal" for
/// the home page also strips the frames off the settings screen, which nobody
/// asked for and which no test would have caught (nothing renders those screens
/// beside a home tile).
///
/// So the shell travels as a SCOPE, placed by `HomeTileView` around each tile
/// and nowhere else. Everything outside it — the device page, settings, history,
/// the calibration wizard, the drag ghost — reads the fallback,
/// [CardShell.standard]. The fallback is written the same way `context.colors`
/// writes its own (`?? AppPalette.dark`), so an unscoped card is a defined
/// rendering rather than a crash.
///
/// That fallback also makes design 0054 S-R6 true by construction: the shell is
/// a property of the HOME GRID, and the watchface layer cannot see it because
/// nothing on that layer is inside a scope.
library;

import 'package:flutter/widgets.dart';

import '../models/card_shell.dart';

/// Carries the [CardShell] that the cards below should draw with.
class CardStyleScope extends InheritedWidget {
  const CardStyleScope({
    super.key,
    required this.shell,
    required super.child,
  });

  final CardShell shell;

  @override
  bool updateShouldNotify(CardStyleScope oldWidget) =>
      oldWidget.shell != shell;
}

/// `context.cardShell` → the shell in force, or [CardShell.standard] when there
/// is no scope. See the library comment for why the absence is a defined answer
/// rather than an error.
extension BuildContextCardStyle on BuildContext {
  CardShell get cardShell =>
      dependOnInheritedWidgetOfExactType<CardStyleScope>()?.shell ??
      CardShell.standard;

  CardShellTokens get cardShellTokens => cardShell.tokens;

  /// A VALUE type size, scaled by the shell.
  ///
  /// Used by the readings that set their own size directly (the 32 px device
  /// tile / clock digits). [AppTextStyles.gaugeValue] and
  /// [AppTextStyles.statValue] go through the same multiplier, which is why
  /// "values shrink in `dense`" needed no change at any of their call sites —
  /// they already took a [BuildContext].
  double cardValueSize(double base) => base * cardShellTokens.valueScale;

  /// Apply the shell's padding scales to a card's own padding.
  EdgeInsets scaleCardPadding(EdgeInsets p) {
    final t = cardShellTokens;
    return EdgeInsets.fromLTRB(
      p.left * t.padScaleH,
      p.top * t.padScaleV,
      p.right * t.padScaleH,
      p.bottom * t.padScaleV,
    );
  }
}
