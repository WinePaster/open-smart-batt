// The watchface, on screen (design 0034 Phase 5 + Phase 1 — tests T1 / T2 /
// T4 / T5 / T7 / T8 / T9).
//
// THE INVARIANT WORTH THE MOST HERE IS G4: a user who never opens the setting
// must see the screen they saw yesterday. ⚠️ Design 0040 RELAXED what that
// means, deliberately and with the owner's ruling — see the long note on the T1
// group below before assuming it was abandoned.
//
// The invariant this file gained is G1 (T2): the three faces must produce
// PAIRWISE DIFFERENT layouts on EVERY product class. That is not a nicety. On
// v0.7.2 a power bank's `standard` and `compact` returned identical lists, so
// the owner tapped through all three settings and reported that nothing
// happened — three menu entries, two outcomes. T2 is the test that makes that
// state of affairs impossible to ship again.
//
// The third is §6, and it is an INVARIANT rather than a default: the control
// card is last, always, and cannot be moved or removed. It is enforced
// structurally — there is no `DisplayModule` for it, so no watchface can name
// it — but "structurally impossible" is a claim that has to be executed, not
// asserted in a comment.
import 'dart:async';
import 'dart:io';

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
import 'package:open_smart_batt/ui/dashboard/display_modules.dart';
import 'package:open_smart_batt/ui/dashboard/dvol_bars.dart';
import 'package:open_smart_batt/ui/dashboard/pack_view.dart';
import 'package:open_smart_batt/ui/dashboard/power_bank_view.dart';
import 'package:open_smart_batt/ui/dashboard/pvlt_gauge.dart';
import 'package:open_smart_batt/ui/dashboard/readouts_card.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls.dart';
import 'package:open_smart_batt/ui/dashboard/watchfaces.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:open_smart_batt/ui/widgets/industrial_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService with a settable connected id — the layout is bound to a
/// device, so "which device" is an input to every test here.
class _FakeBleService extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  String? connectedId = 'DEV-A';

  @override
  String? get connectedDeviceId => connectedId;

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
      // Two saved units: the second exists so that "the setting follows the
      // device" can be tested against something, not asserted against nothing.
      await services.devices.saveNew('DEV-A', 'unit A');
      await services.devices.saveNew('DEV-B', 'unit B');
    });
    return services;
  }

  /// Tear a test down WITHOUT tripping "used after being disposed".
  ///
  /// `AppServices.dispose()` disposes the controllers and only then drains the
  /// pending writes — and those writes call back into [DeviceController]
  /// (`touch`, `setProductClass`). Every test here has a connected device id,
  /// which is exactly what makes those writes fire, so the queue is drained
  /// first, while the controllers are still alive.
  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => s.pending.drain());
    await s.dispose();
  }

  Future<void> pumpUnder(
      WidgetTester tester, AppServices s, Widget child) async {
    // A TALL surface, on purpose. Every page here is a ListView, which builds
    // only the children it can show — on the default 800x600 the control card
    // is simply not in the tree, and "the controls are last" would pass by
    // never finding them at all.
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
          locale: const Locale('en'),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pump();
  }

  /// Push one telemetry snapshot carrying per-cell voltages, so the DVOL card
  /// has data and its DATA gate is satisfied (the card's own condition, which
  /// the watchface never overrides).
  Future<void> feedDvol(WidgetTester tester) async {
    ble.emit(TelemetrySample(
      timestamp: DateTime(2026, 8, 4, 9, 30),
      pvlt: 13.2,
      svlt: 13.1,
      temperatureC: 31,
      dvol: const [3.30, 3.31, 3.29, 3.30],
    ));
    await tester.pump();
    await tester.pump();
  }

  /// Let a real database write started by a tap actually finish.
  ///
  /// The picker writes through sqflite, which needs real async; inside a widget
  /// test the clock is faked, so a plain `pump()` returns before the row is
  /// updated and the assertion reads the value from before the tap.
  Future<void> settleWrite(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump();
  }

  /// Vertical position of the first match — the page is a ListView, so "which
  /// card comes first" is a y comparison.
  double dy(WidgetTester tester, Finder f) =>
      tester.getTopLeft(f.first).dy;

  /// The pack shell's top-level children, in order.
  List<Widget> shellChildren(WidgetTester tester) {
    final lv = tester.widget<ListView>(find.descendant(
      of: find.byType(PackScaffold),
      matching: find.byType(ListView),
    ));
    return (lv.childrenDelegate as SliverChildListDelegate).children;
  }

  Future<void> setFace(AppServices s, String id, Watchface f) =>
      s.devices.setDisplayLayout(id, DisplayLayout(watchface: f));

  // =========================================================================
  // T2 (G1) — the three faces are pairwise different, on EVERY class
  // =========================================================================
  //
  // THIS TEST IS THE REASON DESIGN 0040 EXISTS. Pure Dart, no widgets: the
  // defect was in `watchfaceModules` itself, not in how a view drew it.
  //
  // What went wrong on v0.7.2: a power bank had four registered modules, the
  // chart was withheld from every face (Phase 1 unimplemented) and the
  // energy-path row rode every face by ruling (design 0035 Q2). That left two
  // placeable cards, hence two possible orderings, hence `standard == compact`
  // — verbatim, same list object contents. The picker offered three choices and
  // delivered two screens, and the owner found out by using it.
  //
  // ⚠️ It is also the guard against the CHEAP fix. The alternative on the table
  // was to hide `compact` from the picker for power banks, which would have
  // made the symptom invisible while leaving the cause in place. That "fix"
  // fails this test too, because this asserts the FACES differ, not that the
  // picker is short.
  group('T2 (G1): no two faces draw the same layout, for any class', () {
    for (final cls in ProductClass.values) {
      test('${cls.name}: standard / compact / diagnostic are pairwise unequal',
          () {
        final byFace = {
          for (final f in Watchface.values) f: watchfaceModules(cls, f),
        };
        for (final a in Watchface.values) {
          for (final b in Watchface.values) {
            if (a == b) continue;
            expect(byFace[a], isNot(byFace[b]),
                reason: '${a.slug} and ${b.slug} give ${cls.name} the same '
                    'page: ${byFace[a]}');
          }
        }
      });
    }

    test('every face still draws at least the instrument, and no empty page',
        () {
      // The trivially "different" layouts — one of them empty — would satisfy
      // the pairwise check above while shipping a blank screen.
      for (final cls in ProductClass.values) {
        for (final f in Watchface.values) {
          final mods = watchfaceModules(cls, f);
          expect(mods, isNotEmpty, reason: '${cls.name}/${f.slug}');
          expect(mods.toSet(), hasLength(mods.length),
              reason: '${cls.name}/${f.slug} repeats a card');
          expect(
            mods.any((m) =>
                m == DisplayModule.gaugeSoc || m == DisplayModule.gaugeVoltage),
            isTrue,
            reason: '${cls.name}/${f.slug} has no instrument',
          );
        }
      }
    });
  });

  // =========================================================================
  // T5 — the toggle, and its vocabulary, are gone from the app
  // =========================================================================
  group('T5: `_ModeToggle` and its two l10n keys are gone from lib/', () {
    // Source-level, because the widget is private and the two strings are
    // reachable from nothing once the toggle is removed — a `find.text` test
    // can only prove they are not on ONE page. The precedent is design 0035 T11
    // for the retired USB keys: an orphan key survives forever otherwise, gets
    // re-translated at every locale pass, and eventually gets reused for
    // something unrelated because its name still sounds available.
    late final List<String> sources;

    setUpAll(() {
      sources = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart') || f.path.endsWith('.arb'))
          .map((f) => f.readAsStringSync())
          .toList();
      // The scan must have found something, or every expectation below is
      // vacuously true.
      expect(sources.length, greaterThan(20));
      expect(sources.any((s) => s.contains('dashboardChartWaiting')), isTrue);
    });

    for (final needle in const [
      '_ModeToggle',
      'dashboardModeNumbers',
      'dashboardModeChart',
    ]) {
      test('no occurrence of `$needle`', () {
        expect(sources.where((s) => s.contains(needle)), isEmpty);
      });
    }
  });

  // =========================================================================
  // T1 — the default screen, and how much of it G4 still protects
  // =========================================================================
  //
  // ⚠️ RELAXED 2026-08-05 (design 0040 §3.2 / Q1 — an owner ruling, not a
  // quiet loosening). This group used to pin the WHOLE standard list; it now
  // pins the FIRST THREE cards. G4 was not abandoned, it was made decidable:
  //
  //   Phase 1 removes `_ModeToggle`, which was the only way to reach the live
  //   curve. So after Phase 1 either `standard` gains the chart (the page grows
  //   a card) or the chart becomes unreachable for everyone who never opens
  //   Settings (a feature silently disappears). G4's literal wording — "nothing
  //   changes" — is not available in either direction. The ruling chose the
  //   smaller change and put the chart LAST, so the FIRST SCREEN is
  //   pixel-identical to v0.7.2 and the new card is below the fold.
  //
  // Hence: the prefix is pinned, the tail is allowed to grow. What is NOT
  // relaxed is the order or the identity of those first three cards — those are
  // still asserted card for card, and the pure-Dart prefix test below states it
  // without depending on a viewport size.
  group('T1: the standard face reproduces the pre-0034 dashboard', () {
    test('the first three cards are, verbatim, the pre-Phase-1 list', () {
      // Transcribed from `watchfaces.dart` as it stood at v0.7.2 — the whole
      // return value then, the required prefix now.
      const pre = <ProductClass, List<DisplayModule>>{
        ProductClass.smartBattery: [
          DisplayModule.gaugeVoltage,
          DisplayModule.readouts,
          DisplayModule.cells,
        ],
        ProductClass.supercapacitor: [
          DisplayModule.gaugeVoltage,
          DisplayModule.readouts,
          DisplayModule.cells,
        ],
        ProductClass.unknown: [
          DisplayModule.gaugeVoltage,
          DisplayModule.readouts,
          DisplayModule.cells,
        ],
        ProductClass.powerBank: [
          DisplayModule.gaugeSoc,
          DisplayModule.readouts,
          DisplayModule.energyPath,
        ],
      };
      pre.forEach((cls, prefix) {
        final now = watchfaceModules(cls, Watchface.standard);
        expect(now.take(3).toList(), prefix, reason: cls.name);
        // And the ONLY thing appended is the chart. A second new card would
        // slide into the first screen on a short phone, which is the thing the
        // relaxation above was careful not to permit.
        expect(now.skip(3).toList(), [DisplayModule.chart], reason: cls.name);
      });
    });

    testWidgets('battery: gauge → readouts → DVOL → controls', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(s.devices.layoutFor('DEV-A'), DisplayLayout.defaults,
          reason: 'nobody opened the setting');
      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(ReadoutsCard))));
      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(DvolBars))));
      // The Phase 1 addition, and where it sits: after the three cards G4
      // protects, before the control card §6 pins last.
      expect(dy(tester, find.byType(DvolBars)),
          lessThan(dy(tester, find.byType(TrendChartCard))));
      expect(dy(tester, find.byType(TrendChartCard)),
          lessThan(dy(tester, find.byType(BatteryControls))));
    });

    testWidgets('capacitor: the same order, with the capacitor body',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await pumpUnder(
          tester, s, const PackScaffold(controls: CapacitorControls()));
      await feedDvol(tester);

      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(ReadoutsCard))));
      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(DvolBars))));
      expect(dy(tester, find.byType(DvolBars)),
          lessThan(dy(tester, find.byType(CapacitorControls))));

      // T4 — the footnote travelled WITH the chart.
      //
      // This is the one string the split could plausibly have dropped, and the
      // capacitor is the only class that has it. "No current track: this unit
      // reports a constant 0 A, which is not a measurement" is what stops an
      // owner reading the missing series as an app failure — the same reason
      // `display_modules.dart` calls it the entry most easily lost in a
      // refactor. Asserted as a DESCENDANT of the chart card, not merely
      // somewhere on the page, because "still rendered, but under the numbers"
      // is exactly the wrong outcome this pins against.
      expect(
        find.descendant(
          of: find.byType(TrendChartCard),
          matching: find.textContaining('constant 0 A'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ReadoutsCard),
          matching: find.textContaining('constant 0 A'),
        ),
        findsNothing,
      );
    });

    testWidgets('T4: a battery has no chart footnote — the note is a '
        'capacitor fact, not decoration', (tester) async {
      // The inverse of the assertion above. A footnote that appeared on every
      // class would tell battery owners their current track is fake.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(find.byType(TrendChartCard), findsOneWidget);
      expect(find.textContaining('constant 0 A'), findsNothing);
    });

    testWidgets('power bank: SOC ring → readouts (USB card retired)',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpUnder(tester, s, const PowerBankView());

      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(ReadoutsCard))));
      // design 0035 Phase 2: the two-port USB card is gone and its slot now
      // holds the energy-path row [PowerPathRow]. That row renders nothing here
      // (this harness leaves the class un-overridden, so it is not a power bank
      // to the row's own gate), so the pinned order is the surviving two cards.
    });

    testWidgets('an unclassified pack keeps the standard order even with a '
        'diagnostic face stored (Q4)', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(
          () => setFace(s, 'DEV-A', Watchface.diagnostic));
      // No label override and no wire byte → unclassified.
      await pumpUnder(tester, s, const PackScaffold(controls: PackControls()));
      await feedDvol(tester);

      expect(s.connection.packLabel, ProductClass.unknown);
      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(ReadoutsCard))),
          reason: 'a page that is asking the user what this device is must not '
              'also be rearranged under them');
    });
  });

  // =========================================================================
  // The other two faces actually do something
  // =========================================================================
  group('the non-default faces change the page', () {
    testWidgets('compact drops the DVOL card even when DVOL has data',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.compact));
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(find.byType(PvltGauge), findsOneWidget);
      expect(find.byType(ReadoutsCard), findsOneWidget);
      expect(find.byType(DvolBars), findsNothing,
          reason: 'the card is off the page by choice, not for want of data — '
              'which is exactly why the export preamble still records it');
      expect(find.byType(TrendChartCard), findsNothing,
          reason: 'compact is the one-screenful face; a stack of tracks is the '
              'first thing it drops');
      // And the controls are still there, and still last.
      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(BatteryControls))));
    });

    testWidgets('a power bank on compact keeps the direction row and drops '
        'the numbers (design 0040 Q2)', (tester) async {
      // The deliberate asymmetry: a PACK's compact drops its extra card and
      // keeps the grid; a POWER BANK does the opposite. design 0035 Q2's
      // reason for the energy-path row — "that line IS the answer to which way
      // it is charging" — only gets stronger as the page gets shorter.
      //
      // The accepted cost is R3: this face carries no temperature at all,
      // because temperature lives in the grid that just went away. Two other
      // faces have it.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.compact));
      await pumpUnder(tester, s, const PowerBankView());

      expect(
          watchfaceModules(ProductClass.powerBank, Watchface.compact),
          [DisplayModule.gaugeSoc, DisplayModule.energyPath]);
      // On screen: the ring is there, the grid is not. (The energy-path row
      // renders nothing in this harness — the class is not overridden to power
      // bank, so its own gate holds it back; it is covered by
      // power_bank_direction_test.dart, which does set the 0x22 wire byte.)
      expect(find.byType(PvltGauge), findsOneWidget);
      expect(find.byType(ReadoutsCard), findsNothing);
      expect(find.byType(TrendChartCard), findsNothing);
    });

    testWidgets('diagnostic puts the numbers first and the instrument last',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.diagnostic));
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(DvolBars))));
      // Detail first, and the curve counts as detail: it sits between the
      // per-cell card and the instrument, so a reporter screenshotting the top
      // of the page catches the numbers, the cells AND the trace.
      expect(dy(tester, find.byType(DvolBars)),
          lessThan(dy(tester, find.byType(TrendChartCard))));
      expect(dy(tester, find.byType(TrendChartCard)),
          lessThan(dy(tester, find.byType(PvltGauge))));
      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(BatteryControls))));
    });

    testWidgets('a power bank on the diagnostic face puts numbers before the '
        'instrument', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.diagnostic));
      await pumpUnder(tester, s, const PowerBankView());

      // Diagnostic leads with the readouts and ends with the SOC ring. The
      // energy-path row (design 0035 Phase 2) renders nothing in this harness
      // (the class is not overridden to power bank), so the pinned order is the
      // surviving three.
      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(TrendChartCard))));
      expect(dy(tester, find.byType(TrendChartCard)),
          lessThan(dy(tester, find.byType(PvltGauge))));
    });
  });

  // =========================================================================
  // T7 / T8 — the control card
  // =========================================================================
  group('T7: the control card is last on every face, and unremovable', () {
    for (final face in Watchface.values) {
      testWidgets('${face.slug}: the protection card is the final child',
          (tester) async {
        final s = await makeServices(tester);
        addTearDown(() => teardown(tester, s));
        s.connection.setPackLabelOverride(ProductClass.smartBattery);
        await tester.runAsync(() => setFace(s, 'DEV-A', face));
        await pumpUnder(
            tester, s, const PackScaffold(controls: BatteryControls()));
        await feedDvol(tester);

        // Structural: it is the LAST entry of the shell's child list, not
        // merely the lowest thing that happened to render.
        expect(shellChildren(tester).last, isA<IndustrialCard>());
        expect(find.byType(BatteryControls), findsOneWidget,
            reason: 'no face may remove it');
        // Every card a pack face can place, including the one Phase 1 added:
        // the control card outranks all of them. (`TrendChartCard` is absent on
        // `compact`, and `dy` is only evaluated for what a face actually
        // placed, hence the filter rather than a fixed list.)
        for (final other in [
          find.byType(PvltGauge),
          find.byType(ReadoutsCard),
          find.byType(TrendChartCard),
        ].where((f) => f.evaluate().isNotEmpty)) {
          expect(dy(tester, other),
              lessThan(dy(tester, find.byType(BatteryControls))));
        }
      });
    }
  });

  group('T8: a power bank grows no empty control card', () {
    for (final face in Watchface.values) {
      testWidgets('${face.slug}: no protection card, no pack controls',
          (tester) async {
        final s = await makeServices(tester);
        addTearDown(() => teardown(tester, s));
        await tester.runAsync(() => setFace(s, 'DEV-A', face));
        await pumpUnder(tester, s, const PowerBankView());

        // The page did render — otherwise "no controls" would be vacuous.
        //
        // Probed on the SOC ring rather than the readouts card: since design
        // 0040 Q2 the power bank's `compact` face has no readouts card at all,
        // so that probe would have started passing for the wrong reason.
        expect(find.byType(PvltGauge), findsOneWidget);
        expect(find.byType(BatteryControls), findsNothing);
        expect(find.byType(CapacitorControls), findsNothing);
        expect(find.byType(PackControls), findsNothing);
        // And no heading was borrowed from the pack page to hold an empty one.
        expect(find.text('Protection Status'), findsNothing);
      });
    }
  });

  // =========================================================================
  // The binding: the layout belongs to the DEVICE (Q3)
  // =========================================================================
  group('switching devices switches the layout with them', () {
    testWidgets('the same widget draws two different pages for two units',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() async {
        await setFace(s, 'DEV-A', Watchface.compact);
        await setFace(s, 'DEV-B', Watchface.standard);
      });

      ble.connectedId = 'DEV-A';
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);
      expect(find.byType(DvolBars), findsNothing, reason: 'A is compact');

      // Same telemetry, same widget, different unit.
      ble.connectedId = 'DEV-B';
      await tester.runAsync(() => s.devices.load()); // notifies → rebuild
      await tester.pump();
      expect(find.byType(DvolBars), findsOneWidget, reason: 'B is standard');
    });
  });

  // =========================================================================
  // The settings entry point (Q6)
  // =========================================================================
  group('the Display card carries the picker and the restore', () {
    Future<void> pumpSettings(WidgetTester tester, AppServices s) async {
      await pumpUnder(tester, s, const SettingsScreen());
      await tester.scrollUntilVisible(find.text('Watchface'), 60,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();
    }

    testWidgets('picking a face writes it against the connected device',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpSettings(tester, s);

      expect(find.text('Standard'), findsOneWidget);
      expect(find.text('Compact'), findsOneWidget);
      expect(find.text('Diagnostic'), findsOneWidget);

      await tester.tap(find.text('Diagnostic'));
      await settleWrite(tester);
      expect(s.devices.layoutFor('DEV-A').watchface, Watchface.diagnostic);
      expect(s.devices.layoutFor('DEV-B'), DisplayLayout.defaults,
          reason: 'the other saved unit is untouched');
    });

    // T9 — one tap back to T1.
    testWidgets('T9: restore defaults puts the standard face back',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.diagnostic));
      await pumpSettings(tester, s);

      await tester.tap(find.text('Restore default display'));
      await settleWrite(tester);
      expect(s.devices.layoutFor('DEV-A'), DisplayLayout.defaults);
    });

    testWidgets('with no device the row is disabled and says why',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      ble.connectedId = null;
      await pumpSettings(tester, s);

      // Kept visible rather than hidden — the background-monitoring precedent:
      // a user who has heard of the feature needs to see WHY it is off.
      expect(find.text('Watchface'), findsOneWidget);
      expect(
        find.textContaining('This setting belongs to a device'),
        findsOneWidget,
      );
      // Inert, not merely dimmed: tapping writes nothing anywhere.
      await tester.tap(find.text('Diagnostic'), warnIfMissed: false);
      await settleWrite(tester);
      expect(s.devices.layoutFor('DEV-A'), DisplayLayout.defaults);
      expect(s.devices.layoutFor('DEV-B'), DisplayLayout.defaults);
    });

    testWidgets('a connected but UNSAVED device also disables the row',
        (tester) async {
      // The layout lives in the saved_devices row. A unit the user declined to
      // name has nowhere to put one, and adding it to their device list as a
      // side effect of a display setting would be a surprise.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      ble.connectedId = 'DEV-UNSAVED';
      await pumpSettings(tester, s);

      expect(
        find.textContaining('This setting belongs to a device'),
        findsOneWidget,
      );
      await tester.tap(find.text('Compact'), warnIfMissed: false);
      await settleWrite(tester);
      expect(s.devices.isSaved('DEV-UNSAVED'), isFalse);
    });
  });
}
