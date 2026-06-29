/// Open-RCE-Batt — industrial dark theme.
///
/// Colors/typography lifted from the project's own UI mockup (mockup/index.html
/// CSS `:root`): carbon background, thin frames, amber accent, cyan secondary,
/// tabular-numeric monospace for readouts. Portrait-locked app.
library;

import 'package:flutter/material.dart';

/// Palette (mockup CSS custom properties).
class AppColors {
  AppColors._();

  static const Color bg = Color(0xFF0B0D11); // --bg
  static const Color panel = Color(0xFF14171D); // --panel
  static const Color panel2 = Color(0xFF1B1F27); // --panel2
  static const Color line = Color(0xFF2A3039); // --line
  static const Color line2 = Color(0xFF363D48); // --line2
  static const Color text = Color(0xFFE8EDF4); // --txt
  static const Color muted = Color(0xFF838D9C); // --muted
  static const Color amber = Color(0xFFF6A821); // --amber (accent / gauge)
  static const Color amberDark = Color(0xFFC8861A); // --amber-d
  static const Color cyan = Color(0xFF46D4C8); // --cyan (secondary)
  static const Color danger = Color(0xFFFF5765); // --danger
  static const Color good = Color(0xFF5AD27E); // --good

  /// Foreground used on top of amber fills (mockup `#1a1205`).
  static const Color onAmber = Color(0xFF1A1205);
}

/// Reusable text styles. Monospace family list mirrors the mockup `--mono`.
class AppTextStyles {
  AppTextStyles._();

  static const List<String> monoFallback = [
    'SF Mono',
    'Roboto Mono',
    'JetBrains Mono',
    'monospace',
  ];

  /// Large gauge readout (mockup `.ring .num`).
  static const TextStyle gaugeValue = TextStyle(
    fontSize: 50,
    height: 1.0,
    fontWeight: FontWeight.w700,
    letterSpacing: -1,
    color: AppColors.text,
  );

  /// Readout-grid value (mockup `.stat .v`), tabular numerals.
  static const TextStyle statValue = TextStyle(
    fontFamilyFallback: monoFallback,
    fontFeatures: [FontFeature.tabularFigures()],
    fontSize: 23,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    color: AppColors.text,
  );

  /// Section header (mockup `.card h3`): uppercase, muted, wide tracking.
  static const TextStyle cardHeading = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 2,
    color: AppColors.muted,
  );

  /// Small muted label (mockup `.stat .k`).
  static const TextStyle label = TextStyle(
    fontSize: 10,
    letterSpacing: 1,
    color: AppColors.muted,
  );

  /// Monospace data line (mockup `.mono`).
  static const TextStyle mono = TextStyle(
    fontFamilyFallback: monoFallback,
    fontFeatures: [FontFeature.tabularFigures()],
    color: AppColors.text,
  );
}

/// Builds the app-wide [ThemeData] (industrial dark).
class AppTheme {
  AppTheme._();

  /// Standard card padding (mockup `.card { padding: 15px }`).
  static const EdgeInsets cardPadding = EdgeInsets.all(15);

  /// Standard corner radius for panels/cards (mockup 12px).
  static const double radius = 12;

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: AppColors.amber,
      onPrimary: AppColors.onAmber,
      secondary: AppColors.cyan,
      onSecondary: AppColors.onAmber,
      surface: AppColors.panel,
      onSurface: AppColors.text,
      error: AppColors.danger,
      onError: AppColors.text,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg,
      canvasColor: AppColors.bg,
      dividerColor: AppColors.line,
      cardColor: AppColors.panel,
      cardTheme: CardThemeData(
        color: AppColors.panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: AppColors.line),
        ),
        margin: const EdgeInsets.only(bottom: 14),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.text,
        elevation: 0,
        centerTitle: false,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.panel,
        selectedItemColor: AppColors.amber,
        unselectedItemColor: AppColors.muted,
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
          foregroundColor: AppColors.text,
          backgroundColor: AppColors.panel2,
          side: const BorderSide(color: AppColors.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.onAmber
              : const Color(0xFFDFE5EE),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.amber
              : AppColors.panel2,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.bg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: AppColors.line2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: AppColors.amber),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: AppColors.text),
        bodySmall: TextStyle(color: AppColors.muted),
        titleMedium:
            TextStyle(color: AppColors.text, fontWeight: FontWeight.w700),
      ),
    );
  }
}
