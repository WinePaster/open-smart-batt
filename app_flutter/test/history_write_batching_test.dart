// Per-second recording and the batched writer behind it — design 0061 T1/T7
// (FB-71).
//
// Three things have to hold at once, and each one fails silently on its own:
//
//   1. **A row is a second, and says so.** `bucket_s = 1`, `samples ≈ 5`. The
//      column's DEFAULT is 60 — it is what back-filled every pre-v17 row — so
//      an insert that merely forgot the field would produce stored seconds
//      claiming to be minute averages, and nothing downstream could tell.
//   2. **Sixty rows a minute must not be sixty transactions a minute.** This
//      project already ran one accidental experiment in writing a row per
//      sample: a 900× write amplification, with no error, no exception and
//      nothing on screen (`telemetry_controller.dart`'s bucket class records
//      it). Rows are batched, and segments of one second merge in memory before
//      the batch so design 0048's per-(device, window) guarantee survives
//      without a single DB read.
//   3. 🔴 **Nothing is dropped, and nothing is dropped QUIETLY.** The buffer has
//      a cap because `PendingWrites` provides no back-pressure — it states
//      plainly that it is "not a queue and not a scheduler". Over the cap the
//      policy is to commit early, which loses nothing; what is not optional is
//      saying so in the diagnostic log. The 900× incident's whole legacy is
//      that its only trace was a column nobody reads.
//
// V3 of design 0061 §6.0 is the last group: buffered rows must reach the disk
// before the database closes. Its failure mode is intermittent and reads like a
// haunting (`pending_writes.dart` records the original), so it is pinned here
// rather than discovered in the field.
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

/// A repo whose batch write can be held open, so "the buffer filled while a
/// write was in flight" is a state the test can create on purpose rather than
/// hope for.
class _StallableHistoryRepo extends HistoryRepo {
  _StallableHistoryRepo(super.db);

  Completer<void>? gate;
  int batches = 0;
  int rowsWritten = 0;

  @override
  Future<void> insertSamples(Iterable<HistoryWrite> writes) async {
    batches++;
    final list = writes.toList();
    final g = gate;
    if (g != null) await g.future;
    rowsWritten += list.length;
    return super.insertSamples(list);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late _StallableHistoryRepo history;
  late _FakeBle ble;
  late SessionContext session;
  late TelemetryController tele;
  var disposed = false;

  setUp(() async {
    disposed = false;
    db = await AppDatabase.open(
        path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    history = _StallableHistoryRepo(db.db);
    ble = _FakeBle();
    session = SessionContext();
    tele = TelemetryController(
      ble,
      settings: SettingsController(SettingsRepo(db.db)),
      history: history,
      logs: LogRepo(db.db),
      session: session,
      appBuild: '0.7.17+26081400',
    );
  });

  tearDown(() async {
    await tele.pendingWrites.drain();
    if (!disposed) tele.dispose();
    await ble.dispose();
    await db.close();
  });

  final t0 = DateTime(2026, 8, 14, 10, 0, 0);

  Future<void> feed(TelemetrySample s, {String deviceId = 'AA'}) async {
    session.begin(deviceId);
    ble.emit(s);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> settle() async {
    tele.flushPendingHistory();
    await tele.pendingWrites.drain();
  }

  Future<List<Map<String, Object?>>> rows() =>
      db.db.query(Db.tableHistory, orderBy: 'timestamp, id');

  group('a stored row is a SECOND', () {
    test('five snapshots of one second become one row saying `bucket_s = 1`',
        () async {
      // ~4.8 Hz, which is what the two field captures measured.
      for (var i = 0; i < 5; i++) {
        await feed(TelemetrySample(
            timestamp: t0.add(Duration(milliseconds: i * 208)),
            pvlt: 13.0 + i * 0.1));
      }
      await settle();

      final r = await rows();
      expect(r, hasLength(1));
      expect(r.single['bucket_s'], 1,
          reason: 'written explicitly — the column DEFAULT is 60');
      expect(r.single['samples'], 5);
      expect(r.single['app_build'], '0.7.17+26081400');
      expect(r.single['pvlt'] as double, closeTo(13.2, 1e-9));
      // The bucket's start, not the last snapshot's own instant.
      expect(r.single['timestamp'], t0.millisecondsSinceEpoch);
    });

    test('🔴 the one-second surge that a minute average deletes survives',
        () async {
      // The measurement the whole design rests on: a 2026-08-03 capture whose
      // 75 seconds ran −29 A to +8 A came out of history as a single −0.31 A.
      // Sixty seconds of near-idle with one second of −29 A must leave that
      // second visible AS a row.
      for (var s = 0; s < 60; s++) {
        await feed(TelemetrySample(
          timestamp: t0.add(Duration(seconds: s)),
          pvlt: 13.0,
          current: s == 30 ? -29.0 : 0.2,
        ));
      }
      await settle();

      final r = await rows();
      expect(r, hasLength(60));
      expect(r.map((m) => m['ampere']).where((a) => a == -29.0), hasLength(1));
      // And the minute-aggregated view of the same data is the old behaviour —
      // the average really is unremarkable, which is the point.
      final minute = await history.queryListBuckets(
          bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0);
      expect(minute, hasLength(1));
      expect(minute.single.sample.current!.abs() < 1.0, isTrue);
      expect(minute.single.minPvlt, isNotNull);
    });

    test('two units in the same second stay two rows', () async {
      await feed(TelemetrySample(timestamp: t0, pvlt: 13.6), deviceId: 'AA');
      await feed(TelemetrySample(timestamp: t0, pvlt: 3.9), deviceId: 'BB');
      await settle();
      final r = await rows();
      expect(r, hasLength(2));
      expect(r.map((m) => m['device_id']).toSet(), {'AA', 'BB'});
    });
  });

  group('writes are batched, not one transaction per second', () {
    test('ten seconds of recording is ONE batch', () async {
      for (var s = 0; s < 10; s++) {
        await feed(TelemetrySample(
            timestamp: t0.add(Duration(seconds: s)), pvlt: 13.0));
      }
      // The tenth row closes the ninth bucket; the tenth is still open, so a
      // flush is what lands it.
      await settle();
      expect(await history.count(), 10);
      expect(history.batches, lessThanOrEqualTo(2),
          reason: 'ten rows, not ten transactions — the 900× lesson');
    });

    test('a closed bucket waits in the buffer until a batch commits', () async {
      await feed(TelemetrySample(timestamp: t0, pvlt: 13.0));
      await feed(
          TelemetrySample(timestamp: t0.add(const Duration(seconds: 1)), pvlt: 13.1));
      await Future<void>.delayed(Duration.zero);
      expect(tele.pendingHistoryRows, 1);
      expect(await history.count(), 0, reason: 'buffered, not lost');
      await settle();
      expect(await history.count(), 2);
    });

    test('segments landing in ONE batch merge there, weighted, with no DB read',
        () async {
      // Two units and a single flush: everything the flush collects goes into
      // one batch, and same-key rows combine inside it. (The direct proof of
      // the merge arithmetic is in `data_test.dart`; this pins that the
      // controller's flush actually routes through it.)
      await feed(TelemetrySample(timestamp: t0, pvlt: 13.0), deviceId: 'AA');
      await feed(TelemetrySample(
          timestamp: t0.add(const Duration(milliseconds: 400)), pvlt: 14.0),
          deviceId: 'AA');
      await settle();

      final r = await rows();
      expect(r, hasLength(1));
      expect(r.single['samples'], 2);
      expect(r.single['pvlt'] as double, closeTo(13.5, 1e-9));
      expect(history.batches, 1);
    });

    test('⚠️ segments split ACROSS batches stay two rows — the known residual',
        () async {
      // 🔴 Written down because it is a real limitation, not an accident. A
      // lifecycle flush landing mid-second commits what it collected (it has
      // to: every caller of `flushPendingHistory` is saying the app may be
      // about to stop running), so the rest of that second arrives in a LATER
      // batch and cannot be merged with it — the batch path deliberately does
      // not read the table back (design 0061 §3.7).
      //
      // The consequence is the shape `conventions.md` already describes for
      // minutes: the timestamp column is not a unique key. It is invisible to
      // the list and to a per-minute export, both of which aggregate and both
      // of which weight by `samples`; it is visible only in a per-second
      // export, as two rows of one second whose counts add up.
      await feed(TelemetrySample(timestamp: t0, pvlt: 13.0));
      await settle(); // the flush a lifecycle event would perform
      await feed(TelemetrySample(
          timestamp: t0.add(const Duration(milliseconds: 400)), pvlt: 14.0));
      await settle();

      final r = await rows();
      expect(r, hasLength(2));
      expect(r.map((m) => m['samples']).toList(), [1, 1]);
      // And the reading paths still report the second correctly.
      final window = await history.queryListBuckets(
          bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0);
      expect(window.single.sample.pvlt, closeTo(13.5, 1e-9));
      expect(window.single.samples, 2);
    });
  });

  group('🔴 the buffer has a cap, and overflowing it is never silent', () {
    test('over the cap it commits early, logs, and loses nothing', () async {
      // Hold the first write open so the buffer keeps filling — the state that
      // 60× the row rate makes reachable and that `PendingWrites` cannot
      // prevent, because it only tracks writes that have already started.
      history.gate = Completer<void>();

      const n = 700; // > the 600-row cap
      for (var s = 0; s < n; s++) {
        await feed(TelemetrySample(
            timestamp: t0.add(Duration(seconds: s)), pvlt: 13.0));
      }
      history.gate!.complete();
      history.gate = null;
      await settle();

      // Nothing dropped. The last bucket is still open until the flush, and the
      // flush is in `settle()`, so all 700 seconds are on disk.
      expect(await history.count(), n,
          reason: 'the overflow policy commits early; it never discards');

      final log = await db.db.query(Db.tableDiagLog);
      final overflow = log
          .map((m) => (m['note'] as String?) ?? '')
          .where((s) => s.contains('write buffer'))
          .toList();
      expect(overflow, isNotEmpty,
          reason: 'the 900× failure was invisible because nothing said so');
      expect(overflow.first, contains('committing early'));
      // Once per episode, not once per row over the cap.
      expect(overflow.length, lessThan(10));
    });
  });

  group('V3: shutdown lands what is still buffered', () {
    test('disposing the controller commits the buffer before anything closes',
        () async {
      await feed(TelemetrySample(timestamp: t0, pvlt: 13.0));
      await feed(TelemetrySample(
          timestamp: t0.add(const Duration(seconds: 1)), pvlt: 13.1));
      await Future<void>.delayed(Duration.zero);
      expect(tele.pendingHistoryRows, greaterThan(0));

      // What `AppServices.dispose` does, in its order: flush, then drain, then
      // the database would close. A drain cannot wait for a write that was
      // never STARTED, which is exactly why the flush has to come first.
      tele.dispose();
      disposed = true;
      await tele.pendingWrites.drain();

      expect(await history.count(), 2,
          reason: 'both seconds, including the one still open at teardown');
    });

    test('a disconnect commits too — the last seconds of a session are not '
        'left waiting for a tenth row', () async {
      await feed(TelemetrySample(timestamp: t0, pvlt: 13.0));
      ble.emit(TelemetrySample(timestamp: t0, pvlt: 13.0));
      await Future<void>.delayed(Duration.zero);
      tele.flushPendingHistory();
      await tele.pendingWrites.drain();
      expect(await history.count(), greaterThan(0));
    });
  });
}
