/// design 0077 path A (FB-93) — widening a device-scoped query to the ids a
/// record used to be keyed by.
///
/// ## Why this exists at all
///
/// A rebind changes `saved_devices.id`. Under path A nothing else moves:
/// `history` and `diag_log` keep the id that was dialled when their rows were
/// written. So the only thing standing between a rebound unit and a blank
/// history page is that the two `_scope` helpers know about the old ids.
///
/// 🔴 **Injected rather than looked up.** `HistoryRepo` and `LogRepo` take a
/// `Database` and nothing else — giving either of them a dependency on
/// `saved_devices` would make a table that records a human act (this unit is
/// mine, and it is called Fu's bike) a prerequisite for reading telemetry that
/// was recorded without one. The composition root already holds both halves;
/// it wires them together and neither repo learns what a saved device is.
///
/// ⚠️ **Synchronous by contract.** `_scope` is a pure string builder called
/// inside query construction; making it `await` would push `async` through
/// every caller for a lookup that is a map read on data already in memory.
/// A resolver that cannot answer synchronously must return `const []` rather
/// than block — one missing alias narrows a query, which shows up as missing
/// history; a hang takes the page down.
library;

/// Returns the ids [deviceId] used to be keyed by. Never includes [deviceId].
typedef DeviceIdAliases = List<String> Function(String deviceId);

/// The full id set to scope a query by: the current id first, then any former
/// ones, de-duplicated and stable-ordered.
///
/// Kept out of both repos so the two `_scope` helpers cannot drift — they are
/// the only two places in the app that filter by `device_id` (design 0077
/// §7.1 fact 5), and the whole of path A is that they agree.
List<String> scopeIdsFor(String deviceId, DeviceIdAliases? aliases) {
  final extra = aliases?.call(deviceId) ?? const <String>[];
  if (extra.isEmpty) return <String>[deviceId];
  // A resolver that mistakenly includes the current id must not make it appear
  // twice in the IN list: harmless to SQLite, confusing to anyone counting.
  final seen = <String>{deviceId};
  final out = <String>[deviceId];
  for (final id in extra) {
    if (id.isEmpty || !seen.add(id)) continue;
    out.add(id);
  }
  return out;
}
