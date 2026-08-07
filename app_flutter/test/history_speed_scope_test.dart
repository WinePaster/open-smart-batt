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
import 'package:open_smart_batt/state/accel_estimator.dart';
import 'package:open_smart_batt/state/gps_speed_controller.dart';
import 'package:open_smart_batt/state/session_context.dart';
import 'package:open_smart_batt/state/settings_controller.dart';
import 'package:open_smart_batt/state/speed_estimator.dart';
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

    // =======================================================================
    // design 0045 §3.7 / Q4 — the two G columns, on the same path
    // =======================================================================
    test('g_long and g_lat ride the same path, independently of the other two',
        () {
      // The G meter and the GPS are INDEPENDENT switches (design 0045 Q2), so
      // every combination of "which columns did this minute measure" is
      // reachable. A minute with G and no speed must record the G and leave
      // speed NULL — the same rule that already separates speed from accel.
      return () async {
        await feed('AA', sampleAt(10, pvlt: 13.2));
        tele.foldSpeedSample(gLongMs2: 2.0, gLatMs2: -1.0);
        tele.foldSpeedSample(gLongMs2: 4.0, gLatMs2: -3.0);
        tele.flushPendingHistory();
        await tele.pendingWrites.drain();

        final r = (await rows()).single;
        expect(r['g_long'], 3.0);
        expect(r['g_lat'], -2.0);
        expect(r['speed'], isNull, reason: 'the GPS switch was off');
        expect(r['accel'], isNull);
      }();
    });

    test('the G columns are SIGNED averages, and that is deliberate', () {
      // Half a minute accelerating and half braking averages towards zero. It
      // is a known cost of a minute-scale table (design 0045 §3.7, following
      // C1) and the alternative — recording an absolute value or a peak —
      // would put a number in the file that the rider was never shown.
      return () async {
        await feed('AA', sampleAt(10, pvlt: 13.2));
        tele.foldSpeedSample(gLongMs2: 3.0, gLatMs2: 1.0);
        tele.foldSpeedSample(gLongMs2: -3.0, gLatMs2: -1.0);
        tele.flushPendingHistory();
        await tele.pendingWrites.drain();

        final r = (await rows()).single;
        expect(r['g_long'], 0.0);
        expect(r['g_lat'], 0.0);
      }();
    });

    test('a minute with no G samples is NULL, never 0.0', () {
      return () async {
        await feed('AA', sampleAt(10, pvlt: 13.2));
        tele.foldSpeedSample(speedMps: 10.0);
        tele.flushPendingHistory();
        await tele.pendingWrites.drain();

        final r = (await rows()).single;
        expect(r['speed'], 10.0);
        expect(r['g_long'], isNull);
        expect(r['g_lat'], isNull);
      }();
    });

    test('and they reach the CSV, at the end, under their own names', () {
      return () async {
        await feed('AA', sampleAt(10, pvlt: 13.2));
        tele.foldSpeedSample(gLongMs2: 1.5, gLatMs2: -0.5);
        tele.flushPendingHistory();
        await tele.pendingWrites.drain();

        // Appended, in order, after `accel` — the standing rule in
        // `history_repo.dart` is that columns only ever join the END, because
        // recipients have spreadsheets built on the existing order.
        expect(HistoryRepo.csvColumns.sublist(HistoryRepo.csvColumns.length - 4),
            ['speed', 'accel', 'g_long', 'g_lat']);

        final csv = await HistoryRepo(db.db).exportCsv();
        final lines = csv.text.split(RegExp(r'\r?\n'));
        final header =
            lines.first.split(',').map((c) => c.replaceAll('"', '')).toList();
        final cells = lines[1].split(',');
        expect(cells[header.indexOf('g_long')], '1.5');
        expect(cells[header.indexOf('g_lat')], '-0.5');
      }();
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

  // -------------------------------------------------------------------------
  // design 0044 §3.5 / Phase 2 — the acceleration column, wired end to end.
  //
  // The two tests above prove `foldSpeedSample` writes what it is given. These
  // prove the right thing is GIVEN to it, driven from a real
  // [GpsSpeedController] over a fake receiver — because every defect this
  // project has shipped in this area lived at the call site while the callee's
  // own tests stayed green.
  // -------------------------------------------------------------------------
  group('acceleration lands raw (design 0044 §3.5)', () {
    late _FakeGpsSource src;
    late DateTime clock;
    late GpsSpeedController gps;

    setUp(() async {
      src = _FakeGpsSource();
      clock = DateTime.utc(2026, 8, 7, 10, 10);
      gps = GpsSpeedController(
        source: src,
        now: () => clock,
        // Short: the tunnel case needs the heartbeat that makes an absence
        // of samples visible. It is harmless in the others — a tick with the
        // clock unmoved changes neither state nor quality, so it emits
        // nothing.
        tickInterval: const Duration(milliseconds: 20),
      );
      tele
        ..bindSpeedEstimates(gps.estimates)
        ..bindAccelEstimates(gps.accelEstimates);
      gps
        ..setFaceWantsSpeed(true)
        ..setDashboardVisible(true);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });

    tearDown(() => gps.dispose());

    /// One fix per second, at [speeds] m/s.
    Future<void> ride(List<double> speeds) async {
      for (final v in speeds) {
        src.emit(SpeedFix(
          speedMps: v,
          horizontalAccuracyM: 5,
          timestamp: clock,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        clock = clock.add(const Duration(seconds: 1));
      }
    }

    test('🔴 the recorded value is the estimator\'s, not the display\'s',
        () async {
      // A crawl so gentle the card shows `0.0`: the slope is well inside the
      // 0.15 m/s² deadband. History must still get the number that was
      // measured — an analyst reading `0` has to be able to trust it means
      // zero, and the deadband would make it mean "small".
      await feed('AA', sampleAt(10, pvlt: 13.2));
      await ride([9.00, 9.02, 9.04, 9.06]);
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();

      final r = (await rows()).single;
      final accel = r['accel'] as double?;
      expect(accel, isNotNull, reason: 'the fold never happened');
      expect(accel, greaterThan(0));
      expect(accel!.abs(), lessThan(0.15));
      expect(displayAccel(accel), 0.0,
          reason: 'the card showed 0.0 for this ride — and the column did not');
    });

    test('a minute that never left warming records a speed and no accel',
        () async {
      // Two samples: enough for a speed, not enough for a two second slope.
      // The pair of columns says exactly that, and design 0044 §3.5 reads it
      // back the same way — accel blank WITH a speed means warming/suppressed.
      await feed('AA', sampleAt(10, pvlt: 13.2));
      await ride([9.0, 11.0]);
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();

      final r = (await rows()).single;
      expect(r['speed'], isNotNull);
      expect(r['accel'], isNull);
    });

    test('a frozen stretch adds nothing to the column', () async {
      // The tunnel, through the whole chain: the speed estimator holds, the
      // acceleration estimator suppresses, and the minute's average is left
      // describing only the part that was measured (0044 G2).
      await feed('AA', sampleAt(10, pvlt: 13.2));
      await ride([9.0, 10.0, 11.0, 12.0]);
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();
      final measured = (await rows()).single['accel'] as double?;
      expect(measured, isNotNull);

      // Now the signal goes. No fixes; only time and a tick.
      clock = clock.add(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await feed('AA', sampleAt(11, pvlt: 13.2));
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();

      final second = (await rows()).last;
      expect(second['accel'], isNull,
          reason: 'a held speed differentiates to a flawless 0.0 that nobody '
              'measured — that zero must never reach the record');
    });
  });
}

/// A GNSS receiver under the test's control.
class _FakeGpsSource implements SpeedLocationSource {
  StreamController<SpeedFix>? _c;

  void emit(SpeedFix f) => _c!.add(f);

  @override
  Stream<SpeedFix> fixes() {
    final c = StreamController<SpeedFix>();
    c.onCancel = () => _c = null;
    _c = c;
    return c.stream;
  }

  @override
  Future<SpeedPermissionState> status() async => SpeedPermissionState.granted;

  @override
  Future<SpeedPermissionState> request() async => SpeedPermissionState.granted;

  @override
  Future<void> openSystemSettings() async {}
}
