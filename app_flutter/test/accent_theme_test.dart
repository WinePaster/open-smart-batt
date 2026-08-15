import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/theme/app_theme.dart';

/// The shipped accent sets (design 0064 Phase 1).
///
/// 🔴 READ THIS BEFORE ADDING ASSERTIONS. These are DELIBERATELY weak checks.
/// The six sets were signed off by eye against V1–V7 (see `accent_theme.dart`),
/// and design 0064 §3.3-bis rules that no contrast or clash FORMULA may exist
/// in `lib/` during Phase 1 — precisely so that nobody re-derives a
/// human-checked value from an uncalibrated one. What is left for CI is design
/// 0064 §6 R9 mitigation ③: catch the copy-paste that forgot to change a
/// value. It cannot catch "these two look alike", and must not be mistaken for
/// the verification.
void main() {
  // Channel-sum distance. Crude on purpose — see the file comment.
  // 0 = identical, 765 = black vs white.
  int distance(Color a, Color b) =>
      (((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs()) * 255)
          .round();

  group('AccentTheme.all', () {
    test('ships exactly six sets with unique ids', () {
      expect(AccentTheme.all, hasLength(6));
      expect(
        AccentTheme.all.map((t) => t.id).toSet(),
        hasLength(6),
        reason: 'a duplicated id would make two swatches share one stored '
            'value, and the second one could never be selected',
      );
      // amber must stay first: it is the default, and the swatch row's first
      // position is what a reporter means by "the original one".
      expect(AccentTheme.all.first.id, 'amber');
    });

    test('amber is byte-for-byte the pre-0064 palette', () {
      // G3: an existing user who upgrades and never opens the setting must see
      // no change at all. If this fails, the upgrade repainted the app.
      expect(AccentTheme.amber.accent, AppColors.amber);
      expect(AccentTheme.amber.accentSecondary, AppColors.cyan);
      expect(AccentTheme.amber.onAccent, AppColors.onAmber);
      expect(AccentTheme.amber.accentMuted, AppColors.amberDark);
    });

    for (final t in AccentTheme.all) {
      test('${t.id}: no field was left as a copy of another', () {
        // The copy-paste this catches: duplicating the block above and
        // changing only `accent`, which leaves the new set drawing its chart's
        // second series in the previous set's colour.
        expect(distance(t.accent, t.accentSecondary), greaterThan(90),
            reason: 'the two are the chart\'s two data series');
        expect(distance(t.accent, t.accentMuted), greaterThan(20));
        expect(distance(t.accent, t.onAccent), greaterThan(200));
      });

      test('${t.id}: neither colour was set to a status colour', () {
        // A set whose accent IS `good` would merge CONNECTING with CONNECTED
        // everywhere at once — the failure design 0064 is built around.
        for (final c in [t.accent, t.accentSecondary]) {
          expect(distance(c, AppSemantics.good), greaterThan(60));
          expect(distance(c, AppSemantics.danger), greaterThan(60));
        }
      });
    }

    test('byId resolves shipped ids and refuses everything else', () {
      expect(AccentTheme.byId('teal'), AccentTheme.teal);
      // Null, not amber: `AppSettings` needs "unknown id" and "never chose"
      // to arrive as separate facts even though both end at amber.
      expect(AccentTheme.byId('nonexistent'), isNull);
      expect(AccentTheme.byId(null), isNull);
      expect(AccentTheme.byId(''), isNull);
    });
  });

  group('AccentTheme.lerp', () {
    test('does not invent an id mid-animation', () {
      // A blended id would reach the export header while the theme animates,
      // and no `byId` could resolve it.
      final quarter = AccentTheme.amber.lerp(AccentTheme.teal, 0.25);
      final threeQuarter = AccentTheme.amber.lerp(AccentTheme.teal, 0.75);
      expect(quarter.id, 'amber');
      expect(threeQuarter.id, 'teal');
      expect(AccentTheme.byId(quarter.id), isNotNull);
      expect(AccentTheme.byId(threeQuarter.id), isNotNull);
    });
  });
}
