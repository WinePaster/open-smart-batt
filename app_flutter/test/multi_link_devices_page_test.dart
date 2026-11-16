// feedback 2026.11.16/009 — the 裝置 tab with units live on SECONDARY links.
//
// The reporter saw one 已連線 row and concluded "only one can be connected",
// while three links were up: the saved list read the primary alone. Owner
// ruling (a): a secondary row reads 已連線 and its 中斷 lets go of that link
// only, recorded as a user disconnect so it is not adopted again.
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
import 'package:open_smart_batt/ui/devices/devices_page.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePrimary extends BleService {
  /// A scan that has already found both units: only a unit seen in range is
  /// adopted as a secondary (2026.11.12/004).
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
      Stream<BluetoothAdapterState>.value(BluetoothAdapterState.on);
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
  @override
  Future<bool> ensurePermissions() async => true;
  @override
  Future<void> startScan(
      {Duration timeout = const Duration(seconds: 8)}) async {}
  @override
  Future<void> stopScan() async {}
  int disconnects = 0;
  @override
  Future<void> disconnect() async => disconnects++;
}

class _FakeSecondary extends BleService {
  _FakeSecondary(this.all) {
    all.add(this);
  }
  final List<_FakeSecondary> all;
  final _linkOut = StreamController<BleLinkState>.broadcast();
  String? id;
  bool released = false;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();
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
  Future<void> disconnect() async {
    released = true;
    _linkOut.add(BleLinkState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  testWidgets(
      'two secondary-live rows read Connected; 中斷 on one releases only it',
      (tester) async {
    final markers = Directory.systemTemp.createTempSync('osb_ml_devices');
    AckMarker.debugDirectoryOverride = markers;
    final secs = <_FakeSecondary>[];
    final primary = _FakePrimary();
    late AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      s = await AppServices.create(
        appDatabase: db,
        ble: primary,
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
    });
    expect(s.multiLink!.isOnlineFor('A'), isTrue);
    expect(s.multiLink!.isOnlineFor('B'), isTrue);

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
          ChangeNotifierProvider<AlertController>.value(value: s.alerts),
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
          ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
          ChangeNotifierProvider<MultiLinkController>.value(
              value: s.multiLink!),
          Provider<AppServices>.value(value: s),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const Scaffold(body: DevicesPage(active: false)),
        ),
      ),
    );
    await tester.pump();

    // Before the fix: 0 Connected, two "Connect" buttons that hand over.
    expect(find.text('Connected'), findsNWidgets(2));
    expect(find.text('Disconnect'), findsNWidgets(2));

    await tester.tap(find.text('Disconnect').first);
    // The release awaits the link's teardown; let both zones run it out.
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }

    final a = secs.firstWhere((b) => b.id == 'A');
    final b = secs.firstWhere((b) => b.id == 'B');
    expect(a.released, isTrue, reason: 'the row pressed');
    expect(b.released, isFalse, reason: 'the other secondary stays');
    expect(primary.disconnects, 0, reason: 'never the primary path');
    expect(s.multiLink!.isOnlineFor('A'), isFalse);
    expect(s.multiLink!.isOnlineFor('B'), isTrue);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);

    // Not adopted again behind the user's back (PR #43's rule).
    await tester.runAsync(() async {
      s.multiLink!.presenceTick();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(s.multiLink!.isOnlineFor('A'), isFalse);
    expect(secs.where((x) => x.id == 'A'), hasLength(1),
        reason: 'no second link was opened to A');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await s.pending.drain();
      await s.dispose();
    });
    AckMarker.debugDirectoryOverride = null;
    markers.deleteSync(recursive: true);
  });
}
