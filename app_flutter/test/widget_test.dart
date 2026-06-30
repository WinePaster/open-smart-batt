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
    });

    await tester.pumpWidget(OpenRceBattApp(services: services));
    // A couple of frames to let the provider graph + first build settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The MaterialApp + brand shell are present.
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(RootShell), findsOneWidget);
    // Brand mark from the app bar (mockup `.appbar`).
    expect(find.text('OPEN-RCE-BATT'), findsWidgets);
    // Nothing threw while building the tree.
    expect(tester.takeException(), isNull);

    // Note: OpenRceBattApp.dispose() tears down `services` (controllers, BLE,
    // DB) when the test framework unmounts the tree, so we don't dispose here
    // (doing so would double-dispose the ChangeNotifiers).
  });
}
