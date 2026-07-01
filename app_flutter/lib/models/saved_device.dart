/// OpenSmartBatt — saved device model (our own SQLite, not the vendor's).
///
/// PURE Dart. Represents a battery the user has chosen to remember, with an
/// editable alias, for the device-list quick-reconnect flow (mockup screen 3).
library;

/// A user-saved battery + its alias and last-seen metadata.
class SavedDevice {
  /// BLE device id (platform remote id).
  ///
  /// Android: the hardware MAC — globally stable, a fine long-term key.
  /// iOS: an OS-assigned, install-scoped NSUUID — it changes on reinstall and
  /// differs per phone for the same physical battery. On iOS this field is
  /// therefore treated as a volatile binding that is re-resolved against the
  /// stable [name] on each fresh discovery (see [rebindSavedDeviceId], D.3).
  final String id;

  /// User-editable display alias (e.g. "電容 #1（前車）").
  final String alias;

  /// Advertised local name captured when the device was saved (e.g.
  /// "RCE-SCAP_II"). Used as the STABLE secondary key to rebind a volatile iOS
  /// NSUUID on reinstall / a fresh scan. May be empty for older saved records
  /// (then rebinding falls back to the raw [id]).
  ///
  /// NOTE: persisting this requires the `name` column added by the data-layer
  /// schema migration; until then it round-trips as '' and rebinding is inert.
  final String name;

  /// When this device was last connected/seen.
  final DateTime? lastSeen;

  /// Last PVLT value (V) shown in the quick-pick meta line; null if never read.
  final double? lastValue;

  /// True once a connect to this record's (iOS) id failed to resolve — the
  /// saved NSUUID is likely stale (reinstall / rotated). Surfaced so the UI can
  /// prompt a re-pick instead of the controller retrying forever.
  final bool stale;

  const SavedDevice({
    required this.id,
    required this.alias,
    this.name = '',
    this.lastSeen,
    this.lastValue,
    this.stale = false,
  });

  SavedDevice copyWith({
    String? id,
    String? alias,
    String? name,
    DateTime? lastSeen,
    double? lastValue,
    bool? stale,
  }) =>
      SavedDevice(
        id: id ?? this.id,
        alias: alias ?? this.alias,
        name: name ?? this.name,
        lastSeen: lastSeen ?? this.lastSeen,
        lastValue: lastValue ?? this.lastValue,
        stale: stale ?? this.stale,
      );

  // Mirrors the v3 `saved_devices` schema. `name`/`stale` were added by the
  // schemaVersion 3 migration (D.3) so the stable advertised name persists and
  // the iOS NSUUID rebind can actually fire on reinstall.
  Map<String, Object?> toMap() => {
        'id': id,
        'alias': alias,
        'name': name,
        'last_seen': lastSeen?.millisecondsSinceEpoch,
        'last_value': lastValue,
        'stale': stale ? 1 : 0,
      };

  static SavedDevice fromMap(Map<String, Object?> m) => SavedDevice(
        id: m['id'] as String,
        alias: (m['alias'] as String?) ?? '',
        // Forward-compatible: read the stable name / stale flag once the schema
        // migration adds them; default safely for pre-migration rows.
        name: (m['name'] as String?) ?? '',
        lastSeen: m['last_seen'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (m['last_seen'] as num).toInt()),
        lastValue: (m['last_value'] as num?)?.toDouble(),
        stale: ((m['stale'] as num?)?.toInt() ?? 0) == 1,
      );
}

/// Resolve the BLE id to connect to for a saved device (D.3). Pure +
/// unit-testable.
///
/// On platforms where the remote id is stable ([useNameKey] == false, i.e.
/// Android MAC) this is identity: always use [savedId].
///
/// On iOS ([useNameKey] == true) the saved NSUUID is volatile, so we rebind:
///   1. if [savedId] is still present among [candidates] (id → advertised
///      name), keep it (the OS is reusing the same UUID this session);
///   2. otherwise pick the freshly-discovered candidate whose advertised name
///      equals [savedName];
///   3. otherwise fall back to [savedId] (caller surfaces a stale error if the
///      connect then fails).
String rebindSavedDeviceId({
  required String savedId,
  required String savedName,
  required Map<String, String> candidates,
  required bool useNameKey,
}) {
  if (!useNameKey || savedName.isEmpty) return savedId;
  if (candidates.containsKey(savedId)) return savedId;
  for (final e in candidates.entries) {
    if (e.value.isNotEmpty && e.value == savedName) return e.key;
  }
  return savedId;
}
