// AccelEstimator — the slope of the speed curve, and when to refuse to draw it
// (design 0044 §3.2 / impl plan Phase G, test vectors 1-4).
//
// 🔴 The first group below is the reason this module exists. Every other test
// here checks arithmetic; that one checks a REFUSAL. While the speed estimator
// holds a frozen value, the naive implementation of this feature emits a
// flawless 0.00 m/s² — the difference of a repeated number — and the rider
// reads it as "steady speed". Design 0044 G2 forbids exactly that, and nothing
// but a test can tell the two zeros apart afterwards.
//
// The tunnel case is driven through a REAL [SpeedEstimator] rather than through
// hand-built [SpeedEstimate]s. This project has shipped three defects that sat
// at a call site while the callee's own tests stayed green, so the edges that
// suppress this module — including the silent-looking one that `reset()` emits —
// are exercised as they actually arrive: over two broadcast streams, from the
// real state machine, with a hand-driven clock.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/state/accel_estimator.dart';
import 'package:open_smart_batt/state/speed_estimator.dart';

class _Clock {
  _Clock(this.t);
  DateTime t;
  void advance(Duration d) => t = t.add(d);
}

/// Let the two broadcast streams deliver. Both controllers dispatch through the
/// microtask queue, so one turn is enough and the FIFO order is what a
/// production listener sees too.
Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  final t0 = DateTime.utc(2026, 8, 7, 10, 0);

  SpeedEstimate est(
    DateTime t,
    double v, {
    SpeedState state = SpeedState.live,
  }) =>
      SpeedEstimate(
        t: t,
        vSmoothMps: v,
        state: state,
        quality: SpeedSignalQuality.good,
      );

  group('vector 1 — a straight speed ramp gives back its own slope', () {
    test('accelerating: the fitted slope is the real one, both signs',
        () async {
      for (final a in [2.0, -1.5]) {
        final accel = AccelEstimator();
        addTearDown(accel.dispose);
        final out = <AccelEstimate>[];
        accel.estimates.listen(out.add);

        for (var i = 0; i <= 5; i++) {
          accel.onSpeedEstimate(
              est(t0.add(Duration(seconds: i)), 20.0 + a * i));
        }
        await _pump();
        expect(accel.state, AccelState.live);
        expect(out, isNotEmpty);
        for (final e in out) {
          expect(e.aMps2, closeTo(a, 1e-9),
              reason: 'least squares through a straight line is that line');
        }
        expect(accel.current!.aMps2, closeTo(a, 1e-9));
      }
    });

    test('a sample every 500 ms fits the same line as one every second',
        () async {
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);
      for (var i = 0; i <= 8; i++) {
        accel.onSpeedEstimate(
            est(t0.add(Duration(milliseconds: 500 * i)), 5.0 + 1.25 * 0.5 * i));
      }
      await _pump();
      expect(out.last.aMps2, closeTo(1.25, 1e-9));
    });
  });

  group('vector 2 — a frozen speed must not differentiate to zero', () {
    test('🔴 holding samples repeat the last value; nothing is emitted',
        () async {
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);

      for (var i = 0; i <= 3; i++) {
        accel.onSpeedEstimate(est(t0.add(Duration(seconds: i)), 10.0 + 2.0 * i));
      }
      await _pump();
      expect(accel.state, AccelState.live);
      final emittedWhileLive = out.length;
      expect(emittedWhileLive, greaterThan(0));
      final frozen = accel.current!.aMps2;
      expect(frozen, closeTo(2.0, 1e-9));

      // The tunnel. The card is showing 16.0 m/s and marking it as held; the
      // estimator keeps saying so. Differencing this run yields 0.0 m/s² —
      // indistinguishable on screen from a measured steady speed.
      for (var i = 4; i <= 8; i++) {
        accel.onSpeedEstimate(
          est(t0.add(Duration(seconds: i)), 16.0, state: SpeedState.holding),
        );
      }
      await _pump();
      expect(accel.state, AccelState.suppressed);
      expect(out.length, emittedWhileLive,
          reason: 'a frozen run emitted an acceleration — that is 0044 G2');
      expect(accel.current, isNull);
      expect(accel.windowLength, 0, reason: 'the window must be emptied too');
    });

    test('lost samples suppress for the same reason', () async {
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);
      for (var i = 0; i <= 3; i++) {
        accel.onSpeedEstimate(est(t0.add(Duration(seconds: i)), 4.0 * i));
      }
      await _pump();
      final n = out.length;
      expect(n, greaterThan(0));
      accel.onSpeedEstimate(
          est(t0.add(const Duration(seconds: 4)), 12.0, state: SpeedState.lost));
      await _pump();
      expect(accel.state, AccelState.suppressed);
      expect(out.length, n);
    });

    test(
      'through the real estimator: a tunnel suppresses, and recovery refits '
      'from an empty window',
      () async {
        final clock = _Clock(t0);
        final speed = SpeedEstimator(now: () => clock.t);
        addTearDown(speed.dispose);
        final accel = AccelEstimator();
        addTearDown(accel.dispose);
        final subs = [
          speed.estimates.listen(accel.onSpeedEstimate),
          speed.transitions.listen(accel.onTransition),
        ];
        addTearDown(() {
          for (final s in subs) {
            s.cancel();
          }
        });
        final out = <AccelEstimate>[];
        accel.estimates.listen(out.add);

        // Riding at a steady 25 m/s for three seconds.
        for (var i = 0; i <= 2; i++) {
          speed.addFix(SpeedFix(
            speedMps: 25.0,
            horizontalAccuracyM: 5,
            timestamp: clock.t,
          ));
          await _pump();
          if (i < 2) clock.advance(const Duration(seconds: 1));
        }
        expect(accel.state, AccelState.live);
        final beforeTunnel = out.length;

        // Into the tunnel: samples stop, the ticker keeps running. The speed
        // card freezes at 25 m/s and says so; this module must go quiet.
        for (var i = 0; i < 6; i++) {
          clock.advance(const Duration(seconds: 1));
          speed.tick();
          await _pump();
        }
        expect(speed.current!.state, SpeedState.lost);
        expect(accel.state, AccelState.suppressed);
        expect(out.length, beforeTunnel,
            reason: 'the held/lost stretch produced an acceleration');

        // Out the other side, half an hour later and much slower. A window that
        // kept the pre-tunnel 25 m/s would fit a steep NEGATIVE slope across
        // the join — an emergency stop that never happened.
        clock.advance(const Duration(minutes: 30));
        for (var i = 0; i <= 2; i++) {
          speed.addFix(SpeedFix(
            speedMps: 10.0 + i,
            horizontalAccuracyM: 5,
            timestamp: clock.t,
          ));
          await _pump();
          if (i < 2) clock.advance(const Duration(seconds: 1));
        }
        expect(accel.state, AccelState.live);
        expect(out.length, beforeTunnel + 1,
            reason: 'exactly one slope, and only once the new window was full');
        expect(out.last.aMps2, greaterThan(0),
            reason: 'the rider was speeding up after the tunnel, not braking');
      },
    );

    test('reset() suppresses even though it emits no estimate', () async {
      // Every AppLifecycleState.inactive runs _stop() → reset(); pulling down
      // the notification shade is enough. The only trace on the wire is a
      // transition, so a module that watched estimates alone would splice the
      // two sessions together.
      final clock = _Clock(t0);
      final speed = SpeedEstimator(now: () => clock.t);
      addTearDown(speed.dispose);
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final subs = [
        speed.estimates.listen(accel.onSpeedEstimate),
        speed.transitions.listen(accel.onTransition),
      ];
      addTearDown(() {
        for (final s in subs) {
          s.cancel();
        }
      });
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);

      for (var i = 0; i <= 2; i++) {
        speed.addFix(SpeedFix(
          speedMps: 20.0 + i,
          horizontalAccuracyM: 5,
          timestamp: clock.t,
        ));
        await _pump();
        if (i < 2) clock.advance(const Duration(seconds: 1));
      }
      expect(accel.state, AccelState.live);
      final before = out.length;

      speed.reset();
      await _pump();
      expect(accel.state, AccelState.suppressed);
      expect(accel.windowLength, 0);
      expect(out.length, before);
    });

    test('a resumed series does not inherit the old window', () {
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      for (var i = 0; i <= 3; i++) {
        accel.onSpeedEstimate(est(t0.add(Duration(seconds: i)), 30.0 - 3.0 * i));
      }
      expect(accel.state, AccelState.live);
      accel.onTransition(SpeedStateTransition(
        from: SpeedState.live,
        to: SpeedState.lost,
        at: t0.add(const Duration(seconds: 4)),
      ));
      expect(accel.windowLength, 0);
      accel.onTransition(SpeedStateTransition(
        from: SpeedState.lost,
        to: SpeedState.live,
        at: t0.add(const Duration(seconds: 60)),
      ));
      expect(accel.state, AccelState.warming);
      accel.onSpeedEstimate(est(t0.add(const Duration(seconds: 60)), 5.0));
      expect(accel.windowLength, 1, reason: 'one new sample, not five');
      expect(accel.current, isNull);
    });

    test('the two streams may arrive in either order', () {
      // Belt and braces against the real wiring: `addFix` adds the transition
      // before the estimate, but that is two separate broadcast controllers and
      // this module must not depend on their interleaving.
      for (final transitionFirst in [true, false]) {
        final accel = AccelEstimator();
        addTearDown(accel.dispose);
        for (var i = 0; i <= 3; i++) {
          accel.onSpeedEstimate(est(t0.add(Duration(seconds: i)), 2.0 * i));
        }
        accel.onSpeedEstimate(est(
          t0.add(const Duration(seconds: 4)),
          6.0,
          state: SpeedState.holding,
        ));
        expect(accel.state, AccelState.suppressed);

        final back = t0.add(const Duration(seconds: 20));
        final tr = SpeedStateTransition(
            from: SpeedState.holding, to: SpeedState.live, at: back);
        final sample = est(back, 9.0);
        if (transitionFirst) {
          accel.onTransition(tr);
          accel.onSpeedEstimate(sample);
        } else {
          accel.onSpeedEstimate(sample);
          accel.onTransition(tr);
        }
        expect(accel.state, AccelState.warming);
        expect(accel.windowLength, 1,
            reason: 'the resumed sample survives either ordering');
      }
    });
  });

  group('vector 3 — stationary noise reads 0 without changing the record', () {
    test('a sub-deadband slope displays as 0.0 and never flips sign', () async {
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);

      // A true drift of 0.05 m/s² with 0.04 m/s of jitter on top: alternating
      // raw slopes, all of them well inside the 0.15 m/s² deadband.
      const jitter = [0.0, 0.04, -0.03, 0.02, -0.04, 0.03, -0.02, 0.01];
      for (var i = 0; i < jitter.length; i++) {
        accel.onSpeedEstimate(
          est(t0.add(Duration(seconds: i)), 1.0 + 0.05 * i + jitter[i]),
        );
      }
      await _pump();
      expect(out.length, greaterThan(2));
      final signs = out.map((e) => displayAccel(e.aMps2).sign).toSet();
      expect(signs, {0.0}, reason: 'the display flickered between + and −');
      for (final e in out) {
        expect(displayAccel(e.aMps2), 0.0);
      }
      // …and the raw series is untouched: not deadbanded, not quantised.
      expect(out.any((e) => e.aMps2 != 0.0), isTrue);
      expect(
        out.any((e) => e.aMps2.abs() > 1e-9 && e.aMps2.abs() < 0.15),
        isTrue,
        reason: 'a value the display suppresses must still reach history raw',
      );
    });

    test('displayAccel deadbands, then quantises, and leaves the sign alone',
        () {
      expect(displayAccel(0.149), 0.0);
      expect(displayAccel(-0.149), 0.0);
      // Exclusive: 0.15 is not "inside" the 0.15 deadband. (It quantises to
      // 0.1 rather than 0.2 because 0.15/0.1 is 1.4999999999999998 in binary
      // floating point — a boundary artefact, not a rule.)
      expect(displayAccel(0.15), isNot(0.0));
      expect(displayAccel(0.16), closeTo(0.2, 1e-9));
      expect(displayAccel(-1.24), closeTo(-1.2, 1e-9));
      expect(displayAccel(2.06), closeTo(2.1, 1e-9));
      // The deadband is a display decision only; a config with none passes the
      // raw value through, which is what the history column always gets.
      const raw = AccelEstimatorConfig(aDeadMps2: 0, displayQuantumMps2: 0);
      expect(displayAccel(0.037, raw), 0.037);
    });
  });

  group('vector 4 — an unfull window emits nothing', () {
    test('fewer than nMin samples: no output', () async {
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);
      accel.onSpeedEstimate(est(t0, 4.0));
      accel.onSpeedEstimate(est(t0.add(const Duration(seconds: 2)), 8.0));
      await _pump();
      expect(accel.windowLength, 2);
      expect(accel.state, AccelState.warming);
      expect(out, isEmpty);
      expect(accel.current, isNull);
    });

    test('enough samples but a span shorter than tWindow: no output',
        () async {
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);
      for (var i = 0; i <= 3; i++) {
        accel.onSpeedEstimate(
            est(t0.add(Duration(milliseconds: 200 * i)), 4.0 + 0.4 * i));
      }
      await _pump();
      expect(accel.windowLength, 4);
      expect(accel.state, AccelState.warming,
          reason: '0.6 s of samples is not a two second average');
      expect(out, isEmpty);
    });

    test('the first output arrives exactly when both conditions are met',
        () async {
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);
      accel.onSpeedEstimate(est(t0, 4.0));
      accel.onSpeedEstimate(est(t0.add(const Duration(seconds: 1)), 6.0));
      await _pump();
      expect(out, isEmpty);
      accel.onSpeedEstimate(est(t0.add(const Duration(seconds: 2)), 8.0));
      await _pump();
      expect(out.length, 1);
      expect(out.single.aMps2, closeTo(2.0, 1e-9));
      expect(out.single.t, t0.add(const Duration(seconds: 2)));
    });

    test('a gap with no transition falls back to warming instead of fitting '
        'across the hole', () async {
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);
      for (var i = 0; i <= 2; i++) {
        accel.onSpeedEstimate(est(t0.add(Duration(seconds: i)), 4.0 + 2.0 * i));
      }
      await _pump();
      expect(accel.state, AccelState.live);
      accel.onSpeedEstimate(est(t0.add(const Duration(minutes: 5)), 30.0));
      await _pump();
      expect(accel.state, AccelState.warming);
      expect(accel.windowLength, 1);
      expect(out.length, 1, reason: 'no slope may be drawn across the gap');
    });

    test('a timestamp that runs backwards restarts the window', () {
      // The mixed-clock defect that impl plan §1.4 note 2 records was fixed
      // upstream; a negative dt divides into a plausible magnitude with the
      // wrong sign, so this guard stays.
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      for (var i = 0; i <= 2; i++) {
        accel.onSpeedEstimate(est(t0.add(Duration(seconds: i)), 4.0 + 2.0 * i));
      }
      expect(accel.state, AccelState.live);
      accel.onSpeedEstimate(est(t0.add(const Duration(milliseconds: 1750)), 9.0));
      expect(accel.state, AccelState.warming);
      expect(accel.windowLength, 1);
    });

    test('a repeated instant is not new information', () {
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      accel.onSpeedEstimate(est(t0, 4.0));
      accel.onSpeedEstimate(est(t0, 4.2));
      expect(accel.windowLength, 1);
    });

    test(
        '🔴 FB-57: jittered 1 Hz timestamps still fill the window — exact '
        'equality was the bug', () async {
      // As shipped, _prune() capped the span at tWindow while _windowIsFull()
      // demanded >= tWindow, so only a timestamp landing on the boundary to
      // the microsecond could go live. Every real fix carries jitter; the
      // accel column had never held a value in production. The offsets below
      // are a fixed pattern of the tens-of-milliseconds jitter a GNSS clock
      // actually produces — under the old predicate this test emits nothing.
      const jitterMs = [0, 23, -17, 31, -29, 13, -7, 19];
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);
      for (var i = 0; i < jitterMs.length; i++) {
        final t = t0.add(Duration(milliseconds: 1000 * i + jitterMs[i]));
        // Speed is a straight 2.0 m/s² ramp in REAL elapsed time, so the
        // fitted slope has an exact answer despite the jitter.
        final v = 2.0 * (t.difference(t0).inMicroseconds / 1e6);
        accel.onSpeedEstimate(est(t, v));
      }
      await _pump();
      expect(accel.state, AccelState.live);
      expect(out.length, greaterThanOrEqualTo(5),
          reason: 'after warm-up every accepted sample must emit — a jittered '
              'clock is the normal case, not an edge case');
      for (final e in out) {
        expect(e.aMps2, closeTo(2.0, 1e-9));
      }
    });

    test('the window slides: only the last tWindow seconds are fitted',
        () async {
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);
      // Two seconds of hard acceleration, then two of coasting. Once the ramp
      // has slid out, the slope must be the coast, not the average of both.
      final vs = [0.0, 3.0, 6.0, 6.0, 6.0, 6.0];
      for (var i = 0; i < vs.length; i++) {
        accel.onSpeedEstimate(est(t0.add(Duration(seconds: i)), vs[i]));
      }
      await _pump();
      expect(accel.windowLength, 3);
      expect(out.last.aMps2, closeTo(0.0, 1e-9));
      expect(out.first.aMps2, closeTo(3.0, 1e-9));
    });
  });

  // ==========================================================================
  // design 0073 §7 Q9 — the adaptive DISPLAY slope (`displaySlopeMps2`)
  // ==========================================================================
  //
  // 🔴 THE CLAIM UNDER TEST IS A NEGATIVE ONE, so read this before the
  // assertions. Design 0073 extrapolates the SPEED reading along this module's
  // slope, and at a standing start the fixed two-second window makes that slope
  // half its true size — the window still contains the seconds the vehicle was
  // stopped. 0073 §7 Q9's arithmetic: three 1 Hz samples reading `0, 0, a` fit
  // a least squares slope of exactly `a/2`.
  //
  // The fix is a SECOND READING of the SAME buffer, not a second buffer and not
  // a shorter `tWindow`, and the reason is design 0044 §3.5: what this module
  // EMITS is "the average acceleration over the last two seconds", a sentence
  // an analyst reads back off the history column and off design 0061's
  // per-second storage. Shortening the window would have changed that sentence
  // for everyone in order to fix a display. So `estimates` keeps fitting the
  // whole window and `displaySlopeMps2` fits it from the last stationary sample
  // onward — and the tests below check BOTH halves, because a change that only
  // did the first half would look identical from the card.
  group('design 0073 §7 Q9 — the adaptive display slope', () {
    test('🔴 at a standing start the fixed window is half, adaptive is whole',
        () async {
      // 0073 §7 Q9's own vectors, so the number in the design doc and the
      // number here are the same number: samples 0, 0, a at 1 Hz.
      const a = 3.0;
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);

      accel.onSpeedEstimate(est(t0, 0.0));
      accel.onSpeedEstimate(est(t0.add(const Duration(seconds: 1)), 0.0));
      accel.onSpeedEstimate(est(t0.add(const Duration(seconds: 2)), a));
      await _pump();

      expect(accel.state, AccelState.live);
      expect(out.last.aMps2, closeTo(a / 2, 1e-9),
          reason: '🔴 the RECORDED slope must stay `a/2` — it is the two-second '
              'average, and design 0044 §3.5 / design 0061 define it that way. '
              'If this ever reads `a`, the display change leaked into history');
      expect(accel.displaySlopeMps2, closeTo(a, 1e-9),
          reason: 'the DISPLAYED trend drops the stationary half of the window '
              'and recovers the real acceleration');
    });

    test('with no stationary sample in the window it IS the recorded slope',
        () async {
      // The trim only ever removes leading zeros, so in ordinary riding the two
      // readings are the same number — bit for bit, not approximately. That is
      // what makes the adaptive path a launch fix rather than a second, subtly
      // different estimator running all the time.
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);
      final vs = [11.0, 13.7, 16.1, 18.9, 21.2];
      for (var i = 0; i < vs.length; i++) {
        accel.onSpeedEstimate(est(t0.add(Duration(seconds: i)), vs[i]));
        await _pump();
        // Nothing is emitted until the window is full, and the display reading
        // is null for exactly as long (C3①).
        if (out.isEmpty) {
          expect(accel.displaySlopeMps2, isNull);
          continue;
        }
        expect(accel.displaySlopeMps2, out.last.aMps2,
            reason: 'sample \$i: the two readings diverged with no zero in the '
                'window');
      }
    });

    test('the newest sample being still falls back to the whole window',
        () async {
      // Braking to a stop: the trim would leave a single point, which is not a
      // line. Falling back to the full window is also the honest answer — a
      // vehicle that has just stopped should report the deceleration that
      // stopped it, not nothing.
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);
      final vs = [6.0, 3.0, 0.0];
      for (var i = 0; i < vs.length; i++) {
        accel.onSpeedEstimate(est(t0.add(Duration(seconds: i)), vs[i]));
      }
      await _pump();
      expect(out.last.aMps2, closeTo(-3.0, 1e-9));
      expect(accel.displaySlopeMps2, closeTo(-3.0, 1e-9));
    });

    test('a stationary window has no trend to show', () async {
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      for (var i = 0; i < 4; i++) {
        accel.onSpeedEstimate(est(t0.add(Duration(seconds: i)), 0.0));
      }
      await _pump();
      expect(accel.state, AccelState.live);
      expect(accel.displaySlopeMps2, 0.0,
          reason: 'a flat zero window fits a flat zero line, which design '
              "0073's C3② deadband then discards");
    });

    test('🔴 null whenever the window is not live — C3① and 0044 G2', () async {
      // The adaptive reading does NOT loosen the fullness rule. Coming out of a
      // tunnel there is still nothing to extrapolate along for about two
      // seconds, which is design 0073's replacement for 0071 pin 5 and the
      // reason a tunnel cannot be swept across.
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      expect(accel.displaySlopeMps2, isNull, reason: 'warming, empty');

      accel.onSpeedEstimate(est(t0, 10.0));
      accel.onSpeedEstimate(est(t0.add(const Duration(seconds: 1)), 13.0));
      await _pump();
      expect(accel.state, AccelState.warming);
      expect(accel.displaySlopeMps2, isNull,
          reason: 'two points span 1 s — short of T_w − T_slack');

      accel.onSpeedEstimate(est(t0.add(const Duration(seconds: 2)), 16.0));
      await _pump();
      expect(accel.displaySlopeMps2, isNotNull);

      accel.onSpeedEstimate(est(t0.add(const Duration(seconds: 3)), 16.0,
          state: SpeedState.holding));
      await _pump();
      expect(accel.state, AccelState.suppressed);
      expect(accel.displaySlopeMps2, isNull,
          reason: 'a frozen speed differentiates to a flawless 0.0 that nobody '
              'measured — 0044 G2, and 0073 must not reopen it');
    });

    test('reading it a thousand times emits nothing and changes nothing',
        () async {
      // The card asks for this every frame. It is a getter over a buffer it
      // must not disturb.
      final accel = AccelEstimator();
      addTearDown(accel.dispose);
      final out = <AccelEstimate>[];
      accel.estimates.listen(out.add);
      for (var i = 0; i < 4; i++) {
        accel.onSpeedEstimate(est(t0.add(Duration(seconds: i)), i * 3.0));
      }
      await _pump();
      final before = out.length;
      final len = accel.windowLength;
      final value = accel.displaySlopeMps2;
      for (var i = 0; i < 1000; i++) {
        accel.displaySlopeMps2;
      }
      await _pump();
      expect(out.length, before);
      expect(accel.windowLength, len);
      expect(accel.displaySlopeMps2, value);
      expect(accel.current, out.last);
    });
  });
}
