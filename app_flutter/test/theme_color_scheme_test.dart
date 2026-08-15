import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/theme/app_theme.dart';

/// `ColorScheme` foreground/background pairings.
///
/// design 0064 Q10 found `onSecondary` carrying [AppColors.onAmber] while
/// `secondary` was cyan — a foreground computed for a different colour than the
/// one it sits on. Nothing in the app reads `onSecondary`, which is exactly why
/// it drifted unnoticed for the theme's whole lifetime.
///
/// 🔴 The repair is no longer a constant. Q1 made `secondary` part of the
/// user's accent set, so its foreground comes from the same set — one
/// `onAccent` for both colours, legitimate only because criterion V3 in
/// `accent_theme.dart` is checked for every set. That is why the tests below
/// drive a NON-DEFAULT set: under amber, `onPrimary` and `onSecondary` are the
/// same value, so a hard-coded `AppColors.onAmber` would still pass. Under
/// teal it would not.
void main() {
  group('ColorScheme foreground pairing', () {
    for (final entry in <String, ThemeData Function({AccentTheme accent})>{
      'light': AppTheme.light,
      'dark': AppTheme.dark,
    }.entries) {
      final name = entry.key;
      final build = entry.value;

      test('$name: the default scheme is the pre-0064 palette', () {
        // G3: an existing user who upgrades and never opens the setting sees
        // no change. If this fails, the upgrade repainted the app.
        final scheme = build().colorScheme;
        expect(scheme.primary, AppColors.amber);
        expect(scheme.onPrimary, AppColors.onAmber);
        expect(scheme.secondary, AppColors.cyan);
      });

      test('$name: every accent pair comes from the chosen set', () {
        for (final t in AccentTheme.all) {
          final scheme = build(accent: t).colorScheme;
          expect(scheme.primary, t.accent, reason: t.id);
          expect(scheme.onPrimary, t.onAccent, reason: t.id);
          expect(scheme.secondary, t.accentSecondary, reason: t.id);
          // The Q10 assertion in its durable form: the secondary's foreground
          // belongs to the same set as the secondary. A regression to any
          // fixed constant fails here for five of the six sets.
          expect(scheme.onSecondary, t.onAccent, reason: t.id);
        }
      });

      test('$name: onSecondary is not the historical amber foreground', () {
        // The literal flaw, kept as its own assertion because it is the one
        // that was actually shipped. Driven with teal so it cannot pass by
        // coincidence.
        final scheme = build(accent: AccentTheme.teal).colorScheme;
        expect(scheme.onSecondary, isNot(AppColors.onAmber));
      });

      test('$name: neutrals do not follow the accent', () {
        // N2: the user picks an ACCENT, not a skin. `ColorScheme.fromSeed`
        // was rejected in design 0064 §4 method B precisely because it tints
        // the surfaces; this catches anyone reintroducing it.
        final amber = build().colorScheme;
        final teal = build(accent: AccentTheme.teal).colorScheme;
        expect(teal.surface, amber.surface);
        expect(teal.onSurface, amber.onSurface);
        expect(teal.error, AppSemantics.danger);
      });

      test('$name: the accent extension is attached', () {
        // Without this every `context.accent` silently falls back to amber and
        // the whole feature is a no-op that no other test would notice.
        final theme = build(accent: AccentTheme.violet);
        expect(theme.extension<AccentTheme>(), AccentTheme.violet);
        expect(theme.extension<AppPalette>(), isNotNull);
      });
    }
  });
}
