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
    // One saved device generates TWO tiles, so deleting one gets us to the
    // floor by the route a user would take rather than by constructing it.
    final s = await boot(tester);
    addTearDown(() => teardown(tester, s));
    await pumpEditor(tester, s);

    var deletes = find.byIcon(Icons.close);
    expect(deletes, findsNWidgets(2));
    expect(
      tester.widgetList<IconButton>(find.byType(IconButton)).where((b) =>
          (b.icon as Icon).icon == Icons.close && b.onPressed != null),
      hasLength(2),
    );

    await tester.tap(deletes.first);
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
    expect(beforeIds, hasLength(3));

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
}
