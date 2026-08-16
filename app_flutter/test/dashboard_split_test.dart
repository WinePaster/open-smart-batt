// Widget tests for the per-class control split + pack-shell body selection.
//
//   * controls-subset: CapacitorControls shows ONLY 檢測電容; BatteryControls
//     shows 復電 and NOT 檢測電容. A capacitor has no run mode, so it must never
//     be handed a cut-off control; a battery has no capacitor to self-check.
//   * pack-shell body: PackView picks CapacitorView / BatteryView by the
//     COSMETIC label, and the bounded fallback (union minus anti-theft) while
//     still unclassified. All three render the SAME shell — the label chooses
//     controls, never layout.
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
    // A TALL surface. The pack shell is a ListView, so it builds only what
    // fits — and since design 0051 the drawn face carries the trend chart,
    // which pushes the control card past the bottom of the default 800x600.
    // "the controls are absent" would then pass by never building them.
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: s.settings),
          ChangeNotifierProvider<DeviceController>.value(value: s.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: s.connection),
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
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
    // design 0065: the pack shell now ends with the embedded history block,
    // which fires its three queries on mount. Real database IO cannot settle
    // under the widget tester's fake clock, so it is drained here — otherwise
    // every test in this file ends holding a pending timer.
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
  }

  group('controls subset — each body shows only what its class has', () {
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

  group('pack-shell body chosen by cosmetic label (gating, not routing)', () {
    testWidgets('super-capacitor label → CapacitorView', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));

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
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));

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
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));

      expect(find.byType(CapacitorView), findsNothing);
      expect(find.byType(BatteryView), findsNothing);
      // Union of pack controls EXCEPT anti-theft — the bounded fallback.
      expect(find.text('Check Capacitor'), findsOneWidget);
      expect(find.text('Restore Power'), findsOneWidget);
      expect(find.text('Anti-theft'), findsNothing);
    });
  });

  // REWRITTEN 2026-08-04 (design 0034 §5.4 ruling, Phase 2). This group used
  // to assert that each body renders its own permanent "this unit is a …"
  // note, and those three notes have now been removed — they fired on every
  // render and told the owner nothing they could act on.
  //
  // Rewritten rather than deleted, because the bug the group was built for is
  // still reachable. Before the notes were split per class there was ONE
  // string saying "this unit is detected as a Supercapacitor", rendered under
  // all three control sets, so a battery owner was told their battery was a
  // capacitor. Deleting the copy removes today's instance of that bug; it does
  // not remove the way back to it, since the next line of copy added to a
  // shared helper lands in all three bodies again.
  //
  // So the assertion is INVERTED: a body must never render the other class's
  // vocabulary. That holds now (nothing names a class at all) and keeps
  // holding the day any class-specific copy returns — which is the protection
  // the original tests were really providing.
  group('no control body speaks another class\'s vocabulary', () {
    testWidgets('a battery body never says capacitor', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());

      // The body did render — otherwise "no capacitor text" would be vacuous.
      expect(find.text('Restore Power'), findsOneWidget);
      // Nothing capacitor-flavoured, in any casing: this body has no capacitor
      // control and no capacitor status to report.
      expect(find.textContaining(RegExp('capacitor', caseSensitive: false)),
          findsNothing);
    });

    testWidgets('a capacitor body never says battery', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());

      expect(find.text('Check Capacitor'), findsOneWidget);
      expect(find.textContaining(RegExp('battery', caseSensitive: false)),
          findsNothing);
    });

    testWidgets('the unclassified fallback claims neither class',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const PackControls());

      // This body legitimately OFFERS both classes' controls — that is what
      // "bounded union" means — so the check here is narrower: it may hand you
      // a capacitor button, but it may never assert which class the unit is.
      expect(find.text('Check Capacitor'), findsOneWidget);
      expect(find.text('Restore Power'), findsOneWidget);
      expect(
          find.textContaining(
              RegExp('super-capacitor|smart battery', caseSensitive: false)),
          findsNothing);
      expect(find.textContaining('This unit is'), findsNothing);
    });
  });

  group('capacitor current readout is class-gated, not data-driven', () {
    testWidgets('hidden on a capacitor even when a 0.0 A register arrives',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      // The field unit: device-type 0x17 plus the 0x2E register pinned at 0.0 A.
      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));
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
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));
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
