// The home grid draws COLUMNS, not rows (design 0084 §4.1, stage S2).
//
// ## What changed, and what the change is worth
//
// A row makes both sides advance together: the card under a short one starts
// where the TALLEST card of that row ends. On a 390 pt phone that hole measured
// 135–190 px (design 0084 §2). A column starts it where the short card itself
// ends, and that is the whole of the feature owner ruled for on 2026-08-23
// (方案 B, 可以不等長).
//
// ⚠️ The implementation plan claimed S2 would be invisible ("遷移後結果同今天").
// That was wrong and T-0084-1b is the proof: any block holding more than one
// pair moves, because that is exactly when a column gets to keep going while
// the other side is still tall. It is a small move on the layouts real users
// have (~10 px on the one 4-half capture) and an unbounded one in general.
//
// ## Why the assertions are geometric rather than pixel counts
//
// `chart.top == clock.bottom` is true in any font, at any text scale, on any
// screen. A height total is true in Flutter's test font and nowhere else —
// design 0084 §4.5 records what happens when that distinction is forgotten.
//
// CLEAN-ROOM: expectations derive from this project's own source and rulings.
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/home/home_page.dart';
import 'package:open_smart_batt/ui/home/home_tiles.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();
}

// ## ⚠️ No phone modules in this file, on purpose
//
// `speed`, `gForce` and `clock` would need their switches on to survive
// `renderedFor`, and switching them on mounts the REAL sensor controllers —
// `narrow_tile_layout_test.dart` carries stubs for exactly that reason. They
// are not needed here: a disconnected module tile is the 102 px waiting card
// and a disconnected DEVICE card is 147 px (it has a cached reading and an
// age), so there is a tall card and a short card without touching a receiver.
//
// 🔑 That height difference is what makes these tests able to fail. With every
// card the same height, a column and a row draw the same picture, and every
// assertion below would pass against the code this stage replaced.

Finder _tile(DisplayModule m) => find.byWidgetPredicate(
    (w) => w is HomeTileView && w.tile.module == m,
    description: 'HomeTileView(${m.name})');

Finder _deviceTile() => find.byWidgetPredicate(
    (w) => w is HomeTileView && w.tile.kind == HomeTileKind.deviceCard,
    description: 'HomeTileView(deviceCard)');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  Future<AppServices> boot(WidgetTester tester, List<HomeTile> tiles) async {
    late final AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      s = await AppServices.create(appDatabase: db, ble: _FakeBle());
      // A class is required since design 0050 D4 — the resolver drops every
      // tile belonging to an unidentified unit.
      //
      // ⚠️ `save`, not `saveNew`: `saveNew` leaves work on `pending` that
      // `drain()` in teardown then waits on forever in this harness. Same
      // choice `home_tiles_test.dart` makes, and it is not cosmetic — the
      // symptom is a test that hangs with no output rather than one that fails.
      await s.devices.save(const SavedDevice(
          id: 'DEV-A',
          alias: 'unit A',
          productClass: ProductClass.smartBattery));
      await s.settings.setHomeLayout(HomeLayout(tiles).encode());
    });
    return s;
  }

  Future<void> pump(WidgetTester tester, AppServices s) async {
    tester.view.physicalSize = const Size(390, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<BleService>.value(value: s.ble),
          ChangeNotifierProvider<SettingsController>.value(value: s.settings),
          ChangeNotifierProvider<DeviceController>.value(value: s.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: s.connection),
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
          ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'TW'),
          home: const Scaffold(body: HomePage()),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    // ⚠️ BOTH inside `runAsync`. `dispose()` awaits real I/O, and outside
    // `runAsync` that await sits in the fake-async zone where it can never
    // complete — the symptom is a test that hangs with no output at all rather
    // than one that fails, which cost an hour to find the first time.
    await tester.runAsync(() async {
      await s.pending.drain();
      await s.dispose();
    });
  }

  // ===========================================================================
  // T-0084-1 — a column keeps stacking; a row would not
  // ===========================================================================
  testWidgets("T-0084-1: the card below a short one starts where IT ends",
      (tester) async {
    // 🔑 The shape that tells the two models apart: a SHORT card top-left, a
    // TALLER one beside it, and a third below the short one.
    //   row model    → cells starts below the taller neighbour (147)
    //   column model → cells starts below chart itself (102)
    final s = await boot(tester, const [
      HomeTile.module(DisplayModule.chart,
          deviceId: 'DEV-A', span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.device('DEV-A', span: HomeSpan.half, column: HomeColumn.right),
      HomeTile.module(DisplayModule.cells,
          deviceId: 'DEV-A', span: HomeSpan.half, column: HomeColumn.left),
    ]);
    await pump(tester, s);

    final chartBottom = tester.getBottomLeft(_tile(DisplayModule.chart)).dy;
    final cellsTop = tester.getTopLeft(_tile(DisplayModule.cells)).dy;
    final deviceBottom = tester.getBottomLeft(_deviceTile()).dy;

    expect(cellsTop, chartBottom,
        reason: 'the left column stacks: cells follows chart directly');
    expect(cellsTop, lessThan(deviceBottom),
        reason: 'a row would have pushed cells below the TALLER neighbour — '
            'that push is the hole design 0084 was opened about');
    await teardown(tester, s);
  });

  testWidgets('T-0084-1b: the two columns keep their own x', (tester) async {
    final s = await boot(tester, const [
      HomeTile.module(DisplayModule.chart,
          deviceId: 'DEV-A', span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.device('DEV-A', span: HomeSpan.half, column: HomeColumn.right),
      HomeTile.module(DisplayModule.cells,
          deviceId: 'DEV-A', span: HomeSpan.half, column: HomeColumn.left),
    ]);
    await pump(tester, s);

    final chart = tester.getRect(_tile(DisplayModule.chart));
    final cells = tester.getRect(_tile(DisplayModule.cells));
    final device = tester.getRect(_deviceTile());

    expect(cells.left, chart.left, reason: 'same column ⇒ same x');
    expect(device.left, greaterThan(chart.left));
    expect(chart.width, closeTo(device.width, 0.01),
        reason: 'the two columns split the page evenly');
    // 🔵 2026-08-24. Reported as「左右卡片是黏在一起的」— `Expanded` alone puts
    // the two cards edge to edge, so their 1 px borders meet and read as one
    // line. `kHomeColumnGap` separates them, half taken from each column's
    // inner edge (`home_page.dart`).
    //
    // ⚠️ Asserted as a GAP, not as a width, because the failure this catches is
    // the asymmetric one: all the padding on a single column keeps a gap of
    // exactly this size while making that column narrower than its partner.
    // The width equality above and this together pin both halves.
    expect(device.left - chart.right, closeTo(kHomeColumnGap, 0.01),
        reason: 'the two halves must not touch');
    await teardown(tester, s);
  });

  // ===========================================================================
  // T-0084-6 — 🔴 uneven columns are the SPEC, not a defect
  // ===========================================================================
  testWidgets('T-0084-6: the two columns are allowed to end at different y',
      (tester) async {
    // Owner ruled 2026-08-23「可以不等長」. This test exists so that nobody
    // later "fixes" the ragged bottom — the only way to fix it is to re-impose
    // the row, which silently overturns the ruling. If this ever fails, read
    // design 0084 §4.1a ② before changing it.
    final s = await boot(tester, const [
      HomeTile.module(DisplayModule.chart,
          deviceId: 'DEV-A', span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.module(DisplayModule.cells,
          deviceId: 'DEV-A', span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.device('DEV-A', span: HomeSpan.half, column: HomeColumn.right),
    ]);
    await pump(tester, s);

    final leftBottom = tester.getBottomLeft(_tile(DisplayModule.cells)).dy;
    final rightBottom = tester.getBottomLeft(_deviceTile()).dy;
    expect(leftBottom, isNot(closeTo(rightBottom, 1)),
        reason: 'left holds two cards and right holds one — they must NOT be '
            'equalised');
    await teardown(tester, s);
  });

  testWidgets('T-0084-6b: no card is stretched to match its neighbour',
      (tester) async {
    // The other way a row could creep back: keep two columns but stretch the
    // cards. A clock rendered 427 px tall is not the fix this design chose.
    final s = await boot(tester, const [
      HomeTile.module(DisplayModule.chart,
          deviceId: 'DEV-A', span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.device('DEV-A', span: HomeSpan.half, column: HomeColumn.right),
    ]);
    await pump(tester, s);

    final chart = tester.getSize(_tile(DisplayModule.chart));
    final device = tester.getSize(_deviceTile());
    expect(chart.height, lessThan(device.height),
        reason: 'the waiting card keeps its own height beside a taller one');
    await teardown(tester, s);
  });

  // ===========================================================================
  // T-0084-1c — the rulings this change must NOT disturb
  // ===========================================================================
  testWidgets('T-0084-1c: a full tile still owns the whole width',
      (tester) async {
    final s = await boot(tester, const [
      HomeTile.device('DEV-A'),
      HomeTile.module(DisplayModule.chart,
          deviceId: 'DEV-A', span: HomeSpan.half, column: HomeColumn.left),
      HomeTile.module(DisplayModule.cells,
          deviceId: 'DEV-A', span: HomeSpan.half, column: HomeColumn.right),
    ]);
    await pump(tester, s);

    final full = tester.getSize(_deviceTile()).width;
    final half = tester.getSize(_tile(DisplayModule.chart)).width;
    // Half of the row, less this column's share of `kHomeColumnGap` (3 px).
    expect(half, closeTo((full - kHomeColumnGap) / 2, 0.6),
        reason: 'a full tile spans both columns — it ENDS a block');
    await teardown(tester, s);
  });

  testWidgets('T-0084-1d: a lone 1x1 is still 1x1', (tester) async {
    // 🔴 Ruled twice (`home_page.dart` header). In the column model this falls
    // out of the structure — the other column is simply empty — rather than
    // needing a placeholder beside it. The behaviour must be identical.
    final s = await boot(tester, const [
      HomeTile.device('DEV-A'),
      HomeTile.module(DisplayModule.chart,
          deviceId: 'DEV-A', span: HomeSpan.half, column: HomeColumn.left),
    ]);
    await pump(tester, s);

    final full = tester.getSize(_deviceTile()).width;
    final lone = tester.getRect(_tile(DisplayModule.chart));
    expect(lone.width, closeTo((full - kHomeColumnGap) / 2, 0.6),
        reason: 'an orphan the USER made is drawn as asked, not promoted');
    expect(lone.left, closeTo(tester.getRect(_deviceTile()).left, 0.01),
        reason: 'and it stays in the left column');
    await teardown(tester, s);
  });
}
