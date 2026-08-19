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
    // 🔵 `dart:math` joined the list on 2026-08-19 (design 0071): the display
    // curve is `(1−α)^(Δt/T)` and there is no `pow` in `dart:core`. The
    // property this test defends is unchanged — it is "no Flutter, no plugin",
    // i.e. nothing that needs a device to run — and `dart:math` is a pure-Dart
    // core library with no platform binding, available on every target this app
    // has. The list stays EXACT rather than becoming a "does not contain
    // flutter" check, because an exact list is what forces the next addition to
    // be argued for in a diff instead of slipping in.
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
    expect(imports, ['dart:async', 'dart:math']);
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
  // design 0071 — the display curve (`displaySpeedMpsAt`)
  // ==========================================================================
  //
  // THE FIELD REPORT. "增減速的時候數字跳動慢" — clarified by the owner to mean
  // the reading moves ONCE A SECOND and jumps several km/h when it does, not
  // that it trails the true speed. At 2 m/s² that is a 7 km/h step, and a whole
  // 0 → 50 km/h launch shows the rider about seven different numbers.
  //
  // WHAT CHANGED. Nothing about the filter. The same EWMA is now READ as the
  // curve it always was — `v_disp(t) = z_k + (v_{k−1} − z_k)·(1−α)^(Δt/T)` —
  // instead of as the staircase the card used to draw. On every sampling
  // instant the two agree to the last bit (test #1), which is the whole of
  // 0071's answer to 0042 G2: it is not a new estimate and not a prediction.
  //
  // WHAT IT COST. Sweeping between two samples always adds lag, so α went from
  // 0.5 to 0.632 in the same change to buy it back (§3.3). Test #7 is that
  // trade, made executable; test #6(b) is the guard that the RECORDED series
  // design 0044 and design 0061 consume did not move as a side effect.
  group('design 0071: the display curve', () {
    const T = Duration(seconds: 1);

    /// Everything except α at the shipped defaults, so a test that is ABOUT α
    /// can say so out loud instead of inheriting it.
    SpeedEstimatorConfig cfgWithAlpha(double alpha) =>
        SpeedEstimatorConfig(alpha: alpha);

    test('#0 the shipped α is the ruled 0.632, not the pre-0071 0.5', () {
      // Pinned because NOTHING ELSE IN THIS SUITE PINS IT. Every existing
      // smoothing assertion is a `greaterThan`/`lessThan` on a monotone ramp or
      // a `closeTo` on a converged value, all of which hold for any α in
      // (0, 1) — so before this line α could have been changed to anything at
      // all and the suite would have stayed green. It is an input to design
      // 0044's slope and to design 0061's stored series; it does not get to
      // move silently.
      expect(const SpeedEstimatorConfig().alpha, 0.632,
          reason: 'design 0071 §3.3 / §7 Q2, ruled 2026-08-19');
      expect(const SpeedEstimatorConfig().displayRampPeriod, T,
          reason: 'must mirror GeolocatorSpeedSource.speedSamplingPeriod');
    });

    test('#1 🔴 at every sampling instant the curve IS the recorded value', () {
      // The red-line test. If this ever fails, the card is drawing a number
      // that is not on the series design 0044 differentiates and design 0061
      // stores, and 0042 G2's "no number nobody measured" is gone with it.
      final (:clock, :est) = build();
      double? previousRecorded;
      for (final v in [5.0, 7.0, 9.0, 11.0, 13.0]) {
        final anchor = clock.t;
        est.addFix(_fix(anchor, v));
        final recorded = est.current!.vSmoothMps;

        // Property 1: the curve STARTS where the last one ended, so a sample
        // landing does not make the digits jump.
        if (previousRecorded != null) {
          expect(est.displaySpeedMpsAt(anchor), closeTo(previousRecorded, 1e-9),
              reason: 'a sample arriving must not move the reading by itself');
        }
        // Property 2: one sampling period later it has arrived at exactly the
        // value the old stepped card jumped to.
        expect(est.displaySpeedMpsAt(anchor.add(T)), closeTo(recorded, 1e-9),
            reason: 'v_disp(t_k + T) must equal α·z_k + (1−α)·v_{k−1}');

        previousRecorded = recorded;
        clock.advance(T);
      }
    });

    test('#2 the curve stops on arrival — it never runs past the sample', () {
      // `min(Δt, T)` in one assertion. Without the clamp the reading would keep
      // sliding while no fix is arriving, which is a decay animation wearing a
      // different hat (0042 §3.2 forbids it by name).
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 20.0));
      clock.advance(T);
      final anchor = clock.t;
      est.addFix(_fix(anchor, 30.0));

      final arrived = est.displaySpeedMpsAt(anchor.add(T));
      expect(arrived, closeTo(est.current!.vSmoothMps, 1e-9));
      for (final over in [T * 2, T * 3, T * 10]) {
        expect(est.displaySpeedMpsAt(anchor.add(over)), arrived,
            reason: 'the curve must be frozen at v_k from t_k + T onwards, '
                'not still moving at t_k + $over');
      }
    });

    test('#3 a held reading does not sweep — holding and lost are frozen', () {
      // §3.5 pin 1. The moment the state stops being `live`, the number stops
      // being a measurement, and 0042 G2 says a frozen number must be visibly
      // frozen — a value still gliding under a "held" badge is the exact
      // contradiction the badge exists to prevent.
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 12.0));
      clock.advance(const Duration(milliseconds: 2500));
      est.tick();
      expect(est.current!.state, SpeedState.holding,
          reason: 'precondition: the sample aged past T_hold');

      final frozen = est.current!.vSmoothMps;
      for (final d in [Duration.zero, T, T * 2]) {
        expect(est.displaySpeedMpsAt(clock.t.add(d)), frozen);
      }

      clock.advance(const Duration(seconds: 2));
      est.tick();
      expect(est.current!.state, SpeedState.lost);
      for (final d in [Duration.zero, T, T * 5]) {
        expect(est.displaySpeedMpsAt(clock.t.add(d)), frozen,
            reason: 'lost demotes the number to a footnote; footnotes do not '
                'animate');
      }
    });

    test('#4 🔴 the FB-56 sustain branch does not re-anchor the curve', () {
      // §3.5 pin 4, and the vectors are chosen so a re-anchor would be VISIBLE.
      // A parked scooter's numbers are all under the still-clamp, so a naive
      // version of this test reads 0 either way and proves nothing.
      //
      // The setup instead straddles the clamp: the average is 2.0 m/s when a
      // 0.1 m/s sample lands, so the curve sweeps 2.0 → 0.799 (0.632·0.1 +
      // 0.368·2.0), i.e. from 7.2 km/h on screen down through the 3 km/h floor
      // to a clamped 0. A null-speed fix arriving after that must NOT restart
      // the sweep — nothing entered the smoother, so the target has not moved,
      // and re-anchoring would make a stationary scooter's reading jump back to
      // 7 km/h and crawl down again once a second, for ever.
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 2.0));
      clock.advance(T);
      final anchor = clock.t;
      est.addFix(_fix(anchor, 0.1));
      expect(est.displaySpeedMpsAt(anchor), closeTo(2.0, 1e-9),
          reason: 'precondition: the sweep starts ABOVE the still-clamp');
      expect(est.current!.vSmoothMps, 0.0,
          reason: 'precondition: it ends below it, so the card reads 0');

      clock.advance(T);
      expect(est.displaySpeedMpsAt(clock.t), 0.0);

      // The stationary iOS fix: good position, no Doppler speed at all.
      est.addFix(SpeedFix(
        speedMps: null,
        horizontalAccuracyM: 5.0,
        timestamp: clock.t,
      ));
      expect(est.current!.state, SpeedState.live,
          reason: 'precondition: FB-56 kept the reading alive');
      for (final d in [
        Duration.zero,
        const Duration(milliseconds: 200),
        const Duration(milliseconds: 500),
        T,
      ]) {
        expect(est.displaySpeedMpsAt(clock.t.add(d)), 0.0,
            reason: 'the curve was re-anchored at +$d — a fix that never '
                'entered the smoother must not restart the sweep (§3.5 pin 4)');
      }
    });

    test('#5 reset() takes the curve with it', () {
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 18.0));
      expect(est.displaySpeedMpsAt(clock.t.add(T)), closeTo(18.0, 1e-9));

      est.reset();
      expect(est.current, isNull);
      expect(est.displaySpeedMpsAt(clock.t), isNull,
          reason: 'null is "there is no series to draw". Answering 0.0 would '
              'be a reading nobody measured, and answering 18.0 would be last '
              "session's speed on a card that says it is waiting for a fix");
      clock.advance(T);
      expect(est.displaySpeedMpsAt(clock.t), isNull);
    });

    group('#6 🔴 the recorded series is untouched (G3)', () {
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
          est.displaySpeedMpsAt(clock.t.add(Duration(milliseconds: i * 16)));
        }
        await pumpEventQueue();
        expect(estimates, isEmpty,
            reason: 'the card asks this 60 times a second; if it published, '
                'design 0044 would differentiate the ANIMATION and design 0061 '
                'would store it');
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
        // without that. Design 0071 §3.3 CHANGES the shipped α from 0.5 to
        // 0.632, which by design changes every value on this series — so a
        // version of this test that used the default would be asserting the
        // ruling had not happened. What is under test is the OTHER half: that
        // introducing the display curve did not perturb the recorded series
        // behind α's back.
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
          // Read the curve between every pair of samples, exactly as the card
          // does. If any of these mutated state, the series below would move.
          for (var i = 1; i < 10; i++) {
            est.displaySpeedMpsAt(clock.t.add(Duration(milliseconds: i * 100)));
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

    test('#7 🔴 the lag budget does not get worse (G2), and α is why', () {
      // 0071 G2 made executable: "the average lag after this change must not be
      // greater than it was before it". Three readings of the same synthetic
      // ride are compared, and the middle one is the whole argument for
      // touching α at all.
      //
      // The ride: constant 2 m/s² (a brisk scooter launch), 1 Hz samples that
      // report the true speed exactly. Lag is integrated over seconds 20–30 by
      // the midpoint rule, so the seeding transient is long gone and the
      // quadrature error (~1e-5 m/s) is far below the differences being judged.
      const a = 2.0;
      const first = 20, last = 30, sub = 100;
      const stepUs = 1000000 ~/ sub;

      /// The card BEFORE 0071: a discrete EWMA held flat for a whole period.
      /// Reimplemented here rather than fetched from git history, because a
      /// baseline you cannot read next to the assertion is not a baseline.
      double steppedLag(double alpha) {
        var ewma = 0.0;
        var sum = 0.0;
        var n = 0;
        for (var k = 0; k < last; k++) {
          final z = a * k;
          ewma = k == 0 ? z : alpha * z + (1 - alpha) * ewma;
          if (k < first) continue;
          for (var j = 0; j < sub; j++) {
            final t = k + (j + 0.5) / sub;
            sum += a * t - ewma; // the number on screen is flat across [k, k+1)
            n++;
          }
        }
        return sum / n;
      }

      /// The card AFTER 0071, driven through the real estimator.
      double sweptLag(double alpha) {
        final clock = _Clock(t0);
        final est = SpeedEstimator(
          config: cfgWithAlpha(alpha),
          now: () => clock.t,
        );
        var sum = 0.0;
        var n = 0;
        for (var k = 0; k < last; k++) {
          final anchor = clock.t;
          est.addFix(_fix(anchor, a * k));
          if (k >= first) {
            for (var j = 0; j < sub; j++) {
              final offset = Duration(microseconds: stepUs ~/ 2 + j * stepUs);
              sum += a * (k + (j + 0.5) / sub) -
                  est.displaySpeedMpsAt(anchor.add(offset))!;
              n++;
            }
          }
          clock.advance(T);
        }
        return sum / n;
      }

      final before = steppedLag(0.5); // 2·(0.5 + 1.000) = 3.000 m/s
      final naive = sweptLag(0.5); // 2·(0.5 + 1.443) = 3.885 m/s
      final shipped = sweptLag(0.632); // 2·(0.5 + 1.000) = 3.001 m/s

      expect(before, closeTo(3.0, 0.01));
      expect(naive, closeTo(3.885, 0.01));
      expect(shipped, closeTo(3.001, 0.01));

      // R1, and the reason §3.3 is not optional: shipping the sweep on its own
      // would have made the reading ~0.44 s SLOWER, which is the other half of
      // what the user complained about.
      expect(naive, greaterThan(before * 1.2),
          reason: 'a continuous curve at the OLD α is a regression, not a fix');
      // G2 itself. The 0.1 % allowance is the ruled α being the three-digit
      // 0.632 rather than 1 − e⁻¹ = 0.63212…, which leaves τ 0.033 % long —
      // 0.3 ms of lag. See `SpeedEstimatorConfig.alpha`.
      expect(shipped, lessThanOrEqualTo(before * 1.001),
          reason: '0071 G2: the sweep must not cost the rider any lag');
    });

    test('#8 🔴 coming out of a tunnel does not sweep the old speed', () {
      // §3.5 pin 5, and it is the one pin that can violate an EXISTING ruling
      // rather than just look wrong. 0042 §3.2 forbids blending the speed from
      // before a gap into the samples after it, and `addFix` obeys that by
      // re-seeding the average. A display curve that still ran the general rule
      // would sweep 25 → 3 m/s over the first second back — showing every
      // number in between, none of which was ever measured. Drawing the
      // forbidden blend instead of averaging it in is not a loophole.
      final (:clock, :est) = build();
      est.addFix(_fix(clock.t, 25.0));
      expect(est.current!.vSmoothMps, closeTo(25.0, 1e-9));

      clock.advance(const Duration(seconds: 10));
      est.tick();
      expect(est.current!.state, SpeedState.lost,
          reason: 'precondition: the tunnel ended the series');

      final anchor = clock.t;
      est.addFix(_fix(anchor, 3.0));
      expect(est.current!.state, SpeedState.live);
      for (var ms = 0; ms <= 2000; ms += 50) {
        final v = est.displaySpeedMpsAt(anchor.add(Duration(milliseconds: ms)))!;
        expect(v, closeTo(3.0, 1e-9),
            reason: 'at +${ms}ms the reading was $v — the curve out of a gap '
                'must be FLAT (§3.5 pin 5 / 0042 §3.2)');
      }
    });
  });

}
