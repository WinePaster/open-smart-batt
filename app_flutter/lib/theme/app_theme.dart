/// OpenSmartBatt — industrial theme (light / dark).
///
/// Colors/typography lifted from the project's own UI mockup (mockup/index.html
/// CSS `:root`): carbon background, thin frames, amber accent, cyan secondary,
/// tabular-numeric monospace for readouts. Portrait-locked app.
///
/// The brand ACCENTS ([AppColors]) are identical in both themes; only the
/// NEUTRALS flip. Neutrals live in the [AppPalette] [ThemeExtension] attached to
/// both [ThemeData]s — read them via `context.colors` so every widget (Material
/// and custom-painted alike) follows the effective brightness.
library;

import 'package:flutter/material.dart';

/// Brand accent palette (mockup CSS custom properties). IDENTICAL in light and
/// dark — kept `const` so accent-only widgets can stay `const`.
class AppColors {
  AppColors._();

  static const Color amber = Color(0xFFF6A821); // --amber (accent / gauge)
  static const Color amberDark = Color(0xFFC8861A); // --amber-d
  static const Color cyan = Color(0xFF46D4C8); // --cyan (secondary)
  static const Color danger = Color(0xFFFF5765); // --danger
  static const Color good = Color(0xFF5AD27E); // --good

  /// Foreground used on top of amber fills (mockup `#1a1205`).
  static const Color onAmber = Color(0xFF1A1205);
}

/// Neutral palette that flips between light and dark. Attached to [ThemeData]
/// via [ThemeData.extensions]; read through [BuildContextPalette.colors].
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.bg,
    required this.panel,
    required this.panel2,
    required this.line,
    required this.line2,
    required this.text,
    required this.muted,
  });

  /// Scaffold / canvas background (mockup `--bg`).
  final Color bg;

  /// Card / panel surface (mockup `--panel`).
  final Color panel;

  /// Inset / secondary surface (mockup `--panel2`).
  final Color panel2;

  /// Hairline / divider (mockup `--line`).
  final Color line;

  /// Slightly stronger hairline (mockup `--line2`).
  final Color line2;

  /// Primary foreground text (mockup `--txt`).
  final Color text;

  /// Muted / secondary text (mockup `--muted`).
  final Color muted;

  /// Dark neutrals — the original industrial values.
  static const AppPalette dark = AppPalette(
    bg: Color(0xFF0B0D11),
    panel: Color(0xFF14171D),
    panel2: Color(0xFF1B1F27),
    line: Color(0xFF2A3039),
    line2: Color(0xFF363D48),
    text: Color(0xFFE8EDF4),
    muted: Color(0xFF838D9C),
  );

  /// Light neutrals — high-contrast counterpart (DEFAULT theme).
  static const AppPalette light = AppPalette(
    bg: Color(0xFFF4F6FA),
    panel: Color(0xFFFFFFFF),
    panel2: Color(0xFFEDF0F5),
    line: Color(0xFFD4DAE3),
    line2: Color(0xFFC1C9D5),
    text: Color(0xFF11151B),
    muted: Color(0xFF66707D),
  );

  @override
  AppPalette copyWith({
    Color? bg,
    Color? panel,
    Color? panel2,
    Color? line,
    Color? line2,
    Color? text,
    Color? muted,
  }) =>
      AppPalette(
        bg: bg ?? this.bg,
        panel: panel ?? this.panel,
        panel2: panel2 ?? this.panel2,
        line: line ?? this.line,
        line2: line2 ?? this.line2,
        text: text ?? this.text,
        muted: muted ?? this.muted,
      );

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      bg: Color.lerp(bg, other.bg, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      panel2: Color.lerp(panel2, other.panel2, t)!,
      line: Color.lerp(line, other.line, t)!,
      line2: Color.lerp(line2, other.line2, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
    );
  }
}

/// `context.colors` → the active [AppPalette]. Falls back to dark if (somehow)
/// no extension is attached.
extension BuildContextPalette on BuildContext {
  AppPalette get colors =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.dark;
}

/// Reusable text styles. Monospace family list mirrors the mockup `--mono`.
///
/// These carry NEUTRAL colors, so they are methods taking a [BuildContext]:
/// the color follows the active [AppPalette].
class AppTextStyles {
  AppTextStyles._();

  static const List<String> monoFallback = [
    'SF Mono',
    'Roboto Mono',
    'JetBrains Mono',
    'monospace',
  ];

  /// Large gauge readout (mockup `.ring .num`).
  static TextStyle gaugeValue(BuildContext context) => TextStyle(
        fontSize: 50,
        height: 1.0,
        fontWeight: FontWeight.w700,
        letterSpacing: -1,
        color: context.colors.text,
      );

  /// Readout-grid value (mockup `.stat .v`), tabular numerals.
  static TextStyle statValue(BuildContext context) => TextStyle(
        fontFamilyFallback: monoFallback,
        fontFeatures: const [FontFeature.tabularFigures()],
        fontSize: 23,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
        color: context.colors.text,
      );

  /// Section header (mockup `.card h3`): uppercase, muted, wide tracking.
  static TextStyle cardHeading(BuildContext context) => TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 2,
        color: context.colors.muted,
      );

  /// Small muted label (mockup `.stat .k`).
  static TextStyle label(BuildContext context) => TextStyle(
        fontSize: 10,
        letterSpacing: 1,
        color: context.colors.muted,
      );

  /// Monospace data line (mockup `.mono`).
  static TextStyle mono(BuildContext context) => TextStyle(
        fontFamilyFallback: monoFallback,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: context.colors.text,
      );
}

/// Builds the app-wide [ThemeData] for light and dark.
class AppTheme {
  AppTheme._();

  /// Standard card padding (mockup `.card { padding: 15px }`).
  static const EdgeInsets cardPadding = EdgeInsets.all(15);

  /// Standard corner radius for panels/cards (mockup 12px).
  static const double radius = 12;

  /// Industrial dark theme (the original mockup look).
  static ThemeData dark() => _build(Brightness.dark, AppPalette.dark);

  /// Industrial light theme (high-contrast counterpart, DEFAULT).
  static ThemeData light() => _build(Brightness.light, AppPalette.light);

  static ThemeData _build(Brightness brightness, AppPalette p) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: AppColors.amber,
      onPrimary: AppColors.onAmber,
      secondary: AppColors.cyan,
      onSecondary: AppColors.onAmber,
      surface: p.panel,
      onSurface: p.text,
      error: AppColors.danger,
      onError: brightness == Brightness.dark ? p.text : Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      extensions: [p],
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      dividerColor: p.line,
      cardColor: p.panel,
      cardTheme: CardThemeData(
        color: p.panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: p.line),
        ),
        margin: const EdgeInsets.only(bottom: 14),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        foregroundColor: p.text,
        elevation: 0,
        centerTitle: false,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: p.panel,
        selectedItemColor: AppColors.amber,
        unselectedItemColor: p.muted,
        type: BottomNavigationBarType.fixed,
        showUnselectedLabels: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.amber,
          foregroundColor: AppColors.onAmber,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.text,
          backgroundColor: p.panel2,
          side: BorderSide(color: p.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.onAmber
              : (brightness == Brightness.dark
                  ? const Color(0xFFDFE5EE)
                  : Colors.white),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.amber : p.panel2,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: p.line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.bg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: p.line2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: AppColors.amber),
        ),
      ),
      textTheme: TextTheme(
        bodyMedium: TextStyle(color: p.text),
        bodySmall: TextStyle(color: p.muted),
        titleMedium: TextStyle(color: p.text, fontWeight: FontWeight.w700),
      ),
    );
  }
}
