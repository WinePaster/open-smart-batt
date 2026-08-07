// GpsSpeedController — the lifecycle gate and the permission flow
// (design 0042 Phase B / §3.4 / §3.5).
//
// The gate is the whole of G4. Continuous GNSS costs an order of magnitude more
// battery than the BLE link this app already holds open, and every one of the
// three conditions below is a case where the stream would otherwise keep
// running with nobody able to see the number. "It stops when you leave the
// dashboard" is a claim; these are the tests that make it one we can support.
//
// The location plugin is behind [SpeedLocationSource] so all of that is
// reachable without a GNSS chip.
import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/state/accel_estimator.dart';
import 'package:open_smart_batt/state/gps_speed_controller.dart';
import 'package:open_smart_batt/state/speed_estimator.dart';

class _Clock {
  _Clock(this.t);
  DateTime t;
  void advance(Duration d) => t = t.add(d);
}

class _FakeSource implements SpeedLocationSource {
  _FakeSource({this.grant = SpeedPermissionState.granted});

  /// What [status]/[request] report.
  SpeedPermissionState grant;

  int subscribes = 0;
  int cancels = 0;
  int statusReads = 0;
  int requests = 0;
  int settingsOpens = 0;

  StreamController<SpeedFix>? _controller;

  void emit(SpeedFix f) => _controller!.add(f);
  void breakStream(Object error) => _controller!.addError(error);

  @override
  Stream<SpeedFix> fixes() {
    final c = StreamController<SpeedFix>();
    c.onListen = () {
      subscribes++;
    };
    c.onCancel = () {
      cancels++;
      _controller = null;
    };
    _controller = c;
    return c.stream;
  }

  @override
  Future<SpeedPermissionState> status() async {
    statusReads++;
    return grant;
  }

  @override
  Future<SpeedPermissionState> request() async {
    requests++;
    return grant;
  }

  @override
  Future<void> openSystemSettings() async => settingsOpens++;
}

SpeedFix _fix(DateTime at, double mps) => SpeedFix(
      speedMps: mps,
      horizontalAccuracyM: 5.0,
      timestamp: at,
    );

void main() {
  final t0 = DateTime.utc(2026, 8, 7, 10);

  ({_Clock clock, _FakeSource src, GpsSpeedController ctl}) build({
    SpeedPermissionState grant = SpeedPermissionState.granted,
    Duration tick = const Duration(milliseconds: 5),
  }) {
    final clock = _Clock(t0);
    final src = _FakeSource(grant: grant);
    return (
      clock: clock,
      src: src,
      ctl: GpsSpeedController(
        source: src,
        now: () => clock.t,
        tickInterval: tick,
      ),
    );
  }

  /// Open all three gate conditions and let the async permission read settle.
  Future<void> openGate(GpsSpeedController c) async {
    c
      ..setFaceWantsSpeed(true)
      ..setDashboardVisible(true)
      ..setAppResumed(true);
    await pumpEventQueue();
  }

  group('the three-condition gate (§3.4)', () {
    test('no stream until all three conditions hold', () async {
      final (:clock, :src, :ctl) = build();
      expect(ctl.streaming, isFalse);

      ctl.setFaceWantsSpeed(true);
      await pumpEventQueue();
      expect(ctl.streaming, isFalse, reason: 'face alone is not enough');

      ctl.setDashboardVisible(true);
      await pumpEventQueue();
      expect(ctl.streaming, isTrue,
          reason: 'resumed defaults true — the app starts in the foreground');
      expect(src.subscribes, 1);
      ctl.dispose();
    });

    test('each condition going false cancels the stream on its own', () async {
      for (final close in <void Function(GpsSpeedController)>[
        (c) => c.setFaceWantsSpeed(false),
        (c) => c.setDashboardVisible(false),
        (c) => c.setAppResumed(false),
      ]) {
        final (:clock, :src, :ctl) = build();
        await openGate(ctl);
        expect(ctl.streaming, isTrue);

        close(ctl);
        // Synchronous on purpose: a cancel that sits behind an await is a
        // stream that keeps running after the user left the screen.
        expect(ctl.streaming, isFalse);
        await pumpEventQueue();
        expect(src.cancels, 1);
        ctl.dispose();
      }
    });

    test('reopening the gate starts a fresh subscription', () async {
      final (:clock, :src, :ctl) = build();
      await openGate(ctl);
      ctl.setDashboardVisible(false);
      await pumpEventQueue();
      ctl.setDashboardVisible(true);
      await pumpEventQueue();
      expect(ctl.streaming, isTrue);
      expect(src.subscribes, 2);
      ctl.dispose();
    });

    // ---------------------------------------------------------------------
    // design 0046 Step 8c — condition 3 has TWO producers now.
    //
    // Before design 0046 the only surface that could carry a speed card was the
    // dashboard TAB, so one tab-derived flag said everything. After it, the
    // dashboard lives inside a PUSHED route (the device detail page) while the
    // tab underneath is 裝置, and the home grid can carry a speed card of its
    // own. With one flag the gate would have stayed SHUT for exactly as long as
    // the user was on the page showing speed — a card stuck on "waiting for a
    // fix", no error anywhere, and a user concluding their GPS was broken.
    // ---------------------------------------------------------------------
    test('a speed tile on the home page opens the GPS gate', () async {
      final (:clock, :src, :ctl) = build();
      ctl
        ..setFaceWantsSpeed(true)
        ..setDashboardVisible(true);
      await pumpEventQueue();
      expect(ctl.streaming, isTrue);
      expect(ctl.speedSurfaceVisible, isTrue);
      ctl.dispose();
    });

    test('so does a detail page pushed over another tab', () async {
      final (:clock, :src, :ctl) = build();
      ctl
        ..setFaceWantsSpeed(true)
        // The shell is on 裝置 — the home tab is NOT visible.
        ..setDashboardVisible(false)
        ..setDetailVisible(true);
      await pumpEventQueue();
      expect(ctl.streaming, isTrue,
          reason: 'the detail page is where the dashboard went; a gate that '
              'only knows about tabs keeps it shut there forever');
      ctl.dispose();
    });

    test('leaving both the home page and the detail page closes it', () async {
      // 🔒 THIS is the half that keeps design 0042 G4. Widening condition 3 to
      // "either surface" must not become "the app is running": with neither up,
      // the receiver goes off even though the card is still MOUNTED in the
      // IndexedStack (condition 1 stays true) and the app is in the foreground
      // (condition 2 stays true).
      final (:clock, :src, :ctl) = build();
      ctl
        ..setFaceWantsSpeed(true)
        ..setDashboardVisible(true)
        ..setDetailVisible(true);
      await pumpEventQueue();
      expect(ctl.streaming, isTrue);

      ctl.setDashboardVisible(false);
      expect(ctl.streaming, isTrue, reason: 'the detail page is still up');

      ctl.setDetailVisible(false);
      // Synchronous, for the same reason every other cancel here is.
      expect(ctl.streaming, isFalse);
      expect(ctl.speedSurfaceVisible, isFalse);
      await pumpEventQueue();
      expect(src.cancels, 1);
      ctl.dispose();
    });

    test('closing the gate forgets the reading', () async {
      final (:clock, :src, :ctl) = build();
      await openGate(ctl);
      src.emit(_fix(clock.t, 14.0));
      await pumpEventQueue();
      expect(ctl.current!.vSmoothMps, closeTo(14.0, 1e-9));

      ctl.setAppResumed(false);
      // Coming back must show "waiting for a fix", not the speed you were doing
      // when you put the phone away — an unmarked frozen number is exactly what
      // G2 forbids.
      expect(ctl.current, isNull);
      ctl.dispose();
    });
  });

  group('permission (§3.5)', () {
    test('a denied permission holds the stream shut with the gate open',
        () async {
      final (:clock, :src, :ctl) = build(grant: SpeedPermissionState.denied);
      await openGate(ctl);
      expect(ctl.streaming, isFalse);
      expect(ctl.permission, SpeedPermissionState.denied);
      expect(src.subscribes, 0);
      ctl.dispose();
    });

    test('the gate never prompts — only the consent flow does', () async {
      final (:clock, :src, :ctl) = build(grant: SpeedPermissionState.denied);
      await openGate(ctl);
      expect(src.requests, 0,
          reason: 'the OS dialog must arrive inside the consent flow the user '
              'asked for, not from wandering onto a watchface');
      expect(src.statusReads, greaterThan(0));
      ctl.dispose();
    });

    test('granting from the consent flow opens an already-open gate', () async {
      final (:clock, :src, :ctl) = build(grant: SpeedPermissionState.denied);
      await openGate(ctl);
      expect(ctl.streaming, isFalse);

      src.grant = SpeedPermissionState.granted;
      await ctl.requestPermission();
      await pumpEventQueue();
      expect(ctl.permission, SpeedPermissionState.granted);
      expect(ctl.streaming, isTrue);
      ctl.dispose();
    });

    test('permanentlyDenied keeps its own value, and can reach settings',
        () async {
      final (:clock, :src, :ctl) =
          build(grant: SpeedPermissionState.permanentlyDenied);
      await openGate(ctl);
      // Distinct from plain denied because the OS will not show the dialog
      // again: the card has to offer a different way out.
      expect(ctl.permission, SpeedPermissionState.permanentlyDenied);
      await ctl.openSystemSettings();
      expect(src.settingsOpens, 1);
      ctl.dispose();
    });

    test('notRequested is the starting value, not denied', () {
      final (:clock, :src, :ctl) = build();
      expect(ctl.permission, SpeedPermissionState.notRequested,
          reason: 'the card must not accuse the user of refusing before '
              'anything was asked');
      ctl.dispose();
    });
  });

  group('driving the estimator', () {
    test('a fix becomes an estimate and notifies listeners', () async {
      final (:clock, :src, :ctl) = build();
      var notifications = 0;
      ctl.addListener(() => notifications++);
      await openGate(ctl);
      notifications = 0;

      src.emit(_fix(clock.t, 9.0));
      await pumpEventQueue();
      expect(ctl.current!.vSmoothMps, closeTo(9.0, 1e-9));
      expect(ctl.current!.state, SpeedState.live);
      expect(notifications, greaterThan(0));
      ctl.dispose();
    });

    test('the tick timer is what makes a tunnel visible', () async {
      final (:clock, :src, :ctl) = build();
      await openGate(ctl);
      src.emit(_fix(clock.t, 9.0));
      await pumpEventQueue();
      expect(ctl.current!.state, SpeedState.live);

      // No further fixes; only time passes.
      clock.advance(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(ctl.current!.state, SpeedState.holding);
      ctl.dispose();
    });

    test('the estimates stream is the 0044 hook and it forwards', () async {
      final (:clock, :src, :ctl) = build();
      final seen = <SpeedEstimate>[];
      final sub = ctl.estimates.listen(seen.add);
      await openGate(ctl);
      src.emit(_fix(clock.t, 9.0));
      await pumpEventQueue();
      expect(seen, hasLength(1));
      expect(seen.single.t, t0);
      await sub.cancel();
      ctl.dispose();
    });

    test('a stream error shuts the hardware down instead of retrying',
        () async {
      final (:clock, :src, :ctl) = build();
      await openGate(ctl);
      src.breakStream(StateError('location services disabled'));
      await pumpEventQueue();
      // A retry loop against a disabled location service is battery spent with
      // nothing on screen to show for it.
      expect(ctl.streaming, isFalse);
      expect(ctl.current, isNull);
      ctl.dispose();
    });

    test('dispose stops the hardware', () async {
      final (:clock, :src, :ctl) = build();
      await openGate(ctl);
      expect(ctl.streaming, isTrue);
      ctl.dispose();
      await pumpEventQueue();
      expect(src.cancels, 1);
    });
  });

  // -------------------------------------------------------------------------
  // 2026-08-07 adversarial review. Both tests exist because a real defect got
  // past 940 green tests: nothing in the suite looked at what we hand to the
  // plugin, or at what we read back off it.
  // -------------------------------------------------------------------------
  group('what we ask the platform for', () {
    test('Android is asked for a 1 s interval, explicitly', () {
      final s = GeolocatorSpeedSource.locationSettings(isAndroid: true);
      // The base LocationSettings drops the interval on the floor: its toJson()
      // emits only accuracy and distanceFilter, and the Java side then defaults
      // to 5000 ms AND makes it a floor (setMinUpdateIntervalMillis). Against
      // T_hold = 2 s that produces a permanent live -> holding -> lost cycle on
      // a clear-sky ride. The subtype IS the fix, so the subtype is the assert.
      expect(s, isA<AndroidSettings>());
      expect((s as AndroidSettings).intervalDuration,
          GeolocatorSpeedSource.speedSamplingPeriod);
      expect(GeolocatorSpeedSource.speedSamplingPeriod,
          lessThanOrEqualTo(const Duration(seconds: 1)),
          reason: 'the sampling period must stay at or below T_hold/2, or the '
              'state machine declares a tunnel between two good fixes');
    });

    test('a fix with no reported accuracy is not scored as a perfect one', () {
      // Both platforms OMIT the key when the value is unavailable, and
      // Position._toDouble(null) turns an absent key into 0.0 — the best
      // possible accuracy. iOS reports a negative accuracy for an invalid fix.
      // Either way "we do not know" used to read as "0 m, excellent".
      final unknown = GeolocatorSpeedSource.toFix(Position(
        latitude: 25.0, longitude: 121.0, timestamp: DateTime(2026, 8, 7),
        accuracy: 0.0, altitude: 0, altitudeAccuracy: 0, heading: 0,
        headingAccuracy: 0, speed: 4.0, speedAccuracy: 0.0,
      ));
      expect(unknown.horizontalAccuracyM, double.infinity,
          reason: 'unknown accuracy must fail the reject floor, not pass it');
      expect(unknown.speedAccuracyMps, isNull);

      final good = GeolocatorSpeedSource.toFix(Position(
        latitude: 25.0, longitude: 121.0, timestamp: DateTime(2026, 8, 7),
        accuracy: 8.0, altitude: 0, altitudeAccuracy: 0, heading: 0,
        headingAccuracy: 0, speed: 4.0, speedAccuracy: 0.5,
      ));
      expect(good.horizontalAccuracyM, 8.0);
      expect(good.speedAccuracyMps, 0.5);
    });

    test('an unreported speed arrives as null, not as a measured 0', () {
      Position at({required double speed, required double speedAcc}) => Position(
            latitude: 25.0, longitude: 121.0, timestamp: DateTime(2026, 8, 7),
            accuracy: 8.0, altitude: 0, altitudeAccuracy: 0, heading: 0,
            headingAccuracy: 0, speed: speed, speedAccuracy: speedAcc,
          );

      // The shape of "the chip has no speed solution": both keys omitted, both
      // rendered as 0.0 by the platform interface. This used to be published as
      // `0 km/h, quality good, state live` — a number nobody measured.
      expect(GeolocatorSpeedSource.toFix(at(speed: 0.0, speedAcc: 0.0)).speedMps,
          isNull);

      // A real stop: the chip reports zero AND says how sure it is.
      expect(GeolocatorSpeedSource.toFix(at(speed: 0.0, speedAcc: 0.4)).speedMps,
          0.0);

      // Moving is never ambiguous, with or without an uncertainty.
      expect(GeolocatorSpeedSource.toFix(at(speed: 9.5, speedAcc: 0.0)).speedMps,
          9.5);
    });
  });

  // -------------------------------------------------------------------------
  // Design 0044 Phase G — the acceleration wiring.
  //
  // Two values leave this controller and they are deliberately NOT the same
  // one: [accelEstimates] is the raw series that gets recorded, [currentAccel]
  // is what a rider is shown. The throttle lives on the second only, and these
  // tests are what stop a later "simplification" from collapsing them.
  // -------------------------------------------------------------------------
  group('acceleration (design 0044)', () {
    ({_Clock clock, _FakeSource src, GpsSpeedController ctl}) buildAccel({
      AccelEstimatorConfig accel = const AccelEstimatorConfig(),
      Duration tick = const Duration(hours: 1),
    }) {
      final clock = _Clock(t0);
      final src = _FakeSource();
      return (
        clock: clock,
        src: src,
        ctl: GpsSpeedController(
          source: src,
          now: () => clock.t,
          // Long by default, so the ticker never fires on its own: every one
          // of these tests wants the clock under its own control.
          tickInterval: tick,
          accelConfig: accel,
        ),
      );
    }

    /// Feed a 1 Hz ramp of [n] fixes starting at [from] m/s, +[step] each.
    Future<void> ramp(
      _Clock clock,
      _FakeSource src, {
      required int n,
      double from = 10.0,
      double step = 1.0,
    }) async {
      for (var i = 0; i < n; i++) {
        src.emit(_fix(clock.t, from + step * i));
        await pumpEventQueue();
        clock.advance(const Duration(seconds: 1));
      }
    }

    test('the window fills, then a slope appears on both outputs', () async {
      final (:clock, :src, :ctl) = buildAccel();
      final raw = <AccelEstimate>[];
      final sub = ctl.accelEstimates.listen(raw.add);
      await openGate(ctl);

      await ramp(clock, src, n: 2);
      expect(ctl.currentAccel, isNull,
          reason: 'two samples are not a two second average');
      expect(ctl.accelState, AccelState.warming);
      expect(raw, isEmpty);

      await ramp(clock, src, n: 1, from: 12.0);
      expect(ctl.accelState, AccelState.live);
      expect(raw, hasLength(1));
      expect(ctl.currentAccel!.aMps2, greaterThan(0));
      await sub.cancel();
      ctl.dispose();
    });

    test('a tunnel clears the displayed value immediately, throttle or not',
        () async {
      // The throttle must never delay SILENCE. A held speed with a leftover
      // acceleration beside it is exactly the pairing design 0044 G2 forbids,
      // and a throttle that applied to disappearance would produce it for as
      // long as the throttle lasts.
      final (:clock, :src, :ctl) = buildAccel(
        accel: const AccelEstimatorConfig(displayThrottle: Duration(hours: 1)),
        tick: const Duration(milliseconds: 5),
      );
      await openGate(ctl);
      await ramp(clock, src, n: 3);
      expect(ctl.currentAccel, isNotNull);

      // Into the tunnel: no more fixes, only time and the real ticker.
      clock.advance(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(ctl.current!.state, SpeedState.holding);
      expect(ctl.accelState, AccelState.suppressed);
      expect(ctl.currentAccel, isNull,
          reason: 'a frozen speed must not keep an acceleration beside it');
      ctl.dispose();
    });

    test('the display throttle does not thin the recorded series', () async {
      final (:clock, :src, :ctl) = buildAccel(
        accel: const AccelEstimatorConfig(displayThrottle: Duration(hours: 1)),
      );
      final raw = <AccelEstimate>[];
      final sub = ctl.accelEstimates.listen(raw.add);
      await openGate(ctl);

      await ramp(clock, src, n: 6);
      expect(raw.length, greaterThanOrEqualTo(4),
          reason: 'every live sample past the warm-up produces a slope');
      // …while the card was handed exactly one value, an hour being the
      // throttle. The recorded series is untouched by that decision.
      expect(ctl.currentAccel, isNotNull);
      expect(identical(ctl.currentAccel, raw.first), isTrue);
      await sub.cancel();
      ctl.dispose();
    });

    test('with the default throttle a 1 Hz series updates every sample',
        () async {
      final (:clock, :src, :ctl) = buildAccel();
      await openGate(ctl);
      await ramp(clock, src, n: 4);
      final first = ctl.currentAccel;
      await ramp(clock, src, n: 1, from: 20.0);
      expect(identical(ctl.currentAccel, first), isFalse,
          reason: '500 ms of throttle must not swallow a 1 Hz update');
      ctl.dispose();
    });

    test('closing the gate takes the acceleration with it', () async {
      // `_stop()` resets the estimator, and the reset announces itself only on
      // `transitions`. If this controller wired the acceleration module to
      // `estimates` alone, the value below would survive the gate closing and
      // reappear beside the next session's first speed.
      final (:clock, :src, :ctl) = buildAccel();
      await openGate(ctl);
      await ramp(clock, src, n: 3);
      expect(ctl.currentAccel, isNotNull);

      ctl.setDashboardVisible(false);
      await pumpEventQueue();
      expect(ctl.currentAccel, isNull);
      expect(ctl.accelState, AccelState.suppressed);
      ctl.dispose();
    });
  });
}
