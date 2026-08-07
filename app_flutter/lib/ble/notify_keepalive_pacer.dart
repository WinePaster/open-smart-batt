/// OpenSmartBatt — notify-driven keep-alive pacer (design 0047 Phase 1).
///
/// iOS with `bluetooth-central` declared freezes Dart timers while the app is
/// backgrounded, but every inbound notify from an already-connected peripheral
/// opens a short execution window. The device streams telemetry only for as
/// long as it keeps receiving a poll token (PROTOCOL.md §2), so if nothing
/// writes during those windows the stream starves and the link dies. This
/// class is the policy that keeps it fed: while ACTIVE, a notify arrival may
/// carry one keep-alive write with it — debounced against the last SUCCESSFUL
/// write so a healthy 1 Hz stream produces at most the cadence the foreground
/// timer already produces, and a backlog flushed on thaw produces ONE send,
/// not one per queued chunk.
///
/// Pure and clock-free (callers pass `now`), like [ExecGapTracker] and
/// `BackgroundWindowTracker`: the debounce is the thing worth testing, and a
/// policy that needs a frozen iOS process to exercise is a policy nobody
/// tests.
///
/// 🔴 Android must never activate this. Its keep-alive stays timer-driven
/// under the foreground service (FB-26 / design 0038); the only caller of
/// [setActive] gates on `MonitorService.pacesKeepAliveInBackground`, which is
/// false on every implementation except `IosMonitorService`. Foreground iOS
/// behaviour is also unchanged: the pacer is active only inside a background
/// window, and the 1 Hz timer keeps running everywhere else.
class NotifyKeepAlivePacer {
  NotifyKeepAlivePacer({this.minInterval = defaultMinInterval});

  /// Minimum age of the last successful keep-alive write before a notify may
  /// carry another one. Matches `BleService.keepAliveInterval` (1 Hz) — the
  /// point is to reproduce the existing cadence from a different trigger, not
  /// to invent a new one. (A test pins the two values together; they live in
  /// different files only because this one must not import the service.)
  static const Duration defaultMinInterval = Duration(seconds: 1);

  final Duration minInterval;

  bool _active = false;
  DateTime? _activeSince;
  int _sends = 0;

  /// True while keep-alives ride the notify path (iOS, backgrounded, setting
  /// on, monitor engaged).
  bool get active => _active;

  /// Keep-alive writes sent from the notify path since the window opened.
  /// Test-visible; the field capture reads it off the summary line instead.
  int get sends => _sends;

  /// Turn the pacing window on or off. Idempotent. Returns the one-line
  /// diagnostic summary when an active window CLOSES (the format follows the
  /// `bg-window:` instrument: fixed prefix, `key=value` fields), else null.
  ///
  /// The summary goes out at close rather than per send because the captures
  /// that need it arrive with the raw-packet log off, and a line per wakeup at
  /// ~1 Hz would crowd the always-on event log the way the FB-20 histogram
  /// note warns against.
  String? setActive(bool v, DateTime now) {
    if (v == _active) return null;
    _active = v;
    if (v) {
      _activeSince = now;
      _sends = 0;
      return null;
    }
    final since = _activeSince;
    _activeSince = null;
    final ms = since == null ? 0 : now.difference(since).inMilliseconds;
    return 'bg-keepalive: window=${ms}ms paced=$_sends';
  }

  /// A notify arrived. True when a keep-alive should ride this execution
  /// window: pacing is active and the last SUCCESSFUL keep-alive write is at
  /// least [minInterval] old (or none has succeeded yet). Counts the send.
  ///
  /// FB-53 / design 0047 R2: measured against the last successful WRITE, not
  /// the last notify, so a backlog of queued notifies flushed on thaw — which
  /// all land inside one wall-clock instant — yields exactly one send. The
  /// caller additionally skips a link whose write is still in flight, the same
  /// re-entrancy rule the 1 Hz timer obeys.
  bool shouldSend({required DateTime? lastWriteOk, required DateTime now}) {
    if (!_active) return false;
    if (lastWriteOk != null && now.difference(lastWriteOk) < minInterval) {
      return false;
    }
    _sends++;
    return true;
  }
}
