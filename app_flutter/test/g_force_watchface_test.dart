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
import 'package:open_smart_batt/ui/dashboard/g_force_card.dart';
import 'package:open_smart_batt/ui/dashboard/speed_card.dart';
import 'package:open_smart_batt/ui/dashboard/watchfaces.dart';
import 'package:open_smart_batt/ui/home/home_page.dart';
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
  // 📦 REPOINTED by design 0051 (2026-08-09). This group used to sweep the four
  // states of the `riding` WATCHFACE. Owner ruling A took both phone modules
  // off every face —「表盤不會有速度卡跟Ｇ值卡 這兩個應該只會在主頁出現」— so
  // the four states now live on the HOME grid, and `HomeLayout.renderedFor` is
  // the resolver that decides them.
  //
  // 🔴 The QUESTION is identical and the stakes are higher, not lower: this is
  // now the ONLY instance of design 0042's privacy chain (no module ⇒ no card
  // ⇒ no `setFaceWantsSpeed` ⇒ no stream). Before, a bug here still had the
  // watchface layer's copy of the same filter standing behind it.
  group('HomeLayout.renderedFor — the four states of the two phone tiles', () {
    const off = AppSettings();
    const speedOn = AppSettings(speedDetection: true);

    const battery = SavedDevice(
        id: 'DEV-A', alias: 'A', productClass: ProductClass.smartBattery);

    /// A grid holding both phone tiles plus one device tile, resolved.
    List<DisplayModule?> home(AppSettings s, {required bool g}) => const HomeLayout([
          HomeTile.module(DisplayModule.speed),
          HomeTile.module(DisplayModule.gForce),
          HomeTile.device('DEV-A'),
        ])
            .renderedFor(const [battery], s, gForceAvailable: g)
            .tiles
            .map((t) => t.module)
            .toList();

    test('speed on, G unavailable → the speed card, no ball', () {
      expect(home(speedOn, g: false), [DisplayModule.speed, null]);
    });

    test('🔴 speed OFF, G available → the ball, and NO speed card', () {
      // The state design 0045 introduced, and the reason the ruling was needed.
      // Laying `speed` out would mount a SpeedCard, which opens the GNSS
      // stream, for a user who never saw the location consent dialog.
      expect(home(off, g: true), [DisplayModule.gForce, null]);
    });

    test('both on → both cards, speed first', () {
      expect(home(speedOn, g: true),
          [DisplayModule.speed, DisplayModule.gForce, null]);
    });

    test('both off → neither tile, and the device card carries the page', () {
      // 📦 Was "the face falls back to standard entirely". There is no face to
      // fall back to; what stands in its place is T-new-2, the rule that the
      // home grid is never empty. The device card is what keeps it non-empty.
      expect(home(off, g: false), [null]);
    });

    test('no WATCHFACE draws either module, in any state', () {
      // What is left of the old assertions, in the form design 0051 leaves them
      // in: whatever the switches say, the dashboard has no phone card. The
      // export preamble depends on the same fact — `modules=` is printed from
      // the pure `watchfaceModules`, so a leftover `speed` would claim a GPS
      // card in every capture taken on any phone.
      for (final cls in ProductClass.values) {
        for (final f in Watchface.values) {
          for (final st in [off, speedOn]) {
            for (final g in [false, true]) {
              expect(renderedModules(cls, f, st, gForceAvailable: g),
                  watchfaceModules(cls, effectiveWatchface(cls, f)),
                  reason: '$cls / ${f.slug}');
              expect(
                  watchfaceModules(cls, f).where((m) => m.isPhoneModule),
                  isEmpty,
                  reason: '$cls / ${f.slug}');
            }
          }
        }
      }
    });
  });

  // ⚠️ VESTIGIAL since design 0051 — nothing selects a face any more. Kept
  // because the predicate is kept (see `watchfaces.dart`), and an untested
  // survivor is how the wrong expression comes back if a picker ever returns.
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
        // 🔴 THREE since design 0052. The group name says "the two that read no
        // device" and is now one short — kept as written because the PROPERTY
        // it guards is unchanged (a module is a phone module iff it reads no
        // device), and rewriting the sentence to "the three" would only make
        // the next reader do this arithmetic again. `clock` reads the phone's
        // own time-of-day, so it belongs here for `speed`'s exact reason.
        [DisplayModule.speed, DisplayModule.gForce, DisplayModule.clock],
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
  // The same four states, through the real HOME PAGE
  // =========================================================================
  //
  // 📦 REPOINTED by design 0051, not deleted. These used to pump `PackScaffold`
  // with a stored `riding` face. Ruling A moved both phone cards off the
  // dashboard, so the surface that draws them is the home grid — and the
  // assertions about the CONTROLLER (a switch on with no calibration is not
  // availability; calibrating must not need a restart) are exactly as
  // load-bearing there as they were here, because design 0045 R1 expects
  // "switched on, never calibrated" to be the common state.
  //
  // The two picker tests that used to close this group are gone with the
  // picker; what they protected — "unavailable is not offered" — is asserted on
  // the editor's own menu in the group below.
  group('the home page draws the four states', () {
    late _FakeBleService ble;

    Future<AppServices> makeServices(WidgetTester tester) async {
      late final AppServices services;
      await tester.runAsync(() async {
        final appDb = await AppDatabase.open(
            path: inMemoryDatabasePath, factory: databaseFactoryFfi);
        ble = _FakeBleService();
        services = await AppServices.create(appDatabase: appDb, ble: ble);
        await services.devices.saveNew('DEV-A', 'unit A');
        await services.devices
            .setProductClass('DEV-A', ProductClass.smartBattery);
        // Both phone tiles placed explicitly, so what is on screen is decided
        // by availability alone rather than by whatever `defaultFor` generates.
        await services.settings.setHomeLayout(const HomeLayout([
          HomeTile.module(DisplayModule.speed),
          HomeTile.module(DisplayModule.gForce),
          HomeTile.device('DEV-A'),
        ]).encode());
      });
      return services;
    }

    Future<void> teardown(WidgetTester tester, AppServices s) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => s.pending.drain());
      await s.dispose();
    }

    Future<void> pumpHome(WidgetTester tester, AppServices s) async {
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
            home: const Scaffold(body: HomePage()),
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

    double dy(WidgetTester tester, Finder f) => tester.getTopLeft(f.first).dy;

    testWidgets('speed on, G unavailable → speed card only', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await setSwitches(tester, s, speed: true, g: false);
      await pumpHome(tester, s);

      expect(find.byType(SpeedCard), findsOneWidget);
      expect(find.byType(GForceCard), findsNothing);
    });

    testWidgets('🔴 speed OFF, G available → the ball, and no speed card',
        (tester) async {
      // The leak this ruling exists to prevent, asserted where it would happen.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await setSwitches(tester, s, speed: false, g: true);
      await pumpHome(tester, s);

      expect(find.byType(GForceCard), findsOneWidget);
      expect(find.byType(SpeedCard), findsNothing,
          reason: 'a speed card here would open the GNSS stream with the '
              'location consent dialog never having been shown');
    });

    testWidgets('🔴 …and the GNSS gate stayed shut while it did', (tester) async {
      // The consequence, not just the layout. Condition 1 of the gate is driven
      // by a SpeedCard mounting; with no card it must never have opened.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await setSwitches(tester, s, speed: false, g: true);
      await pumpHome(tester, s);
      await tester.pump();

      expect(s.speed.streaming, isFalse);
      expect(s.speed.permission, SpeedPermissionState.notRequested,
          reason: 'the OS was never asked, because nothing asked it');
    });

    testWidgets('both on → both cards, speed above the ball', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await setSwitches(tester, s, speed: true, g: true);
      await pumpHome(tester, s);

      expect(find.byType(SpeedCard), findsOneWidget);
      expect(find.byType(GForceCard), findsOneWidget);
      expect(dy(tester, find.byType(SpeedCard)),
          lessThan(dy(tester, find.byType(GForceCard))));
    });

    testWidgets('both off → neither tile', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await setSwitches(tester, s, speed: false, g: false);
      await pumpHome(tester, s);

      expect(find.byType(SpeedCard), findsNothing);
      expect(find.byType(GForceCard), findsNothing);
      // …and the page is NOT empty, which is T-new-2. The device card is what
      // keeps it non-empty; a blank home screen is the one outcome the grid is
      // never allowed to reach.
      expect(find.text('unit A'), findsOneWidget);
    });

    testWidgets('🔴 switched ON but never calibrated shows NOTHING',
        (tester) async {
      // Design 0045 Q8, and the state design 0045 R1 expects to be the common
      // one. Not a greyed-out card, not a placeholder, not a hint: the module
      // is not laid out at all.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() async {
        await s.settings.setSpeedDetection(false);
        await s.settings.setGMeterEnabled(true);
        // Switch on, calibration absent — the exact half-configured state.
        await s.settings.setGCalibration(null);
      });
      await pumpHome(tester, s);

      expect(s.gforce.enabled, isTrue);
      expect(s.gforce.available, isFalse);
      expect(find.byType(GForceCard), findsNothing);
    });

    testWidgets('an unreadable stored calibration is the same as none',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() async {
        await s.settings.setGMeterEnabled(true);
        // Orthonormal, unit length — and MIRRORED, which swaps left for right.
        await s.settings
            .setGCalibration('{"m":[1,0,0,0,-1,0,0,0,1],"at":0}');
      });
      await pumpHome(tester, s);

      expect(s.gforce.available, isFalse);
      expect(find.byType(GForceCard), findsNothing);
    });

    testWidgets('calibrating makes the card appear without a restart',
        (tester) async {
      // The composition root's settings listener, end to end. Without it the
      // user would calibrate, return to the home page and see no change.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await setSwitches(tester, s, speed: false, g: false);
      await tester.runAsync(() => s.settings.setGMeterEnabled(true));
      await pumpHome(tester, s);
      expect(find.byType(GForceCard), findsNothing);

      await tester
          .runAsync(() => s.settings.setGCalibration(kStoredCalibration));
      await tester.pump();
      expect(find.byType(GForceCard), findsOneWidget);
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
        final entry = DisplayModules.forClass(cls);
        final offered = [
          for (final m in DisplayModule.values)
            if (!m.isPhoneModule && (entry?.has(m) ?? false)) m,
        ];
        expect(offered, isNot(contains(DisplayModule.speed)), reason: '$cls');
        expect(offered, isNot(contains(DisplayModule.gForce)), reason: '$cls');
        // 🔴 The vacuity guard, and its ONE exemption.
        //
        // `unknown` legitimately offers nothing at all since design 0050 D3 —
        // no class means no class-specific cards, so an empty list there is the
        // rule working rather than the guard being defeated. Every class that
        // IS a product must still offer something, or this test would pass by
        // excluding everything.
        if (cls == ProductClass.unknown) {
          expect(entry, isNull,
              reason: 'the empty list must come from D3, not from the '
                  'predicate quietly excluding a real class');
          continue;
        }
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
    });

    test('recalibrating while the card is up REBUILDS the open stream', () {
      // The failure this guards is silent: the new matrix drops the estimator,
      // and a subscription left open behind a null estimator delivers samples
      // that go nowhere. No error, no log — a card drawing zeros forever, on a
      // calibration the user has just been told is good.
      c
        ..setFaceWantsGForce(true)
        ..setDashboardVisible(true);
      expect(c.streaming, isTrue);
      c.applySettings(const AppSettings(
          gMeterEnabled: true,
          gCalibration: '{"m":[0,1,0,-1,0,0,0,0,1],"at":2}'));
      expect(c.streaming, isTrue,
          reason: 'still streaming — and on the NEW matrix, not on a dead '
              'subscription behind a discarded estimator');
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
