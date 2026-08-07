/// OpenSmartBatt — every tunable number the G meter has (design 0045 §3.4).
///
/// One place, for design 0042 §3.2's reason: **all of these are paper values.**
/// Not one of them has been measured on a motorcycle. Phase 4 is a road test
/// whose entire job is to replace them, and a road test that has to hunt for
/// constants across five files replaces the ones it can find.
///
/// 🔴 Motorcycle vibration is the reason the smoothing block exists at all
/// (design 0045 §2.2 #6 / R3): handlebar and frame vibration carries far more
/// high-frequency energy than a car's, so an unfiltered reading flickers. G3
/// says a flickering number is worse than no number — so if the road test
/// cannot make the ball sit still at a steady cruise, the answer is to retune
/// here and test again, not to ship it.
library;

/// Thresholds for the calibration wizard and the ride-time estimator.
///
/// A class with an instance rather than bare top-level constants so tests can
/// pass a tightened copy without reaching into the production values (the same
/// shape as `SpeedEstimatorConfig` / `AccelEstimatorConfig`).
class GForceConfig {
  const GForceConfig({
    this.samplingPeriod = const Duration(milliseconds: 20),
    this.tCal = const Duration(seconds: 3),
    this.stillEpsMs2 = 0.15,
    this.tFwd = const Duration(milliseconds: 1500),
    this.aFwdMs2 = 0.8,
    this.tStill = const Duration(seconds: 2),
    this.thetaInvalidDeg = 10.0,
    this.ewmaAlpha = 0.2,
    this.deadbandG = 0.03,
    this.quantumG = 0.01,
    this.readoutThrottle = const Duration(milliseconds: 200),
  });

  /// ~50 Hz, the platform's "game" rate. The ball's dot has to track the seat
  /// of the rider's pants; a 1 Hz sample would make it jump between cells.
  final Duration samplingPeriod;

  /// How long the phone must sit still to fix "up" (§3.2 step 1).
  final Duration tCal;

  /// Linear-acceleration magnitude below which we call the phone still. Used
  /// both to validate the gravity window and to open the re-validation window.
  final double stillEpsMs2;

  /// How long a launch must persist before it fixes "forward" (§3.2 step 2).
  final Duration tFwd;

  /// Minimum linear-acceleration magnitude that counts as a launch.
  final double aFwdMs2;

  /// How long the phone must be still before the validity check may run.
  ///
  /// 🔴 The check is NOT run while moving. Cornering tilts the apparent gravity
  /// vector by design, so a moving comparison would declare the calibration
  /// broken every time the rider leaned. (§3.2, paper-level judgement, road
  /// test to confirm.)
  final Duration tStill;

  /// Gravity may drift this far from the stored "up" before the calibration is
  /// declared stale.
  final double thetaInvalidDeg;

  /// Per-axis EWMA weight on new samples.
  final double ewmaAlpha;

  /// Below this the display reads 0.0 and the dot pins to the centre, so a bike
  /// idling at a red light does not show a wandering number.
  final double deadbandG;

  /// Display resolution, in g. Racing convention is two decimals.
  final double quantumG;

  /// Minimum gap between READOUT updates. The dot may move faster — a graphic
  /// sliding smoothly is not the thing G3 calls worse than nothing; a digit
  /// changing ten times a second is.
  final Duration readoutThrottle;

  /// Standard gravity, m/s² per g.
  static const double g0 = 9.80665;
}
