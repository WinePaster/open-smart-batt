/// OpenSmartBatt — the home editor's layout operations (design 0049, rewritten
/// for design 0084 S4).
///
/// ## What changed, and why the file got shorter
///
/// Until S4 a `half` had no way to say which side it was on, so the LIST had to
/// say it: two adjacent halves were a row, and the unoccupied half of a row was
/// a stored [HomeTileKind]`.empty` placeholder (design 0049 §3.8). Every
/// operation here existed to keep that arrangement true — vacating a tile
/// without letting its neighbours become adjacent, flipping `[gap, tile]` so
/// the gap was always on the right, dropping rows of two gaps.
///
/// A tile that carries its own [HomeColumn] needs none of it. "This column ends
/// here" is expressed by there being no more tiles in that column, so there is
/// nothing to pad, nothing to flip, and no adjacency to protect. What is left
/// is a flat list whose ORDER is the order within each column, and a side per
/// half.
///
/// 🔴 The defect that produced the placeholder is still prevented, by
/// construction rather than by repair. It was: removing one member of a pair
/// orphaned the other, and the greedy re-pairing then reached FORWARD and
/// swallowed the next half, so a drag landed somewhere the gesture had not
/// asked for. Here, removing a tile changes no other tile's column — and the
/// column is the whole of the placement — so no card can move because a
/// different card left.
library;

import 'home_layout.dart';

/// Pure functions over a tile list. No storage, no widgets.
abstract final class HomeGridOps {
  /// Give every `half` a column and every `full` none.
  ///
  /// The only repair left. It is not a re-derivation: [HomeLayout.seated]
  /// honours a column that is already set and only fills in one that is
  /// missing, which after S4 can only happen to a tile some code just built.
  static List<HomeTile> normalise(List<HomeTile> tiles) =>
      HomeLayout.seated(tiles);

  /// Two tiles change places — **each keeps its own span** (design 0049 Q1),
  /// and since S4 each also takes the other's COLUMN.
  ///
  /// 🔑 The column has to travel with the position, and it is the one place
  /// where "keep your own everything" would be wrong. Dropping A onto B is a
  /// request for A to be where B is; leaving A's side alone would leave both
  /// cards in the same column, one above the other, which is not what the
  /// gesture said and not what the finger was pointing at.
  ///
  /// ⚠️ The consequence the owner asked to be able to feel is unchanged:
  /// dragging a `full` onto a `half` lands the full where the half was, and the
  /// half takes the full's place — so a two-column block can lose a column and
  /// a full-width card can end up between two halves. It has a test of its own.
  static List<HomeTile> swap(List<HomeTile> tiles, int from, int to) {
    if (from == to || !_inRange(tiles, from) || !_inRange(tiles, to)) {
      return List<HomeTile>.of(tiles);
    }
    final out = List<HomeTile>.of(tiles);
    final a = out[from], b = out[to];
    out[from] = b.withColumn(a.column);
    out[to] = a.withColumn(b.column);
    return normalise(out);
  }

  /// Move the tile at [from] to sit at [at] in [column].
  ///
  /// The single move. A null [column] means full width; a non-null one means
  /// the tile becomes a `half` on that side — dropping something into a
  /// half-width position is an unambiguous statement of what width it should
  /// be, so requiring the shape button first would be a step with no
  /// information in it (design 0049 §3.3).
  ///
  /// [at] is an index into the list AS IT IS NOW — the one the caller is
  /// looking at — and means "insert before this position". Taking the tile out
  /// shifts everything after it down by one, and that adjustment is made here
  /// rather than in every caller: the editor computes drop targets from the
  /// blocks it just drew, and asking it to also predict its own removal is how
  /// an off-by-one becomes a card landing one slot from where the finger was.
  ///
  /// 🔴 This one function replaces `moveToOwnRow` + `moveIntoSlot` + `_vacate`.
  /// All three existed to keep the placeholder arrangement intact across a
  /// removal; with the side stored on the tile, taking a card out cannot
  /// disturb where any other card sits.
  static List<HomeTile> moveTo(List<HomeTile> tiles, int from, int at,
      {HomeColumn? column}) {
    if (!_inRange(tiles, from)) return List<HomeTile>.of(tiles);
    final out = List<HomeTile>.of(tiles);
    final moving = out.removeAt(from);
    final into = from < at ? at - 1 : at;
    out.insert(
      into.clamp(0, out.length),
      moving.copyWith(
          span: column == null ? HomeSpan.full : HomeSpan.half)
        .withColumn(column),
    );
    return normalise(out);
  }

  /// Flip one tile between full and half (the shape button).
  ///
  /// Going half seats it on the LEFT — the side a lone card has always been
  /// drawn on, and the one a user reading left-to-right expects the card not to
  /// jump away from. Going full clears the side, because a full-width tile has
  /// none.
  static List<HomeTile> toggleSpan(List<HomeTile> tiles, int index) {
    if (!_inRange(tiles, index)) return List<HomeTile>.of(tiles);
    final t = tiles[index];
    final goingHalf = t.span == HomeSpan.full;
    final out = List<HomeTile>.of(tiles);
    out[index] = t
        .copyWith(span: goingHalf ? HomeSpan.half : HomeSpan.full)
        .withColumn(goingHalf ? HomeColumn.left : null);
    return normalise(out);
  }

  /// Remove one tile.
  ///
  /// 🔵 Since S4 this really is a removal. It used to have to leave a
  /// placeholder behind so the row it was in kept its width; now no other
  /// tile's placement mentions it.
  static List<HomeTile> remove(List<HomeTile> tiles, int index) {
    if (!_inRange(tiles, index)) return List<HomeTile>.of(tiles);
    final out = List<HomeTile>.of(tiles)..removeAt(index);
    return normalise(out);
  }

  /// Append a tile as a full-width row of its own.
  static List<HomeTile> add(List<HomeTile> tiles, HomeTile tile) =>
      normalise([...tiles, tile]);

  static bool _inRange(List<HomeTile> tiles, int i) =>
      i >= 0 && i < tiles.length;
}
