// SpeedCard's continuous readout, through a rendered frame (design 0073 §3.10;
// design 0071 §3.7 / R4 for the ticker, which 0073 did not change).
//
// 🔵 Renamed from `speed_display_curve_widget_test.dart` on 2026-08-19: there
// is no curve any more. Design 0071 swept the reading from the previous
// smoothed value to the new one over a whole second; design 0073 replaced that
// with `level + k·slope·Δ`, which does not sweep anywhere — it is already where
// the trend says the vehicle is. The file was renamed rather than left with a
// stale name because this project has one of those already
// (`fb-registry/fb-50-60.md`, whose contents outgrew its name years of edits
// ago and which nobody now dares rename).
//
// `speed_estimator_test.dart` owns the arithmetic and the five clamps, and
// `speed_trend_extrapolation_test.dart` owns the assembly at controller level.
// What neither can reach is the two things that only exist inside the widget:
//
//   * the WIRING. The estimator can be perfect and the card can still draw
//     `estimate.vSmoothMps`, which is precisely the un-extrapolated reading
//     0073 exists to replace, and every estimator test would stay green. This
//     project has shipped that shape of defect three times (see
//     `accelReadoutFor`'s comment), so the between-samples value is asserted on
//     the actual digits.
//   * the TICKER'S LIFETIME (R4). A `Ticker` that outlives its `State` calls
//     `setState` on a defunct element for the life of the process;
//     `aligned_ticker.dart` carries the same warning because the project has
//     paid for it once already.
//
// The clock is injected into the controller, so "half a second later" is a
// statement rather than a race.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/gps_speed_controller.dart';
import 'package:open_smart_batt/state/settings_controller.dart';
import 'package:open_smart_batt/state/speed_estimator.dart';
import 'package:open_smart_batt/ui/dashboard/speed_card.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Hand-driven clock, same shape as `speed_estimator_test.dart`'s.
class _Clock {
  _Clock(this.t);
  DateTime t;
  void advance(Duration d) => t = t.add(d);
}

/// A location source the test pushes fixes into by hand.
///
/// The REAL [GpsSpeedController] and the REAL [SpeedEstimator] are used on
/// purpose: the claim under test is that the card reads the estimator's curve,
/// and a stub controller that answered `displaySpeedMpsNow` itself would be
/// asserting the test's own arithmetic.
class _HandFedSource implements SpeedLocationSource {
  final _fixes = StreamController<SpeedFix>.broadcast();

  void push(SpeedFix f) => _fixes.add(f);
  Future<void> close() => _fixes.close();

  @override
  Stream<SpeedFix> fixes() => _fixes.stream;

  @override
  Future<SpeedPermissionState> status() async => SpeedPermissionState.granted;

  @override
  Future<SpeedPermissionState> request() async => SpeedPermissionState.granted;

  @override
  Future<void> openSystemSettings() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late SettingsController settings;
  late _Clock clock;
  late _HandFedSource source;
  late GpsSpeedController gps;

  final t0 = DateTime.utc(2026, 8, 19, 9, 30);

  setUp(() async {
    db = await AppDatabase.open(
        path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    settings = SettingsController(SettingsRepo(db.db));
    await settings.load();
    clock = _Clock(t0);
    source = _HandFedSource();
    gps = GpsSpeedController(source: source, now: () => clock.t);
  });

  tearDown(() async {
    gps.dispose();
    await source.close();
    settings.dispose();
    await db.close();
  });

  Future<void> mount(WidgetTester tester, {Widget? child}) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GpsSpeedController>.value(value: gps),
          ChangeNotifierProvider<SettingsController>.value(value: settings),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: child ?? const SpeedCard()),
        ),
      ),
    );
    // Condition 3 of the gate; condition 1 is set by the card's own post-frame
    // callback, which is why this needs a second frame to take effect.
    gps.setDashboardVisible(true);
    await tester.pump();
    await tester.pump();
  }

  /// Push a fix stamped now and let the stream deliver it.
  Future<void> feed(WidgetTester tester, double mps) async {
    source.push(SpeedFix(
      speedMps: mps,
      horizontalAccuracyM: 5.0,
      timestamp: clock.t,
    ));
    // Twice: the broadcast stream delivers on a later microtask, so the first
    // pump is what lets the estimator see the fix and the second is what draws
    // the frame that resulted.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('🔴 between samples the card draws the trend, not the level',
      (tester) async {
    await mount(tester);
    expect(gps.streaming, isTrue,
        reason: 'precondition: the gate opened and the stream is live');

    // A 3 m/s² launch sampled at 1 Hz: 10, 13, 16, 19 m/s. Every number below
    // is arithmetic anyone can redo, and all of it is written out so a failure
    // says WHICH step moved rather than "expected 57".
    //
    //   levels (α = 0.85)   10  →  12.55  →  15.4825  →  18.472375
    //   slope at t=2 s      OLS through (0,10) (1,12.55) (2,15.4825) = 2.74125
    //   Δ at the fix        T(1−α)/α = 0.176471 s   (the fix is stamped now)
    //   compensation        k·slope·Δ = 0.7 · 2.74125 · Δ

    // First sample seeds the average: 10 m/s = 36 km/h. The acceleration window
    // is still warming, so there is no trend and the card shows the level.
    await feed(tester, 10.0);
    expect(find.text('36'), findsOneWidget);

    // Second: level 12.55 = 45.2 km/h. Two samples span one second, which is
    // short of design 0044's T_w − T_slack, so still no trend (C3①).
    clock.advance(const Duration(seconds: 1));
    await feed(tester, 13.0);
    expect(find.text('45'), findsOneWidget);
    expect(gps.trendSlopeMps2, isNull);

    // Third: the window is full. Level 15.4825 = 55.7 km/h ⇒ "56" on its own;
    // with the trend it is 15.4825 + 0.7·2.74125·0.176471 = 15.8211 = 57.0 km/h.
    // 🔴 THIS IS THE ASSERTION THE WHOLE DESIGN IS FOR: the card is ahead of
    // the level the instant the sample lands, rather than starting a journey
    // towards it.
    clock.advance(const Duration(seconds: 1));
    await feed(tester, 16.0);
    expect(gps.trendSlopeMps2, closeTo(2.74125, 1e-9));
    expect(find.text('57'), findsOneWidget,
        reason: 'the card is drawing the plain level (56) rather than the '
            'extrapolated reading');

    // Half a second on, with no new sample at all: Δ = 0.676471 ⇒ 16.7805 m/s
    // = 60.4 km/h. The old stepped card sat on one number for a whole second
    // and 0071's ramp was still walking towards it; this one is following the
    // trend it already measured.
    clock.advance(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('60'), findsOneWidget);

    // Just before the next sample: Δ = 1.176471 ⇒ 17.7399 m/s = 63.9 km/h.
    clock.advance(const Duration(milliseconds: 499));
    await tester.pump();
    expect(find.text('64'), findsOneWidget);

    // And the fourth sample lands almost exactly where the reading already was
    // — 18.4724 + 0.7·2.96119·0.176471 = 18.8382 = 67.8 km/h ⇒ "68" against the
    // 64 on screen. 🔑 That is design 0073 G1: the new sample pushes `level` up
    // one step and resets Δ to nearly nothing at the same instant, and the two
    // changes nearly cancel. The 4 km/h that is left is the `1 − k` discount,
    // not a "count up" — the pre-0071 card hopped 56 → 67 here, eleven km/h in
    // one frame and then nothing for a second.
    clock.advance(const Duration(milliseconds: 1));
    await feed(tester, 19.0);
    expect(find.text('68'), findsOneWidget);
    expect(formatSpeed(gps.current!.vSmoothMps, SpeedUnit.kmh), '67',
        reason: 'and the RECORDED value is a different number — 0073 §3.9: '
            'this is the first time the drawn value has not been on the series '
            'design 0044 differentiates, and it has to stay visible in a test');
  });

  testWidgets('R4: unmounting stops the ticker rather than leaking it',
      (tester) async {
    await mount(tester);
    await feed(tester, 10.0);
    clock.advance(const Duration(seconds: 1));
    await feed(tester, 13.0);
    clock.advance(const Duration(seconds: 1));
    await feed(tester, 16.0);
    clock.advance(const Duration(milliseconds: 200));
    await tester.pump();
    // The reading is moving between samples, so the ticker is definitely
    // running — without this the test would pass on a card that never started
    // one. 15.4825 + 0.7·2.74125·0.376471 = 16.2049 m/s = 58.3 km/h.
    expect(find.text('58'), findsOneWidget);
    expect(find.text('56'), findsNothing);
    expect(find.text('57'), findsNothing);

    await mount(tester, child: const SizedBox.shrink());
    // `SingleTickerProviderStateMixin.dispose` asserts on an undisposed active
    // ticker, so a missing `_ticker.dispose()` surfaces here as an exception
    // rather than as a silent leak.
    expect(tester.takeException(), isNull);
    expect(find.byType(SpeedCard), findsNothing);
  });
}
