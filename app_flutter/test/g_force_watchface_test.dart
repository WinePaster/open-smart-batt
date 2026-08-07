// design 0045 ruling (iv) — the four states of the `riding` face, and the two
// callers that nearly leaked because of them.
//
// 🔴 WHY THIS FILE EXISTS AT THE WIDGET LEVEL AND NOT ONLY AT THE FUNCTION
// LEVEL.
//
// `renderedModules` is easy to test directly and those tests are here, first.
// They are not enough. This project's recurring defect — four times now — is a
// judgement whose INPUT no test ever looked at: the Android sampling period
// pinned at 5 s with 940 tests green, the third `_tab` write bypassing the
// gate with 995 green, the home page handing a power bank the wrong class with
// 1052 green, the estimate stream never connected with 1101 green. Every one of
// them was correct in the function and wrong in the caller.
//
// The caller here is the dashboard. So the same four states are ALSO driven
// through the real `PackScaffold`, with the real providers, asking which cards
// are on screen. If `pack_view.dart` passed the wrong availability — or stopped
// passing it — the pure tests below would stay green and these would not.
//
// The four states are the ruling's own table, one test each:
//
//   speed on,  G off  → [speed, gauge, extra]
//   speed off, G on   → [gForce, gauge, extra]     ← the new one
//   speed on,  G on   → [speed, gForce, gauge, extra]
//   speed off, G off  → not selectable → standard
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
import 'package:open_smart_batt/ui/dashboard/display_modules.dart';
import 'package:open_smart_batt/ui/dashboard/dvol_bars.dart';
import 'package:open_smart_batt/ui/dashboard/g_force_card.dart';
import 'package:open_smart_batt/ui/dashboard/pack_view.dart';
import 'package:open_smart_batt/ui/dashboard/power_bank_view.dart';
import 'package:open_smart_batt/ui/dashboard/pvlt_gauge.dart';
import 'package:open_smart_batt/ui/dashboard/readouts_card.dart';
import 'package:open_smart_batt/ui/dashboard/speed_card.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls.dart';
import 'package:open_smart_batt/ui/dashboard/watchfaces.dart';
import 'package:open_smart_batt/ui/devices/watchface_sheet.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A valid, right-handed, orthonormal calibration. The IDENTITY is fine as
/// stored content — what matters to these tests is that it decodes.
const String kStoredCalibration = '{"m":[1,0,0,0,1,0,0,0,1],"at":1754524800000}';

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

/// Sensors that never emit. The gate is what these tests are about, not the
/// arithmetic — that is `g_force_estimator_test.dart`'s job.
class _SilentSensors implements GForceSensorSource {
  @override
  Stream<Vec3> raw({required Duration samplingPeriod}) =>
      const Stream<Vec3>.empty();

  @override
  Stream<Vec3> linear({required Duration samplingPeriod}) =>
      const Stream<Vec3>.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  // =========================================================================
  // Pure: the ruling's table, module by module
  // =========================================================================
  group('renderedModules — the four states of `riding`', () {
    const off = AppSettings();
    const speedOn = AppSettings(speedDetection: true);

    List<DisplayModule> riding(AppSettings s, {required bool g}) =>
        renderedModules(ProductClass.smartBattery, Watchface.riding, s,
            gForceAvailable: g);

    test('speed on, G unavailable → the speed card, no ball', () {
      expect(riding(speedOn, g: false), [
        DisplayModule.speed,
        DisplayModule.gaugeVoltage,
        DisplayModule.cells,
      ]);
    });

    test('🔴 speed OFF, G available → the ball, and NO speed card', () {
      // The state that did not exist before design 0045 and that the ruling was
      // needed for. `riding` is drawn — the G meter is keeping it alive — and
      // `speed` must not be in it, because laying it out would mount a
      // SpeedCard, which opens the GNSS stream, for a user who never saw the
      // location consent dialog.
      expect(riding(off, g: true), [
        DisplayModule.gForce,
        DisplayModule.gaugeVoltage,
        DisplayModule.cells,
      ]);
    });

    test('both on → both cards, speed first', () {
      expect(riding(speedOn, g: true), [
        DisplayModule.speed,
        DisplayModule.gForce,
        DisplayModule.gaugeVoltage,
        DisplayModule.cells,
      ]);
    });

    test('both off → the face falls back to standard entirely', () {
      expect(riding(off, g: false), [
        DisplayModule.gaugeVoltage,
        DisplayModule.readouts,
        DisplayModule.cells,
      ]);
      expect(
          renderedWatchface(
              ProductClass.smartBattery, Watchface.riding, off,
              gForceAvailable: false),
          Watchface.standard);
    });

    test('every one of the three drawn states differs from compact', () {
      // T2b's property, restated for the state space design 0045 introduced. A
      // face that renders as a copy of another face is the defect design 0041
      // was written for and design 0034 G2 calls unreachable-by-design.
      for (final cls in ProductClass.values) {
        if (cls == ProductClass.unknown) continue; // forced to standard, Q4
        final compact = renderedModules(cls, Watchface.compact, speedOn,
            gForceAvailable: true);
        for (final (s, g) in [(speedOn, false), (off, true), (speedOn, true)]) {
          final drawn =
              renderedModules(cls, Watchface.riding, s, gForceAvailable: g);
          expect(drawn.toSet().difference(compact.toSet()), isNotEmpty,
              reason: '$cls with speed=${s.speedDetection} g=$g renders as a '
                  'copy of compact');
        }
      }
    });

    test('the OTHER faces are untouched by either switch', () {
      // G4: a user who never opens Settings sees the same screen. Both
      // switches, both G states, all four classes, all three original faces.
      for (final cls in ProductClass.values) {
        for (final f in [
          Watchface.standard,
          Watchface.compact,
          Watchface.diagnostic
        ]) {
          final base = watchfaceModules(cls, effectiveWatchface(cls, f));
          for (final s in [off, speedOn]) {
            for (final g in [false, true]) {
              expect(renderedModules(cls, f, s, gForceAvailable: g), base,
                  reason: '$cls / ${f.slug}');
            }
          }
        }
      }
    });

    test('the pure module list still declares everything, for the preamble',
        () {
      // `watchfaceModules` must NOT learn about the switches: it is what
      // `modules=` prints, and a capture whose module list depended on a phone's
      // settings could not be compared with another phone's.
      expect(watchfaceModules(ProductClass.smartBattery, Watchface.riding), [
        DisplayModule.speed,
        DisplayModule.gForce,
        DisplayModule.gaugeVoltage,
        DisplayModule.cells,
      ]);
    });
  });

  group('ridingSelectable', () {
    const off = AppSettings();
    const speedOn = AppSettings(speedDetection: true);

    test('either one is enough, neither is not', () {
      expect(ridingSelectable(speedOn, gForceAvailable: false), isTrue);
      expect(ridingSelectable(off, gForceAvailable: true), isTrue);
      expect(ridingSelectable(speedOn, gForceAvailable: true), isTrue);
      expect(ridingSelectable(off, gForceAvailable: false), isFalse);
    });
  });

  group('phone modules are exactly the two that read no device', () {
    test('the predicate is exhaustive and correct', () {
      // If a module is added to the enum without a decision here, this file
      // will not compile — which is the point of the switch being exhaustive.
      expect(
        [for (final m in DisplayModule.values) if (m.isPhoneModule) m],
        [DisplayModule.speed, DisplayModule.gForce],
      );
    });

    test('and each phone module answers to its OWN switch', () {
      const s = AppSettings(speedDetection: true);
      expect(phoneModuleAvailable(DisplayModule.speed, s, gForceAvailable: false),
          isTrue);
      expect(
          phoneModuleAvailable(DisplayModule.gForce, s, gForceAvailable: false),
          isFalse,
          reason: 'the speed switch must not turn the G meter on');
      const g = AppSettings(gMeterEnabled: true);
      expect(phoneModuleAvailable(DisplayModule.speed, g, gForceAvailable: true),
          isFalse,
          reason: 'and the G meter must not turn the speed card on');
    });
  });

  // =========================================================================
  // The same four states, through the real dashboard
  // =========================================================================
  group('the dashboard draws the four states', () {
    late _FakeBleService ble;

    Future<AppServices> makeServices(WidgetTester tester) async {
      late final AppServices services;
      await tester.runAsync(() async {
        final appDb = await AppDatabase.open(
            path: inMemoryDatabasePath, factory: databaseFactoryFfi);
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

    Future<void> pumpUnder(
        WidgetTester tester, AppServices s, Widget child) async {
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
            ChangeNotifierProvider<TelemetryController>.value(
                value: s.telemetry),
            ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
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
    }

    /// Set the two switches through the REAL settings path, so the composition
    /// root's `applySettings` wiring is exercised rather than bypassed.
    ///
    /// 🔑 That wiring is the input nothing else in this file would look at: a
    /// `GForceController` that never hears about the stored calibration reports
    /// `available == false` forever, and every "the card is absent" assertion
    /// would pass for the wrong reason. The `gOn` cases below are what stop
    /// that.
    Future<void> setSwitches(
      WidgetTester tester,
      AppServices s, {
      required bool speed,
      required bool g,
    }) async {
      await tester.runAsync(() async {
        await s.settings.setSpeedDetection(speed);
        await s.settings.setGMeterEnabled(g);
        await s.settings.setGCalibration(g ? kStoredCalibration : null);
      });
      await tester.pump();
    }

    Future<void> feedDvol(WidgetTester tester) async {
      ble.emit(TelemetrySample(
        timestamp: DateTime(2026, 8, 7, 9, 30),
        pvlt: 13.2,
        svlt: 13.1,
        temperatureC: 31,
        dvol: const [3.30, 3.31, 3.29, 3.30],
      ));
      await tester.pump();
      await tester.pump();
    }

    Future<void> setRiding(WidgetTester tester, AppServices s) async {
      await tester.runAsync(() => s.devices.setDisplayLayout(
          'DEV-A', const DisplayLayout(watchface: Watchface.riding)));
    }

    double dy(WidgetTester tester, Finder f) => tester.getTopLeft(f.first).dy;

    testWidgets('speed on, G unavailable → speed card only', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await setSwitches(tester, s, speed: true, g: false);
      await setRiding(tester, s);
      await pumpUnder(
          tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(find.byType(SpeedCard), findsOneWidget);
      expect(find.byType(GForceCard), findsNothing);
      expect(find.byType(ReadoutsCard), findsNothing);
    });

    testWidgets('🔴 speed OFF, G available → the ball, and no speed card',
        (tester) async {
      // The leak this ruling exists to prevent, asserted where it would happen.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await setSwitches(tester, s, speed: false, g: true);
      await setRiding(tester, s);
      await pumpUnder(
          tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(find.byType(GForceCard), findsOneWidget,
          reason: 'the G meter alone keeps riding alive');
      expect(find.byType(SpeedCard), findsNothing,
          reason: 'a speed card here would open the GNSS stream with the '
              'location consent dialog never having been shown');
      // …and it is still not a copy of compact: the ball is the difference.
      expect(find.byType(PvltGauge), findsOneWidget);
      expect(find.byType(DvolBars), findsOneWidget);
      expect(find.byType(ReadoutsCard), findsNothing);
    });

    testWidgets('🔴 …and the GNSS gate stayed shut while it did', (tester) async {
      // The consequence, not just the layout. Condition 1 of the gate is driven
      // by a SpeedCard mounting; with no card it must never have opened.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await setSwitches(tester, s, speed: false, g: true);
      await setRiding(tester, s);
      await pumpUnder(
          tester, s, const PackScaffold(controls: BatteryControls()));
      await tester.pump();
      expect(s.speed.streaming, isFalse);
      expect(s.speed.permission, SpeedPermissionState.notRequested,
          reason: 'the OS was never asked, because nothing asked it');
    });

    testWidgets('both on → both cards, speed above the ball', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await setSwitches(tester, s, speed: true, g: true);
      await setRiding(tester, s);
      await pumpUnder(
          tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(find.byType(SpeedCard), findsOneWidget);
      expect(find.byType(GForceCard), findsOneWidget);
      expect(dy(tester, find.byType(SpeedCard)),
          lessThan(dy(tester, find.byType(GForceCard))));
      expect(dy(tester, find.byType(GForceCard)),
          lessThan(dy(tester, find.byType(PvltGauge))));
    });

    testWidgets('both off → standard, with its numbers grid back',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await setSwitches(tester, s, speed: false, g: false);
      await setRiding(tester, s);
      await pumpUnder(
          tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(find.byType(SpeedCard), findsNothing);
      expect(find.byType(GForceCard), findsNothing);
      expect(find.byType(ReadoutsCard), findsOneWidget,
          reason: 'the fallback is standard — a page identical to compact is '
              'what T2b exists to make unreachable');
    });

    testWidgets('a power bank gets the same treatment', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await setSwitches(tester, s, speed: false, g: true);
      await setRiding(tester, s);
      await pumpUnder(tester, s, const PowerBankView());

      expect(find.byType(GForceCard), findsOneWidget);
      expect(find.byType(SpeedCard), findsNothing);
    });

    testWidgets('🔴 switched ON but never calibrated shows NOTHING',
        (tester) async {
      // Design 0045 Q8, and the state design 0045 R1 expects to be the common
      // one. Not a greyed-out card, not a placeholder, not a hint: the module
      // is not laid out, so `riding` has nothing to be and falls back.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() async {
        await s.settings.setSpeedDetection(false);
        await s.settings.setGMeterEnabled(true);
        // Switch on, calibration absent — the exact half-configured state.
        await s.settings.setGCalibration(null);
      });
      await setRiding(tester, s);
      await pumpUnder(
          tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(s.gforce.enabled, isTrue);
      expect(s.gforce.available, isFalse);
      expect(find.byType(GForceCard), findsNothing);
      expect(find.byType(ReadoutsCard), findsOneWidget,
          reason: 'fell back to standard, because nothing was available');
    });

    testWidgets('an unreadable stored calibration is the same as none',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() async {
        await s.settings.setGMeterEnabled(true);
        // Orthonormal, unit length — and MIRRORED, which swaps left for right.
        await s.settings
            .setGCalibration('{"m":[1,0,0,0,-1,0,0,0,1],"at":0}');
      });
      await setRiding(tester, s);
      await pumpUnder(
          tester, s, const PackScaffold(controls: BatteryControls()));

      expect(s.gforce.available, isFalse);
      expect(find.byType(GForceCard), findsNothing);
    });

    testWidgets('calibrating makes the card appear without a restart',
        (tester) async {
      // The composition root's settings listener, end to end. Without it the
      // user would calibrate, return to the dashboard and see no change.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await setSwitches(tester, s, speed: false, g: false);
      await tester.runAsync(() => s.settings.setGMeterEnabled(true));
      await setRiding(tester, s);
      await pumpUnder(
          tester, s, const PackScaffold(controls: BatteryControls()));
      expect(find.byType(GForceCard), findsNothing);

      await tester
          .runAsync(() => s.settings.setGCalibration(kStoredCalibration));
      await tester.pump();
      expect(find.byType(GForceCard), findsOneWidget);
    });

    testWidgets('the picker offers riding when EITHER switch is available',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await setSwitches(tester, s, speed: false, g: true);
      await pumpUnder(
        tester,
        s,
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showWatchfaceSheet(context, deviceId: 'DEV-A'),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Riding'), findsOneWidget,
          reason: 'the G meter alone makes riding worth offering');
    });

    testWidgets('and withholds it when neither is', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await setSwitches(tester, s, speed: false, g: false);
      await pumpUnder(
        tester,
        s,
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showWatchfaceSheet(context, deviceId: 'DEV-A'),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Riding'), findsNothing);
    });
  });

  // =========================================================================
  // 🔴 The two callers that would have leaked
  // =========================================================================
  group('the home editor asks the right questions', () {
    late _FakeBleService ble;

    Future<AppServices> makeServices(WidgetTester tester) async {
      late final AppServices services;
      await tester.runAsync(() async {
        final appDb = await AppDatabase.open(
            path: inMemoryDatabasePath, factory: databaseFactoryFfi);
        ble = _FakeBleService();
        services = await AppServices.create(appDatabase: appDb, ble: ble);
        await services.devices.saveNew('DEV-A', 'unit A');
      });
      return services;
    }

    testWidgets('🔴 a G-only user is NOT offered a speed tile', (tester) async {
      // Hazard C. The editor used to ask `ridingSelectable`, which was the same
      // expression as "speed is on" by coincidence. Design 0045 Q3 widened
      // `ridingSelectable` to "speed OR G", and inheriting it here would have
      // offered a speed tile — which mounts a SpeedCard, which opens the GNSS
      // gate — to somebody who only ever turned the G meter on.
      //
      // Asserted on the PREDICATE the editor now calls rather than by driving
      // its bottom sheet, so the assertion names the decision rather than a
      // piece of chrome. The two are the same expression, verbatim, in
      // `home_editor_page.dart`.
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.runAsync(() => s.pending.drain());
        await s.dispose();
      });
      await tester.runAsync(() async {
        await s.settings.setSpeedDetection(false);
        await s.settings.setGMeterEnabled(true);
        await s.settings.setGCalibration(kStoredCalibration);
      });
      expect(s.gforce.available, isTrue);
      expect(ridingSelectable(s.settings.settings, gForceAvailable: true),
          isTrue,
          reason: 'riding IS offered — that is the widened predicate');
      expect(
        phoneModuleAvailable(DisplayModule.speed, s.settings.settings,
            gForceAvailable: true),
        isFalse,
        reason: 'but a speed TILE is not, and this is the difference the '
            'editor now asks about',
      );
    });

    test('🔴 no phone module is offered as a per-device tile', () {
      // Hazard D. The editor's per-device loop used to exclude `speed` with a
      // hardcoded `!=`, which would have let the G meter through as
      // "G meter · <battery name>" — a card bound to a unit that cannot
      // produce it. The exclusion is now the exhaustive predicate, so the NEXT
      // phone module cannot slip through either.
      for (final cls in ProductClass.values) {
        final offered = [
          for (final m in DisplayModule.values)
            if (!m.isPhoneModule && DisplayModules.forClass(cls).has(m)) m,
        ];
        expect(offered, isNot(contains(DisplayModule.speed)), reason: '$cls');
        expect(offered, isNot(contains(DisplayModule.gForce)), reason: '$cls');
        expect(offered, isNotEmpty,
            reason: '$cls — a guard that excluded everything would be vacuous');
      }
    });
  });

  // =========================================================================
  // The gate
  // =========================================================================
  group('GForceController gate', () {
    late GForceController c;

    setUp(() {
      c = GForceController(source: _SilentSensors())
        ..applySettings(const AppSettings(
            gMeterEnabled: true, gCalibration: kStoredCalibration));
    });

    tearDown(() => c.dispose());

    test('all three conditions are needed', () {
      expect(c.available, isTrue);
      expect(c.streaming, isFalse, reason: 'nothing is on screen yet');

      c.setFaceWantsGForce(true);
      expect(c.streaming, isFalse, reason: 'no surface is visible');

      c.setDashboardVisible(true);
      expect(c.streaming, isTrue);

      c.setAppResumed(false);
      expect(c.streaming, isFalse);
      c.setAppResumed(true);
      expect(c.streaming, isTrue);

      c.setDashboardVisible(false);
      expect(c.streaming, isFalse);
      c.setDetailVisible(true);
      expect(c.streaming, isTrue, reason: 'either surface counts');

      c.setFaceWantsGForce(false);
      expect(c.streaming, isFalse);
    });

    test('turning the switch off closes the stream immediately', () {
      c
        ..setFaceWantsGForce(true)
        ..setDashboardVisible(true);
      expect(c.streaming, isTrue);
      c.applySettings(const AppSettings(gCalibration: kStoredCalibration));
      expect(c.available, isFalse);
      expect(c.streaming, isFalse,
          reason: 'not left open for the frame it takes the card to unmount');
    });

    test('a new calibration clears an invalidation', () {
      expect(c.calibrated, isTrue);
      c.applySettings(const AppSettings(
          gMeterEnabled: true,
          gCalibration: '{"m":[0,1,0,-1,0,0,0,0,1],"at":1}'));
      expect(c.calibrated, isTrue);
      expect(c.calibrationInvalidated, isFalse);
    });

    test('the switch alone, with no calibration, is not availability', () {
      final d = GForceController(source: _SilentSensors())
        ..applySettings(const AppSettings(gMeterEnabled: true));
      addTearDown(d.dispose);
      expect(d.enabled, isTrue);
      expect(d.calibrated, isFalse);
      expect(d.available, isFalse);
    });
  });
}
