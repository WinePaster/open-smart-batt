// The device detail page's history toolbar — design 0083 S3 (T9–T11).
//
// 🔴 **This row has never had a test.** `toolbar_narrow_screen_test.dart`
// rebuilds the HISTORY TAB's range row (which owns its whole line); the detail
// page's shares a line with two buttons and therefore gets 86 px less. Nothing
// was watching it, and §1.6 of design 0083 found the consequence sitting in
// `v0.7.30`: with the app in English on a 320 pt phone at the DEFAULT text
// scale, the three range labels needed 225.5 px against a 204 px budget and
// were already truncating to "Tod… / 7 d… / All".
//
// So this file asserts two different things, in the same spirit as its History
// tab sibling:
//   1. no RenderFlex overflow (debug only), and
//   2. every label is really inside the control's box (what ships).
//
// ⚠️ **A known limit is encoded here rather than hidden.** 204 px is not enough
// for every language at every text scale, and design 0083 案 C does not change
// the budget — it only stops the calendar button from eating into it. Shortening
// the English "7 days" to "7d" buys 1.0× and 1.15×; 1.3× and above still
// truncate, and only case D (a dropdown) would fix that. See design 0083 §7 R4.
// The scales below are therefore the ones the fix actually covers, and the
// group name says so.
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
  Widget detailRow(List<String> labels) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Expanded(
              child: SegmentedControl<int>(
                selected: 0,
                onChanged: (_) {},
                options: [
                  for (var i = 0; i < labels.length; i++)
                    (value: i, label: labels[i]),
                ],
              ),
            ),
            const SizedBox(width: 6),
            HistoryCustomRangeButton(
                active: false, enabled: true, onPressed: () {}),
            PopupMenuButton<int>(
              icon: const Icon(Icons.more_vert, size: 18),
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              itemBuilder: (_) => const [],
            ),
          ],
        ),
      );

  Widget host({
    required double width,
    required double scale,
    required Locale locale,
    required Widget child,
  }) =>
      MaterialApp(
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
    List<String> labelsOf(AppLocalizations l10n) =>
        [l10n.historyRangeToday, l10n.historyRangeWeek, l10n.historyRangeAll];

    for (final locale in [const Locale('zh'), const Locale('en')]) {
      // 🔴 1.0 and 1.15 only — see the file header. 1.3× and 1.45× are a KNOWN
      // failure of the 204 px budget, not of this change, and pretending
      // otherwise with a looser assertion would hide it.
      for (final scale in [1.0, 1.15]) {
        testWidgets('${locale.languageCode} at 320 pt / ${scale}x',
            (tester) async {
          await tester.pumpWidget(host(
            width: 320,
            scale: scale,
            locale: locale,
            child: Builder(
                builder: (c) => detailRow(labelsOf(AppLocalizations.of(c)))),
          ));
          expect(tester.takeException(), isNull);

          final labels = labelsOf(AppLocalizations.of(
              tester.element(find.byType(SegmentedControl<int>))));
          final box = tester.getRect(find.byType(SegmentedControl<int>));
          for (final label in labels) {
            final r = tester.getRect(find.text(label));
            expect(r.left, greaterThanOrEqualTo(box.left - 0.5),
                reason: '"$label" starts before the control');
            expect(r.right, lessThanOrEqualTo(box.right + 0.5),
                reason: '"$label" is clipped');
            // 🔑 Inside the box is not the same as READABLE: an ellipsised
            // label is inside it too. The natural width is the only thing that
            // distinguishes "fits" from "fits because it was cut".
            expect(
              segmentedControlNaturalWidth(
                  tester.element(find.byType(SegmentedControl<int>)), labels),
              lessThanOrEqualTo(box.width + 0.5),
              reason: 'the labels only "fit" because they were ellipsised',
            );
          }
        });
      }
    }

    testWidgets('the English shortening is what buys 1.15x', (tester) async {
      // A reverse-proof for the l10n change: with "7 days" the same row at the
      // same scale does NOT fit, which is the state `v0.7.30` shipped in.
      await tester.pumpWidget(host(
        width: 320,
        scale: 1.15,
        locale: const Locale('en'),
        child: detailRow(const ['Today', '7 days', 'All']),
      ));
      final ctx = tester.element(find.byType(SegmentedControl<int>));
      final box = tester.getRect(find.byType(SegmentedControl<int>));
      expect(
        segmentedControlNaturalWidth(ctx, const ['Today', '7 days', 'All']),
        greaterThan(box.width),
        reason: 'if this ever fits, the shortening can be reverted',
      );
    });
  });

  // ==========================================================================
  group('T10 — the calendar button', () {
    testWidgets('T10a: it is at least 40x40 dp', (tester) async {
      // FB-70's floor. Named on the widget rather than inherited, so a later
      // `visualDensity` change cannot shrink it silently.
      await tester.pumpWidget(host(
        width: 320,
        scale: 1.0,
        locale: const Locale('en'),
        child: detailRow(const ['Today', '7d', 'All']),
      ));
      final size = tester.getSize(find.byType(HistoryCustomRangeButton));
      expect(size.width, greaterThanOrEqualTo(40.0));
      expect(size.height, greaterThanOrEqualTo(40.0));
    });

    test('T10b: both surfaces mount the SAME widget', () {
      // Source-level, in the same spirit as T79-12: the failure guarded against
      // is one surface growing its own entry point, which produces no error
      // until the two look or behave differently. Design 0083 §1.3's whole
      // consistency argument rests on there being one widget.
      // 🔴 `readAsStringSync`, NOT the async form: inside `testWidgets` the
      // binding's fake async never completes real file I/O, so an awaited read
      // hangs the whole run with no error — it cost a debug cycle here. This is
      // a plain `test` for the same reason: it needs no widget tree.
      for (final path in const [
        'lib/ui/history/history_screen.dart',
        'lib/ui/history/device_history_tab.dart',
      ]) {
        expect(File(path).readAsStringSync(),
            contains('HistoryCustomRangeButton('),
            reason: '$path must mount the shared button');
      }
    });
  });

  // ==========================================================================
  group('T11 — nothing to pick from means nothing to press', () {
    testWidgets('T11a: disabled, and it says why', (tester) async {
      await tester.pumpWidget(host(
        width: 320,
        scale: 1.0,
        locale: const Locale('en'),
        child: HistoryCustomRangeButton(
            active: false, enabled: false, onPressed: () {}),
      ));
      final btn = tester.widget<IconButton>(find.byType(IconButton));
      expect(btn.onPressed, isNull,
          reason: 'a picker over an empty database can only disappoint');
      expect(btn.tooltip, 'No records for this unit yet');
    });

    testWidgets('T11b: enabled it fires, and `active` tints it',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(
        width: 320,
        scale: 1.0,
        locale: const Locale('en'),
        child: HistoryCustomRangeButton(
            active: true, enabled: true, onPressed: () => taps++),
      ));
      await tester.tap(find.byType(HistoryCustomRangeButton));
      expect(taps, 1);
      // 🔴 The tint is not decoration: with no fourth segment to light up, this
      // button is the ONLY thing on screen saying a custom range is in force.
      final icon = tester.widget<Icon>(find.byIcon(Icons.event_outlined));
      expect(icon.color, isNotNull);
    });
  });

  // ==========================================================================
  group('T11c — the range line shows the days the user picked', () {
    testWidgets('the exclusive end is never printed', (tester) async {
      // The stored upper end is midnight AFTER the last day. Printing it would
      // read as an off-by-one to everyone who did not write the code.
      final sel =
          historyCustomRange(DateTime(2026, 8, 1), DateTime(2026, 8, 15));
      await tester.pumpWidget(host(
        width: 320,
        scale: 1.0,
        locale: const Locale('en'),
        child: HistoryCustomRangeLine(sel: sel),
      ));
      expect(find.textContaining('2026/08/15'), findsOneWidget);
      expect(find.textContaining('2026/08/16'), findsNothing);
    });

    testWidgets('a preset draws nothing at all', (tester) async {
      // Not an empty line — the three existing ranges must keep exactly the
      // layout height they had.
      await tester.pumpWidget(host(
        width: 320,
        scale: 1.0,
        locale: const Locale('en'),
        child: const HistoryCustomRangeLine(sel: HistoryRangeSel.initial),
      ));
      // HEIGHT is the claim — the parent hands down a tight width, so the box
      // is as wide as the card whatever it draws. What must not change is how
      // much vertical space the three existing ranges give up.
      expect(tester.getSize(find.byType(HistoryCustomRangeLine)).height, 0.0);
    });
  });
}
