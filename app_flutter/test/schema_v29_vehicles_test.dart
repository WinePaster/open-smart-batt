// design 0106 Phase 2 — schema v29 (the vehicles tables) and every rule of
// §3.2, enforced in [VehicleRepo] rather than in a screen.
//
// The v28 fixture is made by opening a current database and taking the v29
// tables back out (plus `user_version = 28`). That IS the v28 schema: v29 is
// purely additive — the parity case below is what keeps that claim honest.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';

Future<Set<String>> _columnsOf(dynamic db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return {for (final row in info) row['name'] as String};
}

Future<Set<String>> _tablesOf(dynamic db) async {
  final rows = await db
      .rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
  return {for (final r in rows) r['name'] as String};
}

void main() {
  setUpAll(sqfliteFfiInit);

  Future<String> tempPath(String name) async {
    final dir = await Directory.systemTemp.createTemp('osb_v29_$name');
    addTearDown(() => dir.delete(recursive: true));
    return p.join(dir.path, 'db.sqlite');
  }

  Future<AppDatabase> fresh(String name) async {
    final db = await AppDatabase.open(
        path: await tempPath(name), factory: databaseFactoryFfi);
    addTearDown(db.close);
    return db;
  }

  const layoutJson = '{"tiles":[{"kind":"device","deviceId":"a"}]}';

  /// A v28 database holding a saved unit and a stored home layout.
  Future<String> v28WithData(String name) async {
    final path = await tempPath(name);
    final db = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    for (final t in [
      Db.tableVehicleDevices,
      Db.tableVehicles,
      Db.tableVehicleState,
    ]) {
      await db.db.execute('DROP TABLE $t');
    }
    await db.db.insert(Db.tableSavedDevices,
        {'id': 'a', 'alias': 'a', 'product_class': 'smartBattery'});
    await db.db.insert(Db.tableSettings,
        {'id': Db.settingsRowId, 'home_layout': layoutJson});
    await db.db.execute('PRAGMA user_version = 28');
    await db.close();
    return path;
  }

  group('migration 28 → 29', () {
    test('adds the three tables, empty; home_layout and devices untouched',
        () async {
      final path = await v28WithData('up');
      final db = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      addTearDown(db.close);
      final v = (await db.db.rawQuery('PRAGMA user_version')).single;
      expect(v['user_version'], 29);
      expect(await _tablesOf(db.db),
          containsAll([Db.tableVehicles, Db.tableVehicleDevices, Db.tableVehicleState]));
      for (final t in [Db.tableVehicles, Db.tableVehicleDevices, Db.tableVehicleState]) {
        expect(await db.db.query(t), isEmpty, reason: t);
      }
      final settings = (await db.db.query(Db.tableSettings)).single;
      expect(settings['home_layout'], layoutJson);
      expect(await db.db.query(Db.tableSavedDevices), hasLength(1));
    });

    test('upgraded and fresh schemas match, table by table', () async {
      final path = await v28WithData('parity');
      final up = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      addTearDown(up.close);
      final nu = await fresh('parity_new');
      expect(await _tablesOf(up.db), await _tablesOf(nu.db));
      for (final t in [Db.tableVehicles, Db.tableVehicleDevices, Db.tableVehicleState]) {
        expect(await _columnsOf(up.db, t), await _columnsOf(nu.db, t), reason: t);
      }
    });

    test('purely additive: every v28 table keeps every column', () async {
      final nu = await fresh('additive');
      // The columns a v28 build reads from settings and saved_devices are
      // still there — what lets an older build open a v29 file's data.
      expect(await _columnsOf(nu.db, Db.tableSettings),
          containsAll(['home_layout', 'allow_landscape', 'text_size']));
      expect(await _columnsOf(nu.db, Db.tableSavedDevices),
          containsAll(['id', 'product_class', 'former_ids', 'last_soc']));
    });
  });

  group('VehicleRepo rules (§3.2)', () {
    late AppDatabase db;
    late VehicleRepo repo;
    late DeviceRepo devices;

    setUp(() async {
      db = await fresh('rules');
      repo = VehicleRepo(db.db);
      devices = DeviceRepo(db.db);
      for (final d in const [
        SavedDevice(id: 'a', alias: 'a', productClass: ProductClass.smartBattery),
        SavedDevice(id: 'b', alias: 'b', productClass: ProductClass.supercapacitor),
        SavedDevice(id: 'c', alias: 'c', productClass: ProductClass.smartBattery),
        SavedDevice(id: 'd', alias: 'd', productClass: ProductClass.smartBattery),
        SavedDevice(id: 'e', alias: 'e', productClass: ProductClass.powerBank),
        SavedDevice(id: 'e2', alias: 'e2', productClass: ProductClass.powerBank),
        SavedDevice(id: 'u', alias: 'u'),
      ]) {
        await devices.upsertSavedDevice(d);
      }
    });

    Matcher rule(String code) => throwsA(
        isA<VehicleRuleException>().having((e) => e.code, 'code', code));

    test('nothing exists until the first car; then personal comes with it '
        'and the car becomes current', () async {
      expect(await repo.getAll(), isEmpty);
      expect(await repo.currentId(), isNull);
      final a = await repo.createCar('A');
      final all = await repo.getAll();
      expect(all.map((v) => v.kind),
          [VehicleKind.car, VehicleKind.personal]);
      expect(all.last.id, VehicleRepo.personalId);
      expect(await repo.currentId(), a.id);
    });

    test('at most five cars (Q8); the personal row does not count', () async {
      for (var i = 0; i < Vehicle.maxCars; i++) {
        await repo.createCar('car $i');
      }
      expect(() => repo.createCar('sixth'), rule('vehicle_limit'));
      expect((await repo.getAll()).where((v) => v.isCar), hasLength(5));
    });

    test('at most three units per car (Q6)', () async {
      final a = await repo.createCar('A');
      await repo.setDevices(a.id, ['a', 'b', 'c']);
      expect(() => repo.setDevices(a.id, ['a', 'b', 'c', 'd']),
          rule('vehicle_device_limit'));
    });

    test('no power bank in a car; nothing but power banks in personal',
        () async {
      final a = await repo.createCar('A');
      expect(() => repo.setDevices(a.id, ['a', 'e']), rule('power_bank_in_car'));
      expect(() => repo.setDevices(VehicleRepo.personalId, ['e', 'a']),
          rule('personal_only_power_banks'));
      await repo.setDevices(VehicleRepo.personalId, ['e', 'e2']);
      final p = (await repo.getAll()).last;
      expect(p.deviceIds, ['e', 'e2'], reason: 'PQ2: several power banks');
    });

    test('a unit of unknown class cannot join anything; an unsaved one '
        'is not_found', () async {
      final a = await repo.createCar('A');
      expect(() => repo.setDevices(a.id, ['u']), rule('unknown_class'));
      expect(() => repo.setDevices(a.id, ['zz']), rule('not_found'));
    });

    test('Q2: one battery may sit in two cars', () async {
      final a = await repo.createCar('A');
      final b = await repo.createCar('B');
      await repo.setDevices(a.id, ['a', 'b']);
      await repo.setDevices(b.id, ['a', 'c']);
      final all = await repo.getAll();
      expect(all.where((v) => v.contains('a')), hasLength(2));
    });

    test('the personal row cannot be renamed or deleted', () async {
      await repo.createCar('A');
      expect(() => repo.rename(VehicleRepo.personalId, 'x'), rule('personal_fixed'));
      expect(() => repo.delete(VehicleRepo.personalId), rule('personal_fixed'));
    });

    test('deleting the current car selects the next; the last one clears it; '
        'the units stay saved', () async {
      final a = await repo.createCar('A');
      final b = await repo.createCar('B');
      await repo.setDevices(a.id, ['a', 'b']);
      await repo.delete(a.id);
      expect(await repo.currentId(), b.id);
      expect(await db.db.query(Db.tableVehicleDevices,
          where: 'vehicle_id = ?', whereArgs: [a.id]), isEmpty);
      expect(await devices.getDevice('a'), isNotNull);
      await repo.delete(b.id);
      expect(await repo.currentId(), isNull);
    });

    test('setCurrent refuses an unknown id', () async {
      expect(() => repo.setCurrent('nope'), rule('not_found'));
    });

    test('forgetting a unit drops it from every vehicle and as last power bank',
        () async {
      final a = await repo.createCar('A');
      await repo.setDevices(a.id, ['a', 'b']);
      await repo.setDevices(VehicleRepo.personalId, ['e']);
      await repo.setLastPowerBank('e');
      await devices.deleteSavedDevice('a');
      await devices.deleteSavedDevice('e');
      final all = await repo.getAll();
      expect(all.first.deviceIds, ['b']);
      expect(all.last.deviceIds, isEmpty);
      expect(all.last.lastPowerBankId, isNull);
    });

    test('rebind (§3.3): memberships, vehicle layouts and the last power bank '
        'follow the new id', () async {
      final a = await repo.createCar('A');
      await repo.setDevices(a.id, ['a', 'b']);
      await repo.setHomeLayout(
          a.id, const HomeLayout([HomeTile.device('a'), HomeTile.device('b')]));
      await repo.setDevices(VehicleRepo.personalId, ['e']);
      await repo.setLastPowerBank('e');
      expect(await devices.rebind('a', 'a2'), isTrue);
      expect(await devices.rebind('e', 'e9'), isTrue);
      final all = await repo.getAll();
      expect(all.first.deviceIds, ['a2', 'b']);
      expect(all.first.homeLayout!.tiles.map((t) => t.deviceId), ['a2', 'b']);
      expect(all.last.deviceIds, ['e9']);
      expect(all.last.lastPowerBankId, 'e9');
    });

    test('a car member found to be a power bank moves to personal', () async {
      final a = await repo.createCar('A');
      await repo.setDevices(a.id, ['a', 'b']);
      expect(await repo.movePowerBankToPersonal('a'), isTrue);
      final all = await repo.getAll();
      expect(all.first.deviceIds, ['b']);
      expect(all.last.deviceIds, ['a']);
      expect(await repo.movePowerBankToPersonal('a'), isFalse,
          reason: 'already out of every car');
    });

    test('setLastPowerBank ignores a non-member', () async {
      await repo.createCar('A');
      await repo.setDevices(VehicleRepo.personalId, ['e']);
      await repo.setLastPowerBank('e2');
      expect((await repo.getAll()).last.lastPowerBankId, isNull);
    });
  });
}
