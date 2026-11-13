/// OpenSmartBatt — the geometry rules of the landscape layout (design 0105,
/// option (ii), owner ruling 2026-11-13).
///
/// Every landscape decision the UI makes is answered here, from the window's
/// SHAPE and the width actually available — never from the orientation
/// setting (`OrientationPolicy` decides only what the OS may rotate to). So a
/// head unit whose firmware forces landscape gets the designed layout even
/// with 「允許橫式畫面」 off.
///
/// 🔴 **Portrait is never touched.** Every rule below starts with
/// [isLandscape]; a window taller than it is wide — every phone held upright,
/// a tablet held upright — renders exactly what it rendered before design
/// 0105. That is the hard requirement of the change.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';

/// See the library doc.
abstract final class WideLayout {
  /// Width from which a landscape window trades the bottom bar for a left
  /// [NavigationRail] (0105 §6 P2). A landscape phone (844 × 390) is above it.
  static const double railMinWidth = 600;

  /// Height below which the rail also takes over the brand bar's connection
  /// pill and full-screen button, and the top bar goes away (0105 P2, mock §5
  /// right). A phone on its side (≈ 390) is below it; a 1.5-density head unit
  /// (853 × 480) is not, and keeps the bar as in mock §2.
  static const double compactRailMaxHeight = 450;

  /// The narrowest column the multi-column pages lay cards into: the content
  /// width of a 360 dp phone in portrait (360 − 2 × 15 padding), i.e. a width
  /// every card has already been laid out at on a real phone (0105 §4.4).
  static const double columnMinWidth = 330;

  /// The widest a column may grow: the `maxWidth: 560` every single-column
  /// page already uses (0105 Q4).
  static const double columnMaxWidth = 560;

  /// Gap between columns — the vertical rhythm of the cards themselves
  /// (`cardTheme.margin` bottom 14).
  static const double columnGap = 14;

  /// The user's OWN text enlargement ([AppTheme.userTextScale]) from which a
  /// landscape page lays out one column fewer (0105 Q7 = A「字大就自動少一欄」).
  ///
  /// [AppTheme.userTextScale] divides out the app's own text-size factor, so
  /// it reads 1.0 at the default OS font under BOTH 大 and 小; this threshold
  /// therefore reacts only to the system font being turned up — Android's
  /// first step above default is 1.15 — and not to the app's 大／小 choice,
  /// which never makes a card wider than the portrait phone already drew it.
  static const double largeTextThreshold = 1.1;

  /// Wider than tall. The gate every landscape rule starts from.
  static bool isLandscape(Size window) => window.width > window.height;

  /// Left [NavigationRail] instead of the bottom bar.
  static bool useRail(Size window) =>
      isLandscape(window) && window.width >= railMinWidth;

  /// The rail also carries the connection pill and full-screen button; no
  /// top bar.
  static bool compactRail(Size window) =>
      useRail(window) && window.height < compactRailMaxHeight;

  /// Whether the user's system font is large enough to drop a column.
  static bool largeText(BuildContext context) =>
      AppTheme.userTextScale(context) >= largeTextThreshold;

  /// How many columns fit in [width] (the content width, padding already
  /// removed): clamp(⌊(width + gap) ÷ (min + gap)⌋, 1, [max]), then one fewer
  /// when [largeText] (Q7), never fewer than one.
  static int columnsFor(double width, {int max = 3, bool largeText = false}) {
    final fit = ((width + columnGap) / (columnMinWidth + columnGap)).floor();
    final n = fit.clamp(1, max) - (largeText ? 1 : 0);
    return math.max(1, n);
  }

  /// The total width [columns] columns occupy at most, gaps included.
  static double maxWidthFor(int columns) =>
      columns * columnMaxWidth + (columns - 1) * columnGap;
}
