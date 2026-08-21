/// OpenSmartBatt — saved device model (our own SQLite, not the vendor's).
///
/// PURE Dart. Represents a battery the user has chosen to remember, with an
/// editable alias, for the device-list quick-reconnect flow (mockup screen 3).
library;

import 'declared_device_model.dart';
import 'display_layout.dart';
import 'product_class.dart';

/// A user-saved battery + its alias and last-seen metadata.
class SavedDevice {
  /// BLE device id (platform remote id).
  ///
  /// Android: the hardware MAC — globally stable, a fine long-term key.
  /// iOS: an OS-assigned NSUUID — not a MAC, and different on another phone for
  /// the same physical battery.
  ///
  /// 🔴 CORRECTED 2026-08-17 (design 0068 §1): this used to add *"it changes on
  /// reinstall … therefore treated as a volatile binding"*, and that claim has
  /// no observation behind it while three observations point the other way. See
  /// [DiscoveredDevice.id] for them. The binding is re-resolved against [name]
  /// (see [rebindSavedDeviceId], D.3) only when iOS says it does not know this
  /// id — not on every fresh discovery, which is what let a valid id be rebound
  /// to a different physical unit (`2026.08.14/004` §5 S1).
  final String id;

  /// User-editable display alias (e.g. "電容 #1（前車）").
  final String alias;

  /// Advertised local name captured when the device was saved (e.g.
  /// "RCE-SCAP_II"). The secondary key used to rebind an iOS id that the OS no
  /// longer recognises. ⚠️ It is NOT unique — two capacitors both advertise
  /// `RCE-SCAP_II` — which is why rebinding refuses to guess whenever it could
  /// mean two units (FB-25, design 0068 §4). May be empty for older saved
  /// records
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

  /// What the OWNER says this unit is (design 0066), in its own seven columns.
  ///
  /// 🔴 **This is not a second opinion about [productClass] and must never be
  /// read as one.** [productClass] is measured — `0x10 b4`, deterministic since
  /// design 0007 — and this is typed by a person who may be wrong, may be
  /// guessing, or may be holding hardware we have never seen. The two live side
  /// by side so that a reader months from now can tell which is which; design
  /// 0066 §3.5 records why, and `docs/feedback-triage/discipline.md` records the
  /// three incidents (FB-23 / FB-33 / FB-32) that make it a rule rather than a
  /// preference.
  ///
  /// ⇒ Nothing in the app may route, gate or label on this value. It exists to
  /// be collected and exported.
  ///
  /// [DeclaredModel.none] for every pre-v20 row and for every unit whose owner
  /// has not filled the form in.
  final DeclaredModel declared;

  /// Whether THIS unit is one of the ones warnings are raised for (design 0080
  /// §3.6, schema v22). Defaults to true, including for every pre-v22 row.
  ///
  /// 🔑 Subordinate to the app-wide [AppSettings.alertsEnabled], which defaults
  /// to OFF. Two switches with opposite defaults is not an oversight: the global
  /// one is the consent (§3.7.3 Q4 — notifications are an interruption and iOS's
  /// permission prompt is one-shot), and this one answers a different question,
  /// "now that they are on, is this unit included". Default this to false as
  /// well and the first person who turns the feature on gets silence from every
  /// unit they own, with nothing on screen saying why.
  final bool alertEnabled;

  /// Layer ① of design 0080 §3.1 — what the owner typed for THIS unit, in volts
  /// / °C. **NULL means "not answered" and never "zero"** (§3.6.1).
  ///
  /// 🔴 The null-vs-sentinel rule is load-bearing rather than tidy. A `0.0`
  /// written here to mean "unset" would win layer ① on every comparison, so the
  /// unit's own `0x2B` could never be reached again — and a sentinel is also a
  /// second spelling of NULL in one column, which is what stops
  /// `WHERE alert_uv IS NULL` from counting the people it exists to count. Same
  /// position the `declared_*` columns already take, for the same reason
  /// (`app_database.dart`, v20 and v22).
  ///
  /// ⚠️ Per FIELD, not per unit: a user who typed a UV keeps the device's OV and
  /// OT, so these three are independently nullable and never written as a group.
  final double? alertOv;

  /// See [alertOv] — layer ①, volts, NULL when the owner has not answered.
  final double? alertUv;

  /// See [alertOv] — layer ①, °C, NULL when the owner has not answered.
  final double? alertOt;

  /// Gate ② of design 0080 §3.4 — "mute this unit for an hour", as an epoch-ms
  /// INSTANT rather than a remaining duration. NULL when never muted.
  ///
  /// 🔴 An instant, and it is persisted, because "1 hour" is a promise about
  /// WALL-CLOCK TIME: closing the app must not extend it and reopening the app
  /// must not cancel it. Its sibling — "not again this connection" — is
  /// deliberately memory-only for the mirror-image reason (§3.4: the promise is
  /// about a link, and the link is gone). The asymmetry is the design, not an
  /// omission, which is why only one of the two has a column.
  ///
  /// ⚠️ NULL, never 0. Zero is a real instant (1970-01-01) that happens to read
  /// as "not muted" only by arithmetic accident, and a reader counting rows that
  /// have never been muted would have to know that.
  final int? alertMutedUntilMs;

  /// [alertMutedUntilMs] as a [DateTime], or null. Convenience so no call site
  /// has to remember whether the column is seconds or milliseconds.
  DateTime? get alertMutedUntil => alertMutedUntilMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(alertMutedUntilMs!);

  /// True when [now] is still inside the mute window (§3.4 gate ②).
  ///
  /// Takes [now] rather than reading the clock so the caller's clock — the
  /// substitutable `clock.now()` the evaluator uses — stays the only one in
  /// play. A model that read `DateTime.now()` itself would be the second time
  /// source design 0080 §3.3.1 rules out.
  bool isMutedAt(DateTime now) {
    final until = alertMutedUntilMs;
    return until != null && now.millisecondsSinceEpoch < until;
  }

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
    this.declared = DeclaredModel.none,
    this.alertEnabled = true,
    this.alertOv,
    this.alertUv,
    this.alertOt,
    this.alertMutedUntilMs,
  });

  /// 🔴 The four nullable alert fields need CLEAR FLAGS, unlike every other
  /// nullable on this class, and the reason is that null MEANS something here
  /// (see [alertOv]). `copyWith(alertUv: null)` is indistinguishable from "leave
  /// it alone" in Dart, so without these there would be no way to express the
  /// 「還原」 button — the one control on the alert screen whose entire job is to
  /// put a field back to "the owner has not answered". Same shape and same
  /// reason as [AppSettings.clearGCalibration].
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
    DeclaredModel? declared,
    bool? alertEnabled,
    double? alertOv,
    bool clearAlertOv = false,
    double? alertUv,
    bool clearAlertUv = false,
    double? alertOt,
    bool clearAlertOt = false,
    int? alertMutedUntilMs,
    bool clearAlertMutedUntil = false,
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
        // Clearing works by passing [DeclaredModel.none], which is a real value
        // rather than null — so this one field needs none of the `clearX` flags
        // the settings model has to carry. See `declared_device_model.dart`.
        declared: declared ?? this.declared,
        alertEnabled: alertEnabled ?? this.alertEnabled,
        alertOv: clearAlertOv ? null : (alertOv ?? this.alertOv),
        alertUv: clearAlertUv ? null : (alertUv ?? this.alertUv),
        alertOt: clearAlertOt ? null : (alertOt ?? this.alertOt),
        alertMutedUntilMs: clearAlertMutedUntil
            ? null
            : (alertMutedUntilMs ?? this.alertMutedUntilMs),
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
        // design 0066 v20 — seven nullable columns, spread from one value
        // object. 🔴 They are written even when empty, and that is the point of
        // routing them through `toMap`: `upsertSavedDevice` is an INSERT OR
        // REPLACE of the WHOLE ROW, so a column left out here is not merely
        // unsaved — it is erased on the next unrelated write to the record
        // (the trap `schema_v19_test`'s round-trip case documents).
        ...declared.toMap(),
        // design 0080 v22. Written on EVERY upsert for the reason the declared
        // block above states: `upsertSavedDevice` is an INSERT OR REPLACE of the
        // whole row, so a column left out of this map is not "unsaved", it is
        // erased the next time anything else about this unit is written — a
        // user's mute would expire the moment they renamed the device.
        'alert_enabled': alertEnabled ? 1 : 0,
        // 🔴 NULL travels as NULL. Do not "tidy" these with `?? 0`: null is the
        // answer "the owner has not said", and it is what lets layer ② win. See
        // [alertOv].
        'alert_ov': alertOv,
        'alert_uv': alertUv,
        'alert_ot': alertOt,
        'alert_muted_until': alertMutedUntilMs,
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
        // Absent columns (pre-v20) and NULLs both read back as
        // [DeclaredModel.none] — "the owner has not answered", which is the
        // truth about every row that existed before this shipped (M7).
        declared: DeclaredModel.fromMap(m),
        // Absent column (pre-v22) reads as ON, matching the column's DEFAULT —
        // `!= 0` rather than `== 1`, unlike the two consent switches in
        // `AppSettings`, because this one is not a consent: it is subordinate to
        // the global switch, which is off, so an upgraded row reading "included"
        // grants nothing.
        alertEnabled: ((m['alert_enabled'] as num?)?.toInt() ?? 1) != 0,
        // 🔴 Absent column and stored NULL both read back as null — "not
        // answered" — and nothing here substitutes a number for them.
        alertOv: (m['alert_ov'] as num?)?.toDouble(),
        alertUv: (m['alert_uv'] as num?)?.toDouble(),
        alertOt: (m['alert_ot'] as num?)?.toDouble(),
        alertMutedUntilMs: (m['alert_muted_until'] as num?)?.toInt(),
      );

  /// Value equality (design 0080 P2).
  ///
  /// 🔑 Added with the alert columns rather than before them because this is the
  /// first record the UI DIFFS: the alert screen holds a device, writes a field,
  /// and reloads, and "did anything change" has to be answerable without
  /// comparing eleven fields by hand at each call site. `DeclaredModel` already
  /// carries its own `==`, so the nested compare is a value compare too.
  @override
  bool operator ==(Object other) =>
      other is SavedDevice &&
      other.id == id &&
      other.alias == alias &&
      other.name == name &&
      other.lastSeen == lastSeen &&
      other.lastValue == lastValue &&
      other.stale == stale &&
      other.productClass == productClass &&
      other.displayLayout == displayLayout &&
      other.mac == mac &&
      other.serial == serial &&
      other.declared == declared &&
      other.alertEnabled == alertEnabled &&
      other.alertOv == alertOv &&
      other.alertUv == alertUv &&
      other.alertOt == alertOt &&
      other.alertMutedUntilMs == alertMutedUntilMs;

  @override
  int get hashCode => Object.hash(
        id,
        alias,
        name,
        lastSeen,
        lastValue,
        stale,
        productClass,
        displayLayout,
        mac,
        serial,
        declared,
        alertEnabled,
        alertOv,
        alertUv,
        alertOt,
        alertMutedUntilMs,
      );
}

/// Resolve the BLE id to connect to for a saved device (D.3). Pure +
/// unit-testable.
///
/// On platforms where the remote id is stable ([useNameKey] == false, i.e.
/// Android MAC) this is identity: always use [savedId].
///
/// On iOS ([useNameKey] == true) the saved NSUUID may be one iOS no longer
/// knows, so we rebind:
///   1. if [savedId] is still present among [candidates] (id → advertised
///      name), keep it (the OS is reusing the same UUID this session);
///   2. refuse outright if [savedNames] — the names of the user's OTHER saved
///      records — already contains [savedName]. See below;
///   3. otherwise pick the freshly-discovered candidate whose advertised name
///      equals [savedName];
///   4. otherwise fall back to [savedId] (caller surfaces a stale error if the
///      connect then fails).
///
/// 🔴 WHEN this runs changed in design 0068 (B), and that matters more than
/// anything in here: it used to be consulted BEFORE the connect, on the test
/// "is the saved id in the current scan?" — and a saved unit drops out of a scan
/// for reasons that have nothing to do with its id, the commonest being that we
/// are connected to it (a peripheral does not advertise while connected). In
/// `2026.08.14/004` §5 S1 that is exactly what happened: four connects to the
/// unit, a scan two seconds after the last one dropped, the unit not in it, and
/// the app rebound to the OTHER capacitor of the same name and reached `ready`
/// on it. The caller now dials the saved id FIRST and only asks this function
/// anything if the platform says it does not know that id.
///
/// 🔑 [savedNames] is rule 2 and it is the other half of the same capture. The
/// uniqueness check below is against what is VISIBLE, so "the saved unit is out
/// of range and its twin is not" passes it every time — `matches.length == 1` is
/// then true by construction. Two saved records sharing a name means the user
/// owns two units this function cannot tell apart, so it does not try.
String rebindSavedDeviceId({
  required String savedId,
  required String savedName,
  required Map<String, String> candidates,
  required Iterable<String> savedNames,
  required bool useNameKey,
}) {
  if (!useNameKey || savedName.isEmpty) return savedId;
  if (candidates.containsKey(savedId)) return savedId;
  // Rule 2. Counted rather than `contains`-ed: the caller passes the names of
  // the OTHER records, so one hit is already one too many.
  if (savedNames.any((n) => n == savedName)) return savedId;
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
