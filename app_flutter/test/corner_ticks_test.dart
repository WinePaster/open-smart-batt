// The card's L-shaped corner ticks must not overhang its rounded corner.
//
// Reported after v0.6.9 as "some blocks still have square corners". The cards
// were round; the DECORATION on top of them was not — the ticks came from the
// CSS mockup's `.card::before/::after` and were ported to the raw rect corners
// (0,0) and (w,h), which on a 12px radius sit outside the curve.
//
// Neither grep nor the test suite could have caught it: the ticks are painted,
// not styled, and nothing asserted where they land. Hence this file.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/widgets/industrial_card.dart';

void main() {
  const size = Size(300, 200);
  const r = AppTheme.radiusLg;

  test('no tick touches a raw rect corner', () {
    // The exact regression: a tick that starts at (0,0) or (w,h) is drawn
    // where the card has no edge at all.
    final corners = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ];
    for (final (from, to) in CornerTicksPainter.tickSegments(size, r)) {
      for (final c in corners) {
        expect(from, isNot(c));
        expect(to, isNot(c));
      }
    }
  });

  test('every tick stays on a straight edge, clear of the arc', () {
    for (final (from, to) in CornerTicksPainter.tickSegments(size, r)) {
      for (final pt in [from, to]) {
        final onVertical = pt.dx == 0 || pt.dx == size.width;
        final onHorizontal = pt.dy == 0 || pt.dy == size.height;
        expect(onVertical || onHorizontal, isTrue,
            reason: '$pt is not on an edge');
        // Clear of BOTH arcs on whichever edge it sits.
        if (onVertical) {
          expect(pt.dy, greaterThanOrEqualTo(r));
          expect(pt.dy, lessThanOrEqualTo(size.height - r));
        } else {
          expect(pt.dx, greaterThanOrEqualTo(r));
          expect(pt.dx, lessThanOrEqualTo(size.width - r));
        }
      }
    }
  });

  test('ticks scale with the radius rather than assuming 12', () {
    // Guards the token: change AppTheme.radiusLg and the decoration follows,
    // instead of silently drifting back outside the curve.
    final at20 = CornerTicksPainter.tickSegments(size, 20);
    expect(at20.first.$1, const Offset(20, 0));
  });
}
