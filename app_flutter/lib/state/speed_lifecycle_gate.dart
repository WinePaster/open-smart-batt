/// OpenSmartBatt — mapping app lifecycle onto the GNSS gate (design 0042 §3.4).
///
/// ## Why this is not one line
///
/// The obvious implementation is `setAppResumed(state == resumed)`, and it was
/// that, and it is wrong in a way nothing reports. `AppLifecycleState.inactive`
/// is not "the user left". It fires when a notification banner appears, when
/// the notification centre or control centre is dragged down, when the app
/// switcher is opened, when a call comes in — and, the one that matters most
/// here, **while a system permission dialog is on screen**, which is precisely
/// the moment design 0042's consent flow puts one there.
///
/// Treating each of those as "left the foreground" runs the whole teardown:
/// cancel the platform stream, `SpeedEstimator.reset()`, then on the way back a
/// permission read across a platform channel and a fresh
/// `getPositionStream()`, then a GNSS warm start before the first fix. Three
/// visible consequences, none of them errors:
///
///  1. **The card empties.** `reset()` drops `current`, so the reading returns
///     to "waiting for a fix" and stays there for seconds. Glancing at a
///     notification would blank the speedometer.
///  2. **Battery is probably WORSE, not better.** Stop/start denies the
///     receiver its low-power tracking state. (🔍 Reasoned, not measured —
///     Phase F should check it.)
///  3. **`reset()` emits a `→ lost` transition** (`speed_estimator.dart`), and
///     design 0044 hangs its window-clearing on that edge. A banner would
///     therefore also throw away the acceleration window.
///
/// ## What this does instead
///
/// `resumed` opens immediately. `paused` / `hidden` / `detached` — the states
/// that genuinely mean the app is no longer on screen — close immediately, with
/// no grace at all: G4's "any condition failing cancels it" has to stay literal
/// for the case that actually costs battery.
///
/// Only `inactive` is debounced, by [defaultGrace]. If `resumed` arrives first
/// the timer is cancelled and nothing happened; if it does not, the app was
/// really going away and the stream closes a few seconds later than it would
/// have. Same shape as `kClassPendingGrace` (design 0039 / `routing_decision
/// .dart`), and chosen for the same reason: a flicker on a transient state is
/// the more annoying of the two failure modes.
///
/// 🔴 The debounce lives HERE and not in [GpsSpeedController] deliberately.
/// That controller's contract is that a gate condition going false cancels the
/// stream in the SAME synchronous turn — pinned by its own tests, and the thing
/// that makes "no stream while the dashboard is not on screen" checkable. A
/// grace period inside it would weaken that guarantee for all three conditions
/// to fix a problem that only one lifecycle state has. So the controller keeps
/// its sharp edge and this adapter decides what counts as leaving.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;

/// Translates [AppLifecycleState] into the GNSS gate's "app is in the
/// foreground" condition, absorbing transient [AppLifecycleState.inactive].
class SpeedLifecycleGate {
  SpeedLifecycleGate({
    required this.setAppResumed,
    this.grace = defaultGrace,
  });

  /// How long an `inactive` is allowed to last before it is believed.
  ///
  /// Long enough to cover a banner, a control-centre peek or a permission
  /// dialog being read; short enough that a real departure the OS never
  /// followed up on costs only a few seconds of GNSS. Not tuned against
  /// measurements — Phase F is where it meets a real phone.
  static const Duration defaultGrace = Duration(seconds: 5);

  /// The gate condition to drive — [GpsSpeedController.setAppResumed].
  final void Function(bool) setAppResumed;

  final Duration grace;

  Timer? _pending;

  /// True while an `inactive` is being waited out. Test-visible so the debounce
  /// can be observed rather than inferred from timing.
  bool get gracePending => _pending != null;

  void onLifecycle(AppLifecycleState state) {
    _pending?.cancel();
    _pending = null;
    switch (state) {
      case AppLifecycleState.resumed:
        setAppResumed(true);
      case AppLifecycleState.inactive:
        // Might be a banner, might be the user leaving. Ask again shortly.
        _pending = Timer(grace, () {
          _pending = null;
          setAppResumed(false);
        });
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // No grace: these mean the app is off screen, which is the case G4
        // exists for.
        setAppResumed(false);
    }
  }

  void dispose() {
    _pending?.cancel();
    _pending = null;
  }
}
