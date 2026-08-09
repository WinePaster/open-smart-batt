// FB-47 / design 0037 / design 0035 Phase 2 — direction awareness on the
// power-bank page, AFTER the current + voltage readouts left the grid.
//
// Since FB-46 `current` is signed (design 0030: discharge positive, charge
// negative). The sign alone was not enough: a 9.15 V PD charge drew `-0.43 A`
// under a hardwired charging icon and a readout labelled "Output Voltage", and
// the owner who ruled on the sign convention read his own device as broken
// (`feedback-analysis/2026.08.04-002.md`).
//
// design 0037 first fixed the READOUTS (magnitude + charge/discharge badge,
// ±0.05 A dead-band). design 0035 Phase 2 (Q5+Q12) then MOVED those two
// readouts — the current tile and the "output/input voltage" tile — OFF this
// grid and onto the energy-path row, so the same number is not printed twice.
// Their per-direction wording is now pinned in `power_path_row_test.dart`.
//
// What THIS file still owns after that move:
//   * the type-chip glyph, which follows the flow (charging battery only while
//     charging — FB-47 symptom 1);
//   * the chart's SVLT track legend, which still relabels input/output by
//     direction. ⚠️ Since design 0040 the chart is its own card
//     ([TrendChartCard]) and, after that design's Q1 was reversed, it is placed
//     on the DIAGNOSTIC face only — so the tests below ask for that face
//     explicitly. It is no longer "the other face of the readouts card".
//   * the signed, zero-spanning current TRACK, deliberately NOT direction-
//     switched — a sign flip mid-window is how a start-up load is read;
//   * the surviving grid order (SOC, temp, [capacity]) and the ABSENCE of the
//     moved/removed tiles (the Q5+Q12 de-duplication guard);
//   * the DIAL's direction sub-line (2026-08-05). The dial's caption has always
//     read "SOC · State of Charge" / "電量 · 充電狀態" while the dial drew no
//     state at all — the sub-line under it was the cell voltage, which was ALSO
//     printed as a grid tile. Reported from the field on v0.7.2
//     (a 2026-08-04 owner-run controlled capture). The cell tile is gone and the
//     sub-line now carries the direction, which is why every flow-glyph count
//     below went up by exactly one.
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
import 'package:open_smart_batt/ui/dashboard/pvlt_gauge.dart';
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
  /// [face] exists because since design 0040's Q1 reversal the chart card is
  /// on the DIAGNOSTIC face only. The tests about the chart's legends have to
  /// ask for that face; everything else stays on the default, which is also the
  /// screen almost every field capture shows.
  Future<AppServices> pumpBank(
    WidgetTester tester, {
    required double? current,
    String locale = 'en',
    Watchface face = Watchface.standard,
  }) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    if (face != Watchface.standard) {
      await tester.runAsync(() =>
          s.devices.setDisplayLayout('DEV-A', DisplayLayout(watchface: face)));
    }
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
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
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

  ReadoutsCard readoutsCard(WidgetTester tester) =>
      tester.widget<ReadoutsCard>(find.byType(ReadoutsCard));

  /// The chart is its own card since design 0040 (design 0034 Phase 1), so the
  /// track list is read off [TrendChartCard], not off the readouts card it used
  /// to be a mode of.
  TrendChartCard chartCard(WidgetTester tester) =>
      tester.widget<TrendChartCard>(find.byType(TrendChartCard));

  PvltGauge gauge(WidgetTester tester) =>
      tester.widget<PvltGauge>(find.byType(PvltGauge));

  /// The SVLT chart-track legend, which still follows the direction after the
  /// voltage READOUT tile moved to the energy-path row.
  String? svltTrackLabel(WidgetTester tester) => chartCard(tester)
      .tracks
      .firstWhere((t) => t.field == TrendField.svlt)
      .label;

  String kind(Readout r) {
    if (r.unit == '%') return 'soc';
    if (r.unit == 'A') return 'current';
    if (r.icon == Icons.thermostat) return 'temp';
    if (r.icon == Icons.usb) return 'svlt';
    if (r.icon == Icons.battery_5_bar) return 'cell';
    return 'other';
  }

  // =========================================================================
  // The grid no longer carries current or voltage (design 0035 Q5+Q12).
  // These are the de-duplication guards: the two moved tiles must be ABSENT so
  // the energy-path row is the only place that number appears.
  // =========================================================================
  group('Q5+Q12 — current and voltage tiles are gone from the grid', () {
    testWidgets('no current tile and no voltage tile, either direction',
        (tester) async {
      await pumpBank(tester, current: -0.43);
      final items = readoutsCard(tester).items.map(kind).toList();
      expect(items, isNot(contains('current')),
          reason: 'the current readout now lives on the energy-path row');
      expect(items, isNot(contains('svlt')),
          reason: 'the port-voltage readout now lives on the energy-path row');
    });

    testWidgets('the moved numbers do not print as grid tiles', (tester) async {
      // The magnitude/voltage strings used to be tiles here; they must not be
      // (the energy-path row is a separate widget, tested elsewhere, and is not
      // even built in this harness — the class is not overridden to powerBank).
      await pumpBank(tester, current: -0.43);
      // No Icons.usb tile (that was the voltage readout's icon).
      expect(find.byIcon(Icons.usb), findsNothing);
    });
  });

  // =========================================================================
  // The type-chip + SOC-tile + DIAL glyph all follow the flow (FB-47 symptom
  // 1). THREE flow glyphs now: chip, SOC tile, and the dial's sub-line. They
  // read one derivation (`powerFlowOf`) and one glyph table (`_flowIcon`), so
  // the count is the assertion that they cannot drift apart.
  //
  // NB (design 0035 Phase 2): the energy-path row is now wired into this page,
  // and the class DOES resolve to power bank off the 0x22 wire byte, so the row
  // renders. With no `0x4B` in these snapshots it sits in its "waiting" state —
  // a card whose HEADING draws one extra `Icons.bolt`. That single bolt is the
  // proof the row is on the page; the flow glyphs (battery_charging_full /
  // pause_circle_outline) are the clean FB-47 signal because the row draws
  // neither of those.
  // =========================================================================
  group('the glyph follows the flow', () {
    testWidgets('charging draws the charging battery (chip + SOC tile + dial)',
        (tester) async {
      await pumpBank(tester, current: -0.43);
      expect(iconCount(tester, Icons.battery_charging_full), 3);
      // The lone bolt is the energy-path row's (waiting) heading, not a flow
      // glyph — charging draws no discharge glyph on chip or SOC tile.
      expect(iconCount(tester, Icons.bolt), 1);
      expect(iconCount(tester, Icons.pause_circle_outline), 0);
    });

    testWidgets('discharging stops drawing a charging battery', (tester) async {
      await pumpBank(tester, current: 1.2);
      // FB-47 symptom 1, pinned: NOTHING here may show a charging battery while
      // the bank is being drained.
      expect(iconCount(tester, Icons.battery_charging_full), 0);
      // chip + SOC tile + dial sub-line + the energy-path row's heading = 4.
      expect(iconCount(tester, Icons.bolt), 4);
    });

    testWidgets('idle draws neither', (tester) async {
      await pumpBank(tester, current: 0.0);
      expect(iconCount(tester, Icons.pause_circle_outline), 3);
      expect(iconCount(tester, Icons.battery_charging_full), 0);
    });

    testWidgets('no reading keeps the status-quo glyph (chip + SOC tile)',
        (tester) async {
      await pumpBank(tester, current: null);
      // Still 2, NOT 3: `unknown` is the absence of a reading, so the dial
      // draws no glyph rather than guessing one. Its sub-line says so in words.
      expect(iconCount(tester, Icons.battery_charging_full), 2);
      expect(gauge(tester).subIcon, isNull);
      expect(gauge(tester).subText, 'NO READING');
    });
  });

  // =========================================================================
  // The SVLT chart-track legend still relabels input/output by direction — the
  // surviving direction relabel now that the voltage tile has moved.
  //
  // On the DIAGNOSTIC face: design 0040 split the chart into its own card and
  // the Q1 reversal put that card on diagnostic alone. The legend is worth
  // pinning wherever it renders — it and the energy-path row now sit on the
  // same page, so a legend saying "output" under a row saying "input" would be
  // visibly self-contradictory.
  // =========================================================================
  group('the chart SVLT legend follows the direction', () {
    testWidgets('charging → input', (tester) async {
      await pumpBank(tester,
          current: -0.43, face: Watchface.diagnostic);
      expect(svltTrackLabel(tester), 'Input voltage');
    });

    testWidgets('discharging → output', (tester) async {
      await pumpBank(tester, current: 1.2, face: Watchface.diagnostic);
      expect(svltTrackLabel(tester), 'Output voltage');
    });

    testWidgets('no reading keeps output (relabel would be a guess)',
        (tester) async {
      await pumpBank(tester, current: null, face: Watchface.diagnostic);
      expect(svltTrackLabel(tester), 'Output voltage');
    });

    testWidgets('and the DEFAULT page carries the same labelled chart',
        (tester) async {
      // 🔴 INVERTED by design 0051 (2026-08-09), and the inversion is the
      // point rather than a concession. This used to assert that the default
      // face had NO chart — which was true, and was the accepted cost of
      // design 0040 Q1's reversal: a user who never opened Settings could not
      // reach the live curve at all. The owner has now removed the setting
      // entirely and put the chart on the one page there is, so the cost is
      // paid off and the direction-aware legend has to hold on the page
      // EVERYONE sees, not only on the one nobody selected.
      //
      // What the original was really guarding — "the three tests above pass
      // because the face was asked for, not because the card is everywhere" —
      // no longer has a subject: the card IS everywhere now, by ruling.
      await pumpBank(tester, current: -0.43);
      expect(find.byType(TrendChartCard), findsOneWidget);
      final svlt = chartCard(tester)
          .tracks
          .firstWhere((t) => t.field == TrendField.svlt);
      expect(svlt.label, 'Input voltage',
          reason: 'charging, on the default page');
    });
  });

  // =========================================================================
  // The chart current track this fix must NOT touch
  // =========================================================================
  testWidgets('the current track stays signed and zero-spanning while charging',
      (tester) async {
    await pumpBank(tester, current: -0.43, face: Watchface.diagnostic);

    final current = chartCard(tester)
        .tracks
        .firstWhere((t) => t.field == TrendField.current);
    expect(current.spanZero, isTrue,
        reason: 'a sign flip mid-window is how a start-up load is read');
  });

  // =========================================================================
  // Readout order after Q5+Q12 and the 2026-08-05 cell-tile removal:
  // SOC, temperature, [capacity]. Classified by icon/unit so l10n wording can
  // change freely.
  // =========================================================================
  testWidgets('readout tiles are in the surviving grid order', (tester) async {
    await pumpBank(tester, current: 1.2); // pumpBank registers its own teardown

    // designCapacityMah is unset in this snapshot, so the capacity tile is
    // absent; the surviving two must be in order, with current, port voltage
    // and cell voltage all gone.
    expect(readoutsCard(tester).items.map(kind).toList(), ['soc', 'temp']);
  });

  // =========================================================================
  // The dial says what its caption promises (2026-08-04 field report).
  // =========================================================================
  group('the dial sub-line carries the direction', () {
    testWidgets('charging', (tester) async {
      await pumpBank(tester, current: -0.43);
      expect(gauge(tester).subText, 'CHARGING');
      expect(gauge(tester).subIcon, Icons.battery_charging_full);
    });

    testWidgets('discharging', (tester) async {
      await pumpBank(tester, current: 1.2);
      expect(gauge(tester).subText, 'DISCHARGING');
      expect(gauge(tester).subIcon, Icons.bolt);
    });

    testWidgets('in-band current is standby, not a direction', (tester) async {
      await pumpBank(tester, current: 0.0);
      expect(gauge(tester).subText, 'STANDBY');
    });

    testWidgets('the cell voltage is printed exactly zero times', (tester) async {
      // It used to appear twice on one screen: the dial sub-line AND a grid
      // tile, both reading `tele.pvlt`. Owner's call was to drop it, not to
      // de-duplicate it — a 1S bank's cell voltage is the pack voltage the SOC
      // ring already stands for.
      await pumpBank(tester, current: 1.2);
      expect(readoutsCard(tester).items.map(kind).toList(),
          isNot(contains('cell')));
      expect(find.byIcon(Icons.battery_5_bar), findsNothing);
    });
  });
}
