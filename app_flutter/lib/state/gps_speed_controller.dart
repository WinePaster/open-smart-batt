/// OpenSmartBatt — GPS speed controller (design 0042 Phase B).
///
/// Everything platform-shaped about the speed feature lives here: the location
/// plugin, the runtime permission, and the lifecycle gate that decides when a
/// GNSS stream is allowed to exist at all. [SpeedEstimator] next door stays
/// pure Dart and does the arithmetic.
///
/// 🔴 PRIVACY RED LINE (design 0042 G5). The platform hands us a position
/// object that DOES carry a coordinate. [GeolocatorSpeedSource._toFix] is the
/// single line where that object is read, and it copies four scalars out of it —
/// none of them a coordinate. Downstream of that line no latitude or longitude
/// exists, so none can be logged, stored or exported. `speed_privacy_test.dart`
/// scans this file for coordinate identifiers.
///
/// **Why there is no `speedDetection` gate here.** The master switch (design
/// 0042 §3.9, arriving in Phase D) does not need a fourth condition: with the
/// switch off `riding` falls back to `standard` at the render layer (§3.9
/// revision of 2026-08-07), the effective face therefore has no `speed` module,
/// and [setFaceWantsSpeed] is false. The switch gates the stream through
/// condition 1 rather than beside it — which is also what makes "off ⇒ speed
/// never lands" true by construction instead of by a second check somebody
/// could forget.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

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
  @override
  Stream<SpeedFix> fixes() => Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
        ),
      ).map(_toFix);

  /// 🔴 G5's enforcement point. Four scalars are copied out; everything else
  /// the platform offers is left behind with the object it came on.
  static SpeedFix _toFix(Position p) => SpeedFix(
        speedMps: p.speed,
        // Non-nullable on the platform side, so "not reported" arrives as 0 or
        // -1 (0042 §2.3 #3, still unverified in the field on old Android).
        // Both are mapped to null, which is what makes the card omit the ±
        // line rather than print a meaningless "±0.0".
        speedAccuracyMps: p.speedAccuracy > 0 ? p.speedAccuracy : null,
        horizontalAccuracyM: p.accuracy,
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
/// The gate (0042 §3.4) is three booleans that must ALL hold for a stream to
/// exist; any one going false cancels it immediately:
///
/// 1. the effective watchface renders the `speed` module ([setFaceWantsSpeed]);
/// 2. the app is in the foreground ([setAppResumed]);
/// 3. the dashboard is the visible tab ([setDashboardVisible]).
///
/// Continuous GNSS costs an order of magnitude more battery than the BLE link
/// this app already holds open (0042 G4), and unlike the BLE link it buys
/// nothing while nobody is looking at the number — design 0039's background
/// connection deliberately does not extend to location.
class GpsSpeedController extends ChangeNotifier {
  GpsSpeedController({
    this.source = const GeolocatorSpeedSource(),
    SpeedEstimatorConfig config = const SpeedEstimatorConfig(),
    DateTime Function() now = DateTime.now,
    this.tickInterval = const Duration(seconds: 1),
  }) : _estimator = SpeedEstimator(config: config, now: now);

  /// The platform seam. Swapped for a fake in tests; there is exactly one
  /// production implementation.
  final SpeedLocationSource source;

  /// How often [SpeedEstimator.tick] runs while the stream is open.
  final Duration tickInterval;

  final SpeedEstimator _estimator;

  bool _faceWantsSpeed = false;
  // The app is in the foreground when it starts; lifecycle callbacks only fire
  // on a CHANGE, so starting this false would need a resume that never comes.
  bool _appResumed = true;
  bool _dashboardVisible = false;

  StreamSubscription<SpeedFix>? _fixes;
  Timer? _ticker;
  SpeedPermissionState _permission = SpeedPermissionState.notRequested;
  bool _starting = false;
  bool _disposed = false;

  /// Newest estimate, or null when no fix has been accepted since the stream
  /// last opened — the card's "waiting for a fix" state.
  SpeedEstimate? get current => _estimator.current;

  SpeedPermissionState get permission => _permission;

  /// True while the GNSS stream is actually open. Distinct from "the gate is
  /// open": a denied permission holds the stream shut with the gate open.
  bool get streaming => _fixes != null;

  /// Timestamped smoothed samples, forwarded straight from the estimator.
  /// Design 0044's acceleration estimator hangs here.
  Stream<SpeedEstimate> get estimates => _estimator.estimates;

  /// State-change edges. See [SpeedStateTransition].
  Stream<SpeedStateTransition> get transitions => _estimator.transitions;

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

  /// Gate condition 3 — the dashboard tab being the visible one.
  void setDashboardVisible(bool v) {
    if (_dashboardVisible == v) return;
    _dashboardVisible = v;
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
    _estimator.dispose().ignore();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  bool get _wantsStream => _faceWantsSpeed && _appResumed && _dashboardVisible;

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
