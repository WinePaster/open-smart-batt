/// OpenSmartBatt — saved device model (our own SQLite, not the vendor's).
///
/// PURE Dart. Represents a battery the user has chosen to remember, with an
/// editable alias, for the device-list quick-reconnect flow (mockup screen 3).
library;

import 'display_layout.dart';
import 'product_class.dart';

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

  /// The unit's resolved product class + cosmetic pack label, persisted so a
  /// reconnect can route and gate correctly before the device-type byte has had
  /// time to arrive. For a power bank this is [ProductClass.powerBank]; for a
  /// pack it
  /// is the inferred / user-chosen [ProductClass.supercapacitor] or
  /// [ProductClass.smartBattery]. Defaults to [ProductClass.unknown] for
  /// pre-migration rows.
  final ProductClass productClass;

  /// Which dashboard layout this unit is shown with (design 0034 Q3: the
  /// setting is bound to the DEVICE). Defaults to [DisplayLayout.defaults] for
  /// pre-v10 rows and for any unit whose owner never changed it — and that
  /// default draws exactly the pre-0034 screen.
  final DisplayLayout displayLayout;

  /// The device's own BLE address (selector 0x38), as an upper-case
  /// colon-separated MAC — the stable cross-platform identity (design 0027
  /// §3.2). NULL for pre-v11 rows and until a 0x38 frame has been observed for
  /// this unit.
  ///
  /// 🔴 CLEAN-ROOM: this is raw personal data — fine to persist internally, but
  /// an export writes its [shortDeviceHash], never this value (design 0027 §3.1).
  final String? mac;

  /// The full 15-digit product serial (design 0027 §3.2.2). NULL for pre-v11
  /// rows, for a unit that reports an all-zero 0x26 (a serial is never
  /// fabricated), and for classes that carry none (power banks).
  final String? serial;

  const SavedDevice({
    required this.id,
    required this.alias,
    this.name = '',
    this.lastSeen,
    this.lastValue,
    this.stale = false,
    this.productClass = ProductClass.unknown,
    this.displayLayout = DisplayLayout.defaults,
    this.mac,
    this.serial,
  });

  SavedDevice copyWith({
    String? id,
    String? alias,
    String? name,
    DateTime? lastSeen,
    double? lastValue,
    bool? stale,
    ProductClass? productClass,
    DisplayLayout? displayLayout,
    String? mac,
    String? serial,
  }) =>
      SavedDevice(
        id: id ?? this.id,
        alias: alias ?? this.alias,
        name: name ?? this.name,
        lastSeen: lastSeen ?? this.lastSeen,
        lastValue: lastValue ?? this.lastValue,
        stale: stale ?? this.stale,
        productClass: productClass ?? this.productClass,
        displayLayout: displayLayout ?? this.displayLayout,
        mac: mac ?? this.mac,
        serial: serial ?? this.serial,
      );

  // Mirrors the v10 `saved_devices` schema. `name`/`stale` were added by the
  // schemaVersion 3 migration (D.3); `product_class` by the schemaVersion 4
  // migration, so the resolved class / cosmetic label persists across
  // reconnects; `display_layout` by schemaVersion 10 (design 0034). Every one
  // of these migrations is additive and nullable: rows written by an older
  // build read back with the column absent rather than wrong.
  Map<String, Object?> toMap() => {
        'id': id,
        'alias': alias,
        'name': name,
        'last_seen': lastSeen?.millisecondsSinceEpoch,
        'last_value': lastValue,
        'stale': stale ? 1 : 0,
        'product_class': productClass.storageKey,
        // A default layout is written as NULL, not as its JSON. The column then
        // says "never customised" rather than "customised, to the default",
        // which is the distinction the editor (design 0034 Phase 7) will need
        // and which a blanket encode() would destroy on the first upsert.
        'display_layout': displayLayout.isDefault ? null : displayLayout.encode(),
        // design 0027 v11. Nullable: a row that has never seen a 0x38 frame /
        // a serial keeps NULL rather than an empty string, so "unknown" stays
        // distinct from "known to be blank".
        'mac': mac,
        'serial': serial,
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
        // Absent column / unknown key falls back to unknown (old rows).
        productClass: ProductClass.fromStorageKey(m['product_class'] as String?),
        // Absent column, NULL, or content this build cannot parse — all three
        // land on the default layout WITHOUT throwing. See the reasoning in
        // display_layout.dart: a hand-edited or newer-build value must not be
        // able to take the dashboard down.
        displayLayout: DisplayLayout.decode(m['display_layout']),
        // Absent column (pre-v11) or NULL both read back as null — see toMap.
        mac: m['mac'] as String?,
        serial: m['serial'] as String?,
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
  // Rebind only on a UNIQUE name match. Duplicate advertised names are real,
  // not hypothetical: two distinct power banks both advertise 'RCE_RSPB-01'
  // (a 2026-07-29 field capture, confirmed in the vendor app's own scan list).
  // Returning the first iteration hit would connect to whichever entry the map
  // happened to yield and file its telemetry under the other unit's alias —
  // silent, and indistinguishable afterwards. The caller already handles
  // "cannot resolve", so refusing to guess is the cheaper failure.
  final matches = [
    for (final e in candidates.entries)
      if (e.value.isNotEmpty && e.value == savedName) e.key,
  ];
  if (matches.length == 1) return matches.first;
  return savedId;
}
