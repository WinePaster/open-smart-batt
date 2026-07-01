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
