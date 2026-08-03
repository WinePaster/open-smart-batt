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

  /// Begin recording for [deviceId]; allocates a session id if that unit does
  /// not already have one open.
  ///
  /// A session is ONE CONNECTION, not one attempt at connecting. Re-entering
  /// for a unit that already has an open session (a `ready` re-emitted with no
  /// intervening disconnect, or — once several links are alive — this unit's
  /// turn coming round again) keeps its number and only moves the "current"
  /// pointer. Splitting one connection into several numbered sessions is what
  /// FB-41 looked like from the export side: section headers for connections
  /// that never happened.
  ///
  /// The rule used to be narrower — "the same device AND it is the current one"
  /// — which is only correct while at most one link exists. With two alive,
  /// their interleaved `connecting`/`connected`/`ready` transitions re-allocate
  /// on every alternation, so `begin('AA'); begin('BB'); begin('AA')` minted
  /// THREE sessions for two connections. Widened deliberately (2026-08-03).
  ///
  /// 🔑 **A failed attempt still gets its own id, and `connections=N` still
  /// counts attempts.** That property does not come from this method — it comes
  /// from [end] being called on every `disconnected`, which closes the session
  /// before the retry calls [begin] again. So attempt 1 and attempt 2 to the
  /// same unit are bracketed and get different numbers, while two `ready`s
  /// inside one live connection do not. The two behaviours were previously
  /// entangled in this one condition; they are now separate, and the
  /// begin/end/begin case is pinned by its own test.
  void begin(String deviceId) {
    if (_sessions.containsKey(deviceId)) {
      _currentDeviceId = deviceId;
      return;
    }
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
