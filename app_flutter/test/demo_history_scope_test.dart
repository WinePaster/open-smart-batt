// design 0097 review (2026-11-05) — the History screen with a saved unit AND a
// demo unit's rows. Harness copied from `history_device_menu_test.dart`.
//
// The device options are sorted named-first by the saved-device rank; a demo
// unit has a name but is never saved, so the rank lookup threw and the screen
// showed 「讀取歷史失敗：Null check operator used on a null value」 for the
// whole demo session — but only for someone who also has a saved unit with
// history, which is why the reviewer path (nothing saved) never showed it.
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
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:open_smart_batt/demo/demo.dart';

/// BleService stub: nothing here reaches the plugin channel.
class _StubBle extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;
  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
  @override
  String? get connectedDeviceId => null;

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  const cap = 'DEV-CAP';
  const bank = 'DEV-PB';

  // Long enough to ellipsise in the narrow case, which is where a menu that
  // sizes itself to its widest child would have grown out of the card.
  const capName = '車庫那台超級電容模組';
  const bankName = '行動電源';

  late AppServices services;

  Future<void> boot(WidgetTester tester) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      services = await AppServices.create(appDatabase: db, ble: _StubBle());
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(services.dispose);
    });
  }

  /// Two named units with history, [bankName] the more recently seen — so the
  /// screen opens on it and [capName] is the one waiting in the menu.
  Future<void> seed(WidgetTester tester) async {
    final now = DateTime.now();
    await tester.runAsync(() async {
      await services.devices.save(SavedDevice(
        id: cap,
        alias: capName,
        lastSeen: now.subtract(const Duration(days: 2)),
      ));
      await services.devices
          .save(SavedDevice(id: bank, alias: bankName, lastSeen: now));
      await services.historyRepo.insertSample(
        TelemetrySample(
            timestamp: now.subtract(const Duration(minutes: 5)), pvlt: 13.5),
        deviceId: cap,
      );
      await services.historyRepo.insertSample(
        TelemetrySample(
            timestamp: now.subtract(const Duration(minutes: 4)), pvlt: 3.9),
        deviceId: bank,
      );
    });
  }

  Future<void> pumpHistory(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppServices>.value(value: services),
          Provider<BleService>.value(value: services.ble),
          ChangeNotifierProvider<SettingsController>.value(
              value: services.settings),
          ChangeNotifierProvider<DeviceController>.value(
              value: services.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: services.connection),
          ChangeNotifierProvider<TelemetryController>.value(
              value: services.telemetry),
          ChangeNotifierProvider<GForceController>.value(
              value: services.gforce),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const Scaffold(body: HistoryScreen()),
        ),
      ),
    );
    // Two chained reads — the option list, then the data for whichever unit
    // that list caused to be selected. Both need the real event loop.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    await tester.pump();
  }


  testWidgets('saved unit + demo rows: history opens', (t) async {
    await boot(t);
    await seed(t);
    await t.runAsync(() async {
      await services.historyRepo.insertSamples(
          demoHistorySeed(DemoKind.battery, DateTime.now()).take(3).toList());
    });
    await pumpHistory(t);
    expect(t.takeException(), isNull);
    // design 0097 review: a demo unit has a NAME but no saved record, and the
    // option sort used to index the saved-device rank with it.
    expect(find.textContaining('Null check'), findsNothing);
    expect(find.byType(MenuAnchor), findsOneWidget,
        reason: 'the device picker must render');
  });
  testWidgets('control: saved units only', (t) async {
    await boot(t);
    await seed(t);
    await pumpHistory(t);
    expect(find.byType(MenuAnchor), findsOneWidget);
  });
}
