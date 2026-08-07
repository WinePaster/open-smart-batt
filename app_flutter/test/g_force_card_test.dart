// design 0045 §3.6 / §3.5 — the card, and the settings flow that is the only
// way to reach it.
//
// The card's ABSENCE is pinned in `g_force_watchface_test.dart`, where the
// decision that removes it is made. This file is about what happens once it is
// there: that it shows what the controller measured, that mounting it is what
// opens the sensor gate, and that the peak readout is really a button.
//
// 🔴 The settings group at the bottom exists because of design 0045 R1. Q8 left
// the dashboard with nothing at all to say about a switched-on-but-uncalibrated
// G meter, so the consent-then-wizard flow and the status row beneath the
// switch carry the entire feature's guidance. If that flow can be entered and
// silently left half-done with no trace, the feature has no failure state a
// user can see — which is the risk the design names as its largest.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/g_force_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String kCal = '{"m":[1,0,0,0,1,0,0,0,1],"at":1754524800000}';

/// Sensors driven by hand, so a test can decide exactly what the phone "felt".
class _FakeSensors implements GForceSensorSource {
  final linearCtl = StreamController<Vec3>.broadcast();
  final rawCtl = StreamController<Vec3>.broadcast();
  int linearSubscriptions = 0;
  int rawSubscriptions = 0;

  @override
  Stream<Vec3> linear({required Duration samplingPeriod}) {
    linearSubscriptions++;
    return linearCtl.stream;
  }

  @override
  Stream<Vec3> raw({required Duration samplingPeriod}) {
    rawSubscriptions++;
    return rawCtl.stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('GForceCard', () {
    late _FakeSensors sensors;
    late GForceController controller;
    late DateTime clock;

    setUp(() {
      sensors = _FakeSensors();
      clock = DateTime.utc(2026, 8, 7, 9);
      controller = GForceController(source: sensors, now: () => clock)
        ..applySettings(
            const AppSettings(gMeterEnabled: true, gCalibration: kCal));
    });

    tearDown(() {
      controller.dispose();
      sensors.linearCtl.close();
      sensors.rawCtl.close();
    });

    Future<void> pumpCard(WidgetTester tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<GForceController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const Scaffold(body: GForceCard()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    /// Feed one linear sample and let the throttle pass.
    Future<void> feed(WidgetTester tester, Vec3 v) async {
      clock = clock.add(const Duration(milliseconds: 300));
      sensors.linearCtl.add(v);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('🔴 mounting the card is what opens the sensor gate',
        (tester) async {
      // Condition 1, driven by the widget's own lifecycle — the same mechanism
      // `SpeedCard` uses. This is what lets the controller have NO switch
      // condition of its own: if the card is here, the feature is on and
      // calibrated, because nothing else lays the module out.
      controller.setDashboardVisible(true);
      expect(controller.streaming, isFalse);

      await pumpCard(tester);
      expect(controller.streaming, isTrue);
      expect(sensors.linearSubscriptions, 1);
      expect(sensors.rawSubscriptions, 1,
          reason: 'raw is subscribed for the still-window validity check only');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(controller.streaming, isFalse,
          reason: 'and unmounting closes it — a sensor stream running for a '
              'card nobody can see is the defect the gate exists for');
    });

    testWidgets('it shows what was measured, with the direction in words',
        (tester) async {
      controller.setDashboardVisible(true);
      await pumpCard(tester);

      // 3 m/s² forward ≈ 0.31 g, accelerating.
      await feed(tester, const Vec3(3.0, 0, 0));
      expect(find.textContaining('+0.31'), findsWidgets);
      expect(find.textContaining('accel'), findsWidgets);

      // Braking is a MINUS and the other word — the case a sign-only readout
      // makes the rider decode at speed.
      controller.resetPeak();
      await feed(tester, const Vec3(-4.0, 0, 0));
      await feed(tester, const Vec3(-4.0, 0, 0));
      await feed(tester, const Vec3(-4.0, 0, 0));
      expect(find.textContaining('brake'), findsWidgets);
    });

    testWidgets('the peak is held, and tapping it zeroes it', (tester) async {
      // design 0045 Q5. Peaks never land and never cross a session; the tap is
      // the only way to clear one without the stream stopping.
      controller.setDashboardVisible(true);
      await pumpCard(tester);

      await feed(tester, const Vec3(-6.0, 0, 0));
      final peaked = controller.reading!.peakG;
      expect(peaked, greaterThan(0.5));

      // Value comes back down, peak does not.
      for (var i = 0; i < 40; i++) {
        await feed(tester, Vec3.zero);
      }
      expect(controller.reading!.peakG, peaked);
      expect(controller.reading!.longG.abs(), lessThan(0.05));

      await tester.tap(find.text('PEAK'));
      await tester.pump();
      expect(controller.reading!.peakG, 0.0);
    });

    testWidgets('it draws the ball, and the ball is context-free',
        (tester) async {
      controller.setDashboardVisible(true);
      await pumpCard(tester);
      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<GForceBallPainter>()
          .toList();
      expect(painters, hasLength(1));
      // Every colour arrives as a parameter (the `pvlt_gauge.dart` rule): a
      // painter that looked up the theme could not be exercised without a
      // whole widget tree, and the wizard reuses this one.
      expect(painters.single.dotColor, isNotNull);
      expect(painters.single.fullScaleG, 1.0);
    });

    testWidgets('the dot follows the vehicle frame, not the phone frame',
        (tester) async {
      // Up is acceleration and left is a left-hand corner. The card converts
      // once, here, so the painter has no opinion — and this is the assertion
      // that would fail if the conversion were dropped or inverted.
      controller.setDashboardVisible(true);
      await pumpCard(tester);
      await feed(tester, const Vec3(5.0, 0, 0));
      GForceBallPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<GForceBallPainter>()
          .single;
      expect(painter().dot.dy, lessThan(0), reason: 'accelerating draws UPWARD');

      controller.resetPeak();
      for (var i = 0; i < 40; i++) {
        await feed(tester, const Vec3(0, 5.0, 0));
      }
      expect(painter().dot.dx, lessThan(0),
          reason: 'a left-hand corner draws to the LEFT');
    });
  });

  // =========================================================================
  // The settings flow — the only route to a working G meter
  // =========================================================================
  group('the settings flow', () {
    late AppDatabase db;
    late SettingsController settings;

    setUp(() async {
      db = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      settings =
          SettingsController(SettingsRepo(db.db), history: HistoryRepo(db.db));
      await settings.load();
    });

    tearDown(() async {
      settings.dispose();
      await db.close();
    });

    test('the switch and the calibration are separate facts', () async {
      // Turning the feature OFF must not discard the calibration: the mount has
      // not moved because somebody switched a feature off, and making them redo
      // the wizard would punish trying it.
      await settings.setGMeterEnabled(true);
      await settings.setGCalibration(kCal);
      await settings.setGMeterEnabled(false);
      expect(settings.gCalibration, kCal);

      // …and clearing the calibration is not switching the feature off.
      await settings.setGMeterEnabled(true);
      await settings.setGCalibration(null);
      expect(settings.gMeterEnabled, isTrue);
      expect(settings.gCalibration, isNull);
    });

    test('a half-finished flow leaves a state the settings page can name',
        () async {
      // The R1 mitigation, at the data layer: "switched on, never calibrated"
      // is a distinct, detectable state — not indistinguishable from "off" and
      // not indistinguishable from "working". The settings row prints a
      // different sentence for each of the three.
      final c = GForceController(source: _FakeSensors());
      addTearDown(c.dispose);

      c.applySettings(settings.settings);
      expect(c.enabled, isFalse);
      expect(c.calibratedAt, isNull);

      await settings.setGMeterEnabled(true);
      c.applySettings(settings.settings);
      expect(c.enabled, isTrue, reason: 'consent was given');
      expect(c.calibrated, isFalse, reason: 'the wizard was not finished');
      expect(c.available, isFalse);

      await settings.setGCalibration(kCal);
      c.applySettings(settings.settings);
      expect(c.available, isTrue);
      expect(c.calibratedAt, isNotNull,
          reason: 'the row prints the date, so "I set this up before I moved '
              'the mount" is answerable without guessing');
    });

    test('a completed wizard produces something the settings layer can store',
        () {
      // The wizard hands its result to `SettingsController`, not to the
      // controller that produced it — one writer, see `g_force_controller.dart`.
      // This pins the round trip that flow depends on.
      final session = CalibrationSession()..start();
      var t = DateTime.utc(2026, 8, 7);
      for (var i = 0; i < 170; i++) {
        t = t.add(const Duration(milliseconds: 20));
        session.addLinearSample(Vec3.zero, t);
        session.addRawSample(const Vec3(0, 0, 9.80665), t);
      }
      for (var i = 0; i < 80; i++) {
        t = t.add(const Duration(milliseconds: 20));
        session.addLinearSample(const Vec3(2.0, 0, 0), t);
      }
      expect(session.phase, CalibrationPhase.complete);

      final encoded = session.result!.encode();
      final c = GForceController(source: _FakeSensors())
        ..applySettings(
            AppSettings(gMeterEnabled: true, gCalibration: encoded));
      addTearDown(c.dispose);
      expect(c.available, isTrue);
    });
  });
}
