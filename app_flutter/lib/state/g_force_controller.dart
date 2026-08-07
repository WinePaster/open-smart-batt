/// OpenSmartBatt — G meter controller (design 0045 Phase 1).
///
/// Everything platform-shaped about the G meter is here: the `sensors_plus`
/// streams and the lifecycle gate that decides when they may exist.
/// [GForceEstimator] next door stays pure Dart and does the arithmetic.
///
/// ## Data flows ONE way through this class
///
/// The switch and the stored matrix arrive via [applySettings] and leave via
/// nothing: when the wizard completes, the SETTINGS SCREEN writes the matrix
/// through `SettingsController`, and it comes back here on the next
/// [applySettings]. This class holds no persistence callback at all.
///
/// 🔑 That is deliberate, and the reason is in `app_settings.dart`'s own
/// warning: `SettingsRepo.saveSettings` uses `INSERT OR REPLACE`, so any column
/// written outside `AppSettings.toMap()` is erased the next time any other
/// setting changes. A controller with its own private write path to
/// `g_calibration` is exactly the shape that bug takes. With one writer there
/// is nothing to keep in step.
///
/// If the composition root forgets to call [applySettings], the failure is
/// [available] staying false — the card never appears and the settings page
/// says "not calibrated". Wrong, but fail-CLOSED and visible, rather than a
/// calibration that works today and vanishes next week.
///
/// ## Which stream, when
///
/// * `userAccelerometerEvent` (linear, gravity removed by the OS — design 0045
///   §3.3 case 甲) drives the estimator AND the still detector.
/// * `accelerometerEvent` (raw, gravity included) is read in exactly two
///   places: the wizard's gravity window, and the still-window validity check
///   that notices the mount has been moved (impl plan Phase 1). It is never the
///   source of a displayed number.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../models/models.dart';
import 'g_force_config.dart';
import 'g_force_estimator.dart';

/// The platform seam, for the same reason [SpeedLocationSource] has one: the
/// part worth testing is WHEN we talk to the sensors, and that must be testable
/// without an accelerometer.
abstract class GForceSensorSource {
  /// Proper acceleration, gravity included.
  Stream<Vec3> raw({required Duration samplingPeriod});

  /// OS-fused linear acceleration, gravity removed.
  Stream<Vec3> linear({required Duration samplingPeriod});
}

/// The one production implementation.
class SensorsPlusGForceSource implements GForceSensorSource {
  const SensorsPlusGForceSource();

  @override
  Stream<Vec3> raw({required Duration samplingPeriod}) =>
      accelerometerEventStream(samplingPeriod: samplingPeriod)
          .map((e) => Vec3(e.x, e.y, e.z));

  @override
  Stream<Vec3> linear({required Duration samplingPeriod}) =>
      userAccelerometerEventStream(samplingPeriod: samplingPeriod)
          .map((e) => Vec3(e.x, e.y, e.z));
}

/// One estimator-layer G sample on its way to the history table.
///
/// m/s², signed, WITHOUT the display deadband or quantisation — design 0045
/// §3.7, the same rule design 0044 applies to `accel`: what the analyst reads is
/// what the estimator produced, so the recorded series and the rendered one
/// have a single source.
@immutable
class GForceEstimate {
  const GForceEstimate({
    required this.longMs2,
    required this.latMs2,
    required this.at,
  });

  final double longMs2;
  final double latMs2;
  final DateTime at;
}

/// Owns the sensor streams' lifetime and the calibration state machine.
///
/// The gate (design 0045 §3.5, deliberately the same shape as design 0042
/// §3.4) is three conditions that must ALL hold before the ride streams exist:
///
/// 1. a G card is mounted ([setFaceWantsGForce], driven by `GForceCard`'s own
///    lifecycle);
/// 2. the app is in the foreground ([setAppResumed]);
/// 3. a surface that can carry the card is on screen ([setDashboardVisible] /
///    [setDetailVisible]).
///
/// There is deliberately NO `gMeterEnabled` condition, for design 0042's
/// reason applied here: with the switch off — or with no valid calibration —
/// `renderedModules` drops `gForce` from the face, so no card is built, so
/// condition 1 never opens. One decision point, not two.
///
/// The wizard is the exception and has its own subscription: it must run from
/// the SETTINGS page, where none of the three conditions hold.
class GForceController extends ChangeNotifier {
  GForceController({
    this.source = const SensorsPlusGForceSource(),
    this.config = const GForceConfig(),
    DateTime Function()? now,
    this.onCalibrationInvalidated,
  }) : _now = now ?? DateTime.now;

  /// Called once when the mount is detected to have moved, so the caller can
  /// make that durable.
  ///
  /// 🔴 A CALLBACK rather than a settings write, and the indirection is the
  /// point. This class deliberately imports no repository and no database —
  /// that is what makes the `INSERT OR REPLACE` column-wipe trap (see
  /// `settings_repo.dart`) unreachable here rather than merely avoided. Giving
  /// it a write path to close one hole would open a worse one.
  ///
  /// Why it has to be durable at all: the invalidation used to live only in
  /// memory, while this file's own header said "Once tripped it stays tripped
  /// … There is no path back". Across a restart it was not tripped at all — the
  /// old matrix read back, `available` returned true, and the card drew G
  /// values on axes the phone no longer had. Move the mount, restart, ride off
  /// without ever standing still for the two seconds the still-window check
  /// needs, and the whole session is wrong AND lands in `g_long`/`g_lat`. That
  /// is the "confident, plausible, wrong" failure this feature is most exposed
  /// to, so it does not get to be memory-only.
  final Future<void> Function(String encoded)? onCalibrationInvalidated;

  final GForceSensorSource source;
  final GForceConfig config;
  final DateTime Function() _now;

  // --- settings-derived state (one-way, see the library comment) ------------
  bool _enabled = false;
  String? _storedCalibration;
  GForceCalibration? _calibration;
  bool _invalidated = false;

  /// The master switch.
  bool get enabled => _enabled;

  /// A usable matrix exists and has not been invalidated since it was stored.
  bool get calibrated => _calibration != null && !_invalidated;

  /// 🔑 The predicate design 0045 Q8 calls "可用", and the ONLY thing the UI
  /// should ask. Both the watchface layer (`renderedModules`) and the settings
  /// page read it, so "the card is not shown" and "riding is not offered" can
  /// never disagree.
  bool get available => _enabled && calibrated;

  /// True when a stored calibration was rejected by the still-window check —
  /// i.e. the mount moved. Distinct from "never calibrated" because the
  /// settings page says different things about them.
  bool get calibrationInvalidated => _invalidated;

  /// When the stored calibration was made, for the settings row.
  DateTime? get calibratedAt => _calibration?.calibratedAt;

  /// Feed the persisted settings in. Called once at startup and on every
  /// settings change; see the library comment for why this is the only input.
  void applySettings(AppSettings s) {
    var changed = false;
    if (_enabled != s.gMeterEnabled) {
      _enabled = s.gMeterEnabled;
      changed = true;
    }
    if (_storedCalibration != s.gCalibration) {
      _storedCalibration = s.gCalibration;
      _calibration = GForceCalibration.decode(s.gCalibration);
      // A NEW matrix is trusted again — recalibrating is the documented way out
      // of the invalidated state. But a matrix that comes back CARRYING the
      // flag stays invalidated: that is what makes "the mount moved" survive a
      // restart instead of being forgotten the moment the process dies.
      _invalidated = _calibration?.invalidated ?? false;
      _estimator = null;
      _monitor = null;
      _reading = null;
      changed = true;
    }
    if (!changed) return;
    // The gate's condition 1 is driven by the card, and the card disappears
    // when availability goes; closing here as well means the stream cannot
    // outlive availability even for the frame it takes the card to unmount.
    //
    // ⚠️ A stream that is already open must also be REBUILT, not merely left
    // alone: the block above dropped the estimator the new matrix invalidated,
    // and an open subscription with no estimator behind it would go quietly
    // dead — no error, no reading, a card drawing zeros. Restarting through the
    // gate is the same path the card's own mount takes.
    _stopRide();
    if (available) _onGateChanged();
    _notify();
  }

  // --- the gate ------------------------------------------------------------
  bool _faceWantsGForce = false;
  bool _appResumed = true;
  bool _dashboardVisible = false;
  bool _detailVisible = false;

  /// Condition 3's tab half, observable so a test can drive the real shell
  /// rather than this class — the 0042 lesson about defects living in the
  /// CALLER, applied before it can happen again here.
  @visibleForTesting
  bool get dashboardVisible => _dashboardVisible;

  @visibleForTesting
  bool get detailVisible => _detailVisible;

  /// Whether the ride streams are open right now.
  @visibleForTesting
  bool get streaming => _rideLinear != null;

  void setFaceWantsGForce(bool v) {
    if (_faceWantsGForce == v) return;
    _faceWantsGForce = v;
    _onGateChanged();
  }

  void setAppResumed(bool v) {
    if (_appResumed == v) return;
    _appResumed = v;
    _onGateChanged();
  }

  void setDashboardVisible(bool v) {
    if (_dashboardVisible == v) return;
    _dashboardVisible = v;
    _onGateChanged();
  }

  void setDetailVisible(bool v) {
    if (_detailVisible == v) return;
    _detailVisible = v;
    _onGateChanged();
  }

  bool get _wantsRide =>
      _faceWantsGForce && _appResumed && (_dashboardVisible || _detailVisible);

  // --- ride streams --------------------------------------------------------
  StreamSubscription<Vec3>? _rideLinear;
  StreamSubscription<Vec3>? _rideRaw;
  GForceEstimator? _estimator;
  CalibrationValidityMonitor? _monitor;

  GForceReading? _reading;
  DateTime? _readingPublishedAt;

  final StreamController<GForceEstimate> _estimates =
      StreamController<GForceEstimate>.broadcast();

  /// Estimator-layer samples for the history table (design 0045 §3.7).
  ///
  /// Named `estimates` to match `SpeedEstimator.estimates` and
  /// `GpsSpeedController.accelEstimates`, and that is not only tidiness:
  /// `estimate_wiring_test.dart` derives its checklist from
  /// `bind\w*Estimates` on `TelemetryController`, so a stream named to the
  /// house pattern is covered by that guard automatically. A third estimate
  /// stream produced and never bound is exactly the defect that test was
  /// written for, one release ago.
  Stream<GForceEstimate> get estimates => _estimates.stream;

  /// What the card draws, or null when there is nothing to draw.
  GForceReading? get reading => _reading;

  void resetPeak() {
    _estimator?.resetPeak();
    // Immediately, not on the next throttled tick: the user tapped it, and a
    // number that takes a fifth of a second to obey a tap reads as ignored.
    final e = _estimator;
    if (e != null && _reading != null) {
      _reading = GForceReading(
        longG: _reading!.longG,
        latG: _reading!.latG,
        peakLongG: 0,
        peakLatG: 0,
        peakG: 0,
      );
    }
    _notify();
  }

  void _onGateChanged() {
    if (!_wantsRide) {
      _stopRide();
      return;
    }
    _startRide();
  }

  void _startRide() {
    if (_disposed || _rideLinear != null) return;
    final cal = _calibration;
    if (cal == null) return;
    _estimator = GForceEstimator(cal, config: config);
    _monitor = CalibrationValidityMonitor(cal, config: config);
    _rideLinear = source
        .linear(samplingPeriod: config.samplingPeriod)
        .listen(_onLinearSample);
    // Raw is subscribed here ONLY so the still-window check can notice a mount
    // that has been moved. Nothing it carries is ever displayed.
    _rideRaw =
        source.raw(samplingPeriod: config.samplingPeriod).listen(_onRawSample);
  }

  void _stopRide() {
    final was = _rideLinear != null;
    _rideLinear?.cancel();
    _rideRaw?.cancel();
    _rideLinear = null;
    _rideRaw = null;
    _estimator = null;
    _monitor = null;
    if (!was) return;
    // design 0045 Q5: peaks do not survive the stream. A peak is "the hardest
    // you braked THIS ride"; carrying one across a gap in the recording would
    // make it something else.
    _reading = null;
    _readingPublishedAt = null;
    _notify();
  }

  void _onLinearSample(Vec3 v) {
    final e = _estimator;
    if (e == null) return;
    final t = _now();
    _monitor?.addLinearSample(v, t);
    final r = e.process(v);

    // 🔴 The RECORDED series is published FIRST and UNCONDITIONALLY.
    //
    // This used to sit below the throttle, so the history series was thinned by
    // a decision about repaint rates — measured at 50 samples in, 5 landed.
    // Design 0044 ruled the same question the other way for acceleration and
    // pinned it ("the recorded series must not be thinned by a decision about
    // repaint rates"); 0045 was written without inheriting that. The visible
    // cost of getting it wrong is subtle and permanent: the Phase 4 road test
    // will tune `readoutThrottle`, and tuning a DISPLAY knob would silently
    // change what lands in the database.
    //
    // Same split as design 0044: `estimates` is the raw, unthrottled,
    // unrounded series; `reading` is what a rider glances at.
    if (!_estimates.isClosed) {
      _estimates.add(GForceEstimate(
          longMs2: e.rawLongMs2, latMs2: e.rawLatMs2, at: t));
    }

    final last = _readingPublishedAt;
    if (last != null && t.difference(last) < config.readoutThrottle) return;
    _readingPublishedAt = t;
    _reading = r;
    _notify();
  }

  void _onRawSample(Vec3 v) {
    final m = _monitor;
    if (m == null) return;
    m.addRawSample(v, _now());
    if (!m.invalidated || _invalidated) return;
    // The mount moved. Stop drawing immediately — a G reading on stale axes is
    // the one thing design 0045 G1/G2 will not allow, and it is worse than no
    // reading because it looks like one.
    _invalidated = true;
    _stopRide();
    // Fire-and-forget: the screen must stop drawing NOW, and a slow write must
    // not hold that up. Failing to persist leaves the pre-fix behaviour (a
    // stale matrix returning after a restart), which is bad but no worse than
    // before; failing to stop drawing is the thing G1/G2 forbid outright.
    //
    // The matrix goes WITH the flag, not away: the settings page has two
    // different sentences for "never calibrated" and "the mount moved", and
    // the second one needs the date the first calibration was taken.
    final marked = _calibration?.markedInvalid;
    if (marked != null) {
      unawaited(onCalibrationInvalidated?.call(marked.encode()) ??
          Future<void>.value());
    }
    _notify();
  }

  // --- the wizard ----------------------------------------------------------
  CalibrationSession? _session;
  StreamSubscription<Vec3>? _wizardLinear;
  StreamSubscription<Vec3>? _wizardRaw;

  /// The live wizard, or null when none is running.
  CalibrationSession? get calibrationSession => _session;

  /// Start (or restart) the two-step wizard and open the sensor streams it
  /// needs. The result is committed by the CALLER through `SettingsController`
  /// — see the library comment.
  CalibrationSession startCalibration() {
    final s = _session ?? CalibrationSession(config: config);
    s.start();
    // A restart must not preview the PREVIOUS attempt's matrix.
    _preview = null;
    _previewReading = null;
    _session = s;
    _wizardLinear ??= source
        .linear(samplingPeriod: config.samplingPeriod)
        .listen(_onWizardLinear);
    _wizardRaw ??=
        source.raw(samplingPeriod: config.samplingPeriod).listen(_onWizardRaw);
    _notify();
    return s;
  }

  void cancelCalibration() {
    _wizardLinear?.cancel();
    _wizardRaw?.cancel();
    _wizardLinear = null;
    _wizardRaw = null;
    _session = null;
    _preview = null;
    _previewReading = null;
    _notify();
  }

  GForceEstimator? _preview;
  GForceReading? _previewReading;

  /// A live reading from the calibration the wizard has JUST produced, before
  /// it is saved.
  ///
  /// 🔑 This is the mitigation the whole "define forward from the launch" step
  /// rests on. Design 0045 §3.2 is candid that a launch taken while turning
  /// skews the forward axis, and no amount of arithmetic can detect that from
  /// inside. What CAN detect it is the rider: accelerate in a straight line and
  /// watch whether the dot goes straight up. So the wizard's last page shows a
  /// ball driven by this, and "calibrate again" is one tap away.
  ///
  /// Null until a session completes; it uses the wizard's own subscription, so
  /// no extra stream is opened for it.
  GForceReading? get previewReading => _previewReading;

  void _onWizardLinear(Vec3 v) {
    final s = _session;
    if (s == null) return;
    final before = s.phase;
    s.addLinearSample(v, _now());
    if (s.phase != before) _notify();
    final result = s.result;
    if (result == null) return;
    _preview ??= GForceEstimator(result, config: config);
    _previewReading = _preview!.process(v);
    _notify();
  }

  void _onWizardRaw(Vec3 v) {
    final s = _session;
    if (s == null) return;
    final before = s.phase;
    s.addRawSample(v, _now());
    if (s.phase != before) _notify();
  }

  // --- teardown ------------------------------------------------------------
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _rideLinear?.cancel();
    _rideRaw?.cancel();
    _wizardLinear?.cancel();
    _wizardRaw?.cancel();
    _estimates.close();
    super.dispose();
  }
}
