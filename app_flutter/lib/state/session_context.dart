/// OpenSmartBatt — "which unit is being recorded right now": the single place
/// the device/session attribution stamped on stored rows comes from.
///
/// PURE Dart (no Flutter imports) so it is trivially unit-testable. Both
/// [ConnectionController] (link/scan events) and [TelemetryController] (packets
/// + history rows) write to the same tables, so the device/session attribution
/// they stamp on must come from ONE place — otherwise the two could disagree
/// and rows would be filed under the wrong unit.
library;

/// The device + connection a recorded row belongs to.
///
/// [deviceId] is the BLE remote id (iOS NSUUID / Android MAC). It is a storage
/// key only: never render it in a filename or in anything the user shares. On
/// Android it IS the unit's MAC address, so putting it in a file that gets
/// mailed out leaks hardware identity; exports name a unit by serial, then by
/// the user's alias, then by a short hash of this id — never by the id.
class SessionContext {
  /// Unit currently being recorded, or null when disconnected.
  String? get deviceId => _deviceId;
  String? _deviceId;

  /// Current connection counter, or null when disconnected.
  int? get sessionId => _sessionId;
  int? _sessionId;

  int _nextSession = 1;

  /// Restore the counter after a restart so session ids stay monotonic across
  /// app launches. [lastSeen] is the highest id already stored (null if none).
  void seed(int? lastSeen) {
    if (lastSeen != null && lastSeen >= _nextSession) {
      _nextSession = lastSeen + 1;
    }
  }

  /// Begin recording for [deviceId]; allocates the next session id.
  ///
  /// Re-entering with the SAME device while already in a session (e.g. a
  /// `ready` state re-emitted without an intervening disconnect) keeps the
  /// current session rather than splitting one connection into two.
  void begin(String deviceId) {
    if (_deviceId == deviceId && _sessionId != null) return;
    _deviceId = deviceId;
    _sessionId = _nextSession++;
  }

  /// Stop attributing rows to a unit (link dropped / user disconnected).
  void end() {
    _deviceId = null;
    _sessionId = null;
  }
}
