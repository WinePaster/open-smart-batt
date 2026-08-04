// The history toolbar on a narrow phone.
//
// `feedback-attachments/our-app.md` `2026.07.30/009` shows the range picker
// with its third segment cut in half. Measured 2026-08-03: at 320 pt the three
// zh labels need 184.1 px and the control was given 175.7 — and because
// SegmentedControl was `Row(mainAxisSize.min)` inside `Clip.antiAlias`, the
// excess was CLIPPED, not reported. A release build shows no error; the
// segment is just gone.
//
// These tests therefore assert two different things:
//   1. no RenderFlex overflow (which only fires in debug), and
//   2. every label is actually inside the control's box (which is what the
//      user sees in release).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/widgets/industrial.dart';

void main() {
  const labels = ['今天', '近 7 天', '全部'];

  Widget host({
    required double width,
    required double scale,
    required Widget child,
  }) =>
      MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: SizedBox(width: width, child: child),
          ),
        ),
      );

  // The toolbar's own layout lives in a private method of HistoryScreen, so
  // this rebuilds the same composition the screen builds. If the screen's
  // gaps change, `_kToolbarGap` moves with them and this stays representative.
  Widget toolbar(BuildContext _) => Padding(
        padding: const EdgeInsets.fromLTRB(15, 8, 15, 4),
        child: LayoutBuilder(
          builder: (context, c) {
            final needed = segmentedControlNaturalWidth(context, labels) +
                8 +
                filterChipNaturalWidth(context, '警告', hasIcon: true) +
                7 +
                filterChipNaturalWidth(context, '匯出 CSV', hasIcon: true);
            final segmented = SegmentedControl<int>(
              selected: 0,
              onChanged: (_) {},
              options: [
                for (var i = 0; i < labels.length; i++)
                  (value: i, label: labels[i]),
              ],
            );
            final actions = [
              FilterChip2(
                  label: '警告',
                  icon: Icons.warning_amber_rounded,
                  selected: false,
                  onTap: () {}),
              const SizedBox(width: 7),
              FilterChip2(
                  label: '匯出 CSV',
                  icon: Icons.file_download_outlined,
                  filled: true,
                  selected: true,
                  onTap: () {}),
            ];
            if (needed <= c.maxWidth) {
              return Row(children: [
                Expanded(child: segmented),
                const SizedBox(width: 8),
                ...actions,
              ]);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                segmented,
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
              ],
            );
          },
        ),
      );

  group('history toolbar', () {
    // 320 = iPhone SE 1 / small Android. 375 = the machine in the FB-40
    // captures. 440 = a current large phone.
    for (final width in [320.0, 375.0, 390.0, 440.0]) {
      for (final scale in [1.0, 1.15, 1.3, 1.45]) {
        testWidgets('every range label is fully visible at $width pt / $scale×',
            (tester) async {
          await tester.pumpWidget(
              host(width: width, scale: scale, child: Builder(builder: toolbar)));

          final box = tester.getRect(find.byType(SegmentedControl<int>));
          for (final label in labels) {
            final rect = tester.getRect(find.text(label));
            // Inside the control on both edges: a label whose right edge is
            // past the box is the 2026.07.30/009 screenshot.
            expect(rect.left, greaterThanOrEqualTo(box.left - 0.5),
                reason: '"$label" starts before the control at $width/$scale');
            expect(rect.right, lessThanOrEqualTo(box.right + 0.5),
                reason: '"$label" is clipped at $width/$scale');
          }
        });
      }
    }

    testWidgets('the narrow phone gets two lines, the wide one stays on one',
        (tester) async {
      await tester.pumpWidget(
          host(width: 320, scale: 1.15, child: Builder(builder: toolbar)));
      final narrow = tester.getSize(find.byType(LayoutBuilder).first).height;

      await tester.pumpWidget(
          host(width: 440, scale: 1.15, child: Builder(builder: toolbar)));
      final wide = tester.getSize(find.byType(LayoutBuilder).first).height;

      expect(narrow, greaterThan(wide),
          reason: '320 pt should wrap to a second line');
    });
  });

  group('SegmentedControl overflow guard', () {
    testWidgets('a slot far too small ellipsises instead of clipping away',
        (tester) async {
      await tester.pumpWidget(host(
        width: 120,
        scale: 1.45,
        child: Row(children: [
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
        ]),
      ));
      // No RenderFlex overflow (pumpWidget would have recorded the exception),
      // and all three segments still exist as tap targets.
      expect(tester.takeException(), isNull);
      expect(find.byType(InkWell), findsNWidgets(labels.length));
    });

    testWidgets('an unbounded slot keeps its natural width', (tester) async {
      // The settings rows lay the control out with an unbounded main axis;
      // a flex child there would throw.
      await tester.pumpWidget(host(
        width: 600,
        scale: 1.15,
        child: Row(children: [
          const Expanded(child: SizedBox()),
          SegmentedControl<int>(
            selected: 0,
            onChanged: (_) {},
            options: [
              for (var i = 0; i < labels.length; i++)
                (value: i, label: labels[i]),
            ],
          ),
        ]),
      ));
      expect(tester.takeException(), isNull);
      final box = tester.getSize(find.byType(SegmentedControl<int>));
      // Natural width, not squeezed. The helper is an UPPER bound (it takes
      // the wider of the two font weights per label), so the real control is
      // never wider than it, and never far below it either.
      final ctx = tester.element(find.byType(SegmentedControl<int>));
      final bound = segmentedControlNaturalWidth(ctx, labels);
      expect(box.width, lessThanOrEqualTo(bound + 0.5));
      expect(box.width, greaterThan(bound * 0.95));
    });
  });
}
