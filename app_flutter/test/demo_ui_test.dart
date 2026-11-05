// design 0097 P3 — the demo mode's screens.
//
// T7: the scan list's demo entry is there with and without scan hits, and
//     leads to the picker.
// Banner: up on every route while a demo unit is the target, and its button
//     ends the demo.
// Names: a demo unit is named by what it is, in the app's language.
// Save: a demo unit is never offered for saving.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState, ErrorPlatform, FlutterBluePlusException;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/demo/demo.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/demo/demo_ui.dart';
import 'package:open_smart_batt/ui/devices/device_detail_page.dart';
import 'package:open_smart_batt/ui/devices/devices_page.dart';
import 'package:open_smart_batt/ui/devices/save_device_flow.dart';
import 'package:open_smart_batt/ui/util/export_scope.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Link state and scan results a test can state outright.
class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _scanOut = StreamController<List<DiscoveredDevice>>.broadcast();
  String? connectedId;

  @override
  String? get connectedDeviceId => connectedId;

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

  /// Make a scan fail the way flutter_blue_plus does with the radio off.
  bool scanFails = false;

  @override
  Future<void> startScan(
      {Duration timeout = const Duration(seconds: 15)}) async {
    if (scanFails) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, 'startScan', 1, 'Bluetooth must be turned on');
    }
  }

  @override
  Future<void> stopScan() async {}

  void emitScan(List<DiscoveredDevice> r) => _scanOut.add(r);

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
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      ble = _FakeBle();
      s = await AppServices.create(appDatabase: db, ble: ble);
    });
    return s;
  }

  Widget app(AppServices s, Widget home, {String locale = 'en'}) =>
      MultiProvider(
        providers: [
          Provider<AppServices>.value(value: s),
          Provider<BleService>.value(value: s.ble),
          ChangeNotifierProvider<SettingsController>.value(value: s.settings),
          ChangeNotifierProvider<DeviceController>.value(value: s.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: s.connection),
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
          ChangeNotifierProvider<AlertController>.value(value: s.alerts),
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
          ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale(locale),
          // The same wrapper `main.dart` installs.
          builder: (context, child) => DemoBannerFrame(child: child!),
          home: home,
        ),
      );

  group('T7 scan list entry', () {
    testWidgets('shown with no scan hits', (tester) async {
      final s = await makeServices(tester);
      await tester.pumpWidget(app(s, const Scaffold(body: DevicesPage(active: true))));
      await tester.pump();
      expect(find.byKey(const ValueKey('demo-entry')), findsOneWidget);
      expect(find.text('No device? Try a demo unit'), findsOneWidget);
      await tester.runAsync(s.dispose);
    });

    testWidgets('still shown when real units are found', (tester) async {
      final s = await makeServices(tester);
      await tester.pumpWidget(app(s, const Scaffold(body: DevicesPage(active: true))));
      ble.emitScan(const [
        DiscoveredDevice(
            id: 'AA:BB:CC:DD:EE:01', name: 'RCE-CarBatt', rssi: -60, isVendor: true),
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.text('RCE-CarBatt'), findsOneWidget);
      expect(find.byKey(const ValueKey('demo-entry')), findsOneWidget);
      await tester.runAsync(s.dispose);
    });

    testWidgets('opens the picker with both units', (tester) async {
      final s = await makeServices(tester);
      await tester.pumpWidget(app(s, const Scaffold(body: DevicesPage(active: true))));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('demo-entry')));
      await tester.pumpAndSettle();
      expect(find.text('Choose a demo unit'), findsOneWidget);
      expect(find.byKey(ValueKey('demo-pick-${DemoKind.battery.id}')),
          findsOneWidget);
      expect(find.byKey(ValueKey('demo-pick-${DemoKind.capacitor.id}')),
          findsOneWidget);
      await tester.runAsync(s.dispose);
    });
  });

  testWidgets('picking a demo unit connects it and opens its page',
      (tester) async {
    final s = await makeServices(tester);
    await tester.pumpWidget(app(s, const Scaffold(body: DevicesPage(active: true))));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('demo-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('demo-pick-${DemoKind.battery.id}')));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ble.connectedId, DemoKind.battery.id);
    expect(find.byType(DeviceDetailPage), findsOneWidget);
    expect(find.text('Demo battery'), findsWidgets);
    expect(find.byKey(const ValueKey('demo-banner')), findsOneWidget);
    await tester.runAsync(s.dispose);
  });

  testWidgets('Bluetooth off does not stop the demo from opening',
      (tester) async {
    final s = await makeServices(tester);
    ble.scanFails = true; // the simulator / a reviewer with the radio off
    await tester.pumpWidget(app(s, const Scaffold(body: DevicesPage(active: true))));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(s.connection.lastErrorFor('AA:BB:CC:DD:EE:01'), 'bluetooth_off',
        reason: 'precondition: a real unit does see the radio error');
    expect(s.connection.lastErrorFor(DemoKind.battery.id), isNull);
    await tester.tap(find.byKey(const ValueKey('demo-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('demo-pick-${DemoKind.battery.id}')));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(DeviceDetailPage), findsOneWidget);
    await tester.runAsync(s.dispose);
  });

  group('banner', () {
    testWidgets('up while a demo unit is linked, and ends it', (tester) async {
      final s = await makeServices(tester);
      await tester.pumpWidget(app(s, const Scaffold(body: Text('page'))));
      expect(find.byKey(const ValueKey('demo-banner')), findsNothing);

      await tester.runAsync(() => s.connection.connect(DemoKind.battery.id));
      await tester.pump();
      expect(find.byKey(const ValueKey('demo-banner')), findsOneWidget);
      expect(find.text('Demo mode · simulated data, no device connected'),
          findsOneWidget);
      expect(find.text('page'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('demo-end')));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(find.byKey(const ValueKey('demo-banner')), findsNothing);
      await tester.runAsync(s.dispose);
    });

    testWidgets('not shown for a real unit', (tester) async {
      final s = await makeServices(tester);
      await tester.pumpWidget(app(s, const Scaffold(body: Text('page'))));
      await tester.runAsync(() => s.connection.connect('AA:BB:CC:DD:EE:01'));
      await tester.pump();
      expect(find.byKey(const ValueKey('demo-banner')), findsNothing);
      await tester.runAsync(s.dispose);
    });

    testWidgets('fits at 1.5x text in Chinese', (tester) async {
      final s = await makeServices(tester);
      tester.view.physicalSize = const Size(375 * 3, 667 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: app(s, const Scaffold(body: Text('page')), locale: 'zh'),
      ));
      await tester.runAsync(() => s.connection.connect(DemoKind.capacitor.id));
      await tester.pump();
      expect(find.text('示範模式 · 資料為模擬，未連線任何裝置'), findsOneWidget);
      expect(find.text('結束示範'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'no overflow');
      await tester.runAsync(s.dispose);
    });
  });

  group('names and saving', () {
    testWidgets('a demo unit is named in the app language', (tester) async {
      final s = await makeServices(tester);
      late AppLocalizations zh;
      await tester.pumpWidget(app(
          s,
          Builder(builder: (c) {
            zh = AppLocalizations.of(c);
            return const SizedBox();
          }),
          locale: 'zh'));
      expect(demoDisplayName(zh, DemoKind.battery.id), '示範電池');
      expect(demoDisplayName(zh, DemoKind.capacitor.id), '示範電容');
      expect(demoDisplayName(zh, 'AA:BB:CC:DD:EE:01'), isNull);
      expect(deviceLabelFor(s.devices, DemoKind.battery.id, l10n: zh), '示範電池');
      expect(deviceLabelFor(s.devices, DemoKind.battery.id), 'Demo Battery',
          reason: 'no hash suffix: there is no unit to identify');
      await tester.runAsync(s.dispose);
    });

    testWidgets('no save prompt for a demo unit', (tester) async {
      final s = await makeServices(tester);
      late BuildContext ctx;
      await tester.pumpWidget(app(s, Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      late bool saved;
      await tester.runAsync(() async {
        saved = await promptAndSaveDevice(ctx, DemoKind.battery.id);
      });
      await tester.pump();
      expect(saved, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.runAsync(s.dispose);
    });
  });
}
