// The device detail page's history toolbar — design 0083 S3, re-ruled 案 A on
// 2026-08-24 (T9–T11).
//
// 🔴 **This row has never had a test.** `toolbar_narrow_screen_test.dart`
// covers the HISTORY TAB's range row, which owns its whole line; this one
// shares a line with the `⋮` overflow button and therefore gets 46 px less.
// Nothing was watching it, and §1.6 of design 0083 found the consequence
// sitting in `v0.7.30`: with the app in English on a 320 pt phone at the
// DEFAULT text scale, the three range labels needed 225.5 px against a 204 px
// budget and were already truncating to "Tod… / 7 d… / All".
//
// So this file asserts two different things, in the same spirit as its History
// tab sibling:
//   1. no RenderFlex overflow (debug only), and
//   2. every label is really inside the control's box AND was not ellipsised
//      to get there (what ships).
//
// 🔵 **2026-08-24 — what changed.** The calendar `IconButton` became the
// control's FOURTH segment (owner: 「今天/近7天/全部的右邊 放一個自訂」), which
// gives the labels back the 46 px that button cost ⇒ budget 204 px ⇒ 244 px.
// And when even 244 is not enough the row now drops to TWO LINES instead of
// ellipsising, which is what carries zh 1.3× and 1.45× — both of which the
// 案 C arrangement could not draw.
//
// ⚠️ **A known limit is still encoded here rather than hidden.** English needs
// 292.4 px for four segments at 1.15×, against 290 px for the whole line at
// 320 pt — 2.4 px short, with nothing left to reclaim. So the English cases
// below stop at 1.0×, and the group name says so. Only case D (a dropdown,
// design 0083 §4.1) removes the width question entirely.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/custom_range_sheet.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:open_smart_batt/ui/widgets/industrial.dart';

void main() {
  /// The detail row's composition, rebuilt here because the real one lives in
  /// a private method. If its gaps change, this drifts — which is the same
  /// bargain `toolbar_narrow_screen_test.dart` already makes.
  ///
  /// 🔑 The wrap rule is reproduced too, not just the widgets: the two-line
  /// fallback IS the thing that makes zh fit at 1.3× and 1.45×, so a helper
  /// that always built one `Row` would report a failure the app does not have.
  Widget detailRow(
    List<String> labels, {
    Set<int> disabled = const {},
    int selected = 0,
    ValueChanged<int>? onChanged,
  }) {
    final control = SegmentedControl<int>(
      selected: selected,
      onChanged: onChanged ?? (_) {},
      disabled: disabled,
      disabledTooltip: 'No records for this unit yet',
      options: [
        for (var i = 0; i < labels.length; i++) (value: i, label: labels[i]),
      ],
    );
    final trailing = PopupMenuButton<int>(
      icon: const Icon(Icons.more_vert, size: 18),
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      itemBuilder: (_) => const [],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LayoutBuilder(
        builder: (context, c) {
          final needed = segmentedControlNaturalWidth(context, labels) + 6 + 40;
          if (needed <= c.maxWidth) {
            return Row(
              children: [
                Expanded(child: control),
                const SizedBox(width: 6),
                trailing,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              control,
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerRight, child: trailing),
            ],
          );
        },
      ),
    );
  }

  Widget host({
    required double width,
    required double scale,
    required Locale locale,
    required Widget child,
  }) => MaterialApp(
    theme: AppTheme.light(),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        // The page centres a 560-wide column and pads it (15, _, 15, _).
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SizedBox(
              width: width,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15),
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  // ==========================================================================
  group('T9 — every range label is fully visible on the detail row', () {
    // 🔴 **The labels come from the ARB, not from a list written here.** They
    // were hard-coded at first, and a reverse-proof caught it: reverting the
    // English "7d" back to "7 days" left this group entirely green, because it
    // was measuring strings the app does not necessarily use. A layout test
    // whose input is not the shipped text answers a question nobody asked.
    List<String> labelsOf(AppLocalizations l10n) => [
      l10n.historyRangeToday,
      l10n.historyRangeWeek,
      l10n.historyRangeAll,
      // 🔵 The fourth, 2026-08-24. Reading it from the ARB matters twice
      // over here: this string used to be a TOOLTIP on the calendar
      // button, so a hard-coded copy would keep passing after someone
      // changed the one the user reads.
      l10n.historyRangeCustom,
    ];

    // 🔵 zh now covers all FOUR text scales — 1.3× and 1.45× are carried by
    // the two-line fallback, and they are exactly what 案 C could not draw.
    // English still stops at 1.0×: four segments need 292.4 px at 1.15× and
    // the whole line is 290. See the file header.
    const scalesFor = {
      'zh': [1.0, 1.15, 1.3, 1.45],
      'en': [1.0],
    };

    for (final locale in [const Locale('zh'), const Locale('en')]) {
      for (final scale in scalesFor[locale.languageCode]!) {
        testWidgets('${locale.languageCode} at 320 pt / ${scale}x', (
          tester,
        ) async {
          await tester.pumpWidget(
            host(
              width: 320,
              scale: scale,
              locale: locale,
              child: Builder(
                builder: (c) => detailRow(labelsOf(AppLocalizations.of(c))),
              ),
            ),
          );
          expect(tester.takeException(), isNull);

          final labels = labelsOf(
            AppLocalizations.of(
              tester.element(find.byType(SegmentedControl<int>)),
            ),
          );
          final box = tester.getRect(find.byType(SegmentedControl<int>));
          for (final label in labels) {
            final r = tester.getRect(find.text(label));
            expect(
              r.left,
              greaterThanOrEqualTo(box.left - 0.5),
              reason: '"$label" starts before the control',
            );
            expect(
              r.right,
              lessThanOrEqualTo(box.right + 0.5),
              reason: '"$label" is clipped',
            );
            // 🔑 Inside the box is not the same as READABLE: an ellipsised
            // label is inside it too. The natural width is the only thing that
            // distinguishes "fits" from "fits because it was cut".
            expect(
              segmentedControlNaturalWidth(
                tester.element(find.byType(SegmentedControl<int>)),
                labels,
              ),
              lessThanOrEqualTo(box.width + 0.5),
              reason: 'the labels only "fit" because they were ellipsised',
            );
          }
        });
      }
    }

    testWidgets('the English shortening is what buys 1.0x', (tester) async {
      // A reverse-proof for the l10n change: with "7 days" back in place, the
      // four English segments do not fit even at the DEFAULT text scale and
      // even with both lines to spend — 310.0 px against 290. `v0.7.30`
      // shipped the un-shortened form.
      //
      // ⚠️ It used to say "buys 1.15x" and that was true of THREE segments.
      // With four, 1.15× is out of reach either way (292.4 > 290), so the
      // claim this test makes was narrowed rather than left overstated.
      await tester.pumpWidget(
        host(
          width: 320,
          scale: 1.0,
          locale: const Locale('en'),
          child: detailRow(const ['Today', '7 days', 'All', 'Custom']),
        ),
      );
      final ctx = tester.element(find.byType(SegmentedControl<int>));
      final box = tester.getRect(find.byType(SegmentedControl<int>));
      expect(
        segmentedControlNaturalWidth(ctx, const [
          'Today',
          '7 days',
          'All',
          'Custom',
        ]),
        greaterThan(box.width),
        reason: 'if this ever fits, the shortening can be reverted',
      );
    });

    testWidgets('🔵 the row really does take two lines when it must', (
      tester,
    ) async {
      // The fallback the zh 1.3× / 1.45× cases above rely on. Asserted as a
      // HEIGHT difference between a scale that fits and one that does not,
      // because "it wrapped" is not otherwise observable — and if the wrap
      // silently stopped happening, those cases would fail with an ellipsis
      // instead and the cause would be two files away.
      Future<double> heightAt(double scale) async {
        await tester.pumpWidget(
          host(
            width: 320,
            scale: scale,
            locale: const Locale('zh'),
            child: Builder(
              builder: (c) => detailRow(labelsOf(AppLocalizations.of(c))),
            ),
          ),
        );
        return tester.getSize(find.byType(LayoutBuilder).first).height;
      }

      final oneLine = await heightAt(1.0);
      final twoLines = await heightAt(1.45);
      expect(
        twoLines,
        greaterThan(oneLine),
        reason:
            'zh at 1.45x needs 265.4 px and the single-line budget is '
            '244 — it must wrap, not ellipsise',
      );
    });
  });

  // ==========================================================================
  group('T10 — the fourth segment', () {
    const zhLabels = ['今天', '近 7 天', '全部', '自訂'];

    testWidgets('T10a: it is the same target as the other three', (
      tester,
    ) async {
      // 🔴 **NOT a 40 dp claim, and that is deliberate.** The button this
      // replaced carried FB-70's 40 dp floor because it was a bare glyph
      // floating beside the control. A segment is not that: it is one of four
      // cells in a bordered strip, and the strip's height has been the same
      // since the mockup. Asserting 40 here would fail on a control the user
      // has been tapping for months.
      //
      // What IS worth pinning is that "custom" did not become a lesser target
      // than its neighbours on the way in.
      await tester.pumpWidget(
        host(
          width: 320,
          scale: 1.0,
          locale: const Locale('zh'),
          child: detailRow(zhLabels),
        ),
      );
      final sizes = [
        for (var i = 0; i < zhLabels.length; i++)
          tester.getSize(
            find.ancestor(
              of: find.text(zhLabels[i]),
              matching: find.byType(InkWell),
            ),
          ),
      ];
      for (final s in sizes) {
        expect(
          s.height,
          sizes.first.height,
          reason: 'every segment is one strip — none of them is shorter',
        );
        expect(
          s.height,
          greaterThan(24.0),
          reason: 'sanity: a real target, not a hairline',
        );
      }
    });

    test('T10b: both surfaces offer the SAME fourth segment', () {
      // Source-level, in the same spirit as T79-12, and the direct successor
      // of the assertion that used to read `contains('HistoryCustomRangeButton(')`
      // — the failure guarded against is unchanged: one surface growing its
      // own entry point, which produces no error until the two behave
      // differently. Design 0083 §1.3's consistency argument rests on it.
      //
      // 🔴 `readAsStringSync`, NOT the async form: inside `testWidgets` the
      // binding's fake async never completes real file I/O, so an awaited read
      // hangs the whole run with no error — it cost a debug cycle here. This
      // is a plain `test` for the same reason: it needs no widget tree.
      for (final path in const [
        'lib/ui/history/history_screen.dart',
        'lib/ui/history/device_history_tab.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(
          src,
          contains('l10n.historyRangeCustom'),
          reason: '$path must offer the custom segment',
        );
        expect(
          src,
          contains('HistoryRange.custom'),
          reason: '$path must route it somewhere',
        );
        expect(
          src,
          isNot(contains('HistoryCustomRangeButton(')),
          reason:
              'the calendar button was removed 2026-08-24 — a surface '
              'still mounting it would be showing two entry points',
        );
      }
    });

    testWidgets('T10c: a custom range in force lights the fourth segment up', (
      tester,
    ) async {
      // 🔴 This is the whole reason the re-ruling is an improvement and not
      // just a relabel. Under 案 C the control showed NOTHING selected while a
      // custom range was in force — the old button's doc comment said so in
      // as many words ("there is no fourth segment to light up") and used its
      // own tint to compensate. Now the state has a home in the control.
      await tester.pumpWidget(
        host(
          width: 320,
          scale: 1.0,
          locale: const Locale('zh'),
          child: detailRow(zhLabels, selected: 3),
        ),
      );
      final onAccent = tester
          .element(find.byType(SegmentedControl<int>))
          .accent
          .onAccent;
      expect(tester.widget<Text>(find.text('自訂')).style?.color, onAccent);
      expect(
        tester.widget<Text>(find.text('今天')).style?.color,
        isNot(onAccent),
      );
    });
  });

  // ==========================================================================
  group('T11 — nothing to pick from means nothing to press', () {
    const zhLabels = ['今天', '近 7 天', '全部', '自訂'];

    testWidgets('T11a: with no records the segment is inert, and says why', (
      tester,
    ) async {
      var picked = 0;
      await tester.pumpWidget(
        host(
          width: 320,
          scale: 1.0,
          locale: const Locale('zh'),
          child: detailRow(
            zhLabels,
            disabled: const {3},
            onChanged: (_) => picked++,
          ),
        ),
      );
      await tester.tap(find.text('自訂'));
      await tester.pump();
      expect(
        picked,
        0,
        reason: 'a picker over an empty database can only disappoint',
      );
      // …and it does not merely fail silently: it is drawn faded, and the
      // long-press tooltip is the same sentence the button used to carry.
      final custom = tester.widget<Text>(find.text('自訂')).style!.color!;
      final normal = tester.widget<Text>(find.text('今天')).style!.color!;
      expect(
        custom.a,
        lessThan(normal.a),
        reason: '"cannot pick" must not look like "have not picked"',
      );
      // ⚠️ Scoped to the segment. The `⋮` carries a tooltip of its own, so a
      // `findsOneWidget` over every Tooltip would be asserting the row's
      // furniture rather than this segment's explanation.
      final tip = find.ancestor(
        of: find.text('自訂'),
        matching: find.byType(Tooltip),
      );
      expect(tip, findsOneWidget);
      expect(
        tester.widget<Tooltip>(tip).message,
        'No records for this unit yet',
      );
    });

    testWidgets('T11b: with records it fires', (tester) async {
      var picked = <int>[];
      await tester.pumpWidget(
        host(
          width: 320,
          scale: 1.0,
          locale: const Locale('zh'),
          child: detailRow(zhLabels, onChanged: picked.add),
        ),
      );
      await tester.tap(find.text('自訂'));
      await tester.pump();
      expect(picked, [3]);
      // The three presets still work the ordinary way — the fourth segment is
      // the only one whose handler does something different.
      await tester.tap(find.text('全部'));
      await tester.pump();
      expect(picked, [3, 2]);
    });
  });

  // ==========================================================================
  group('T11c — the range line shows the days the user picked', () {
    testWidgets('the exclusive end is never printed', (tester) async {
      // The stored upper end is midnight AFTER the last day. Printing it would
      // read as an off-by-one to everyone who did not write the code.
      final sel = historyCustomRange(
        DateTime(2026, 8, 1),
        DateTime(2026, 8, 15),
      );
      await tester.pumpWidget(
        host(
          width: 320,
          scale: 1.0,
          locale: const Locale('en'),
          child: HistoryCustomRangeLine(sel: sel),
        ),
      );
      expect(find.textContaining('2026/08/15'), findsOneWidget);
      expect(find.textContaining('2026/08/16'), findsNothing);
    });

    testWidgets('a preset draws nothing at all', (tester) async {
      // Not an empty line — the three existing ranges must keep exactly the
      // layout height they had.
      await tester.pumpWidget(
        host(
          width: 320,
          scale: 1.0,
          locale: const Locale('en'),
          child: const HistoryCustomRangeLine(sel: HistoryRangeSel.initial),
        ),
      );
      // HEIGHT is the claim — the parent hands down a tight width, so the box
      // is as wide as the card whatever it draws. What must not change is how
      // much vertical space the three existing ranges give up.
      expect(tester.getSize(find.byType(HistoryCustomRangeLine)).height, 0.0);
    });
  });
}
