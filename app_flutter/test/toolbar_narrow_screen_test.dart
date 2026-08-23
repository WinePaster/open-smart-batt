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
  // 🔵 FOUR labels since 2026-08-24 (design 0083 Q1 re-ruled to 案 A): the
  // calendar `IconButton` that used to sit beside this control became its
  // fourth segment. The zh strings are the ARB's, kept literal here for the
  // same reason the detail-row test reads them FROM the ARB — see its header.
  const labels = ['今天', '近 7 天', '全部', '自訂'];

  Widget host({
    required double width,
    required double scale,
    required Widget child,
  }) => MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SizedBox(width: width, child: child),
      ),
    ),
  );

  // The toolbar's own layout lives in a private method of HistoryScreen, so
  // this rebuilds the same composition the screen builds.
  //
  // 🔵 **2026-08-24: it is now just the control, and that is the point.** This
  // helper used to reproduce a `Row` of control + warning chip + export chip
  // with a natural-width breakpoint that dropped to two lines. That row has
  // not existed on this screen since the actions moved into the device-scope
  // card, and the calendar button that briefly took their place became the
  // fourth segment — so `_toolbar()` is one padded control and nothing else.
  //
  // 🔴 A test helper that rebuilds a layout the app no longer has answers a
  // question nobody asked (`device_history_toolbar_test.dart` T9 records the
  // same lesson about hard-coded labels), so it was cut down rather than kept
  // for its coverage count.
  Widget toolbar(BuildContext _) => Padding(
    padding: const EdgeInsets.fromLTRB(15, 8, 15, 8),
    child: SegmentedControl<int>(
      selected: 0,
      onChanged: (_) {},
      options: [
        for (var i = 0; i < labels.length; i++) (value: i, label: labels[i]),
      ],
    ),
  );

  group('history toolbar', () {
    // 320 = iPhone SE 1 / small Android. 375 = the machine in the FB-40
    // captures. 440 = a current large phone.
    for (final width in [320.0, 375.0, 390.0, 440.0]) {
      for (final scale in [1.0, 1.15, 1.3, 1.45]) {
        testWidgets(
          'every range label is fully visible at $width pt / $scale×',
          (tester) async {
            await tester.pumpWidget(
              host(
                width: width,
                scale: scale,
                child: Builder(builder: toolbar),
              ),
            );

            final box = tester.getRect(find.byType(SegmentedControl<int>));
            for (final label in labels) {
              final rect = tester.getRect(find.text(label));
              // Inside the control on both edges: a label whose right edge is
              // past the box is the 2026.07.30/009 screenshot.
              expect(
                rect.left,
                greaterThanOrEqualTo(box.left - 0.5),
                reason: '"$label" starts before the control at $width/$scale',
              );
              expect(
                rect.right,
                lessThanOrEqualTo(box.right + 0.5),
                reason: '"$label" is clipped at $width/$scale',
              );
            }
            // 🔑 Inside the box is not the same as READABLE — an ellipsised
            // label is inside it too. Added 2026-08-24 with the fourth
            // segment, because this is the assertion that fails if 「自訂」
            // ever pushes the row past its width; the loop above would not.
            expect(
              segmentedControlNaturalWidth(
                tester.element(find.byType(SegmentedControl<int>)),
                labels,
              ),
              lessThanOrEqualTo(box.width + 0.5),
              reason:
                  'the labels only "fit" at $width/$scale because they '
                  'were ellipsised',
            );
          },
        );
      }
    }

    // 🔵 **The old 'narrow phone gets two lines' case was DELETED 2026-08-24.**
    // It asserted that this toolbar wraps when its contents do not fit — but
    // the contents that could not fit were the two action chips, which left
    // this line long ago. With one control on the line there is nothing to
    // move to a second one, and the test was passing only because the helper
    // above still built the departed row.
    //
    // 🔑 The wrap itself did not disappear, it MOVED: the device detail page's
    // range row is the one that shares a line now, and
    // `device_history_toolbar_test.dart` asserts the two-line fallback there.
  });

  group('SegmentedControl overflow guard', () {
    testWidgets('a slot far too small ellipsises instead of clipping away', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          width: 120,
          scale: 1.45,
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
            ],
          ),
        ),
      );
      // No RenderFlex overflow (pumpWidget would have recorded the exception),
      // and all three segments still exist as tap targets.
      expect(tester.takeException(), isNull);
      expect(find.byType(InkWell), findsNWidgets(labels.length));
    });

    testWidgets('an unbounded slot keeps its natural width', (tester) async {
      // The settings rows lay the control out with an unbounded main axis;
      // a flex child there would throw.
      await tester.pumpWidget(
        host(
          width: 600,
          scale: 1.15,
          child: Row(
            children: [
              const Expanded(child: SizedBox()),
              SegmentedControl<int>(
                selected: 0,
                onChanged: (_) {},
                options: [
                  for (var i = 0; i < labels.length; i++)
                    (value: i, label: labels[i]),
                ],
              ),
            ],
          ),
        ),
      );
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
