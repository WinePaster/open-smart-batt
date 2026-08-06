// The devices tab (design 0046 §4.1 N4–N6, §4.2 T-new-6).
//
// 🔑 N4 IS THE CLOSING ARGUMENT FOR FB `2026.08.02/004`. The reporter (林陳裕)
// said switching devices "跳回主頁面 3～4 秒，以為藍牙斷線". Nothing was wrong
// with the link: the device-list SHEET popped itself the instant a connect
// returned, which put the dashboard's empty state on screen for the several
// seconds a switch takes — and an empty state is indistinguishable from a
// dropped link. Independent measurement put the median switch at 4.97 s over 12
// attempts.
//
// Design 0046 R22 ruled fix C — the UI stays put — so what this file pins is an
// ABSENCE: no navigation happens on a successful connect. An absence needs a
// test more than a presence does, because the way it regresses is somebody
// adding a `Navigator.pop()` back for a reason that looks good locally.
//
// CLEAN-ROOM: expectations derive from this project's own source, design docs
// and field reports.
import 'dart:async';

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
import 'package:open_smart_batt/ui/devices/device_detail_page.dart';
import 'package:open_smart_batt/ui/devices/devices_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A BLE service whose link state and scan results a test can simply state.
class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _scanOut = StreamController<List<DiscoveredDevice>>.broadcast();

  String? connectedId;

  @override
  String get connectedDeviceName => connectedId == null ? '' : 'RCE-CarBatt';

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<List<DiscoveredDevice>> get scanResults => _scanOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      Stream<BluetoothAdapterState>.value(BluetoothAdapterState.on);

  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> startScan(
      {Duration timeout = const Duration(seconds: 15)}) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    connectedId = deviceId;
    _linkOut.add(BleLinkState.connecting);
    _linkOut.add(BleLinkState.connected);
    _linkOut.add(BleLinkState.ready);
  }

  @override
  Future<void> disconnect() async {
    connectedId = null;
    _linkOut.add(BleLinkState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _scanOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late _FakeBle ble;

  Future<AppServices> makeServices(WidgetTester tester) async {
    late final AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _FakeBle();
      s = await AppServices.create(appDatabase: db, ble: ble);
      await s.devices.saveNew('DEV-A', 'Cap #1', name: 'RCE-SCAP_II');
    });
    return s;
  }

  Future<void> teardown(WidgetTester tester, AppServices s) =>
      tester.runAsync(s.dispose);

  Future<void> pumpPage(WidgetTester tester, AppServices s) async {
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
          home: const Scaffold(body: DevicesPage()),
        ),
      ),
    );
    await tester.pump();
  }

  /// Let the real (ffi) database finish whatever the last frame started.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump();
  }

  testWidgets('N4: connecting a saved device leaves the user on this page',
      (tester) async {
    // FB `2026.08.02/004`'s closing criterion, stated as an absence.
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    await pumpPage(tester, s);
    await settle(tester);

    expect(find.text('Cap #1'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    await settle(tester);

    expect(s.connection.isOnline, isTrue);
    // THE assertion: the page is still the one the tap happened on. Before
    // design 0046 this was a modal sheet that popped itself here, dropping the
    // user onto the dashboard's empty state for ~5 s.
    expect(find.byType(DevicesPage), findsOneWidget);
    expect(find.byType(DeviceDetailPage), findsNothing);
    // …and the row says so in place.
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets('N5: a new device is named without leaving either',
      (tester) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    await pumpPage(tester, s);
    await settle(tester);

    // A nearby, unsaved unit.
    await tester.runAsync(() async {
      ble._scanOut.add([
        const DiscoveredDevice(
            id: 'DEV-NEW', name: 'RCE-CarBatt', rssi: -55, isVendor: true),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    expect(find.text('RCE-CarBatt'), findsOneWidget);

    await tester.tap(find.text('Connect').last);
    await settle(tester);

    // The alias prompt appears IN PLACE — it used to belong to the sheet's
    // host, reached by popping with the new id.
    expect(find.byType(DevicesPage), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Car #2');
    await tester.pump();
    await tester.tap(find.text('Save alias'));
    await settle(tester);

    expect(s.devices.isSaved('DEV-NEW'), isTrue);
    expect(s.devices.deviceFor('DEV-NEW')!.alias, 'Car #2');
    // The stable advertised name is captured too (D.3): on iOS the saved id is
    // a volatile NSUUID and the name is what rebinds the record.
    expect(s.devices.deviceFor('DEV-NEW')!.name, 'RCE-CarBatt');
    expect(find.byType(DevicesPage), findsOneWidget);
  });

  testWidgets('N6: disconnecting leaves the user on this page too',
      (tester) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    await pumpPage(tester, s);
    await settle(tester);

    await tester.tap(find.text('Connect'));
    await settle(tester);
    expect(s.connection.isOnline, isTrue);

    await tester.tap(find.text('Disconnect'));
    await settle(tester);

    expect(s.connection.isOnline, isFalse);
    expect(find.byType(DevicesPage), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}
