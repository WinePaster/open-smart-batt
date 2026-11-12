// design 0103 phase 3 — the home grid with two units live on SECONDARY links.
//
// The UI half of FB-41: each card must draw its own link's reading, under its
// own name.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/home/home_page.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePrimary extends BleService {
  /// A scan that has already found both units: since 2026.11.12/004 only a
  /// unit seen in range is adopted as a secondary.
  @override
  Stream<List<DiscoveredDevice>> get scanResults =>
      Stream<List<DiscoveredDevice>>.value(const [
        DiscoveredDevice(id: 'A', name: 'A', rssi: -60),
        DiscoveredDevice(id: 'B', name: 'B', rssi: -60),
      ]);
  @override
  String? get connectedDeviceId => null;
  @override
  Stream<BleLinkState> get linkState => const Stream<BleLinkState>.empty();
  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
}

class _FakeSecondary extends BleService {
  _FakeSecondary(this.all) {
    all.add(this);
  }
  final List<_FakeSecondary> all;
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _teleOut = StreamController<TelemetrySample>.broadcast();
  String? id;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<TelemetrySample> get telemetry => _teleOut.stream;
  @override
  Stream<BlePacketEvent> get packets => const Stream<BlePacketEvent>.empty();
  @override
  Stream<String> get diagnostics => const Stream<String>.empty();

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    id = deviceId;
    _linkOut.add(BleLinkState.ready);
  }

  @override
  Future<void> disconnect() async => _linkOut.add(BleLinkState.disconnected);

  void sample(double pvlt) => _teleOut
      .add(TelemetrySample(timestamp: DateTime.now(), pvlt: pvlt, deviceId: id));

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _teleOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  testWidgets('each secondary-live card draws its own link, under its own name',
      (tester) async {
    final markers = Directory.systemTemp.createTempSync('osb_ml_ui');
    AckMarker.debugDirectoryOverride = markers;
    final secs = <_FakeSecondary>[];
    late AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      s = await AppServices.create(
        appDatabase: db,
        ble: _FakePrimary(),
        multiLinkBuild: true,
        multiLinkBleFactory: () => _FakeSecondary(secs),
      );
      for (final d in [
        const SavedDevice(
            id: 'A', alias: 'Bat A', productClass: ProductClass.smartBattery),
        const SavedDevice(
            id: 'B', alias: 'Bat B', productClass: ProductClass.smartBattery),
      ]) {
        await s.devices.save(d);
      }
      await s.multiLink!.setEnabled(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      secs.firstWhere((b) => b.id == 'A').sample(13.25);
      secs.firstWhere((b) => b.id == 'B').sample(12.20);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

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
          ChangeNotifierProvider<MultiLinkController>.value(
              value: s.multiLink!),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const Scaffold(body: HomePage()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Bat A'), findsWidgets);
    expect(find.text('Bat B'), findsWidgets);
    expect(find.text('13.25'), findsWidgets, reason: "A's link");
    expect(find.text('12.20'), findsWidgets, reason: "B's link");
    expect(find.text('LIVE'), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await s.pending.drain();
      await s.dispose();
    });
    AckMarker.debugDirectoryOverride = null;
    markers.deleteSync(recursive: true);
  });
}
