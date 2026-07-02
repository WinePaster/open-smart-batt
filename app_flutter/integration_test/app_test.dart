// End-to-end (on-device) smoke harness for the iOS port.
//
// WHAT THIS COVERS:
//   - The app boots and renders its first frame without throwing.
//   - The device-list bottom sheet opens (tap the connection pill) without
//     crashing — i.e. the D.1/D.2 scan-start path is reached and its adapter /
//     permission handling does not blow up on entry.
//
// WHAT THIS DOES *NOT* COVER (and CANNOT, here):
//   The BLE scan / connect / keep-alive paths — the entire reason this app
//   exists — require a PHYSICAL iPhone running iOS plus a nearby, physical RCE
//   battery peripheral. The iOS Simulator has NO Bluetooth radio, and cloud
//   device farms cannot reach a local BLE peripheral. So this skeleton injects
//   an inert fake BleService and asserts only that the UI shell + sheet mount.
//   Real BLE behaviour MUST be verified by manual on-device QA against a real
//   battery (see docs/ios-port-plan.md section 5, the acceptance checklist).
//
// HOW TO RUN (needs a real device, NOT run in CI here):
//   flutter test integration_test/app_test.dart -d <device-id>
// CI only confirms it COMPILES via `flutter analyze`.
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/main.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/ui/devices/device_list_sheet.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService so the harness never touches the (Simulator-absent)
/// CoreBluetooth radio. Overrides only the streams read during startup.
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
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
  });

  testWidgets('app boots to first frame and the device sheet opens',
      (tester) async {
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
    });

    await tester.pumpWidget(OpenSmartBattApp(services: services));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // First frame: the shell mounted without throwing.
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(RootShell), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Open the device-list sheet from the connection pill ("OFFLINE" while
    // disconnected). This exercises the sheet's scan-start entry path.
    await tester.tap(find.text('OFFLINE').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(DeviceListSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
