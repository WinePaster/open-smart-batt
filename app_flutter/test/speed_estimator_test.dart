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
import 'package:open_smart_batt/state/accel_estimator.dart';
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

    // ⚠️ NARROWED 2026-08-09 (FB-56). The property this pins is unchanged and
    // is still the important one: a null speed arriving beside a MOVING
    // reading must not be read as a stop, and must not refresh the age. What
    // changed is that this is no longer the only null-speed case — see the
    // `a stationary iOS phone` group below for the one that now behaves
    // differently, and why the two are told apart by the value on screen
    // rather than by the fix.
    test('a fix with no reported speed, beside a MOVING reading, is rejected',
        () {
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
          reason: 'a null speed beside a non-zero reading must not count as a '
              'recent sample — freezing 10 m/s as `live` is exactly G2');
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

  // ==========================================================================
  // FB-56 — a stationary iOS phone is not a phone with no signal.
  // ==========================================================================
  //
  // THE FIELD REPORT. The owner rode to a stop and the card said "no signal"
  // seconds later, while the phone was sitting on a parked scooter under open
  // sky. His words: "會跳出無訊號 但是沒看到 hold, 減速到 0 的那幾秒基本上是
  // 數字" and "大多是停下來之後會跳無訊號, 我目前都是在 ios 測試".
  //
  // WHAT WAS ACTUALLY HAPPENING. iOS auto-pause is off (`GpsSpeedController`
  // passes a bare `LocationSettings`), so fixes kept arriving at ~1 Hz the
  // whole time — good accuracy, open sky, nothing wrong with the signal. What
  // stopped was the DOPPLER SPEED: a stationary chip has no speed solution, the
  // platform omits the key, and `toFix` maps that to `speedMps: null` (which is
  // the right call — see its comment). The estimator then rejected every one of
  // those fixes, the age grew, and four seconds later the card announced a loss
  // of signal it was holding the disproof of in its hand.
  //
  // WHY THE FIX IS SAFE. It is gated on the value ALREADY DISPLAYED being a
  // clamped zero, which makes it structurally unable to freeze a moving number
  // and call it live — the thing 0042 G2 exists to forbid. Each test below
  // holds up one of those gates; the last group is the one that would fail if
  // somebody widened the branch to "null speed ⇒ assume stopped".
  group('FB-56: a null speed beside a displayed zero keeps the reading alive',
      () {
    /// A stationary iOS fix: good position, no speed field at all.
    SpeedFix stillFix(DateTime at, {double acc = 5.0}) => SpeedFix(
          speedMps: null,
          horizontalAccuracyM: acc,
          timestamp: at,
        );

    /// Ride to a standstill and return the clock/estimator at the moment the
    /// card first reads exactly 0.0 while still `live`.
    ({_Clock clock, SpeedEstimator est}) rolledToAStop() {
      final built = build();
      for (final v in [8.0, 4.0, 2.0, 0.5, 0.2, 0.1]) {
        built.est.addFix(_fix(built.clock.t, v));
        built.clock.advance(const Duration(seconds: 1));
      }
      expect(built.est.current!.vSmoothMps, 0.0,
          reason: 'precondition: the deceleration ramp reached the clamp');
      expect(built.est.current!.state, SpeedState.live);
      return built;
    }

    test('a parked phone stays live at 0.0 — it never says "no signal"', () {
      final (:clock, :est) = rolledToAStop();

      // Ten seconds of the real steady state: a fix a second, a tick a second.
      // Both bounds that end a reading (T_lost = 4 s, holdCap = 5 s) are well
      // inside this window, so a regression cannot hide behind a short run.
      for (var i = 0; i < 10; i++) {
        est.addFix(stillFix(clock.t));
        est.tick();
        expect(est.current!.state, SpeedState.live,
            reason: 'second $i: the receiver is delivering a good fix, so '
                '"no signal" would be a false statement');
        expect(est.current!.vSmoothMps, 0.0);
        clock.advance(const Duration(seconds: 1));
      }
      expect(est.current!.quality, SpeedSignalQuality.good,
          reason: 'the position accuracy is being refreshed by these fixes, '
              'so the grade must not decay either');
    });

    test('the frozen average is not touched, so pulling away is not blended',
        () {
      // The branch refreshes the AGE and nothing else. If it had decayed or
      // re-seeded `_ewma`, the first sample after pulling away would be
      // smoothed against a number nobody measured (0042 §3.2 forbids inventing
      // a deceleration; inventing one is exactly what a decay would be).
      final (:clock, :est) = rolledToAStop();
      final parked = est.current!.vSmoothMps;
      for (var i = 0; i < 5; i++) {
        est.addFix(stillFix(clock.t));
        clock.advance(const Duration(seconds: 1));
      }
      expect(est.current!.vSmoothMps, parked);

      // Pulling away. `live` was never left, so this is an ordinary EWMA step
      // from the real stored average (~0.66 m/s), not a post-gap re-seed.
      est.addFix(_fix(clock.t, 6.0));
      expect(est.current!.state, SpeedState.live);
      expect(est.current!.vSmoothMps, lessThan(6.0),
          reason: 'the smoother must still be smoothing, not re-seeding');
      expect(est.current!.vSmoothMps, greaterThan(0.0));
    });

    test('Android, which reports a real 0 with an uncertainty, is unaffected',
        () {
      // The other way a genuine stop arrives: API 26+ reports `speed = 0`
      // AND a speed accuracy, so `toFix` keeps it and this is an ORDINARY
      // accepted sample that never reaches the new branch. Pinned so that a
      // future edit to the branch cannot change the platform that was already
      // correct.
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 4.0, speedAcc: 0.5));
      clock.advance(const Duration(seconds: 1));
      for (var i = 0; i < 6; i++) {
        est.addFix(_fix(clock.t, 0.0, speedAcc: 0.5));
        est.tick();
        expect(est.current!.state, SpeedState.live);
        clock.advance(const Duration(seconds: 1));
      }
      expect(est.current!.vSmoothMps, 0.0);
      expect(est.current!.speedAccuracyMps, closeTo(0.5, 1e-9),
          reason: 'these samples go through the normal path, ± included');
    });

    test('a moving reading is unaffected — fixes with a speed always smooth',
        () {
      // The third row of the ruling's table: nothing about a ride changes.
      // Same vectors as the smoothing group, asserted here as a regression
      // guard on the new early-return specifically.
      final (:clock, :est) = build();
      final raw = [5.0, 7.0, 9.0, 11.0, 13.0];
      double? previous;
      for (final v in raw) {
        est.addFix(_fix(clock.t, v));
        final now = est.current!;
        expect(now.state, SpeedState.live);
        if (previous != null) expect(now.vSmoothMps, greaterThan(previous));
        previous = now.vSmoothMps;
        clock.advance(const Duration(seconds: 1));
      }
      expect(previous, lessThan(13.0));
    });

    group('the gates that keep G2 intact', () {
      test('a displayed NON-zero still goes holding → lost', () {
        // The gate that matters most. At 10 m/s the speed field vanishing means
        // we have stopped measuring a MOVING vehicle, and freezing 10 m/s as
        // `live` is precisely the lie 0042 G2 forbids.
        final (:clock, :est) = build();
        est.addFix(_fix(clock.t, 10.0));
        for (var i = 0; i < 6; i++) {
          clock.advance(const Duration(seconds: 1));
          est.addFix(stillFix(clock.t));
          est.tick();
        }
        expect(est.current!.state, SpeedState.lost);
        expect(est.current!.vSmoothMps, closeTo(10.0, 1e-9));
      });

      test('a bad position fix is still junk, however low the reading is', () {
        // A real signal loss where the chip keeps talking: no speed AND a
        // useless accuracy. The zero on screen must not launder it into
        // evidence that anything is alive.
        final (:clock, :est) = rolledToAStop();
        for (var i = 0; i < 6; i++) {
          est.addFix(stillFix(clock.t, acc: 120.0));
          est.tick();
          clock.advance(const Duration(seconds: 1));
        }
        expect(est.current!.state, SpeedState.lost);
      });

      test('an unreported accuracy (infinity) is junk too', () {
        // `toFix` maps "no accuracy reported" to `double.infinity` rather than
        // to 0 m (B3), so the floor is what throws it out. That mapping is the
        // only thing standing between this branch and a phone that reports
        // nothing at all.
        final (:clock, :est) = rolledToAStop();
        for (var i = 0; i < 6; i++) {
          est.addFix(stillFix(clock.t, acc: double.infinity));
          est.tick();
          clock.advance(const Duration(seconds: 1));
        }
        expect(est.current!.state, SpeedState.lost);
      });

      test('it never CREATES a zero: a phone that never reported speed waits',
          () {
        // The pre-API-26 Android case the adapter errs toward silence for. With
        // no measurement behind it there is no zero to sustain, so the card
        // stays on "waiting for a fix" — `current` null — rather than printing
        // a 0 km/h nobody measured.
        final (:clock, :est) = build();
        for (var i = 0; i < 10; i++) {
          est.addFix(stillFix(clock.t));
          est.tick();
          clock.advance(const Duration(seconds: 1));
        }
        expect(est.current, isNull);
      });

      test('it never RESURRECTS: a lost series is not revived by a null speed',
          () {
        // Sustaining is not the same as recovering. Only a fix carrying an
        // actual speed may end a loss, because only that is a measurement — the
        // vehicle may well have moved during the gap.
        final (:clock, :est) = rolledToAStop();
        clock.advance(const Duration(seconds: 10));
        est.tick();
        expect(est.current!.state, SpeedState.lost);

        est.addFix(stillFix(clock.t));
        expect(est.current!.state, SpeedState.lost,
            reason: 'a fix with no speed cannot end a signal loss');

        est.addFix(_fix(clock.t, 0.1));
        expect(est.current!.state, SpeedState.live,
            reason: 'a fix that measures something can, and does');
      });
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
    //
    // 🔵 `dart:math` joined the list on 2026-08-19 (design 0071), because the
    // display curve was `(1−α)^(Δt/T)` and there is no `pow` in `dart:core`.
    // 🔵 It LEFT again the same day (design 0073): the curve was replaced by
    // `level + k·slope·Δ`, which is three multiplications and two comparisons.
    // The list stays EXACT rather than becoming a "does not contain flutter"
    // check, because an exact list is what forces the next addition to be
    // argued for in a diff instead of slipping in — and it is why the removal
    // showed up here rather than being noticed by nobody.
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

  // ==========================================================================
  // design 0073 — trend extrapolation (`speedWithTrend` / `displaySpeedMpsAt`)
  // ==========================================================================
  //
  // 🔵 THIS GROUP REPLACES design 0071's "the display curve". The curve is
  // gone; so are its tests. What replaced them is listed here rather than in a
  // commit message, because the reason for the swap is not obvious from either
  // version on its own.
  //
  // WHAT 0071 DID, AND WHY IT WAS NOT ENOUGH. 0071 read the same EWMA as a
  // ramp instead of a staircase, so the digits stopped hopping once a second.
  // But the ramp ran from the PREVIOUS smoothed value to the new one — it
  // pointed at the past — so the smoother it was drawn, the later the reading
  // began to move. Two rides later the owner's complaint was unchanged and
  // 0071 §8.2 had already written down why: matching the AVERAGE lag is not
  // the same as matching the LEADING EDGE, and α is the only knob a ramp has.
  // 0073 §2.2 finishes the argument with the ceiling — even α = 1, i.e. no
  // smoothing whatever, still lags 0.5 s at a 1 Hz sample rate.
  //
  // WHAT 0073 DOES. `v_display = level + k·slope·Δ`. The trend is design
  // 0044's least squares slope, already computed, from the speed series itself
  // — no new sensor, and specifically not the inertial dead reckoning design
  // 0042 §4 "丙" archived. Δ is how long ago the sample now on screen was
  // actually measured. So a new sample no longer has to TRAVEL anywhere: it
  // moves `level` up a step and resets `Δ` to nearly zero at the same instant,
  // and the two changes cancel.
  //
  // 🔴 WHAT PAYS FOR IT, and what these tests are really guarding. This is the
  // first time this project has put a number on screen that is not on the
  // series it records — 0071's curve at least passed through `v_k` at every
  // sampling instant, and this does not. The ruling that allowed it (0073 §7
  // Q2, 2026-08-19) rests entirely on FIVE CLAMPS being real:
  //
  //   C1  never extrapolate unless the speed is live      → #1
  //   C2  the horizon has a ceiling                       → #2
  //   C3  no trend, or a trend inside the noise → level   → #3, #4
  //   C4  the compensation has a ceiling                  → #5
  //   C5  it fades out at the still-clamp                 → #6, #7
  //
  // Each is tested on its own, because "the five together produce a sensible
  // number" is what an implementation that had only three of them would also
  // pass. #12 is the one that must never go green for the wrong reason: the
  // recorded series design 0044 differentiates and design 0061 stores has to
  // be bit-for-bit what it was.
  group('design 0073: trend extrapolation', () {
    const T = Duration(seconds: 1);
    const cfg = SpeedEstimatorConfig();
    const trend = TrendConfig();

    /// `T(1−α)/α` — the filter's own steady-state lag, the part of Δ that is
    /// not measurable from the sample (0073 §3.3.1).
    const filterLag = Duration(microseconds: 176471); // 1 s · 0.15/0.85

    /// `Δ_max = T + λ_cap + T(1−α)/α` (C2).
    const horizonMax = Duration(microseconds: 1676471);

    /// Everything except α at the shipped defaults, so a test that is ABOUT α
    /// can say so out loud instead of inheriting it.
    SpeedEstimatorConfig cfgWithAlpha(double alpha) =>
        SpeedEstimatorConfig(alpha: alpha);

    test('#0 the shipped constants are the ones the ruling names', () {
      // Pinned because NOTHING ELSE IN THIS SUITE PINS THEM. Every other
      // assertion here is an inequality or a `closeTo` that would hold for a
      // range of values, so without this line k could be changed to 2.0 and
      // the suite would stay green.
      //
      // ⚠️ These are ROAD-TEST knobs (0073 §7 Q3, ruled 2026-08-19: k = 0.7,
      // C = ±10 km/h). They are expected to move — what they are not allowed
      // to do is move silently, because both feed a number the rider reads as
      // their speed.
      expect(cfg.alpha, 0.85,
          reason: 'design 0073 §7 Q6 ruled α UNCHANGED — one thing at a time, '
              'or the road test cannot tell whose fault the result is');
      expect(cfg.samplingPeriod, T,
          reason: 'must mirror GeolocatorSpeedSource.speedSamplingPeriod');
      expect(trend.k, 0.7);
      expect(trend.capMps, closeTo(10 / 3.6, 1e-12),
          reason: 'C = ±10 km/h. 0073 §3.5.3: ±8 starts biting at Δ ≈ 1.06 s '
              'at 3 m/s², i.e. it would cut off the tail of the very launch '
              'this feature exists for');
      expect(trend.lambdaCap, const Duration(milliseconds: 500),
          reason: 'provisional until `lag_p90` from the speed-timing log');

      // 🔴 THE MIRROR. `TrendConfig.aDeadMps2` is a copy of design 0044's
      // deadband, copied because `accel_estimator.dart` imports
      // `speed_estimator.dart` and importing back would be a cycle (0073 §2.5
      // #1). A copy nobody checks is a copy that drifts, and the drift would be
      // silent: the acceleration ROW would go quiet at one threshold while the
      // speed reading kept extrapolating on a slope below it.
      expect(trend.aDeadMps2, const AccelEstimatorConfig().aDeadMps2,
          reason: 'C3② must use design 0044\'s deadband, not a second one');
    });

    test('#1 🔴 C1 — a held or lost reading is frozen, however far time runs',
        () {
      // THE RED-LINE TEST (0042 G2). Extrapolating into a tunnel would be the
      // mirror image of the decay animation 0042 §3.2 forbids by name: one
      // pretends to slow down, the other pretends to speed up, and neither was
      // measured. 0073 §4.3 row 4 is the line the whole ruling rests on — "no
      // measurement ⇒ it stops" — and this is that line, executable.
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 12.0));
      clock.advance(const Duration(milliseconds: 2500));
      est.tick();
      expect(est.current!.state, SpeedState.holding,
          reason: 'precondition: the sample aged past T_hold');

      final frozen = est.current!.vSmoothMps;
      for (final d in [Duration.zero, T, T * 10, T * 600]) {
        expect(est.displaySpeedMpsAt(clock.t.add(d), slopeMps2: 3.0), frozen,
            reason: 'held, +$d, with a 3 m/s² trend in hand — the number must '
                'not move by so much as a bit');
      }

      clock.advance(const Duration(seconds: 2));
      est.tick();
      expect(est.current!.state, SpeedState.lost);
      for (final d in [Duration.zero, T, T * 10]) {
        expect(est.displaySpeedMpsAt(clock.t.add(d), slopeMps2: -3.0), frozen,
            reason: 'lost demotes the number to a footnote; footnotes do not '
                'extrapolate, in either direction');
      }
    });

    test('#2 🔴 C2 — the horizon has a ceiling, so the reading parks', () {
      // Without this a sample that stopped arriving would be carried forward
      // for ever, which is design 0042 §4 "丙" (integrate until you have a
      // fantasy) reached by accident rather than on purpose. G5: the distance
      // between what is drawn and what was measured must have a bound you can
      // write on paper, and `Δ_max` is it.
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 20.0));
      const slope = 2.0;
      final level = est.current!.vSmoothMps;

      // Δ = (at − lastLiveAt) + T(1−α)/α, and the fix is stamped now, so at
      // t = 0 the horizon is the filter's lag alone.
      expect(est.trendHorizonAt(clock.t), filterLag);
      expect(est.trendHorizonMax, horizonMax);

      final capped = level +
          trend.k * slope * (horizonMax.inMicroseconds / 1e6);
      for (final d in [
        horizonMax,
        horizonMax + T,
        const Duration(seconds: 60),
        const Duration(hours: 1),
      ]) {
        expect(est.displaySpeedMpsAt(clock.t.add(d), slopeMps2: slope),
            closeTo(capped, 1e-9),
            reason: 'at +$d the reading was still climbing — a late sample '
                'must degrade to the pre-0073 behaviour (it parks), not to an '
                'ever-growing invention');
      }
      // And it is genuinely still moving BEFORE the ceiling, or the assertion
      // above would pass on an implementation that never extrapolates at all.
      expect(est.displaySpeedMpsAt(clock.t.add(T), slopeMps2: slope),
          lessThan(capped - 1e-6));
    });

    test('#3 C3① — no trend available ⇒ the plain level, bit for bit', () {
      // The acceleration window is warming (fewer than three samples, or
      // spanning less than T_w − T_slack) or suppressed. The controller passes
      // null, and null must mean "show what we have", not "assume zero and
      // show what we have" — those happen to agree here, and they would not if
      // anyone ever gave the null case a default slope.
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 15.0));
      clock.advance(T);
      est.addFix(_fix(clock.t, 18.0));
      final level = est.current!.vSmoothMps;
      for (final d in [Duration.zero, T, T * 2]) {
        expect(est.displaySpeedMpsAt(clock.t.add(d)), level,
            reason: 'no slope argument at all');
        expect(est.displaySpeedMpsAt(clock.t.add(d), slopeMps2: null), level);
      }
    });

    test('#4 C3② — a slope inside design 0044\'s deadband is not a trend', () {
      // GNSS speed noise is 0.1–0.5 m/s (0044 §2.2) and differentiating it
      // gives numbers of the same order as a real scooter launch. Below the
      // deadband the sign of the slope is not information, and multiplying a
      // coin flip by Δ and putting it on the speedo is worse than showing the
      // level.
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 20.0));
      final level = est.current!.vSmoothMps;
      final at = clock.t.add(const Duration(milliseconds: 500));

      for (final s in [0.0, 0.14, -0.14, 0.1499]) {
        expect(est.displaySpeedMpsAt(at, slopeMps2: s), level,
            reason: 'slope $s is inside the 0.15 m/s² deadband');
      }
      for (final s in [0.16, -0.16, 3.0]) {
        expect(est.displaySpeedMpsAt(at, slopeMps2: s), isNot(level),
            reason: 'slope $s is outside it and must reach the reading — '
                'otherwise this test would pass on a build that never '
                'extrapolates');
      }
    });

    test('#5 🔴 C4 — the compensation is capped at C, whatever the slope', () {
      // "The owner accepts overshoot" (2026-08-19) is not "the owner accepts
      // any overshoot" (0073 R4). A slope that is briefly enormous — a GNSS
      // glitch, a three-point fit through a jump — must not be multiplied by
      // the horizon and shown.
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 20.0));
      final level = est.current!.vSmoothMps;
      final far = clock.t.add(const Duration(seconds: 2)); // Δ pinned at Δ_max

      for (final s in [10.0, 50.0, 1000.0]) {
        expect(est.displaySpeedMpsAt(far, slopeMps2: s),
            closeTo(level + trend.capMps, 1e-9),
            reason: 'slope $s m/s² must still only be worth C = 10 km/h');
      }
      for (final s in [-10.0, -50.0]) {
        expect(est.displaySpeedMpsAt(far, slopeMps2: s),
            closeTo(level - trend.capMps, 1e-9),
            reason: 'and the cap is symmetric — braking may not UNDER-report '
                'without limit either');
      }
      // Below the cap nothing is clipped: 0.7 · 2 · 1.676 = 2.35 < 2.78.
      expect(est.displaySpeedMpsAt(far, slopeMps2: 2.0),
          lessThan(level + trend.capMps - 1e-6));
    });

    test('#6 🔴 C5 — the still-clamp cannot be crossed by extrapolation', () {
      // 0073 §7 Q10, and it was a HOLE in the four clamps as first drafted:
      // extrapolation could push a crawling reading over `vStillMps` and back,
      // producing a 0 ⇄ 4 km/h flicker — a louder version of the "2 km/h at a
      // red light" the clamp exists to remove.
      //
      // 🔑 The fade band is exactly `[vStillMps, vStillMps + C]`, and that is
      // not a coincidence — it makes crossing STRUCTURALLY impossible rather
      // than unlikely. The compensation is at most `C` (C4) and is then scaled
      // by `(level − vStillMps)/C`, so it is at most `level − vStillMps`: it
      // can reach the clamp and never pass it. The sweep below is the proof.
      const vStill = 3.0 / 3.6;
      for (var i = 0; i <= 60; i++) {
        final level = vStill + i * 0.1;
        for (final s in [-1000.0, -50.0, -3.0, -0.2, 0.2, 3.0, 1000.0]) {
          for (final dtMs in [0, 200, 700, 1676, 5000]) {
            final v = speedWithTrend(
              level: level,
              slopeMps2: s,
              horizon: Duration(milliseconds: dtMs),
              horizonMax: horizonMax,
              vStillMps: vStill,
            );
            expect(v, greaterThanOrEqualTo(vStill - 1e-12),
                reason: 'level $level, slope $s, Δ ${dtMs}ms fell through the '
                    'still-clamp to $v — that is the 0 ⇄ 4 km/h flicker');
          }
        }
      }
      // The band itself, so the ramp is pinned and not just its consequence.
      expect(stillFade(vStill, vStillMps: vStill), 0.0);
      expect(stillFade(vStill + trend.capMps, vStillMps: vStill), 1.0);
      expect(stillFade(vStill + trend.capMps / 2, vStillMps: vStill),
          closeTo(0.5, 1e-12));
      expect(stillFade(vStill + 100, vStillMps: vStill), 1.0,
          reason: 'well clear of the clamp the feature is at full strength — '
              'C5 is a floor guard, not a global discount');
    });

    test('#7 the order is extrapolate → clamp → format', () {
      // 0073 §3.8 pin 3, inherited from 0071. The clamp is `_clampStill`, the
      // same one the RECORDED value goes through, so the drawn number and the
      // stored number cannot disagree about where zero starts.
      final (:clock, :est) = build();
      // Straddle the clamp: 2.0 m/s averaged with a 0.1 m/s sample gives 0.385,
      // which is under `vStillMps` and therefore reads 0.
      est.addFix(_fix(clock.t, 2.0));
      clock.advance(T);
      est.addFix(_fix(clock.t, 0.1));
      expect(est.current!.vSmoothMps, 0.0,
          reason: 'precondition: the recorded value is a clamped zero');

      for (final s in [3.0, -3.0, 0.5]) {
        expect(est.displaySpeedMpsAt(clock.t.add(const Duration(seconds: 1)),
                slopeMps2: s),
            0.0,
            reason: 'a clamped zero must stay a hard 0, not creep to 0.4 with '
                'a slope of $s applied to it');
      }
      // `speedWithTrend` itself does NOT clamp — one clamp, one place.
      expect(
          speedWithTrend(
            level: 0.385,
            slopeMps2: 3.0,
            horizon: T,
            horizonMax: horizonMax,
            vStillMps: 3.0 / 3.6,
          ),
          0.385,
          reason: 'C5 zeroes the compensation here; the CLAMP is the caller\'s');
    });

    test('#8 Δ never runs backwards — a fix stamped in the future', () {
      // Clock skew between the GNSS chip and the system clock is real and
      // signed (`TelemetryController`'s speed-timing line records `lag` signed
      // precisely so a negative median shows up rather than being hidden). A
      // negative horizon would extrapolate BACKWARDS, i.e. invent a
      // deceleration out of a clock difference.
      final (:clock, :est) = build();
      est.addFix(SpeedFix(
        speedMps: 20.0,
        horizontalAccuracyM: 5.0,
        timestamp: clock.t.add(const Duration(seconds: 2)), // the future
      ));
      final level = est.current!.vSmoothMps;
      expect(est.trendHorizonAt(clock.t).isNegative, isTrue,
          reason: 'precondition: the raw horizon really is negative here');
      expect(est.displaySpeedMpsAt(clock.t, slopeMps2: 3.0), level);
      expect(est.displaySpeedMpsAt(clock.t, slopeMps2: -3.0), level);
    });

    test('#9 🔴 G6 — k = 0 is bit-for-bit the pre-0073 reading', () {
      // The way out if the road test goes badly is editing a constant, not
      // reverting a merge, and a claim like that is worth exactly as much as
      // its test. `vSmoothMps` is what the card drew before design 0071 and
      // what it draws with the feature off.
      final clock = _Clock(t0);
      final est = SpeedEstimator(
        config: const SpeedEstimatorConfig(trend: TrendConfig(k: 0)),
        now: () => clock.t,
      );
      for (final v in [5.0, 9.0, 14.0, 20.0, 27.0, 1.0]) {
        est.addFix(_fix(clock.t, v));
        final recorded = est.current!.vSmoothMps;
        for (final ms in [0, 100, 500, 900, 3000]) {
          for (final s in [3.0, -3.0, 0.0, 100.0]) {
            expect(
                est.displaySpeedMpsAt(
                    clock.t.add(Duration(milliseconds: ms)), slopeMps2: s),
                recorded,
                reason: 'k = 0 must be the plain EWMA at +${ms}ms, slope $s');
          }
        }
        clock.advance(T);
      }
    });

    test('#10 Δ is measured per sample, not assumed', () {
      // 0073 §7 Q4 (a). `t − lastLiveAt` is not an ESTIMATE of the delivery
      // latency — `lastLiveAt` is the platform's own stamp, so the difference
      // is how long ago this very sample was taken. A sample that arrived
      // 300 ms late is extrapolated 300 ms further, and that is correct rather
      // than noisy.
      final (:clock, :est) = build();
      const lateBy = Duration(milliseconds: 300);
      est.addFix(SpeedFix(
        speedMps: 20.0,
        horizontalAccuracyM: 5.0,
        timestamp: clock.t.subtract(lateBy),
      ));
      expect(est.trendHorizonAt(clock.t), lateBy + filterLag);

      final level = est.current!.vSmoothMps;
      const slope = 2.0;
      expect(
          est.displaySpeedMpsAt(clock.t, slopeMps2: slope),
          closeTo(
              level +
                  trend.k *
                      slope *
                      ((lateBy + filterLag).inMicroseconds / 1e6),
              1e-9));

      // A punctual sample gets a shorter horizon, which is the whole point.
      final (clock: c2, est: e2) = build();
      e2.addFix(_fix(c2.t, 20.0));
      expect(e2.trendHorizonAt(c2.t), filterLag);
      expect(e2.displaySpeedMpsAt(c2.t, slopeMps2: slope),
          lessThan(est.displaySpeedMpsAt(clock.t, slopeMps2: slope)!));
    });

    test('#11 the ticker predicate matches what actually moves', () {
      // The card's per-frame loop is armed by this rather than by watching the
      // value change (a value-watching loop cannot tell "it stopped" from "no
      // time passed", so it shuts off on the first cheap frame). If the
      // predicate says false while the value is still moving, the reading
      // freezes between samples and no arithmetic test would notice.
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 20.0));

      expect(est.displayTrendActiveAt(clock.t, slopeMps2: 2.0), isTrue);
      expect(est.displayTrendActiveAt(clock.t), isFalse,
          reason: 'no trend, nothing to draw');
      expect(est.displayTrendActiveAt(clock.t, slopeMps2: 0.1), isFalse,
          reason: 'inside the deadband, nothing to draw');
      expect(est.displayTrendActiveAt(clock.t.add(horizonMax), slopeMps2: 2.0),
          isFalse,
          reason: 'the horizon has hit its ceiling; only a new sample can move '
              'the reading now');

      clock.advance(const Duration(milliseconds: 2500));
      est.tick();
      expect(est.current!.state, SpeedState.holding);
      expect(est.displayTrendActiveAt(clock.t, slopeMps2: 2.0), isFalse,
          reason: 'C1 — a held reading does not move, so the ticker must not '
              'be held open for it (0042 G4)');
    });

    group('#12 🔴 the recorded series is untouched (G4)', () {
      test('(a) displaySpeedMpsAt emits nothing — it is a pure read', () async {
        final (:clock, :est) = build();
        final estimates = <SpeedEstimate>[];
        final edges = <SpeedStateTransition>[];
        final s1 = est.estimates.listen(estimates.add);
        final s2 = est.transitions.listen(edges.add);

        est.addFix(_fix(clock.t, 10.0));
        await pumpEventQueue();
        estimates.clear();
        edges.clear();

        // Sixty reads, i.e. one second of the card's ticker at 60 Hz.
        for (var i = 0; i < 60; i++) {
          est.displaySpeedMpsAt(clock.t.add(Duration(milliseconds: i * 16)),
              slopeMps2: 3.0);
          est.displayTrendActiveAt(clock.t.add(Duration(milliseconds: i * 16)),
              slopeMps2: 3.0);
        }
        await pumpEventQueue();
        expect(estimates, isEmpty,
            reason: 'the card asks this 60 times a second; if it published, '
                'design 0044 would differentiate the EXTRAPOLATION and design '
                '0061 would store it');
        expect(edges, isEmpty);
        expect(est.current!.vSmoothMps, closeTo(10.0, 1e-9),
            reason: 'and `current` did not move either');

        await s1.cancel();
        await s2.cancel();
        await est.dispose();
      });

      test('(b) with α pinned, the series is bit-for-bit the pre-0071 one',
          () async {
        // ⚠️ α IS PINNED TO 0.5 HERE ON PURPOSE, and the test is worthless
        // without that: the shipped α has moved twice since this series was
        // first written down (0.5 ⇒ 0.632 ⇒ 0.85), so a version of this test
        // that used the default would be asserting that the rulings had not
        // happened. What is under test is the OTHER half — that neither 0071's
        // curve nor 0073's extrapolation perturbed the recorded series behind
        // α's back.
        //
        // The expected values are the discrete EWMA by hand at α=0.5:
        //   5                                    (first sample seeds)
        //   0.5·7  + 0.5·5     = 6
        //   0.5·9  + 0.5·6     = 7.5
        //   0.5·11 + 0.5·7.5   = 9.25
        //   0.5·13 + 0.5·9.25  = 11.125
        // All five are exact in binary (halves, quarters, eighths), so this is
        // an equality test rather than a `closeTo` — "逐位元相同" literally.
        final clock = _Clock(t0);
        final est = SpeedEstimator(
          config: cfgWithAlpha(0.5),
          now: () => clock.t,
        );
        final values = <double>[];
        final stamps = <DateTime>[];
        final sub = est.estimates.listen((e) {
          values.add(e.vSmoothMps);
          stamps.add(e.t);
        });

        final anchors = <DateTime>[];
        for (final v in [5.0, 7.0, 9.0, 11.0, 13.0]) {
          anchors.add(clock.t);
          est.addFix(_fix(clock.t, v));
          // Read the display value between every pair of samples, exactly as
          // the card does. If any of these mutated state, the series below
          // would move.
          for (var i = 1; i < 10; i++) {
            est.displaySpeedMpsAt(clock.t.add(Duration(milliseconds: i * 100)),
                slopeMps2: 2.0);
          }
          clock.advance(T);
        }
        await pumpEventQueue();

        expect(values, [5.0, 6.0, 7.5, 9.25, 11.125]);
        expect(stamps, anchors,
            reason: 'the rhythm has to be untouched too — one estimate per '
                'accepted fix, stamped on our clock at the moment it arrived');

        await sub.cancel();
        await est.dispose();
      });
    });

    test('#13 🔴 FB-56: a parked scooter does not creep upward', () {
      // 0073 §3.8 pin 4. 0071 protected this with a comment in `addFix` ("do
      // not re-anchor the curve"); there is no anchor now, so the protection
      // has to come from the clamps. C5 is what supplies it: the level is
      // under the still-clamp, so the fade is 0 and NO slope — however stale,
      // however large — can lift the reading off zero.
      //
      // The vectors straddle the clamp on purpose. A naive version of this
      // test parks the scooter at 0 m/s, reads 0 either way, and proves
      // nothing.
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 2.0));
      clock.advance(T);
      est.addFix(_fix(clock.t, 0.1)); // level 0.385 ⇒ clamped 0
      expect(est.current!.vSmoothMps, 0.0);

      for (var i = 0; i < 10; i++) {
        clock.advance(T);
        // The stationary iOS fix: good position, no Doppler speed at all.
        est.addFix(SpeedFix(
          speedMps: null,
          horizontalAccuracyM: 5.0,
          timestamp: clock.t,
        ));
        expect(est.current!.state, SpeedState.live,
            reason: 'precondition: FB-56 kept the reading alive');
        for (final ms in [0, 250, 500, 900]) {
          expect(
              est.displaySpeedMpsAt(clock.t.add(Duration(milliseconds: ms)),
                  slopeMps2: 3.0),
              0.0,
              reason: 'second $i, +${ms}ms: a parked scooter crawled off zero');
        }
      }
    });

    test('#14 reset() takes the reading with it', () {
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 18.0));
      expect(est.displaySpeedMpsAt(clock.t, slopeMps2: 2.0),
          greaterThan(18.0));

      est.reset();
      expect(est.current, isNull);
      expect(est.displaySpeedMpsAt(clock.t, slopeMps2: 2.0), isNull,
          reason: 'null is "there is no series to draw". Answering 0.0 would '
              'be a reading nobody measured, and answering 18.0 would be last '
              "session's speed on a card that says it is waiting for a fix");
      clock.advance(T);
      expect(est.displaySpeedMpsAt(clock.t, slopeMps2: 2.0), isNull);
      expect(est.displayTrendActiveAt(clock.t, slopeMps2: 2.0), isFalse);
    });
  });

}
