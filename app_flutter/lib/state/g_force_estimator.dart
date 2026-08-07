/// OpenSmartBatt — G meter arithmetic (design 0045 Phase 0).
///
/// PURE Dart, and deliberately so: **nothing in this file imports a sensor
/// plugin.** The controller next door turns platform events into [Vec3] and
/// hands them here, which is what lets every rule below be tested with
/// synthetic vectors — including the ones that only appear when the phone is
/// mounted the "wrong" way round.
///
/// 🔴 That last part is the whole reason the split is worth its seam. Rotation
/// arithmetic tested on its own always passes: give a matrix the right input and
/// it returns the right output. The defect this feature can actually ship is a
/// matrix built from the wrong axes — a sign flip, a swapped cross product, a
/// mirrored frame — and NONE of those are visible from inside the multiply.
/// They are only visible if the test starts from a physical mounting attitude,
/// synthesises what the sensors would report in that attitude, runs the whole
/// calibration, and then asks whether a known vehicle-frame acceleration comes
/// back. That is what `g_force_estimator_test.dart` does, and why it builds its
/// inputs from `R_true` rather than from a hand-written matrix.
///
/// ## What the sensors report, stated once
///
/// * `accelerometerEvent` is PROPER acceleration and INCLUDES gravity. A phone
///   lying still reads **+9.81 m/s² along whichever axis points at the sky** —
///   not −9.81. Design 0045 §3.2 words the same fact as "gravity vector ĝ, so
///   −ĝ is up"; that is the field-vector convention, and this file uses the
///   sensor-reading one. The two differ by a sign, which is exactly the sort of
///   difference that has to be written down rather than inferred.
/// * `userAccelerometerEvent` is the OS's gravity-free linear acceleration
///   (design 0045 §3.3 案甲). Still-detection and the launch heading both read
///   this one; only the gravity window reads the raw stream.
///
/// ## The vehicle frame
///
/// x = forward, y = left, z = up, right-handed. So a rider accelerating gets
/// positive x, braking gets negative x, and a LEFT turn's centripetal
/// acceleration points along +y.
library;

import 'dart:math' as math;

import '../models/g_force_calibration.dart';
import 'g_force_config.dart';

export '../models/g_force_calibration.dart' show Vec3, GForceCalibration;

/// Where the two-step wizard has got to (design 0045 §3.2).
enum CalibrationPhase {
  /// Nothing started.
  idle,

  /// Averaging the raw stream to find "up". The phone must not move.
  samplingGravity,

  /// "Up" is fixed; waiting for a straight-line launch to fix "forward".
  waitingLaunch,

  /// [CalibrationSession.result] is available.
  complete,

  /// The phone moved during the gravity window, so the average would have been
  /// gravity plus whatever else was happening. Start over.
  ///
  /// A separate state rather than a silent restart: the user needs to be told
  /// why nothing happened, or they will conclude the button is broken.
  failedMotion,
}

/// The two-step calibration (design 0045 §3.2), as a state machine.
///
/// Step 1 (still) is standard practice and carries no guesswork — it is what
/// any spirit level does. Step 2 (launch) rests on an ASSUMPTION that has not
/// been road-tested: that the first sustained acceleration after calibration is
/// roughly straight ahead. A launch taken while turning skews "forward". The
/// mitigation is not more arithmetic, it is that the wizard's last page shows
/// the live ball so the user can watch a straight accelerate push the dot
/// straight up — and re-run it in five seconds if it does not.
class CalibrationSession {
  CalibrationSession({this.config = const GForceConfig()});

  final GForceConfig config;

  CalibrationPhase _phase = CalibrationPhase.idle;
  CalibrationPhase get phase => _phase;

  GForceCalibration? _result;

  /// Non-null exactly when [phase] is [CalibrationPhase.complete].
  GForceCalibration? get result => _result;

  // --- gravity window ---
  Vec3 _gravitySum = Vec3.zero;
  int _gravityCount = 0;
  DateTime? _gravityStart;
  Vec3? _up;

  // --- launch window ---
  Vec3 _launchSum = Vec3.zero;
  int _launchCount = 0;
  DateTime? _launchStart;

  /// Begin (or restart) the wizard.
  void start() {
    reset();
    _phase = CalibrationPhase.samplingGravity;
  }

  void reset() {
    _phase = CalibrationPhase.idle;
    _result = null;
    _gravitySum = Vec3.zero;
    _gravityCount = 0;
    _gravityStart = null;
    _up = null;
    _clearLaunch();
  }

  void _clearLaunch() {
    _launchSum = Vec3.zero;
    _launchCount = 0;
    _launchStart = null;
  }

  /// 0…1 progress through the still window, for the wizard's ring.
  double get gravityProgress {
    final start = _gravityStart;
    if (start == null || _phase != CalibrationPhase.samplingGravity) {
      return _up == null ? 0 : 1;
    }
    final elapsed = _lastGravityAt!.difference(start).inMicroseconds;
    return (elapsed / config.tCal.inMicroseconds).clamp(0.0, 1.0);
  }

  DateTime? _lastGravityAt;

  /// Feed one RAW (gravity-bearing) sample.
  void addRawSample(Vec3 a, DateTime t) {
    if (_phase != CalibrationPhase.samplingGravity) return;
    _gravityStart ??= t;
    _lastGravityAt = t;
    _gravitySum = _gravitySum + a;
    _gravityCount++;
    if (t.difference(_gravityStart!) < config.tCal) return;
    // Enough samples that one stray reading cannot decide "up". At the game
    // sampling rate three seconds is ~150 samples, so this only ever fires when
    // the stream is starved — in which case refusing is the honest answer.
    if (_gravityCount < 5) return;
    final up = _gravitySum.scaled(1 / _gravityCount).normalized;
    if (up == null) {
      // Free fall, or a sensor returning zeros. There is no "up" to be had.
      _phase = CalibrationPhase.failedMotion;
      return;
    }
    _up = up;
    _phase = CalibrationPhase.waitingLaunch;
  }

  /// Feed one LINEAR (gravity-free) sample.
  void addLinearSample(Vec3 a, DateTime t) {
    switch (_phase) {
      case CalibrationPhase.samplingGravity:
        // The still check. Without it a phone being carried to the bike would
        // average "gravity plus walking" and call the result up.
        if (a.magnitude > config.stillEpsMs2) {
          _phase = CalibrationPhase.failedMotion;
        }
      case CalibrationPhase.waitingLaunch:
        _accumulateLaunch(a, t);
      case CalibrationPhase.idle:
      case CalibrationPhase.complete:
      case CalibrationPhase.failedMotion:
        return;
    }
  }

  void _accumulateLaunch(Vec3 a, DateTime t) {
    if (a.magnitude < config.aFwdMs2) {
      // The launch has to be SUSTAINED. A pothole is a big number for one
      // sample; pulling away is a big number for a second and a half.
      _clearLaunch();
      return;
    }
    _launchStart ??= t;
    _launchSum = _launchSum + a;
    _launchCount++;
    if (t.difference(_launchStart!) < config.tFwd) return;
    final up = _up!;
    final mean = _launchSum.scaled(1 / _launchCount);
    // Strip the vertical part before calling it a heading: a launch measured on
    // a slope carries a component along `up`, and leaving it in would tilt
    // "forward" out of the vehicle's horizontal plane.
    final horizontal = mean - up.scaled(mean.dot(up));
    final forward = horizontal.normalized;
    if (forward == null) {
      // Purely vertical — a bump, not a launch. Keep waiting rather than
      // inventing a heading.
      _clearLaunch();
      return;
    }
    // y = z × x completes a right-handed frame. Written this way round on
    // purpose: `forward.cross(up)` would give RIGHT and every lateral reading
    // would come out mirrored, which no amount of orthonormality checking
    // would catch.
    final left = up.cross(forward);
    final built = GForceCalibration.fromAxes(
      forward: forward,
      left: left,
      up: up,
      at: t,
    );
    if (built == null) {
      _clearLaunch();
      return;
    }
    _result = built;
    _phase = CalibrationPhase.complete;
  }
}

/// One frame of the G meter, already in DISPLAY units.
///
/// Everything here has been through the deadband and the quantiser, so it is
/// what the rider sees. The values that get RECORDED are
/// [GForceEstimator.rawLongMs2] / [GForceEstimator.rawLatMs2] instead — design
/// 0045 §3.7, matching design 0044's rule that the landed number is the
/// estimator's, not the display's.
class GForceReading {
  const GForceReading({
    required this.longG,
    required this.latG,
    required this.peakLongG,
    required this.peakLatG,
    required this.peakG,
  });

  static const GForceReading zero = GForceReading(
      longG: 0, latG: 0, peakLongG: 0, peakLatG: 0, peakG: 0);

  /// Signed longitudinal G. Positive = accelerating, negative = braking.
  final double longG;

  /// Signed lateral G. Positive = the acceleration points LEFT, which is what a
  /// left-hand corner produces.
  final double latG;

  /// Largest |longG| / |latG| seen this ride.
  final double peakLongG, peakLatG;

  /// Largest combined magnitude seen this ride — the third readout.
  final double peakG;

  bool get isBraking => longG < 0;
  bool get isLeft => latG > 0;

  /// Distance of the dot from the centre of the ball.
  double get magnitude => math.sqrt(longG * longG + latG * latG);
}

/// Ride-time estimation: rotate → smooth → deadband → quantise → peak-hold.
///
/// Holds no clock and no stream. One [process] call per sample; the caller
/// decides how often to publish (design 0045 §3.4 throttles the readout at
/// 200 ms, which is the controller's job, not this one's).
class GForceEstimator {
  GForceEstimator(this.calibration, {this.config = const GForceConfig()});

  final GForceCalibration calibration;
  final GForceConfig config;

  double _sLong = 0, _sLat = 0;
  bool _seeded = false;

  double _peakLongG = 0, _peakLatG = 0, _peakG = 0;

  /// Smoothed longitudinal acceleration in m/s², WITHOUT deadband or
  /// quantisation. This is the number that reaches the history table.
  double get rawLongMs2 => _sLong;

  /// Smoothed lateral acceleration in m/s², same terms as [rawLongMs2].
  ///
  /// 🔑 This one is the reason design 0045 Q4 ruled that G belongs in the
  /// history table at all: design 0044's GPS-derived acceleration is a scalar
  /// along the direction of travel and cannot see cornering. Lateral G is the
  /// only column that can be lined up against "what did the current do through
  /// that bend".
  double get rawLatMs2 => _sLat;

  /// Whether any sample has been seen since the last [reset].
  bool get hasSample => _seeded;

  GForceReading process(Vec3 linearPhoneFrame) {
    final body = calibration.toBody(linearPhoneFrame);
    if (!_seeded) {
      // Seed rather than ease in from zero: an EWMA started at 0 spends its
      // first second reporting a fraction of the truth, and the first second is
      // when the rider is looking at it to see whether it works.
      _sLong = body.x;
      _sLat = body.y;
      _seeded = true;
    } else {
      _sLong += config.ewmaAlpha * (body.x - _sLong);
      _sLat += config.ewmaAlpha * (body.y - _sLat);
    }
    final longG = _display(_sLong);
    final latG = _display(_sLat);
    _peakLongG = math.max(_peakLongG, longG.abs());
    _peakLatG = math.max(_peakLatG, latG.abs());
    _peakG = math.max(_peakG, math.sqrt(longG * longG + latG * latG));
    return GForceReading(
      longG: longG,
      latG: latG,
      peakLongG: _peakLongG,
      peakLatG: _peakLatG,
      peakG: _peakG,
    );
  }

  /// m/s² → g, deadbanded then quantised.
  double _display(double ms2) {
    final g = ms2 / GForceConfig.g0;
    if (g.abs() < config.deadbandG) return 0;
    final q = config.quantumG;
    return (g / q).roundToDouble() * q;
  }

  /// Clear the peak-hold readouts (design 0045 Q5 — tap to zero).
  void resetPeak() {
    _peakLongG = 0;
    _peakLatG = 0;
    _peakG = 0;
  }

  /// Forget everything, including the smoother.
  ///
  /// Called when the stream stops. Peaks do not survive it, which is Q5's
  /// ruling: a peak is "the hardest you braked THIS ride", and a value carried
  /// across a gap in the recording is not that.
  void reset() {
    _sLong = 0;
    _sLat = 0;
    _seeded = false;
    resetPeak();
  }
}

