// The navigation shell after design 0046 (§4.1, N1–N3).
//
// Three facts about the bottom bar that nothing else in the suite states, and
// each of them is a decision somebody made rather than an accident:
//
//   N1 — four destinations, in the order 主頁 / 裝置 / 歷史 / 設定. The ORDER is
//        load-bearing: `_Tab.index` is the IndexedStack index, so a destination
//        inserted in the wrong place silently shows the wrong page.
//   N2 — the app opens on HOME. That is design 0046 R3, and it deliberately
//        overturns design 0034 G4 ("a user who never opens the setting sees no
//        change"). An overturned invariant needs a test of its own, or the next
//        reader restores the old default believing it was a regression.
//   N3 — switching to 歷史 re-keys [HistoryScreen] so it reloads. That
//        behaviour predates 0046 and rode on `_tab == _Tab.history`; going from
//        a 3-value enum to a 4-value one is exactly when an index comparison
//        would have started pointing at the wrong tab.
//
// CLEAN-ROOM: assertions derive from this project's own source and design docs.
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/main.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/ui/devices/device_detail_page.dart';
import 'package:open_smart_batt/ui/devices/devices_page.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:open_smart_batt/ui/home/home_page.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService: never reaches the (unsupported) flutter_blue_plus platform.
class _FakeBleService extends BleService {
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  // The devices tab starts a scan when it becomes visible. Left to the real
  // implementation that would await the adapter behind a 6 s timer this test's
  // fake-async zone never advances, and the suite would report a pending timer
  // instead of the thing under test.
  @override
  Future<void> startScan(
      {Duration timeout = const Duration(seconds: 15)}) async {}

  @override
  Future<void> stopScan() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  /// Let the real (ffi) database finish whatever the last frame started.
  Future<void> drain(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  Future<AppServices> pumpShell(WidgetTester tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      services =
          await AppServices.create(appDatabase: appDb, ble: _FakeBleService());
    });
    await tester.pumpWidget(OpenSmartBattApp(services: services));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await drain(tester);
    // The one-time community disclaimer lands once its marker-file read
    // resolves, which only happens on the REAL event loop — so it appears the
    // moment this file drains one. Dismiss it, or it absorbs every tap aimed at
    // the navigation bar underneath.
    final ack = find.text('我了解，開始使用');
    if (ack.evaluate().isNotEmpty) {
      await tester.tap(ack);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    return services;
  }

  testWidgets('N1: four destinations, in the ruled order', (tester) async {
    await pumpShell(tester);

    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations, hasLength(4));
    expect(
      [
        for (final d in bar.destinations)
          ((d as NavigationDestination).label),
      ],
      ['主頁', '裝置', '歷史', '設定'],
      reason: 'the label order IS the IndexedStack order (design 0046 §3.1)',
    );

    // …and the four bodies exist, so the order above is not describing an
    // empty stack. `skipOffstage: false` because an IndexedStack keeps the
    // unselected pages MOUNTED but offstage — which is the very reason gate
    // condition 3 has to be told which tab is showing.
    expect(find.byType(HomePage, skipOffstage: false), findsOneWidget);
    expect(find.byType(DevicesPage, skipOffstage: false), findsOneWidget);
    expect(find.byType(HistoryScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(SettingsScreen, skipOffstage: false), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('N2: the app opens on the home tab (design 0046 R3)',
      (tester) async {
    await pumpShell(tester);

    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.selectedIndex, 0);

    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.index, 0,
        reason: 'R3 overturns design 0034 G4 on the owner\'s ruling: the '
            'default entry point is the home grid, not one device\'s '
            'dashboard');
  });

  testWidgets('N3: switching to History rebuilds it', (tester) async {
    await pumpShell(tester);

    Key? historyKey() => tester.widget<HistoryScreen>(
          find.byType(HistoryScreen, skipOffstage: false),
        ).key;

    final first = historyKey();

    await tester.tap(find.byIcon(Icons.history_outlined));
    await tester.pump();
    // A remount re-runs HistoryScreen's own DB read against the real (ffi)
    // database, which does not progress inside the widget tester's fake-async
    // zone — drain it on the real event loop, or its lock timer is still
    // pending at teardown.
    await drain(tester);
    final second = historyKey();
    expect(second, isNot(first),
        reason: 'the epoch key is what forces the reload; it was compared '
            'against the enum VALUE, not an index, and the enum just grew');

    // Leaving and coming back bumps it again — the reload is per visit.
    await tester.tap(find.byIcon(Icons.dashboard_outlined));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.history_outlined));
    await tester.pump();
    await drain(tester);
    expect(historyKey(), isNot(second));
  });

  // ==========================================================================
  // design 0046 Step 8c — the GNSS gate, driven through the REAL shell
  // ==========================================================================
  //
  // The 2026-08-07 review established the rule this follows: a unit test on the
  // controller's setters would have passed throughout the defect it was written
  // for, because the defect was in the CALLER. So this drives the tab bar and a
  // pushed route and reads the gate's own condition.
  //
  // ⚠️ SCOPE, stated precisely because the review caught these two overclaiming
  // (W-5). What they pin is the INPUT: does every navigation route actually
  // reach the controller. They deliberately do NOT pin the EFFECT — a shell
  // test cannot, because conditions 1 (a speed card is mounted) and 2 (permission
  // granted) are unreachable here, so `streaming` is false throughout no matter
  // what the gate does.
  //
  // Measured: deleting condition 3 from `_wantsStream` leaves BOTH of these
  // green and turns FOUR tests in `gps_speed_controller_test.dart` red. That
  // split is correct and intentional — the shell owns "did the signal arrive",
  // the controller owns "what the gate does with it" — but it is only safe
  // while both halves exist. **Do not delete either side thinking the other
  // covers it.**
  testWidgets('the home tab is what condition 3 now means', (tester) async {
    final s = await pumpShell(tester);
    final gps = s.speed;

    expect(gps.dashboardVisible, isTrue, reason: 'the app opens on 主頁');
    expect(gps.speedSurfaceVisible, isTrue);

    await tester.tap(find.byIcon(Icons.list_alt_outlined));
    await tester.pump();
    expect(gps.speedSurfaceVisible, isFalse,
        reason: 'the devices LIST carries no speed card, so the shell must '
            'tell the controller the surface is gone. Whether the controller '
            'then closes the stream is pinned in gps_speed_controller_test');

    await tester.tap(find.byIcon(Icons.dashboard_outlined));
    await tester.pump();
    expect(gps.speedSurfaceVisible, isTrue);
  });

  testWidgets('a device page pushed over another tab counts as well',
      (tester) async {
    final s = await pumpShell(tester);
    final gps = s.speed;
    await tester.runAsync(() => s.devices.saveNew('DEV-A', 'Cap #1'));
    await tester.pump();

    // Onto the devices tab: the home grid is covered, so the gate closes…
    await tester.tap(find.byIcon(Icons.list_alt_outlined));
    await tester.pump();
    await drain(tester);
    expect(gps.speedSurfaceVisible, isFalse);

    // …and opening one unit's page — where the dashboard now lives — reopens
    // it. Without this the detail page's own speed card would sit on "waiting
    // for a fix" for as long as it was on screen, with nothing to explain why.
    await tester.tap(find.text('Cap #1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await drain(tester);
    expect(find.byType(DeviceDetailPage), findsOneWidget);
    expect(gps.detailVisible, isTrue);
    expect(gps.speedSurfaceVisible, isTrue);

    // Back out: neither surface is up, so it closes again (design 0042 G4).
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump();
    // Two frames past the transition: the page's `dispose` defers its report to
    // a post-frame callback (same reason `SpeedCard` does), so the value lands
    // one frame after the route is actually gone.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await drain(tester);
    expect(find.byType(DeviceDetailPage), findsNothing);
    expect(gps.detailVisible, isFalse);
    expect(gps.speedSurfaceVisible, isFalse);
  });
}
