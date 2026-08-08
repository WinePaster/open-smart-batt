/// OpenSmartBatt — the home grid's three move operations, as pure functions.
///
/// PURE Dart. No Flutter, no widgets, no gestures — and that is the whole
/// reason this file exists rather than the logic living inside the editor.
///
/// ## Why the arithmetic is out here
///
/// Drag-and-drop defects are almost never in the drawing. They are in the index
/// arithmetic: an item is removed and every index after it shifts, and the
/// insertion point computed before the removal is now off by one. That is a
/// pure-data question with a right answer, and it needs no pointer events to
/// ask — so the part most likely to be wrong, and hardest to drive from a
/// widget test, becomes the part that is easiest to test.
///
/// ## The invariant
///
/// **Every row is either one `full` tile, or exactly two `half` slots** — where
/// a slot is a real tile or a [HomeTileKind.empty]. [normalise] establishes it
/// and every operation here ends by calling it.
///
/// That invariant is what makes `HomeLayout.rowsOf` exact rather than greedy,
/// and greedy is what made a drop land somewhere the gesture had not asked for
/// (design 0049 §3.8):
///
/// ```
/// drag A into chart's empty slot
/// before  [gauge(full)] [A(half) B(half)] [chart(half) ▢]
/// greedy  → removing A orphans B, B swallows chart, A lands elsewhere   ✗
/// stored  → [gauge(full)] [B(half) ▢] [chart(half) A(half)]             ✓
/// ```
library;

import 'home_layout.dart';

/// The three moves a drag can make, plus the invariant they all preserve.
abstract final class HomeGridOps {
  /// Repair the row structure: every `half` paired, every `empty` justified.
  ///
  /// Rules, in the order they are applied while walking the list:
  ///
  ///  * a `full` tile owns its row and is left alone;
  ///  * two adjacent `half` slots are a row — unless BOTH are empty, in which
  ///    case the row has nothing in it and is dropped;
  ///  * `[empty, tile]` is flipped to `[tile, empty]`, so the gap is always on
  ///    the right and two layouts that look the same are the same list;
  ///  * a trailing lone `half` gets an `empty` beside it.
  ///
  /// A leading `empty` cannot survive: it is either flipped behind its partner
  /// or dropped with it.
  static List<HomeTile> normalise(List<HomeTile> tiles) {
    final out = <HomeTile>[];
    var i = 0;
    while (i < tiles.length) {
      final t = tiles[i];
      if (t.span != HomeSpan.half) {
        // A stray full-width empty is not a row, it is a blank. Drop it.
        if (!t.isEmpty) out.add(t);
        i += 1;
        continue;
      }
      final next = i + 1 < tiles.length && tiles[i + 1].span == HomeSpan.half
          ? tiles[i + 1]
          : null;
      if (next == null) {
        // Lone half at the end (or before a full): give it its gap.
        if (t.isEmpty) {
          i += 1; // an empty with nobody to hold a place for
          continue;
        }
        out.addAll([t, const HomeTile.empty()]);
        i += 1;
        continue;
      }
      if (t.isEmpty && next.isEmpty) {
        i += 2; // a row of two gaps is not a row
        continue;
      }
      if (t.isEmpty) {
        out.addAll([next, const HomeTile.empty()]);
      } else {
        out.addAll([t, next]);
      }
      i += 2;
    }
    return out;
  }

  /// Two tiles change places. **Each keeps its own span** (design 0049 Q1).
  ///
  /// ⚠️ The consequence the owner asked to be able to feel: dragging a `full`
  /// onto a `half` lands the full inside what was a half-row, and that row
  /// expands. It is the one case where swapping is harder to predict than
  /// inserting would be, so it has a test of its own.
  static List<HomeTile> swap(List<HomeTile> tiles, int from, int to) {
    if (from == to || !_inRange(tiles, from) || !_inRange(tiles, to)) {
      return List<HomeTile>.of(tiles);
    }
    final out = List<HomeTile>.of(tiles);
    final a = out[from];
    out[from] = out[to];
    out[to] = a;
    return normalise(out);
  }

  /// Take the tile at [from] out **without disturbing any row boundary**.
  ///
  /// 🔴 This is the correction that makes the stored empty slot actually work,
  /// and it was found by Phase A before a single widget existed.
  ///
  /// The obvious implementation — remove the element, then repair — puts the
  /// departing tile's neighbours next to each other, and the repair pass then
  /// pairs them, because "two adjacent halves are a row" is still greedy at
  /// heart. That is the ORIGINAL defect wearing a different hat:
  ///
  /// ```
  /// [gauge] [A|B] [chart|▢]   drag A into chart's slot
  /// remove A → gauge,B,chart,▢ → B and chart are now adjacent halves
  /// repair   → [gauge] [B|chart] [A|▢]      ✗ chart moved; nobody asked
  /// ```
  ///
  /// So a departing HALF leaves an empty in its place. The row it was in keeps
  /// its width, nothing becomes newly adjacent, and — usefully — no index
  /// shifts, so the arithmetic for the insertion disappears entirely.
  ///
  /// A departing FULL owns its whole row, so removing it removes the row and
  /// creates no new adjacency. That one really is a removal, and it is the only
  /// case where later indices shift.
  static (List<HomeTile>, bool) _vacate(List<HomeTile> tiles, int from) {
    final out = List<HomeTile>.of(tiles);
    if (tiles[from].span == HomeSpan.half) {
      out[from] = const HomeTile.empty();
      return (out, false);
    }
    out.removeAt(from);
    return (out, true);
  }

  /// Move the tile at [from] so it starts row [rowIndex]. Span unchanged.
  ///
  /// A `half` moved this way stays a `half` and gets an empty slot beside it —
  /// design 0049 §3.8, and the reason `moveToOwnRow` could not keep its promise
  /// under the derived model.
  static List<HomeTile> moveToOwnRow(
      List<HomeTile> tiles, int from, int rowIndex) {
    if (!_inRange(tiles, from)) return List<HomeTile>.of(tiles);
    final moving = tiles[from];
    // Computed on the ORIGINAL list, because that is the list the caller's
    // `rowIndex` refers to.
    var at = _flatIndexOfRow(tiles, rowIndex);
    final (out, shifted) = _vacate(tiles, from);
    if (shifted && from < at) at -= 1;
    out.insert(at.clamp(0, out.length), moving);
    return normalise(out);
  }

  /// Move the tile at [from] into the empty slot at [slot], pairing it with
  /// that slot's partner. The tile becomes a `half`.
  ///
  /// Dropping something into a half-width hole is an unambiguous statement of
  /// what width it should be, so requiring the shape button first would be a
  /// step with no information in it (design 0049 §3.3).
  static List<HomeTile> moveIntoSlot(
      List<HomeTile> tiles, int from, int slot) {
    if (!_inRange(tiles, from) || !_inRange(tiles, slot) || from == slot) {
      return List<HomeTile>.of(tiles);
    }
    if (!tiles[slot].isEmpty) return List<HomeTile>.of(tiles);
    final moving = tiles[from].copyWith(span: HomeSpan.half);
    final (out, shifted) = _vacate(tiles, from);
    final at = shifted && from < slot ? slot - 1 : slot;
    out[at] = moving;
    return normalise(out);
  }

  /// Flip one tile between full and half, in place (the shape button).
  ///
  /// Going half leaves an empty beside it; going full removes the empty its
  /// partner no longer needs. Both fall out of [normalise] rather than being
  /// special-cased here.
  static List<HomeTile> toggleSpan(List<HomeTile> tiles, int index) {
    if (!_inRange(tiles, index)) return List<HomeTile>.of(tiles);
    final t = tiles[index];
    final out = List<HomeTile>.of(tiles);
    out[index] = t.copyWith(
        span: t.span == HomeSpan.full ? HomeSpan.half : HomeSpan.full);
    return normalise(out);
  }

  /// Remove one tile. Its partner, if it had one, keeps its half and its gap.
  static List<HomeTile> remove(List<HomeTile> tiles, int index) {
    if (!_inRange(tiles, index)) return List<HomeTile>.of(tiles);
    final (out, _) = _vacate(tiles, index);
    return normalise(out);
  }

  /// Append a tile as a row of its own.
  static List<HomeTile> add(List<HomeTile> tiles, HomeTile tile) =>
      normalise([...tiles, tile]);

  /// The flat index at which row [rowIndex] begins. `rows.length` means "past
  /// the end", which is how a drop below the last row is expressed.
  static int _flatIndexOfRow(List<HomeTile> tiles, int rowIndex) {
    final rows = HomeLayout.rowsOf(tiles);
    var flat = 0;
    for (var r = 0; r < rows.length; r++) {
      if (r == rowIndex) return flat;
      flat += rows[r].length;
    }
    return tiles.length;
  }

  static bool _inRange(List<HomeTile> tiles, int i) =>
      i >= 0 && i < tiles.length;
}
