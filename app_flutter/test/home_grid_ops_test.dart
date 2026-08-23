// The home grid's move operations (design 0049 Phase A, rewritten for design
// 0084 S4).
//
// 🔴 THE POINT OF THIS FILE, stated before the first test.
//
// Drag-and-drop defects are almost never in the drawing. They are in the index
// arithmetic — an element is removed, every index after it shifts, and the
// insertion point computed before the removal is now off by one. A widget test
// can only reach that through a gesture, across frames, through a hit test; by
// the time it fails you are debugging three layers to find a subtraction.
//
// So the arithmetic lives in `home_grid_ops.dart` as pure functions, and this
// file drives it directly with the positional cases that matter:
//
//     from before the target · from after it · same column · different column
//
// ## What S4 changed, and what it did NOT
//
// Until S4 a `half` had no way to say which side it was on, so the LIST said
// it: two adjacent halves were a row, and the unoccupied half was a stored
// placeholder. Half of this file used to be about keeping that arrangement
// true — the gap always on the right, a row of two gaps dropped, a departing
// tile leaving its gap behind.
//
// 🔴 Those tests are gone because the STATE they described is gone, not because
// the defect they guarded stopped mattering. That defect was: removing one
// member of a pair orphaned the other, and greedy re-pairing then reached
// forward and swallowed the next half, so a drop landed where nobody asked.
// It is now impossible by construction — a card's placement is its own
// `column`, so no card can move because a different card left — and
// `remove: taking a card out moves nobody else` is the test that says so.
//
// Kept in full: every index-arithmetic case, and the full-onto-half swap the
// owner asked to be able to feel (design 0049 Q1).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';

/// Short spellings, so a layout reads as a picture.
HomeTile f(String id) => HomeTile.device(id);
HomeTile l(String id) =>
    HomeTile.device(id, span: HomeSpan.half, column: HomeColumn.left);
HomeTile r(String id) =>
    HomeTile.device(id, span: HomeSpan.half, column: HomeColumn.right);

/// `[A] [B,C|D]` — a full-width band in its own brackets, a two-column band as
/// `left|right` with each column comma-separated top to bottom.
String shape(List<HomeTile> tiles) => HomeLayout.blocksOf(tiles).map((b) {
      String col(List<int> ix) => ix.map((i) => tiles[i].deviceId!).join(',');
      return b.full != null
          ? '[${tiles[b.full!].deviceId}]'
          : '[${col(b.left)}|${col(b.right)}]';
    }).join(' ');

void main() {
  group('normalise: the invariant', () {
    test('every half has a side, every full has none', () {
      final out = HomeGridOps.normalise([
        f('A'),
        const HomeTile(kind: HomeTileKind.deviceCard, deviceId: 'B', span: HomeSpan.half),
        f('C'),
      ]);
      expect(out[0].column, isNull);
      expect(out[1].column, HomeColumn.left, reason: 'a side-less half seats left');
      expect(out[2].column, isNull);
    });

    test('a stored side is honoured, never recomputed', () {
      // 🔴 The whole of Q1. Three cards in one column is a layout no ordering
      // could express, so a normalise that "repaired" it by alternating sides
      // would delete the arrangement the user was given the ability to make.
      expect(shape(HomeGridOps.normalise([l('A'), l('B'), l('C'), r('D')])),
          '[A,B,C|D]');
    });

    test('a full ends a band; halves either side of it are two bands', () {
      expect(shape(HomeGridOps.normalise([l('A'), f('B'), l('C')])),
          '[A|] [B] [C|]');
    });
  });

  group('swap: places change, and so do sides', () {
    test('two halves in the same band exchange columns', () {
      // Dropping A onto B is a request for A to be where B is. Leaving A on the
      // left would put both cards in one column, which is not what the finger
      // was pointing at.
      expect(shape(HomeGridOps.swap([l('A'), r('B')], 0, 1)), '[B|A]');
    });

    test('🔴 a full dropped onto a half lands where the half was (Q1)', () {
      // The consequence the owner asked to be able to FEEL, and it is louder in
      // the column model than it was in the row one: each keeps its own SPAN,
      // so the full-width card lands between the two halves and SPLITS their
      // band into two one-column bands.
      //
      //     before  [A] [B|C]        A full, B left, C right
      //     after   [B|] [A] [|C]
      //
      // Nothing here is a repair — B and C each kept the side they had. It
      // reads as a big change because a full-width tile genuinely cannot sit
      // inside a two-column band; it is the whole width.
      expect(shape(HomeGridOps.swap([f('A'), l('B'), r('C')], 0, 1)),
          '[B|] [A] [|C]');
    });

    test('out of range, or onto itself, changes nothing', () {
      final before = [f('A'), l('B'), r('C')];
      expect(shape(HomeGridOps.swap(before, 1, 1)), shape(before));
      expect(shape(HomeGridOps.swap(before, 0, 9)), shape(before));
      expect(shape(HomeGridOps.swap(before, -1, 0)), shape(before));
    });
  });

  group('moveTo: the index arithmetic, in both directions', () {
    // `at` is an index into the list AS IT IS NOW. The removal shifts
    // everything after `from` down by one, and `moveTo` — not the caller — is
    // what accounts for it. These four cases are the ones that catch it.
    test('moving DOWN lands before the tile that was at `at`', () {
      expect(shape(HomeGridOps.moveTo([f('A'), f('B'), f('C')], 0, 2)),
          '[B] [A] [C]');
    });

    test('moving UP lands before the tile that was at `at`', () {
      expect(shape(HomeGridOps.moveTo([f('A'), f('B'), f('C')], 2, 1)),
          '[A] [C] [B]');
    });

    test('past the end is the end', () {
      expect(shape(HomeGridOps.moveTo([f('A'), f('B')], 0, 99)), '[B] [A]');
    });

    test('a column target makes the tile a half on that side', () {
      expect(
          shape(HomeGridOps.moveTo([f('A'), l('B')], 0, 2,
              column: HomeColumn.right)),
          '[B|A]');
    });

    test('a null column makes it full width again', () {
      expect(shape(HomeGridOps.moveTo([l('A'), r('B')], 1, 0)), '[B] [A|]');
    });

    test('dropping into the tail of a column that is empty is allowed', () {
      // 🔑 Q2「可以不等長」 is reachable only because of this: the tail of the
      // SHORTER column is a target, so a user can give one column three cards.
      expect(
          shape(HomeGridOps.moveTo([l('A'), l('B'), f('C')], 2, 2,
              column: HomeColumn.right)),
          '[A,B|C]');
    });
  });

  group('toggleSpan: the shape button', () {
    test('full becomes a half on the LEFT', () {
      final out = HomeGridOps.toggleSpan([f('A')], 0);
      expect(out[0].span, HomeSpan.half);
      expect(out[0].column, HomeColumn.left,
          reason: 'a lone card has always been drawn on the left; jumping to '
              'the right would be a move nobody asked for');
    });

    test('half becomes full and loses its side', () {
      final out = HomeGridOps.toggleSpan([l('A'), r('B')], 0);
      expect(out[0].span, HomeSpan.full);
      expect(out[0].column, isNull);
      expect(shape(out), '[A] [|B]',
          reason: 'B keeps the RIGHT side it had — widening A must not shunt '
              'the other card across the page');
    });
  });

  group('remove: taking a card out moves nobody else', () {
    test('🔴 the defect the stored placeholder existed to prevent', () {
      // The original: `[gauge] [A|B] [chart|▢]`, drag A away, and greedy
      // re-pairing made B and chart adjacent — so CHART moved, and nobody had
      // asked it to. Here the survivors keep their own sides, so the only thing
      // that changes is the thing that left.
      final before = [f('G'), l('A'), r('B'), l('C')];
      expect(shape(before), '[G] [A,C|B]');
      expect(shape(HomeGridOps.remove(before, 1)), '[G] [C|B]',
          reason: 'B and C keep the columns they were in');
    });

    test('removing a full closes its band', () {
      expect(shape(HomeGridOps.remove([l('A'), f('B'), l('C')], 1)), '[A,C|]');
    });

    test('out of range changes nothing', () {
      final before = [f('A'), l('B')];
      expect(shape(HomeGridOps.remove(before, 9)), shape(before));
    });
  });

  group('add', () {
    test('appends full width', () {
      final out = HomeGridOps.add([l('A')], f('B'));
      expect(shape(out), '[A|] [B]');
      expect(out.last.column, isNull);
    });
  });
}
