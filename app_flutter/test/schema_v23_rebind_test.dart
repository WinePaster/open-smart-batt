// Schema v23 / design 0077 — rebind re-keys the saved record (FB-93).
//
// WHAT THIS PINS. On iOS a unit's BLE id is an NSUUID, and it changes when the
// app is reinstalled. The saved record keeps the old one, so after a rebind the
// list row never says "connected" — the link is up, telemetry is flowing, and
// the screen still offers a Connect button. That is FB-93.
//
// 🔴 THE DANGEROUS HALF. Re-keying is irreversible and moves a unit's alias,
// home tiles and history onto whatever id we happen to be talking to. FB-25 is
// the entry where the app connected to the WRONG unit three times — two
// capacitors sharing an advertised name — so the preconditions are the feature,
// not paperwork around it. Every "refuses to" test below is load-bearing.
//
// PATH A (Q3/Q4). Nothing is moved out of `history` / `diag_log`. The old id
// goes into `former_ids` and the two `_scope` helpers widen to it. The last
// group is the acceptance test for that: rows written under the old id have to
// stay visible afterwards, because "history went blank" is the failure this
// design was chosen to avoid.
//
// CLEAN-ROOM: expectations derive from this project's own source and rulings.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<AppDatabase> freshDb(String tag) async {
    final dir = await Directory.systemTemp.createTemp('osb_$tag');
    addTearDown(() => dir.delete(recursive: true));
    final db = await AppDatabase.open(
      path: p.join(dir.path, 'fresh.db'),
      factory: databaseFactoryFfi,
    );
    addTearDown(db.close);
    return db;
  }

  group('v23 — the column', () {
    test('exists, and is NULL for a record that has never been rebound',
        () async {
      final db = await freshDb('v23_col');
      final repo = DeviceRepo(db.db);
      await repo.upsertSavedDevice(const SavedDevice(id: 'OLD', alias: 'a'));

      final row = (await db.db.query(Db.tableSavedDevices)).single;
      expect(row.containsKey('former_ids'), isTrue);
      expect(row['former_ids'], isNull,
          reason: 'an empty list stores as NULL — "never rebound" and '
              '"rebound to nothing" are not two states');
      expect((await repo.getDevice('OLD'))!.formerIds, isEmpty);
    });
  });

  group('v23 — rebind moves what carries the id, and only that', () {
    test('the record itself, with the old id kept', () async {
      final db = await freshDb('v23_rec');
      final repo = DeviceRepo(db.db);
      await repo.upsertSavedDevice(
          const SavedDevice(id: 'OLD', alias: 'Fu\'s bike', mac: 'AA:BB'));

      expect(await repo.rebind('OLD', 'NEW'), isTrue);

      expect(await repo.getDevice('OLD'), isNull);
      final moved = (await repo.getDevice('NEW'))!;
      expect(moved.alias, 'Fu\'s bike', reason: 'the row moved, not a new one');
      expect(moved.mac, 'AA:BB');
      expect(moved.formerIds, ['OLD'],
          reason: 'THE WHOLE OF PATH A — this list is how the history is '
              'still reachable');
    });

    test('a second rebind appends, oldest first', () async {
      final db = await freshDb('v23_two');
      final repo = DeviceRepo(db.db);
      await repo.upsertSavedDevice(const SavedDevice(id: 'A', alias: 'x'));
      await repo.rebind('A', 'B');
      await repo.rebind('B', 'C');
      expect((await repo.getDevice('C'))!.formerIds, ['A', 'B']);
    });

    test('home tiles pinned to the unit follow it', () async {
      final db = await freshDb('v23_home');
      final repo = DeviceRepo(db.db);
      final settings = SettingsRepo(db.db);
      await repo.upsertSavedDevice(const SavedDevice(id: 'OLD', alias: 'x'));
      final layout = HomeLayout(const [
        HomeTile.device('OLD'),
        HomeTile.device('OTHER'),
      ]);
      await settings.saveSettings((await settings.loadSettings()).copyWith(
          homeLayout: layout.encode()));

      await repo.rebind('OLD', 'NEW');

      final after = HomeLayout.decode((await settings.loadSettings()).homeLayout)!;
      expect(after.tiles.map((t) => t.deviceId), ['NEW', 'OTHER'],
          reason: '§3.2 #6 — missing these silently drops the user\'s cards');
    });

    test('⛔ history is NOT moved — that is the whole point of path A',
        () async {
      final db = await freshDb('v23_nomove');
      final repo = DeviceRepo(db.db);
      await repo.upsertSavedDevice(const SavedDevice(id: 'OLD', alias: 'x'));
      await db.db.insert(Db.tableHistory, {
        'timestamp': 1000,
        'device_id': 'OLD',
        'pvlt': 12.8,
      });

      await repo.rebind('OLD', 'NEW');

      final rows = await db.db.query(Db.tableHistory);
      expect(rows.single['device_id'], 'OLD',
          reason: 'Q3 chose to widen the query, not to rewrite every row '
              'a long-lived unit ever produced under a lock');
    });
  });

  group('v23 — rebind refuses when a precondition is stale', () {
    test('R5 — the target id already has a record', () async {
      final db = await freshDb('v23_r5');
      final repo = DeviceRepo(db.db);
      await repo.upsertSavedDevice(const SavedDevice(id: 'OLD', alias: 'a'));
      await repo.upsertSavedDevice(const SavedDevice(id: 'NEW', alias: 'b'));

      expect(await repo.rebind('OLD', 'NEW'), isFalse);
      expect((await repo.getDevice('OLD'))!.alias, 'a',
          reason: 'nothing may be written when the answer is no');
      expect((await repo.getDevice('NEW'))!.alias, 'b');
    });

    test('the source record is gone', () async {
      final db = await freshDb('v23_gone');
      final repo = DeviceRepo(db.db);
      expect(await repo.rebind('MISSING', 'NEW'), isFalse);
      expect(await repo.getDevice('NEW'), isNull);
    });

    test('same id in and out is a no-op', () async {
      final db = await freshDb('v23_same');
      final repo = DeviceRepo(db.db);
      await repo.upsertSavedDevice(const SavedDevice(id: 'A', alias: 'a'));
      expect(await repo.rebind('A', 'A'), isFalse);
      expect((await repo.getDevice('A'))!.formerIds, isEmpty);
    });
  });

  group('v23 — path A acceptance: the old rows stay visible', () {
    test('🔑 history written under the old id is still found after a rebind',
        () async {
      final db = await freshDb('v23_scope');
      final devices = DeviceRepo(db.db);
      final history = HistoryRepo(db.db);
      await devices.upsertSavedDevice(const SavedDevice(id: 'OLD', alias: 'x'));
      for (var i = 0; i < 3; i++) {
        await db.db.insert(Db.tableHistory,
            {'timestamp': 1000 + i, 'device_id': 'OLD', 'pvlt': 12.0});
      }
      await db.db.insert(Db.tableHistory,
          {'timestamp': 2000, 'device_id': 'SOMEONE_ELSE', 'pvlt': 9.0});

      await devices.rebind('OLD', 'NEW');
      // The resolver the composition root wires — here by hand, so the test
      // pins the repo's behaviour rather than `AppServices`' plumbing.
      history.idAliases = (id) =>
          id == 'NEW' ? const ['OLD'] : const <String>[];

      expect((await history.querySamples(deviceId: 'NEW')).length, 3,
          reason: 'THE SYMPTOM FB-93 WOULD OTHERWISE LEAVE — without the '
              'widening this is 0 and the history page is blank');
      expect((await history.querySamples(deviceId: 'SOMEONE_ELSE')).length, 1,
          reason: 'widening one unit must not widen every unit');
    });

    test('an un-rebound unit is unaffected', () async {
      final db = await freshDb('v23_plain');
      final history = HistoryRepo(db.db);
      await db.db.insert(Db.tableHistory,
          {'timestamp': 1, 'device_id': 'A', 'pvlt': 12.0});
      history.idAliases = (_) => const <String>[];
      expect((await history.querySamples(deviceId: 'A')).length, 1);
      expect((await history.querySamples(deviceId: 'B')).length, 0);
    });
  });
}
