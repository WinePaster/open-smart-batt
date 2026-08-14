// Minimal widget smoke test: pump the app shell and confirm it builds without
// crashing. The full graph (DB-backed controllers + the UI shell) is assembled
// via AppServices, using an in-memory sqflite (ffi) database so the test runs
// headless.
//
// The real BleService talks to flutter_blue_plus, which is unsupported on the
// host VM. We inject a tiny [_FakeBleService] that only overrides the few
// members the controllers touch at startup (the platform-backed streams) with
// inert ones, so the shell renders its disconnected/empty state. We avoid
// pumpAndSettle (the app schedules periodic work) and just confirm it builds.
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/main.dart';
import 'package:open_smart_batt/ui/devices/devices_page.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService: never reaches the (unsupported) flutter_blue_plus platform.
/// Overrides only the members evaluated during construction / first build.
class _FakeBleService extends BleService {
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

  setUpAll(() {
    sqfliteFfiInit();
  });

  testWidgets('app shell pumps without crashing', (tester) async {
    // The ffi DB does real (isolate) IO, which won't progress inside the
    // widget-tester fake-async zone — run that setup on the real event loop.
    late final AppServices services;
    await tester.runAsync(() async {
      // In-memory DB so no platform databases dir / file IO is touched.
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      services = await AppServices.create(
        appDatabase: appDb,
        ble: _FakeBleService(),
      );
      // 🔴 Startup queues work that must finish on the REAL event loop, or it
      // is still in flight when the fake-async zone takes over and the test
      // fails on a pending timer it cannot advance. It became reachable on
      // 2026-08-14: `pruneHistory()` used to be a no-op because a fresh install
      // defaulted to `forever`, and design 0061 T8a made a NEW install default
      // to 90 days — so the retention pass now issues a real DELETE.
      await services.pending.drain();
    });

    await tester.pumpWidget(OpenSmartBattApp(services: services));
    // A couple of frames to let the provider graph + first build settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The MaterialApp + brand shell are present.
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(RootShell), findsOneWidget);
    // Brand mark from the app bar (mockup `.appbar`).
    expect(find.text('OPENSMARTBATT'), findsWidgets);
    // Nothing threw while building the tree.
    expect(tester.takeException(), isNull);

    // Note: OpenSmartBattApp.dispose() tears down `services` (controllers, BLE,
    // DB) when the test framework unmounts the tree, so we don't dispose here
    // (doing so would double-dispose the ChangeNotifiers).
  });

  // ---------------------------------------------------------------------------
  // 2026-08-07 Phase D+E review, B1. The GPS gate's condition 3 ("the dashboard
  // is on screen") is produced HERE, by RootShell's tab state — and nothing in
  // the suite had ever driven a tab change through the real shell. That is the
  // same shape as the Phase A–C defect where the Android sampling period was
  // pinned at 5 s past 940 green tests: the gate's INPUT had no test looking at
  // it, only the gate's logic did.
  //
  // The concrete bypass this pins: the stale-telemetry banner's "open Settings"
  // callback wrote `_tab` with its own setState, which does not run
  // didChangeDependencies, so the controller was never told. The receiver kept
  // running behind the Settings page.
  // ---------------------------------------------------------------------------
  testWidgets('every route to another tab closes the GPS gate', (tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      services = await AppServices.create(
        appDatabase: appDb,
        ble: _FakeBleService(),
      );
      // 🔴 Startup queues work that must finish on the REAL event loop, or it
      // is still in flight when the fake-async zone takes over and the test
      // fails on a pending timer it cannot advance. It became reachable on
      // 2026-08-14: `pruneHistory()` used to be a no-op because a fresh install
      // defaulted to `forever`, and design 0061 T8a made a NEW install default
      // to 90 days — so the retention pass now issues a real DELETE.
      await services.pending.drain();
    });

    await tester.pumpWidget(OpenSmartBattApp(services: services));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final gps = services.speed;
    expect(gps.dashboardVisible, isTrue,
        reason: 'the app opens on the home tab, which is the tab that can '
            'carry a speed card since design 0046 R3 moved the dashboard into '
            'the per-device detail page');

    // Route 1: the bottom navigation bar.
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    expect(gps.dashboardVisible, isFalse);

    await tester.tap(find.byIcon(Icons.dashboard_outlined));
    await tester.pump();
    expect(gps.dashboardVisible, isTrue);

    // Route 2: the one that used to bypass it. Driving it through the shell —
    // rather than calling the callback directly — is the point: a unit test on
    // setDashboardVisible would have passed throughout.
    // Re-pointed by design 0046, NOT relaxed: the dashboard (and with it the
    // stale banner that owns this callback) moved into the device detail page,
    // so the shell now hands the callback down through [DevicesPage]. The
    // bypass being pinned is unchanged — a route that switches tab without
    // going through `_setTab` leaves gate condition 3 stuck open.
    final shell = tester.state<State>(find.byType(RootShell));
    final devices = tester.widget<DevicesPage>(
        find.byType(DevicesPage, skipOffstage: false));
    devices.onOpenSettings!();
    await tester.pump();
    expect(gps.dashboardVisible, isFalse,
        reason: 'opening Settings from the stale banner must close the gate '
            'too — the IndexedStack keeps the home grid mounted, so nothing '
            'else will notice it is no longer on screen');
    expect(shell.mounted, isTrue);

    expect(tester.takeException(), isNull);
  });
}
