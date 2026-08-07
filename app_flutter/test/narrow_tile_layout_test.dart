// 🔴 The phone's own cards, at the width a 1x1 home tile actually gives them.
//
// Reported from the field on v0.7.8 (2026-08-07) as「這排版實在是」: the G meter
// in a half tile broke each reading ACROSS TWO LINES — `+0.` above `00`. Not
// merely ugly; a G value split over two lines is briefly readable as a
// different number.
//
// Both cards were designed and tested at the width of the `riding` watchface,
// which is the whole page. Nothing ever rendered them narrow, so nothing ever
// saw it — the same shape as every other defect this project has shipped: the
// INPUT to the layout (how much room there is) had no test looking at it.
//
// The width below is derived, not guessed, and the derivation is the reason
// this file can be trusted after a padding change:
//
//   HomePage's ConstrainedBox   maxWidth 560
//   ListView padding            −15 left −15 right      → 530
//   Row of two Expanded         ÷2                      → 265
//
// 265 is therefore the REAL slot. `kTight` goes below it because
// `home_editor_page.dart` lets a user set any tile to 1x1 on a small phone,
// where the ConstrainedBox never binds and the slot is narrower still.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/g_force_card.dart';
import 'package:open_smart_batt/ui/dashboard/speed_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The width one half of a home-grid row really gets. See the header.
const double kHalfTile = 265;

/// A deliberately cruel slot: a 320 pt phone, halved.
const double kTight = 150;

/// One line of the G readout's 22 px type at `height: 1.1`, plus slack for
/// rounding. Two lines would be ~48 — which is exactly what the field photo
/// showed, so this threshold separates the defect from the fix rather than
/// being a round number someone liked.
const double kOneLineMax = 30;

const String kCal = '{"m":[1,0,0,0,1,0,0,0,1],"at":1754524800000}';

class _DeadSensors implements GForceSensorSource {
  @override
  Stream<Vec3> linear({required Duration samplingPeriod}) =>
      const Stream<Vec3>.empty();

  @override
  Stream<Vec3> raw({required Duration samplingPeriod}) =>
      const Stream<Vec3>.empty();
}

class _StubGps extends GpsSpeedController {
  _StubGps() : super(source: const _DeadSource());

  SpeedEstimate? _current;
  AccelEstimate? _accel;

  @override
  SpeedEstimate? get current => _current;

  @override
  AccelEstimate? get currentAccel => _accel;

  @override
  SpeedPermissionState get permission => SpeedPermissionState.granted;

  void report(double vMps, {double? aMps2}) {
    final t = DateTime.utc(2026, 8, 7, 10);
    _current = SpeedEstimate(
      t: t,
      vSmoothMps: vMps,
      state: SpeedState.live,
      quality: SpeedSignalQuality.good,
      lastLiveAt: t,
      speedAccuracyMps: 0.8,
    );
    _accel = aMps2 == null ? null : AccelEstimate(t: t, aMps2: aMps2);
    notifyListeners();
  }
}

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

  group('the G meter in a 1x1 tile', () {
    late GForceController g;

    setUp(() {
      g = GForceController(source: _DeadSensors())
        ..applySettings(
            const AppSettings(gMeterEnabled: true, gCalibration: kCal));
    });

    tearDown(() => g.dispose());

    Future<void> pump(WidgetTester tester, double width) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<GForceController>.value(
          value: g,
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: width, child: const GForceCard()),
              ),
            ),
          ),
        ),
      );
      g.setDashboardVisible(true);
      await tester.pump();
      await tester.pump();
    }

    for (final width in [kHalfTile, kTight]) {
      testWidgets('🔴 no reading is broken across two lines at ${width}px',
          (tester) async {
        await pump(tester, width);

        // All three readouts are at their resting value, which is the exact
        // string the field photo showed split in half.
        final values = find.text('+0.00');
        expect(values, findsWidgets, reason: 'the numbers must be on screen '
            'for their height to mean anything');
        for (var i = 0; i < tester.widgetList(values).length; i++) {
          expect(tester.getSize(values.at(i)).height, lessThan(kOneLineMax),
              reason: 'readout $i wrapped: a two-line height at ${width}px is '
                  'the v0.7.8 defect');
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('and the full-width rendering is untouched', (tester) async {
      // scaleDown only shrinks when it must. The riding watchface is where this
      // card was designed, and this pins that the fix costs nothing there —
      // 22 px type, full size, exactly as before.
      await pump(tester, 530);
      final size = tester.getSize(find.text('+0.00').first);
      expect(size.height, lessThan(kOneLineMax));
      expect(size.height, greaterThan(20),
          reason: 'at full width the number must NOT have been shrunk');
    });
  });

  group('the speed card in a 1x1 tile', () {
    late AppDatabase db;
    late SettingsController settings;
    late _StubGps gps;

    setUp(() async {
      db = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      settings = SettingsController(SettingsRepo(db.db));
      await settings.load();
      gps = _StubGps();
    });

    tearDown(() async {
      gps.dispose();
      settings.dispose();
      await db.close();
    });

    Future<void> pump(WidgetTester tester, double width) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GpsSpeedController>.value(value: gps),
            ChangeNotifierProvider<SettingsController>.value(value: settings),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: width, child: const SpeedCard()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    for (final width in [kHalfTile, kTight]) {
      testWidgets('🔴 a three-digit speed does not overflow at ${width}px',
          (tester) async {
        // 52 px digits + the unit + the quality pill in one Row. Three digits
        // is not a corner case on a motorbike, and an overflow here is the
        // striped bar across the reading the rider is looking at.
        gps.report(120 / 3.6, aMps2: 1.4);
        await pump(tester, width);
        expect(find.text('120'), findsOneWidget);
        expect(tester.takeException(), isNull,
            reason: 'a RenderFlex overflow at ${width}px');
      });
    }
  });
}
