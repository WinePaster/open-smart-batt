// The home editor (design 0046 §4.2, T-new-2b and T-new-2c).
//
// Design 0034 refused a drag editor for three reasons; owner ruling R19
// overturns that, and §4.9 says one of the three still stands and must travel
// with the change: **a free editor can produce a bad page, and the worst one is
// an empty page.** The home grid is the app's default entry point since R3, so
// an empty grid is a blank screen on launch.
//
// T-new-2b pins BOTH halves of the guard, and the second half is the one that
// gets lost: the floor must be expressed by a DISABLED control, not by a
// message shown after the tap. §4.7 is a discipline about our own UI — "if you
// need a sentence to explain your interface, the interface is the problem" —
// and a SnackBar reading "at least one card is required" is precisely the
// sentence it forbids.
//
// T-new-2c pins that "restore defaults" writes NULL rather than a snapshot of
// today's generated layout. A snapshot would freeze the device list at the
// moment of the reset, so a unit saved next week would never appear.
//
// 🔴 2026-08-09, design 0053: this page now opens a tutorial dialog on the
// FIRST visit. Every test below pre-acknowledges its marker in `setUp`, so what
// is being driven is still the editor and not a modal barrier. The dialog's own
// behaviour — including the assertion that an unacknowledged marker really does
// open it — lives in `home_editor_tutorial_test.dart`, so pre-acknowledging
// here hides nothing.
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/home/home_preview.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/home/home_editor_page.dart';
import 'package:open_smart_batt/ui/widgets/dashed_border.dart';
import 'package:open_smart_batt/ui/home/home_editor_tutorial.dart';
import 'package:open_smart_batt/ui/dashboard/display_modules.dart';
import 'package:open_smart_batt/ui/home/home_tiles.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  // See the header: design 0053's tutorial is opt-out, and these tests opt out.
  late Directory markerDir;
  setUp(() async {
    markerDir = await Directory.systemTemp.createTemp('osb_ack');
    AckMarker.debugDirectoryOverride = markerDir;
    await kHomeEditorTutorialAck.markAcknowledged();
  });
  tearDown(() {
    AckMarker.debugDirectoryOverride = null;
    if (markerDir.existsSync()) markerDir.deleteSync(recursive: true);
  });

  Future<AppServices> boot(WidgetTester tester,
      {int devices = 1, String? stored}) async {
    late final AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      s = await AppServices.create(appDatabase: db, ble: _FakeBle());
      for (var i = 0; i < devices; i++) {
        // 🔴 A class is required since design 0050 D4 — the home surface (and
        // therefore this editor, which edits the same resolved list) drops
        // every tile belonging to an unidentified device.
        await s.devices.saveNew('DEV-$i', 'unit $i',
            productClass: ProductClass.smartBattery);
      }
      if (stored != null) await s.settings.setHomeLayout(stored);
    });
    return s;
  }

  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => s.pending.drain());
    await s.dispose();
  }

  Future<void> pumpEditor(WidgetTester tester, AppServices s) async {
    tester.view.physicalSize = const Size(900, 2400);
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
          locale: const Locale('en'),
          home: const HomeEditorPage(),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump();
  }

  testWidgets('T-new-2b: the last card cannot be deleted', (tester) async {
    // One saved device generates THREE tiles (device card + gauge + readouts;
    // the card was added 2026-08-07), so deleting down to the floor happens by
    // the route a user would take rather than by constructing it.
    final s = await boot(tester);
    addTearDown(() => teardown(tester, s));
    await pumpEditor(tester, s);

    var deletes = find.byIcon(Icons.close);
    expect(deletes, findsNWidgets(3));
    expect(
      tester.widgetList<IconButton>(find.byType(IconButton)).where((b) =>
          (b.icon as Icon).icon == Icons.close && b.onPressed != null),
      hasLength(3),
    );

    await tester.tap(deletes.first);
    await settle(tester);
    await tester.tap(find.byIcon(Icons.close).first);
    await settle(tester);

    // At the floor.
    deletes = find.byIcon(Icons.close);
    expect(deletes, findsOneWidget);
    final last = tester.widgetList<IconButton>(find.byType(IconButton)).where(
        (b) => (b.icon as Icon).icon == Icons.close);
    expect(last, hasLength(1));
    expect(last.single.onPressed, isNull,
        reason: '§4.9: the floor is a disabled control, not a message');

    // …and pressing it says nothing, because there is nothing to press.
    //
    // 🔴 NARROWED, not deleted, on 2026-08-09 (design 0053 §6). The page now
    // has a tutorial dialog, so "this page shows no dialog at all" is no longer
    // the truth — but the thing this line was really holding is not that. It is
    // the SECOND half of the floor guard: the floor must be expressed by a dead
    // control, never by a message produced in response to the tap. Deleting the
    // line to make the file green again would have thrown that away and left
    // nothing asserting it, so it is re-aimed at the tap instead of the page.
    //
    // `Dialog` as well as `AlertDialog`: the tutorial is a bare `Dialog`, and a
    // matcher that only knew about `AlertDialog` would now pass no matter what
    // the ✕ opened.
    await tester.tap(deletes.first, warnIfMissed: false);
    await settle(tester);
    expect(find.byType(SnackBar), findsNothing,
        reason: '§4.7: a sentence explaining our own UI is the thing this '
            'discipline forbids');
    expect(find.byType(AlertDialog), findsNothing,
        reason: '§4.9: the floor is a disabled control. A dialog opened BY THE '
            'TAP is the "tap and be told" shape the ruling forbids — design '
            '0053 overturned "no instructions anywhere", not this');
    expect(find.byType(Dialog), findsNothing,
        reason: 'the tutorial is opened by the ? action or by a first visit, '
            'never by pressing a dead control');
    expect(HomeLayout.decode(s.settings.homeLayout)!.tiles, hasLength(1));
  });

  testWidgets('T-new-2c: restore defaults writes NULL, not a snapshot',
      (tester) async {
    final s = await boot(tester, devices: 2);
    addTearDown(() => teardown(tester, s));
    await pumpEditor(tester, s);

    // Make it non-default first, so "restore" has something to undo.
    await tester.tap(find.byIcon(Icons.close).first);
    await settle(tester);
    expect(s.settings.homeLayout, isNotNull);

    await tester.tap(find.text('Restore default layout'));
    await settle(tester);

    expect(s.settings.homeLayout, isNull,
        reason: 'a stored snapshot would freeze the device list at this '
            'moment; NULL keeps the generator, so a unit saved next week '
            'appears by itself');
    // And the page now shows what the generator produces for two devices.
    //
    // 🔴 Counted by TILE, not by alias, since design 0051. Every card in this
    // screen draws sample data now — including the device name — so 'unit 0'
    // is not on screen and its absence is the ruling working, not a
    // regression. The two delete buttons and the two preview cards are the
    // honest count of "the generator produced two device tiles".
    expect(find.byIcon(Icons.close), findsNWidgets(2));
    expect(find.text(kPreviewAlias), findsNWidgets(2));
    expect(find.text('unit 0'), findsNothing,
        reason: 'the editor shows sample data, never the real device list');
  });

  testWidgets('the editor offers no protection card, and excludes none either',
      (tester) async {
    // T-new-1 paying out: the add menu is built from `DisplayModule.values`
    // plus one entry per saved device, and nothing in the code filters controls
    // out — there is no member to filter.
    final s = await boot(tester);
    addTearDown(() => teardown(tester, s));
    await pumpEditor(tester, s);

    await tester.tap(find.text('Add card'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    for (final word in ['Protection', 'Cut-off', '斷電', '復電', '保護']) {
      expect(find.textContaining(word), findsNothing, reason: 'must not offer '
          '"$word": design 0034 §6 / design 0046 R4');
    }
    // The menu did render, so "nothing forbidden" is not vacuous.
    expect(find.text('unit 0'), findsWidgets);
  });

  testWidgets('dragging a card onto another swaps them, and it persists',
      (tester) async {
    // 🔴 Rewritten 2026-08-08 for design 0049's grid editor. The old version
    // drove `ReorderableDragStartListener`; the editor now uses `Draggable` /
    // `DragTarget` because a one-dimensional reorderable cannot express a row
    // of two.
    //
    // The gesture is still built by hand and held across frames — an immediate
    // `tester.drag` completes inside one frame, which is not long enough for a
    // drag to be recognised and a target to be entered.
    final s = await boot(tester, devices: 3);
    addTearDown(() => teardown(tester, s));
    await pumpEditor(tester, s);

    final before = HomeLayout.decode(s.settings.homeLayout) ??
        HomeLayout.defaultFor(s.devices.devices);
    final beforeIds = [for (final t in before.tiles) t.deviceId];

    final handles = find.byIcon(Icons.drag_indicator);
    expect(handles, findsWidgets, reason: 'sanity: the grid has drag handles');
    final from = tester.getCenter(handles.first);
    final onto = tester.getCenter(find.byType(HomeTileView).at(1));

    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 150));
    // Several steps: one big jump can pass over the target without the
    // DragTarget ever being entered.
    for (var i = 1; i <= 6; i++) {
      await gesture.moveTo(Offset.lerp(from, onto, i / 6)!);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.pump();
    await settle(tester);

    final after = HomeLayout.decode(s.settings.homeLayout);
    expect(after, isNotNull, reason: 'the drop must be written');
    expect([for (final t in after!.tiles) t.deviceId], isNot(beforeIds),
        reason: 'the drag has to actually move something, or this test is '
            'asserting nothing');

    // §4.9: the grab handle says "drag me". No sentence does.
    for (final word in ['Drag', 'drag', 'reorder', 'at least']) {
      expect(find.textContaining(word), findsNothing);
    }
  });


  testWidgets('🔴 holding a drag at the bottom edge scrolls the grid',
      (tester) async {
    // design 0049 §C5 was written as "not now: the grid is short". That was
    // wrong about the symptom — reported from TestFlight on 0.7.10: with more
    // than a screenful of cards you cannot REORDER AT ALL, because every target
    // you might drop on is off screen.
    //
    // A short viewport is used deliberately: the defect only exists when the
    // content is taller than the view, and a full-height test surface would
    // pass whatever the code did.
    final s = await boot(tester, devices: 6);
    addTearDown(() => teardown(tester, s));
    await pumpEditor(tester, s);
    // AFTER pumpEditor, which sets a tall surface of its own.
    tester.view.physicalSize = const Size(390, 560) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pump();

    final list = find.byType(Scrollable).first;
    final before = tester.widget<Scrollable>(list).controller!.offset;
    expect(tester.getSize(find.byType(ListView).first).height,
        lessThan(1000), reason: 'sanity: the viewport is short');

    // Pick up the first card and hold the finger near the bottom of the grid.
    final handle = find.byIcon(Icons.drag_indicator).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 150));
    final box = tester.getRect(find.byType(ListView).first);
    final target = Offset(box.center.dx, box.bottom - 12);
    // Stepped, with pumps: a single jump can be delivered before the drag
    // recogniser has claimed the pointer, so `onDragUpdate` never fires.
    final start = tester.getCenter(handle);
    for (var i = 1; i <= 5; i++) {
      await gesture.moveTo(Offset.lerp(start, target, i / 5)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    // The ticker runs on a real timer, so the frames have to be pumped.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final during = tester.widget<Scrollable>(list).controller!.offset;
    expect(during, greaterThan(before),
        reason: 'the grid must move under a finger held at its edge');

    // …and it must STOP when the finger lifts, or the list scrolls on its own.
    await gesture.up();
    await tester.pump();
    final atRelease = tester.widget<Scrollable>(list).controller!.offset;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.widget<Scrollable>(list).controller!.offset, atRelease,
        reason: 'a ticker left running is a list that scrolls by itself');
  });

  testWidgets('🔵 S4: dropping into a column tail joins that column',
      (tester) async {
    // 🔴 The gesture the whole of design 0084 exists to make possible, end to
    // end: model → op → widget. `home_grid_ops_test.dart` proves `moveTo`
    // seats the card; this proves the editor is WIRED to it, which is the half
    // a pure-function test cannot see.
    //
    // Three device cards, all full width. Drag the first onto the RIGHT
    // column's tail of the band the second one is in — after making the second
    // a half so a two-column band exists at all.
    final s = await boot(tester, devices: 3);
    addTearDown(() => teardown(tester, s));
    await tester.runAsync(() => s.settings.setHomeLayout(HomeLayout(const [
          HomeTile.device('DEV-0', span: HomeSpan.half, column: HomeColumn.left),
          HomeTile.device('DEV-1'),
          HomeTile.device('DEV-2'),
        ]).encode()));
    await pumpEditor(tester, s);

    final tails = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is DashedBorderPainter);
    expect(tails, findsNWidgets(2),
        reason: 'the first band has one card and two column tails');

    // The RIGHT tail of the first band — the empty column.
    final onto = tester.getCenter(tails.at(1));
    final from = tester.getCenter(find.byIcon(Icons.drag_indicator).at(2));

    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 150));
    for (var i = 1; i <= 6; i++) {
      await gesture.moveTo(Offset.lerp(from, onto, i / 6)!);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.pump();
    await settle(tester);

    final after = HomeLayout.decode(s.settings.homeLayout)!;
    final moved = after.tiles.firstWhere((t) => t.deviceId == 'DEV-2');
    expect(moved.span, HomeSpan.half,
        reason: 'dropping into a half-width position states the width — '
            'design 0049 §3.3, and it must not be asked for twice');
    expect(moved.column, HomeColumn.right,
        reason: 'it joined the column whose tail was under the finger');
  });

  testWidgets('🔴 the column tail is on screen without dragging (Q2)',
      (tester) async {
    // It is the only thing on this page that says "something can go here", and
    // §3.7 forbids saying it in words. If it appeared only mid-drag, nobody
    // would learn it exists.
    //
    // 🔵 design 0084 S4: the slot is no longer a STORED tile, it is the foot of
    // each column. Q2's requirement is unchanged and so is this test's subject
    // — what changed is that there is now one per column instead of one per
    // row, which is also what makes 「可以不等長」 reachable.
    final s = await boot(tester, devices: 1);
    addTearDown(() => teardown(tester, s));
    await tester.runAsync(() => s.settings.setHomeLayout(
          HomeLayout(HomeGridOps.normalise(
                  const [HomeTile.device('DEV-0', span: HomeSpan.half)]))
              .encode(),
        ));
    await pumpEditor(tester, s);

    final stored = HomeLayout.decode(s.settings.homeLayout)!;
    expect(stored.tiles, hasLength(1),
        reason: 'nothing is stored for the empty side any more (S4)');
    expect(stored.tiles.single.column, HomeColumn.left);
    // Both columns of the band draw a tail, so the affordance is on screen for
    // the side that is empty — which is the one Q2 is about.
    expect(
        find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is DashedBorderPainter),
        findsNWidgets(2),
        reason: 'one tail per column, both visible with nothing being dragged');
  });

  testWidgets('🔴 the editor and the home page group tiles identically (G1)',
      (tester) async {
    // The assertion that makes "所見即所得" executable rather than a hope.
    // Both surfaces call `HomeLayout.blocksOf`; if either ever grows its own
    // grouping, this fails — and that drift is the root of all three reports
    // that led to design 0049.
    final s = await boot(tester, devices: 3);
    addTearDown(() => teardown(tester, s));
    await pumpEditor(tester, s);

    // The SAME resolution `_initial()` does — the editor edits the rendered
    // list, not the stored one, so comparing against the stored one would be
    // comparing against a list neither surface draws.
    final tiles = (HomeLayout.decode(s.settings.homeLayout) ??
            HomeLayout.defaultFor(s.devices.devices))
        .renderedFor(s.devices.devices, s.settings.settings,
            gForceAvailable: s.gforce.available)
        .tiles;
    // 🔵 design 0084 S4: the invariant is stated per BAND. A band is either one
    // full-width tile, or two columns of halves — and the columns may be of
    // different lengths, which is Q2.
    for (final b in HomeLayout.blocksOf(tiles)) {
      if (b.full case final int i) {
        expect(tiles[i].span, HomeSpan.full);
      } else {
        expect([...b.left, ...b.right], isNotEmpty);
        for (final i in [...b.left, ...b.right]) {
          expect(tiles[i].span, HomeSpan.half);
        }
      }
    }
    // …and the editor drew one cell per tile.
    expect(find.byType(HomeTileView), findsNWidgets(tiles.length));
  });

  // ===========================================================================
  // 🔴 The shape button — 2026-08-07, from the field:「改形狀…按了沒反應」.
  //
  // It always worked. `HomeTile.copyWith(span:)` was right, `_persist` wrote,
  // the stored layout changed. What did not change was ANYTHING ON SCREEN:
  //
  //   * the editor drew every preview at full width regardless of span, so the
  //     only feedback was a 16 px muted icon swapping between two crop glyphs;
  //   * `HomeLayout.rows` pairs two ADJACENT halves and otherwise emits a row
  //     of one, which the home page then stretched to the full width — so a
  //     half tile next to a full one looked exactly like a full one.
  //
  // Both together meant a control that could only be seen to work if you
  // happened to toggle two neighbours in a row. The state was never the bug;
  // the RENDERING of the state was, in two places at once.
  // ===========================================================================
  group('the shape button', () {
    testWidgets('🔴 halving a tile halves its preview', (tester) async {
      final s = await boot(tester, devices: 2);
      addTearDown(() => teardown(tester, s));
      await pumpEditor(tester, s);

      final before = tester.getSize(find.byType(HomeTileView).first).width;
      expect(before, greaterThan(200), reason: 'sanity: a full-width preview');

      await tester.tap(find.byIcon(Icons.crop_16_9).first);
      await tester.pump();

      final after = tester.getSize(find.byType(HomeTileView).first).width;
      expect(after, closeTo(before / 2, 1.0),
          reason: 'the preview is the only feedback this control has; if it '
              'does not move, the control does not work as far as anyone can '
              'tell');
      // …and the icon follows it, so the two agree about what the tile is now.
      expect(find.byIcon(Icons.crop_square), findsWidgets);
    });

    testWidgets('and the change is written, not just drawn', (tester) async {
      final s = await boot(tester, devices: 2);
      addTearDown(() => teardown(tester, s));
      await pumpEditor(tester, s);

      await tester.tap(find.byIcon(Icons.crop_16_9).first);
      await tester.pump();
      await tester.runAsync(() => s.pending.drain());

      final stored = HomeLayout.decode(s.settings.settings.homeLayout);
      expect(stored, isNotNull);
      expect(stored!.tiles.first.span, HomeSpan.half);
    });
  });

  // ===========================================================================
  // 🔴 Every AVAILABLE phone module can be added back — 2026-08-08, from the
  // field:「我現在 G 值表校準完成；我的主頁沒有 G 值表」.
  //
  // Two things had to line up, and both were true:
  //   * `_initial()` prunes tiles `renderedFor` drops, and `_persist()` writes
  //     the pruned list — so any edit made while the G meter was uncalibrated
  //     deleted its tile from storage permanently;
  //   * the add menu's phone-module entries were HAND-WRITTEN and listed
  //     `speed` only, so there was no way back.
  //
  // The menu now derives them from `DisplayModule.values`. The pruning is
  // unchanged and still one-way — the menu is the way back.
  // ===========================================================================
  group('the add menu offers the phone modules', () {
    testWidgets('🔴 a calibrated G meter can be added back', (tester) async {
      final s = await boot(tester, devices: 1);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() async {
        await s.settings.setGMeterEnabled(true);
        await s.settings
            .setGCalibration('{"m":[1,0,0,0,1,0,0,0,1],"at":1754524800000}');
      });
      // A stored layout with no phone modules at all — exactly what an edit
      // made before calibrating leaves behind.
      await tester.runAsync(() => s.settings.setHomeLayout(
            const HomeLayout([HomeTile.device('DEV-0')]).encode(),
          ));
      await pumpEditor(tester, s);
      expect(s.gforce.available, isTrue, reason: 'sanity: the feature is on');

      await tester.tap(find.text('Add card'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('G meter'), findsOneWidget);
    });

    testWidgets('and an uncalibrated one is not offered', (tester) async {
      // The gate is `available` (switch AND calibration), not the switch —
      // offering a card that would render as nothing is the same defect from
      // the other side.
      final s = await boot(tester, devices: 1);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() => s.settings.setGMeterEnabled(true));
      await pumpEditor(tester, s);
      expect(s.gforce.available, isFalse);

      await tester.tap(find.text('Add card'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('G meter'), findsNothing);
    });


    testWidgets('🔴 the data-gated cells card IS offered to a battery',
        (tester) async {
      // design 0059, flipping the second half of design 0050 缺陷 B. The old
      // `!isDataGated` filter feared "a card that can never render", but on the
      // home surface that card does not exist: a module tile whose body is null
      // draws `HomeWaitingTile` (`home_tiles.dart`), the same honest `--` every
      // module card shows offline. And the only class this menu ever offers
      // `cells` to is the battery, whose DVOL (`0x24`) streams ungated every
      // second (`telemetry-decoding.md` §8.2) — connected, the card has data.
      //
      // The registry still declares the gate (`dataGated: {cells}`): the
      // DASHBOARD keeps showing the card only once data arrives. What changed
      // is this menu alone.
      final s = await boot(tester, devices: 1);
      addTearDown(() => teardown(tester, s));
      await pumpEditor(tester, s);

      expect(DisplayModules.forClass(ProductClass.smartBattery)!
          .has(DisplayModule.cells), isTrue,
          reason: 'sanity: the class does have this card');

      await tester.tap(find.text('Add card'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Per-Cell Voltage'), findsOneWidget);
    });

    testWidgets('🔴 and never to a capacitor', (tester) async {
      // design 0050 D5 pinned through the MENU: with the data-gate filter gone
      // (design 0059), the only thing keeping 分串電壓 away from a capacitor
      // owner — the 2026-08-08 report — is the class registry itself.
      final s = await boot(tester, devices: 0);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() => s.devices.saveNew('CAP-0', 'cap unit',
          productClass: ProductClass.supercapacitor));
      await pumpEditor(tester, s);

      await tester.tap(find.text('Add card'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Per-Cell Voltage'), findsNothing);
      // …and the menu is not empty, so this is not vacuous.
      expect(find.textContaining('cap unit'), findsWidgets);
    });

    testWidgets('🔴 and a device with no class offers no class-specific card',
        (tester) async {
      // design 0050 D3 + 缺陷 A — the exact path that put 分串電壓 in front of
      // a capacitor owner on 2026-08-08: the menu read the STORED class, which
      // is `unknown` for a unit saved but never connected, and `unclassified`
      // was field-for-field the battery.
      final s = await boot(tester, devices: 0);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() => s.devices.saveNew('MYSTERY', 'unknown unit'));
      await pumpEditor(tester, s);

      await tester.tap(find.text('Add card'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (final label in ['Per-Cell Voltage', 'Primary Voltage', 'Live Readings']) {
        expect(find.textContaining('$label · unknown unit'), findsNothing,
            reason: 'no class means no class-specific cards');
      }
    });

    testWidgets('and one already on the page is not offered twice',
        (tester) async {
      final s = await boot(tester, devices: 1);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() async {
        await s.settings.setGMeterEnabled(true);
        await s.settings
            .setGCalibration('{"m":[1,0,0,0,1,0,0,0,1],"at":1754524800000}');
        await s.settings.setHomeLayout(const HomeLayout([
          HomeTile.device('DEV-0'),
          HomeTile.module(DisplayModule.gForce),
        ]).encode());
      });
      await pumpEditor(tester, s);

      await tester.tap(find.text('Add card'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('G meter'), findsNothing,
          reason: 'a second copy of a phone module reads the same sensor and '
              'draws the same number');
    });
  });
}
