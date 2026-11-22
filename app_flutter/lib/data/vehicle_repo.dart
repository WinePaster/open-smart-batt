/// design 0106 Phase 2 — the vehicles tables (schema v29).
///
/// Every rule of §3.2 is enforced HERE, not in a screen: a rule that lives in
/// one page is a rule the next page forgets. Violations throw
/// [VehicleRuleException] with a stable code.
library;

import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import 'app_database.dart';

class VehicleRepo {
  VehicleRepo(this._db);

  final Database _db;

  /// The personal row's fixed id. Fixed rather than random so a rebind or a
  /// device delete can address it without a lookup, and so there can never be
  /// two of them.
  static const String personalId = 'personal';

  static final Random _rng = Random.secure();

  static String _newId() {
    final b = StringBuffer('car-');
    for (var i = 0; i < 8; i++) {
      b.write(_rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  // ---- reads ---------------------------------------------------------------

  /// Every vehicle: cars by their sort, the personal row last.
  Future<List<Vehicle>> getAll() => _readAll(_db);

  static Future<List<Vehicle>> _readAll(DatabaseExecutor ex) async {
    final rows = await ex.query(Db.tableVehicles, orderBy: 'sort ASC, id ASC');
    final links = await ex.query(Db.tableVehicleDevices,
        orderBy: 'vehicle_id ASC, sort ASC');
    final members = <String, List<String>>{};
    for (final l in links) {
      (members[l['vehicle_id'] as String] ??= <String>[])
          .add(l['device_id'] as String);
    }
    return [
      for (final r in rows)
        Vehicle(
          id: r['id'] as String,
          kind: VehicleKind.fromStorageKey(r['kind'] as String?),
          name: (r['name'] as String?) ?? '',
          sort: (r['sort'] as int?) ?? 0,
          homeLayout: HomeLayout.decode(r['home_layout']),
          deviceIds: List<String>.unmodifiable(
              members[r['id'] as String] ?? const <String>[]),
          lastPowerBankId: r['last_power_bank_id'] as String?,
        ),
    ];
  }

  /// The current vehicle's id, or null (no vehicle selected / none exist).
  Future<String?> currentId() => _currentId(_db);

  static Future<String?> _currentId(DatabaseExecutor ex) async {
    final rows = await ex.query(Db.tableVehicleState,
        where: 'id = ?', whereArgs: [Db.vehicleStateRowId], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['current_vehicle_id'] as String?;
  }

  static Future<void> _writeCurrent(DatabaseExecutor ex, String? id) =>
      ex.insert(
        Db.tableVehicleState,
        {'id': Db.vehicleStateRowId, 'current_vehicle_id': id},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  // ---- writes --------------------------------------------------------------

  /// Select [id] as the current vehicle, or clear the selection with null.
  Future<void> setCurrent(String? id) => _db.transaction((txn) async {
        if (id != null && !await _exists(txn, id)) {
          throw const VehicleRuleException('not_found');
        }
        await _writeCurrent(txn, id);
      });

  /// Add a car. The personal row is created alongside the FIRST car (§3.1 —
  /// an install that never uses vehicles keeps empty tables), and a car added
  /// while nothing is selected — or while no other car exists — becomes the
  /// current vehicle.
  ///
  /// 2026.11.22/004: "no other car" also covers an install left with
  /// `personal` selected and zero cars (what [delete] used to leave behind when
  /// the last car went while the personal row was picked). Without it the new
  /// car was never selected, the personal row (power banks only) took over the
  /// moment a car existed, and every unit of the new car was dropped.
  Future<Vehicle> createCar(String name) async {
    final id = _newId();
    await _db.transaction((txn) async {
      final cars = await txn.query(Db.tableVehicles,
          columns: ['sort'], where: 'kind = ?', whereArgs: ['car']);
      if (cars.length >= Vehicle.maxCars) {
        throw const VehicleRuleException('vehicle_limit');
      }
      final nextSort = cars.isEmpty
          ? 0
          : cars.map((r) => r['sort'] as int).reduce(max) + 1;
      await txn.insert(Db.tableVehicles, {
        'id': id,
        'kind': VehicleKind.car.storageKey,
        'name': name,
        'sort': nextSort,
      });
      await _ensurePersonal(txn);
      if (cars.isEmpty || await _currentId(txn) == null) {
        await _writeCurrent(txn, id);
      }
    });
    return (await getAll()).firstWhere((v) => v.id == id);
  }

  static Future<void> _ensurePersonal(DatabaseExecutor ex) => ex.insert(
        Db.tableVehicles,
        {
          'id': personalId,
          'kind': VehicleKind.personal.storageKey,
          'name': '',
          'sort': Vehicle.personalSort,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

  Future<void> rename(String id, String name) => _db.transaction((txn) async {
        if (id == personalId) throw const VehicleRuleException('personal_fixed');
        final n = await txn.update(Db.tableVehicles, {'name': name},
            where: 'id = ?', whereArgs: [id]);
        if (n == 0) throw const VehicleRuleException('not_found');
      });

  /// Delete a car. Its memberships go with it (the units themselves stay
  /// saved). Deleting the current car selects the first remaining car;
  /// deleting the LAST car clears the selection whatever it was — a personal
  /// row picked on its own must not outlive the cars (2026.11.22/004).
  Future<void> delete(String id) => _db.transaction((txn) async {
        if (id == personalId) throw const VehicleRuleException('personal_fixed');
        if (!await _exists(txn, id)) {
          throw const VehicleRuleException('not_found');
        }
        // Explicit, not only the FK cascade: the cascade depends on a PRAGMA
        // set per connection, and this delete must not depend on that.
        await txn.delete(Db.tableVehicleDevices,
            where: 'vehicle_id = ?', whereArgs: [id]);
        await txn.delete(Db.tableVehicles, where: 'id = ?', whereArgs: [id]);
        final next = await txn.query(Db.tableVehicles,
            columns: ['id'],
            where: 'kind = ?',
            whereArgs: ['car'],
            orderBy: 'sort ASC, id ASC',
            limit: 1);
        if (next.isEmpty) {
          await _writeCurrent(txn, null);
        } else if (await _currentId(txn) == id) {
          await _writeCurrent(txn, next.first['id'] as String);
        }
      });

  /// Replace the members of vehicle [id], in order. §3.2:
  /// * a car takes at most [Vehicle.maxDevicesPerCar] units, never a power
  ///   bank, never a unit whose class is still unknown (it might turn out to be
  ///   a power bank);
  /// * the personal row takes power banks only.
  Future<void> setDevices(String id, List<String> deviceIds) =>
      _db.transaction((txn) async {
        final v = await txn.query(Db.tableVehicles,
            where: 'id = ?', whereArgs: [id], limit: 1);
        if (v.isEmpty) throw const VehicleRuleException('not_found');
        final kind = VehicleKind.fromStorageKey(v.first['kind'] as String?);
        final ids = <String>[];
        for (final d in deviceIds) {
          if (!ids.contains(d)) ids.add(d);
        }
        if (kind == VehicleKind.car && ids.length > Vehicle.maxDevicesPerCar) {
          throw const VehicleRuleException('vehicle_device_limit');
        }
        final classes = <String, ProductClass>{};
        if (ids.isNotEmpty) {
          final rows = await txn.query(Db.tableSavedDevices,
              columns: ['id', 'product_class'],
              where: 'id IN (${List.filled(ids.length, '?').join(',')})',
              whereArgs: ids);
          for (final r in rows) {
            classes[r['id'] as String] =
                ProductClass.fromStorageKey(r['product_class'] as String?);
          }
        }
        for (final d in ids) {
          final cls = classes[d];
          if (cls == null) throw const VehicleRuleException('not_found');
          if (cls == ProductClass.unknown) {
            throw const VehicleRuleException('unknown_class');
          }
          if (kind == VehicleKind.car && cls == ProductClass.powerBank) {
            throw const VehicleRuleException('power_bank_in_car');
          }
          if (kind == VehicleKind.personal && cls != ProductClass.powerBank) {
            throw const VehicleRuleException('personal_only_power_banks');
          }
        }
        await txn.delete(Db.tableVehicleDevices,
            where: 'vehicle_id = ?', whereArgs: [id]);
        for (var i = 0; i < ids.length; i++) {
          await txn.insert(Db.tableVehicleDevices,
              {'vehicle_id': id, 'device_id': ids[i], 'sort': i});
        }
        if (kind == VehicleKind.personal) {
          final last = v.first['last_power_bank_id'] as String?;
          if (last != null && !ids.contains(last)) {
            await txn.update(Db.tableVehicles, {'last_power_bank_id': null},
                where: 'id = ?', whereArgs: [id]);
          }
        }
      });

  /// This vehicle's home layout; null hands it back to the generated default.
  Future<void> setHomeLayout(String id, HomeLayout? layout) async {
    final n = await _db.update(
        Db.tableVehicles, {'home_layout': layout?.encode()},
        where: 'id = ?', whereArgs: [id]);
    if (n == 0) throw const VehicleRuleException('not_found');
  }

  /// Order the cars as [carIds] lists them (the personal row stays last).
  Future<void> reorderCars(List<String> carIds) => _db.transaction((txn) async {
        for (var i = 0; i < carIds.length; i++) {
          if (carIds[i] == personalId) continue;
          await txn.update(Db.tableVehicles, {'sort': i},
              where: 'id = ? AND kind = ?', whereArgs: [carIds[i], 'car']);
        }
      });

  /// PQ2: remember the power bank connected last. Ignored unless it is a
  /// member of the personal row.
  Future<void> setLastPowerBank(String deviceId) => _db.update(
        Db.tableVehicles,
        {'last_power_bank_id': deviceId},
        where: 'id = ? AND EXISTS (SELECT 1 FROM ${Db.tableVehicleDevices} '
            'WHERE vehicle_id = ? AND device_id = ?)',
        whereArgs: [personalId, personalId, deviceId],
      );

  /// §3.2 last row: a unit that turned out on the wire to be a power bank
  /// leaves every car and joins the personal row. Bypasses the saved-class
  /// check on purpose — the wire is better evidence than the record. Returns
  /// whether anything moved.
  Future<bool> movePowerBankToPersonal(String deviceId) =>
      _db.transaction<bool>((txn) async {
        final inCars = await txn.rawQuery(
            'SELECT vd.vehicle_id FROM ${Db.tableVehicleDevices} vd '
            'JOIN ${Db.tableVehicles} v ON v.id = vd.vehicle_id '
            "WHERE vd.device_id = ? AND v.kind = 'car'",
            [deviceId]);
        if (inCars.isEmpty) return false;
        await txn.delete(Db.tableVehicleDevices,
            where: 'device_id = ? AND vehicle_id != ?',
            whereArgs: [deviceId, personalId]);
        await _ensurePersonal(txn);
        final n = await txn.query(Db.tableVehicleDevices,
            where: 'vehicle_id = ?', whereArgs: [personalId]);
        await txn.insert(
          Db.tableVehicleDevices,
          {'vehicle_id': personalId, 'device_id': deviceId, 'sort': n.length},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        return true;
      });

  static Future<bool> _exists(DatabaseExecutor ex, String id) async =>
      (await ex.query(Db.tableVehicles,
              columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1))
          .isNotEmpty;

  // ---- hooks for DeviceRepo (run inside ITS transaction) --------------------

  /// A saved unit was deleted: drop it from every vehicle (§3.2).
  static Future<void> forgetDevice(DatabaseExecutor ex, String deviceId) async {
    await ex.delete(Db.tableVehicleDevices,
        where: 'device_id = ?', whereArgs: [deviceId]);
    await ex.update(Db.tableVehicles, {'last_power_bank_id': null},
        where: 'last_power_bank_id = ?', whereArgs: [deviceId]);
  }

  /// A saved unit changed id (§3.3): memberships, every vehicle's home layout
  /// and the personal row's last power bank follow it.
  static Future<void> rebindDevice(
      DatabaseExecutor ex, String oldId, String newId) async {
    await ex.update(Db.tableVehicleDevices, {'device_id': newId},
        where: 'device_id = ?', whereArgs: [oldId]);
    await ex.update(Db.tableVehicles, {'last_power_bank_id': newId},
        where: 'last_power_bank_id = ?', whereArgs: [oldId]);
    final rows = await ex.query(Db.tableVehicles,
        columns: ['id', 'home_layout'], where: 'home_layout IS NOT NULL');
    for (final r in rows) {
      final layout = HomeLayout.decode(r['home_layout']);
      if (layout == null || !layout.tiles.any((t) => t.deviceId == oldId)) {
        continue;
      }
      final moved = HomeLayout([
        for (final t in layout.tiles)
          t.deviceId == oldId ? t.copyWith(deviceId: newId) : t,
      ]);
      await ex.update(Db.tableVehicles, {'home_layout': moved.encode()},
          where: 'id = ?', whereArgs: [r['id']]);
    }
  }
}
