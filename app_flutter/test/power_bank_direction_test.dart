// FB-47 — the power-bank page has to SAY which way the energy is going.
//
// Since FB-46 `current` is signed (design 0030: discharge positive, charge
// negative). The sign alone was not enough: a 9.15 V PD charge drew `-0.43 A`
// under a hardwired charging icon and a readout labelled "Output Voltage", and
// the owner who ruled on the sign convention read his own device as broken
// (`feedback-analysis/2026.08.04-002.md`).
//
// What is pinned here is the CONTRACT, not the styling: for each of the three
// directions, what the page says in words, which glyph it draws, and — for the
// two cases where saying nothing is the honest answer — that it says nothing.
//
// NOT pinned, deliberately: the signed, zero-spanning current TRACK. A sign
// flip mid-window is how a start-up load is recognised, so that axis stays as
// it is whatever the instantaneous direction is; the test at the bottom is
// there to stop a future "make the chart consistent too" from removing it.
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
import 'package:open_smart_batt/ui/dashboard/power_bank_view.dart';
import 'package:open_smart_batt/ui/dashboard/readouts_card.dart';
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

  /// Render the page with one telemetry snapshot already applied.
  ///
  /// [current] null means "no reading has arrived" — the direction-unknown
  /// case, which is a separate branch from idle and must not be conflated with
  /// a zero.
  Future<AppServices> pumpBank(
    WidgetTester tester, {
    required double? current,
    String locale = 'en',
  }) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    // Tall surface: the page is a ListView, and a card that is never built
    // cannot fail an assertion about what it says.
    tester.view.physicalSize = const Size(900, 3000);
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
          locale: Locale(locale),
          home: const Scaffold(body: PowerBankView()),
        ),
      ),
    );
    await tester.pump();
    ble.emit(TelemetrySample(
      timestamp: DateTime(2026, 8, 4, 14, 43),
      deviceType: 0x22,
      pvlt: 3.95,
      svlt: 9.15,
      temperatureC: 31,
      socPercent: 64,
      current: current,
    ));
    await tester.pump();
    await tester.pump();
    return s;
  }

  /// How many tiles/chips draw [icon] right now.
  int iconCount(WidgetTester tester, IconData icon) =>
      tester.widgetList(find.byIcon(icon)).length;

  // =========================================================================
  // Charging — the case that produced the report
  // =========================================================================
  group('charging (current < 0)', () {
    testWidgets('says CHARGING, keeps the minus, relabels 0x37 as input',
        (tester) async {
      await pumpBank(tester, current: -0.43);

      // The word. Without it the minus sign is the whole explanation, which is
      // precisely what was not enough.
      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('DISCHARGING'), findsNothing);
      expect(find.text('IDLE'), findsNothing);

      // The sign SURVIVES. design 0030 is not renegotiated by this fix — the
      // badge explains the number, it does not replace it.
      expect(find.text('-0.43 A'), findsOneWidget);
      expect(find.text('0.43 A'), findsNothing);

      // 0x37 reads the port-side voltage: 9.15 V here is what is coming IN.
      expect(find.text('INPUT VOLTAGE'), findsOneWidget);
      expect(find.text('OUTPUT VOLTAGE'), findsNothing);

      // Charging is the one direction for which the old hardwired glyph was
      // right, so it stays — on the type chip, the SOC tile and the current
      // tile alike.
      expect(iconCount(tester, Icons.battery_charging_full), 3);
      expect(iconCount(tester, Icons.bolt), 0);
      expect(iconCount(tester, Icons.pause_circle_outline), 0);
    });

    testWidgets('zh-Hant says 充電中 / 輸入電壓', (tester) async {
      await pumpBank(tester, current: -0.43, locale: 'zh');

      expect(find.text('充電中'), findsOneWidget);
      expect(find.text('輸入電壓'), findsOneWidget);
      expect(find.text('輸出電壓'), findsNothing);
    });
  });

  // =========================================================================
  // Discharging — the direction that used to draw a charging icon
  // =========================================================================
  group('discharging (current > 0)', () {
    testWidgets('says DISCHARGING and stops drawing a charging battery',
        (tester) async {
      await pumpBank(tester, current: 1.2);

      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('CHARGING'), findsNothing);
      expect(find.text('1.20 A'), findsOneWidget);

      // Symptom 1 of FB-47, pinned: NOTHING on this page may show a charging
      // battery while the bank is being drained.
      expect(iconCount(tester, Icons.battery_charging_full), 0);
      expect(iconCount(tester, Icons.bolt), 3);

      // Output really is output here, so the original wording is correct and
      // must not be "fixed" too.
      expect(find.text('OUTPUT VOLTAGE'), findsOneWidget);
      expect(find.text('INPUT VOLTAGE'), findsNothing);
    });

    testWidgets('zh-Hant says 放電中 and keeps 輸出電壓', (tester) async {
      await pumpBank(tester, current: 1.2, locale: 'zh');

      expect(find.text('放電中'), findsOneWidget);
      expect(find.text('輸出電壓'), findsOneWidget);
      expect(find.text('輸入電壓'), findsNothing);
    });
  });

  // =========================================================================
  // Idle — and the -0.00 that started it
  // =========================================================================
  group('idle (|current| below the deadband)', () {
    testWidgets('a flat zero says IDLE, with neither arrow nor bolt',
        (tester) async {
      await pumpBank(tester, current: 0.0);

      expect(find.text('IDLE'), findsOneWidget);
      expect(find.text('0.00 A'), findsOneWidget);
      expect(iconCount(tester, Icons.pause_circle_outline), 3);
      expect(iconCount(tester, Icons.battery_charging_full), 0);
      expect(find.text('OUTPUT VOLTAGE'), findsOneWidget);
    });

    testWidgets('a 2 mA trickle shows 0.00, NOT -0.00', (tester) async {
      // charge 2 mA, discharge 0 → current == -0.002. Straight through
      // toStringAsFixed(2) this reads "-0.00": a minus sign on a zero, which
      // is a number no device ever reported.
      await pumpBank(tester, current: -0.002);

      expect(find.text('0.00 A'), findsOneWidget);
      expect(find.text('-0.00 A'), findsNothing);
      // 2 mA is noise, not a direction — it must not claim to be charging.
      expect(find.text('IDLE'), findsOneWidget);
      expect(find.text('CHARGING'), findsNothing);
    });

    testWidgets('just past the deadband is a direction, and rounds to a digit',
        (tester) async {
      await pumpBank(tester, current: -0.006);

      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('-0.01 A'), findsOneWidget);
    });
  });

  // =========================================================================
  // Unknown — where the honest answer is to say nothing
  // =========================================================================
  group('direction unknown (no current reading)', () {
    testWidgets('no badge, no relabel, no guess', (tester) async {
      await pumpBank(tester, current: null);

      // No current reading → no current tile at all (its own pre-existing
      // gate), and therefore no badge to be wrong.
      expect(find.text('CHARGING'), findsNothing);
      expect(find.text('DISCHARGING'), findsNothing);
      expect(find.text('IDLE'), findsNothing);
      expect(find.text('CURRENT'), findsNothing);

      // The label stays as it was. "Input" would be a guess dressed as a fix.
      expect(find.text('OUTPUT VOLTAGE'), findsOneWidget);
      expect(find.text('INPUT VOLTAGE'), findsNothing);

      // Status quo on the glyph too — two of them, the chip and the SOC tile,
      // since there is no current tile.
      expect(iconCount(tester, Icons.battery_charging_full), 2);
    });
  });

  // =========================================================================
  // The chart track this fix must NOT touch
  // =========================================================================
  testWidgets('the current track stays signed and zero-spanning while charging',
      (tester) async {
    await pumpBank(tester, current: -0.43);

    final card = tester.widget<ReadoutsCard>(find.byType(ReadoutsCard));
    final current =
        card.tracks.firstWhere((t) => t.field == TrendField.current);
    expect(current.spanZero, isTrue,
        reason: 'a sign flip mid-window is how a start-up load is read');

    // The SVLT track legend, by contrast, DOES follow the direction: it is the
    // other face of the same card, so it cannot disagree with the tile.
    final svlt = card.tracks.firstWhere((t) => t.field == TrendField.svlt);
    expect(svlt.label, 'Input voltage');
  });
}
