/// OpenSmartBatt — saved-device repository (mockup screen 3).
///
/// Stores user-remembered batteries with editable aliases + last-seen metadata
/// for the quick-reconnect list.
library;

import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import 'app_database.dart';

/// CRUD over the `saved_devices` table.
class DeviceRepo {
  DeviceRepo(this._db);

  final Database _db;

  /// All saved devices, most-recently-seen first (nulls last).
  Future<List<SavedDevice>> getSavedDevices() async {
    final rows = await _db.query(
      Db.tableSavedDevices,
      orderBy: 'last_seen IS NULL, last_seen DESC, alias ASC',
    );
    return rows.map(SavedDevice.fromMap).toList(growable: false);
  }

  /// Fetch one device by BLE id, or null if not saved.
  Future<SavedDevice?> getDevice(String id) async {
    final rows = await _db.query(
      Db.tableSavedDevices,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SavedDevice.fromMap(rows.first);
  }

  /// Insert or replace a saved device (keyed by [SavedDevice.id]).
  Future<void> upsertSavedDevice(SavedDevice device) {
    return _db.insert(
      Db.tableSavedDevices,
      device.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Update only the alias of an existing device. Returns rows affected.
  Future<int> updateAlias(String id, String alias) {
    return _db.update(
      Db.tableSavedDevices,
      {'alias': alias},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Update last-seen / last-value telemetry meta (used after a connection).
  Future<int> touch(String id, {DateTime? lastSeen, double? lastValue}) {
    return _db.update(
      Db.tableSavedDevices,
      {
        'last_seen': (lastSeen ?? DateTime.now()).millisecondsSinceEpoch,
        'last_value': ?lastValue,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Persist the resolved product class / cosmetic pack label for [id] (design
  /// 0001 §5 Phase 5). Returns rows affected (0 if the device is not saved).
  Future<int> setProductClass(String id, ProductClass productClass) {
    return _db.update(
      Db.tableSavedDevices,
      {'product_class': productClass.storageKey},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Persist the dashboard layout for [id] (design 0034 Phase 3). Returns rows
  /// affected (0 if the device is not saved).
  ///
  /// The DEFAULT layout is stored as NULL rather than as its JSON — see
  /// [SavedDevice.toMap]. That is also what makes "restore defaults" (Q6) a
  /// plain write of [DisplayLayout.defaults] rather than a separate delete
  /// path.
  Future<int> setDisplayLayout(String id, DisplayLayout layout) {
    return _db.update(
      Db.tableSavedDevices,
      {'display_layout': layout.isDefault ? null : layout.encode()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Persist the device's own BLE address (0x38 MAC) and/or full serial for
  /// [id] (design 0027 §3.2). Only the non-null arguments are written, so a
  /// serial-only or mac-only observation never clears the other column. Returns
  /// rows affected (0 if the device is not saved).
  Future<int> setIdentity(String id, {String? mac, String? serial}) {
    final values = <String, Object?>{
      'mac': ?mac,
      'serial': ?serial,
    };
    if (values.isEmpty) return Future.value(0);
    return _db.update(
      Db.tableSavedDevices,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Persist what the OWNER says [id] is (design 0066). Returns rows affected
  /// (0 if the device is not saved).
  ///
  /// 🔴 Writes ALL SEVEN columns every time, including the null ones — unlike
  /// [setIdentity], which skips nulls so a serial-only observation cannot clear
  /// a MAC. The asymmetry is deliberate and comes from what the two write:
  /// [setIdentity] merges independent OBSERVATIONS arriving at different times,
  /// whereas this writes one FORM the user just submitted, and a form's cleared
  /// field is an answer ("I am no longer sure it was orange"). Skip the nulls
  /// here and a value can only ever be set, never taken back.
  ///
  /// 🔴 It touches no other column. `product_class` in particular is not in this
  /// statement and must never be — design 0066 §3.5.
  Future<int> setDeclaredModel(String id, DeclaredModel declared) {
    return _db.update(
      Db.tableSavedDevices,
      declared.toMap(),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Persist this unit's warning settings (design 0080 §3.6, schema v22).
  /// Returns rows affected (0 if the device is not saved).
  ///
  /// 🔴 **Writes all five columns every time, NULLS INCLUDED** — the
  /// [setDeclaredModel] side of the asymmetry, not the [setIdentity] side, and
  /// for the same reason: this is a FORM the user just submitted, not a merge of
  /// observations arriving at different times. A cleared threshold is an answer
  /// (「還原」 = "go back to what the device says"), and skipping nulls would make
  /// a value settable but never retractable — which is the one operation the
  /// screen's 還原 button exists to perform.
  ///
  /// 🔴 It touches no other column, `product_class` and `declared_*` least of
  /// all: a threshold is not an opinion about what the unit IS.
  Future<int> setAlertSettings(
    String id, {
    required bool enabled,
    required double? ov,
    required double? uv,
    required double? ot,
    required int? mutedUntilMs,
  }) {
    return _db.update(
      Db.tableSavedDevices,
      {
        'alert_enabled': enabled ? 1 : 0,
        'alert_ov': ov,
        'alert_uv': uv,
        'alert_ot': ot,
        'alert_muted_until': mutedUntilMs,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Delete a saved device. Returns rows affected.
  Future<int> deleteSavedDevice(String id) {
    return _db.delete(
      Db.tableSavedDevices,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// True if [id] is already saved.
  Future<bool> isSaved(String id) async => (await getDevice(id)) != null;

  /// Re-key the saved record [oldId] to [newId] — design 0077, FB-93.
  ///
  /// 🔴 **Irreversible, and the caller owns the decision.** This method does no
  /// identity checking whatsoever: the six preconditions (0077 §6.2) live in
  /// `ConnectionController`, where the wire evidence is, and they include the
  /// only one that matters — the unit reported a hardware address on the link
  /// and it matched the one we had stored. Calling this without them is how
  /// FB-25 happens: one unit's history, alias and home tiles moved onto
  /// another, permanently.
  ///
  /// ## What moves, and why it is one transaction
  ///
  /// Three things carry the id, and a partial write leaves the app in a state
  /// no code path expects (0077 §6.4):
  ///
  ///  * the record itself — the old id is appended to `former_ids`, which is
  ///    what keeps its history reachable under path A (see
  ///    `device_id_aliases.dart`);
  ///  * every home tile pinned to it — miss these and the user's home page
  ///    silently loses cards, or resets;
  ///  * the pending auto-connect arm, if it happens to name this unit.
  ///
  /// `history` / `diag_log` / `device_facts` are deliberately NOT touched
  /// (Q3/Q4/Q5). Path A reads them through the widened scope instead; moving
  /// them would mean a write of every row a long-lived unit ever produced,
  /// under a lock, for no visible gain.
  ///
  /// Returns false and writes nothing when [newId] already has a row (R5) or
  /// [oldId] has none — both are "the caller's preconditions were stale", and
  /// a throw would turn a race into a crash on a path that runs during a
  /// connection.
  Future<bool> rebind(String oldId, String newId) async {
    if (oldId == newId) return false;
    return _db.transaction<bool>((txn) async {
      final rows = await txn.query(Db.tableSavedDevices,
          where: 'id IN (?, ?)', whereArgs: [oldId, newId]);
      final existing = {for (final r in rows) r['id'] as String: r};
      if (!existing.containsKey(oldId) || existing.containsKey(newId)) {
        return false;
      }
      final old = SavedDevice.fromMap(existing[oldId]!);

      // The record. `former_ids` gains the id being retired, in order, so the
      // scope helpers can find rows written under any of them.
      await txn.update(
        Db.tableSavedDevices,
        {
          'id': newId,
          'former_ids': <String>[...old.formerIds, oldId].join(','),
        },
        where: 'id = ?',
        whereArgs: [oldId],
      );

      // The home layout. Stored as one JSON blob on the settings row, so this
      // is a read-modify-write — inside the same transaction precisely because
      // it is.
      final settingsRows = await txn.query(Db.tableSettings,
          columns: ['home_layout'],
          where: 'id = ?',
          whereArgs: [Db.settingsRowId]);
      if (settingsRows.isNotEmpty) {
        final layout = HomeLayout.decode(settingsRows.first['home_layout']);
        if (layout != null && layout.tiles.any((t) => t.deviceId == oldId)) {
          final moved = HomeLayout([
            for (final t in layout.tiles)
              t.deviceId == oldId ? t.copyWith(deviceId: newId) : t,
          ]);
          await txn.update(Db.tableSettings, {'home_layout': moved.encode()},
              where: 'id = ?', whereArgs: [Db.settingsRowId]);
        }
      }

      // The pending arm, if it names this unit. 0 or 1 rows by construction.
      await txn.update(Db.tableAutoConnectArm, {'device_id': newId},
          where: 'device_id = ?', whereArgs: [oldId]);
      return true;
    });
  }
}
