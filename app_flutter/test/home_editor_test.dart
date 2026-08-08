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
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
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
import 'package:open_smart_batt/ui/home/home_editor_page.dart';
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
        await s.devices.saveNew('DEV-$i', 'unit $i');
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
    await tester.tap(deletes.first, warnIfMissed: false);
    await settle(tester);
    expect(find.byType(SnackBar), findsNothing,
        reason: '§4.7: a sentence explaining our own UI is the thing this '
            'discipline forbids');
    expect(find.byType(AlertDialog), findsNothing);
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
    expect(find.byIcon(Icons.close), findsNWidgets(2));
    expect(find.text('unit 0'), findsOneWidget);
    expect(find.text('unit 1'), findsOneWidget);
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

  testWidgets('reordering persists, and there is no instruction telling you to',
      (tester) async {
    final s = await boot(tester, devices: 3);
    addTearDown(() => teardown(tester, s));
    await pumpEditor(tester, s);

    // The saved-device order is whatever `getSavedDevices` returns; what this
    // test is about is that dragging CHANGES it and that the change is written.
    final before = HomeLayout.decode(s.settings.homeLayout) ??
        HomeLayout.defaultFor(s.devices.devices);
    final beforeIds = [for (final t in before.tiles) t.deviceId];
    // Three device tiles, plus the phone's own modules (speed + G), which carry
    // no deviceId. Counting only the device ones keeps this assertion about
    // what the test is about; the phone tiles are pinned in home_layout_test.
    expect(beforeIds.whereType<String>(), hasLength(3));

    // A manual gesture rather than `tester.drag`: the handle is a
    // `ReorderableDragStartListener`, so the drag has to be held across frames
    // for the list to pick it up.
    final handle = find.byIcon(Icons.drag_handle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 200));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    final after = HomeLayout.decode(s.settings.homeLayout);
    expect(after, isNotNull);
    expect([for (final t in after!.tiles) t.deviceId], isNot(beforeIds),
        reason: 'the drag has to actually move something, or this test is '
            'asserting nothing');

    // §4.9: the grab handle says "drag me". No sentence does.
    for (final word in ['Drag', 'drag', 'reorder', 'at least']) {
      expect(find.textContaining(word), findsNothing);
    }
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
