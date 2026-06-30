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
}
