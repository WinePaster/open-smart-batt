/// OpenSmartBatt — foreground/background window instrument (design 0047
/// Phase 0).
///
/// Pairs the "left the foreground" lifecycle states with the `resumed` that
/// ends them and emits one diagnostic line at each edge:
///
///     bg-window: enter link=<ready|connected|none>
///     bg-window: exit away=<n>ms link=<ready|connected|none>
///
/// Fixed prefix and `key=value` fields so a line-oriented log parser can count
/// windows and bucket their durations without free-text matching. The lines
/// carry NO device identifier — the surrounding attributed event path already
/// stamps the session, and the window is a fact about the app, not a unit.
///
/// Instrument only: it observes lifecycle transitions and produces text. It
/// does not reconnect, flush, or gate anything.
///
/// `inactive` is deliberately NOT an enter edge — it fires for a notification
/// banner or a permission dialog (see `SpeedLifecycleGate`), and a window
/// opened there would count seconds the app never left the screen. Whether a
/// reconnect was needed on resume is also deliberately NOT a field: the link
/// events that follow (`link: …`, `resume probe: …`) already say so, and a
/// second copy could disagree with them.
library;

import '../ble/ble_models.dart' show BleLinkState;

/// Pairs non-foreground lifecycle edges and formats the `bg-window:` lines.
class BackgroundWindowTracker {
  DateTime? _enteredAt;

  /// Three-token snapshot vocabulary for the `link=` field: `ready` (telemetry
  /// flowing), `connected` (GATT link up, setup not finished), `none` (no live
  /// link — transitional states included, because no data can arrive on them).
  /// Deliberately smaller than [BleLinkState] so the field stays countable;
  /// the full state is already on the adjacent `link:` lines when it matters.
  static String linkToken(BleLinkState s) => switch (s) {
        BleLinkState.ready => 'ready',
        BleLinkState.connected => 'connected',
        BleLinkState.disconnected ||
        BleLinkState.connecting ||
        BleLinkState.disconnecting =>
          'none',
      };

  /// True between an enter edge and its matching resume. Test-visible so the
  /// pairing can be asserted directly rather than inferred from output.
  bool get inBackground => _enteredAt != null;

  /// Feed one lifecycle transition ([state] is `AppLifecycleState.name`).
  /// Returns the diagnostic line to log, or null when this transition is not
  /// an edge — repeated non-foreground states (`hidden` then `paused` arrive
  /// back to back) open ONE window, and a `resumed` with no window open (cold
  /// start, or return from a banner) reports nothing.
  ///
  /// [link] is the state snapshot token for the current BLE link — use
  /// [linkToken]. Clock-free: callers pass [now] so pairing is testable.
  String? onLifecycle(String state,
      {required String link, required DateTime now}) {
    switch (state) {
      case 'paused':
      case 'hidden':
      case 'detached':
        if (_enteredAt != null) return null;
        _enteredAt = now;
        return 'bg-window: enter link=$link';
      case 'resumed':
        final entered = _enteredAt;
        if (entered == null) return null;
        _enteredAt = null;
        final away = now.difference(entered).inMilliseconds;
        return 'bg-window: exit away=${away}ms link=$link';
      default:
        // `inactive` and anything a future SDK adds: not an edge.
        return null;
    }
  }
}
