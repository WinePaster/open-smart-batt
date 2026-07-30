// D.7 — iPad share-sheet popover anchor geometry (export_share.dart).
//
// `Share.shareXFiles` needs a `sharePositionOrigin` Rect on iPad (the sheet is
// a popover); a missing anchor throws/mispositions. The anchor calc was
// extracted into `sharePositionFromBox` / `sharePositionFromContext` so it is
// testable without the platform share channel. We verify the Rect equals the
// triggering widget's global bounds (offset & size), and that an unlaid /
// non-RenderBox context returns null so callers fall back to the system default
// (harmless on iPhone/Android, which ignore the anchor).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ui/util/export_share.dart';

void main() {
  testWidgets('sharePositionFromContext returns the widget global bounds',
      (tester) async {
    late BuildContext anchorContext;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 10, top: 20),
            child: SizedBox(
              width: 40,
              height: 30,
              child: Builder(
                builder: (ctx) {
                  anchorContext = ctx;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      ),
    );

    final rect = sharePositionFromContext(anchorContext);
    expect(rect, isNotNull);
    // Builder fills the 40x30 SizedBox, offset by the padding (10, 20).
    expect(rect!.left, 10);
    expect(rect.top, 20);
    expect(rect.width, 40);
    expect(rect.height, 30);
  });

  testWidgets('sharePositionFromBox matches localToGlobal & size',
      (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(key: key, width: 50, height: 60),
        ),
      ),
    );

    final box = key.currentContext!.findRenderObject()! as RenderBox;
    final rect = sharePositionFromBox(box);
    expect(rect, box.localToGlobal(Offset.zero) & box.size);
    expect(rect, const Rect.fromLTWH(0, 0, 50, 60));
  });

  // --- FB-40: out-of-bounds anchors are rejected by iOS on every device -----
  //
  // 2026-07-30 `016` reported 匯出失敗 with the anchor
  //   {{15, -76.928543864442759}, {345, 369}}
  // against a source view of {{0, 0}, {375, 667}} — an iPhone SE/8, not an
  // iPad. The Settings 「資料」 card had been scrolled 77 pt above the viewport
  // top. Anchors are taken from the card, not the screen, so this reproduces on
  // any phone-sized screen.

  group('clampShareAnchor', () {
    const view = Rect.fromLTWH(0, 0, 375, 667);

    test('leaves a fully visible anchor untouched', () {
      const rect = Rect.fromLTWH(15, 100, 345, 369);
      expect(clampShareAnchor(rect, view), rect);
    });

    test('clips the reported 016 anchor into the view', () {
      // The exact Rect from the field report.
      const rect = Rect.fromLTWH(15, -76.928543864442759, 345, 369);
      final clipped = clampShareAnchor(rect, view);
      expect(clipped, isNotNull);
      expect(clipped!.top, 0);
      expect(clipped.left, 15);
      expect(clipped.width, 345);
      // 369 tall starting 76.93 above the top ⇒ 292.07 visible.
      expect(clipped.height, closeTo(292.071456, 1e-6));
      // The property iOS actually checks.
      expect(view.contains(clipped.topLeft), isTrue);
      expect(clipped.isEmpty, isFalse);
    });

    test('clips an anchor scrolled past the bottom edge', () {
      const rect = Rect.fromLTWH(15, 600, 345, 369);
      final clipped = clampShareAnchor(rect, view);
      expect(clipped, isNotNull);
      expect(clipped!.bottom, 667);
      expect(clipped.height, 67);
    });

    test('returns null when the anchor is entirely off-screen', () {
      expect(clampShareAnchor(const Rect.fromLTWH(15, -400, 345, 369), view),
          isNull);
      expect(clampShareAnchor(const Rect.fromLTWH(15, 700, 345, 369), view),
          isNull);
    });

    test('returns null for a zero-sized anchor (iOS: "must be non-zero")', () {
      expect(clampShareAnchor(const Rect.fromLTWH(15, 100, 0, 0), view), isNull);
      expect(
          clampShareAnchor(const Rect.fromLTWH(15, 100, 345, 0), view), isNull);
    });
  });

  testWidgets('sharePositionFromContext clips a card scrolled off the top',
      (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ListView(
          controller: controller,
          // Same padding as SettingsScreen: x = 15, width = 375 - 30 = 345.
          padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
          children: [
            const SizedBox(height: 200),
            SizedBox(key: key, height: 369),
            const SizedBox(height: 800),
          ],
        ),
      ),
    );

    // Unscrolled: the card is fully visible and the anchor is its raw bounds.
    final before = sharePositionFromContext(key.currentContext!);
    expect(before, const Rect.fromLTWH(15, 203, 345, 369));

    // Scroll so the card's top sits ~77 pt above the viewport, as in `016`.
    controller.jumpTo(280);
    await tester.pump();

    final after = sharePositionFromContext(key.currentContext!);
    expect(after, isNotNull);
    // Before the fix this was Rect.fromLTWH(15, -77, 345, 369) and iOS threw.
    expect(after!.top, greaterThanOrEqualTo(0.0));
    expect(after.left, 15);
    expect(after.width, 345);
    expect(after.height, greaterThan(0.0));
    expect(after.bottom, lessThanOrEqualTo(667.0));
  });

  testWidgets('sharePositionFromContext returns null for an off-screen card',
      (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        // Non-lazy, so the off-screen child stays mounted and we are testing
        // the anchor rather than ListView's viewport recycling.
        child: SingleChildScrollView(
          controller: controller,
          child: Column(
            children: [
              SizedBox(key: key, height: 100),
              const SizedBox(height: 3000),
            ],
          ),
        ),
      ),
    );

    controller.jumpTo(1000);
    await tester.pump();

    // Scrolled far above the viewport: no anchor at all, so the caller passes
    // null and the platform uses its default position.
    expect(sharePositionFromContext(key.currentContext!), isNull);
  });
}
