/// OpenSmartBatt — GPS speed controller (design 0042 Phase B).
///
/// Everything platform-shaped about the speed feature lives here: the location
/// plugin, the runtime permission, and the lifecycle gate that decides when a
/// GNSS stream is allowed to exist at all. [SpeedEstimator] next door stays
/// pure Dart and does the arithmetic.
///
/// 🔴 PRIVACY RED LINE (design 0042 G5). The platform hands us a position
/// object that DOES carry a coordinate. [GeolocatorSpeedSource.toFix] is the
/// single line where that object is read, and it copies four scalars out of it —
/// none of them a coordinate. Downstream of that line no latitude or longitude
/// exists, so none can be logged, stored or exported. `speed_privacy_test.dart`
/// scans this file for coordinate identifiers.
///
/// **Why there is no `speedDetection` gate here.** The master switch (design
/// 0042 §3.9) does not need a fourth condition: with the switch off
/// `renderedModules` drops `speed` from whatever face named it, no `SpeedCard`
/// is ever built, and [setFaceWantsSpeed] is therefore never true. The switch
/// gates the stream through condition 1 rather than beside it — which is also
/// what makes "off ⇒ speed never lands" true by construction instead of by a
/// second check somebody could forget.
///
/// 🔴 That chain was rebuilt one layer down on 2026-08-07 and it is worth
/// knowing why, because the version it replaced looked equally sound. Until
/// design 0045 the filtering happened at the FACE layer: switch off ⇒ `riding`
/// falls back to `standard` ⇒ no `speed` module exists. Design 0045 Q3 then let
/// the G meter keep `riding` alive on its own, at which point a face-level
/// answer would have drawn `riding` — including its speed card — for a user who
/// had only ever turned the G meter on. GNSS would have opened, and speed rows
/// would have landed, with the location consent dialog never shown. Moving the
/// decision from "which face" to "which modules" keeps one decision point and
/// restores the property; `speed_privacy_test.dart` pins it at the new
/// layer.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'accel_estimator.dart';
import 'speed_estimator.dart';

/// What the OS currently says about our access to location.
///
/// [notRequested] is our own "we have not looked yet" and is distinct from
/// [denied] on purpose: the card must not accuse the user of refusing before
/// anything was asked.
enum SpeedPermissionState { notRequested, granted, denied, permanentlyDenied }

/// The platform work the controller needs, behind a seam.
///
/// It exists so the three-condition gate — the part with real failure modes —
/// can be tested without a GNSS chip. Same reasoning as the injectable
/// [BleService] and [MonitorService]: the logic worth testing is the one
/// deciding WHEN to talk to the platform.
abstract class SpeedLocationSource {
  /// Continuous fixes. Subscribing starts the hardware; cancelling stops it.
  Stream<SpeedFix> fixes();

  /// Read the current permission WITHOUT prompting.
  Future<SpeedPermissionState> status();

  /// Prompt for permission. Only ever called from the consent flow (§3.5).
  Future<SpeedPermissionState> request();

  /// Send the user to the OS settings page for this app.
  Future<void> openSystemSettings();
}

/// The real implementation: `geolocator` for fixes, `permission_handler` for
/// the grant — the same `Permission.locationWhenInUse` the pre-Android-12 BLE
/// scan already uses (`ble_service.dart`), so there is one location permission
/// in the app, not two.
class GeolocatorSpeedSource implements SpeedLocationSource {
  const GeolocatorSpeedSource();

  /// `bestForNavigation` with no distance filter (0042 §3.4).
  ///
  /// A distance filter looks like the obvious battery saving and is the wrong
  /// one here: it suppresses updates while the vehicle holds a steady speed,
  /// which is exactly when the estimator would then age its last sample out and
  /// declare a tunnel that is not there. Battery is bought by the lifecycle
  /// gate instead — no stream at all when the dashboard is not on screen.
  /// 🔴 The sampling period must be requested EXPLICITLY on Android.
  ///
  /// The base [LocationSettings] looks like it asks for "as fast as the chip
  /// will go". It does not, and the gap is silent: its `toJson()` emits only
  /// `accuracy` and `distanceFilter` (geolocator_platform_interface 4.2.8,
  /// `location_settings.dart:38-43`), so no interval crosses the channel; the
  /// Java side then falls back to its own default of **5000 ms**
  /// (`LocationOptions.java:59`) and — the part that actually bites —
  /// `FusedLocationClient.java:106-107` sets it as `setIntervalMillis` AND
  /// `setMinUpdateIntervalMillis`, so 5 s becomes a floor as well as a target.
  ///
  /// Against a state machine whose T_hold is 2 s and T_lost is 4 s, a 5 s
  /// period means a clear-sky ride cycles live → holding → lost → live forever:
  /// the screen would say "no signal" roughly 60 % of the time, every sample
  /// would arrive as a post-gap sample and re-seed the EWMA (so the smoothing
  /// would not exist), and `transitions` would emit three edges every 5 s.
  ///
  /// None of the 940 tests caught it because none of them looks at what is
  /// handed to the plugin. [speedSamplingPeriod] and the test that pins it are
  /// the correction: the settings object is now an argument the suite can read.
  ///
  /// iOS is unaffected (CoreLocation delivers ~1 Hz on its own) but is given
  /// the same object for one behaviour on both platforms.
  ///
  /// 🔴 **This is the eleventh road-test knob, and the only one not inside
  /// [SpeedEstimatorConfig]** — so retuning after Phase F means editing TWO
  /// files, not one. It is here rather than there because it is an argument to
  /// a plugin, and `speed_estimator.dart` deliberately imports nothing but
  /// `dart:async`; a platform constant is not worth breaking that for.
  ///
  /// The pairing is not optional to remember: `tHold` (2 s) and `tLost` (4 s)
  /// are ages measured against THIS interval. Keep it comfortably below `tHold`
  /// or a clear sky cycles live → holding → lost forever — which is precisely
  /// what the plugin's own 5 s default did. `SpeedEstimatorConfig`'s doc
  /// comment carries the mirror of this note.
  ///
  /// 🔴 Since design 0071 there is a THIRD place this number appears:
  /// `SpeedEstimatorConfig.samplingPeriod` (called `displayRampPeriod` until
  /// design 0073 removed the ramp). It is now `T` in the extrapolation ceiling
  /// `Δ_max = T + λ_cap + T(1−α)/α`. Change this one and that one must move
  /// with it, or the reading is allowed to run forward for the wrong length of
  /// time — which does not look like a bug while you are staring at it.
  ///
  /// 🔵 Lowering it is design 0073 §4.4 D, and the reason that option is
  /// COMPATIBLE with 0073 rather than an alternative to it: a shorter period
  /// makes Δ smaller and Δ_max tighter by itself, so the extrapolation quietly
  /// does less work and no other line has to change.
  static const Duration speedSamplingPeriod = Duration(seconds: 1);

  /// The settings actually handed to the plugin. Exposed so a test can assert
  /// the interval survives the trip — see the note above.
  ///
  /// [isAndroid] is injectable because the host test VM is neither platform,
  /// so the branch that actually matters would otherwise be the one branch no
  /// test can reach — which is precisely how the 5 s default got in.
  @visibleForTesting
  static LocationSettings locationSettings({bool? isAndroid}) {
    if (isAndroid ?? Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: speedSamplingPeriod,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
  }

  @override
  Stream<SpeedFix> fixes() =>
      Geolocator.getPositionStream(locationSettings: locationSettings())
          .map(toFix);

  /// 🔴 G5's enforcement point. Four scalars are copied out; everything else
  /// the platform offers is left behind with the object it came on.
  @visibleForTesting
  static SpeedFix toFix(Position p) => SpeedFix(
        // 🔴 "No speed reported" and "stopped" arrive as the SAME bytes.
        //
        // Both mappers omit the key when the chip has no speed solution
        // (`LocationMapper.java:29` guards on `hasSpeed()`), and
        // `Position._toDouble(null)` renders an absent key as `0.0`. The design
        // doc's `speed < 0` filter was written for CoreLocation's documented
        // invalid marker, which geolocator never lets through — so an
        // unmeasured reading used to be published as `0 km/h, good, live`.
        //
        // The disambiguator is the accuracy: a chip with a real speed solution
        // reports its uncertainty alongside (API 26+ / iOS 10+). Zero speed
        // AND no uncertainty is the shape of "nothing to report".
        //
        // ⚠️ This deliberately errs toward silence. A genuinely stationary
        // vehicle on a pre-API-26 device also lands here and shows "waiting"
        // rather than "0 km/h" — which is the honest side to be wrong on, and
        // the only side G2 allows.
        speedMps: (p.speed == 0.0 && p.speedAccuracy <= 0) ? null : p.speed,
        // Non-nullable on the platform side, so "not reported" arrives as 0 or
        // -1 (0042 §2.3 #3, still unverified in the field on old Android).
        // Both are mapped to null, which is what makes the card omit the ±
        // line rather than print a meaningless "±0.0".
        speedAccuracyMps: p.speedAccuracy > 0 ? p.speedAccuracy : null,
        // B3: the same guard the line above has, for the same reason. Both
        // platforms omit the key when the value is unavailable and
        // `Position._toDouble(null)` turns that into 0.0
        // (geolocator_platform_interface `position.dart:200-206`), while iOS
        // reports a NEGATIVE accuracy for an invalid fix. Ungrounded, "no
        // accuracy reported" scored as 0 m — the best possible reading — and
        // the estimator called it `good`. Anything <= 0 is "not reported", and
        // the estimator's reject floor is what should then throw it out.
        horizontalAccuracyM:
            p.accuracy > 0 ? p.accuracy : double.infinity,
        timestamp: p.timestamp,
      );

  @override
  Future<SpeedPermissionState> status() async =>
      _map(await Permission.locationWhenInUse.status);

  @override
  Future<SpeedPermissionState> request() async =>
      _map(await Permission.locationWhenInUse.request());

  @override
  Future<void> openSystemSettings() => openAppSettings();

  static SpeedPermissionState _map(PermissionStatus s) {
    if (s.isGranted) return SpeedPermissionState.granted;
    if (s.isPermanentlyDenied) return SpeedPermissionState.permanentlyDenied;
    return SpeedPermissionState.denied;
  }
}

/// Owns the GNSS stream's lifetime and feeds [SpeedEstimator].
///
/// The gate (0042 §3.4) is three conditions that must ALL hold for a stream to
/// exist; any one going false cancels it immediately:
///
/// 1. a speed card is mounted ([setFaceWantsSpeed], driven by `SpeedCard`'s own
///    lifecycle);
/// 2. the app is in the foreground ([setAppResumed]);
/// 3. a surface that can CARRY a speed card is on screen —
///    [setDashboardVisible] for the tab, [setDetailVisible] for the pushed
///    device page.
///
/// 🔴 Condition 3 grew a second input in design 0046 Step 8c, and the reason is
/// worth stating because the failure it prevents is SILENT. Before 0046 there
/// was exactly one surface that could hold a speed card — the dashboard tab —
/// so `setDashboardVisible(_tab == dashboard)` said everything. After 0046 the
/// dashboard lives inside a PUSHED route (the device detail page) while the tab
/// underneath it is 裝置, and the home grid can hold a speed card of its own. A
/// single tab-derived flag would therefore have kept the gate SHUT for the whole
/// time the user is on the page that shows speed: the card would sit there
/// forever displaying "waiting for a fix", with no error, and the user would
/// conclude the GPS could not get a signal. That is precisely the class of
/// defect this project is worst at diagnosing.
///
/// ⚠️ What did NOT change is that the gate exists. 0042 G4 (battery cost is
/// controlled) is a hard goal; what widened is WHICH SCREENS COUNT, not whether
/// screens are counted. With neither surface up, the stream closes.
///
/// Continuous GNSS costs an order of magnitude more battery than the BLE link
/// this app already holds open (0042 G4), and unlike the BLE link it buys
/// nothing while nobody is looking at the number — design 0039's background
/// connection deliberately does not extend to location.
class GpsSpeedController extends ChangeNotifier {
  GpsSpeedController({
    this.source = const GeolocatorSpeedSource(),
    SpeedEstimatorConfig config = const SpeedEstimatorConfig(),
    this.accelConfig = const AccelEstimatorConfig(),
    DateTime Function() now = DateTime.now,
    this.tickInterval = const Duration(seconds: 1),
  })  : _now = now,
        _estimator = SpeedEstimator(config: config, now: now),
        _accel = AccelEstimator(config: accelConfig) {
    // Design 0044 Phase G. Both of the estimator's streams are needed and the
    // second one is the easy one to forget: `reset()` announces the end of a
    // series on `transitions` and emits no estimate at all, so an acceleration
    // module fed only by `estimates` would differentiate straight across a
    // notification-shade pull (impl plan §1.4 note 1).
    _speedToAccel = _estimator.estimates.listen(_feedAccelEstimate);
    _transitionsToAccel = _estimator.transitions.listen(_feedAccelTransition);
  }

  /// The platform seam. Swapped for a fake in tests; there is exactly one
  /// production implementation.
  final SpeedLocationSource source;

  /// How often [SpeedEstimator.tick] runs while the stream is open.
  final Duration tickInterval;

  /// Design 0044's thresholds, including the display throttle this class
  /// applies on the way to the card.
  final AccelEstimatorConfig accelConfig;

  final SpeedEstimator _estimator;
  final AccelEstimator _accel;

  /// The same clock the estimator uses, kept so the display throttle is driven
  /// by injected time rather than by the wall clock — otherwise the one piece
  /// of timing in this class would be the one piece no test could reach.
  final DateTime Function() _now;

  StreamSubscription<SpeedEstimate>? _speedToAccel;
  StreamSubscription<SpeedStateTransition>? _transitionsToAccel;

  AccelEstimate? _publishedAccel;
  DateTime? _publishedAccelAt;

  bool _faceWantsSpeed = false;
  // The app is in the foreground when it starts; lifecycle callbacks only fire
  // on a CHANGE, so starting this false would need a resume that never comes.
  bool _appResumed = true;
  bool _dashboardVisible = false;
  bool _detailVisible = false;

  /// Gate condition 3's TAB half, readable so a test can drive it through the
  /// real shell.
  ///
  /// It is exposed because the 2026-08-07 review found a route that set the tab
  /// without telling this controller, and a unit test on [setDashboardVisible]
  /// would have passed the whole time — the defect was in the CALLER. Making
  /// the condition observable is what lets `widget_test.dart` assert on the
  /// shell's behaviour instead of on this class's.
  @visibleForTesting
  bool get dashboardVisible => _dashboardVisible;

  /// Gate condition 3's PUSHED-ROUTE half. See [setDetailVisible].
  @visibleForTesting
  bool get detailVisible => _detailVisible;

  /// Whether condition 3 holds at all — either surface counts.
  @visibleForTesting
  bool get speedSurfaceVisible => _dashboardVisible || _detailVisible;

  StreamSubscription<SpeedFix>? _fixes;
  Timer? _ticker;
  SpeedPermissionState _permission = SpeedPermissionState.notRequested;
  bool _starting = false;
  bool _disposed = false;

  /// Newest estimate, or null when no fix has been accepted since the stream
  /// last opened — the card's "waiting for a fix" state.
  SpeedEstimate? get current => _estimator.current;

  /// 🔑 **The assembly point for design 0073's trend extrapolation.**
  ///
  /// The drawn speed is `level + k·slope·Δ`, and the three inputs live in three
  /// different places: `level` and `Δ` in [SpeedEstimator], `slope` in
  /// [AccelEstimator]. This class is where they meet, and it is the ONLY place
  /// they can meet: `accel_estimator.dart` imports `speed_estimator.dart` for
  /// [SpeedEstimate], so the estimator cannot reach forward for the slope
  /// without a cycle (0073 §2.5 #1 / §3.10). Both estimators are already owned
  /// here, so the assembly costs one getter and no new wiring.
  ///
  /// 🔴 **`_accel.displaySlopeMps2`, NOT [currentAccel].** The latter is
  /// `_publishedAccel`, which passes through the 500 ms display throttle that
  /// exists to stop the acceleration ROW flickering. Feeding a throttled slope
  /// into the speed reading would freeze the extrapolation for half a second at
  /// a time the moment `speedSamplingPeriod` is lowered — a coupling nobody
  /// would look for, between two readouts that only share a source.
  double? _trendSlopeMps2() {
    // C3③ — belt and braces. `AccelEstimator.onSpeedEstimate` already suppresses
    // on any non-live estimate, so this can only ever agree with it; 0073 §3.4
    // asks for the check anyway rather than letting a display guarantee rest on
    // another module's internal invariant.
    if (_estimator.current?.state != SpeedState.live) return null;
    // C3① — null while the least squares window is warming or suppressed.
    return _accel.displaySlopeMps2;
  }

  /// The speed to DRAW right now — [SpeedEstimator.displaySpeedMpsAt] read on
  /// this controller's clock (design 0073 §3.10).
  ///
  /// The card asks for it once per frame. It deliberately does not take a
  /// `DateTime`: a widget reaching for `DateTime.now()` would put a SECOND
  /// clock in the speed feature, and the one thing every timing bug in this
  /// module has had in common (M2, the throttle above) is two time bases in one
  /// series. Tests drive the injected clock instead.
  ///
  /// Null while this controller's estimator has no series — which is also how
  /// a test double that overrides [current] without owning an estimator gets
  /// the right answer: the card falls back to the estimate it was given rather
  /// than to a 0 the empty estimator would otherwise have handed it.
  ///
  /// 🔴 Read-only. It publishes nothing and notifies nobody, so calling it 60
  /// times a second costs the recorded series exactly nothing (0073 G4).
  double? displaySpeedMpsNow() =>
      _estimator.displaySpeedMpsAt(_now(), slopeMps2: _trendSlopeMps2());

  /// Whether the reading is still moving between samples — the card's ticker
  /// asks this to decide whether the next frame has anything to draw
  /// (design 0073 §3.10, sustaining 0071 §3.7).
  bool displayTrendActiveNow() =>
      _estimator.displayTrendActiveAt(_now(), slopeMps2: _trendSlopeMps2());

  /// The same value at an arbitrary instant. Exposed for tests and for the road
  /// test's diagnosis; production reads [displaySpeedMpsNow].
  ///
  /// ⚠️ The SLOPE is still read as of now — there is no way to ask the least
  /// squares window what it thought at some other instant, and pretending
  /// otherwise would make this method quietly disagree with the one the card
  /// uses. It is [at] that moves, i.e. the horizon Δ.
  @visibleForTesting
  double? displaySpeedMpsAt(DateTime at) =>
      _estimator.displaySpeedMpsAt(at, slopeMps2: _trendSlopeMps2());

  /// The slope the reading is currently being extrapolated along, or null when
  /// it is not being extrapolated at all. Exposed for tests and for the road
  /// test's diagnosis (0073 §7 Q8 makes measuring this a release gate).
  @visibleForTesting
  double? get trendSlopeMps2 => _trendSlopeMps2();

  SpeedPermissionState get permission => _permission;

  /// True while the GNSS stream is actually open. Distinct from "the gate is
  /// open": a denied permission holds the stream shut with the gate open.
  bool get streaming => _fixes != null;

  /// Timestamped smoothed samples, forwarded straight from the estimator.
  /// Design 0044's acceleration estimator hangs here.
  Stream<SpeedEstimate> get estimates => _estimator.estimates;

  /// State-change edges. See [SpeedStateTransition].
  Stream<SpeedStateTransition> get transitions => _estimator.transitions;

  /// Raw acceleration slopes, unthrottled and unrounded (design 0044).
  ///
  /// This is the RECORDED series: `TelemetryController` folds it into the
  /// minute bucket. Deliberately not the same value as [currentAccel] — the
  /// display's deadband and quantisation are decisions about a rider glancing
  /// at a phone, and baking them into history would leave the analyst unable to
  /// tell a measured 0 from a rounded one.
  Stream<AccelEstimate> get accelEstimates => _accel.estimates;

  /// The acceleration to SHOW, or null whenever there is none to show.
  ///
  /// Null covers both of design 0044's silent states: warming (the window is
  /// still filling) and suppressed (the speed underneath is frozen). The card
  /// renders nothing at all in either — it never shows `0.0`, because a rider
  /// cannot tell that zero from a measured one (§3.3).
  ///
  /// Updates are throttled to [AccelEstimatorConfig.displayThrottle].
  /// DISAPPEARANCE is not: the moment the value stops being a measurement the
  /// row goes, throttle or no throttle. Making silence wait would be the one
  /// direction in which a stale number could survive on screen.
  AccelEstimate? get currentAccel => _publishedAccel;

  /// Whether an acceleration reading exists, is warming up, or is suppressed.
  /// Exposed for tests and for the road test's diagnosis, not for the card —
  /// the card asks [currentAccel] and renders nothing when it is null.
  @visibleForTesting
  AccelState get accelState => _accel.state;

  /// Gate condition 1 — evaluated after `effectiveWatchface`, so a face the
  /// user picked but cannot currently get does not open the stream.
  void setFaceWantsSpeed(bool v) {
    if (_faceWantsSpeed == v) return;
    _faceWantsSpeed = v;
    _onGateChanged();
  }

  /// Gate condition 2 — forwarded from the app's lifecycle observer.
  void setAppResumed(bool v) {
    if (_appResumed == v) return;
    _appResumed = v;
    _onGateChanged();
  }

  /// Gate condition 3, TAB half — the speed-carrying tab being the visible one.
  ///
  /// Since design 0046 that is the HOME tab: the dashboard moved into a pushed
  /// route, which reports itself through [setDetailVisible] instead.
  void setDashboardVisible(bool v) {
    if (_dashboardVisible == v) return;
    _dashboardVisible = v;
    _onGateChanged();
  }

  /// Gate condition 3, PUSHED-ROUTE half — a device detail page is on screen.
  ///
  /// Separate from [setDashboardVisible] because the two are produced by
  /// different owners: the shell knows its tab, and only the pushed route knows
  /// it was pushed. ORing them is what lets the detail page's own speed card
  /// stream while the tab underneath it is 裝置.
  ///
  /// ⚠️ Known and accepted over-approximation: with a speed tile on the home
  /// grid AND a detail page open that has no speed card, condition 1 is still
  /// true (the home tile stays mounted in the IndexedStack) and this makes
  /// condition 3 true, so GNSS runs with nobody looking at a speed. Being exact
  /// would need per-surface accounting of condition 1, i.e. a redesign of the
  /// gate; the window here is bounded by "a detail page is open" and was judged
  /// not to be worth it. Design 0046 交付二 revisits the gate anyway.
  void setDetailVisible(bool v) {
    if (_detailVisible == v) return;
    _detailVisible = v;
    _onGateChanged();
  }

  /// Prompt for location permission.
  ///
  /// Called only from the consent flow (0042 §3.5): the user has already read
  /// what the feature does and pressed "enable", so the OS dialog lands inside
  /// a context they asked for rather than out of nowhere.
  Future<void> requestPermission() async {
    final next = await source.request();
    if (_disposed) return;
    if (next != _permission) {
      _permission = next;
      notifyListeners();
    }
    await _evaluate();
  }

  /// Open the OS settings page — the only way back from
  /// [SpeedPermissionState.permanentlyDenied], since the system dialog will not
  /// be shown again.
  Future<void> openSystemSettings() => source.openSystemSettings();

  @override
  void dispose() {
    _disposed = true;
    _stop();
    _speedToAccel?.cancel();
    _transitionsToAccel?.cancel();
    _estimator.dispose().ignore();
    _accel.dispose().ignore();
    super.dispose();
  }

  // ---- design 0044 wiring -------------------------------------------------

  void _feedAccelEstimate(SpeedEstimate e) {
    _accel.onSpeedEstimate(e);
    _republishAccel();
  }

  void _feedAccelTransition(SpeedStateTransition t) {
    _accel.onTransition(t);
    _republishAccel();
  }

  /// Move [AccelEstimator.current] to [currentAccel], subject to the display
  /// throttle — and drop it immediately when there is nothing to show.
  void _republishAccel() {
    final next = _accel.current;
    if (next == null) {
      if (_publishedAccel == null) return;
      _publishedAccel = null;
      _publishedAccelAt = null;
      if (!_disposed) notifyListeners();
      return;
    }
    if (identical(next, _publishedAccel)) return;
    final at = _now();
    final last = _publishedAccelAt;
    if (last != null && at.difference(last) < accelConfig.displayThrottle) {
      return;
    }
    _publishedAccel = next;
    _publishedAccelAt = at;
    if (!_disposed) notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  bool get _wantsStream =>
      _faceWantsSpeed && _appResumed && (_dashboardVisible || _detailVisible);

  /// Closing is synchronous and unconditional; opening is not (it may have to
  /// await a permission read first). Splitting them this way is what guarantees
  /// G4's "any one condition failing cancels it immediately" — a cancel must
  /// never sit behind an await.
  void _onGateChanged() {
    if (!_wantsStream) {
      _stop();
      return;
    }
    unawaited(_evaluate());
  }

  Future<void> _evaluate() async {
    if (_disposed || !_wantsStream || _fixes != null || _starting) return;
    _starting = true;
    try {
      if (_permission != SpeedPermissionState.granted) {
        final next = await source.status();
        if (_disposed) return;
        if (next != _permission) {
          _permission = next;
          notifyListeners();
        }
      }
      // The gate may have closed while we were awaiting.
      if (_disposed ||
          !_wantsStream ||
          _fixes != null ||
          _permission != SpeedPermissionState.granted) {
        return;
      }
      _fixes = source.fixes().listen(_onFix, onError: _onSourceError);
      _ticker = Timer.periodic(tickInterval, _onTick);
      notifyListeners();
    } finally {
      _starting = false;
    }
  }

  void _stop() {
    final had = _fixes != null;
    _fixes?.cancel();
    _fixes = null;
    _ticker?.cancel();
    _ticker = null;
    // Forget the reading as well as the stream. Coming back to the dashboard
    // after a break must show "waiting for a fix", not the speed you were doing
    // when you left — a frozen number with nothing marking it as frozen is the
    // exact failure G2 exists to prevent.
    _estimator.reset();
    if (had && !_disposed) notifyListeners();
  }

  void _onFix(SpeedFix fix) {
    _estimator.addFix(fix);
    notifyListeners();
  }

  /// The heartbeat that makes a tunnel detectable. Without it the estimator
  /// would sit in [SpeedState.live] forever, because the event it is waiting
  /// for is the absence of events.
  void _onTick(Timer _) {
    _estimator.tick();
    // Unconditional: `lost` renders "measured N seconds ago", so the card has
    // something new to say every second even when nothing changed.
    notifyListeners();
  }

  /// The stream failing is nearly always the OS refusing us — location services
  /// switched off system-wide, or the grant revoked from under a running app.
  ///
  /// Shut down and re-read the permission rather than retry: a retry loop
  /// against a disabled location service is a battery drain with no display to
  /// show for it. The stream comes back the next time the gate reopens (leaving
  /// and returning to the dashboard), which is also when the user is in a
  /// position to notice it did.
  void _onSourceError(Object error, StackTrace stack) {
    _stop();
    unawaited(_refreshPermission());
  }

  Future<void> _refreshPermission() async {
    final next = await source.status();
    if (_disposed || next == _permission) return;
    _permission = next;
    notifyListeners();
  }
}
