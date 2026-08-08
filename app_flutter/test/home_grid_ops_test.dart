// The home grid's move operations (design 0049 Phase A).
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
// file drives it directly with the four positional cases that matter:
//
//     from before the target · from after it · same row · different row
//
// The second half of the file is about the INVARIANT (`normalise`): every row
// is one `full`, or exactly two `half` slots where a slot may be an empty. It
// is what makes `rowsOf` exact instead of greedy — and greedy is what made a
// drop land where nobody asked, which is the whole reason design 0049 §3.8
// stores the empty slot instead of deriving it.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';

/// Short spellings, so a layout reads as a picture.
HomeTile f(String id) => HomeTile.device(id);
HomeTile h(String id) => HomeTile.device(id, span: HomeSpan.half);
const e = HomeTile.empty();

/// `[A|B] [C] [D|▢]` — the shape every assertion below is checked against.
String shape(List<HomeTile> tiles) => HomeLayout.rowsOf(tiles)
    .map((r) => '[${r.map((t) => t.isEmpty ? '▢' : t.deviceId).join('|')}]')
    .join(' ');

void main() {
  group('normalise: the invariant', () {
    test('a lone half gets its gap', () {
      expect(shape(HomeGridOps.normalise([f('A'), h('B')])), '[A] [B|▢]');
    });

    test('a half before a full gets one too', () {
      expect(shape(HomeGridOps.normalise([h('A'), f('B')])), '[A|▢] [B]');
    });

    test('two halves pair, and gain nothing', () {
      expect(shape(HomeGridOps.normalise([h('A'), h('B')])), '[A|B]');
    });

    test('the gap is always on the RIGHT', () {
      // Two lists that draw the same picture must BE the same list, or every
      // equality check downstream has to know about the flip.
      expect(HomeGridOps.normalise([e, h('A')]), HomeGridOps.normalise([h('A'), e]));
      expect(shape(HomeGridOps.normalise([e, h('A')])), '[A|▢]');
    });

    test('a row of two gaps is not a row', () {
      expect(shape(HomeGridOps.normalise([f('A'), e, e])), '[A]');
    });

    test('a full-width empty is dropped, not drawn as a blank row', () {
      final odd = [f('A'), const HomeTile(kind: HomeTileKind.empty)];
      expect(shape(HomeGridOps.normalise(odd)), '[A]');
    });

    test('it is idempotent', () {
      final once = HomeGridOps.normalise([h('A'), f('B'), h('C')]);
      expect(HomeGridOps.normalise(once), once);
    });

    test('🔴 every row it produces has width 2 or a single full', () {
      // The general form, and the one worth keeping: whatever goes in, what
      // comes out can be grouped exactly. `rowsOf` depends on this.
      final inputs = <List<HomeTile>>[
        [h('A')],
        [h('A'), h('B'), h('C')],
        [e, e, h('A'), f('B'), e],
        [f('A'), f('B')],
        [],
      ];
      for (final input in inputs) {
        for (final row in HomeLayout.rowsOf(HomeGridOps.normalise(input))) {
          if (row.length == 1) {
            expect(row.single.span, HomeSpan.full, reason: shape(input));
          } else {
            expect(row, hasLength(2), reason: shape(input));
            expect(row.every((t) => t.span == HomeSpan.half), isTrue);
            expect(row.every((t) => t.isEmpty), isFalse,
                reason: 'an all-empty row should have been dropped');
          }
        }
      }
    });
  });

  group('swap: two tiles change places, each keeping its span (Q1)', () {
    test('within a row', () {
      final out = HomeGridOps.swap([h('A'), h('B')], 0, 1);
      expect(shape(out), '[B|A]');
    });

    test('across rows, dragging forwards', () {
      final out = HomeGridOps.swap([f('A'), f('B'), f('C')], 0, 2);
      expect(shape(out), '[C] [B] [A]');
    });

    test('across rows, dragging backwards', () {
      final out = HomeGridOps.swap([f('A'), f('B'), f('C')], 2, 0);
      expect(shape(out), '[C] [B] [A]');
    });

    test('🔴 a full onto a half expands that row — and is meant to', () {
      // Design 0049 §7 names this the one case where swapping is harder to
      // predict than inserting. It is pinned rather than smoothed over: the
      // owner chose swap knowing this, and a later "fix" that quietly changed
      // spans would break the promise that a 1x1 stays a 1x1.
      final before = [f('BIG'), h('A'), h('B')];
      expect(shape(before), '[BIG] [A|B]');

      final out = HomeGridOps.swap(before, 0, 1);
      // A took BIG's place and stayed 1x1, so it gets a gap. BIG took A's place
      // and stayed 1x2, so it claims that whole row — which pushes B out to a
      // row of its own, also with a gap. Three rows out of two.
      expect(shape(out), '[A|▢] [BIG] [B|▢]',
          reason: 'neither span travels, so the ROW COUNT changes instead');
      expect(out[0].span, HomeSpan.half);
      expect(out.firstWhere((t) => t.deviceId == 'BIG').span, HomeSpan.full);
    });

    test('swapping a tile with itself changes nothing', () {
      final before = [f('A'), h('B'), h('C')];
      expect(HomeGridOps.swap(before, 1, 1), before);
    });

    test('an out-of-range index is a no-op, not a crash', () {
      final before = [f('A')];
      expect(HomeGridOps.swap(before, 0, 9), before);
      expect(HomeGridOps.swap(before, -1, 0), before);
    });
  });

  group('moveToOwnRow: span survives, and so does the gap (§3.8)', () {
    test('a half dropped on an insertion line stays a half', () {
      // The promise design 0049 §3.3 made and the derived model could not keep:
      // under greedy pairing this tile would have been swallowed by whatever
      // half it landed next to.
      final out = HomeGridOps.moveToOwnRow([f('A'), h('B'), h('C')], 2, 0);
      expect(shape(out), '[C|▢] [A] [B|▢]');
      expect(out.first.span, HomeSpan.half);
    });

    test('a full stays a full', () {
      final out = HomeGridOps.moveToOwnRow([f('A'), f('B')], 1, 0);
      expect(shape(out), '[B] [A]');
    });

    test('🔴 moving DOWN corrects for the removal', () {
      // The off-by-one this file exists for. Row 2 is computed on the list as
      // the caller saw it; after the removal everything below `from` has
      // shifted up by one.
      final before = [f('A'), f('B'), f('C'), f('D')];
      expect(shape(HomeGridOps.moveToOwnRow(before, 0, 2)), '[B] [A] [C] [D]');
      expect(shape(HomeGridOps.moveToOwnRow(before, 0, 4)), '[B] [C] [D] [A]');
    });

    test('moving UP needs no correction, and gets none', () {
      final before = [f('A'), f('B'), f('C')];
      expect(shape(HomeGridOps.moveToOwnRow(before, 2, 0)), '[C] [A] [B]');
    });

    test('a row index past the end lands last', () {
      final before = [f('A'), f('B')];
      expect(shape(HomeGridOps.moveToOwnRow(before, 0, 99)), '[B] [A]');
    });

    test('breaking a pair leaves the partner at half, with a gap (Q3)', () {
      final out = HomeGridOps.moveToOwnRow([h('A'), h('B'), f('C')], 0, 2);
      expect(shape(out), '[B|▢] [C] [A|▢]');
    });
  });

  group('moveIntoSlot: pairing, and the case that defeated greedy', () {
    test('the tile becomes a half and pairs with the slot owner', () {
      final out = HomeGridOps.moveIntoSlot([f('A'), h('B'), e], 0, 2);
      expect(shape(out), '[B|A]');
      expect(out.last.span, HomeSpan.half);
    });

    test('🔴 the case the prototype exposed', () {
      // Drag A into chart's empty slot. Under greedy pairing, removing A
      // orphaned B, B then swallowed `chart`, and A landed somewhere nobody
      // asked for. With the slot stored, A goes exactly where it was dropped
      // and B keeps its own gap.
      final before = [f('gauge'), h('A'), h('B'), h('chart'), e];
      expect(shape(before), '[gauge] [A|B] [chart|▢]');

      final out = HomeGridOps.moveIntoSlot(before, 1, 4);
      expect(shape(out), '[gauge] [B|▢] [chart|A]');
    });

    test('dragging backwards into a slot', () {
      final before = [h('A'), e, f('B')];
      final out = HomeGridOps.moveIntoSlot(before, 2, 1);
      expect(shape(out), '[A|B]');
    });

    test('a target that is not an empty slot is refused', () {
      final before = [f('A'), h('B'), h('C')];
      expect(HomeGridOps.moveIntoSlot(before, 0, 1), before);
    });
  });

  group('toggleSpan and remove keep the invariant', () {
    test('full → half gains a gap', () {
      expect(shape(HomeGridOps.toggleSpan([f('A'), f('B')], 0)), '[A|▢] [B]');
    });

    test('half → full drops the gap it no longer needs', () {
      expect(shape(HomeGridOps.toggleSpan([h('A'), e, f('B')], 0)), '[A] [B]');
    });

    test('half → full inside a pair leaves the partner half, with a gap', () {
      expect(shape(HomeGridOps.toggleSpan([h('A'), h('B')], 0)), '[A] [B|▢]');
    });

    test('removing one of a pair leaves the other half (Q3)', () {
      expect(shape(HomeGridOps.remove([h('A'), h('B')], 0)), '[B|▢]');
    });

    test('removing a lone half takes its gap with it', () {
      expect(shape(HomeGridOps.remove([f('A'), h('B'), e], 1)), '[A]');
    });

    test('add appends as its own row', () {
      expect(shape(HomeGridOps.add([h('A'), e], f('B'))), '[A|▢] [B]');
    });
  });

  group('every operation round trips through storage', () {
    test('🔴 encode → decode is the identity for each result', () {
      // The first line of defence named in design 0049 R1: the home page is the
      // app's default entry point, so a layout that cannot survive being
      // written and read back is a blank screen on next launch.
      final results = <List<HomeTile>>[
        HomeGridOps.swap([f('A'), h('B'), h('C')], 0, 1),
        HomeGridOps.moveToOwnRow([f('A'), h('B'), h('C')], 2, 0),
        HomeGridOps.moveIntoSlot([f('A'), h('B'), e], 0, 2),
        HomeGridOps.toggleSpan([f('A'), f('B')], 0),
        HomeGridOps.remove([h('A'), h('B')], 0),
      ];
      for (final tiles in results) {
        final back = HomeLayout.decode(HomeLayout(tiles).encode());
        expect(back, isNotNull, reason: shape(tiles));
        expect(shape(back!.tiles), shape(tiles));
      }
    });
  });
}
