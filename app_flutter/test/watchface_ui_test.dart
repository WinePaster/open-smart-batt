// The watchface, on screen (design 0034 Phase 5 + Phase 1, design 0051).
//
// 🔴 REWRITTEN 2026-08-09 by design 0051. The owner ruled 「同意拿掉入口」: the
// picker is gone from the device page, the Settings signpost is gone with it,
// and `effectiveWatchface` resolves every stored slug to `Watchface.fixed`.
// What that does to this file is worth stating, because "the tests were changed
// to make them pass" is exactly what it looks like from a diff:
//
//  * **G1 / T2 — "the faces are pairwise different" — LOSES ITS SUBJECT.** It
//    existed because the picker offered three entries and delivered two screens
//    on a power bank (v0.7.2, reported from the field). With no picker there is
//    no entry to be disappointed by, and `riding` legitimately collapses onto
//    `compact`'s list now that neither phone module is on a face. The pairwise
//    assertion is REPLACED by the invariant that actually governs today: there
//    is ONE drawn face, its card order is pinned verbatim, and NO face names a
//    phone module. That last one is a privacy guard, not a cosmetic one — a
//    module named by a face is one resolver bug away from mounting a card that
//    opens the GNSS gate.
//  * **G4 — "a user who never opens the setting sees no change" — was already
//    overturned** by design 0046 R3 (the home grid became the entry point) and
//    is now finished: everyone gets the chart. The pre-0034 list is still
//    pinned, as the definition old `face=standard` captures were taken under.
//  * The §6 invariant is UNTOUCHED and still swept over every enum value: the
//    control card is last, always, and no stored slug can move or remove it.
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
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
import 'package:open_smart_batt/ui/history/device_history_section.dart';
import 'package:open_smart_batt/ui/dashboard/power_bank_view.dart';
import 'package:open_smart_batt/ui/dashboard/pvlt_gauge.dart';
import 'package:open_smart_batt/ui/dashboard/readouts_card.dart';
import 'package:open_smart_batt/ui/dashboard/speed_card.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls.dart';
import 'package:open_smart_batt/ui/dashboard/watchfaces.dart';
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
    // design 0065: the dashboard now ends with the embedded history block,
    // which fires its queries on mount. Real database IO cannot settle under
    // the widget tester's fake clock, so it is drained here — otherwise the
    // test ends holding a pending timer.
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 60)));
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
  // design 0051 — there is ONE face, and no face carries a phone module
  // =========================================================================
  //
  // 📦 This group REPLACES T2 (G1), "no two faces draw the same layout". T2
  // existed because the PICKER offered three entries and delivered two screens
  // on a power bank, and the owner found out by tapping through them. Design
  // 0051 removed the picker, so there is nothing left to be disappointed by —
  // and `riding`, stripped of both phone modules, is now `compact`'s list
  // verbatim. Keeping T2 would mean either keeping a card on `riding` that the
  // ruling took off it, or asserting a property with no consequence.
  //
  // What replaces it is stricter about the thing that still matters.
  group('design 0051: one drawn face', () {
    test('every stored slug, on every class, resolves to `fixed`', () {
      for (final cls in ProductClass.values) {
        for (final stored in Watchface.values) {
          expect(effectiveWatchface(cls, stored), Watchface.fixed,
              reason: '${cls.name} / ${stored.slug}');
        }
      }
    });

    // The ruled order, written out: 圓錶 → 趨勢圖 → 數字格 → 類別卡.
    //
    // 🔴 NOT `diagnostic`'s order (chart first, instrument last). That order
    // was chosen in design 0041 Q4 on the premise that anyone who went to
    // Settings and picked `diagnostic` came for the curve; once this is the
    // only page, that population is everybody, and the cost the premise was
    // paying — the chart has no points for the first seconds of a link, so the
    // TOP of the page is a waiting card — lands on every user on every connect.
    test('the fixed face is gauge → chart → readouts → class card', () {
      const expected = <ProductClass, List<DisplayModule>>{
        ProductClass.smartBattery: [
          DisplayModule.gaugeVoltage,
          DisplayModule.chart,
          DisplayModule.readouts,
          DisplayModule.cells,
        ],
        // No `cells` — design 0050 D5,「電容沒有分串電壓」.
        ProductClass.supercapacitor: [
          DisplayModule.gaugeVoltage,
          DisplayModule.chart,
          DisplayModule.readouts,
        ],
        ProductClass.unknown: [
          DisplayModule.gaugeVoltage,
          DisplayModule.chart,
          DisplayModule.readouts,
          DisplayModule.cells,
        ],
        ProductClass.powerBank: [
          DisplayModule.gaugeSoc,
          DisplayModule.chart,
          DisplayModule.readouts,
          DisplayModule.energyPath,
        ],
      };
      expected.forEach((cls, mods) {
        expect(watchfaceModules(cls, Watchface.fixed), mods, reason: cls.name);
      });
    });

    // 🔴 A PRIVACY guard, not a cosmetic one (design 0051 ruling A:「表盤不會
    // 有速度卡跟Ｇ值卡 這兩個應該只會在主頁出現」).
    //
    // the card factory turns `speed` into a `SpeedCard`, and mounting one calls
    // `setFaceWantsSpeed(true)` — condition 1 of design 0042's three-condition
    // GNSS gate. A module named by ANY face is one resolver bug away from being
    // built, so the modules are removed at the face layer rather than filtered
    // at the caller. It also keeps the export preamble honest: `modules=` is
    // printed from `watchfaceModules` verbatim, so a leftover `speed` would
    // claim a GPS card in every capture.
    test('no face on any class names a phone module', () {
      for (final cls in ProductClass.values) {
        for (final f in Watchface.values) {
          expect(watchfaceModules(cls, f).where((m) => m.isPhoneModule), isEmpty,
              reason: '${cls.name}/${f.slug}');
        }
      }
    });

    test('every face still draws at least the instrument, and no empty page',
        () {
      // Inherited from T2 unchanged. A blank page is the failure the pairwise
      // check could never have caught on its own, and it is still possible.
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

    // The historical baseline. `standard` is not drawn any more, but every
    // capture in the corpus was taken under it — 11 of 11 — so the list it
    // named is what `face=standard modules=…` in an old preamble means.
    test('the `standard` list is still, verbatim, the pre-Phase-1 list', () {
      const pre = <ProductClass, List<DisplayModule>>{
        ProductClass.smartBattery: [
          DisplayModule.gaugeVoltage,
          DisplayModule.readouts,
          DisplayModule.cells,
        ],
        ProductClass.supercapacitor: [
          DisplayModule.gaugeVoltage,
          DisplayModule.readouts,
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
      // design 0051: the picker, its host sheet, the Settings signpost and the
      // eleven strings that only they used. Same T11 reasoning as above — an
      // orphan key survives forever, is re-translated at every locale pass and
      // is eventually reused for something unrelated because its name still
      // sounds available. `Watchface` itself is NOT here: the enum, the slugs
      // and the stored column are the skeleton the ruling kept.
      'showWatchfaceSheet',
      '_WatchfaceSheet',
      '_WatchfaceGuidanceRow',
      'settingsWatchfaceLabel',
      'settingsWatchfaceSub',
      'settingsWatchfaceSubNoDevice',
      'settingsWatchfaceGuidance',
      'watchfaceStandard',
      'watchfaceCompact',
      'watchfaceDiagnostic',
      'watchfaceRiding',
      'settingsRestoreDisplayLabel',
      'settingsRestoreDisplayDone',
      'deviceDetailWatchface',
    ]) {
      test('no occurrence of `$needle`', () {
        expect(sources.where((s) => s.contains(needle)), isEmpty);
      });
    }
  });


  // =========================================================================
  // The page that is actually drawn
  // =========================================================================
  //
  // 📦 Was T1 ("the default IS today's screen"). The G4 promise it enforced was
  // overturned in two steps and both are recorded rather than quietly dropped:
  // design 0046 R3 made the home grid the entry point, and design 0051 gives
  // every user the chart. What is pinned here is the ORDER the ruling named.
  group('the fixed face, on screen', () {
    testWidgets('battery: gauge → chart → readouts → DVOL → controls',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await pumpUnder(tester, s, const PackScaffold(deviceId: 'DEV-TEST', controls: BatteryControls()));
      await feedDvol(tester);

      expect(s.devices.layoutFor('DEV-A'), DisplayLayout.defaults,
          reason: 'nothing writes this column any more');
      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(TrendChartCard))));
      expect(dy(tester, find.byType(TrendChartCard)),
          lessThan(dy(tester, find.byType(ReadoutsCard))));
      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(DvolBars))));
      expect(dy(tester, find.byType(DvolBars)),
          lessThan(dy(tester, find.byType(BatteryControls))));
    });

    testWidgets('capacitor: the same order, minus the card it has no data for',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await pumpUnder(
          tester, s, const PackScaffold(deviceId: 'DEV-TEST', controls: CapacitorControls()));
      await feedDvol(tester);

      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(TrendChartCard))));
      expect(dy(tester, find.byType(TrendChartCard)),
          lessThan(dy(tester, find.byType(ReadoutsCard))));
      // 🔴 No DVOL bars on a capacitor since design 0050 D5. `feedDvol` above
      // still runs, and that is the point: the frames are fed and the card
      // still does not appear, so this asserts the CLASS gate rather than an
      // absence of data.
      expect(find.byType(DvolBars), findsNothing);
      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(CapacitorControls))));
      // 🔑 The footnote is BACK on the default page. This assertion was the
      // inverse before design 0051 — a capacitor owner who never opened
      // Settings saw neither the curve nor the sentence explaining why it has
      // no current track. That was the accepted cost of design 0040 Q1's
      // reversal, and the fixed face pays it off.
      expect(find.textContaining('constant 0 A'), findsOneWidget);
    });

    testWidgets('power bank: SOC ring → chart → readouts', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpUnder(tester, s, const PowerBankView(deviceId: 'DEV-TEST'));

      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(TrendChartCard))));
      expect(dy(tester, find.byType(TrendChartCard)),
          lessThan(dy(tester, find.byType(ReadoutsCard))));
      // The energy-path row renders nothing in this harness — the class is not
      // overridden to power bank, so its own gate holds it back. Covered by
      // power_bank_direction_test.dart, which sets the 0x22 wire byte.
    });

    testWidgets('an unclassified pack gets the same page, chart included (Q4)',
        (tester) async {
      // 📦 Design 0034 Q4 used to force `standard` here, so that a screen
      // asking the user what the device is would not also be rearranged under
      // them by "a preference carried over from another unit". That second
      // clause was the whole argument and design 0051 removed preferences —
      // there is nothing to carry over, so there is nothing to protect against,
      // and the unclassified page simply joins everyone else's.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.diagnostic));
      await pumpUnder(tester, s, const PackScaffold(deviceId: 'DEV-TEST', controls: PackControls()));
      await feedDvol(tester);

      expect(s.connection.packLabel, ProductClass.unknown);
      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(TrendChartCard))));
      expect(dy(tester, find.byType(TrendChartCard)),
          lessThan(dy(tester, find.byType(ReadoutsCard))));
    });
  });

  // =========================================================================
  // T4 — the chart footnote travels with the chart
  // =========================================================================
  //
  // Unchanged in substance; it no longer has to select a face to find a chart.
  // "No current track: this unit reports a constant 0 A, which is not a
  // measurement" is what stops a capacitor owner reading the missing series as
  // an app failure.
  group('T4: the capacitor footnote renders inside the chart card', () {
    testWidgets('capacitor: the note is under the chart, not the numbers',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await pumpUnder(
          tester, s, const PackScaffold(deviceId: 'DEV-TEST', controls: CapacitorControls()));
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

    testWidgets('battery: a chart, and no footnote', (tester) async {
      // The inverse. A footnote that appeared on every class would tell battery
      // owners their current track is fake.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await pumpUnder(tester, s, const PackScaffold(deviceId: 'DEV-TEST', controls: BatteryControls()));
      await feedDvol(tester);

      expect(find.byType(TrendChartCard), findsOneWidget);
      expect(find.textContaining('constant 0 A'), findsNothing);
    });
  });

  // =========================================================================
  // A stored non-default face is READ, and then ignored
  // =========================================================================
  //
  // 📦 Replaces "the non-default faces change the page", which asserted the
  // opposite and could only be reached through a picker that no longer exists.
  //
  // This is the SILENT MIGRATION the ruling accepted in as many words: a user
  // who chose `compact` on v0.7.10 gets the fixed layout on next launch with no
  // dialog and no data loss. It is only safe because `DisplayLayout.decode`
  // never throws, and that contract is asserted here from the rendering end
  // rather than trusted from its doc comment.
  group('a stored face survives storage and changes nothing on screen', () {
    for (final stored in [
      Watchface.standard,
      Watchface.compact,
      Watchface.diagnostic,
      Watchface.riding,
    ]) {
      testWidgets('${stored.slug}: the page is the fixed one', (tester) async {
        final s = await makeServices(tester);
        addTearDown(() => teardown(tester, s));
        s.connection.setPackLabelOverride(ProductClass.smartBattery);
        // Both switches ON, so `riding` is at its most tempting.
        await setSpeedDetection(tester, s, true);
        await tester.runAsync(() => setFace(s, 'DEV-A', stored));
        await pumpUnder(
            tester, s, const PackScaffold(deviceId: 'DEV-TEST', controls: BatteryControls()));
        await feedDvol(tester);

        // Every card of the fixed face, in its order.
        expect(dy(tester, find.byType(PvltGauge)),
            lessThan(dy(tester, find.byType(TrendChartCard))));
        expect(dy(tester, find.byType(TrendChartCard)),
            lessThan(dy(tester, find.byType(ReadoutsCard))));
        expect(find.byType(DvolBars), findsOneWidget);
        // 🔴 And neither phone card, on the face most likely to carry one.
        expect(find.byType(SpeedCard), findsNothing);
        // The stored value is untouched: this is a rendering decision, not a
        // migration, so restoring the picker would restore the user's choice.
        expect(s.devices.layoutFor('DEV-A').watchface, stored);
      });
    }

    testWidgets('two devices with different stored faces draw one page',
        (tester) async {
      // 📦 Was "switching devices switches the layout with them" (design 0034
      // Q3). The BINDING is still real and still tested — see
      // `display_layout_test.dart`, which reads it back out of the row — but it
      // no longer reaches the screen, and pretending otherwise here would be
      // asserting a difference the user cannot see.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() async {
        await setFace(s, 'DEV-A', Watchface.compact);
        await setFace(s, 'DEV-B', Watchface.standard);
      });

      ble.connectedId = 'DEV-A';
      await pumpUnder(tester, s, const PackScaffold(deviceId: 'DEV-TEST', controls: BatteryControls()));
      await feedDvol(tester);
      expect(find.byType(ReadoutsCard), findsOneWidget);

      ble.connectedId = 'DEV-B';
      await tester.runAsync(() => s.devices.load()); // notifies -> rebuild
      await tester.pump();
      expect(find.byType(ReadoutsCard), findsOneWidget);
      // The rows still differ, which is what makes the assertion above a
      // statement about RENDERING rather than about storage.
      expect(s.devices.layoutFor('DEV-A').watchface, Watchface.compact);
      expect(s.devices.layoutFor('DEV-B').watchface, Watchface.standard);
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
            tester, s, const PackScaffold(deviceId: 'DEV-TEST', controls: BatteryControls()));
        await feedDvol(tester);

        // Structural: it is the last CARD of the shell's child list, not
        // merely the lowest thing that happened to render.
        //
        // ⚠️ AMENDED 2026-08-16 (design 0065 §3.3.4). This used to assert
        // `.last`, and one thing now comes after the control card: the
        // embedded history block. That is NOT a breach of design 0034 §6's
        // "controls last, always" — that rule is about the WATCHFACE, and it
        // is enforced structurally by there being no `DisplayModule` for the
        // protection card, so no face can name it or move it. The history
        // block has no `DisplayModule` either; it is appended by the SHELL,
        // below everything the face placed. The two are not on the same axis.
        //
        // So the assertion becomes the precise one: the control card is the
        // last thing the DASHBOARD puts up, and the only thing after it is the
        // history block. A face that managed to place a card below the
        // controls would still fail here.
        final children = shellChildren(tester);
        expect(children.last, isA<DeviceHistorySection>(),
            reason: 'the history block is appended by the shell, last');
        expect(children[children.length - 2], isA<IndustrialCard>(),
            reason: 'and the control card is still the last card of the '
                'dashboard proper');
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
        await pumpUnder(tester, s, const PowerBankView(deviceId: 'DEV-TEST'));

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
  // design 0051 ruling A — the phone cards are off the dashboard entirely
  // =========================================================================
  //
  // 📦 Replaces the `riding` group. Those tests asserted that the speed card
  // sat above the instrument and that the face fell back when the switch went
  // off — both statements about a face that can no longer be selected and no
  // longer carries the card. What is worth keeping from them is the CHAIN they
  // were really protecting: no module ⇒ no card ⇒ no `setFaceWantsSpeed` ⇒ no
  // GNSS stream. That chain now has to hold with both switches ON, which is a
  // strictly harder condition than the one those tests exercised.
  group('no dashboard page mounts a phone card, whatever is on', () {
    testWidgets('pack: speed on, G stored face, no speed card and no gate',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await setSpeedDetection(tester, s, true);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.riding));
      await pumpUnder(tester, s, const PackScaffold(deviceId: 'DEV-TEST', controls: BatteryControls()));
      await feedDvol(tester);

      expect(find.byType(SpeedCard), findsNothing);
      // The gate's first condition never opened, which is the fact the absent
      // widget is only a proxy for.
      expect(s.speed.streaming, isFalse);
      // …and the page is the ordinary one.
      expect(find.byType(ReadoutsCard), findsOneWidget);
      expect(find.byType(TrendChartCard), findsOneWidget);
    });

    testWidgets('power bank: the same', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await setSpeedDetection(tester, s, true);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.riding));
      await pumpUnder(tester, s, const PowerBankView(deviceId: 'DEV-TEST'));

      expect(find.byType(SpeedCard), findsNothing);
      expect(s.speed.streaming, isFalse);
      expect(find.byType(ReadoutsCard), findsOneWidget);
    });
  });
}
