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
import 'dart:async';

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
///
/// [emit] pushes a telemetry snapshot through the same stream the real service
/// uses, so a test can drive the readouts without a device.
class _FakeBleService extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  void emit(TelemetrySample s) => _telemetryOut.add(s);

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
  });

  /// Build the full controller graph over an in-memory DB (real IO → runAsync).
  late _FakeBleService fakeBle;

  Future<AppServices> makeServices(WidgetTester tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      fakeBle = _FakeBleService();
      services = await AppServices.create(
        appDatabase: appDb,
        ble: fakeBle,
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
      expect(find.text('Restore Power'), findsNothing);
      expect(find.text('Anti-theft'), findsNothing);
    });

    testWidgets('BatteryControls shows 復電 but not 檢測電容',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());

      expect(find.text('Restore Power'), findsOneWidget);
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
      expect(find.text('Restore Power'), findsNothing);
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
      expect(find.text('Restore Power'), findsOneWidget);
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
      expect(find.text('Restore Power'), findsOneWidget);
      expect(find.text('Anti-theft'), findsNothing);
    });
  });

  group('advisory note is class-specific (design 0007)', () {
    // It used to be ONE string saying "this unit is detected as a
    // Supercapacitor", rendered under all three control sets — so a battery
    // owner was told their battery was a capacitor.
    testWidgets('a battery is never told it is a capacitor', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());

      expect(find.textContaining('smart battery'), findsOneWidget);
      expect(find.textContaining('super-capacitor'), findsNothing);
    });

    testWidgets('a capacitor says capacitor', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());

      expect(find.textContaining('super-capacitor'), findsOneWidget);
    });

    testWidgets('an unclassified pack says so instead of naming a class',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const PackControls());

      expect(find.textContaining('not recognised yet'), findsOneWidget);
      expect(find.textContaining('super-capacitor'), findsNothing);
      expect(find.textContaining('smart battery'), findsNothing);
    });
  });

  group('capacitor current readout (design 0007)', () {
    testWidgets('hidden on a capacitor even when a 0.0 A register arrives',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      // The field unit: device-type 0x17 plus the 0x2E register pinned at 0.0 A.
      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await pumpUnder(tester, s, const PackView());
      await tester.runAsync(() async {
        fakeBle.emit(TelemetrySample(timestamp: DateTime.now(), current: 0.0));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(find.byType(CapacitorView), findsOneWidget);
      // A capacitor cannot measure current; a permanent 0.0 A would be a lie.
      expect(find.text('MAIN CURRENT'), findsNothing);
    });

    testWidgets('still shown for a battery streaming the same register',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await pumpUnder(tester, s, const PackView());
      await tester.runAsync(() async {
        fakeBle.emit(TelemetrySample(timestamp: DateTime.now(), current: 1.5));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(find.byType(BatteryView), findsOneWidget);
      // Same register, different class → shown here, hidden on the capacitor.
      expect(find.text('MAIN CURRENT'), findsOneWidget);
    });
  });
}
