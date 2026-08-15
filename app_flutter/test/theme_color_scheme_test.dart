import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/theme/app_theme.dart';

/// `ColorScheme` foreground/background pairings.
///
/// design 0064 Q10. `onSecondary` carried [AppColors.onAmber] while `secondary`
/// was [AppColors.cyan] — a foreground computed for a different colour than the
/// one it sits on. Nothing in the app reads `onSecondary` today, which is
/// exactly why it drifted unnoticed for the theme's whole lifetime: the first
/// Material widget to use a tonal secondary fill would have inherited it.
void main() {
  group('ColorScheme foreground pairing', () {
    for (final entry in <String, ThemeData Function()>{
      'light': AppTheme.light,
      'dark': AppTheme.dark,
    }.entries) {
      test('${entry.key}: onSecondary is paired with secondary, not amber', () {
        final scheme = entry.value().colorScheme;

        // Catches a revert to the historical value. Stated as "not onAmber"
        // as well as "is onCyan" because the two fail for different reasons:
        // the first is the flaw coming back, the second is somebody swapping in
        // a third colour without pairing it to `secondary`.
        expect(scheme.onSecondary, isNot(AppColors.onAmber));
        expect(scheme.onSecondary, AppColors.onCyan);
        expect(scheme.secondary, AppColors.cyan);
      });

      test('${entry.key}: primary keeps its own foreground', () {
        final scheme = entry.value().colorScheme;

        // Guards the fix's blast radius: a careless replace_all of `onAmber`
        // would have taken `onPrimary` with it, which IS on an amber fill.
        expect(scheme.primary, AppColors.amber);
        expect(scheme.onPrimary, AppColors.onAmber);
      });
    }
  });
}
