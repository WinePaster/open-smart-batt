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

  @override
  Future<bool> ensurePermissions() async => true;

  /// The unit the shell believes it is linked to. Set directly rather than
  /// through `connect()`: what the pill reads is `connectedDeviceId`, and these
  /// tests are about where a TAP goes, not about how a link is established.
  String? connectedId;

  @override
  String? get connectedDeviceId => connectedId;

  @override
  String get connectedDeviceName => connectedId == null ? '' : 'RCE-CarBatt';

  /// W-3 is a claim about the radio, so the radio has to be counted.
  int startScans = 0;
  int stopScans = 0;

  // The devices tab starts a scan when it becomes visible. Left to the real
  // implementation that would await the adapter behind a 6 s timer this test's
  // fake-async zone never advances, and the suite would report a pending timer
  // instead of the thing under test.
  @override
  Future<void> startScan(
      {Duration timeout = const Duration(seconds: 15)}) async {
    startScans++;
  }

  @override
  Future<void> stopScan() async {
    stopScans++;
  }
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

  late _FakeBleService ble;

  Future<AppServices> pumpShell(WidgetTester tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _FakeBleService();
      services = await AppServices.create(appDatabase: appDb, ble: ble);
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

    // The shell mounted with nothing saved, so the devices tab opened on 搜尋裝置
    // (design 0055 rule 1) and this row — saved programmatically afterwards,
    // which no real path does — is on the other sub-tab. Go and get it.
    await tester.tap(find.text('已儲存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await drain(tester);

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

  // ==========================================================================
  // The app-bar connection pill (ruled 2026-08-12)
  // ==========================================================================
  //
  // Owner report: 「點選右上角的藍牙符號按鈕　就沒作用了」. It was not broken — it
  // did the one thing it had ever done, `_setTab(devices)`, from the devices
  // tab. Nothing was supposed to happen, and nothing did.
  //
  // The rule is three-way so FB-49 (multi-device, filed 2026-08-03) never has
  // to re-open it: nothing linked ⇒ the list; exactly one ⇒ that unit's page;
  // several ⇒ the list. The third case is unreachable today — `BleService` is
  // single-connection — so only the first two can be pinned here. **When FB-49
  // lands, the plural case belongs in this group.**
  group('the connection pill', () {
    Finder pill() => find.byIcon(Icons.bluetooth);

    Future<void> tapPill(WidgetTester tester) async {
      await tester.tap(pill());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await drain(tester);
    }

    testWidgets('with nothing linked it still goes to the list', (tester) async {
      await pumpShell(tester);

      await tapPill(tester);

      expect(find.byType(DeviceDetailPage), findsNothing,
          reason: 'there is no unit to open — pushing a page titled by a null '
              'id would be worse than the tab switch it replaced');
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 1,
          reason: 'design 0046 R2 unchanged for this case');
    });

    testWidgets('with one unit linked it opens THAT unit', (tester) async {
      await pumpShell(tester);
      ble.connectedId = 'DEV-A';
      await tester.pump();

      await tapPill(tester);

      expect(find.byType(DeviceDetailPage), findsOneWidget);
      final page =
          tester.widget<DeviceDetailPage>(find.byType(DeviceDetailPage));
      expect(page.deviceId, 'DEV-A');
      // 🔴 The advertised name travels WITH the push. The case this was
      // reported from is a link with no saved record, and for that unit the
      // advertised name is the only name there is — the page cannot look it up,
      // because the scan that carried it has been stopped (design 0055 §4.2).
      // Without this the title falls back to the raw id.
      expect(page.fallbackName, 'RCE-CarBatt');
    });

    testWidgets('from the devices tab it is no longer a no-op', (tester) async {
      // The report, exactly: standing on 裝置 and pressing it.
      await pumpShell(tester);
      ble.connectedId = 'DEV-A';
      await tester.tap(find.byIcon(Icons.list_alt_outlined));
      await tester.pump();
      await drain(tester);
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 1);

      await tapPill(tester);

      expect(find.byType(DeviceDetailPage), findsOneWidget,
          reason: 'the tab switch it used to do is a no-op from here, which is '
              'the whole complaint');
    });

    // ------------------------------------------------------------------------
    // W-3, rewired 2026-08-12: the scan pauses because a DEVICE PAGE IS UP, not
    // because the devices list was the thing that pushed it.
    //
    // 🔴 This is the test the old wiring could not have. W-3 lived inside
    // `DevicesPage._openDetail`, so it was true by construction for the only
    // entrance that existed and vacuously untested for any other. The pill is a
    // second entrance and it pushes from the SHELL, which has no idea a list is
    // scanning behind it — so under the old code the radio ran for the whole
    // time the user read the page.
    // ------------------------------------------------------------------------
    testWidgets('a page opened from the pill still stops the scan',
        (tester) async {
      await pumpShell(tester);
      ble.connectedId = 'DEV-A';
      await tester.tap(find.byIcon(Icons.list_alt_outlined));
      await tester.pump();
      await drain(tester);
      expect(ble.startScans, greaterThan(0),
          reason: 'the precondition: the tab is scanning');

      final stopsBefore = ble.stopScans;
      await tapPill(tester);
      expect(find.byType(DeviceDetailPage), findsOneWidget);
      expect(ble.stopScans, greaterThan(stopsBefore),
          reason: 'the GNSS and G-force gates already call this window '
              '"somebody is looking at one unit". One of them leaving a radio '
              'on only ever shows up as battery.');

      final startsBefore = ble.startScans;
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump();
      // Two frames past the transition: the page defers its report to a
      // post-frame callback, so the value lands after the route is gone.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await drain(tester);
      expect(find.byType(DeviceDetailPage), findsNothing);
      expect(ble.startScans, greaterThan(startsBefore),
          reason: '`_wantScan` carries the tab\'s intent across the gap, so '
              'the list comes back scanning without anyone re-asking');
    });
  });

  // ==========================================================================
  // "Open Settings" from inside the pushed device page (fixed 2026-08-15)
  // ==========================================================================
  //
  // 🔴 The defect these pin is a control that did NOTHING VISIBLE. The
  // stale-telemetry banner belongs to [DashboardPage], and design 0046 R3 moved
  // the dashboard inside [DeviceDetailPage] — a PUSHED ROUTE. The shell's
  // callback was a bare `_setTab(settings)`, which swaps the IndexedStack page
  // UNDERNEATH that route: the tab really did change, and the device page went
  // on covering it. Tapping the banner looked broken.
  //
  // ⚠️ Why 940-odd green tests missed it, stated so the next reader does not
  // weaken these back: the callback is THREADED, and every test that had ever
  // fired it — `widget_test`'s GPS-gate test and the suite's tab tests — fired
  // it with nothing pushed, which is exactly the one stack depth where a bare
  // `_setTab` is correct. So these two drive it from the route it is actually
  // pressed on, and assert the ROUTE as well as the tab. Asserting only
  // `IndexedStack.index` would have been green throughout the defect.
  //
  // Both entrances are covered on purpose: the shell pushes this page (pill /
  // home tile) and so does [DevicesPage], and the two used to hand down two
  // separately-written callbacks. One of them being fixed is the state this
  // group exists to prevent.
  group('Settings from the device page', () {
    /// The callback the banner would fire, taken from the REAL page in the
    /// tree — not a hand-built one. What is under test is the wiring, and a
    /// locally constructed callback would test the test.
    void tapBannerLink(WidgetTester tester) {
      final page = tester.widget<DeviceDetailPage>(
          find.byType(DeviceDetailPage, skipOffstage: false));
      expect(page.onOpenSettings, isNotNull,
          reason: 'a null here is the same dead control by another route: the '
              'banner renders its chevron only when this is wired');
      page.onOpenSettings!();
    }

    /// Past the pop transition. Same two-frame wait the pill tests use: the
    /// page defers its visibility report to a post-frame callback, so the route
    /// is gone one frame before the controllers hear about it.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await drain(tester);
    }

    testWidgets('leaves the page opened from the pill, and lands on 設定',
        (tester) async {
      final s = await pumpShell(tester);
      ble.connectedId = 'DEV-A';
      await tester.pump();

      await tester.tap(find.byIcon(Icons.bluetooth));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await drain(tester);
      expect(find.byType(DeviceDetailPage), findsOneWidget,
          reason: 'the precondition: a route is on top of the shell');

      tapBannerLink(tester);
      await settle(tester);

      expect(find.byType(DeviceDetailPage), findsNothing,
          reason: 'THE defect: the tab changed and this stayed on top, so the '
              'user saw nothing happen');
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 3,
          reason: 'and the destination is still Settings — leaving the route '
              'must not cost the tab switch it was pressed for');
      expect(
          tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
          3,
          reason: 'the bar agrees, so the user can see where they landed');

      // The pre-existing invariant this fix must not break: every route to
      // another tab still closes GNSS gate condition 3 (design 0042 G4). The
      // pop and the tab switch each close one half — the page reports its own
      // `detailVisible`, the shell reports the tab — and getting the ORDER
      // wrong would leave one of them latched open.
      expect(s.speed.detailVisible, isFalse);
      expect(s.speed.dashboardVisible, isFalse);
      expect(s.speed.speedSurfaceVisible, isFalse);

      expect(tester.takeException(), isNull);
    });

    testWidgets('and the same from the page opened via the devices list',
        (tester) async {
      final s = await pumpShell(tester);
      await tester.runAsync(() => s.devices.saveNew('DEV-A', 'Cap #1'));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.list_alt_outlined));
      await tester.pump();
      await drain(tester);
      // Saved after the shell mounted, so the tab opened on 搜尋裝置 (design
      // 0055 rule 1) and the row is on the other sub-tab.
      await tester.tap(find.text('已儲存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await drain(tester);
      await tester.tap(find.text('Cap #1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await drain(tester);
      expect(find.byType(DeviceDetailPage), findsOneWidget);

      tapBannerLink(tester);
      await settle(tester);

      expect(find.byType(DeviceDetailPage), findsNothing);
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 3,
          reason: 'this entrance hands the callback down through DevicesPage; '
              'it is the same callback for a reason');
      // `DevicesPage._openDetail` resumes AFTER the push returns (it reveals the
      // 已儲存 sub-tab if the unit got named up there). That continuation now
      // runs off a pop it did not perform, on a tab that is no longer showing —
      // it must not throw, and it must not drag the user back to 裝置.
      expect(tester.takeException(), isNull);
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 3);
    });
  });
}
