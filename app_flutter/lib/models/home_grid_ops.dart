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
      HomeLayout.seated(HomeLayout.autoSized(tiles));

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
  ///
  /// 🔵 design 0106 §6.7: [pin] ⇒ the user dropped the card INTO [column], so
  /// it is pinned there (`columnBy = user`, Q-A3). A move that changes the
  /// card's width is a size the user chose (`sizeBy = user`); a move that
  /// keeps it leaves the size wherever it came from.
  static List<HomeTile> moveTo(List<HomeTile> tiles, int from, int at,
      {HomeColumn? column, bool pin = false}) {
    if (!_inRange(tiles, from)) return List<HomeTile>.of(tiles);
    final out = List<HomeTile>.of(tiles);
    final moving = out.removeAt(from);
    final into = from < at ? at - 1 : at;
    final span = column == null ? HomeSpan.full : HomeSpan.half;
    out.insert(
      into.clamp(0, out.length),
      moving
          .copyWith(span: span)
          .withColumn(column)
          .withSources(
            sizeBy: span != moving.span ? TileSource.user : null,
            columnBy: pin ? TileSource.user : null,
          ),
    );
    return normalise(out);
  }

  /// Set one tile's width — the user's own answer (`sizeBy = user`,
  /// design 0106 §6.7). The editor passes the width it wants rather than
  /// asking for a flip, because what the user SAW may be an engine decision
  /// (an `auto` half drawn full) that the stored span does not record.
  static List<HomeTile> setSpan(
      List<HomeTile> tiles, int index, HomeSpan span) {
    if (!_inRange(tiles, index)) return List<HomeTile>.of(tiles);
    final t = tiles[index];
    final out = List<HomeTile>.of(tiles);
    out[index] = t
        .copyWith(span: span)
        .withColumn(span == HomeSpan.half ? (t.column ?? HomeColumn.left) : null)
        .withSources(sizeBy: TileSource.user);
    return normalise(out);
  }

  /// Hand one tile's size and column back to the engine (design 0106 §6.7).
  static List<HomeTile> resetToAuto(List<HomeTile> tiles, int index) {
    if (!_inRange(tiles, index)) return List<HomeTile>.of(tiles);
    final out = List<HomeTile>.of(tiles);
    out[index] = out[index].asAuto;
    return normalise(out);
  }

  /// How many cards 一鍵整理 would take back from the user: `(sizes, columns)`
  /// currently set by hand (design 0106 §6.6, Q-T1 — the confirm dialog).
  static (int, int) tidyCost(List<HomeTile> tiles) => (
        tiles.where((t) => t.sizeBy == TileSource.user).length,
        tiles
            .where((t) =>
                t.span == HomeSpan.half && t.columnBy == TileSource.user)
            .length,
      );

  /// 一鍵整理 (design 0106 §6.6, Q-T2). Never adds or removes a card.
  ///
  /// 1. Group by device, in the order each device first appears.
  /// 2. Inside a group: the device card, then the group's half-width cards
  ///    (tallest plan height first, so the shortest-column fill pairs similar
  ///    heights), then its full-width cards.
  /// 3. The phone's own modules (no device) last; the add-device card first.
  /// 4. Every card back to `auto` size and column.
  ///
  /// ⚠️ Deviation from the plan's literal order「裝置卡 → 全寬圖表 → 半寬」:
  /// the device card is half since Q-Z1, so putting a full chart right after it
  /// would leave it alone in its run and the orphan rule would draw it full.
  /// Keeping it with the group's halves pairs it instead.
  static List<HomeTile> tidy(List<HomeTile> tiles,
      {List<double?>? planHeights}) {
    final auto = HomeLayout.autoSized([for (final t in tiles) t.asAuto]);
    double h(int i) =>
        (planHeights != null && i < planHeights.length ? planHeights[i] : null) ??
        0;
    final head = <int>[];
    final tail = <int>[];
    final order = <String>[];
    final groups = <String, List<int>>{};
    for (var i = 0; i < auto.length; i++) {
      final t = auto[i];
      final id = t.deviceId;
      if (t.kind == HomeTileKind.addDevice) {
        head.add(i);
      } else if (id == null) {
        tail.add(i);
      } else {
        if (!groups.containsKey(id)) order.add(id);
        groups.putIfAbsent(id, () => []).add(i);
      }
    }
    final picked = <int>[...head];
    for (final id in order) {
      final g = groups[id]!;
      final cards = [
        for (final i in g)
          if (auto[i].kind == HomeTileKind.deviceCard) i,
      ];
      // Tallest first; equal heights keep their list order (stable).
      final halves = [
        for (final i in g)
          if (auto[i].kind != HomeTileKind.deviceCard &&
              auto[i].span == HomeSpan.half)
            i,
      ]..sort((a, b) {
          final c = h(b).compareTo(h(a));
          return c != 0 ? c : a.compareTo(b);
        });
      final fulls = [
        for (final i in g)
          if (auto[i].kind != HomeTileKind.deviceCard &&
              auto[i].span == HomeSpan.full)
            i,
      ];
      picked..addAll(cards)..addAll(halves)..addAll(fulls);
    }
    picked.addAll(tail);
    return normalise([for (final i in picked) auto[i]]);
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
  ///
  /// 🔵 design 0106 §6.5: a newly added card is the engine's — `auto` size and
  /// column — whatever span the caller built it with.
  static List<HomeTile> add(List<HomeTile> tiles, HomeTile tile) =>
      normalise([...tiles, tile.asAuto]);

  static bool _inRange(List<HomeTile> tiles, int i) =>
      i >= 0 && i < tiles.length;
}
