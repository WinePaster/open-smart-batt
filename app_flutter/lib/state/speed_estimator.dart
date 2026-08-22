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
    //
    // ────────────────────────────────────────────────────────────────────────
    // 🔴 **Raised a third time, 0.632 ⇒ 0.85, by the 2026-08-19 field check on
    // `v0.7.25` (design 0071 §7 Q2's "revisit after the ride", FB-89).**
    // Everything above stays true and stays here; it is the derivation of the
    // number this line NO LONGER carries, and the road test is what §7 Q2 said
    // would overwrite it. The owner rode 0.632 and reported two things: the
    // sub-10 km/h decimal reads well (so `formatSpeed` is untouched — Q3
    // closed), and **the reading still FEELS slow**.
    //
    // 🔑 **Why "feels slow" can be true while the average lag is unchanged, and
    // why that is not a contradiction.** 0.632 was chosen to make the AVERAGE
    // lag come out at the pre-0071 1.50 s (§3.3), and it does. But the average
    // is not what a rider notices when they open the throttle. Before 0071 the
    // instant a sample landed the digits jumped the WHOLE step; the first
    // visible reaction was immediate and full-size. After 0071 that same step is
    // spread across a whole second, so the earliest reaction is a fraction of
    // it. Matching the mean moved the FRONT of the response later — 0071 §3.3
    // balanced an integral and the rider is watching a leading edge. So: G2 was
    // satisfied and the complaint survived it. That is a real result, not a
    // measurement error, and it is the reason this line moved rather than the
    // curve being taken back out.
    //
    // The arithmetic, from the same formulas as above (T = 1 s):
    //
    //     τ    = T / ln(1/(1−α))       = 1 / ln(1/0.15) = 1/1.89712 = 0.527 s
    //     mean lag = T·(0.5 + τ/T)     = 0.5 + 0.527    = 1.03 s
    //     travelled by t_k + 0.3 s = 1 − (1−α)^0.3 = 1 − 0.15^0.3 = 43 %
    //
    // against α = 0.632: τ = 1.000 s, mean lag 1.50 s, 0.3 s progress
    // 1 − 0.368^0.3 = 26 %. **The leading edge is what this buys**: 26 % ⇒ 43 %
    // of the step visible in the first third of a second. The mean coming down
    // 1.50 ⇒ 1.03 s is a bonus, and it is why this change does not need a fresh
    // G2 argument — it moves lag the right way on both measures at once.
    //
    // ⚠️ **The ceiling, so nobody reads "higher is better" off the paragraph
    // above.** The 0.5·T half-step in `0.5 + τ/T` is the ZERO-ORDER-HOLD floor
    // of a 1 Hz sample rate; τ is the only part α can touch, and it is already
    // the smaller half here. α = 0.9 gives τ = 0.434 s (mean 0.93 s) and α =
    // 0.95 gives τ = 0.334 s (mean 0.83 s) — 0.09 s and 0.19 s respectively,
    // for a filter that passes 90 % / 95 % of every jitter spike straight to
    // the digits. Even α = 1 (no smoothing at all) still lags 0.5 s. **Past
    // ~0.85 the lag is bought in hundredths of a second and the twitch is paid
    // in full**, so this is where it stops until a measurement says otherwise —
    // see [SpeedEstimate.lastLiveAt] and `TelemetryController`'s
    // `speed-timing:` log line, which was added in the same change to find out
    // whether the real ceiling is the filter at all or the delivery latency in
    // front of it (M2 below: 2.1 s, observed once, never characterised).
    //
    // ⚠️ FB-56's warning survives all three raises and now applies at 0.85: in
    // stop-start traffic this number is twitchy. 0071 §3.3's answer (the twitch
    // arrives as a sweep, not an integer hop) is what makes it tolerable and is
    // still the thing a road test can overturn.
    this.alpha = 0.85,
    // `T`. It must MIRROR `GeolocatorSpeedSource.speedSamplingPeriod`, and it
    // is a second copy of that number for the same reason `alpha` is not over
    // in `gps_speed_controller.dart`: this file imports nothing but
    // `dart:async` and is not going to acquire a plugin import for a constant.
    // The mirror note lives beside `speedSamplingPeriod`.
    //
    // 🔵 Renamed from `displayRampPeriod` by design 0073 §3.10. Until then it
    // was the LENGTH OF THE DISPLAY RAMP (0071 §3.1); that ramp is gone and
    // this number now only appears in [trendHorizonMax]. The value and the
    // mirroring requirement are unchanged, which is why it was renamed rather
    // than deleted and re-added.
    this.samplingPeriod = const Duration(seconds: 1),
    this.trend = const TrendConfig(),
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

  /// `T` — the interval samples are REQUESTED at. Must equal
  /// `GeolocatorSpeedSource.speedSamplingPeriod`.
  ///
  /// 🔴 Getting this wrong is silent: it only shows up inside
  /// [SpeedEstimator.trendHorizonMax], i.e. as an extrapolation ceiling that is
  /// too generous or too mean, and no test of a single sample would notice.
  final Duration samplingPeriod;

  /// Design 0073's trend extrapolation knobs. See [TrendConfig].
  final TrendConfig trend;

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

/// Design 0073's trend-extrapolation knobs, in one const object.
///
/// 🔴 **These are ROAD-TEST knobs, not derived constants** — the same status
/// `alpha` has, and for the same reason (0073 §7 Q3, ruled 2026-08-19). They
/// are written as literals on purpose: spelling [capMps] as `10 / 3.6` would
/// invite the next reader to "correct" a ruling into arithmetic, which is
/// exactly the note `alpha` carries about the three-digit 0.632.
class TrendConfig {
  const TrendConfig({
    // 🔒 Ruled 2026-08-19 (0073 §7 Q3 option (b)).
    //
    // `k` is how much of the trend is put on screen: `level + k·slope·Δ`. At
    // k = 1 the steady-state lag under constant acceleration is exactly zero
    // and every bit of slope error goes straight to the digits; at k = 0
    // nothing is extrapolated and the reading is the plain EWMA (0073 G6, and
    // the way out if the road test goes badly — it is a constant, not a
    // revert). 0.7 keeps a 30 % discount as the standing allowance for the
    // slope being a three-point fit through noisy GNSS speed (0073 R1/R2).
    this.k = 0.7,
    // 🔒 `C` — the absolute ceiling on the compensation, 10 km/h, ruled with
    // `k` in the same breath and NOT independent of it.
    //
    // 0073 §3.5.3 did the arithmetic: at the acceleration this feature exists
    // for (3 m/s²) and k = 0.7, a ceiling of 8 km/h starts binding at Δ ≈
    // 1.06 s — i.e. it would cut off the tail of exactly the launch the rider
    // is complaining about. 10 km/h moves that to Δ ≈ 1.32 s, past the useful
    // part of the horizon. It is still a ceiling and it is meant to bind
    // eventually: "the owner accepts overshoot" is not "the owner accepts any
    // overshoot" (0073 R4).
    this.capMps = 2.7777777777777777, // 10 km/h
    // 🔒 `λ_cap` — how much DELIVERY LATENCY the horizon is allowed to carry
    // (0073 §7 Q4, ruled). Δ itself is measured per sample (`t − lastLiveAt`),
    // which is not an estimate: it is how long ago that sample was actually
    // taken. This is the guard against the pathological case — a sample that
    // arrives ten seconds late must not be extrapolated ten seconds forward.
    //
    // ⚠️ **Provisional.** The number the road test will replace it with is
    // `lag_p90` from `TelemetryController`'s `speed-timing:` log line, which
    // has no data yet (0073 §2.4: the one observation on record, 2.1 s, is one
    // observation and not a distribution). 0.5 s is a conservative placeholder,
    // and the log line's job is to calibrate THIS constant — it is not fed into
    // the formula anywhere.
    this.lambdaCap = const Duration(milliseconds: 500),
    // 🔴 MIRROR of `AccelEstimatorConfig.aDeadMps2`, and the mirror is checked
    // by a test rather than by care (`speed_estimator_test.dart`, design 0073
    // C3②). It is copied rather than imported because `accel_estimator.dart`
    // imports THIS file for [SpeedEstimate]; importing it back would be a
    // cycle (0073 §2.5 #1), and duplicating a dozen lines of least squares to
    // avoid one constant would be worse.
    this.aDeadMps2 = 0.15,
  });

  /// Fraction of the trend that reaches the screen. 0 disables the feature.
  final double k;

  /// Absolute ceiling on `k·slope·Δ`, in m/s.
  final double capMps;

  /// Ceiling on the delivery-latency part of the horizon.
  final Duration lambdaCap;

  /// Below this slope magnitude nothing is extrapolated (C3②).
  final double aDeadMps2;
}

/// The speed to DRAW: the filter's level, carried forward along the trend the
/// same filter's output already shows (design 0073 §3.3).
///
/// ```
/// v_display = level + k · slope · Δ
/// ```
///
/// 🔑 **A named top-level function rather than four lines inside
/// [SpeedEstimator.displaySpeedMpsAt], for the reason `displayAccel` in
/// `accel_estimator.dart` states in full**: this project has three times
/// shipped a defect that lived at a call site while every test looked at the
/// callee, and the judgements in here — how far forward is too far, how much
/// overshoot is too much — are precisely the ones that decide whether the card
/// tells the truth. Each of them has to be reachable from a test on its own.
///
/// Four of design 0073's five clamps are here; the fifth, **C1 (never
/// extrapolate unless the speed is `live`)**, is in [SpeedEstimator] because
/// only it knows the state, and it is the one that keeps 0042 G2 intact.
///
///  * **C2** — [horizon] is clamped into `[0, horizonMax]`. A negative horizon
///    (clock skew between the GNSS chip and the system clock) extrapolates
///    BACKWARDS, which is a fabricated deceleration; a late sample must
///    degrade to the pre-0073 behaviour (the reading parks) rather than being
///    carried further and further forward.
///  * **C3②** — a null [slopeMps2] (the acceleration estimator is warming or
///    suppressed: C3①) or one inside [TrendConfig.aDeadMps2] yields [level]
///    unchanged. "We do not know the trend" and "the trend is inside the noise"
///    are both answered by showing the number we actually have.
///  * **C4** — `|k·slope·Δ|` is capped at [TrendConfig.capMps].
///  * **C5** — as [level] approaches the still-clamp the compensation fades
///    linearly to zero, so extrapolation can never push a reading across the
///    clamp and back (0073 §7 Q10). Without it a scooter creeping at 3 km/h
///    would flicker 0 ⇄ 4 km/h, which is a louder version of the "2 km/h at a
///    red light" that [SpeedEstimatorConfig.vStillMps] exists to remove.
///
/// 🔴 Does NOT apply the still-clamp: the caller does, in the order 0073 §3.8
/// pin 3 fixes (extrapolate → clamp → format), through the same `_clampStill`
/// the recorded series uses. One clamp, one place.
double speedWithTrend({
  required double level,
  required double? slopeMps2,
  required Duration horizon,
  required Duration horizonMax,
  required double vStillMps,
  TrendConfig cfg = const TrendConfig(),
}) {
  // C3.
  final slope = slopeMps2;
  if (slope == null || slope.isNaN || slope.abs() < cfg.aDeadMps2) return level;

  // C2. Both ends bind: the low one against clock skew, the high one against a
  // late sample.
  var dt = horizon;
  if (dt.isNegative) dt = Duration.zero;
  if (dt > horizonMax) dt = horizonMax;

  var comp = cfg.k * slope * (dt.inMicroseconds / 1e6);

  // C4.
  if (comp > cfg.capMps) comp = cfg.capMps;
  if (comp < -cfg.capMps) comp = -cfg.capMps;

  // C5. The fade spans exactly the band a full-size compensation could carry a
  // reading across, `[vStillMps, vStillMps + C]`, so at the top of the band the
  // feature is at full strength and at the bottom it is off.
  comp *= stillFade(level, vStillMps: vStillMps, cfg: cfg);

  return level + comp;
}

/// C5's ramp, separately callable so the band can be pinned on its own.
///
/// 1.0 well clear of the still-clamp, 0.0 at or below it, linear in between.
double stillFade(
  double level, {
  required double vStillMps,
  TrendConfig cfg = const TrendConfig(),
}) {
  final band = cfg.capMps;
  if (band <= 0) return 1.0;
  final above = level.abs() - vStillMps;
  if (above <= 0) return 0.0;
  if (above >= band) return 1.0;
  return above / band;
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

  // ---- design 0073 replaced design 0071's three curve fields with none ----
  //
  // 🔵 0071 kept `_prevSmoothed`, `_lastRaw` and `_anchorAt` so the reading
  // could SWEEP from the previous smoothed value to the new one over a whole
  // sampling period. That curve pointed at the PAST — it started at the old
  // value, so the smoother it was drawn the later the reading began to move —
  // and 0073 §3.1 is the argument that this is the design's defect rather than
  // its tuning. There is nothing to carry between samples any more: the drawn
  // value is a pure function of `_ewma`, the clock, and a slope the caller
  // passes in, so removing the three fields also removed three ways for the
  // drawn value and the recorded one to disagree.

  /// Timestamped smoothed samples. Broadcast: the controller forwards it to the
  /// UI while design 0044's acceleration estimator listens in parallel.
  Stream<SpeedEstimate> get estimates => _estimates.stream;

  /// State changes only. See [SpeedStateTransition].
  Stream<SpeedStateTransition> get transitions => _transitions.stream;

  /// The newest estimate, or null while no fix has ever been accepted.
  SpeedEstimate? get current => _current;

  /// How far forward the reading may be carried, `Δ_max` (design 0073 C2).
  ///
  /// `T + λ_cap + T(1−α)/α`, i.e. one whole sampling period (the sample we are
  /// showing is at most that old before its successor lands), plus the delivery
  /// latency we are willing to believe ([TrendConfig.lambdaCap]), plus the
  /// filter's own steady-state lag — the last term being why `level` does not
  /// represent the moment the fix was stamped but a moment `T(1−α)/α` before it
  /// (0073 §3.3.1).
  ///
  /// ⚠️ The last term is only 0.176 s at α = 0.85 and would be easy to drop as
  /// noise. It is 1.0 s at α = 0.5 — 10.8 km/h at 3 m/s² — so it is carried
  /// symbolically rather than folded into a constant.
  Duration get trendHorizonMax {
    final t = config.samplingPeriod.inMicroseconds;
    final filterLagUs = config.alpha <= 0
        ? 0
        : (t * (1 - config.alpha) / config.alpha).round();
    return Duration(
        microseconds: t + config.trend.lambdaCap.inMicroseconds + filterLagUs);
  }

  /// The horizon Δ at [at]: how long ago the value now on screen was actually
  /// measured (0073 §3.3.1).
  ///
  /// `(at − lastLiveAt) + T(1−α)/α`. 🔑 The first term is NOT an estimate of
  /// the delivery latency, it IS this sample's own latency — `lastLiveAt` is
  /// the PLATFORM timestamp, so the difference is the complete "measured →
  /// now" distance and a sample that arrived two seconds late honestly has a
  /// two-second Δ (0073 §3.6 (A), ruled §7 Q4). The second term is the
  /// filter's, as in [trendHorizonMax].
  ///
  /// Not clamped here — [speedWithTrend] owns C2, so that the clamp is
  /// testable without an estimator.
  Duration trendHorizonAt(DateTime at) {
    final measuredAt = _lastFixAt;
    if (measuredAt == null) return Duration.zero;
    final t = config.samplingPeriod.inMicroseconds;
    final filterLagUs = config.alpha <= 0
        ? 0
        : (t * (1 - config.alpha) / config.alpha).round();
    return at.difference(measuredAt) + Duration(microseconds: filterLagUs);
  }

  /// Whether the drawn value would still be MOVING at [at] — the card's
  /// per-frame loop is armed and disarmed by this (design 0073 §3.10).
  ///
  /// The predicate is armed by the same three facts that make the reading move
  /// at all: the speed is live (C1), there is a usable slope (C3), and the
  /// horizon has not yet hit its ceiling (C2). Asking it rather than watching
  /// the value change is deliberate and predates 0073: a value-watching loop
  /// cannot tell "it has stopped" from "no time passed between these two
  /// frames", so it shuts itself off the first time a frame is cheap and
  /// nothing restarts it until the next sample.
  ///
  /// False in every state but [SpeedState.live], because those do not move at
  /// all — a new sample is then the only thing that can change the reading, and
  /// a new sample makes the controller notify, which rebuilds, which re-arms
  /// the ticker. Nothing is missed by stopping (0042 G4).
  bool displayTrendActiveAt(DateTime at, {double? slopeMps2}) {
    if (_state != SpeedState.live) return false;
    final smoothed = _ewma;
    if (smoothed == null) return false;
    if (slopeMps2 == null ||
        slopeMps2.isNaN ||
        slopeMps2.abs() < config.trend.aDeadMps2) {
      return false;
    }
    if (stillFade(smoothed, vStillMps: config.vStillMps, cfg: config.trend) <=
        0) {
      return false;
    }
    return trendHorizonAt(at) < trendHorizonMax;
  }

  /// The speed to DRAW at [at]: the filter's level carried forward along
  /// [slopeMps2] (design 0073 §3.3).
  ///
  /// ```
  /// v_display(t) = level + k · slope · Δ(t)
  /// ```
  ///
  /// [slopeMps2] is passed IN rather than read, and that is an architectural
  /// constraint rather than a preference: the slope is design 0044's least
  /// squares fit, which lives in `accel_estimator.dart`, which imports THIS
  /// file for [SpeedEstimate]. Reaching back for it would be a cycle, so
  /// [GpsSpeedController] — which already holds both estimators — is the
  /// assembly point (0073 §2.5 #1 / §3.10). Null means "no trend is available",
  /// which the caller uses for C3① (the acceleration window is warming or
  /// suppressed).
  ///
  /// 🔴 **C1 lives here, and it is what keeps 0042 G2 intact.** Only
  /// [SpeedState.live] is extrapolated. Holding, lost and "no fix yet" answer
  /// with the frozen [SpeedEstimate.vSmoothMps] and go on answering with it
  /// however far [at] is advanced — extrapolating into a tunnel would be the
  /// MIRROR of the decay animation 0042 §3.2 forbids by name: one pretends to
  /// slow down, the other pretends to speed up, and neither was measured.
  ///
  /// 🔴 Pure read. It emits nothing, mutates nothing, and is not consulted by
  /// [_estimateAt]: the RECORDED series is untouched by everything in here
  /// (0073 G4, sustaining 0071 §3.5 pin 2). Design 0044 differentiates
  /// [estimates] and design 0061 stores it; both must see the series they saw
  /// before this method existed.
  ///
  /// Returns null only when no fix has ever been accepted (or after a
  /// [reset]) — see the body.
  ///
  /// The still-clamp is applied on the way out, in the same order as
  /// [_estimateAt] applies it (0073 §3.8 pin 3): extrapolate, then clamp, then
  /// the caller's `formatSpeed`. So a reading decelerating through 3 km/h still
  /// lands on a hard 0 rather than trailing decimals at a red light.
  double? displaySpeedMpsAt(DateTime at, {double? slopeMps2}) {
    final smoothed = _ewma;
    // 🔴 Null, not 0.0. "This estimator has no series to draw" and "the vehicle
    // is stopped" are different facts, and returning 0.0 for the first is the
    // same mistake `SpeedFix.speedMps` was made nullable to stop: a number
    // nobody measured, indistinguishable from one somebody did. The caller
    // renders whatever it was already rendering (`SpeedCardBody` falls back to
    // [SpeedEstimate.vSmoothMps]) instead of a zero this method invented.
    if (smoothed == null) return null;
    // C1. Note this returns the STILL-CLAMPED level and ignores `at` entirely,
    // so "push the clock forward ten seconds" cannot move a held number.
    if (_state != SpeedState.live) return _clampStill(smoothed);

    return _clampStill(speedWithTrend(
      level: smoothed,
      slopeMps2: slopeMps2,
      horizon: trendHorizonAt(at),
      horizonMax: trendHorizonMax,
      vStillMps: config.vStillMps,
      cfg: config.trend,
    ));
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
      // 🔵 0071 §3.5 pin 4 used to be a WARNING here — "do not re-anchor the
      // display curve" — because re-anchoring would have replayed the last step
      // of a ramp that had already finished, making a parked scooter's reading
      // crawl once a second for ever. 0073 §3.8 keeps the pin and changes its
      // shape: there is no anchor left to reset, and the protection is now
      // structural. Nothing entered the smoother, so `level` is unchanged; the
      // repeated value goes into design 0044's window, so the slope decays
      // toward zero and C3②'s deadband stops the extrapolation. ⚠️ **A parked
      // scooter must not creep upward on a leftover slope** — that is what
      // `speed_estimator_test.dart`'s FB-56 case is now checking.
      //
      // ⚠️ `_lastFixAt` IS refreshed, and that half matters more than it did
      // before 0073: it is the origin of the horizon Δ, so a sustained zero
      // keeps Δ small rather than letting it drift out to its ceiling.
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
      // 🔴 0071 §3.5 pin 5 lived here as a second assignment (`_prevSmoothed =
      // fix.speedMps!`), which gave the re-seed a FLAT curve: without it the
      // first second out of a tunnel was spent walking the reading down from
      // the speed the rider was doing BEFORE the tunnel — the exact number
      // 0042 §3.2 forbids blending in, drawn instead of averaged.
      //
      // 🔵 0073 §3.8 removed the curve, and with it that line. The protection
      // did not move into this file: it is now that `AccelEstimator` empties
      // its window on the way back to `live`, so there is no slope for about
      // two seconds and C3① shows the plain re-seeded level. 🔴 **That makes
      // this the one place where 0073 weakened a guard we owned into one
      // another module happens to provide** — hence a test that asserts the
      // RESULT (no value between the pre- and post-tunnel speeds ever appears)
      // rather than trusting 0044 to keep behaving this way.
      _ewma = fix.speedMps!;
    } else {
      _ewma = config.alpha * fix.speedMps! + (1 - config.alpha) * previousSmoothed;
    }
    // Read once and used for the estimate's `t`; a second `now()` call would
    // let two stamps in one operation disagree by microseconds.
    final at = now();

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
    // 🔵 0071 cleared three curve fields here so that [displaySpeedMpsAt] could
    // not answer with the previous session's speed while [current] was already
    // null — a card drawing a number it is simultaneously reporting it does not
    // have (0071 §5 #5). 0073 removed those fields; `_ewma = null` above is now
    // the whole of it, because the drawn value is a pure function of `_ewma`.
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
