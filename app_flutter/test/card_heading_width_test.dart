// The card heading gets the width it needs, and the fade rule gets a slice.
//
// The defect. `CardHeading` laid its label out as `Flexible(flex: 1)` next to a
// `_FadeRule` in `Expanded(flex: 1)`. `RenderFlex` divides the free space by
// the flex factors BEFORE it lays a flexible child out, and space a `loose`
// child does not use is not handed back to a `tight` one — so the label could
// never take more than HALF of what was left after the icon and the two 7 px
// gaps, however short the label was. On a 320 dp phone that is ~44 dp of label
// on a 1x1 tile: `PER-CELL VOLTAGE DVOL` reduced to about four characters and
// an ellipsis, and the full-width 1x2 card truncated it too.
//
// `industrial_card.dart:126-133` already records the previous round of this —
// the heading overflowed a 1x1 tile outright until it was given `Flexible`.
// That stopped the striped overflow bar; it did not give the label the room,
// because the `Expanded` beside it was still taking half.
//
// The fix makes the label the ONLY flexible child of the row, so it is laid out
// against everything that is left, and gives the rule a fixed width instead.
//
// ## What is asserted, and why it is not a pixel count of a string
//
// Widget tests render with Flutter's fixed-advance test font, which is WIDER
// per character than the proportional font a phone resolves. Asserting "this
// heading now fits on a 1x2 card" would therefore be asserting the test host's
// font metrics, not the layout. So the assertions are about the BUDGET — the
// width the row hands the label — which is the thing this code decides. The
// one "it fits now" case builds its string from a measurement taken in the same
// run, and states its own premise.
//
// ⚠️ This is a LAYOUT fix. No heading string and no l10n key changes here —
// whether a heading should also name its device is a separate question.
//
// CLEAN-ROOM: expectations derive from this project's own source and mockup.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/widgets/industrial_card.dart';

void main() {
  // The longest heading the app ships (`app_en.arb:133`).
  const enHeading = 'Per-Cell Voltage DVOL';

  // `home_page.dart:77` pads the list by 15 either side of a 320 dp phone, and
  // a half tile is one of two `Expanded` children of the row, with no gap.
  const phone = 320.0;
  const fullTile = phone - 15 * 2; // 290
  const halfTile = fullTile / 2; // 145

  /// The label's share of a card [outer] dp wide: card padding either side,
  /// then the icon and the two gaps `CardHeading` lays down.
  double budget(double outer) => outer - 15 * 2 - 13 - 7 - 7 - CardHeading.ruleWidth;

  /// What the same row gave the label under the 50/50 split, for contrast.
  double oldBudget(double outer) => (outer - 15 * 2 - 13 - 7 - 7) / 2;

  /// Render one heading inside a card of [width] and report how wide the
  /// label's own render box ended up.
  Future<double> labelWidth(
    WidgetTester tester,
    String text, {
    required double width,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: IndustrialCard(
              heading: text,
              headingIcon: Icons.battery_std,
              child: const SizedBox(height: 20),
            ),
          ),
        ),
      ),
    ));
    return tester.getSize(find.text(text.toUpperCase())).width;
  }

  /// What the string measures when nothing constrains it. A label rendering
  /// narrower than this has lost characters to the ellipsis.
  Future<double> naturalWidth(WidgetTester tester, String text) =>
      labelWidth(tester, text, width: 4000);

  group('a truncating label gets the whole remainder, not half of it', () {
    testWidgets('🔴 on a 1x1 tile', (tester) async {
      final rendered = await labelWidth(tester, enHeading, width: halfTile);

      expect(rendered, greaterThan(oldBudget(halfTile) + 5),
          reason: 'the 50/50 split allowed ~44 dp here — about four characters '
              'of an uppercase heading');
      // Not exactly the budget: an ellipsized line stops on a glyph boundary,
      // so it lands within one character of the edge it was given.
      expect(rendered, lessThanOrEqualTo(budget(halfTile) + 0.5));
      expect(rendered, greaterThan(budget(halfTile) - 13),
          reason: 'and it runs out at the edge of the row rather than halfway '
              'across it');
    });

    testWidgets('🔴 and on a full-width 1x2 card', (tester) async {
      // The one the user sees most: even at 290 dp the English heading was
      // being cut, because half of 233 is 116.
      final rendered = await labelWidth(tester, enHeading, width: fullTile);

      expect(rendered, greaterThan(oldBudget(fullTile) + 5));
      expect(rendered, lessThanOrEqualTo(budget(fullTile) + 0.5));
    });
  });

  group('a heading that fits is drawn whole', () {
    testWidgets('one that used to be cut on a 1x1 tile no longer is',
        (tester) async {
      const short = 'CELL';
      final natural = await naturalWidth(tester, short);

      // The premise, stated so a font change fails here instead of silently
      // turning the assertion below into a tautology.
      expect(natural, greaterThan(oldBudget(halfTile)),
          reason: 'sanity: this string did NOT fit the old half-row');
      expect(natural, lessThanOrEqualTo(budget(halfTile)),
          reason: 'sanity: it does fit the new one');

      expect(await labelWidth(tester, short, width: halfTile),
          closeTo(natural, 0.5));
    });

    testWidgets('a short heading still takes only what it needs',
        (tester) async {
      // Making the label greedy must not make it claim the row: `1328` is a
      // real alias from a field log, and the rule has to stay beside it.
      final natural = await naturalWidth(tester, '1328');

      expect(await labelWidth(tester, '1328', width: halfTile),
          closeTo(natural, 0.5));
    });
  });

  group('the rule keeps its place', () {
    testWidgets('dropping it does not move the trailing slot', (tester) async {
      // `industrial_card.dart` has always promised this: design 0054's `dense`
      // shell drops the rule, and that must not re-flow the row. Both branches
      // are the same fixed width, so the promise survives losing the
      // `Expanded` that used to carry it.
      Future<Rect> trailingRect(bool rule) async {
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: halfTile,
                child: CardHeading(
                  text: 'DVOL',
                  icon: Icons.battery_std,
                  rule: rule,
                  trailing: const Icon(Icons.more_horiz, size: 13),
                ),
              ),
            ),
          ),
        ));
        return tester.getRect(find.byIcon(Icons.more_horiz));
      }

      expect(await trailingRect(true), await trailingRect(false));
    });
  });
}
