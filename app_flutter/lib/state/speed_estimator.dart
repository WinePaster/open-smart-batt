/// OpenSmartBatt — GPS speed estimator (design 0042 Phase 0).
///
/// 🔴 PRIVACY RED LINE (design 0042 G5). **No type in this file may carry a
/// coordinate.** Latitude/longitude never enter the estimator, so they cannot
/// leak out of it — not into history, not into the diagnostic log, not into any
/// export. This is enforced by the shape of [SpeedFix] rather than by review:
/// there is no field to put a coordinate in, so a future change that wants to
/// persist one has to widen a type first, which is a diff nobody merges by
/// accident. FB-33 (a MAC address reaching an exported log note) is the reason
/// we do not rely on care alone; a GPS track is far more sensitive than a MAC.
/// `test/speed_privacy_test.dart` pins it.
///
/// Pure Dart on purpose: no Flutter and no plugin imports. The hard part of
/// this feature is the signal-loss state machine, and keeping it here means it
/// is tested with an injected clock and synthetic fixes instead of a tunnel.
/// [GpsSpeedController] owns the plugin, the permissions and the lifecycle
/// gate; this file owns only the arithmetic.
library;

import 'dart:async';
import 'dart:math' as math;

/// Whether the displayed speed is being measured, held, or is gone.
///
/// The three values exist to make design 0042 G2 expressible: a frozen number
/// must never be presentable as a live one. A card that renders [holding] the
/// same as [live] is a bug even though the digits are identical.
enum SpeedState {
  /// A fix that passed the filters arrived recently; the number is measured.
  live,

  /// No usable fix for longer than [SpeedEstimatorConfig.tHold]. The last
  /// smoothed value is frozen and MUST be marked as held on screen.
  holding,

  /// Signal is gone (see [SpeedEstimatorConfig.tLost] /
  /// [SpeedEstimatorConfig.holdCap]). The card leads with "no signal"; the last
  /// known speed drops to secondary information with an age beside it.
  ///
  /// Deliberately not a decay animation: pretending to slow down is less honest
  /// than freezing, not more (0042 §3.2).
  lost,
}

/// Four-level signal quality, judged on sample age AND accuracy together.
///
/// Both halves are load-bearing because the platforms fail differently: Android
/// typically STOPS delivering samples in a tunnel, while iOS may keep
/// delivering degraded/extrapolated ones with the accuracy figure blown up
/// (0042 §2.3 #4). Age alone misses the second case; accuracy alone misses the
/// first.
enum SpeedSignalQuality { good, fair, poor, none }

/// Every threshold the estimator uses, in one const object.
///
/// All of these are paper starting points. Design 0042 R3 makes the road test
/// (Phase F) a release gate precisely because none of them has met a real
/// motorcycle yet — collecting them here is what makes that retune a one-file
/// edit instead of a hunt through the state machine.
///
/// 🔴 **ONE knob is not here, and the road test needs it: the SAMPLING PERIOD**
/// (`GeolocatorSpeedSource.speedSamplingPeriod`, `gps_speed_controller.dart`).
///
/// It lives there because it is a platform argument, not estimator arithmetic —
/// this file has no Flutter or plugin import and is not going to acquire one
/// for a constant. But the omission is exactly the kind that costs an afternoon
/// in a car park, because [tHold] and [tLost] are meaningless without it:
/// they are ages measured against the interval at which samples are requested,
/// and the plugin's own default (5 s) is longer than BOTH. So retuning is
/// "edit two files", and this note plus the mirror note beside
/// `speedSamplingPeriod` is what makes the second one findable.
///
/// Rule of thumb when changing either: `speedSamplingPeriod` must stay
/// comfortably below [tHold], or a perfectly clear sky cycles
/// live → holding → lost forever.
class SpeedEstimatorConfig {
  const SpeedEstimatorConfig({
    this.aRejectM = 50.0,
    this.sRejectMps = 5.0,
    // Raised from 0.3 by the 2026-08-09 road test (design 0042 Phase F, the
    // first of these knobs to meet a real motorcycle; FB-56). The owner rode
    // to a full stop and the card took 3–5 s to reach 0 — τ at α=0.3 and a
    // 1 Hz sampling period is ≈2.8 s, so the reading was still ~5% of the
    // entry speed three seconds after the wheels stopped. α=0.5 halves that
    // (τ ≈1.4 s) at the cost of a twitchier number in traffic, which is the
    // side the rider can see is honest.
    //
    // ⚠️ This value is coupled to `GeolocatorSpeedSource.speedSamplingPeriod`:
    // τ is measured in SAMPLES, so changing the period changes the lag without
    // touching this line.
    //
    // 🔴 Raised again 2026-08-19, from 0.5 to 1 − e⁻¹ (design 0071 §3.3, ruled).
    // This one is NOT a retune: it is the price of [displaySpeedMpsAt].
    //
    // Until 0071 the card jumped to `v_k` the instant a sample landed and sat
    // there for a whole period, so the lag a rider saw averaged
    // `0.5·T + T(1−α)/α` = 1.50 s at α=0.5. Drawing the same EWMA as a RAMP
    // instead of a step replaces the 0.5·T half-step with the curve's own mean,
    // `τ = T / ln(1/(1−α))`, giving `0.5·T + τ` — 1.94 s at α=0.5, i.e. 0.44 s
    // WORSE. Setting τ = T buys that back exactly:
    //
    //     0.5 + τ/T = 1.5  ⇒  τ = T  ⇒  ln(1/(1−α)) = 1  ⇒  α = 1 − e⁻¹
    //
    // So the continuous reading lags the same 1.50 s the stepped one did; what
    // changed is only that it sweeps there instead of hopping. ⚠️ It does NOT
    // make the reading as quick as a DISCRETE filter at α=0.632 would be
    // (1.08 s) — smoothing between samples always costs something, and this
    // constant is what stops it costing the rider anything (0071 G2).
    //
    // ⚠️ The FB-56 note above still applies with more force: a higher α is a
    // twitchier number in traffic. 0071 §3.3 argues the twitch now arrives as a
    // sweep rather than as an integer hop, which is a claim only the road test
    // can settle (0071 §7 Q2, ruled "ship 0.632, revisit after the ride").
    // 📌 The RULED value is the three-digit 0.632, not `1 - 1/e`
    // (0.6321205588…). The difference is τ = 1.00033 T instead of 1.00000 T —
    // 0.3 ms of lag on a reading that updates every second — and a literal is
    // what the ruling says, what the road test will be told, and what a future
    // retune will overwrite. Spelling it as an expression would invite the next
    // reader to "correct" the ruling into arithmetic.
    this.alpha = 0.632,
    // The length of the display ramp (design 0071 §3.1). It must MIRROR
    // `GeolocatorSpeedSource.speedSamplingPeriod`, and it is a second copy of
    // that number for the same reason `alpha` is not over in
    // `gps_speed_controller.dart`: this file imports nothing but `dart:async`
    // and `dart:math`, and is not going to acquire a plugin import for a
    // constant. The mirror note lives beside `speedSamplingPeriod`.
    this.displayRampPeriod = const Duration(seconds: 1),
    // 3.0 km/h. Ruled 2026-08-07, raised from the 1.0 km/h the design doc
    // first named. The doc's own justification says stationary GNSS jitter
    // reads 1–3 km/h and calls a red light showing 2 km/h "an error the user
    // spots instantly" — so a 1.0 km/h floor sat BELOW the noise it exists to
    // remove, and let the named failure through. The cost is that a genuine
    // sub-3 km/h crawl (walking the bike) reads 0, which is accepted for the
    // scooter use case this module was built for.
    this.vStillMps = 3.0 / 3.6,
    this.tHold = const Duration(seconds: 2),
    this.tLost = const Duration(seconds: 4),
    this.holdCap = const Duration(seconds: 5),
    this.goodAccM = 10.0,
    this.fairAccM = 25.0,
    this.freshAge = const Duration(seconds: 2),
  });

  /// Reject a fix whose horizontal accuracy is worse than this (metres).
  final double aRejectM;

  /// Reject a fix whose reported speed accuracy is worse than this (m/s).
  /// Only applied when the platform reports one at all.
  final double sRejectMps;

  /// EWMA weight of the newest sample. Higher = twitchier.
  final double alpha;

  /// How long [SpeedEstimator.displaySpeedMpsAt]'s curve takes to walk one
  /// EWMA step (design 0071 §3.1). Must equal the SAMPLING period.
  ///
  /// 🔴 Getting this wrong is silent in both directions. Too short and the
  /// curve arrives early and then sits still — the old stepped behaviour with
  /// extra arithmetic. Too long and the curve never reaches `v_k` before the
  /// next sample re-anchors it, so the reading permanently undershoots and no
  /// test of a single step would notice.
  final Duration displayRampPeriod;

  /// Below this the displayed speed is clamped to exactly 0 (m/s).
  ///
  /// A stationary GNSS receiver produces 1–3 km/h of fake speed from position
  /// jitter, and "2 km/h at a red light" is the one error every user spots.
  final double vStillMps;

  /// No usable fix for longer than this ⇒ [SpeedState.holding].
  final Duration tHold;

  /// No usable fix for longer than this ⇒ [SpeedState.lost].
  final Duration tLost;

  /// Upper bound on time spent in [SpeedState.holding], independent of [tLost].
  ///
  /// With the paper defaults (`tHold` 2 s, `tLost` 4 s, `holdCap` 5 s) the age
  /// bound always fires first and this one never binds — it is here so that the
  /// Phase F retune can raise [tLost] for a long overpass without also granting
  /// an unbounded freeze. Both bounds are checked; whichever is reached first
  /// wins.
  final Duration holdCap;

  /// Accuracy (metres) at or below which a fresh fix counts as
  /// [SpeedSignalQuality.good].
  final double goodAccM;

  /// Accuracy (metres) at or below which a fresh fix counts as
  /// [SpeedSignalQuality.fair].
  final double fairAccM;

  /// Age at or below which a fix still counts as "fresh" for quality grading.
  /// Distinct from [tHold] on purpose: quality is about how much to trust the
  /// number, the state machine is about whether it is still being measured.
  final Duration freshAge;
}

/// One location sample, reduced to the four things this feature needs.
///
/// 🔴 There is no latitude/longitude field and there must never be one (G5).
/// The mapping from the platform's position object drops the coordinate on the
/// line that constructs this object, so no coordinate ever exists downstream of
/// [GpsSpeedController]'s stream handler.
class SpeedFix {
  const SpeedFix({
    required this.speedMps,
    this.speedAccuracyMps,
    required this.horizontalAccuracyM,
    required this.timestamp,
  });

  /// Doppler speed from the GNSS chipset in m/s, or **null when the platform
  /// did not report one at all**.
  ///
  /// 🔴 Nullable since 2026-08-07, and the nullability is the whole point.
  /// The design doc's filter said "reject `speed < 0`", borrowed from
  /// CoreLocation's documented invalid marker. **That value never arrives.**
  /// Both platform mappers OMIT the key when the reading is unavailable
  /// (`LocationMapper.java:29` guards on `hasSpeed()`; the iOS mapper does the
  /// same), and `Position._toDouble(null)` turns an absent key into `0.0`
  /// (geolocator_platform_interface `position.dart:200-206`).
  ///
  /// So "we have no speed yet" used to arrive as a perfectly ordinary
  /// `0.0 m/s`, sail through every filter, and be published as
  /// `0 km/h, quality good, state live` — a number nobody measured, presented
  /// as measured, in the first seconds the user is watching. That is the exact
  /// thing G2 forbids.
  ///
  /// There is no value that can mean both, so the absence is carried in the
  /// type instead. The adapter decides; the estimator never smooths a null.
  ///
  /// 🔴 Narrowed 2026-08-09 (FB-56): the estimator no longer treats null as
  /// "nothing happened" in every case. A null-speed fix on a good position fix,
  /// arriving while the display is already a clamped zero, keeps the reading
  /// alive — see [SpeedEstimator.addFix]. It still never enters the smoother
  /// and it still never CREATES a zero.
  final double? speedMps;

  /// Reported uncertainty of [speedMps] in m/s, or null where the platform does
  /// not report one (pre-API-26 Android, pre-iOS-10).
  final double? speedAccuracyMps;

  /// Horizontal position accuracy in metres — the only usable proxy for "is
  /// this fix worth anything" that both platforms provide.
  final double horizontalAccuracyM;

  /// When the platform says the fix was taken. Age is measured from this rather
  /// than from arrival, so a sample delivered late is aged correctly instead of
  /// looking fresh.
  final DateTime timestamp;
}

/// One output sample: a timestamped smoothed speed plus the state it was
/// produced in.
///
/// The shape is fixed by design 0044's requirement (0042 Phase 0 completion
/// condition, 0044 §3.1/R4): the acceleration module differentiates this
/// series, so exposing only "the number to show right now" would have forced a
/// rewrite one design later. `t` and `state` are what make that possible —
/// without the state, a consumer cannot tell a real zero from a frozen one.
///
/// 🔴 No coordinate field (G5).
class SpeedEstimate {
  const SpeedEstimate({
    required this.t,
    required this.vSmoothMps,
    required this.state,
    required this.quality,
    this.speedAccuracyMps,
    this.lastLiveAt,
  });

  /// Time this estimate describes, on the estimator's injected clock.
  final DateTime t;

  /// Smoothed speed in m/s, already still-clamped (see
  /// [SpeedEstimatorConfig.vStillMps]).
  ///
  /// The clamp is applied here rather than in the card because design 0044
  /// differentiates this series: leaving the jitter in would hand the
  /// acceleration module a stream of noise to differentiate while the vehicle
  /// stands still, which is exactly the fake reading the clamp exists to stop.
  final double vSmoothMps;

  final SpeedState state;
  final SpeedSignalQuality quality;

  /// Reported speed uncertainty of the last accepted fix, or null when the
  /// platform does not report one. Null means the card omits the ± line
  /// entirely — it never renders `--` (0042 §3.8).
  final double? speedAccuracyMps;

  /// Timestamp of the last accepted fix, i.e. the last moment this was
  /// measured. [SpeedState.lost] renders "N seconds ago" from it.
  final DateTime? lastLiveAt;
}

/// A change of [SpeedState], with the moment it happened.
///
/// Emitted on its own stream because design 0044 needs the edge, not the level:
/// leaving [SpeedState.live] is what tells the acceleration estimator to drop
/// its window. Reconstructing that edge by diffing consecutive estimates would
/// work only while estimates are emitted on every tick, which they are not.
class SpeedStateTransition {
  const SpeedStateTransition({
    required this.from,
    required this.to,
    required this.at,
  });

  final SpeedState from;
  final SpeedState to;
  final DateTime at;
}

/// Filters, smooths and grades GNSS speed samples, and decides whether what is
/// on screen is measured, held or gone.
///
/// Driven from two places: [addFix] when the platform delivers a sample, and
/// [tick] on a timer. The timer is not decoration — the interesting transition
/// (a tunnel) is the ABSENCE of samples, so without an external heartbeat the
/// estimator would sit in [SpeedState.live] forever with a stale number.
class SpeedEstimator {
  /// [now] is injected so the age-driven transitions can be tested with a fake
  /// clock instead of real elapsed time; the whole tunnel state machine is
  /// unreachable in a unit test otherwise.
  SpeedEstimator({
    this.config = const SpeedEstimatorConfig(),
    required this.now,
  });

  final SpeedEstimatorConfig config;

  /// The estimator's only clock. Everything age-related is measured with it, so
  /// a test can make four seconds pass without waiting four seconds.
  final DateTime Function() now;

  final StreamController<SpeedEstimate> _estimates =
      StreamController<SpeedEstimate>.broadcast();
  final StreamController<SpeedStateTransition> _transitions =
      StreamController<SpeedStateTransition>.broadcast();

  /// Null until the first accepted fix. That is a fourth situation the card has
  /// to render ("waiting for a fix") and it is deliberately NOT a [SpeedState]
  /// value: "we never had signal" and "we had it and lost it" look the same on
  /// a three-value enum, and only one of them should say "no signal".
  SpeedState? _state;

  double? _ewma;
  DateTime? _lastFixAt;
  double? _lastAccuracyM;
  double? _lastSpeedAccuracyMps;
  DateTime? _holdingSince;
  SpeedEstimate? _current;

  // ---- design 0071: the three numbers the display curve is drawn from ------
  //
  // 🔴 None of them is read by [_estimateAt], and that is the whole point.
  // They exist only for [displaySpeedMpsAt]; the RECORDED series
  // ([estimates], which feeds design 0044 and design 0061) is produced by
  // exactly the code that produced it before 0071 (0071 §3.5 pin 2).

  /// Where the curve starts: the smoothed value BEFORE the newest sample was
  /// folded in — except on a re-seed, where it is the sample itself (pin 4).
  double? _prevSmoothed;

  /// Where the curve is heading: the newest RAW sample `z_k`.
  ///
  /// The curve aims at the measurement, not at `_ewma`, because that is what
  /// makes `v_disp(t_k + T)` come out equal to `v_k` — see [displaySpeedMpsAt].
  double? _lastRaw;

  /// When the curve started, **on our own clock**.
  ///
  /// 🔴 Deliberately not `fix.timestamp` (0071 §3.1). M2 below measured 2.1 s
  /// of delivery latency between the GNSS chip and this isolate; anchoring on
  /// the platform stamp would mean the curve is already finished the moment it
  /// is created, which is the stepped behaviour this feature exists to replace.
  DateTime? _anchorAt;

  /// Timestamped smoothed samples. Broadcast: the controller forwards it to the
  /// UI while design 0044's acceleration estimator listens in parallel.
  Stream<SpeedEstimate> get estimates => _estimates.stream;

  /// State changes only. See [SpeedStateTransition].
  Stream<SpeedStateTransition> get transitions => _transitions.stream;

  /// The newest estimate, or null while no fix has ever been accepted.
  SpeedEstimate? get current => _current;

  /// The speed to DRAW at [at] — the same EWMA, read as a curve instead of as
  /// a staircase (design 0071 §3.1).
  ///
  /// ```
  /// v_disp(t) = z_k + (v_{k−1} − z_k)·(1−α)^( min(t − t_k, T) / T )
  /// ```
  ///
  /// with `z_k` the newest raw sample, `v_{k−1}` the smoothed value before it,
  /// `t_k` the moment it arrived on OUR clock, and `T` [config.displayRampPeriod].
  /// Three properties, all three load-bearing:
  ///
  ///  1. at `t = t_k` it equals `v_{k−1}` — the curve starts where the previous
  ///     one ended, so a sample landing does not make the digits jump;
  ///  2. at `t = t_k + T` it equals `α·z_k + (1−α)·v_{k−1}` — which IS `v_k`,
  ///     because `(1−α)^1 = 1−α`. So on every sampling instant this agrees with
  ///     [SpeedEstimate.vSmoothMps] to the last bit. That equality is the whole
  ///     of 0071's answer to 0042 G2: this is not a new estimate and not a
  ///     prediction, it is the filter's own trajectory between two points it
  ///     already occupied. `speed_estimator_test.dart` pins it.
  ///  3. past `t_k + T` the exponent is clamped, so the curve STOPS. Nothing
  ///     moves without a new measurement, a freeze freezes at exactly the value
  ///     the old code froze at, and a late sample simply spends its overrun
  ///     parked — which is the pre-0071 behaviour.
  ///
  /// 🔴 Pure read. It emits nothing, mutates nothing, and is not consulted by
  /// [_estimateAt]: the RECORDED series is untouched by everything in here
  /// (0071 §3.5 pin 2, G3). Design 0044 differentiates [estimates] and design
  /// 0061 stores it; both must see the series they saw before this method
  /// existed.
  ///
  /// Only [SpeedState.live] gets a curve (pin 1). Holding, lost, and "no fix
  /// yet" answer with the frozen [SpeedEstimate.vSmoothMps], which is what the
  /// card showed for them before 0071 and what 0042 §3.2 requires: a held
  /// number must not move, in either direction, for any reason.
  ///
  /// Returns null only when no fix has ever been accepted (or after a
  /// [reset]) — see the body.
  ///
  /// The still-clamp is applied on the way out, in the same order as
  /// [_estimateAt] applies it (pin 3): curve first, then clamp, then the
  /// caller's `formatSpeed`. So sweeping down through 3 km/h still lands on a
  /// hard 0 rather than trailing decimals at a red light.
  /// Whether [displaySpeedMpsAt] would still be MOVING at [at].
  ///
  /// The card's per-frame loop is armed and disarmed by this rather than by
  /// watching the value stop changing, and the difference is not cosmetic: a
  /// value-watching loop cannot tell "the curve has arrived" from "no time has
  /// passed between these two frames", so it shuts itself off the first time a
  /// frame is cheap — and then nothing restarts it until the next sample.
  ///
  /// False once the curve is clamped at `t_k + T`, and false in every state but
  /// [SpeedState.live], because those do not have a curve at all (§3.5 pin 1).
  /// After that only a new sample can move the reading, and a new sample makes
  /// the controller notify — so there is nothing to draw and no reason to hold
  /// a vsync callback open (0042 G4).
  bool displayRampActiveAt(DateTime at) {
    if (_state != SpeedState.live) return false;
    final anchor = _anchorAt;
    if (anchor == null || _ewma == null) return false;
    return at.difference(anchor) < config.displayRampPeriod;
  }

  double? displaySpeedMpsAt(DateTime at) {
    final smoothed = _ewma;
    // 🔴 Null, not 0.0. "This estimator has no series to draw" and "the vehicle
    // is stopped" are different facts, and returning 0.0 for the first is the
    // same mistake `SpeedFix.speedMps` was made nullable to stop: a number
    // nobody measured, indistinguishable from one somebody did. The caller
    // renders whatever it was already rendering (`SpeedCardBody` falls back to
    // [SpeedEstimate.vSmoothMps]) instead of a zero this method invented.
    if (smoothed == null) return null;
    final frozen = _clampStill(smoothed);
    if (_state != SpeedState.live) return frozen;

    final anchor = _anchorAt;
    final from = _prevSmoothed;
    final target = _lastRaw;
    if (anchor == null || from == null || target == null) return frozen;

    final period = config.displayRampPeriod.inMicroseconds;
    if (period <= 0) return frozen;
    var elapsed = at.difference(anchor).inMicroseconds;
    // Asked about a moment before the anchor (a caller with its own clock, or
    // a clock stepped backwards): the curve had not started, so its start is
    // the honest answer. Never a negative exponent, which would OVERSHOOT.
    if (elapsed < 0) elapsed = 0;
    if (elapsed > period) elapsed = period; // property 3
    final v = target + (from - target) * math.pow(1 - config.alpha, elapsed / period);
    return _clampStill(v);
  }

  /// Feed one location sample.
  ///
  /// Rejected samples are dropped whole: they do not enter the smoother AND
  /// they do not refresh the age. That second half is the point — an iOS tunnel
  /// keeps delivering samples with a useless accuracy figure, and a rejected
  /// sample that still counted as "recent" would hold the state machine in
  /// [SpeedState.live] for the length of the tunnel.
  ///
  /// 🔴 ONE narrow exception, added 2026-08-09 for FB-56:
  /// [_sustainsClampedStill] refreshes the age WITHOUT entering the smoother,
  /// for a fix that carries no speed but proves the receiver is alive while a
  /// clamped zero is already on screen. Read that predicate before widening it
  /// — every one of its four conditions is holding something up.
  void addFix(SpeedFix fix) {
    // 🔴 FB-56, ruled 2026-08-09 (design 0042 revision). A fix with no speed
    // field, arriving on a good position fix while the card is ALREADY showing
    // a clamped zero, is evidence that the receiver is alive and the vehicle is
    // standing still — not evidence that the signal went away. Sustain `live`
    // and refresh the age; the smoother is not touched.
    //
    // Without this, a parked scooter read "no signal" while iOS was delivering
    // a perfectly good fix every second (iOS auto-pause is off — we pass a bare
    // `LocationSettings`, so `pausesLocationUpdatesAutomatically` stays NO),
    // and the chip simply stops reporting a Doppler speed once it is stationary.
    // Saying "no signal" while holding a good fix in hand is the same class of
    // lie as G2's, pointed the other way.
    if (_sustainsClampedStill(fix)) {
      // Only the liveness half of the sample is consumed: when it was taken,
      // and how good the position was. `_ewma` and `_lastSpeedAccuracyMps`
      // belong to the last real speed MEASUREMENT and stay exactly as they are
      // — no decay toward zero, which 0042 §3.2 forbids for the same reason it
      // forbids a decay animation.
      //
      // 🔴 The display curve is not re-anchored here either (0071 §3.5 pin 4),
      // and it is the easiest line in this file to add by accident. Nothing
      // entered the smoother, so the curve's TARGET has not changed — moving
      // `_anchorAt` would replay the last step of a ramp that already finished,
      // i.e. make a parked scooter's reading crawl once a second forever.
      _lastFixAt = fix.timestamp;
      _lastAccuracyM = fix.horizontalAccuracyM;
      _holdingSince = null;
      final estimate = _estimateAt(now());
      _current = estimate;
      _estimates.add(estimate);
      return;
    }
    if (!_accepts(fix)) return;

    // Recovering from a gap restarts the average rather than continuing it.
    // Blending the speed from before a tunnel into the first samples after it
    // would show a number that was never measured, at the exact moment the user
    // is looking to see whether the reading came back (0042 §3.2).
    final resuming = _state != null && _state != SpeedState.live;
    final previousSmoothed = _ewma;
    if (previousSmoothed == null || resuming) {
      _ewma = fix.speedMps!;
      // 🔴 0071 §3.5 pin 5. A re-seed gets a FLAT curve — start and end are
      // both the new sample — because the general rule (sweep from
      // `previousSmoothed` to `v_k`) would spend the first second after a
      // tunnel walking the reading down from the speed the rider was doing
      // BEFORE the tunnel. That is the exact number 0042 §3.2 forbids blending
      // in, and drawing it instead of averaging it in is not a loophole.
      //
      // Note this is the same branch that re-seeds `_ewma`, on purpose: the two
      // decisions are one decision ("this sample starts a new series"), and
      // splitting them is how they would drift apart.
      _prevSmoothed = fix.speedMps!;
    } else {
      _ewma = config.alpha * fix.speedMps! + (1 - config.alpha) * previousSmoothed;
      _prevSmoothed = previousSmoothed;
    }
    _lastRaw = fix.speedMps!;
    // On OUR clock, for the reason in [_anchorAt]. `at` is read once and used
    // for both the anchor and the estimate's `t` so the two cannot disagree by
    // the microseconds a second `now()` call would cost.
    final at = now();
    _anchorAt = at;

    _lastFixAt = fix.timestamp;
    _lastAccuracyM = fix.horizontalAccuracyM;
    _lastSpeedAccuracyMps = fix.speedAccuracyMps;
    _holdingSince = null;

    final previous = _state;
    _state = SpeedState.live;
    // M2: stamp on OUR clock, not the platform's.
    //
    // This used to be `_estimateAt(fix.timestamp)` while `tick()` used
    // `_estimateAt(now())` — one series carrying two time bases. Delivery
    // latency between the GNSS chip and this isolate then made `t` run
    // BACKWARDS across an addFix/tick boundary (measured: 0 ms → 2100 ms →
    // 1750 ms), which hands design 0044 a negative dt to divide by. It also
    // contradicted [SpeedEstimate.t]'s own doc, which has always said "on the
    // estimator's injected clock".
    //
    // The fix's own timestamp is still what ages it — see [_ageAt] — because
    // "how stale is this reading" is a question about when it was MEASURED.
    // `t` answers a different one: when did this app learn it.
    final estimate = _estimateAt(at);
    _current = estimate;

    // No transition is emitted for the very first fix: there is no prior state
    // to come from, and [SpeedStateTransition.from] is non-nullable by design
    // (0042 Phase 0 / 0044 R4). Consumers learn about first acquisition from
    // the estimate, which carries the state.
    if (previous != null && previous != SpeedState.live) {
      _transitions.add(SpeedStateTransition(
        from: previous,
        to: SpeedState.live,
        at: fix.timestamp,
      ));
    }
    _estimates.add(estimate);
  }

  /// Re-evaluate age-driven state. Call on a timer (1 Hz) while the GPS stream
  /// is open; a no-op until the first fix has been accepted.
  ///
  /// Emits an estimate only when the state or the quality actually changed. A
  /// held value re-announced every second would give design 0044 a run of
  /// identical points to differentiate — the frozen-difference-is-zero trap its
  /// G2 names — and would repaint the card for nothing.
  void tick() {
    final previous = _state;
    if (previous == null) return;

    final at = now();
    final next = _stateAt(at);
    if (next != previous) {
      if (next == SpeedState.holding) _holdingSince = at;
      _state = next;
      _transitions
          .add(SpeedStateTransition(from: previous, to: next, at: at));
    }

    final previousQuality = _current?.quality;
    final estimate = _estimateAt(at);
    _current = estimate;
    if (next != previous || estimate.quality != previousQuality) {
      _estimates.add(estimate);
    }
  }

  /// Forget everything, silently.
  ///
  /// Used when the lifecycle gate closes the GPS stream: on the next open the
  /// card must be back to "waiting for a fix" rather than showing a speed from
  /// the previous session. Emits nothing — [current] going null IS the signal,
  /// and a synthetic estimate here would be a reading nobody measured.
  /// Drop everything and start a new series.
  ///
  /// 🔴 A reset ENDS the series, and it says so on [transitions].
  ///
  /// It used to be silent, and silence was wrong for one specific consumer:
  /// design 0044 differentiates [estimates] to get acceleration, and it decides
  /// when to suppress that derivative from the transition edges. A silent reset
  /// therefore spliced two unrelated segments into what looked like one
  /// continuous series — measured: a 25 m/s sample, a reset, then a 3 m/s
  /// sample thirty minutes later, with `transitions` empty. 0044 would have
  /// differentiated straight across the join.
  ///
  /// That path is not hypothetical: every `AppLifecycleState.inactive` (pulling
  /// down the notification shade is enough) runs `_stop()` → `reset()`.
  ///
  /// `lost` is the honest edge to emit rather than a new member: from the
  /// consumer's side "the signal is gone and the series it belonged to is over"
  /// is exactly what happened, and 0044 already suppresses on it. Keeping the
  /// vocabulary as-is is also what keeps the frozen interface (impl plan §1.4)
  /// frozen — a new stream or state would have unfrozen it and forced 0044 to
  /// re-align before it has even started.
  void reset() {
    final previous = _state;
    _state = null;
    _ewma = null;
    _lastFixAt = null;
    _lastAccuracyM = null;
    _lastSpeedAccuracyMps = null;
    _holdingSince = null;
    _current = null;
    // The display curve goes with it. Leaving these set would let
    // [displaySpeedMpsAt] answer with the previous session's speed while
    // [current] is already null — the card would be drawing a number it is
    // simultaneously reporting it does not have (design 0071 §5 #5).
    _prevSmoothed = null;
    _lastRaw = null;
    _anchorAt = null;
    // Nothing to leave if the series never started, and `from` is non-nullable.
    if (previous != null && previous != SpeedState.lost) {
      _transitions.add(SpeedStateTransition(
          from: previous, to: SpeedState.lost, at: now()));
    }
  }

  Future<void> dispose() async {
    await _estimates.close();
    await _transitions.close();
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  /// Whether [fix] may keep an already-displayed zero alive without entering
  /// the smoother (FB-56; design 0042 revision 2026-08-09).
  ///
  /// Four conditions, and G2 survives because of the third one:
  ///
  ///  1. **No speed field.** A fix that carries one goes down the normal path,
  ///     so this branch never competes with a measurement.
  ///  2. **Already `live`.** The branch SUSTAINS a zero that a real measurement
  ///     put on screen; it never resurrects a series that was lost, and it
  ///     never starts one. A phone that has never reported a speed still shows
  ///     "waiting for a fix" rather than `0 km/h` — the pre-API-26 Android case
  ///     the adapter's own comment errs toward silence for.
  ///  3. 🔴 **What is on screen is already a clamped zero.** `_ewma <
  ///     vStillMps` is EXACTLY the test [_estimateAt] applies to decide the
  ///     display reads `0.0`, so this branch is structurally incapable of
  ///     freezing a non-zero number and presenting it as live. A vehicle in
  ///     motion whose speed field disappears has an `_ewma` above the clamp,
  ///     fails here, and takes the honest holding → lost path G2 requires.
  ///  4. **The position fix is one we would otherwise keep** (same floor
  ///     [_accepts] uses). A fix we would throw out as junk cannot be evidence
  ///     that anything is alive — so a real signal loss, where the accuracy
  ///     blows up or is not reported at all and the adapter maps it to
  ///     `double.infinity`, still walks live → holding → lost.
  ///
  /// ⚠️ The reason to key on "no speed field" rather than on `speed == 0` is
  /// upstream, in `GpsSpeedController.toFix`: "stopped" and "the chip has no
  /// speed solution" arrive as the SAME bytes, and that mapper deliberately
  /// resolves the ambiguity toward silence. This branch does not reopen it —
  /// it uses a SECOND, independent piece of evidence (a zero that was already
  /// measured) to decide the fix means "still stationary".
  bool _sustainsClampedStill(SpeedFix fix) {
    if (fix.speedMps != null) return false;
    if (_state != SpeedState.live) return false;
    final smoothed = _ewma;
    if (smoothed == null || smoothed >= config.vStillMps) return false;
    final acc = fix.horizontalAccuracyM;
    return !acc.isNaN && acc <= config.aRejectM;
  }

  /// Sample-level filters (0042 §3.2). All three reject the whole sample.
  bool _accepts(SpeedFix fix) {
    // Null is "the platform reported no speed" — see [SpeedFix.speedMps].
    // Rejecting it here is what keeps an unmeasured 0 off the screen.
    final v = fix.speedMps;
    if (v == null || v.isNaN || v < 0) return false;
    if (fix.horizontalAccuracyM.isNaN ||
        fix.horizontalAccuracyM > config.aRejectM) {
      return false;
    }
    final sa = fix.speedAccuracyMps;
    if (sa != null && sa > config.sRejectMps) return false;
    return true;
  }

  Duration _ageAt(DateTime at) {
    final age = at.difference(_lastFixAt!);
    // A fix stamped in the future (clock skew between the GNSS chip and the
    // system clock) must not read as "aged into the past".
    return age.isNegative ? Duration.zero : age;
  }

  SpeedState _stateAt(DateTime at) {
    final age = _ageAt(at);
    if (age > config.tLost) return SpeedState.lost;
    if (age <= config.tHold) return SpeedState.live;
    final since = _holdingSince;
    if (since != null && at.difference(since) > config.holdCap) {
      return SpeedState.lost;
    }
    return SpeedState.holding;
  }

  SpeedSignalQuality _qualityAt(DateTime at) {
    if (_lastFixAt == null) return SpeedSignalQuality.none;
    final age = _ageAt(at);
    if (age > config.tLost) return SpeedSignalQuality.none;
    if (age <= config.freshAge) {
      final acc = _lastAccuracyM!;
      if (acc <= config.goodAccM) return SpeedSignalQuality.good;
      if (acc <= config.fairAccM) return SpeedSignalQuality.fair;
    }
    return SpeedSignalQuality.poor;
  }

  /// The still-clamp, in one place so the recorded value and the drawn value
  /// cannot disagree about where zero starts (0071 §3.5 pin 3).
  double _clampStill(double v) => v < config.vStillMps ? 0.0 : v;

  SpeedEstimate _estimateAt(DateTime at) {
    final v = _ewma ?? 0.0;
    return SpeedEstimate(
      t: at,
      vSmoothMps: _clampStill(v),
      state: _state!,
      quality: _qualityAt(at),
      speedAccuracyMps: _lastSpeedAccuracyMps,
      lastLiveAt: _lastFixAt,
    );
  }
}
