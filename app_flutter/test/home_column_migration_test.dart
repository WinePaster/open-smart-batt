// Half-width tiles gain a stored COLUMN (design 0084 §4.1 / §4.2, stage S1).
//
// ## What S1 is, and what it deliberately is not
//
// Design 0084 Q1 chose "the user says which column a 1x1 sits in" over a
// masonry that works it out from the heights. S1 is the EXPAND half of an
// expand/migrate/contract: the field exists, every path fills it, and
// **nothing reads it yet**. Position still decides what is drawn.
//
// That is what makes the step safe to land on its own — there is no state
// `HomeTile.column` can hold that the old model could not, so no stored layout
// can start meaning something new by accident. The other two halves are named
// so nobody has to guess: S2 reverses the arrow (column decides, `rowsOf`
// reads it), S4 removes `HomeTileKind.empty` once the editor no longer needs a
// stored slot to drop onto.
//
// 🔴 Which is why T-0084-S1-2 exists. A redundant representation is exactly the
// "狀態散到兩處" this project keeps a discipline file about; the answer here is
// not to avoid the redundancy (an expand step cannot) but to make it CHECKED,
// and to name the commit that removes it.
//
// ## The migration, and why it is tested against real layouts
//
// Owner ruled Q3 "ok" = lossless conversion. The layouts below are not
// invented: they are the three shapes that actually appear in the corpus's 124
// `home: tiles=` capture headers (design 0084 §1.3), and 20 of those 26
// half-width captures are the first one. Testing the migration against made-up
// layouts would be testing it against the thing this whole design refused to
// do — guess what users had arranged.
//
// CLEAN-ROOM: expectations derive from this project's own source and captures.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';

/// L1 — 18 of the 26 half-width captures.
/// `gaugeVoltage@d1, chart@d1:half, readouts@d1:half, deviceCard@d1`
List<HomeTile> _l1() => const [
      HomeTile.module(DisplayModule.gaugeVoltage, deviceId: 'd1'),
      HomeTile.module(DisplayModule.chart, deviceId: 'd1', span: HomeSpan.half),
      HomeTile.module(DisplayModule.readouts,
          deviceId: 'd1', span: HomeSpan.half),
      HomeTile.device('d1'),
    ];

/// L3 — 6 captures. Four consecutive halves, then two full.
List<HomeTile> _l3() => const [
      HomeTile.module(DisplayModule.clock, span: HomeSpan.half),
      HomeTile.module(DisplayModule.speed, span: HomeSpan.half),
      HomeTile.module(DisplayModule.chart, deviceId: 'd1', span: HomeSpan.half),
      HomeTile.module(DisplayModule.gForce, span: HomeSpan.half),
      HomeTile.device('d2'),
      HomeTile.module(DisplayModule.cells, deviceId: 'd2'),
    ];

/// L5 — 2 captures. A full, then one pair.
List<HomeTile> _l5() => const [
      HomeTile.module(DisplayModule.speed),
      HomeTile.module(DisplayModule.chart, deviceId: 'd1', span: HomeSpan.half),
      HomeTile.module(DisplayModule.gForce, span: HomeSpan.half),
    ];

Map<String, List<HomeTile>> _real() =>
    {'L1': _l1(), 'L3': _l3(), 'L5': _l5()};

/// What a build BEFORE design 0084 wrote: the same layout with every `column`
/// key removed. Simulating the old store this way — rather than pasting a
/// literal — keeps the fixture honest if any other key changes.
String _storedWithoutColumns(List<HomeTile> tiles) {
  final json = jsonDecode(HomeLayout(tiles).encode()) as Map<String, Object?>;
  for (final t in json[HomeLayout.tilesKey] as List) {
    (t as Map).remove('column');
  }
  return jsonEncode(json);
}

/// The invariant S1 rests on: a `half`'s column is the side its POSITION puts
/// it on, and a `full` has none.
void _expectColumnsMatchPositions(HomeLayout layout, {required String because}) {
  for (final row in layout.rows) {
    for (final (i, t) in row.indexed) {
      if (t.span == HomeSpan.full) {
        expect(t.column, isNull, reason: '$because — a full tile has no side');
      } else {
        expect(t.column, i == 0 ? HomeColumn.left : HomeColumn.right,
            reason: '$because — $t is at index $i of its row');
      }
    }
  }
}

void main() {
  // ===========================================================================
  // T-0084-2 — the migration is lossless, measured on the real layouts
  // ===========================================================================
  test('T-0084-2: a layout stored without columns draws exactly as before', () {
    for (final e in _real().entries) {
      final before = HomeLayout(e.value);
      final after = HomeLayout.decode(_storedWithoutColumns(e.value))!;

      // Same rows, same order, same spans — the ruling ("無損轉換") is about
      // what the user SEES, so this compares the row packing rather than the
      // flat list.
      expect(after.rows.length, before.rows.length, reason: e.key);
      for (var r = 0; r < before.rows.length; r++) {
        expect(after.rows[r].length, before.rows[r].length, reason: e.key);
        for (var c = 0; c < before.rows[r].length; c++) {
          final a = after.rows[r][c], b = before.rows[r][c];
          expect(a.kind, b.kind, reason: '${e.key} row $r col $c');
          expect(a.module, b.module, reason: '${e.key} row $r col $c');
          expect(a.deviceId, b.deviceId, reason: '${e.key} row $r col $c');
          expect(a.span, b.span, reason: '${e.key} row $r col $c');
          expect(a.shell, b.shell, reason: '${e.key} row $r col $c');
          expect(a.storedView, b.storedView, reason: '${e.key} row $r col $c');
        }
      }
      _expectColumnsMatchPositions(after, because: '${e.key} after migration');
    }
  });

  test('T-0084-2b: migration fills every half, and only halves', () {
    // L3 is the one with four consecutive halves, so it is the only real layout
    // where "second pair starts a new row" can go wrong.
    final l3 = HomeLayout.decode(_storedWithoutColumns(_l3()))!;
    expect(
      [for (final t in l3.tiles) t.column?.slug],
      ['left', 'right', 'left', 'right', null, null],
      reason: 'clock|speed then chart|gForce, then two full-width tiles',
    );
  });

  // ===========================================================================
  // T-0084-S1-2 — 🔴 the checked redundancy
  // ===========================================================================
  test('T-0084-S1-2: every path that produces tiles agrees with position', () {
    // decode, the grid ops, and the render-time resolver are the three ways a
    // tile list reaches a renderer. All three must leave the same answer, or
    // S2 — which starts believing `column` — would inherit a lie.
    for (final e in _real().entries) {
      final decoded = HomeLayout.decode(_storedWithoutColumns(e.value))!;
      _expectColumnsMatchPositions(decoded, because: '${e.key} decode');

      final normalised = HomeLayout(HomeGridOps.normalise(e.value));
      _expectColumnsMatchPositions(normalised, because: '${e.key} normalise');
    }
  });

  test('T-0084-S1-2b: an edit that moves a tile moves its column with it', () {
    // 🔑 The case a "preserve what was stored" implementation gets wrong. Swap
    // the two halves of L1's pair: neither TILE changed, but each is now on the
    // other side, so a carried-over column would be stale exactly here.
    final swapped = HomeGridOps.swap(_l1(), 1, 2);
    expect(swapped[1].module, DisplayModule.readouts);
    expect(swapped[1].column, HomeColumn.left);
    expect(swapped[2].module, DisplayModule.chart);
    expect(swapped[2].column, HomeColumn.right);
  });

  // ===========================================================================
  // T-0084-S1-3 — storage round-trips, and refuses to trust garbage
  // ===========================================================================
  test('T-0084-S1-3: columns survive a round trip', () {
    for (final e in _real().entries) {
      final once = HomeLayout.decode(_storedWithoutColumns(e.value))!;
      final twice = HomeLayout.decode(once.encode())!;
      expect(twice.tiles, once.tiles, reason: e.key);
    }
  });

  test('T-0084-S1-3b: a stored column this build cannot read costs no card',
      () {
    // Same rule as shell and view: unknown content degrades to the default, it
    // does not drop the tile. A hand-edited database saying `middle` — or one
    // saying `left, left` for a row, which is worse because it PARSES — must
    // come back as the layout the positions describe.
    final json = jsonDecode(HomeLayout(_l1()).encode()) as Map<String, Object?>;
    final tiles = json[HomeLayout.tilesKey] as List;
    (tiles[1] as Map)['column'] = 'middle';
    (tiles[2] as Map)['column'] = 'left';

    final decoded = HomeLayout.decode(jsonEncode(json))!;
    expect(decoded.tiles.length, 4, reason: 'no tile was dropped');
    _expectColumnsMatchPositions(decoded, because: 'garbage columns');
  });

  // ===========================================================================
  // T-0084-S1-4 — filtering repositions, so it must re-derive
  // ===========================================================================
  test('T-0084-S1-4: renderedFor re-derives after it drops a tile', () {
    // L3 with the G meter switched off: `renderedFor` drops that tile, which
    // repacks `chart` from the LEFT of the second row to... still the left, so
    // pick the case that actually moves — drop `speed` instead by leaving its
    // switch off, and `chart` becomes the right of the FIRST row.
    const settings = AppSettings();
    expect(settings.speedDetection, isFalse,
        reason: 'the premise of this test: speed defaults off');

    final layout = HomeLayout(_l3()).renderedFor(
      const [
        SavedDevice(id: 'd1', alias: 'a', productClass: ProductClass.smartBattery),
        SavedDevice(id: 'd2', alias: 'b', productClass: ProductClass.smartBattery),
      ],
      settings,
      gForceAvailable: false,
    );

    // speed and gForce are both gone (switches off) ⇒ clock and chart pair up.
    expect([for (final t in layout.tiles) t.module], [
      DisplayModule.clock,
      DisplayModule.chart,
      null, // the device card
      DisplayModule.cells,
    ]);
    expect(layout.tiles[0].column, HomeColumn.left);
    expect(layout.tiles[1].column, HomeColumn.right,
        reason: 'chart was the LEFT of the second row before filtering — a '
            'column carried over from storage would still say left');
    _expectColumnsMatchPositions(layout, because: 'renderedFor');
  });

  // ===========================================================================
  // T-0084-S1-5 — the empty slot is still the old model's, and still works
  // ===========================================================================
  test('T-0084-S1-5: a stored empty slot takes a column like any half', () {
    // `HomeTileKind.empty` survives S1 on purpose: removing it takes away a
    // VISIBLE editor affordance (`_EmptySlot` and its own drop path in
    // `home_editor_page.dart`), which is S4's work, not a model change. Until
    // then it is a half like any other and must be seated like one, or the
    // invariant above would have a hole exactly where the old model kept its
    // state.
    final tiles = HomeGridOps.normalise(const [
      HomeTile.module(DisplayModule.clock, span: HomeSpan.half),
    ]);
    expect(tiles.length, 2, reason: 'normalise gives a lone half its gap');
    expect(tiles[0].column, HomeColumn.left);
    expect(tiles[1].isEmpty, isTrue);
    expect(tiles[1].column, HomeColumn.right);
  });
}
