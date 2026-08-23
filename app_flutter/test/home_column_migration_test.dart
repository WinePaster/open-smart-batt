// Half-width tiles carry their own COLUMN (design 0084 §4.1 / §4.2).
//
// ## The three steps, and which one this file is now about
//
// S1 added `HomeTile.column` as a copy of the tile's position and had nothing
// read it (expand). S2 made the home page read it. **S4 removed the other half
// of the old representation** — the stored `empty` placeholder that used to
// mean "the unoccupied half of this row" — and with it the rule that a
// column could be recomputed from the ordering.
//
// So the file that used to assert "column always equals position" now asserts
// the opposite where it counts: **a stored column is honoured and never
// recomputed**. That is not a weakened test, it is the point of the feature.
// Three cards in the left column and one in the right is a layout no ordering
// can express, and Q2 (「可以不等長」) exists to allow it.
//
// ## The migration, and why the ORDER of the two steps matters
//
// A layout written before S4 says which side a half is on by WHERE it is,
// using the placeholder to hold the other slot. `decode` therefore reads the
// placeholder, seats the columns while it is still in the list, and drops it
// afterwards. Doing it the other way round would swap SIDES: in
// `[A, gap, B, C]` the gap is what puts B under A on the left and C on the
// right, and without it B would land beside A and C underneath.
//
// ## ⚠️ One arrangement genuinely does not survive, and it is not a bug
//
// The placeholder also carried a VERTICAL meaning the column model has no way
// to express: `[A, gap, B, C]` used to draw A alone on a row, with B and C
// BOTH starting below it. Now C rises to sit beside A, because A's column has
// moved on and C's has not.
//
// That is the feature, not a loss of one. The placeholder was never something
// a user placed — `normalise` inserted it to pad an odd count, and the old
// editor's own code called it "structure, not content" when deciding what
// could be deleted. Filling the space under a short card is precisely what
// design 0084 was opened about.
//
// 🔑 And it is unreachable in practice: `empty` appears **0 times in the
// corpus's 124 captures**. Nobody's stored page contains one.
//
// The layouts below are the three shapes that actually appear in the corpus's
// 124 `home: tiles=` capture headers (design 0084 §1.3); 20 of the 26
// half-width captures are the first one. Testing a migration against invented
// layouts would be testing it against the thing this design refused to do —
// guess what users had arranged.
//
// CLEAN-ROOM: expectations derive from this project's own source and captures.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';

/// L1 — 18 of the 26 half-width captures.
List<HomeTile> _l1() => const [
      HomeTile.module(DisplayModule.gaugeVoltage, deviceId: 'd1'),
      HomeTile.module(DisplayModule.chart,
          deviceId: 'd1', span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.module(DisplayModule.readouts,
          deviceId: 'd1', span: HomeSpan.half, column: HomeColumn.right),
      HomeTile.device('d1'),
    ];

/// L3 — 6 captures. Four halves, then two full.
List<HomeTile> _l3() => const [
      HomeTile.module(DisplayModule.clock,
          span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.module(DisplayModule.speed,
          span: HomeSpan.half, column: HomeColumn.right),
      HomeTile.module(DisplayModule.chart,
          deviceId: 'd1', span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.module(DisplayModule.gForce,
          span: HomeSpan.half, column: HomeColumn.right),
      HomeTile.device('d2'),
      HomeTile.module(DisplayModule.cells, deviceId: 'd2'),
    ];

/// L5 — 2 captures.
List<HomeTile> _l5() => const [
      HomeTile.module(DisplayModule.speed),
      HomeTile.module(DisplayModule.chart,
          deviceId: 'd1', span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.module(DisplayModule.gForce,
          span: HomeSpan.half, column: HomeColumn.right),
    ];

Map<String, List<HomeTile>> _real() =>
    {'L1': _l1(), 'L3': _l3(), 'L5': _l5()};

/// What a build BEFORE design 0084 wrote: no `column` keys, and a stored
/// placeholder for the unoccupied half of a row.
///
/// Built by stripping a current encode rather than pasted as a literal, so the
/// fixture cannot drift from the real writer if some other key changes.
String _storedPreS4(List<HomeTile> tiles, {List<int> gapsAfter = const []}) {
  final json = jsonDecode(HomeLayout(tiles).encode()) as Map<String, Object?>;
  final list = (json[HomeLayout.tilesKey] as List).toList();
  for (final t in list) {
    (t as Map).remove('column');
  }
  // Insert the placeholders back to front so the earlier indices stay valid.
  for (final i in gapsAfter.reversed) {
    list.insert(i + 1, {'kind': HomeLayout.legacyGapSlug, 'span': 'half'});
  }
  json[HomeLayout.tilesKey] = list;
  return jsonEncode(json);
}

/// `[A] [B,C|D]` — full-width bands in their own brackets, two-column bands as
/// `left|right`, each column top to bottom.
String shape(List<HomeTile> tiles) => HomeLayout.blocksOf(tiles).map((b) {
      String name(int i) =>
          tiles[i].module?.name ?? 'dev(${tiles[i].deviceId})';
      String col(List<int> ix) => ix.map(name).join(',');
      return b.full != null
          ? '[${name(b.full!)}]'
          : '[${col(b.left)}|${col(b.right)}]';
    }).join(' ');

void main() {
  // ===========================================================================
  // T-0084-2 — the migration is lossless, measured on the real layouts
  // ===========================================================================
  test('T-0084-2: a pre-0084 layout draws exactly as it used to', () {
    for (final e in _real().entries) {
      final after = HomeLayout.decode(_storedPreS4(e.value))!;
      expect(shape(after.tiles), shape(e.value), reason: e.key);
    }
  });

  test('T-0084-2b: 🔴 the placeholder decides SIDES, then goes away', () {
    // `[chart, gap, cells, readouts]` — the old build drew chart alone, then
    // cells|readouts below it.
    //
    // The gap is what makes cells LEFT and readouts RIGHT. Drop it first and
    // the sides invert (cells beside chart, readouts underneath), which is a
    // different page. So it is read first.
    //
    // ⚠️ What it does NOT survive as is the vertical hole: readouts rises to
    // sit beside chart, because chart's column has moved on and readouts's has
    // not. See the header — the placeholder was padding inserted by
    // `normalise`, never a position a user chose, and filling that space is the
    // whole of design 0084.
    const tiles = [
      HomeTile.module(DisplayModule.chart,
          deviceId: 'd1', span: HomeSpan.half),
      HomeTile.module(DisplayModule.cells,
          deviceId: 'd1', span: HomeSpan.half),
      HomeTile.module(DisplayModule.readouts,
          deviceId: 'd1', span: HomeSpan.half),
    ];
    final migrated = HomeLayout.decode(_storedPreS4(tiles, gapsAfter: [0]))!;
    expect(shape(migrated.tiles), '[chart,cells|readouts]');
    expect(migrated.tiles.length, 3, reason: 'the placeholder is not a card');

    // And the proof that reading it mattered: without the gap the sides invert.
    final noGap = HomeLayout.decode(_storedPreS4(tiles))!;
    expect(shape(noGap.tiles), '[chart,readouts|cells]');
  });

  test('T-0084-2c: a full ends the run, so the sides restart after it', () {
    const tiles = [
      HomeTile.module(DisplayModule.chart,
          deviceId: 'd1', span: HomeSpan.half),
      HomeTile.device('d1'),
      HomeTile.module(DisplayModule.cells,
          deviceId: 'd1', span: HomeSpan.half),
    ];
    final migrated = HomeLayout.decode(_storedPreS4(tiles))!;
    expect(shape(migrated.tiles), '[chart|] [dev(d1)] [cells|]',
        reason: 'the tile after a full starts a new run on the LEFT');
  });

  // ===========================================================================
  // T-0084-S4-1 — 🔵 what S1 asserted the opposite of
  // ===========================================================================
  test('T-0084-S4-1: a stored column is honoured, never recomputed', () {
    // Three in one column, one in the other — Q2's arrangement, and the one no
    // ordering can express. S1's invariant ("column == position") would have
    // flattened it to alternating sides; that invariant is what S4 removed.
    const tiles = [
      HomeTile.module(DisplayModule.chart,
          deviceId: 'd1', span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.module(DisplayModule.cells,
          deviceId: 'd1', span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.module(DisplayModule.readouts,
          deviceId: 'd1', span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.module(DisplayModule.gaugeVoltage,
          deviceId: 'd1', span: HomeSpan.half, column: HomeColumn.right),
    ];
    final back = HomeLayout.decode(const HomeLayout(tiles).encode())!;
    expect(shape(back.tiles), '[chart,cells,readouts|gaugeVoltage]');
    expect(shape(HomeGridOps.normalise(tiles)),
        '[chart,cells,readouts|gaugeVoltage]',
        reason: 'normalise must not "repair" it either');
  });

  test('T-0084-S4-2: filtering does not move the survivors', () {
    // 🔵 The reverse of S1's T-0084-S1-4. While the column was a copy of the
    // position, `renderedFor` HAD to re-derive after dropping a tile. Now the
    // column is the user's own answer, and a filtered card must not drag its
    // neighbour across the page.
    const settings = AppSettings();
    expect(settings.speedDetection, isFalse, reason: 'the premise');

    final layout = HomeLayout(_l3()).renderedFor(
      const [
        SavedDevice(
            id: 'd1', alias: 'a', productClass: ProductClass.smartBattery),
        SavedDevice(
            id: 'd2', alias: 'b', productClass: ProductClass.smartBattery),
      ],
      settings,
      gForceAvailable: false,
    );

    // speed and gForce are gone (switches off). chart keeps the LEFT it had.
    expect(shape(layout.tiles), '[clock,chart|] [dev(d2)] [cells]');
  });

  // ===========================================================================
  // T-0084-S1-3 — storage round-trips, and refuses to trust garbage
  // ===========================================================================
  test('T-0084-S1-3: columns survive a round trip', () {
    for (final e in _real().entries) {
      final once = HomeLayout.decode(HomeLayout(e.value).encode())!;
      final twice = HomeLayout.decode(once.encode())!;
      expect(twice.tiles, once.tiles, reason: e.key);
    }
  });

  test('T-0084-S1-3b: a stored column this build cannot read costs no card',
      () {
    // Same rule as shell and view: unknown content degrades to a derived
    // default, it does not drop the tile.
    final json = jsonDecode(HomeLayout(_l1()).encode()) as Map<String, Object?>;
    final tiles = json[HomeLayout.tilesKey] as List;
    (tiles[1] as Map)['column'] = 'middle';

    final decoded = HomeLayout.decode(jsonEncode(json))!;
    expect(decoded.tiles.length, 4, reason: 'no tile was dropped');
    expect(decoded.tiles[1].column, HomeColumn.left,
        reason: 'unreadable ⇒ seated from its position');
  });

  test('T-0084-S1-4: a full tile never carries a column', () {
    final seated = HomeGridOps.normalise([
      HomeTile.device('d1', column: HomeColumn.right),
    ]);
    expect(seated.single.column, isNull,
        reason: 'a full-width tile has no side to be on');
  });
}
