// design 0035 Phase 1 — the energy-path row on screen.
//
// One line, three segments (direction → port → readings), driven from ONE
// sample so the port shown cannot disagree with the direction shown (§4.5). The
// invariants pinned here are the ones the design calls out as the easy mistakes:
//
//   * the port is Type-C (b7 bit1) or "path undetermined" — NEVER Type-A, and
//     never inferred from bit0 (§4.3, Q10(a));
//   * "PD" is positive-only, from bit3 (input) / bit5 (output), never crossed
//     and never negated into a "standard"/"non-PD" label (§4.4);
//   * b7 == 0x00 is standby (rail off), decided BEFORE any port test (§4.3);
//   * the §4.8 hook shows ONLY on the "path undetermined" row while energy is
//     moving, is dismissible, and changes no display decision.
//
// The exhaustive T1–T13 wording table is Phase 3; this file is the Phase-1
// pump-the-vectors guard that the row builds and decides correctly.
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
import 'package:open_smart_batt/ui/dashboard/power_path_row.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService that can push one telemetry snapshot.
class _FakeBleService extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  @override
  String? get connectedDeviceId => 'DEV-A';

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
  setUpAll(sqfliteFfiInit);

  late _FakeBleService ble;

  Future<AppServices> makeServices(WidgetTester tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _FakeBleService();
      services = await AppServices.create(appDatabase: appDb, ble: ble);
      await services.devices.saveNew('DEV-A', 'unit A');
    });
    return services;
  }

  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => s.pending.drain());
    await s.dispose();
  }

  /// Pump the row alone with one snapshot already applied.
  ///
  /// [portFlagsRaw] null means "0x4B has not arrived" — the waiting case, which
  /// must stay distinct from a decoded zero. [cls] lets the non-power-bank guard
  /// be exercised (T10).
  Future<AppServices> pumpRow(
    WidgetTester tester, {
    int? portFlagsRaw,
    double? current,
    double? svlt,
    ProductClass cls = ProductClass.powerBank,
    bool emitSample = true,
  }) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    s.connection.setPackLabelOverride(cls);
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppServices>.value(value: s),
          Provider<BleService>.value(value: s.ble),
          Provider<HistoryRepo>.value(value: s.historyRepo),
          Provider<DeviceRepo>.value(value: s.deviceRepo),
          Provider<SettingsRepo>.value(value: s.settingsRepo),
          Provider<LogRepo>.value(value: s.logRepo),
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
          home: const Scaffold(body: PowerPathRow()),
        ),
      ),
    );
    await tester.pump();
    if (emitSample) {
      // No device-type byte: the class is set by [setPackLabelOverride] above,
      // so the wire cannot override the non-power-bank case (T10) out from under
      // the test. The row reads the class from the connection, not the sample.
      ble.emit(TelemetrySample(
        timestamp: DateTime(2026, 8, 4, 14, 43),
        pvlt: 3.95,
        svlt: svlt,
        current: current,
        portFlagsRaw: portFlagsRaw,
      ));
      await tester.pump();
      await tester.pump();
    }
    return s;
  }

  // =========================================================================
  // §3.3 ground-truth vectors — the port ladder
  // =========================================================================
  group('§3.3 port ladder', () {
    testWidgets('0x0a (bit1+bit3) charging: Type-C + PD, never Type-A',
        (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x0a, current: -0.42, svlt: 9.14);

      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('Type-C'), findsOneWidget);
      expect(find.text('PD'), findsOneWidget);
      expect(find.text('9.14 V'), findsOneWidget);
      expect(find.text('0.42 A'), findsOneWidget);
      // Q10(a): no Type-A anywhere, and this is not "undetermined".
      expect(find.text('Type-A'), findsNothing);
      expect(find.text('Path undetermined'), findsNothing);
    });

    testWidgets('0x05 (bit0+bit2, bit1 clear): path undetermined, never Type-A',
        (tester) async {
      // A real discharge current (> dead-band) so the direction is unambiguous;
      // the point is the PORT, which bit1-clear leaves undetermined.
      await pumpRow(tester, portFlagsRaw: 0x05, current: 0.42, svlt: 5.12);

      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('Path undetermined'), findsOneWidget);
      // bit0 is set here and MUST NOT produce a Type-A label (§4.3 / §3.3 #2).
      expect(find.text('Type-A'), findsNothing);
      expect(find.text('Type-C'), findsNothing);
    });

    testWidgets('0x00: standby (rail off), decided before any port test',
        (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x00, current: -0.03, svlt: 3.95);

      expect(find.text('Standby · output off'), findsOneWidget);
      expect(find.text('Type-C'), findsNothing);
      expect(find.text('Path undetermined'), findsNothing);
      expect(find.text('Type-A'), findsNothing);
    });

    testWidgets('0x03 (bit0+bit1): bit1 wins → Type-C, never Type-A',
        (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x03, current: -0.30, svlt: 9.0);

      expect(find.text('Type-C'), findsOneWidget);
      expect(find.text('Type-A'), findsNothing);
      expect(find.text('Path undetermined'), findsNothing);
    });

    testWidgets('0x12 (bit1+bit4): Type-C, and bit4 needs no special case',
        (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x12, current: -0.30, svlt: 9.0);

      expect(find.text('Type-C'), findsOneWidget);
      // bit3 is clear here → no PD, and NO negative label (§4.4).
      expect(find.text('PD'), findsNothing);
    });
  });

  // =========================================================================
  // §4.4 — PD is positive-only and never crossed
  // =========================================================================
  group('§4.4 PD badge', () {
    testWidgets('bit3 clear while charging shows no PD and no negative label',
        (tester) async {
      // 0x02 = bit1 only. Charging, but bit3 clear.
      await pumpRow(tester, portFlagsRaw: 0x02, current: -0.42, svlt: 9.0);

      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('PD'), findsNothing);
      // We never fabricate the negative claim.
      for (final s in ['non-PD', 'Non-PD', 'standard', 'Standard', '一般']) {
        expect(find.text(s), findsNothing);
      }
    });

    testWidgets('charging reads bit3 only — bit5 set must NOT cross to PD',
        (tester) async {
      // 0x22 = bit1 + bit5 (output-PD). While CHARGING we look at bit3 (clear).
      await pumpRow(tester, portFlagsRaw: 0x22, current: -0.42, svlt: 9.0);

      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('PD'), findsNothing);
    });

    testWidgets('discharging reads bit5 → PD from output', (tester) async {
      // 0x22 = bit1 + bit5. Discharging, so bit5 is the one that counts.
      await pumpRow(tester, portFlagsRaw: 0x22, current: 1.2, svlt: 5.1);

      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('PD'), findsOneWidget);
    });
  });

  // =========================================================================
  // waiting / non-power-bank
  // =========================================================================
  group('waiting and gating', () {
    testWidgets('0x4B not yet arrived: waiting, not a decoded zero',
        (tester) async {
      await pumpRow(tester, portFlagsRaw: null, current: -0.42, svlt: 9.0);

      expect(find.textContaining('Waiting for device'), findsOneWidget);
      expect(find.text('0.42 A'), findsNothing);
      expect(find.text('Path undetermined'), findsNothing);
    });

    testWidgets('non-power-bank renders nothing (T10)', (tester) async {
      await pumpRow(tester,
          portFlagsRaw: 0x0a,
          current: -0.42,
          svlt: 9.0,
          cls: ProductClass.smartBattery);

      expect(find.byType(PowerPathRow), findsOneWidget);
      // The card heading is the tell that the row drew anything at all.
      expect(find.text('Energy Path'), findsNothing);
      expect(find.text('CHARGING'), findsNothing);
    });
  });

  // =========================================================================
  // §4.8 — the feedback hook, only where we truly do not know the port
  // =========================================================================
  group('§4.8 feedback hook', () {
    testWidgets('appears on the undetermined row and records a tag once',
        (tester) async {
      final s = await pumpRow(tester, portFlagsRaw: 0x05, current: 0.42, svlt: 5.1);

      final hook = find.text('Which port is this?');
      expect(hook, findsOneWidget);

      await tester.tap(hook);
      await tester.pumpAndSettle();
      // The chooser offers the three tags.
      expect(find.text('Type-A'), findsOneWidget);
      expect(find.text('Other / not sure'), findsWidgets);

      await tester.tap(find.text('Type-A').last);
      await tester.pumpAndSettle();

      // Handled once: the affordance is gone for this connection (non-nagging).
      expect(find.text('Which port is this?'), findsNothing);

      // The tag rides the design 0029 event channel, which writes to the log DB
      // (real async) — drain it, then run out the SnackBar's dismiss timer, so
      // neither outlives the widget tree.
      await tester.runAsync(() => s.pending.drain());
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });

    testWidgets('never shown for a known Type-C port', (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x0a, current: -0.42, svlt: 9.14);
      expect(find.text('Which port is this?'), findsNothing);
    });

    testWidgets('never shown in standby', (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x00, current: -0.03, svlt: 3.95);
      expect(find.text('Which port is this?'), findsNothing);
    });
  });
}
