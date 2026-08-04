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
// Updated for design 0037: the current READOUT now shows the MAGNITUDE plus a
// charge/discharge badge (the ±0.05 A dead-band shows the number but names no
// state); the signed, zero-spanning chart TRACK is untouched (bottom test).
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
import 'package:open_smart_batt/ui/dashboard/readout_grid.dart';
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

      // Magnitude only (design 0037 supersedes FB-47's signed readout): the
      // badge carries the direction, the number does not. The chart track keeps
      // its sign — that is the bottom test, and it must stay.
      expect(find.text('0.43 A'), findsOneWidget);
      expect(find.text('-0.43 A'), findsNothing);

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
  group('idle (|current| below the ±0.05 deadband, design 0037)', () {
    testWidgets('a flat zero shows the magnitude but names NO state',
        (tester) async {
      await pumpBank(tester, current: 0.0);

      // Design 0037: inside the band there is no direction to name, so the
      // badge drops — but the reading itself still shows.
      expect(find.text('CHARGING'), findsNothing);
      expect(find.text('DISCHARGING'), findsNothing);
      expect(find.text('0.00 A'), findsOneWidget);
      expect(iconCount(tester, Icons.pause_circle_outline), 3);
      expect(iconCount(tester, Icons.battery_charging_full), 0);
      expect(find.text('OUTPUT VOLTAGE'), findsOneWidget);
    });

    testWidgets('a non-zero draw inside the band shows its magnitude, no badge',
        (tester) async {
      // 30 mA — real, but below the ±0.05 direction threshold. The user asked
      // that this still display the number (just without a charge/discharge
      // state).
      await pumpBank(tester, current: 0.03);

      expect(find.text('0.03 A'), findsOneWidget);
      expect(find.text('CHARGING'), findsNothing);
      expect(find.text('DISCHARGING'), findsNothing);
    });

    testWidgets('a 2 mA trickle shows 0.00 (absolute), NOT -0.00', (tester) async {
      // current == -0.002. The old signed path read "-0.00"; the absolute
      // value removes the sign entirely.
      await pumpBank(tester, current: -0.002);

      expect(find.text('0.00 A'), findsOneWidget);
      expect(find.text('-0.00 A'), findsNothing);
      expect(find.text('CHARGING'), findsNothing);
    });

    testWidgets('just past ±0.05 is a direction, shown as magnitude + badge',
        (tester) async {
      await pumpBank(tester, current: -0.06);

      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('0.06 A'), findsOneWidget);
      expect(find.text('-0.06 A'), findsNothing);
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

  // =========================================================================
  // Readout order (design 0037): SOC, temp, output voltage, current, cell V,
  // [capacity]. Classified by icon/unit so l10n wording can change freely.
  // =========================================================================
  testWidgets('readout tiles are in the design-0037 order', (tester) async {
    await pumpBank(tester, current: 1.2); // pumpBank registers its own teardown
    final card = tester.widget<ReadoutsCard>(find.byType(ReadoutsCard));

    String kind(Readout r) {
      if (r.unit == '%') return 'soc';
      if (r.unit == 'A') return 'current';
      if (r.icon == Icons.thermostat) return 'temp';
      if (r.icon == Icons.usb) return 'svlt';
      if (r.icon == Icons.battery_5_bar) return 'cell';
      return 'other';
    }

    // designCapacityMah is unset in this snapshot, so the capacity tile is
    // absent; the surviving five must still be in order.
    expect(card.items.map(kind).toList(),
        ['soc', 'temp', 'svlt', 'current', 'cell']);
  });
}
