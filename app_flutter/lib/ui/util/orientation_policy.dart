/// OpenSmartBatt — the ONE place that decides which screen orientations the
/// app allows (design 0105 P1, owner ruling 2026-11-13 Q2 = B, Q3 = A).
///
/// Before design 0105 three call sites each spoke to
/// `SystemChrome.setPreferredOrientations` on their own: `bootstrap()` locked
/// portrait, and the two full-screen chart pages locked landscape on entry and
/// then HARD-CODED portrait on exit. Any rule of the form "landscape is allowed
/// in some cases" breaks the moment one of those three disagrees — on a head
/// unit, leaving a chart would have asked for portrait (0105 §4.1, the mirror
/// image of design 0081 R1). So all three now ask this class, and nothing else
/// in `lib/` calls `setPreferredOrientations`.
///
/// ## The rule
///
/// Landscape (in fact all four orientations) is allowed when EITHER
///
///   * the window's shortest side is at least [autoLandscapeShortestSide] dp —
///     the same line Android 16 draws when it starts ignoring orientation
///     requests on large screens (0105 §2.1), so the app agrees with the OS
///     instead of fighting it; OR
///   * the user turned on 「允許橫式畫面」/ "Allow landscape" (settings
///     `allow_landscape`, schema v28, default OFF) — for small head units and
///     for people who want to turn their phone (Q2 = B).
///
/// Otherwise: portrait, exactly as every build before design 0105.
///
/// 🔑 This decides ORIENTATION only. Layout follows the window's SHAPE (see
/// `wide_layout.dart`), so a head unit whose firmware forces landscape gets
/// the designed layout even with the setting off.
///
/// ## Full-screen chart pages
///
/// They still lock landscape while open (design 0081 Q7 = A) through
/// [enterFullScreenLandscape], and on the way out [exitFullScreenLandscape]
/// restores TO THIS POLICY — never to a hard-coded portrait. While one is open,
/// [apply] only records its inputs; the page owns the orientation until it
/// leaves.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// See the library doc. Static because the platform setting it drives is
/// global too: there is exactly one preferred-orientation set per app.
abstract final class OrientationPolicy {
  /// The window's shortest side (logical px / dp) from which landscape is
  /// allowed without the user asking (Q3 = A). Android 16's own threshold.
  static const double autoLandscapeShortestSide = 600;

  /// Every build before design 0105.
  static const List<DeviceOrientation> portraitOnly = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];

  /// What a full-screen chart page asks for while it is open (design 0081).
  static const List<DeviceOrientation> landscapeOnly = [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// Landscape allowed: all four. Portrait stays in the set — a tablet held
  /// upright still gets today's portrait layout.
  static const List<DeviceOrientation> any = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeRight,
  ];

  /// The decision itself, pure so it can be tested without a platform.
  static bool landscapeAllowed({
    required double shortestSide,
    required bool userAllowsLandscape,
  }) => userAllowsLandscape || shortestSide >= autoLandscapeShortestSide;

  /// [landscapeAllowed] as the orientation set to request.
  static List<DeviceOrientation> orientationsFor({
    required double shortestSide,
    required bool userAllowsLandscape,
  }) =>
      landscapeAllowed(
        shortestSide: shortestSide,
        userAllowsLandscape: userAllowsLandscape,
      )
      ? any
      : portraitOnly;

  // ---- state -------------------------------------------------------------

  static bool _userAllowsLandscape = false;

  /// How many full-screen chart pages are holding landscape right now. A
  /// counter rather than a flag: a page can be pushed over another one, and
  /// only the LAST to leave may restore.
  static int _fullScreenHolds = 0;

  /// The set last sent to the platform, so [apply] — which runs on every
  /// window-metrics change, i.e. on every rotation — does not resend an
  /// unchanged set.
  static List<DeviceOrientation>? _lastSent;

  /// The setting as last reported to [apply].
  static bool get userAllowsLandscape => _userAllowsLandscape;

  /// The window's shortest side in logical pixels, read from the first
  /// [FlutterView]. 0 before the platform has reported any metrics — which
  /// decides "portrait", today's behaviour, until the real size arrives and
  /// `didChangeMetrics` calls [apply] again.
  static double currentShortestSide() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return 0;
    final v = views.first;
    if (v.devicePixelRatio <= 0) return 0;
    return (v.physicalSize / v.devicePixelRatio).shortestSide;
  }

  /// What the policy asks for right now, ignoring any full-screen hold.
  static List<DeviceOrientation> get current => orientationsFor(
    shortestSide: currentShortestSide(),
    userAllowsLandscape: _userAllowsLandscape,
  );

  /// Re-evaluate and apply. Called at boot, when the setting changes and when
  /// the window metrics change. [userAllowsLandscape] updates the remembered
  /// setting when given.
  ///
  /// While a full-screen chart page is open this only records the input: the
  /// page restores to the (then current) policy when it leaves.
  static Future<void> apply({bool? userAllowsLandscape}) async {
    if (userAllowsLandscape != null) {
      _userAllowsLandscape = userAllowsLandscape;
    }
    if (_fullScreenHolds > 0) return;
    await _send(current, force: false);
  }

  /// A full-screen chart page opened (design 0081 Q7 = A): lock landscape.
  static Future<void> enterFullScreenLandscape() async {
    _fullScreenHolds++;
    await _send(landscapeOnly, force: true);
  }

  /// A full-screen chart page closed: restore TO THE POLICY.
  ///
  /// Call it from `dispose`, not from the page's close button — the system
  /// back gesture never reaches that button, and an app left locked to
  /// landscape is the worst outcome a chart page can produce.
  static Future<void> exitFullScreenLandscape() async {
    if (_fullScreenHolds > 0) _fullScreenHolds--;
    if (_fullScreenHolds > 0) return;
    await _send(current, force: true);
  }

  static Future<void> _send(
    List<DeviceOrientation> next, {
    required bool force,
  }) async {
    if (!force && listEquals(next, _lastSent)) return;
    _lastSent = next;
    try {
      await SystemChrome.setPreferredOrientations(next);
    } catch (_) {
      // A host with no platform side (desktop test runs) has nobody to
      // answer; an orientation preference must never stop the app.
    }
  }

  /// Forget all state — for tests, which share one isolate per file.
  @visibleForTesting
  static void debugReset() {
    _userAllowsLandscape = false;
    _fullScreenHolds = 0;
    _lastSent = null;
  }
}
