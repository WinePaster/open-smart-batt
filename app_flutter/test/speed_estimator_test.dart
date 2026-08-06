// SpeedEstimator — filtering, smoothing and the signal-loss state machine
// (design 0042 Phase A / §3.2).
//
// The whole reason this logic is pure Dart with an injected clock is here: the
// interesting cases are a tunnel and a red light, and neither is reachable from
// a unit test that has to wait for real seconds or a real GNSS chip. Every test
// below drives the clock by hand.
//
// The two tunnel shapes are tested separately because the platforms fail
// differently (0042 §2.3 #4): Android stops sending samples, iOS keeps sending
// degraded ones. A state machine that only handles the first would sit in
// `live` for the length of an iOS tunnel showing a number nobody measured.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/state/speed_estimator.dart';

/// Hand-driven clock. `now` is a closure over [t], so advancing it is the whole
/// of "time passed" as far as the estimator is concerned.
class _Clock {
  _Clock(this.t);
  DateTime t;
  void advance(Duration d) => t = t.add(d);
}

SpeedFix _fix(
  DateTime at,
  double mps, {
  double acc = 5.0,
  double? speedAcc,
}) =>
    SpeedFix(
      speedMps: mps,
      horizontalAccuracyM: acc,
      speedAccuracyMps: speedAcc,
      timestamp: at,
    );

void main() {
  final t0 = DateTime.utc(2026, 8, 7, 9, 30);

  ({_Clock clock, SpeedEstimator est}) build([SpeedEstimatorConfig? cfg]) {
    final clock = _Clock(t0);
    return (
      clock: clock,
      est: SpeedEstimator(
        config: cfg ?? const SpeedEstimatorConfig(),
        now: () => clock.t,
      ),
    );
  }

  group('smoothing', () {
    test('an acceleration ramp is followed without overshoot', () {
      final (:clock, :est) = build();
      final raw = [5.0, 7.0, 9.0, 11.0, 13.0];
      final smoothed = <double>[];
      for (final v in raw) {
        est.addFix(_fix(clock.t, v));
        smoothed.add(est.current!.vSmoothMps);
        clock.advance(const Duration(seconds: 1));
      }
      // Monotonically rising and always behind the newest raw sample: an EWMA
      // that ever leads the input has the wrong sign somewhere.
      for (var i = 1; i < smoothed.length; i++) {
        expect(smoothed[i], greaterThan(smoothed[i - 1]));
        expect(smoothed[i], lessThan(raw[i]));
      }
      expect(smoothed.first, closeTo(5.0, 1e-9),
          reason: 'the first sample seeds the average, it is not blended with 0');
    });

    test('below the still threshold the speed reads exactly 0', () {
      final (:clock, :est) = build();
      // Position jitter while standing at a light. The threshold is a paper
      // starting point (3.0 km/h, ruled 2026-08-07) and Phase F may retune it —
      // the invariant under test is the clamp, not the number.
      for (final v in [0.10, 0.22, 0.05, 0.18]) {
        est.addFix(_fix(clock.t, v));
        expect(est.current!.vSmoothMps, 0.0);
        clock.advance(const Duration(seconds: 1));
      }
      // Pulling away crosses the threshold and the clamp lets go.
      est.addFix(_fix(clock.t, 3.0));
      expect(est.current!.vSmoothMps, greaterThan(0.0));
    });

    // The band the design doc names as real stationary GNSS jitter — 1–3 km/h,
    // i.e. 0.28–0.83 m/s — and singles out ("a red light showing 2 km/h is an
    // error the user spots instantly"). It is pinned SEPARATELY from the test
    // above because it is the case the original 1.0 km/h floor let through: the
    // threshold had been set below the noise it was written to remove. If a
    // future retune lowers `vStillMps` back under 0.83 m/s, this fails and the
    // reviewer is sent to the ruling rather than to a mystery.
    test('the 1-3 km/h jitter band the doc names still reads exactly 0', () {
      final (:clock, :est) = build();
      for (final v in [0.30, 0.56, 0.80, 0.42]) {
        est.addFix(_fix(clock.t, v));
        expect(est.current!.vSmoothMps, 0.0,
            reason: '${(v * 3.6).toStringAsFixed(1)} km/h is stationary jitter, '
                'not motion (design 0042 §3.2, ruled 2026-08-07)');
        clock.advance(const Duration(seconds: 1));
      }
    });
  });

  group('sample filtering', () {
    // ⚠️ Kept, but it is no longer the case that matters on a real phone.
    // The 2026-08-07 review found that geolocator NEVER delivers -1: the
    // platform mappers omit the key and the interface renders that as 0.0, so
    // this vector only ever existed on paper. The one below is the real one.
    test("iOS's -1 invalid speed is rejected and does not refresh the age", () {
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 10.0));
      expect(est.current!.vSmoothMps, closeTo(10.0, 1e-9));

      clock.advance(const Duration(seconds: 3));
      est.addFix(_fix(clock.t, -1.0));
      // Not blended into the average...
      expect(est.current!.vSmoothMps, closeTo(10.0, 1e-9));
      // ...and, the half that actually matters, it did not count as a recent
      // sample: the age is still measured from the last GOOD fix, so the
      // state machine has moved on.
      est.tick();
      expect(est.current!.state, SpeedState.holding);
    });

    test('a fix with no reported speed is rejected, not read as a stop', () {
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 10.0));
      expect(est.current!.vSmoothMps, closeTo(10.0, 1e-9));

      // What "the chip has no speed solution" actually looks like after the
      // adapter has done its job. If this were accepted it would both publish
      // an unmeasured 0 AND refresh the age, so the state machine would sit in
      // `live` forever on a phone that is telling us nothing.
      clock.advance(const Duration(seconds: 3));
      est.addFix(SpeedFix(
        speedMps: null,
        horizontalAccuracyM: 5.0,
        timestamp: clock.t,
      ));
      expect(est.current!.vSmoothMps, closeTo(10.0, 1e-9));
      est.tick();
      expect(est.current!.state, SpeedState.holding,
          reason: 'a null speed must not count as a recent sample');
    });

    test('a fix worse than the accuracy floor is rejected whole', () {
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 10.0));
      clock.advance(const Duration(seconds: 1));
      est.addFix(_fix(clock.t, 30.0, acc: 120.0));
      expect(est.current!.vSmoothMps, closeTo(10.0, 1e-9));
    });

    test('a fix with a useless speed accuracy is rejected whole', () {
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 10.0, speedAcc: 0.5));
      clock.advance(const Duration(seconds: 1));
      est.addFix(_fix(clock.t, 30.0, speedAcc: 9.0));
      expect(est.current!.vSmoothMps, closeTo(10.0, 1e-9));
      expect(est.current!.speedAccuracyMps, closeTo(0.5, 1e-9),
          reason: 'the rejected sample must not overwrite the reported ±');
    });
  });

  group('signal-loss state machine', () {
    test('an Android tunnel (samples stop) goes live → holding → lost', () {
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 12.0));
      expect(est.current!.state, SpeedState.live);

      // Exactly at T_hold the reading is still being measured.
      clock.advance(const Duration(seconds: 2));
      est.tick();
      expect(est.current!.state, SpeedState.live);

      clock.advance(const Duration(milliseconds: 500));
      est.tick();
      expect(est.current!.state, SpeedState.holding);
      expect(est.current!.vSmoothMps, closeTo(12.0, 1e-9),
          reason: 'holding freezes the last value, it does not decay it');

      clock.advance(const Duration(seconds: 2));
      est.tick();
      expect(est.current!.state, SpeedState.lost);
      expect(est.current!.quality, SpeedSignalQuality.none);
      expect(est.current!.lastLiveAt, t0,
          reason: 'lost still has to say how long ago the number was measured');
    });

    test('an iOS tunnel (degraded samples keep arriving) takes the same path',
        () {
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 12.0));
      // The chip keeps talking; every one of these is worthless.
      for (var i = 0; i < 5; i++) {
        clock.advance(const Duration(seconds: 1));
        est.addFix(_fix(clock.t, 11.0, acc: 100.0));
        est.tick();
      }
      expect(est.current!.state, SpeedState.lost,
          reason: 'a rejected sample must not count as signal');
      expect(est.current!.vSmoothMps, closeTo(12.0, 1e-9));
    });

    test('the first fix after a gap resets the average instead of blending it',
        () {
      final (:clock, :est) = build();
      for (var i = 0; i < 6; i++) {
        est.addFix(_fix(clock.t, 20.0));
        clock.advance(const Duration(seconds: 1));
      }
      expect(est.current!.vSmoothMps, greaterThan(15.0));

      clock.advance(const Duration(seconds: 10));
      est.tick();
      expect(est.current!.state, SpeedState.lost);

      // Out of the tunnel at walking pace. Blending would show ~15 m/s.
      est.addFix(_fix(clock.t, 2.0));
      expect(est.current!.state, SpeedState.live);
      expect(est.current!.vSmoothMps, closeTo(2.0, 1e-9));
    });

    test('the hold cap can end a freeze that the age bound would not', () {
      // With the shipped defaults the age bound always fires first, so the cap
      // is dead code until Phase F retunes T_lost upward for long overpasses.
      // This pins the cap so that retune cannot silently grant an unbounded
      // freeze.
      final clock = _Clock(t0);
      final est = SpeedEstimator(
        config: const SpeedEstimatorConfig(
          tHold: Duration(seconds: 2),
          tLost: Duration(seconds: 30),
          holdCap: Duration(seconds: 5),
        ),
        now: () => clock.t,
      );
      est.addFix(_fix(clock.t, 12.0));

      clock.advance(const Duration(seconds: 3));
      est.tick();
      expect(est.current!.state, SpeedState.holding);

      clock.advance(const Duration(seconds: 6)); // age 9 s, still under T_lost
      est.tick();
      expect(est.current!.state, SpeedState.lost);
    });

    test('reset() puts the card back to "waiting for a fix", silently',
        () async {
      final (:clock, :est) = build();
      final seen = <SpeedEstimate>[];
      final sub = est.estimates.listen(seen.add);
      est.addFix(_fix(clock.t, 12.0));
      await pumpEventQueue();
      expect(seen, hasLength(1));

      est.reset();
      await pumpEventQueue();
      expect(est.current, isNull,
          reason: 'null current is how the UI tells "never had a fix" apart '
              'from "lost it"');
      expect(seen, hasLength(1),
          reason: 'reset must not invent an estimate nobody measured');
      // A tick with no history is a no-op rather than a crash.
      est.tick();
      expect(est.current, isNull);
      await sub.cancel();
      await est.dispose();
    });
  });

  group('signal quality', () {
    test('a fresh fix is graded on accuracy at the documented boundaries', () {
      final (:clock, :est) = build();
      const cfg = SpeedEstimatorConfig();
      for (final (acc, want) in [
        (cfg.goodAccM, SpeedSignalQuality.good),
        (cfg.goodAccM + 0.1, SpeedSignalQuality.fair),
        (cfg.fairAccM, SpeedSignalQuality.fair),
        (cfg.fairAccM + 0.1, SpeedSignalQuality.poor),
      ]) {
        est.addFix(_fix(clock.t, 10.0, acc: acc));
        expect(est.current!.quality, want, reason: 'accuracy $acc m');
        clock.advance(const Duration(milliseconds: 200));
      }
    });

    test('age degrades the grade even while accuracy stays perfect', () {
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 10.0, acc: 3.0));
      expect(est.current!.quality, SpeedSignalQuality.good);

      clock.advance(const Duration(seconds: 2)); // == freshAge
      est.tick();
      expect(est.current!.quality, SpeedSignalQuality.good);

      clock.advance(const Duration(milliseconds: 100));
      est.tick();
      expect(est.current!.quality, SpeedSignalQuality.poor);

      clock.advance(const Duration(seconds: 2)); // past T_lost
      est.tick();
      expect(est.current!.quality, SpeedSignalQuality.none);
    });
  });

  group('the 0044 consumption contract', () {
    test('transitions are emitted in order, stamped with when they happened',
        () async {
      final (:clock, :est) = build();
      final seen = <SpeedStateTransition>[];
      final sub = est.transitions.listen(seen.add);

      est.addFix(_fix(clock.t, 12.0));
      clock.advance(const Duration(milliseconds: 2500));
      est.tick(); // → holding
      final holdingAt = clock.t;
      clock.advance(const Duration(seconds: 2));
      est.tick(); // → lost
      final lostAt = clock.t;
      clock.advance(const Duration(seconds: 1));
      est.addFix(_fix(clock.t, 3.0)); // → live
      final liveAt = clock.t;
      await pumpEventQueue();

      expect(
        seen.map((e) => (e.from, e.to)).toList(),
        [
          (SpeedState.live, SpeedState.holding),
          (SpeedState.holding, SpeedState.lost),
          (SpeedState.lost, SpeedState.live),
        ],
        reason: 'acquiring the very first fix emits no transition — there is '
            'no prior state, and `from` is non-nullable by design',
      );
      expect(seen.map((e) => e.at).toList(), [holdingAt, lostAt, liveAt]);
      await sub.cancel();
      await est.dispose();
    });

    test('a held value is not re-announced every tick', () async {
      final (:clock, :est) = build();
      final seen = <SpeedEstimate>[];
      final sub = est.estimates.listen(seen.add);

      est.addFix(_fix(clock.t, 12.0));
      clock.advance(const Duration(milliseconds: 2500));
      est.tick(); // live → holding: one emission
      for (var i = 0; i < 5; i++) {
        est.tick(); // nothing changed
      }
      await pumpEventQueue();
      // A run of identical points is exactly what design 0044 G2 calls the
      // frozen-difference trap: differentiating them yields a confident 0.
      expect(seen, hasLength(2));
      expect(seen.last.state, SpeedState.holding);
      await sub.cancel();
      await est.dispose();
    });

    test('estimates carry the state, so a real 0 is separable from a held one',
        () async {
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 0.05)); // stopped, measured
      expect(est.current!.vSmoothMps, 0.0);
      expect(est.current!.state, SpeedState.live);

      clock.advance(const Duration(seconds: 3));
      est.tick();
      expect(est.current!.vSmoothMps, 0.0);
      expect(est.current!.state, SpeedState.holding,
          reason: 'same digits, different meaning — 0042 G2 in one assertion');
      await est.dispose();
    });
  });

  test('the estimator stays pure Dart — no Flutter, no plugin', () {
    // This is what buys the tests above. The moment the estimator imports the
    // location plugin, the tunnel state machine can only be exercised on a
    // phone in a tunnel, and it stops being exercised.
    var dir = Directory.current;
    while (!File('${dir.path}/pubspec.yaml').existsSync()) {
      dir = dir.parent;
    }
    final source =
        File('${dir.path}/lib/state/speed_estimator.dart').readAsStringSync();
    final imports = RegExp(r"^import\s+'([^']+)'", multiLine: true)
        .allMatches(source)
        .map((m) => m.group(1)!)
        .toList();
    expect(imports, ['dart:async']);
  });

  // -------------------------------------------------------------------------
  // 2026-08-07 adversarial review. Both defects were invisible to the suite
  // because the suite only ever asked "what does the estimator say now" —
  // never "is the SERIES it produced coherent", which is the only thing design
  // 0044 will care about when it differentiates it.
  // -------------------------------------------------------------------------
  group('the series design 0044 will differentiate', () {
    test('reset ends the series on `transitions`, it is not silent', () async {
      final (:clock, :est) = build();
      final edges = <SpeedStateTransition>[];
      final sub = est.transitions.listen(edges.add);

      est.addFix(_fix(clock.t, 25.0));
      await pumpEventQueue();
      edges.clear();

      est.reset();
      await pumpEventQueue();

      // Without this edge, a 25 m/s sample and a 3 m/s sample half an hour
      // apart look like one continuous series, and 0044 differentiates across
      // the join. Every AppLifecycleState.inactive takes this path.
      expect(edges, hasLength(1));
      expect(edges.single.from, SpeedState.live);
      expect(edges.single.to, SpeedState.lost);

      // A reset with nothing to end stays quiet: `from` is non-nullable and
      // there is no prior state to name.
      edges.clear();
      est.reset();
      await pumpEventQueue();
      expect(edges, isEmpty);

      await sub.cancel();
    });

    test('`t` is stamped on the injected clock and never goes backwards',
        () async {
      final (:clock, :est) = build();
      final ts = <DateTime>[];
      final sub = est.estimates.listen((e) => ts.add(e.t));

      // The sequence is built so the OLD code would fail it. Stamping addFix
      // with the fix's own platform timestamp while tick() used our clock put
      // two time bases in one series; it only shows up when a tick lands
      // BETWEEN two late-delivered fixes.
      //
      //   fix measured 400 ms before we saw it  -> old t = t0-0.4s, new t = t0
      //   tick that trips live -> holding       ->     t = t0+2.5s
      //   fix measured 400 ms before we saw it  -> old t = t0+2.2s  ← backwards
      //                                            new t = t0+2.6s
      est.addFix(_fix(
          clock.t.subtract(const Duration(milliseconds: 400)), 10.0));
      clock.advance(const Duration(milliseconds: 2500));
      est.tick(); // age is now 2.9 s > T_hold, so this one really does emit
      clock.advance(const Duration(milliseconds: 100));
      est.addFix(_fix(
          clock.t.subtract(const Duration(milliseconds: 400)), 11.0));
      await pumpEventQueue();

      expect(ts, hasLength(3),
          reason: 'the middle tick must emit, or this test proves nothing');
      for (var i = 1; i < ts.length; i++) {
        expect(ts[i].isBefore(ts[i - 1]), isFalse,
            reason: 'estimate $i went backwards: ${ts[i - 1]} -> ${ts[i]} — '
                'design 0044 divides by this dt');
      }
      await sub.cancel();
    });
  });
}
