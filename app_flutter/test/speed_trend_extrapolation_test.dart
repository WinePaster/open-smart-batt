// Design 0073's trend extrapolation, ASSEMBLED — the whole rider-visible claim
// through the real [GpsSpeedController], the real [SpeedEstimator] and the real
// [AccelEstimator].
//
// `speed_estimator_test.dart` owns the five clamps one at a time and
// `accel_estimator_test.dart` owns the adaptive slope; both of them hand the
// slope in by hand, because that is the only way to test a clamp in isolation.
// What neither can reach is the ASSEMBLY, and the assembly is where this
// project keeps shipping its defects: three times now a correct callee has been
// wired to a call site that never used it, with every unit test green (see
// `accelReadoutFor`'s comment for the list). The specific ways it could be
// wrong here are worth naming, because each of them leaves every other test in
// the suite passing:
//
//   * the controller could read `currentAccel` (500 ms display throttle)
//     instead of the raw slope;
//   * it could read `AccelEstimator.current` instead of `displaySlopeMps2`,
//     losing the adaptive window and half the launch;
//   * it could forget C3③ and extrapolate on a stale slope after a tunnel.
//
// So everything below drives fixes into the source and reads
// `displaySpeedMpsNow()`, i.e. exactly what the card calls.
//
// 🔴 The two tests that must never be deleted without a replacement are
// "coming out of a tunnel" (it is 0042 §3.2, an existing ruling, and design
// 0073 §3.8 records that it is the one guard 0073 made weaker — it used to be a
// line we owned in `addFix`, and it is now an invariant of another module) and
// "the recorded series is untouched" (design 0044 differentiates that series
// and design 0061 stores it).
import 'dart:async';

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
  StreamController<SpeedFix>? _c;

  void emit(SpeedFix f) => _c!.add(f);

  @override
  Stream<SpeedFix> fixes() {
    final c = StreamController<SpeedFix>();
    c.onCancel = () => _c = null;
    _c = c;
    return c.stream;
  }

  @override
  Future<SpeedPermissionState> status() async => SpeedPermissionState.granted;

  @override
  Future<SpeedPermissionState> request() async => SpeedPermissionState.granted;

  @override
  Future<void> openSystemSettings() async {}
}

void main() {
  final t0 = DateTime.utc(2026, 8, 19, 10);
  const T = Duration(seconds: 1);
  const trend = TrendConfig();

  /// `Δ` at the instant a punctual sample lands: the filter's own steady-state
  /// lag `T(1−α)/α`, because `t − lastLiveAt` is zero (0073 §3.3.1).
  const filterLagS = 0.17647058823529413;

  late _Clock clock;
  late _FakeSource src;
  late GpsSpeedController ctl;

  /// Long enough that the 1 Hz heartbeat never fires by itself inside a test —
  /// every state change below is driven by the injected clock and by [tick].
  const noTick = Duration(days: 1);

  Future<void> open({SpeedEstimatorConfig? cfg, Duration tick = noTick}) async {
    clock = _Clock(t0);
    src = _FakeSource();
    ctl = GpsSpeedController(
      source: src,
      now: () => clock.t,
      tickInterval: tick,
      config: cfg ?? const SpeedEstimatorConfig(),
    );
    ctl
      ..setFaceWantsSpeed(true)
      ..setDashboardVisible(true)
      ..setAppResumed(true);
    await pumpEventQueue();
    expect(ctl.streaming, isTrue, reason: 'precondition: the gate opened');
  }

  tearDown(() => ctl.dispose());

  /// One fix, stamped now, delivered.
  Future<void> feed(double mps) async {
    src.emit(SpeedFix(
      speedMps: mps,
      horizontalAccuracyM: 5.0,
      timestamp: clock.t,
    ));
    await pumpEventQueue();
  }

  /// `seconds` of constant acceleration from `v0`, one 1 Hz fix each.
  Future<void> ride(double v0, double a, int seconds) async {
    for (var i = 0; i < seconds; i++) {
      await feed(v0 + a * i);
      clock.advance(T);
    }
  }

  test('🔴 G2 — under constant acceleration the reading keeps up', () async {
    // The whole point of the design, made executable. The residual lag is
    // `(1−k)·a·Δ` by construction: `level` sits `a·T(1−α)/α` behind the last
    // measurement, the extrapolation puts back `k·a·Δ`, and what is left over
    // is the 30 % discount `k = 0.7` deliberately keeps as slack for the slope
    // being a three-point fit through noisy GNSS speed.
    //
    // ⛔ If this goes red, recompute it — do not widen the tolerance. Every
    // figure is a closed form.
    const a = 3.0;
    await open();
    // Twenty-five samples so the EWMA transient is long gone.
    await ride(0.0, a, 25);
    // `clock` now sits one period after the last fix was delivered, so step
    // back onto the sample and walk forward across one interval.
    clock.t = clock.t.subtract(T);

    final trueAtFix = 3.0 * 24;
    expect(ctl.current!.state, SpeedState.live);
    expect(ctl.trendSlopeMps2, closeTo(a, 1e-6),
        reason: 'the slope of a straight speed ramp is the ramp');

    var sum = 0.0;
    const n = 1000;
    for (var i = 0; i < n; i++) {
      final ms = i + 0.5; // midpoint rule across one sampling interval
      final at = clock.t.add(Duration(microseconds: (ms * 1000).round()));
      final trueSpeed = trueAtFix + a * (ms / 1000);
      final delta = ms / 1000 + filterLagS;
      final shown = ctl.displaySpeedMpsAt(at)!;
      expect(trueSpeed - shown, closeTo((1 - trend.k) * a * delta, 1e-6),
          reason: '+${ms}ms: the residual lag is not (1−k)·a·Δ');
      sum += trueSpeed - shown;
    }
    // And in the units the argument was made in. 0073 §3.5.1 promises the mean
    // lag drops from 11.1 km/h (v0.7.26, the 0071 ramp at α=0.85) to about 2.2
    // at 3 m/s² with λ = 0. `(1−k)·a·(0.5·T + T(1−α)/α)` = 0.609 m/s.
    expect(sum / n * 3.6, closeTo(2.19, 0.02),
        reason: 'the mean lag over one interval is the number §3.5.1 promised');
  });

  test('🔴 the same ride with k = 0 is the pre-0073 reading, and it is worse',
      () async {
    // The reverse of the test above, and the reason it means anything: with the
    // feature off the residual is the FULL `a·Δ`, which is 3.5–7 km/h across
    // the same interval. Without this pair, an implementation that extrapolated
    // by accident (or not at all) could satisfy one of them.
    const a = 3.0;
    await open(cfg: const SpeedEstimatorConfig(trend: TrendConfig(k: 0)));
    await ride(0.0, a, 25);
    clock.t = clock.t.subtract(T);

    final trueAtFix = 3.0 * 24;
    var sum = 0.0;
    const n = 1000;
    for (var i = 0; i < n; i++) {
      final ms = i + 0.5;
      final at = clock.t.add(Duration(microseconds: (ms * 1000).round()));
      final trueSpeed = trueAtFix + a * (ms / 1000);
      final shown = ctl.displaySpeedMpsAt(at)!;
      expect(shown, ctl.current!.vSmoothMps,
          reason: 'k = 0 must draw exactly the recorded value (G6)');
      expect(trueSpeed - shown, closeTo(a * (ms / 1000 + filterLagS), 1e-6));
      sum += trueSpeed - shown;
    }
    // 7.3 km/h — 0073 §3.5.1's "k = 0" row, and the reason that row is in the
    // design at all: even with the feature switched off, DELETING 0071's ramp
    // is worth 11.1 ⇒ 7.3 km/h on its own.
    expect(sum / n * 3.6, closeTo(7.30, 0.02));
  });

  test('🔴 coming out of a tunnel does not show the speed from before it',
      () async {
    // 0042 §3.2, an EXISTING ruling: the speed from before a gap must not be
    // blended into the samples after it. Design 0071 obeyed it with a line in
    // `addFix` (pin 5: a re-seed gets a flat curve). Design 0073 deleted that
    // line along with the curve, and §3.8 records honestly that the protection
    // is now an invariant of a different module — `AccelEstimator` empties its
    // window on the way back to `live`, so there is no slope to extrapolate
    // along for about two seconds.
    //
    // 🔴 THIS TEST IS THE COMPENSATION FOR THAT. It asserts the RESULT rather
    // than the mechanism, so it survives 0044 being refactored, and it is the
    // replacement for 0071's own §5 #8 rather than an addition to it.
    // A real ticker, because a tunnel is the ABSENCE of samples and only the
    // heartbeat can notice it.
    await open(tick: const Duration(milliseconds: 5));
    // Accelerating hard on the way in, so a slope that survived the tunnel
    // would be visibly wrong on the way out rather than accidentally harmless.
    await ride(15.0, 2.5, 8); // 15 → 32.5 m/s
    expect(ctl.trendSlopeMps2, closeTo(2.5, 1e-4),
        reason: 'precondition: there IS a trend to leak');
    // A tunnel: no fixes at all.
    clock.advance(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(ctl.current!.state, SpeedState.lost,
        reason: 'precondition: the tunnel ended the series');

    // Out the other side, crawling.
    for (var i = 0; i < 3; i++) {
      await feed(3.0);
      expect(ctl.current!.state, SpeedState.live);
      if (i < 2) {
        expect(ctl.trendSlopeMps2, isNull,
            reason: 'second $i: the window restarted EMPTY on the way back to '
                'live, so there is no trend for about two seconds — that is '
                'design 0044\'s own invariant and design 0073 leans on it');
      }
      for (var ms = 0; ms <= 900; ms += 100) {
        final v = ctl.displaySpeedMpsAt(clock.t.add(Duration(milliseconds: ms)))!;
        expect(v, closeTo(3.0, 1e-9),
            reason: 'second $i, +${ms}ms: the reading was $v — anything between '
                '3 and 25 is a number nobody measured, drawn at the exact '
                'moment the rider is looking to see whether the fix came back');
      }
      clock.advance(T);
    }
    // And the mechanism, asserted separately so a failure says WHICH half of it
    // broke. ⚠️ Not `isNull` for ever: three post-tunnel samples DO refill the
    // window, and the slope it then fits is a legitimate ~0 through three
    // 3 m/s readings. What must never come back is the 2.5 m/s² from before.
    final after = ctl.trendSlopeMps2;
    expect(after == null || after.abs() < trend.aDeadMps2, isTrue,
        reason: 'the slope after the tunnel is $after — the window was refilled '
            'from post-tunnel samples only, so it can only be ~0 here');
  });

  test('🔴 the recorded series design 0044 and 0061 consume is untouched',
      () async {
    // G4 / 0071 pin 2, carried forward without an inch of slack. Design 0073
    // reads three things and writes none of them, and "reads" has to mean
    // reads: the card calls `displaySpeedMpsNow` on every vsync.
    await open();
    final speeds = <SpeedEstimate>[];
    final edges = <SpeedStateTransition>[];
    final accels = <AccelEstimate>[];
    final s1 = ctl.estimates.listen(speeds.add);
    final s2 = ctl.transitions.listen(edges.add);
    final s3 = ctl.accelEstimates.listen(accels.add);
    addTearDown(() async {
      await s1.cancel();
      await s2.cancel();
      await s3.cancel();
    });

    await ride(0.0, 3.0, 6);
    await pumpEventQueue();
    final speedsAfterRide = speeds.map((e) => (e.t, e.vSmoothMps)).toList();
    final accelsAfterRide = accels.map((e) => (e.t, e.aMps2)).toList();
    final edgesAfterRide = edges.length;
    expect(speedsAfterRide, hasLength(6),
        reason: 'precondition: the ride actually produced a series');
    expect(accelsAfterRide, isNotEmpty);

    // Ten thousand frames' worth of reads — roughly three minutes of ticker at
    // 60 Hz, all inside one sampling interval.
    for (var i = 0; i < 10000; i++) {
      ctl.displaySpeedMpsNow();
      ctl.displayTrendActiveNow();
    }
    await pumpEventQueue();

    expect(speeds.map((e) => (e.t, e.vSmoothMps)).toList(), speedsAfterRide,
        reason: 'the drawn value leaked into the recorded speed series');
    expect(accels.map((e) => (e.t, e.aMps2)).toList(), accelsAfterRide,
        reason: 'the drawn value leaked into the recorded acceleration series');
    expect(edges, hasLength(edgesAfterRide));
  });

  test('🔴 C4 bounds the overshoot when the acceleration stops', () async {
    // 0073 §3.5.2, and the price of the owner's "過衝可以接受". Letting go of
    // the throttle does not empty the least squares window, so for about two
    // seconds the reading is still being carried forward along an acceleration
    // that has ended. What the ruling bought is bounded and temporary, and both
    // halves are asserted.
    const a = 3.0;
    await open();
    await ride(0.0, a, 8); // 0 → 21 m/s
    final top = 21.0;

    var worst = 0.0;
    for (var s = 0; s < 5; s++) {
      await feed(top);
      for (var ms = 0; ms <= 900; ms += 100) {
        final v = ctl.displaySpeedMpsAt(clock.t.add(Duration(milliseconds: ms)))!;
        final over = v - top;
        if (over > worst) worst = over;
        expect(over, lessThanOrEqualTo(trend.capMps + 1e-9),
            reason: 'second $s, +${ms}ms: overshot by $over m/s, past C');
      }
      clock.advance(T);
      if (s >= 1) {
        // 0073 §3.5.2 promises convergence in 2–2.5 s — the time it takes the
        // least squares window to fill with post-event samples.
        final v = ctl.displaySpeedMpsNow()!;
        expect((v - top).abs() * 3.6, lessThan(1.5),
            reason: '${s + 1}.2 s after the acceleration stopped the reading '
                'is still ${(v - top) * 3.6} km/h out');
      }
    }
    expect(worst, greaterThan(0.2),
        reason: 'there must BE an overshoot to bound, or this test would pass '
            'on a build that never extrapolates');
  });

  test('🔴 a standing start is extrapolated on the real acceleration', () async {
    // Design 0073 §7 Q9, end to end. The fixed two-second window is still
    // half-full of standing still at the moment the throttle opens, so without
    // the adaptive reading the compensation would be half size for the two
    // seconds the rider is watching hardest.
    const a = 3.0;
    await open();
    // Four seconds parked, so the window is full of stationary samples.
    for (var i = 0; i < 4; i++) {
      await feed(0.0);
      clock.advance(T);
    }
    expect(ctl.current!.vSmoothMps, 0.0);

    // Launch.
    await feed(a);
    final adaptive = ctl.trendSlopeMps2!;
    final recorded = ctl.currentAccel!.aMps2;
    expect(recorded, closeTo(adaptive / 2, 1e-9),
        reason: 'the two must differ by exactly the factor 0073 §7 Q9 predicts '
            '— and the RECORDED one must be the half, because design 0044 §3.5 '
            'defines it as the two-second average');
    expect(adaptive, greaterThan(2.0),
        reason: 'the displayed trend at launch was $adaptive m/s² against a '
            'real 3 — the adaptive window is not wired in');
  });
}
