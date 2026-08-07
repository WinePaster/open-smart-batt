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
import 'package:open_smart_batt/ui/dashboard/dvol_bars.dart';
import 'package:open_smart_batt/ui/dashboard/pack_view.dart';
import 'package:open_smart_batt/ui/dashboard/power_bank_view.dart';
import 'package:open_smart_batt/ui/dashboard/pvlt_gauge.dart';
import 'package:open_smart_batt/ui/dashboard/readouts_card.dart';
import 'package:open_smart_batt/ui/dashboard/speed_card.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls.dart';
import 'package:open_smart_batt/ui/dashboard/watchfaces.dart';
import 'package:open_smart_batt/ui/devices/watchface_sheet.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:open_smart_batt/ui/widgets/industrial.dart';
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

/// A one-button host that raises [showWatchfaceSheet] for a device and records
/// whether it opened. Standing in for [DeviceDetailPage]'s app-bar button, so
/// these tests exercise the API rather than that page's chrome.
class _WatchfaceSheetHost extends StatefulWidget {
  const _WatchfaceSheetHost({this.deviceId = 'DEV-A'});

  final String deviceId;

  @override
  State<_WatchfaceSheetHost> createState() => _WatchfaceSheetHostState();
}

class _WatchfaceSheetHostState extends State<_WatchfaceSheetHost> {
  bool? _opened;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () async {
                  final ok = await showWatchfaceSheet(context,
                      deviceId: widget.deviceId);
                  if (mounted) setState(() => _opened = ok);
                },
                child: const Text('open'),
              ),
              if (_opened != null) Text('opened=$_opened'),
            ],
          ),
        ),
      );
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
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
          // design 0042: the speed card reads it, and opens the GNSS gate's
          // first condition from its own mount/unmount. Provided here (with a
          // controller whose platform seam is never touched in a test) so that
          // the `riding` face can be rendered at all.
          ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
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

  /// Flip the design 0042 master switch. It persists, so it goes through
  /// `runAsync` like every other real write in this file.
  Future<void> setSpeedDetection(WidgetTester tester, AppServices s, bool v) =>
      tester.runAsync(() => s.settings.setSpeedDetection(v));

  // =========================================================================
  // T2 (G1) — the faces are pairwise different, on EVERY class
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
      // Iterates `Watchface.values`, so design 0042's `riding` joined it with
      // no change to the assertion — only to this name. A fifth face will do
      // the same.
      test('${cls.name}: every pair of faces is unequal', () {
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
  group('T5: retired widgets and l10n keys are gone from lib/', () {
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
      // design 0040: the readouts card's numbers/chart toggle.
      '_ModeToggle',
      'dashboardModeNumbers',
      'dashboardModeChart',
      // design 0041 Q3 + Q2: the "path undetermined" badge and the two
      // rail-specific standby phrases. The row now withholds a port by drawing
      // NO badge, and every standby reads as the plain `powerBankDirectionIdle`
      // the SOC dial already used.
      //
      // ⚠️ Their absence from `lib/` is what stops them creeping back through a
      // translation pass — the same reason design 0035 T11 scanned for the
      // retired USB keys. If you are reintroducing one of these, read design
      // 0041 R1 first: the standby distinction was given up knowingly.
      'powerPathPortUndetermined',
      'powerPathStandbyOutputOff',
      'powerPathStandbyNoFlow',
      '_undeterminedBadge',
      '_railOff',
    ]) {
      test('no occurrence of `$needle`', () {
        expect(sources.where((s) => s.contains(needle)), isEmpty);
      });
    }
  });

  // =========================================================================
  // T1 — the default IS today's screen, in the strict sense
  // =========================================================================
  //
  // This is the ORIGINAL strict form, and it is strict deliberately. Design
  // 0040 Q1 proposed appending the chart to `standard`; it was implemented,
  // this assertion was relaxed to a three-card prefix to accommodate it, and
  // then the owner REVERSED Q1 on review. So the whole list is pinned again —
  // if you are reading this wondering whether the strict form is merely
  // inherited from before Phase 1: no, it was loosened and put back on purpose.
  // The chart lives on `diagnostic` alone, at the cost recorded in
  // `watchfaces.dart`, and this test is what keeps `standard` paying none of it.
  group('T1: the standard face reproduces the pre-0034 dashboard', () {
    test('the standard list is, verbatim, the pre-Phase-1 list', () {
      // Transcribed from `watchfaces.dart` as it stood at v0.7.2 — the whole
      // return value then, and the whole return value still.
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
      pre.forEach((cls, expected) {
        expect(watchfaceModules(cls, Watchface.standard), expected,
            reason: cls.name);
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
      expect(dy(tester, find.byType(DvolBars)),
          lessThan(dy(tester, find.byType(BatteryControls))));
      // Phase 1 added a card to the app but NOT to this page. The surface here
      // is 3000px tall, so the chart card would be built and found if the
      // standard face named it — this is a real absence, not a lazy ListView.
      expect(find.byType(TrendChartCard), findsNothing,
          reason: 'Q1 reversed: the chart is reachable from diagnostic only');
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
      expect(find.byType(TrendChartCard), findsNothing,
          reason: 'Q1 reversed: no face but diagnostic carries the chart');
      // ⚠️ And with no chart card here there is no chart footnote here either.
      // That is the ACCEPTED cost of the Q1 reversal, spelled out: a capacitor
      // owner on the default face sees neither the curve nor the sentence
      // explaining why it has no current track. Both are on `diagnostic`,
      // together — which is the part T4 below still guarantees.
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
      // Same remap, seen from the other side: the stored face WOULD have put
      // the chart on this page, and Q4 is what keeps it off.
      expect(find.byType(TrendChartCard), findsNothing);
    });
  });

  // =========================================================================
  // T4 — the chart footnote travels with the chart
  // =========================================================================
  //
  // Exercised on the DIAGNOSTIC face, because since the Q1 reversal that is the
  // only face with a chart card to attach a footnote to.
  //
  // This is the one string the Phase 1 split could plausibly have dropped, and
  // the capacitor is the only class that has it. "No current track: this unit
  // reports a constant 0 A, which is not a measurement" is what stops an owner
  // reading the missing series as an app failure — the same reason
  // `display_modules.dart` calls it the entry most easily lost in a refactor.
  group('T4: the capacitor footnote renders inside the chart card', () {
    testWidgets('capacitor / diagnostic: the note is under the chart, not the '
        'numbers', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.diagnostic));
      await pumpUnder(
          tester, s, const PackScaffold(controls: CapacitorControls()));
      await feedDvol(tester);

      expect(find.byType(TrendChartCard), findsOneWidget);
      // A DESCENDANT of the chart card, not merely somewhere on the page:
      // "still rendered, but under the numbers" is exactly the wrong outcome
      // this pins against, and a page-wide finder would accept it.
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

    testWidgets('battery / diagnostic: a chart, and no footnote', (tester) async {
      // The inverse. A footnote that appeared on every class would tell battery
      // owners their current track is fake.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.diagnostic));
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(find.byType(TrendChartCard), findsOneWidget);
      expect(find.textContaining('constant 0 A'), findsNothing);
    });
  });

  // =========================================================================
  // The other two faces actually do something
  // =========================================================================
  group('the non-default faces change the page', () {
    // 🔴 REVERSED 2026-08-05 (design 0041 Q1). This used to assert that compact
    // dropped the DVOL card and KEPT the numbers grid. That was the defect: the
    // grid was then the only thing `compact` and `standard` had in common, so
    // the two faces differed by `cells` alone — and `cells` is the pack's one
    // dataGated module, absent on any unit that never sends 0x24. On such a
    // unit the two faces rendered the same page.
    //
    // The card that goes is now the grid, because the grid is the one a pack
    // always draws. See T2b in display_layout_test.dart for the general rule.
    testWidgets('compact drops the numbers grid and keeps the DVOL card',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.compact));
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(find.byType(PvltGauge), findsOneWidget);
      expect(find.byType(DvolBars), findsOneWidget);
      expect(find.byType(ReadoutsCard), findsNothing,
          reason: 'the grid is off the page by choice, not for want of data — '
              'which is exactly why the export preamble still records what the '
              'LAYOUT says rather than what rendered');
      expect(find.byType(TrendChartCard), findsNothing,
          reason: 'compact is the one-screenful face; a stack of tracks is the '
              'first thing it drops');
      // And the controls are still there, and still last.
      expect(dy(tester, find.byType(DvolBars)),
          lessThan(dy(tester, find.byType(BatteryControls))));
    });

    // The other half of design 0041 Q1, and the one that actually reproduces
    // the field report: a pack whose DVOL never arrives. `standard` loses its
    // per-cell card to the data gate here — that is unchanged and correct — so
    // the ONLY thing that can distinguish the two faces is the grid.
    testWidgets('with no DVOL at all, compact and standard still differ',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.compact));
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      // NOTE: no feedDvol() — this is the unit the report came from.

      expect(find.byType(DvolBars), findsNothing, reason: 'no data to draw');
      expect(find.byType(ReadoutsCard), findsNothing, reason: 'compact');

      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.standard));
      await tester.pump();
      expect(find.byType(ReadoutsCard), findsOneWidget,
          reason: 'standard must still look different from compact on a unit '
              'that reports no per-cell voltages — this is the whole of the '
              'v0.7.4 field report');
    });

    testWidgets('a power bank on compact keeps the direction row and drops '
        'the numbers (design 0040 Q2)', (tester) async {
      // design 0035 Q2's reason for the energy-path row — "that line IS the
      // answer to which way it is charging" — only gets stronger as the page
      // gets shorter. ⚠️ This used to be described here as a deliberate
      // ASYMMETRY against packs, which dropped their extra card and kept the
      // grid. Design 0041 made the pack follow the same rule, so the two are
      // now one rule, not two opposite ones. Nothing in THIS test changed.
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

    // 🔴 REORDERED 2026-08-05 (design 0041 Q4): the CURVE now leads this face.
    // It used to sit third, between the per-cell card and the instrument, on
    // design 0034's reasoning that this face serves someone gathering a report.
    // Design 0040 Q1 made diagnostic the chart's ONLY home, which turned "turn
    // on diagnostic" into the instruction for anyone who wants a live curve at
    // all — so most arrivals here came FOR the curve and had to scroll past two
    // cards to reach it. The instrument still ends the page.
    testWidgets('diagnostic leads with the curve and ends with the instrument',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.diagnostic));
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(dy(tester, find.byType(TrendChartCard)),
          lessThan(dy(tester, find.byType(ReadoutsCard))));
      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(DvolBars))));
      expect(dy(tester, find.byType(DvolBars)),
          lessThan(dy(tester, find.byType(PvltGauge))));
      // The control card is still last, and still not placeable by any face
      // (design 0034 §6).
      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(BatteryControls))));
    });

    testWidgets('a power bank on the diagnostic face leads with the curve too',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.diagnostic));
      await pumpUnder(tester, s, const PowerBankView());

      // Same order as the pack (design 0041 Q4): curve, numbers, class card,
      // instrument. The energy-path row (design 0035 Phase 2) renders nothing
      // in this harness — the class is not overridden to power bank — so the
      // pinned order is the surviving three.
      expect(dy(tester, find.byType(TrendChartCard)),
          lessThan(dy(tester, find.byType(ReadoutsCard))));
      expect(dy(tester, find.byType(ReadoutsCard)),
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
      // Keyed on the GRID since design 0041: it is what compact drops, and it
      // is the card that is guaranteed to be there when it is not dropped.
      expect(find.byType(ReadoutsCard), findsNothing, reason: 'A is compact');

      // Same telemetry, same widget, different unit.
      ble.connectedId = 'DEV-B';
      await tester.runAsync(() => s.devices.load()); // notifies → rebuild
      await tester.pump();
      expect(find.byType(ReadoutsCard), findsOneWidget, reason: 'B is standard');
    });
  });

  // =========================================================================
  // The watchface entry point (Q6)
  //
  // 📦 RE-POINTED by design 0046 R20, not relaxed: the picker moved out of
  // Settings and onto the device's own page (`showWatchfaceSheet`). Every
  // assertion below is the one it was before — what changed is which screen the
  // test opens to reach the control. Settings now carries a signpost, and
  // `watchface_single_writer_test.dart` (T-new-7) is what holds it to being
  // only that.
  // =========================================================================
  group('the watchface sheet carries the picker and the restore', () {
    /// Open the picker the way a user now does: from one device's page.
    Future<void> pumpSettings(WidgetTester tester, AppServices s,
        {String deviceId = 'DEV-A'}) async {
      await pumpUnder(tester, s, const _WatchfaceSheetHost());
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
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

    // ---------------------------------------------------------------------
    // 0034 Q3's asset, carried over as an API rule (design 0046 plan §4.3 R-1).
    //
    // These two used to read "with no device the row is disabled and says why"
    // and "a connected but UNSAVED device also disables the row". Both described
    // a Settings row that had to explain itself because it lived among app-wide
    // settings while being bound to a DEVICE. On the device's own page neither
    // situation can arise — you got there by picking a saved unit — so the rule
    // is now enforced at the entry point instead of explained on screen.
    //
    // ⚠️ NOT deleted, and not weakened. What 0034 Q3 was protecting is that
    // changing a DISPLAY setting must never silently add a unit to the user's
    // device list. That is what is asserted here, one layer lower.
    // ---------------------------------------------------------------------
    testWidgets('an UNSAVED device cannot raise the sheet at all',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      ble.connectedId = 'DEV-UNSAVED';
      await pumpUnder(
          tester, s, const _WatchfaceSheetHost(deviceId: 'DEV-UNSAVED'));

      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Nothing opened…
      expect(find.text('Standard'), findsNothing);
      expect(find.text('Compact'), findsNothing);
      expect(find.text('Restore default display'), findsNothing);
      expect(find.text('opened=false'), findsOneWidget);
      // …and, the part that matters, the unit was not saved as a side effect.
      await settleWrite(tester);
      expect(s.devices.isSaved('DEV-UNSAVED'), isFalse);
      expect(s.devices.layoutFor('DEV-A'), DisplayLayout.defaults);
      expect(s.devices.layoutFor('DEV-B'), DisplayLayout.defaults);
    });

    testWidgets('and Settings no longer offers a picker to reach it by',
        (tester) async {
      // The other half of the old pair: the Settings row still EXISTS (the path
      // has shipped since v0.6.17 and a user who learned it must find out where
      // it went), but it is a link now — see T-new-7.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      ble.connectedId = null;
      await pumpUnder(tester, s, const SettingsScreen());
      await tester.scrollUntilVisible(find.text('Watchface'), 60,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();

      expect(find.text('Watchface'), findsOneWidget);
      expect(find.byType(SegmentedControl<Watchface>), findsNothing);
      expect(find.textContaining('This setting belongs to a device'),
          findsNothing,
          reason: 'the state that sentence explained is now expressed by '
              'navigation: you pick a device, then you get its watchface');
    });

    // design 0034 §4.3 — "unavailable is not offered". `riding` exists only to
    // carry the speed card, so with the master switch off there is nothing for
    // it to be.
    testWidgets('the riding face is offered only while speed detection is on',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpSettings(tester, s);
      expect(find.text('Riding'), findsNothing,
          reason: 'the switch is off by default');

      await setSpeedDetection(tester, s, true);
      await tester.pump();
      expect(find.text('Riding'), findsOneWidget);

      await tester.tap(find.text('Riding'));
      await settleWrite(tester);
      expect(s.devices.layoutFor('DEV-A').watchface, Watchface.riding);
    });
  });

  // =========================================================================
  // design 0042 — the riding face
  // =========================================================================
  group('riding', () {
    testWidgets('puts the speed card above the instrument', (tester) async {
      // §3.3: speed first because on a moving vehicle it is the one reading
      // that has to be legible at a glance.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await setSpeedDetection(tester, s, true);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.riding));
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(find.byType(SpeedCard), findsOneWidget);
      expect(dy(tester, find.byType(SpeedCard)),
          lessThan(dy(tester, find.byType(PvltGauge))));
      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(DvolBars))));
      expect(find.byType(ReadoutsCard), findsNothing,
          reason: 'riding uses the compact shell — the grid is what makes room '
              'for a full-width speed');
      // §6 is unaffected: the controls are still appended after the loop.
      expect(dy(tester, find.byType(DvolBars)),
          lessThan(dy(tester, find.byType(BatteryControls))));
    });

    testWidgets('a power bank gets the same shape', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await setSpeedDetection(tester, s, true);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.riding));
      await pumpUnder(tester, s, const PowerBankView());

      expect(find.byType(SpeedCard), findsOneWidget);
      expect(dy(tester, find.byType(SpeedCard)),
          lessThan(dy(tester, find.byType(PvltGauge))));
      expect(find.byType(ReadoutsCard), findsNothing);
    });

    // 🔴 THE ONE THAT MATTERS. Without the render-layer fallback, `riding` with
    // the switch off draws `[gauge, extra]` — `compact`, card for card — while
    // T2b stays green, because T2b reasons about module LISTS and this collapse
    // happens below them. That is the SAME defect design 0041 was written for,
    // reported from the field as "I tapped through all three and they are all
    // the same". Owner ruling 2026-08-07: make the state unreachable.
    testWidgets('riding falls back to standard when speed detection is off',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await setSpeedDetection(tester, s, true);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.riding));
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);
      expect(find.byType(SpeedCard), findsOneWidget);

      await setSpeedDetection(tester, s, false);
      await tester.pump();

      expect(find.byType(SpeedCard), findsNothing);
      // `standard`, NOT `compact`: the grid is back. Were this rendering as
      // compact, the numbers grid would be absent and the page would be
      // indistinguishable from the compact face.
      expect(find.byType(ReadoutsCard), findsOneWidget,
          reason: 'the fallback is to standard — a page identical to compact '
              'is exactly what T2b exists to make unreachable');
      expect(find.byType(PvltGauge), findsOneWidget);
      expect(find.byType(DvolBars), findsOneWidget);
    });

    testWidgets('the stored face survives the fallback', (tester) async {
      // Non-destructive by design: the slug is not rewritten, so turning the
      // switch back on brings the face back with no migration and no lost
      // setting. A fallback that "corrected" the stored value would silently
      // change a choice the user made.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await setSpeedDetection(tester, s, true);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.riding));
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));

      await setSpeedDetection(tester, s, false);
      await tester.pump();
      expect(s.devices.layoutFor('DEV-A').watchface, Watchface.riding,
          reason: 'the fallback is a rendering decision, not a write');

      await setSpeedDetection(tester, s, true);
      await tester.pump();
      expect(find.byType(SpeedCard), findsOneWidget,
          reason: 'and the face comes back by itself');
    });
  });
}
