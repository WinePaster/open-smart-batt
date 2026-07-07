// Widget tests for design 0004 — the per-class control split + pack-shell body
// routing.
//
//   * controls-subset: CapacitorControls shows ONLY 檢測電容; BatteryControls
//     shows 解除斷電 and NOT 檢測電容 (the corrected capability matrix).
//   * pack-shell routing (option 3): PackView picks CapacitorView /
//     BatteryView by the COSMETIC label, and the bounded fallback (union minus
//     anti-theft) while still unclassified.
//
// Controllers are assembled via AppServices over an in-memory sqflite (ffi) DB
// with an inert BleService (mirrors widget_test.dart), so this runs headless.
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/pack_view.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls.dart';
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
  });

  /// Build the full controller graph over an in-memory DB (real IO → runAsync).
  Future<AppServices> makeServices(WidgetTester tester) async {
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
    return services;
  }

  /// Pump [child] under the controller providers + English localization.
  Future<void> pumpUnder(
      WidgetTester tester, AppServices s, Widget child) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: s.settings),
          ChangeNotifierProvider<DeviceController>.value(value: s.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: s.connection),
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pump();
  }

  group('controls subset (design 0004 §3.4)', () {
    testWidgets('CapacitorControls shows 檢測電容 but not 解除斷電',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());

      expect(find.text('Check Capacitor'), findsOneWidget);
      expect(find.text('Release Cut-off'), findsNothing);
      expect(find.text('Anti-theft'), findsNothing);
    });

    testWidgets('BatteryControls shows 解除斷電 but not 檢測電容',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());

      expect(find.text('Release Cut-off'), findsOneWidget);
      expect(find.text('Check Capacitor'), findsNothing);
      // Anti-theft is model-gated (no override wired) → hidden by default.
      expect(find.text('Anti-theft'), findsNothing);
    });
  });

  group('pack-shell body routing by cosmetic label (design 0004 §3.4)', () {
    testWidgets('super-capacitor label → CapacitorView', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await pumpUnder(tester, s, const PackView());

      expect(find.byType(CapacitorView), findsOneWidget);
      expect(find.byType(BatteryView), findsNothing);
      // Capacitor body → 檢測電容 only.
      expect(find.text('Check Capacitor'), findsOneWidget);
      expect(find.text('Release Cut-off'), findsNothing);
    });

    testWidgets('smart-battery label → BatteryView', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await pumpUnder(tester, s, const PackView());

      expect(find.byType(BatteryView), findsOneWidget);
      expect(find.byType(CapacitorView), findsNothing);
      expect(find.text('Release Cut-off'), findsOneWidget);
      expect(find.text('Check Capacitor'), findsNothing);
    });

    testWidgets('unclassified pack → bounded fallback (union minus anti-theft)',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      // No override, not connected → packLabel is unknown.
      await pumpUnder(tester, s, const PackView());

      expect(find.byType(CapacitorView), findsNothing);
      expect(find.byType(BatteryView), findsNothing);
      // Union of pack controls EXCEPT anti-theft (design 0004 §3.3).
      expect(find.text('Check Capacitor'), findsOneWidget);
      expect(find.text('Release Cut-off'), findsOneWidget);
      expect(find.text('Anti-theft'), findsNothing);
    });
  });
}
