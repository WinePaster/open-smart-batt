/// OpenSmartBatt — a repeating tick that lands ON the wall-clock boundary
/// (design 0052 §4).
///
/// ## Why this is not `Timer.periodic`
///
/// `Timer.periodic(const Duration(minutes: 1), …)` counts from the moment it is
/// created, which is a RANDOM second. Start the app at 19:50:59 and the first
/// fire is at 19:51:59 — the card reads `19:50` for fifty-nine seconds after
/// the minute it names has ended, and it stays exactly that wrong forever,
/// because every later fire inherits the same offset. It is not jitter that
/// averages out; it is a constant lag of up to one whole period, and for a
/// clock the period IS the resolution.
///
/// A clock therefore has to schedule to the boundary rather than by the
/// interval: compute how long until the next whole minute, arm a ONE-SHOT
/// timer, and on fire re-arm from the new `now()`. Re-arming from `now()` each
/// time is also what makes it self-correcting — a late callback (a busy frame,
/// a process resumed from background, a DST jump) is absorbed by the next
/// computation instead of accumulating.
///
/// ## Separate from the widget, on purpose
///
/// Design 0052 §3 seam ③: the ticker and the drawing are different objects, so
/// the tick PERIOD can be declared by whatever is being drawn (V1 says "every
/// minute"; a future seconds-bearing variant says "every second") without the
/// scheduling rule being rewritten per variant. It also makes the alignment
/// itself — [untilNext] — a pure function a test can pin without a real clock.
///
/// This is deliberately NOT a shared app-wide clock stream. The project's
/// standing practice is that each widget ticks for itself
/// (`dashboard_page.dart`'s `_StaleBanner`), with the stated reason that a
/// rebuild should cover exactly the text that changes; a global ticker would
/// rebuild subscribers that had nothing to redraw.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Fires [onTick] on every wall-clock boundary of [period].
///
/// [period] must divide an hour evenly (1 s, 5 s, 15 s, 1 min, 5 min, 15 min,
/// 30 min…), which is what makes "the boundary" a well-defined instant local
/// time agrees with. Asserted rather than silently coped with.
///
/// [now] is injectable so a test can state a time instead of racing the clock —
/// the same seam `relativeTime` uses (`ui/util/relative_time.dart`).
class AlignedTicker {
  AlignedTicker({
    required this.period,
    required this.onTick,
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now,
        assert(period.inMicroseconds > 0, 'a period of zero never advances'),
        assert(Duration.microsecondsPerHour % period.inMicroseconds == 0,
            'period must divide an hour, or "the next boundary" has no meaning');

  final Duration period;
  final VoidCallback onTick;
  final DateTime Function() _now;

  Timer? _timer;

  /// True between [start] and [stop]. Read by tests that must prove the editor
  /// arms no timer at all.
  bool get isRunning => _timer != null;

  /// Arm the first tick. Calling it twice does not stack timers.
  void start() {
    stop();
    _arm();
  }

  /// Cancel any pending tick. Safe to call when never started.
  ///
  /// 🔴 A `State.dispose` that forgets this leaves a timer holding a closure
  /// over a defunct element; the callback then runs `setState` on an unmounted
  /// widget once a minute for the life of the process.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _arm() {
    _timer = Timer(untilNext(_now(), period), () {
      // Re-arm BEFORE the callback: `onTick` calls `setState`, and a build that
      // throws must not take the clock down with it.
      _arm();
      onTick();
    });
  }

  /// How long from [t] to the next whole [period] boundary.
  ///
  /// Never returns zero — landing exactly on a boundary schedules the NEXT one,
  /// so a fire can never re-arm for 0 µs and spin.
  ///
  /// Computed from the LOCAL time-of-day fields rather than from
  /// `microsecondsSinceEpoch`, so a zone whose offset is not a whole number of
  /// hours (UTC+05:30, UTC+05:45, UTC+08:45) still aligns to the minute the
  /// user's screen shows rather than to some UTC minute.
  @visibleForTesting
  static Duration untilNext(DateTime t, Duration period) {
    final intoHour = Duration(
      minutes: t.minute,
      seconds: t.second,
      milliseconds: t.millisecond,
      microseconds: t.microsecond,
    ).inMicroseconds;
    final rem = intoHour % period.inMicroseconds;
    return Duration(microseconds: period.inMicroseconds - rem);
  }
}
