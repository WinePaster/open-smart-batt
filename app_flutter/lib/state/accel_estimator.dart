/// OpenSmartBatt — acceleration from GPS speed (design 0044 Phase 0 / Phase G).
///
/// The acceleration shown by this app is the SLOPE OF THE SPEED CURVE, not an
/// inertial measurement. No accelerometer, no gyroscope, no sensor fusion
/// (0044 N1; the inertial option was archived by 0042 Q3 and this file is not
/// a way to reopen it). It consumes [SpeedEstimator]'s output and nothing else.
///
/// 🔴 **The specification here is the REFUSAL, not the arithmetic.** A least
/// squares slope is a dozen lines; what earns this file its existence is
/// knowing when NOT to produce one:
///
///  * While the speed estimator is `holding` or `lost`, the displayed speed is
///    FROZEN. Differentiating a frozen value yields exactly 0.0 — a number that
///    looks like a perfectly measured "steady speed" and was measured by
///    nobody. That is design 0044 G2, and it is the first pinned test.
///  * After the signal comes back, the window starts EMPTY. The samples from
///    before a tunnel and the samples from after it are two different series,
///    and a slope drawn across the join describes an event that never happened.
///    Acceleration therefore appears `T_w` seconds later than speed does, which
///    is the honest cost of not inventing it.
///
/// 🔴 PRIVACY (0044 G3): acceleration is a pure function of speed. This file
/// adds no data source, touches no coordinate and cannot — [SpeedEstimate] has
/// no coordinate field to read. 0042 G5's red line applies unchanged.
///
/// Pure Dart on purpose, like `speed_estimator.dart`: no Flutter, no plugin.
/// [GpsSpeedController] owns the wiring; this file owns only the arithmetic and
/// the state machine.
library;

import 'dart:async';

import 'speed_estimator.dart';

/// Whether an acceleration reading exists, is still being gathered, or is being
/// deliberately withheld.
///
/// [warming] and [suppressed] both mean "nothing on screen", and they are still
/// two values rather than one because they answer different questions and the
/// road test will want to tell them apart: warming is "give it two seconds",
/// suppressed is "the speed underneath is not being measured".
enum AccelState {
  /// The window is not full enough to draw a line through (fewer than
  /// [AccelEstimatorConfig.nMin] samples, or spanning less than
  /// [AccelEstimatorConfig.tWindow] minus [AccelEstimatorConfig.tSlack]).
  /// Nothing is emitted.
  warming,

  /// The window is full; the slope is a measurement. This is the only state
  /// that emits.
  live,

  /// The speed estimator left [SpeedState.live], so its output is a frozen
  /// value rather than a measured one. The window is EMPTIED and nothing is
  /// emitted — see the file header.
  suppressed,
}

/// Every threshold this module has, in one const object (0044 R3).
///
/// All of them are paper starting points: nothing here has met a real
/// motorcycle yet, which is why design 0044 §5 Phase 3 makes the road test a
/// release gate. Collecting them here is what makes the retune a one-file edit.
///
/// The last three are DISPLAY constants. They live beside the estimator's own
/// because the road test tunes all five in one sitting, but the estimator never
/// applies them: what it emits is the raw slope, and that is also what lands in
/// history (0044 §3.5 — "what the analyst gets is what the screen showed" is
/// about the same source, not about the same rounding).
class AccelEstimatorConfig {
  const AccelEstimatorConfig({
    this.tWindow = const Duration(seconds: 2),
    this.tSlack = const Duration(milliseconds: 500),
    this.nMin = 3,
    this.aDeadMps2 = 0.15,
    this.displayQuantumMps2 = 0.1,
    this.displayThrottle = const Duration(milliseconds: 500),
  });

  /// `T_w` — the sliding window a straight line is fitted to.
  ///
  /// One knob rather than two, which is why a least squares slope was chosen
  /// over a second EWMA stage (0044 §4.2): it has a sentence anyone can read
  /// back — "the average acceleration over the last two seconds".
  final Duration tWindow;

  /// `T_slack` — tolerance around the [tWindow] boundary (FB-57).
  ///
  /// As shipped, pruning guaranteed the window spanned AT MOST `T_w` while
  /// fullness required AT LEAST `T_w`, so the two could only agree when a
  /// sample landed on the boundary to the microsecond. Real GNSS fixes carry
  /// tens of milliseconds of jitter, so `live` was unreachable and the accel
  /// column had never held a value in production. The slack is applied on both
  /// sides: pruning keeps history back to `T_w + T_slack`, and a window
  /// spanning `T_w − T_slack` counts as full. The fitted span therefore lands
  /// in `[T_w − T_slack, T_w + T_slack]` — "about the last two seconds",
  /// which is the only version of that sentence a jittered clock can honour.
  final Duration tSlack;

  /// `N_min` — fewest samples that may be called a line. Two points always fit
  /// a line perfectly, which is another way of saying two points cannot
  /// disagree with one, so a third is the first one that carries information.
  final int nMin;

  /// `A_dead` — display deadband in m/s². Below this the SCREEN reads 0.0.
  ///
  /// Not a filter on the measurement: the value still lands in history
  /// unrounded. GNSS speed noise is 0.1–0.5 m/s (0044 §2.2), and differentiating
  /// it produces a number of the same order as a real scooter launch, so
  /// without a deadband the reading would swing sign at a red light.
  final double aDeadMps2;

  /// Display quantum in m/s². The displayed number is snapped to a multiple of
  /// this BEFORE unit conversion.
  ///
  /// ⚠️ Two sentences in 0044 §3.3 pull in different directions here:
  /// "量化到 0.1 m/s²" and "(換算後同樣一位小數)". One decimal of `km/h/s` is
  /// 0.028 m/s² — 3.6× FINER than 0.1 m/s², so the parenthetical cannot be the
  /// binding one without discarding the constant it follows. G4 ("a flickering
  /// number is worse than none") settles it toward the coarser reading: snap in
  /// m/s², then render one decimal in the user's unit. The visible consequence
  /// is that the reading steps in multiples of 0.36 km/h/s rather than 0.1 —
  /// stable, at the price of never landing on a round-looking number. Revisit
  /// at the road test with the rest of the knobs.
  final double displayQuantumMps2;

  /// Shortest interval between two DISPLAYED values (0044 §3.2 抑抖 3).
  ///
  /// Applied by [GpsSpeedController] on the way to the card, never on
  /// [AccelEstimator.estimates] — the recorded series must not be thinned by a
  /// decision about repaint rates.
  ///
  /// With a 1 s sampling period this never binds; it is here so that lowering
  /// `GeolocatorSpeedSource.speedSamplingPeriod` at the road test cannot turn
  /// the sub-readout into a blur as a side effect.
  final Duration displayThrottle;
}

/// One acceleration sample: the raw slope, in m/s², signed.
///
/// Positive is speeding up. There is no deadband and no quantisation in here —
/// that is the display's business, and this value is the one that lands in
/// history (0044 §3.5 / Phase 2 pinned test).
class AccelEstimate {
  const AccelEstimate({required this.t, required this.aMps2});

  /// The time of the newest sample in the window, on the speed estimator's
  /// injected clock (i.e. [SpeedEstimate.t] — "when this app learnt it", NOT
  /// when the fix was measured; impl plan §1.4).
  final DateTime t;

  /// Signed acceleration in m/s². Internally and in history this is always
  /// m/s²; the unit the user picked is applied at the last moment (0044 §3.3).
  final double aMps2;
}

/// The display transform: deadband, then quantisation. Still in m/s².
///
/// A named top-level function rather than four lines inside a widget's
/// `build`, and deliberately so: this project has three times shipped a defect
/// that lived at a call site while every test looked at the callee. A judgement
/// that cannot be called from a test is a judgement no test is checking, so the
/// deadband — the thing that decides whether the rider sees `0.0` or `-0.2` —
/// is reachable directly from `accel_estimator_test.dart`.
///
/// Applied ONLY to what is shown. [AccelEstimator.estimates] and therefore the
/// history column stay raw (0044 §3.2 抑抖 preamble).
double displayAccel(
  double aMps2, [
  AccelEstimatorConfig config = const AccelEstimatorConfig(),
]) {
  if (aMps2.abs() < config.aDeadMps2) return 0.0;
  final q = config.displayQuantumMps2;
  if (q <= 0) return aMps2;
  return (aMps2 / q).roundToDouble() * q;
}

/// Differentiates [SpeedEstimator]'s smoothed speed series.
///
/// Fed from two streams and both are load-bearing:
///
///  * [onSpeedEstimate] carries the samples, and its `state` field is what says
///    whether a sample is a measurement at all.
///  * [onTransition] carries edges the sample stream cannot express. In
///    particular `SpeedEstimator.reset()` emits a `→ lost` transition and NO
///    estimate (impl plan §1.4 note 1), and a reset is exactly the moment two
///    unrelated series get spliced together — every
///    `AppLifecycleState.inactive`, which a pulled-down notification shade is
///    enough to cause, runs one.
///
/// Neither input is trusted to arrive first. Both handlers make the same
/// decision from whatever they are given, so the two broadcast streams may
/// interleave in either order without changing the outcome.
class AccelEstimator {
  AccelEstimator({this.config = const AccelEstimatorConfig()});

  final AccelEstimatorConfig config;

  final StreamController<AccelEstimate> _estimates =
      StreamController<AccelEstimate>.broadcast();

  final List<_Sample> _window = <_Sample>[];

  AccelState _state = AccelState.warming;
  AccelEstimate? _current;

  /// Raw slopes, one per accepted speed sample while [AccelState.live].
  ///
  /// Nothing is emitted in the other two states. That silence IS the output:
  /// there is no "0.0, but we are not sure" value, because a rider cannot tell
  /// one of those from a real steady speed.
  Stream<AccelEstimate> get estimates => _estimates.stream;

  /// Newest slope, or null whenever [state] is not [AccelState.live].
  AccelEstimate? get current => _current;

  /// 🆕 design 0073 §7 Q9 — the slope to EXTRAPOLATE THE SPEED READING with.
  ///
  /// 🔴 **This is a second reading of the SAME window, not a second window, and
  /// the distinction is the whole reason this getter exists rather than a
  /// shorter `tWindow`.** [estimates] is the RECORDED series: design 0044 §3.5
  /// defines it as "the average acceleration over the last two seconds", it is
  /// a sentence the analyst reads back off the history column and off design
  /// 0061's per-second storage, and nothing in design 0073 is allowed to change
  /// it (0073 G4). So the fit below runs over [_window] — the buffer that was
  /// already there, with the samples that were already in it — and touches
  /// neither the buffer nor anything [onSpeedEstimate] emits.
  ///
  /// **What is adaptive about it.** The fixed two-second window is right for
  /// history and wrong at a standing start, and 0073 §7 Q9 has the arithmetic:
  /// three 1 Hz samples reading `0, 0, a·1` fit a least squares slope of
  /// **a/2**, so for the first two seconds of a launch — the two seconds the
  /// rider is staring at the number — the trend is half its true size, and it
  /// is half because the window still contains the time the vehicle was
  /// STOPPED, not because the estimator is insensitive. A low-speed `k` cannot
  /// fix that (the same constant would have to be 2 at the moment of launch and
  /// 1 two seconds later, which is the proof it is the wrong knob); dropping
  /// the stationary part of the window can.
  ///
  /// So: fit from the LAST still sample onward. `vSmoothMps` arrives already
  /// still-clamped ([SpeedEstimatorConfig.vStillMps]), so a stationary sample
  /// is an exact `0.0` and no threshold of this file's own is needed — the one
  /// that decides where zero starts stays in one place. On the `0, 0, a`
  /// window that leaves `0, a` and a slope of **a**.
  ///
  /// Null unless [state] is [AccelState.live] (0073 C3①): the full 0044
  /// fullness rule still gates whether a trend exists at all, so a tunnel is
  /// still followed by ~2 s of no extrapolation. The trimming only decides
  /// which of the samples in an already-accepted window are fitted.
  ///
  /// ⚠️ The trimmed fit may be two points, which 0044's [AccelEstimatorConfig.nMin]
  /// comment rightly calls the number that carries no information — two points
  /// always fit a line perfectly. That objection is about the RECORDED value,
  /// where a wrong slope is a wrong fact in the history column. Here the
  /// consequence is bounded by design 0073's C4 (±[TrendConfig.capMps]) and
  /// erased by the next sample, and the alternative is knowingly showing half
  /// the acceleration during a launch. If fewer than two samples survive the
  /// trim — i.e. the newest sample is itself a still-clamped zero — the whole
  /// window is fitted instead, which is the right answer anyway: a vehicle that
  /// has just stopped should report the deceleration that stopped it.
  double? get displaySlopeMps2 {
    if (_state != AccelState.live) return null;
    var from = 0;
    for (var i = 0; i < _window.length; i++) {
      if (_window[i].v <= 0.0) from = i;
    }
    if (_window.length - from < 2) from = 0;
    return _slope(from);
  }

  AccelState get state => _state;

  /// Number of samples currently in the window. Exposed for tests, because
  /// "the window was actually emptied" is one of the pinned claims (0044 §3.2)
  /// and the alternative way to check it — waiting to see whether a wrong slope
  /// comes out — only fails some of the time.
  int get windowLength => _window.length;

  /// Feed one speed estimate.
  ///
  /// A non-live estimate suppresses and empties, whatever it says: `holding`
  /// carries the last MEASURED speed repeated, so a run of them differentiates
  /// to a flawless 0.0 m/s² that nobody measured. That is the whole of G2.
  void onSpeedEstimate(SpeedEstimate e) {
    if (e.state != SpeedState.live) {
      _suppress();
      return;
    }
    if (_state == AccelState.suppressed) _restart();

    final last = _window.isEmpty ? null : _window.last;
    if (last != null) {
      if (e.t.isBefore(last.t)) {
        // Time ran backwards, so these are not one series. Documented as a real
        // failure once (impl plan §1.4 note 2: `t` measured 0 → 2100 → 1750 ms
        // while two clocks were mixed) and fixed upstream — the guard stays
        // because a negative dt divides into a slope with a plausible magnitude
        // and the wrong sign, which is the kind of wrong that gets believed.
        _restart();
      } else if (!e.t.isAfter(last.t)) {
        // Same instant. Not a discontinuity and not new information; adding it
        // would put a zero-length step into the fit.
        return;
      }
    }

    _window.add(_Sample(e.t, e.vSmoothMps));
    _prune();
    if (!_windowIsFull()) {
      // Includes the case of a long gap with no transition to mark it: pruning
      // leaves one sample, the window is short again, and the state honestly
      // falls back to warming instead of fitting a line to a hole.
      _state = AccelState.warming;
      _current = null;
      return;
    }
    _state = AccelState.live;
    final estimate = AccelEstimate(t: e.t, aMps2: _slope());
    _current = estimate;
    _estimates.add(estimate);
  }

  /// Feed one speed state transition.
  ///
  /// Leaving [SpeedState.live] suppresses. Returning to it does NOT resume —
  /// it starts a new, empty window, so the first slope after a tunnel is drawn
  /// only through samples taken after the tunnel.
  void onTransition(SpeedStateTransition t) {
    if (t.to != SpeedState.live) {
      _suppress();
      return;
    }
    // If a live estimate got here first, it already restarted the window; doing
    // it again would throw away the sample it added.
    if (_state == AccelState.suppressed) _restart();
  }

  Future<void> dispose() => _estimates.close();

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  void _suppress() {
    _window.clear();
    _current = null;
    _state = AccelState.suppressed;
  }

  void _restart() {
    _window.clear();
    _current = null;
    _state = AccelState.warming;
  }

  /// Drop samples older than [AccelEstimatorConfig.tWindow] plus
  /// [AccelEstimatorConfig.tSlack] behind the newest.
  ///
  /// The slack is what keeps a sample alive on the far side of the `T_w`
  /// boundary. Pruning exactly at `T_w` capped the span at `T_w` while
  /// [_windowIsFull] demanded `T_w` — satisfiable only by a
  /// microsecond-perfect timestamp, which jittered fixes never produce
  /// (FB-57).
  void _prune() {
    final newest = _window.last.t;
    final cutoff = newest.subtract(config.tWindow + config.tSlack);
    _window.removeWhere((s) => s.t.isBefore(cutoff));
  }

  /// Both halves of "full" are required (0044 §3.2): enough points, and enough
  /// elapsed time. Three points 200 ms apart fit a line beautifully and say
  /// nothing about a two second average. "Enough" is `T_w − T_slack`, not
  /// `T_w` — see [AccelEstimatorConfig.tSlack] for why exact equality was a
  /// bug and not a specification.
  bool _windowIsFull() {
    if (_window.length < config.nMin) return false;
    final span = _window.last.t.difference(_window.first.t);
    return span >= config.tWindow - config.tSlack;
  }

  /// Ordinary least squares slope of v against t, in m/s².
  ///
  /// Chosen over adjacent differencing plus a second EWMA (two coupled knobs,
  /// an effective delay nobody can explain) and over central differencing
  /// (needs a future sample, so it is late by construction) — 0044 §4.2. It
  /// also degrades gracefully: a rejected fix just means one fewer point in the
  /// window, not a gap that has to be special-cased.
  ///
  /// [from] is the index of the first sample to fit, and it is 0 for everything
  /// that reaches [estimates] — the recorded series is the whole window, always
  /// (0044 §3.5 / 0073 G4). Only [displaySlopeMps2] ever passes anything else.
  double _slope([int from = 0]) {
    final t0 = _window[from].t;
    var sx = 0.0, sy = 0.0;
    for (var i = from; i < _window.length; i++) {
      final s = _window[i];
      sx += s.t.difference(t0).inMicroseconds / 1e6;
      sy += s.v;
    }
    final n = _window.length - from;
    final mx = sx / n, my = sy / n;
    var num = 0.0, den = 0.0;
    for (var i = from; i < _window.length; i++) {
      final s = _window[i];
      final dx = s.t.difference(t0).inMicroseconds / 1e6 - mx;
      num += dx * (s.v - my);
      den += dx * dx;
    }
    // Unreachable while [_windowIsFull] requires a non-zero span, and still
    // guarded: a zero denominator would produce infinity, and an infinite
    // acceleration would render as a number rather than as an obvious fault.
    if (den == 0) return 0.0;
    return num / den;
  }
}

class _Sample {
  const _Sample(this.t, this.v);
  final DateTime t;
  final double v;
}
