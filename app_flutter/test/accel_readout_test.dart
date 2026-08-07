// The acceleration sub-readout on SpeedCard (design 0044 Phase H / §3.3-§3.4,
// Q1 ruling (b): a line under the speed, not a card of its own).
//
// 🔴 The claim under test is mostly about what is NOT drawn. Warming and
// suppressed both render NOTHING — not `0.0`, not `--` — because a rider cannot
// tell a displayed zero from a measured one, and design 0044 G2 is precisely
// about not letting an unmeasured number look measured. Every "findsNothing"
// below is that rule.
//
// The gate is tested twice over and on purpose:
//   * [accelReadoutFor] directly, because the decision has to be reachable
//     without a rendered frame — this project has three times shipped a defect
//     that lived at a CALL SITE while the callee's own tests stayed green;
//   * through the widget, with a controller reporting combinations the real one
//     cannot easily be pushed into (a held speed WITH a live acceleration),
//     because that is the pairing the rule exists to forbid.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/accel_estimator.dart';
import 'package:open_smart_batt/state/gps_speed_controller.dart';
import 'package:open_smart_batt/state/settings_controller.dart';
import 'package:open_smart_batt/state/speed_estimator.dart';
import 'package:open_smart_batt/ui/dashboard/speed_card.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A controller that reports exactly what a test asks it to.
///
/// Subclassing rather than faking the whole seam, so the widget still talks to
/// the real type and the real `notifyListeners`. The point is to reach state
/// COMBINATIONS the estimator will not produce on demand — the forbidden one
/// being a held speed with an acceleration still beside it.
class _StubGps extends GpsSpeedController {
  _StubGps() : super(source: _DeadSource());

  SpeedEstimate? _current;
  AccelEstimate? _accel;
  SpeedPermissionState _perm = SpeedPermissionState.granted;

  @override
  SpeedEstimate? get current => _current;

  @override
  AccelEstimate? get currentAccel => _accel;

  @override
  SpeedPermissionState get permission => _perm;

  void report({
    required SpeedState state,
    double vMps = 12.0,
    double? aMps2,
    DateTime? at,
  }) {
    final t = at ?? DateTime.utc(2026, 8, 7, 10);
    _current = SpeedEstimate(
      t: t,
      vSmoothMps: vMps,
      state: state,
      quality: SpeedSignalQuality.good,
      lastLiveAt: t,
    );
    _accel = aMps2 == null ? null : AccelEstimate(t: t, aMps2: aMps2);
    notifyListeners();
  }

  set permissionState(SpeedPermissionState s) {
    _perm = s;
    notifyListeners();
  }
}

/// Never produces a fix; the stub above supplies the readings directly.
class _DeadSource implements SpeedLocationSource {
  const _DeadSource();

  @override
  Stream<SpeedFix> fixes() => const Stream<SpeedFix>.empty();

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

  group('the gate, without a frame', () {
    final a = AccelEstimate(t: DateTime.utc(2026, 8, 7, 10), aMps2: 1.4);

    test('a live speed with a live acceleration renders it', () {
      expect(accelReadoutFor(SpeedState.live, a), same(a));
    });

    test('🔴 a held or lost speed renders no acceleration at all', () {
      // The pairing G2 forbids: the big number is frozen and marked as frozen,
      // and an acceleration beside it would be describing a moment the speed
      // has already stopped describing.
      expect(accelReadoutFor(SpeedState.holding, a), isNull);
      expect(accelReadoutFor(SpeedState.lost, a), isNull);
    });

    test('warming and suppressed arrive as null and stay null', () {
      expect(accelReadoutFor(SpeedState.live, null), isNull);
      expect(accelReadoutFor(SpeedState.holding, null), isNull);
    });
  });

  group('formatting (§3.3, Q5)', () {
    test('the sign is always explicit, and zero has none', () {
      expect(formatAccel(1.0, SpeedUnit.kmh), startsWith('+'));
      expect(formatAccel(-1.0, SpeedUnit.kmh), startsWith('-'));
      expect(formatAccel(0.0, SpeedUnit.kmh), '0.0');
      // Inside the deadband, which is a DISPLAY decision — the same value still
      // reaches history unrounded.
      expect(formatAccel(-0.05, SpeedUnit.kmh), '0.0',
          reason: 'a rounded-away minus reads as a measured deceleration');
    });

    test('the unit follows the speed preference and nothing else', () {
      expect(accelUnitLabel(SpeedUnit.kmh), 'km/h/s');
      expect(accelUnitLabel(SpeedUnit.mph), 'mph/s');
      // 1 m/s² = 3.6 km/h per second = 2.237 mph per second.
      expect(formatAccel(1.0, SpeedUnit.kmh), '+3.6');
      expect(formatAccel(1.0, SpeedUnit.mph), '+2.2');
    });

    test('the displayed value is quantised; the recorded one is not', () {
      // 1.24 and 1.16 both snap to 1.2 m/s² for the screen — that is the whole
      // anti-flicker mechanism — while `AccelEstimator.estimates` carries both
      // unchanged (pinned in accel_estimator_test.dart).
      expect(formatAccel(1.24, SpeedUnit.kmh), formatAccel(1.16, SpeedUnit.kmh));
      expect(displayAccel(1.24), isNot(1.24));
    });
  });

  group('on screen', () {
    late AppDatabase db;
    late SettingsController settings;

    setUp(() async {
      db = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      settings = SettingsController(SettingsRepo(db.db));
      await settings.load();
    });

    tearDown(() async {
      settings.dispose();
      await db.close();
    });

    Future<void> pumpCard(WidgetTester tester, _StubGps gps) async {
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
            home: const Scaffold(body: SpeedCard()),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a live reading carries the acceleration under it',
        (tester) async {
      final gps = _StubGps();
      addTearDown(gps.dispose);
      gps.report(state: SpeedState.live, vMps: 12.0, aMps2: 1.0);
      await pumpCard(tester, gps);

      expect(find.text('Accel'), findsOneWidget);
      expect(find.text('+3.6'), findsOneWidget);
      expect(find.text('km/h/s'), findsOneWidget);
      expect(find.byIcon(Icons.trending_up), findsOneWidget);
    });

    testWidgets('braking reads as a negative number and a down arrow',
        (tester) async {
      final gps = _StubGps();
      addTearDown(gps.dispose);
      gps.report(state: SpeedState.live, aMps2: -2.0);
      await pumpCard(tester, gps);

      expect(find.text('-7.2'), findsOneWidget);
      expect(find.byIcon(Icons.trending_down), findsOneWidget);
      expect(find.byIcon(Icons.trending_up), findsNothing);
    });

    testWidgets('🔴 warming shows no row — not a zero, not a dash',
        (tester) async {
      // The two seconds after the speed appears. The speed card is fully
      // populated; the acceleration simply is not there yet.
      final gps = _StubGps();
      addTearDown(gps.dispose);
      gps.report(state: SpeedState.live, vMps: 12.0);
      await pumpCard(tester, gps);

      expect(find.textContaining('43'), findsOneWidget,
          reason: '12 m/s is still shown — only the sub-readout is missing');
      expect(find.text('Accel'), findsNothing);
      expect(find.text('km/h/s'), findsNothing);
      expect(find.text('0.0'), findsNothing);
      expect(find.text('--'), findsNothing);
    });

    testWidgets('🔴 a held speed drops the row even if a value is offered',
        (tester) async {
      // The state the real controller refuses to produce, asserted here anyway:
      // if a future change lets an acceleration outlive the live speed, the
      // card must still not draw it beside a frozen number.
      final gps = _StubGps();
      addTearDown(gps.dispose);
      gps.report(state: SpeedState.holding, vMps: 12.0, aMps2: 1.0);
      await pumpCard(tester, gps);

      expect(find.text('Held'), findsOneWidget);
      expect(find.text('Accel'), findsNothing);
      expect(find.text('+3.6'), findsNothing);
    });

    testWidgets('a lost signal has no acceleration either', (tester) async {
      final gps = _StubGps();
      addTearDown(gps.dispose);
      gps.report(state: SpeedState.lost, vMps: 12.0, aMps2: 1.0);
      await pumpCard(tester, gps);

      expect(find.text('No signal'), findsOneWidget);
      expect(find.text('Accel'), findsNothing);
    });

    testWidgets('switching to mph switches the acceleration unit with it',
        (tester) async {
      // Q5: no preference of its own. One switch moves both readings.
      final gps = _StubGps();
      addTearDown(gps.dispose);
      gps.report(state: SpeedState.live, aMps2: 1.0);
      await pumpCard(tester, gps);
      expect(find.text('km/h/s'), findsOneWidget);

      // Through `runAsync`: this is a real write to a real database, and a
      // widget test's fake clock never lets it complete otherwise.
      await tester.runAsync(() => settings.setSpeedUnit(SpeedUnit.mph));
      await tester.pump();
      expect(find.text('mph/s'), findsOneWidget);
      expect(find.text('+2.2'), findsOneWidget);
      expect(find.text('km/h/s'), findsNothing);
    });

    testWidgets('the row appears and disappears without moving the speed',
        (tester) async {
      // Q1 (b)'s stated advantage over a card of its own. If the big number
      // jumped every time the acceleration came and went, the sub-readout would
      // be worse than nothing on a moving vehicle (G4).
      final gps = _StubGps();
      addTearDown(gps.dispose);
      gps.report(state: SpeedState.live, vMps: 12.0);
      await pumpCard(tester, gps);
      final without = tester.getTopLeft(find.text('43'));

      gps.report(state: SpeedState.live, vMps: 12.0, aMps2: 1.0);
      await tester.pump();
      expect(find.text('Accel'), findsOneWidget);
      expect(tester.getTopLeft(find.text('43')), without);
    });

    testWidgets('a permission refusal still explains itself', (tester) async {
      // Regression guard on the card's own precedence: the acceleration row
      // must not have introduced a path that renders a number where design
      // 0034 §4.3 requires words.
      final gps = _StubGps();
      addTearDown(gps.dispose);
      gps.report(state: SpeedState.live, aMps2: 1.0);
      gps.permissionState = SpeedPermissionState.denied;
      await pumpCard(tester, gps);

      expect(find.text('No location permission'), findsOneWidget);
      expect(find.text('Accel'), findsNothing);
    });
  });
}
