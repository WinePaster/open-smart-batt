// SpeedCard's continuous readout, through a rendered frame (design 0071 §3.7,
// R4).
//
// `speed_estimator_test.dart` owns the arithmetic — it can, because
// `displaySpeedMpsAt` is a pure function of an injected clock. What it cannot
// reach is the two things that only exist inside the widget:
//
//   * the WIRING. The estimator can be perfect and the card can still draw
//     `estimate.vSmoothMps`, which is precisely the stepped reading 0071 exists
//     to replace, and every estimator test would stay green. This project has
//     shipped that shape of defect three times (see `accelReadoutFor`'s
//     comment), so the mid-sweep value is asserted on the actual digits.
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

  testWidgets('🔴 mid-sweep the card draws the curve, not the arrival value',
      (tester) async {
    await mount(tester);
    expect(gps.streaming, isTrue,
        reason: 'precondition: the gate opened and the stream is live');

    // First sample seeds the average: 10 m/s = 36 km/h, and the curve out of a
    // re-seed is flat (§3.5 pin 5), so this is what is on screen for a second.
    await feed(tester, 10.0);
    expect(find.text('36'), findsOneWidget);

    // A second sample, 20 m/s. The RECORDED value it walks to is
    // 0.85·20 + 0.15·10 = 18.5 m/s = 66.6 km/h ⇒ "67". (α was 0.632 until the
    // 2026-08-19 field check; see `SpeedEstimatorConfig.alpha`.)
    clock.advance(const Duration(seconds: 1));
    await feed(tester, 20.0);
    expect(find.text('36'), findsOneWidget,
        reason: 'property 1: a sample landing must not move the digits by '
            'itself — the pre-0071 card jumped to 67 here');

    // Halfway through the period. v = 20 + (10 − 20)·0.15^0.5 = 16.13 m/s
    // = 58.1 km/h ⇒ "58". This is the assertion the whole design is for: the
    // old card showed 36 for the whole second and then 67; this one is passing
    // through 58 on its way.
    clock.advance(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('58'), findsOneWidget,
        reason: 'the card is drawing estimate.vSmoothMps (36 or 67) rather '
            'than the curve');

    // And it arrives exactly where the recorded series already is.
    clock.advance(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('67'), findsOneWidget);
    expect(
        formatSpeed(gps.current!.vSmoothMps, SpeedUnit.kmh), '67',
        reason: 'v_disp(t_k + T) == vSmoothMps — the drawn number and the '
            'recorded one are the same number at every sampling instant');
  });

  testWidgets('R4: unmounting stops the ticker rather than leaking it',
      (tester) async {
    await mount(tester);
    await feed(tester, 10.0);
    clock.advance(const Duration(seconds: 1));
    await feed(tester, 20.0);
    clock.advance(const Duration(milliseconds: 200));
    await tester.pump();
    // The card is mid-sweep, so its ticker is definitely running — without
    // this the test would pass on a card that never started one.
    expect(find.text('36'), findsNothing);
    expect(find.text('67'), findsNothing);

    await mount(tester, child: const SizedBox.shrink());
    // `SingleTickerProviderStateMixin.dispose` asserts on an undisposed active
    // ticker, so a missing `_ticker.dispose()` surfaces here as an exception
    // rather than as a silent leak.
    expect(tester.takeException(), isNull);
    expect(find.byType(SpeedCard), findsNothing);
  });
}
