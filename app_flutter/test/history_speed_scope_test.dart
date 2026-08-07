// Where the phone's speed lands, and where it deliberately does not
// (design 0042 §3.9, owner ruling (b)+(d) of 2026-08-07).
//
// The problem this ruling settles is a shape mismatch, not a preference.
// `history` is one row per minute PER DEVICE; speed is a property of the
// PHONE. Four options were on the table and two were rejected for reasons that
// only tests can keep rejected:
//
//   (a) open a bucket keyed `deviceId == null` — ❌ that IS the device-less
//       history row design 0043 §3.1 refuses to write, and the History screen
//       aggregates by device, so such a row can only ever be averaged in with
//       units it has nothing to do with.
//   (c) give speed its own table — ❌ design 0044's whole purpose is reading a
//       start-up current spike against "was it accelerating just then", and
//       that comparison needs the two numbers on the SAME row.
//   (d) ✅ fold into every open bucket, so N connected units get N rows all
//       carrying the same value.
//   (b) ✅ with nothing connected, write nothing at all.
//
// (b) has a consequence that looks like a bug and is not: minutes spent riding
// with no unit connected have NO row. The last group here pins that the
// controller keeps running anyway, so that a later reader who "fixes" the
// missing rows has to delete a test that says why they are missing.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/session_context.dart';
import 'package:open_smart_batt/state/settings_controller.dart';
import 'package:open_smart_batt/state/telemetry_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  final _telemetry = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetry.stream;

  void emit(TelemetrySample s) => _telemetry.add(s);

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<void> dispose() async {
    await _telemetry.close();
    await super.dispose();
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late HistoryRepo history;
  late _FakeBle ble;
  late SessionContext session;
  late TelemetryController tele;

  setUp(() async {
    db = await AppDatabase.open(
        path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    history = HistoryRepo(db.db);
    ble = _FakeBle();
    session = SessionContext();
    tele = TelemetryController(
      ble,
      settings: SettingsController(SettingsRepo(db.db)),
      history: history,
      logs: LogRepo(db.db),
      session: session,
    );
  });

  tearDown(() async {
    await tele.pendingWrites.drain();
    tele.dispose();
    await ble.dispose();
    await db.close();
  });

  /// One telemetry snapshot at [minute], with a per-unit voltage so the rows of
  /// two units can be told apart.
  TelemetrySample sampleAt(int minute, {required double pvlt}) =>
      TelemetrySample(
        timestamp: DateTime(2026, 8, 7, 10, minute, 30),
        pvlt: pvlt,
      );

  /// Push a sample as though it arrived from [deviceId].
  Future<void> feed(String deviceId, TelemetrySample s) async {
    session.begin(deviceId);
    ble.emit(s);
    await Future<void>.delayed(Duration.zero);
  }

  Future<List<Map<String, Object?>>> rows() =>
      db.db.query(Db.tableHistory, orderBy: 'id');

  group('(b) with nothing connected, speed does not land', () {
    test('a minute of live speed and no device writes no row at all', () async {
      // Sixty samples, no telemetry, no session — the state of riding with the
      // dashboard open and nothing paired.
      for (var i = 0; i < 60; i++) {
        tele.foldSpeedSample(speedMps: 12.0);
      }
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();

      expect(await rows(), isEmpty,
          reason: 'a row here would be a history row with no device — exactly '
              'what design 0043 §3.1 refuses to write, and unreadable by a '
              'screen that aggregates by device');
    });

    test('and it does not silently open a bucket for later', () async {
      // The subtler failure: fold with nothing connected, THEN connect. If the
      // fold had opened a null-keyed bucket, that bucket would flush its own
      // row beside the real one.
      tele.foldSpeedSample(speedMps: 12.0);
      await feed('AA', sampleAt(10, pvlt: 13.2));
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();

      final all = await rows();
      expect(all, hasLength(1));
      expect(all.single['device_id'], 'AA');
      expect(all.single['speed'], isNull,
          reason: 'the sample offered before this unit existed belongs to no '
              'row of its — attributing it here would be inventing a fact');
    });
  });

  group('(d) with units connected, every open bucket gets the same value', () {
    test('two units in one minute yield two rows carrying the same speed',
        () async {
      await feed('AA', sampleAt(10, pvlt: 13.2));
      await feed('BB', sampleAt(10, pvlt: 3.9));
      tele.foldSpeedSample(speedMps: 10.0);
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();

      final all = await rows();
      expect(all, hasLength(2));
      final byDevice = {for (final r in all) r['device_id'] as String?: r};
      // 🔑 The same number, on purpose. One phone was doing one speed; both
      // rows say so. This is why the column is documented as describing the
      // phone and why a per-device query must not SUM it — adding these two
      // would count one journey twice.
      expect(byDevice['AA']!['speed'], 10.0);
      expect(byDevice['BB']!['speed'], 10.0);
      // And the device data did not cross over.
      expect(byDevice['AA']!['pvlt'], 13.2);
      expect(byDevice['BB']!['pvlt'], 3.9);
    });

    test('the column is the minute AVERAGE of the live samples', () async {
      await feed('AA', sampleAt(10, pvlt: 13.2));
      tele.foldSpeedSample(speedMps: 8.0);
      tele.foldSpeedSample(speedMps: 12.0);
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();

      expect((await rows()).single['speed'], 10.0);
    });

    test('a minute with no speed samples is NULL, never 0.0', () async {
      // 0.0 would claim the phone was measured standing still. The absence of
      // a measurement and a measurement of zero are different facts, and the
      // whole feature turns on being able to tell them apart (G2).
      await feed('AA', sampleAt(10, pvlt: 13.2));
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();

      final r = (await rows()).single;
      expect(r['speed'], isNull);
      expect(r['accel'], isNull);
    });

    test('accel rides the same path and is independent of speed', () async {
      // design 0044 writes it; v12 built the column. Pinned now because the
      // fold is shared code and a later change to it would break both.
      await feed('AA', sampleAt(10, pvlt: 13.2));
      tele.foldSpeedSample(speedMps: 10.0, accelMps2: -0.5);
      tele.foldSpeedSample(speedMps: 12.0);
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();

      final r = (await rows()).single;
      expect(r['speed'], 11.0);
      expect(r['accel'], -0.5,
          reason: 'averaged over the samples that HAD one, not diluted by the '
              'ones that did not');
    });
  });

  group('the fold adds no rows and no samples', () {
    test('`samples` counts telemetry snapshots, not speed samples', () async {
      // The regression guard for the 900× write amplification recorded on
      // `_MinuteBucket`: the only visible sign of that defect was `samples`
      // reading 1 on every row. Speed folding must be invisible to it.
      await feed('AA', sampleAt(10, pvlt: 13.2));
      await feed('AA', sampleAt(10, pvlt: 13.3));
      for (var i = 0; i < 30; i++) {
        tele.foldSpeedSample(speedMps: 10.0);
      }
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();

      final all = await rows();
      expect(all, hasLength(1), reason: 'still one row per minute per unit');
      expect(all.single['samples'], 2);
    });
  });

  group('after a disconnect the controller keeps running, it just stops '
      'recording', () {
    test('speed offered with no open bucket is dropped, not queued', () async {
      // 🔴 Written down so that the missing rows read as a decision. Someone
      // will notice a gap in a CSV covering a ride that had the app open the
      // whole time, and the temptation is to "fix" it — which means recreating
      // the null-keyed bucket design 0043 §3.1 closed.
      await feed('AA', sampleAt(10, pvlt: 13.2));
      tele.foldSpeedSample(speedMps: 10.0);
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();
      expect((await rows()).single['speed'], 10.0);

      // The link drops: the session no longer names a unit.
      session.end();
      for (var i = 0; i < 30; i++) {
        tele.foldSpeedSample(speedMps: 25.0);
      }
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();

      final all = await rows();
      expect(all, hasLength(1),
          reason: 'no second row appeared for the disconnected stretch');
      expect(all.single['speed'], 10.0,
          reason: 'and the row already written was not revised');
    });
  });
}
