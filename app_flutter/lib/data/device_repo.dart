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
}
