// The readout grid at the width a HALF-WIDTH home tile really gives it
// (design 0084 §4.5, stage S5).
//
// ## What shipped, and why nothing saw it
//
// `ReadoutGrid` is a 2x2 hairline grid, and it was only ever rendered at the
// width of a full-width card. Design 0046 then let a user set any tile to 1x1
// and design 0059 opened this module to the home grid — so the same widget
// started getting HALF the room, and nothing rendered it there.
//
// The arithmetic is what makes it indefensible, and it holds in any font: a
// two-column cell's content is `(W - 1) / 2 - 14*2`, so at the inner width a
// 1x1 tile on a 390 pt phone gives (150) a cell offers **46.5 px** — less than
// the icon (14) plus its gap (6), before a single character of the label. The
// measured card was **607 px tall at outer 180 and only 409 at outer 265**:
// taller at half width than a whole card gets, because everything wrapped.
//
// 🔴 The height is the symptom. The defect is the WRAPPED VALUE: `_StatTile`
// prints it with `Text.rich` and no `maxLines`, so a number breaks across two
// lines — and a number split over two lines is briefly readable as a different
// number. Same failure the G readout shipped with
// (`narrow_tile_layout_test.dart` header), one card along, found the same way:
// by rendering the INPUT to the layout instead of trusting it.
//
// ## ⚠️ Why this file does NOT assert "no value wraps"
//
// It cannot, honestly. Widget tests render in Flutter's test font, whose every
// glyph is a SQUARE of the font size — `28.4 °C` measures ~125 px here against
// roughly 70 on a device. A sweep with the fold disabled shows this font still
// wrapping at a 122 px cell, which no shipping font does.
//
// So a "no wrap" assertion would either fail on correct code or force the
// breakpoint up to ~137 px, and a breakpoint that high folds a 360 pt phone's
// FULL-width card to one column — a real regression bought with a test-font
// artefact.
//
// This file therefore pins what is font-INDEPENDENT: the breakpoint arithmetic,
// which column count each real container gets, that folding actually clears the
// minimum it was invoked for, and that the widths which were never in trouble
// are untouched. The value of `kReadoutGridMinCellWidth` itself is a real-device
// judgement (~101 px for the widest string, `10000 mAh`, at the value type's
// 23 px) and is documented as such at its declaration.
//
// 🔴 And it pins one thing by REFUSING to claim it: the fold does not make the
// card shorter. Measured both ways, it is taller. T-0084-5d carries the numbers
// and the reason.
//
// CLEAN-ROOM: expectations derive from this project's own source and measurements.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/readout_grid.dart';

/// The grid's own width inside a card, for each container this app puts it in.
///
/// Derived the same way `narrow_tile_layout_test.dart` derives its widths: the
/// card's `EdgeInsets.all(15)` comes off both sides, so a tile of outer width
/// `W` hands the grid `W - 30`.
const double kInnerHalfPhone = 150; // outer 180 — 390 pt phone, 1x1 tile
const double kInnerHalfWide = 235; // outer 265 — the 560 px cap, 1x1 tile
const double kInnerFullPhone = 330; // outer 360 — 390 pt phone, full width
const double kInnerFullWide = 500; // outer 530 — the 560 px cap, full width

/// The four tiles a pack's readouts card builds (`dashboard_cards.dart`).
List<Readout> _items() => const [
      Readout(
          icon: Icons.thermostat, label: '溫度 TEMP', value: '28.4', unit: '°C'),
      Readout(
          icon: Icons.bolt,
          label: '主電流',
          value: '-2.13',
          unit: 'A',
          badge: '放電'),
      Readout(
          icon: Icons.power, label: '次電壓', value: '12.42', unit: 'V'),
      Readout(icon: Icons.favorite, label: '健康 SOH', value: '98', unit: '%'),
    ];

Widget _harness(double width, {Locale locale = const Locale('zh', 'TW')}) =>
    MaterialApp(
      theme: AppTheme.light(),
      locale: locale,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: ReadoutGrid(items: _items())),
          ),
        ),
      ),
    );

Finder _value(String v) => find.textContaining(v, findRichText: true);

void main() {
  // ===========================================================================
  // T-0084-5a — the breakpoint, as arithmetic
  // ===========================================================================
  test('T-0084-5a: which containers clear the two-column minimum', () {
    // A cell's content is `(W - 1) / 2 - 28`. Spelled out per container so a
    // padding change shows up here as a diff rather than as a silent reflow.
    expect(ReadoutGrid.fitsTwoColumns(kInnerHalfPhone), isFalse); // 46.5
    expect(ReadoutGrid.fitsTwoColumns(kInnerHalfWide), isFalse); // 89.0
    expect(ReadoutGrid.fitsTwoColumns(kInnerFullPhone), isTrue); // 136.5
    expect(ReadoutGrid.fitsTwoColumns(kInnerFullWide), isTrue); // 221.5

    // 🔴 The boundary itself, so that raising the constant cannot quietly start
    // folding full-width cards on smaller phones. 277 is `2*110 + 57`.
    expect(ReadoutGrid.fitsTwoColumns(277), isTrue);
    expect(ReadoutGrid.fitsTwoColumns(276), isFalse);
  });

  // ===========================================================================
  // T-0084-5b / 5c — what each real container actually draws
  // ===========================================================================
  testWidgets('T-0084-5b: a half-width tile folds to one column',
      (tester) async {
    for (final w in [kInnerHalfPhone, kInnerHalfWide]) {
      await tester.pumpWidget(_harness(w));
      // Two tiles share a row iff their tops match. One column means the second
      // tile starts BELOW the first, at the same x.
      final first = tester.getTopLeft(_value('28.4'));
      final second = tester.getTopLeft(_value('-2.13'));
      expect(second.dy, greaterThan(first.dy),
          reason: 'inner width $w should be a single column');
      expect(second.dx, first.dx,
          reason: 'single column means both tiles start at the same x');
    }
  });

  testWidgets('T-0084-5c: a full-width card keeps two columns', (tester) async {
    // The fold must not cost density where there was never a problem — this is
    // half the point of deriving a breakpoint instead of keying off "is this a
    // home tile".
    for (final w in [kInnerFullPhone, kInnerFullWide]) {
      await tester.pumpWidget(_harness(w));
      final first = tester.getTopLeft(_value('28.4'));
      final second = tester.getTopLeft(_value('-2.13'));
      expect(second.dy, first.dy,
          reason: 'inner width $w should stay two columns');
      expect(second.dx, greaterThan(first.dx));
    }
  });

  // ===========================================================================
  // T-0084-5d — the fold must actually clear the minimum it was invoked for,
  //             and must not disturb the widths that were already fine
  // ===========================================================================
  testWidgets('T-0084-5d: folding buys the room it was invoked for',
      (tester) async {
    // 🔴 THE FOLD IS NOT A HEIGHT OPTIMISATION, and this test used to claim it
    // was. Measured 2026-08-23 with the fold disabled (constant temporarily 0)
    // against the shipped behaviour, same items, same font:
    //
    //     inner 150   2x2 → 320.0     folded → 398.0    TALLER
    //     inner 235   2x2 → 254.0     folded → (also taller)
    //     inner 330   2x2 → 188.0     unchanged (no fold)
    //     inner 500   2x2 → 188.0     unchanged (no fold)
    //
    // Four short tiles stacked cost more vertical padding than two tall rows,
    // and in the test font the single column's 122 px still wraps, so it pays
    // the padding without collecting the saving. On a shipping font the wrap
    // does stop — but the padding arithmetic does not change, so the card may
    // well be taller there too.
    //
    // What the fold buys is that the number is READABLE: 46.5 px of content
    // cannot hold `12.42 V` in any font, and 26.5 px of label after the icon is
    // two or three characters. Height was always the symptom we noticed, never
    // the thing being fixed. See design 0084 §4.5's 2026-08-23 correction.
    for (final w in [kInnerHalfPhone, kInnerHalfWide]) {
      await tester.pumpWidget(_harness(w));
      expect(w - kReadoutTilePadH * 2,
          greaterThanOrEqualTo(kReadoutGridMinCellWidth),
          reason: 'inner $w folds to one column, but one column STILL does not '
              'clear the minimum — folding there buys nothing and the '
              'breakpoint or the card needs rethinking');
    }

    // The widths that were never in trouble must be byte-for-byte what they
    // were. A fix that quietly reflows the device page is not this fix.
    for (final (width, before) in <(double, double)>[
      (kInnerFullPhone, 188.0),
      (kInnerFullWide, 188.0),
    ]) {
      await tester.pumpWidget(_harness(width));
      expect(tester.getSize(find.byType(ReadoutGrid)).height, before,
          reason: 'inner $width keeps two columns and must be unchanged');
    }
  });

  // ===========================================================================
  // T-0084-5e — the premise the breakpoint rests on
  // ===========================================================================
  testWidgets('T-0084-5e: the label is deliberately not part of the promise',
      (tester) async {
    // `SECONDARY VOLTAGE SVLT` does not fit a two-column cell at ANY width this
    // app produces, which is why `_StatTile` has always given the label
    // Flexible + ellipsis. This test exists so a future reader who finds an
    // ellipsised label does not "fix" it by folding every layout to one column:
    // that would cost density everywhere and still not achieve it.
    await tester
        .pumpWidget(_harness(kInnerFullWide, locale: const Locale('en')));
    final context = tester.element(find.byType(ReadoutGrid));
    final needed = (TextPainter(
      text: TextSpan(
          text: 'SECONDARY VOLTAGE',
          style: AppTextStyles.label(context)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout())
        .width;
    expect(needed, greaterThan(kReadoutGridMinCellWidth),
        reason: 'the longest label now fits a minimum-width cell — revisit '
            'design 0084 §4.5, which assumes it never does');
  });
}
