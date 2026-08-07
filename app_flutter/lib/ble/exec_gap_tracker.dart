/// OpenSmartBatt — Dart execution-gap instrument (design 0047 Phase 0).
///
/// Measures how long the Dart isolate went WITHOUT executing, observed from
/// the BLE event path: the keep-alive timer stamps a tick every second while a
/// link is up, so an inbound BLE event that lands more than [threshold] after
/// the last tick means the isolate was not running in between (OS suspension)
/// — the timer cannot skip five ticks on a live isolate.
///
/// Pure and clock-free (callers pass `now`) so the pairing logic is testable
/// without timers. Instrument only: it changes no connection or recording
/// behaviour, and its one output is a diagnostic line.
///
/// ⚠️ Ticks come from the keep-alive schedule ONLY, and [reset] must be called
/// when that schedule stops (link teardown). Without the reset, idle
/// foreground time between two connections would be reported as an execution
/// gap — the line would then measure "time since the last link", which is not
/// the claim it makes.
class ExecGapTracker {
  ExecGapTracker({this.threshold = defaultThreshold});

  /// Gaps shorter than this are normal scheduling jitter, not a suspension:
  /// the tick source runs at 1 Hz, so a healthy isolate keeps the last tick
  /// under ~1 s old. Five periods clears backlog-flush jitter without hiding
  /// any real suspension window (the ones worth measuring run to minutes).
  static const Duration defaultThreshold = Duration(seconds: 5);

  final Duration threshold;

  DateTime? _lastTick;

  /// Stamp "Dart executed now" — call from the periodic keep-alive callback.
  void tick(DateTime now) => _lastTick = now;

  /// Forget the last tick. Call when the tick source stops (teardown), so a
  /// later event cannot be measured against a schedule that no longer runs.
  void reset() => _lastTick = null;

  /// A BLE event arrived. Returns the diagnostic line to log when the gap
  /// since the last tick is at or over [threshold], else null.
  ///
  /// The event itself counts as a tick: a backlog flushed on resume then
  /// reports ONE line (the first event ends the gap), not one per queued
  /// event.
  String? onEvent(String endedBy, DateTime now) {
    final last = _lastTick;
    _lastTick = now;
    if (last == null) return null;
    final gap = now.difference(last);
    if (gap < threshold) return null;
    return 'exec gap ${gap.inMilliseconds}ms ended by $endedBy';
  }
}
