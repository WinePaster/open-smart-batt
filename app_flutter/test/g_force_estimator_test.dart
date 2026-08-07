// design 0045 Phase 0 — the calibration and rotation arithmetic.
//
// 🔴 THE POINT OF THIS FILE, stated before the first test, because it decides
// how every case below is written.
//
// A rotation matrix tested directly always passes. Feed `toBody` a matrix and a
// vector and it returns the product; there is no interesting way for that to be
// wrong. The defects this feature can actually ship all live one step EARLIER —
// in which axes the calibration decided to build the matrix out of:
//
//   * gravity's sign (the sensor reads +9.81 UP, not down);
//   * `up × forward` versus `forward × up` — one gives left, the other right,
//     and both produce a perfectly orthonormal matrix;
//   * forgetting to project the launch onto the horizontal plane;
//   * a mount attitude nobody pictured while writing the code.
//
// None of those are visible from inside the multiply. So every test here starts
// from a MOUNTING ATTITUDE, synthesises what the two sensor streams would
// report with the phone in that attitude, runs the real calibration end to end,
// and only then asks whether a known vehicle-frame acceleration comes back out.
// The attitudes deliberately include mountings that are upside down, sideways
// and skewed — the project's own recurring failure is a judgement whose INPUT
// no test ever looked at (design 0045 brief), and for this feature the input is
// literally which way up the phone is.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/state/g_force_config.dart';
import 'package:open_smart_batt/state/g_force_estimator.dart';

/// A mounting attitude: the three VEHICLE axes written in PHONE coordinates.
typedef Attitude = ({Vec3 forward, Vec3 left, Vec3 up});

/// What the phone's sensors would report for a vehicle-frame vector, given the
/// mount. The inverse of what the calibration is asked to recover.
Vec3 toPhone(Attitude a, Vec3 body) =>
    a.forward.scaled(body.x) + a.left.scaled(body.y) + a.up.scaled(body.z);

Vec3 _rotX(Vec3 v, double deg) {
  final r = deg * math.pi / 180, c = math.cos(r), s = math.sin(r);
  return Vec3(v.x, v.y * c - v.z * s, v.y * s + v.z * c);
}

Vec3 _rotZ(Vec3 v, double deg) {
  final r = deg * math.pi / 180, c = math.cos(r), s = math.sin(r);
  return Vec3(v.x * c - v.y * s, v.x * s + v.y * c, v.z);
}

Attitude _skew(double aboutX, double aboutZ) => (
      forward: _rotZ(_rotX(const Vec3(1, 0, 0), aboutX), aboutZ),
      left: _rotZ(_rotX(const Vec3(0, 1, 0), aboutX), aboutZ),
      up: _rotZ(_rotX(const Vec3(0, 0, 1), aboutX), aboutZ),
    );

/// The mountings under test. Every one of these is a real way to strap a phone
/// to a motorbike, and three of the five put a DIFFERENT phone axis along the
/// direction of travel.
final Map<String, Attitude> attitudes = {
  // Degenerate base case: the phone's own axes already are the vehicle's.
  'aligned': (
    forward: const Vec3(1, 0, 0),
    left: const Vec3(0, 1, 0),
    up: const Vec3(0, 0, 1),
  ),
  // Flat on the tank bag, screen up, top of the phone pointing ahead.
  'flat on tank, top forward': (
    forward: const Vec3(0, 1, 0),
    left: const Vec3(-1, 0, 0),
    up: const Vec3(0, 0, 1),
  ),
  // 🔴 The same mount rotated 180°: top of the phone pointing at the RIDER.
  // A sign error anywhere in the chain reports braking as acceleration here and
  // nowhere else.
  'flat on tank, top backward': (
    forward: const Vec3(0, -1, 0),
    left: const Vec3(1, 0, 0),
    up: const Vec3(0, 0, 1),
  ),
  // Upright in a bar mount, portrait, screen facing the rider — so the phone's
  // +z (out of the screen) points BACKWARD.
  'upright bar mount': (
    forward: const Vec3(0, 0, -1),
    left: const Vec3(-1, 0, 0),
    up: const Vec3(0, 1, 0),
  ),
  // Nobody mounts a phone squarely. 30° of tilt and 40° of yaw.
  'skewed 30/40': _skew(30, 40),
};

/// Drive the real wizard with synthetic sensor data for [att].
CalibrationSession runCalibration(
  Attitude att, {
  Vec3 launchBody = const Vec3(2.0, 0, 0),
  GForceConfig config = const GForceConfig(),
}) {
  final s = CalibrationSession(config: config)..start();
  var t = DateTime.utc(2026, 8, 7);
  // Still, on the frame, for longer than tCal.
  for (var i = 0; i < 170; i++) {
    t = t.add(const Duration(milliseconds: 20));
    s.addLinearSample(Vec3.zero, t);
    // 🔴 +g along UP. A phone lying still reads plus 9.81 towards the sky.
    s.addRawSample(toPhone(att, const Vec3(0, 0, GForceConfig.g0)), t);
  }
  // Then a sustained launch.
  for (var i = 0; i < 80; i++) {
    t = t.add(const Duration(milliseconds: 20));
    s.addLinearSample(toPhone(att, launchBody), t);
  }
  return s;
}

/// Steady-state reading for a constant vehicle-frame acceleration.
GForceReading settle(GForceEstimator e, Attitude att, Vec3 body,
    {int samples = 200}) {
  late GForceReading r;
  for (var i = 0; i < samples; i++) {
    r = e.process(toPhone(att, body));
  }
  return r;
}

void main() {
  group('calibration recovers the vehicle frame from any mounting', () {
    attitudes.forEach((name, att) {
      test('$name — a known acceleration comes back on the right axis', () {
        final s = runCalibration(att);
        expect(s.phase, CalibrationPhase.complete, reason: name);
        final cal = s.result!;
        expect(cal.isUsable, isTrue, reason: name);

        final e = GForceEstimator(cal);

        // Hard acceleration: forward, so POSITIVE, and no lateral component.
        var r = settle(e, att, const Vec3(3.0, 0, 0));
        expect(r.longG, closeTo(3.0 / GForceConfig.g0, 0.02), reason: name);
        expect(r.isBraking, isFalse, reason: name);
        expect(r.latG.abs(), lessThan(0.02), reason: name);

        // 🔴 Braking. This is the case that catches a flipped forward axis, and
        // it is the reason 'flat on tank, top backward' is in the table.
        e.reset();
        r = settle(e, att, const Vec3(-4.0, 0, 0));
        expect(r.longG, closeTo(-4.0 / GForceConfig.g0, 0.02), reason: name);
        expect(r.isBraking, isTrue, reason: name);

        // A LEFT-hand corner pushes along +y. This is the case that catches
        // `forward × up` written where `up × forward` belongs — a mirrored
        // frame that passes every orthonormality check.
        e.reset();
        r = settle(e, att, const Vec3(0, 2.5, 0));
        expect(r.latG, closeTo(2.5 / GForceConfig.g0, 0.02), reason: name);
        expect(r.isLeft, isTrue, reason: name);
        expect(r.longG.abs(), lessThan(0.02), reason: name);

        // And a right-hand corner is its mirror, not a second positive number.
        e.reset();
        r = settle(e, att, const Vec3(0, -2.5, 0));
        expect(r.isLeft, isFalse, reason: name);
        expect(r.latG, closeTo(-2.5 / GForceConfig.g0, 0.02), reason: name);
      });

      test('$name — bumps and gravity do not leak into the horizontal axes',
          () {
        // A vertical jolt is not braking and is not cornering. If "up" were
        // wrong, or the launch heading had kept its vertical component, this is
        // where it shows.
        final cal = runCalibration(att).result!;
        final e = GForceEstimator(cal);
        final r = settle(e, att, const Vec3(0, 0, 5.0));
        expect(r.longG.abs(), lessThan(0.02), reason: name);
        expect(r.latG.abs(), lessThan(0.02), reason: name);
      });
    });

    test('the recovered axes really are an orthonormal right-handed frame', () {
      // Stated separately from the behaviour above so a future change that
      // makes the numbers come out right by accident still has to face this.
      for (final entry in attitudes.entries) {
        final cal = runCalibration(entry.value).result!;
        expect(cal.forwardAxis.magnitude, closeTo(1, 1e-6), reason: entry.key);
        expect(cal.forwardAxis.dot(cal.leftAxis).abs(), lessThan(1e-6),
            reason: entry.key);
        expect(cal.forwardAxis.dot(cal.upAxis).abs(), lessThan(1e-6),
            reason: entry.key);
        expect(cal.forwardAxis.cross(cal.leftAxis).dot(cal.upAxis),
            closeTo(1, 1e-6),
            reason: entry.key);
      }
    });
  });

  group('the launch assumption, and how far it can be bent', () {
    test('a launch taken 10° off straight skews forward by about 10°, no more',
        () {
      // design 0045 §3.2 admits this is an assumption. The value of pinning it
      // is that the error stays BOUNDED and proportional: a slightly crooked
      // launch gives a slightly crooked frame, not a scrambled one.
      const att = (
        forward: Vec3(1, 0, 0),
        left: Vec3(0, 1, 0),
        up: Vec3(0, 0, 1),
      );
      final skewRad = 10 * math.pi / 180;
      final launch =
          Vec3(2.0 * math.cos(skewRad), 2.0 * math.sin(skewRad), 0);
      final cal = runCalibration(att, launchBody: launch).result!;
      final off = cal.forwardAxis.angleDegreesTo(const Vec3(1, 0, 0))!;
      expect(off, closeTo(10, 0.5));

      // What the rider would SEE: a straight 3 m/s² pull leaks at most
      // sin(10°) into the lateral readout. Small enough that the wizard's live
      // ball is a usable check, which is the mitigation the design leans on.
      final e = GForceEstimator(cal);
      final r = settle(e, att, const Vec3(3.0, 0, 0));
      expect(r.latG.abs(), lessThan(3.0 * math.sin(skewRad) / GForceConfig.g0 + 0.01));
      expect(r.longG, greaterThan(0.25));
    });

    test('a vertical-only jolt is not accepted as a heading', () {
      // A pothole while waiting to pull away is a big linear reading with no
      // horizontal part. Inventing a forward axis from it would calibrate the
      // bike to the kerb.
      const att = (
        forward: Vec3(1, 0, 0),
        left: Vec3(0, 1, 0),
        up: Vec3(0, 0, 1),
      );
      final s = runCalibration(att, launchBody: const Vec3(0, 0, 4.0));
      expect(s.phase, CalibrationPhase.waitingLaunch);
      expect(s.result, isNull);
    });

    test('a launch shorter than tFwd does not complete', () {
      final s = CalibrationSession()..start();
      var t = DateTime.utc(2026, 8, 7);
      for (var i = 0; i < 170; i++) {
        t = t.add(const Duration(milliseconds: 20));
        s.addLinearSample(Vec3.zero, t);
        s.addRawSample(const Vec3(0, 0, GForceConfig.g0), t);
      }
      expect(s.phase, CalibrationPhase.waitingLaunch);
      // One second of pulling away, then it stops. Not enough.
      for (var i = 0; i < 50; i++) {
        t = t.add(const Duration(milliseconds: 20));
        s.addLinearSample(const Vec3(2.0, 0, 0), t);
      }
      expect(s.phase, CalibrationPhase.waitingLaunch);
      // …and the partial window is DISCARDED rather than continued, so a
      // stop-start launch cannot be stitched into a heading.
      for (var i = 0; i < 50; i++) {
        t = t.add(const Duration(milliseconds: 20));
        s.addLinearSample(Vec3.zero, t);
      }
      for (var i = 0; i < 50; i++) {
        t = t.add(const Duration(milliseconds: 20));
        s.addLinearSample(const Vec3(2.0, 0, 0), t);
      }
      expect(s.phase, CalibrationPhase.waitingLaunch,
          reason: 'two half launches must not add up to one');
    });
  });

  group('the still window', () {
    test('movement during the gravity window fails the calibration', () {
      final s = CalibrationSession()..start();
      var t = DateTime.utc(2026, 8, 7);
      for (var i = 0; i < 60; i++) {
        t = t.add(const Duration(milliseconds: 20));
        s.addLinearSample(Vec3.zero, t);
        s.addRawSample(const Vec3(0, 0, GForceConfig.g0), t);
      }
      // The user picks the phone up to look at it.
      s.addLinearSample(const Vec3(0, 0, 1.5), t);
      expect(s.phase, CalibrationPhase.failedMotion);
      for (var i = 0; i < 200; i++) {
        t = t.add(const Duration(milliseconds: 20));
        s.addLinearSample(Vec3.zero, t);
        s.addRawSample(const Vec3(0, 0, GForceConfig.g0), t);
      }
      expect(s.phase, CalibrationPhase.failedMotion,
          reason: 'a failed window must not repair itself silently');
      expect(s.result, isNull);
    });

    test('free fall yields no "up" at all', () {
      final s = CalibrationSession()..start();
      var t = DateTime.utc(2026, 8, 7);
      for (var i = 0; i < 170; i++) {
        t = t.add(const Duration(milliseconds: 20));
        s.addRawSample(Vec3.zero, t);
      }
      expect(s.phase, CalibrationPhase.failedMotion);
      expect(s.result, isNull);
    });
  });

  group('validity monitor (design 0045 §3.2)', () {
    late GForceCalibration cal;
    setUp(() {
      cal = runCalibration(attitudes['upright bar mount']!).result!;
    });

    /// Gravity as the phone would report it after the mount is rotated by
    /// [tiltDeg] about the vehicle's forward axis.
    Vec3 tiltedGravity(double tiltDeg) {
      final r = tiltDeg * math.pi / 180;
      final body = Vec3(0, GForceConfig.g0 * math.sin(r),
          GForceConfig.g0 * math.cos(r));
      // Back into phone coordinates through the STORED calibration.
      return cal.forwardAxis.scaled(body.x) +
          cal.leftAxis.scaled(body.y) +
          cal.upAxis.scaled(body.z);
    }

    void feed(CalibrationValidityMonitor m, Vec3 raw, Vec3 linear,
        {int seconds = 5}) {
      var t = DateTime.utc(2026, 8, 7);
      for (var i = 0; i < seconds * 50; i++) {
        t = t.add(const Duration(milliseconds: 20));
        m.addLinearSample(linear, t);
        m.addRawSample(raw, t);
      }
    }

    test('a mount that moved more than the threshold is caught while still',
        () {
      final m = CalibrationValidityMonitor(cal);
      feed(m, tiltedGravity(20), Vec3.zero);
      expect(m.invalidated, isTrue);
    });

    test('a mount that has not moved is left alone', () {
      final m = CalibrationValidityMonitor(cal);
      feed(m, tiltedGravity(5), Vec3.zero);
      expect(m.invalidated, isFalse);
    });

    test('🔴 the same tilt while MOVING is not judged at all', () {
      // Leaning into a corner tilts apparent gravity by tens of degrees on
      // purpose. A check that ran while moving would declare the calibration
      // broken every single bend — which is why §3.2 restricts it to the still
      // window, and why this case is pinned separately from the two above.
      final m = CalibrationValidityMonitor(cal);
      feed(m, tiltedGravity(35), const Vec3(2.0, 1.0, 0));
      expect(m.invalidated, isFalse);
      expect(m.isStill, isFalse);
    });

    test('the still window must be sustained, not merely touched', () {
      final m = CalibrationValidityMonitor(cal);
      var t = DateTime.utc(2026, 8, 7);
      // Half a second of stillness at a time, repeatedly interrupted.
      for (var cycle = 0; cycle < 10; cycle++) {
        for (var i = 0; i < 25; i++) {
          t = t.add(const Duration(milliseconds: 20));
          m.addLinearSample(Vec3.zero, t);
          m.addRawSample(tiltedGravity(30), t);
        }
        t = t.add(const Duration(milliseconds: 20));
        m.addLinearSample(const Vec3(3, 0, 0), t);
      }
      expect(m.invalidated, isFalse);
    });

    test('once tripped it stays tripped until a recalibration', () {
      final m = CalibrationValidityMonitor(cal);
      feed(m, tiltedGravity(20), Vec3.zero);
      expect(m.invalidated, isTrue);
      feed(m, tiltedGravity(0), Vec3.zero);
      expect(m.invalidated, isTrue,
          reason: '"it looks fine again" is not evidence the mount moved back');
      m.reset();
      expect(m.invalidated, isFalse);
    });
  });

  group('display chain: deadband, quantisation, smoothing, peak hold', () {
    final identity = GForceCalibration(
      rotation: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
      calibratedAt: DateTime.utc(2026, 8, 7),
    );
    const att = (
      forward: Vec3(1, 0, 0),
      left: Vec3(0, 1, 0),
      up: Vec3(0, 0, 1),
    );

    test('inside the deadband the readout is a flat zero', () {
      final e = GForceEstimator(identity);
      // 0.02 g of noise: below the 0.03 g deadband.
      final r = settle(e, att, const Vec3(0.02 * GForceConfig.g0, 0, 0));
      expect(r.longG, 0.0);
      expect(r.magnitude, 0.0);
    });

    test('outside it the readout is quantised to 0.01 g', () {
      final e = GForceEstimator(identity);
      final r = settle(e, att, const Vec3(0.12345 * GForceConfig.g0, 0, 0));
      // Two decimals, racing convention. Compare on the hundredths to keep the
      // assertion about the QUANTUM rather than about float formatting.
      expect((r.longG * 100).roundToDouble(), (r.longG * 100));
      expect(r.longG, closeTo(0.12, 0.005));
    });

    test('the recorded value keeps the resolution the display throws away', () {
      // design 0045 §3.7 / design 0044 same rule: what lands is the estimator's
      // number, not the rendered one. A deadbanded 0.0 on screen must not
      // become a 0.0 in the database when the estimator saw something.
      final e = GForceEstimator(identity);
      settle(e, att, const Vec3(0.02 * GForceConfig.g0, 0, 0));
      expect(e.rawLongMs2, closeTo(0.02 * GForceConfig.g0, 0.005));
      expect(e.rawLongMs2, isNot(0.0));
    });

    test('the smoother converges rather than jumping', () {
      final e = GForceEstimator(identity);
      // First sample seeds, so it is NOT a fraction of the truth.
      final first = e.process(const Vec3(2.0, 0, 0));
      expect(first.longG, closeTo(2.0 / GForceConfig.g0, 0.005));
      // A step change is eased into over several samples, not taken whole.
      final next = e.process(const Vec3(-4.0, 0, 0));
      expect(next.longG, greaterThan(-4.0 / GForceConfig.g0));
      final settled = settle(e, att, const Vec3(-4.0, 0, 0));
      expect(settled.longG, closeTo(-4.0 / GForceConfig.g0, 0.02));
    });

    test('peaks are per axis AND combined, and survive the value dropping', () {
      final e = GForceEstimator(identity);
      settle(e, att, const Vec3(-4.0, 0, 0));
      final braked = e.process(const Vec3(-4.0, 0, 0));
      expect(braked.peakLongG, closeTo(4.0 / GForceConfig.g0, 0.02));
      expect(braked.peakLatG, 0.0);

      final corner = settle(e, att, const Vec3(0, 2.5, 0));
      expect(corner.longG.abs(), lessThan(0.02),
          reason: 'the live value came back down');
      expect(corner.peakLongG, closeTo(4.0 / GForceConfig.g0, 0.02),
          reason: 'the peak did not');
      expect(corner.peakLatG, closeTo(2.5 / GForceConfig.g0, 0.02));
      expect(corner.peakG, greaterThanOrEqualTo(corner.peakLatG));
    });

    test('resetPeak zeroes the peaks and nothing else', () {
      final e = GForceEstimator(identity);
      settle(e, att, const Vec3(-4.0, 0, 0));
      e.resetPeak();
      final r = e.process(const Vec3(-4.0, 0, 0));
      expect(r.peakLongG, closeTo(4.0 / GForceConfig.g0, 0.02),
          reason: 'the live value is still there and re-establishes the peak');
      expect(r.longG, closeTo(-4.0 / GForceConfig.g0, 0.02));
    });

    test('reset clears the smoother too, so a new ride starts from nothing',
        () {
      final e = GForceEstimator(identity);
      settle(e, att, const Vec3(-4.0, 0, 0));
      e.reset();
      expect(e.hasSample, isFalse);
      expect(e.rawLongMs2, 0.0);
      final r = e.process(const Vec3(0, 0, 0));
      expect(r.peakG, 0.0);
    });
  });

  group('storage shape', () {
    test('round trips', () {
      final cal = runCalibration(attitudes['skewed 30/40']!).result!;
      final back = GForceCalibration.decode(cal.encode())!;
      for (var i = 0; i < 9; i++) {
        expect(back.rotation[i], closeTo(cal.rotation[i], 1e-9));
      }
      expect(back.calibratedAt.toUtc(), cal.calibratedAt.toUtc());
    });

    test('every kind of unusable content decodes to null, never to a guess',
        () {
      for (final bad in <Object?>[
        null,
        '',
        'not json',
        '[]',
        '{}',
        '{"m":[1,0,0],"at":0}', // too short
        '{"m":[1,0,0,0,1,0,0,0,1]}', // no timestamp
        '{"m":["a",0,0,0,1,0,0,0,1],"at":0}', // not numbers
        '{"m":[2,0,0,0,1,0,0,0,1],"at":0}', // not unit length
        '{"m":[1,0,0,1,0,0,0,0,1],"at":0}', // rows not orthogonal
        // 🔴 A MIRRORED frame. Orthonormal, unit length, and it swaps left for
        // right — the one corruption that would produce confident, wrong,
        // perfectly plausible cornering numbers.
        '{"m":[1,0,0,0,-1,0,0,0,1],"at":0}',
      ]) {
        expect(GForceCalibration.decode(bad), isNull, reason: '$bad');
      }
    });

    test('fromAxes refuses to build what decode would refuse to read', () {
      // Otherwise a bad calibration is persisted now and rejected on the next
      // launch, which reads to the user as "it forgot".
      expect(
        GForceCalibration.fromAxes(
          forward: const Vec3(1, 0, 0),
          left: const Vec3(1, 0, 0),
          up: const Vec3(0, 0, 1),
          at: DateTime.utc(2026, 8, 7),
        ),
        isNull,
      );
      expect(
        GForceCalibration.fromAxes(
          forward: Vec3.zero,
          left: const Vec3(0, 1, 0),
          up: const Vec3(0, 0, 1),
          at: DateTime.utc(2026, 8, 7),
        ),
        isNull,
      );
    });
  });
}
