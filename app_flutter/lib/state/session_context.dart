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
///
/// Sessions are stored PER DEVICE, keyed by device id, with a separate pointer
/// at whichever one is current. Today at most one is ever open, so the map holds
/// 0 or 1 entries and every rule below is unchanged — the point is
/// [sessionIdFor], which lets a row that names its own unit get THAT unit's
/// session number instead of the ambient one. Reading "the current session" for
/// a row belonging to a different unit is exactly what FB-41 was: a `connect →
/// X` line went out carrying unit Y's session number, and the export minted a
/// section header for a connection that never happened.
class SessionContext {
  /// Open sessions by unit: device id → connection counter.
  final Map<String, int> _sessions = <String, int>{};

  /// Unit currently being recorded, or null when disconnected.
  String? get deviceId => _currentDeviceId;
  String? _currentDeviceId;

  /// Current connection counter, or null when disconnected.
  int? get sessionId => sessionIdFor(_currentDeviceId);

  /// The connection counter open for [deviceId], or null when that unit has no
  /// session (never begun, or already ended). A null [deviceId] returns null:
  /// "no unit" is not a unit whose session could be looked up.
  int? sessionIdFor(String? deviceId) =>
      deviceId == null ? null : _sessions[deviceId];

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
  ///
  /// ⚠️ "the same device" still means "the same device AND it is the current
  /// one", which is a single-connection rule. With two links alive, their
  /// interleaved `connecting`/`connected`/`ready` transitions would re-allocate
  /// on every alternation and one connection would become several sessions.
  /// Loosening it to "this unit already has an open session" is NOT a free
  /// edit: it would make `begin('AA'); begin('BB'); begin('AA')` yield two
  /// sessions where three are pinned today, and what that count means — attempts
  /// or connections — is a decision, not an implementation detail. Left as-is
  /// deliberately; the per-device STORE below is what multi-device needed first.
  void begin(String deviceId) {
    if (_currentDeviceId == deviceId && _sessions.containsKey(deviceId)) return;
    _currentDeviceId = deviceId;
    _sessions[deviceId] = _nextSession++;
  }

  /// Stop attributing rows to a unit (link dropped / user disconnected).
  ///
  /// Closes the CURRENT unit's session and only that one, so another unit's
  /// session would survive its neighbour dropping.
  void end() {
    final gone = _currentDeviceId;
    if (gone != null) _sessions.remove(gone);
    _currentDeviceId = null;
  }
}
