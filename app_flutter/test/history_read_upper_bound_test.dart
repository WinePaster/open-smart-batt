// The read layer grows an UPPER bound — design 0083 S1 (T1/T2, and the guard
// for §7 R1).
//
// 🔴 **What this pins, in one sentence:** every one of the three queries behind
// a history screen covers the SAME span, including at the far end.
//
// The three existing ranges — today / last 7 days / all — are each "from some
// moment until now", so until 2026-08-23 the whole path only ever needed a
// lower bound. `_scope` has taken an `until` since design 0074 and
// `queryListBuckets` passed one; design 0081 S3 gave `queryBuckets` one for the
// landscape window. `aggregate` never got one, and neither did the controller
// methods above them.
//
// That last gap is the one worth a test rather than a comment. Since design
// 0081 S1 the chart's bucket width is derived from `HistoryStats.firstAt` /
// `lastAt`, so an unbounded aggregate under a bounded chart divides the span by
// a `lastAt` covering rows the chart is not drawing: every plotted point
// averages MORE time than it should. Nothing throws, no row is wrong, and the
// only symptom is a chart that looks a bit coarse — which reads as a rendering
// choice. `T2` reproduces exactly that as a reverse-proof.
//
// ⛔ S1 adds no behaviour to the three existing ranges: they pass `until: null`
// and `T1c` pins that this is bit-for-bit what they got before.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  final _telemetry = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetry.stream;

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
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late HistoryRepo history;
  late _FakeBle ble;
  late TelemetryController tele;

  setUp(() async {
    db = await AppDatabase.open(
        path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    history = HistoryRepo(db.db);
    ble = _FakeBle();
    tele = TelemetryController(
      ble,
      settings: SettingsController(SettingsRepo(db.db)),
      history: history,
      logs: LogRepo(db.db),
      session: SessionContext(),
    );
  });

  tearDown(() async {
    await tele.pendingWrites.drain();
    tele.dispose();
    await ble.dispose();
    await db.close();
  });

  /// A fixed local midnight, so the fixtures do not move with the wall clock.
  final midnight = DateTime(2026, 8, 23);
  Duration h(num x) => Duration(milliseconds: (x * 3600000).round());

  Future<void> put(DateTime at,
          {String deviceId = 'AA', double pvlt = 13.4}) =>
      db.db.insert(Db.tableHistory, <String, Object?>{
        'timestamp': at.millisecondsSinceEpoch,
        'pvlt': pvlt,
        'temperature': 30,
        'mode': ReportedStatus.normal,
        'device_id': deviceId,
        'samples': 1,
        'bucket_s': 1,
      });

  // ==========================================================================
  group('T1 — `aggregate` takes a half-open upper bound', () {
    test('T1a: `until` is EXCLUSIVE, `since` is inclusive', () async {
      // CATCHES: a closed upper bound. design 0074 T1 made every range in this
      // file half-open so that one row belongs to exactly one window; an
      // `aggregate` using `<=` would count the boundary row here AND in the
      // window that starts at the same instant.
      await put(midnight.add(h(1)));
      await put(midnight.add(h(2))); // exactly the bound below
      await put(midnight.add(h(3)));

      final a = await history.aggregate(
          since: midnight, until: midnight.add(h(2)), deviceId: 'AA');
      expect(a.count, 1, reason: 'the row AT `until` is outside the range');
      expect(a.firstAt, midnight.add(h(1)));
      expect(a.lastAt, midnight.add(h(1)));

      // …and the inclusive end is the other one.
      final b = await history.aggregate(
          since: midnight.add(h(1)), until: midnight.add(h(4)), deviceId: 'AA');
      expect(b.count, 3);
    });

    test('T1b: it bounds the VALUE aggregates too, not only the timestamps',
        () async {
      // CATCHES: an `until` threaded into the timestamp columns but not into
      // the WHERE — the stats strip would then report a maximum voltage the
      // chart beside it never plots.
      await put(midnight.add(h(1)), pvlt: 13.0);
      await put(midnight.add(h(5)), pvlt: 15.9); // outside, and the extreme

      final a = await history.aggregate(
          since: midnight, until: midnight.add(h(2)), deviceId: 'AA');
      expect(a.count, 1);
      expect(a.maxPvlt, 13.0);
      expect(a.avgPvlt, 13.0);
    });

    test('T1c: `until: null` is bit-for-bit the old behaviour', () async {
      // CATCHES: a regression in the three existing ranges, which all pass
      // null. The pre-0083 call had no `until` parameter at all, so "unchanged"
      // can only be shown as "identical to the unbounded query".
      await put(midnight.add(h(1)));
      await put(midnight.add(h(9)));
      await put(midnight.add(h(20)));

      final bounded = await history.aggregate(
          since: midnight, until: null, deviceId: 'AA');
      final legacy = await history.aggregate(since: midnight, deviceId: 'AA');
      expect(bounded.count, legacy.count);
      expect(bounded.firstAt, legacy.firstAt);
      expect(bounded.lastAt, legacy.lastAt);
      expect(bounded.minPvlt, legacy.minPvlt);
      expect(bounded.maxPvlt, legacy.maxPvlt);
      expect(bounded.count, 3);
    });

    test('T1d: an empty bounded range answers like any other empty range',
        () async {
      await put(midnight.add(h(9)));
      final a = await history.aggregate(
          since: midnight, until: midnight.add(h(2)), deviceId: 'AA');
      expect(a.count, 0);
      expect(a.firstAt, isNull);
      expect(a.lastAt, isNull);
    });
  });

  // ==========================================================================
  group('T2 — a bounded aggregate is what keeps the bucket width honest', () {
    test('T2a: `lastAt` cannot reach past `until`', () async {
      await put(midnight.add(h(7.2)));
      await put(midnight.add(h(8.1)));
      await put(midnight.add(h(20))); // outside the window below

      final a = await history.aggregate(
          since: midnight.add(h(7)), until: midnight.add(h(9)), deviceId: 'AA');
      expect(a.firstAt, midnight.add(h(7.2)));
      expect(a.lastAt, midnight.add(h(8.1)));
    });

    test('T2b: reverse-proof — an UNBOUNDED aggregate coarsens the chart',
        () async {
      // This is design 0083 §1.2's "does not look like a bug", made visible.
      // Same rows, same window; the only difference is whether the aggregate
      // was told where the window ends.
      await put(midnight.add(h(7.2)));
      await put(midnight.add(h(8.1)));
      await put(midnight.add(h(20)));

      final from = midnight.add(h(7));
      final to = midnight.add(h(9));

      final bounded =
          await history.aggregate(since: from, until: to, deviceId: 'AA');
      final unbounded = await history.aggregate(since: from, deviceId: 'AA');

      final good = historyChartBucketMs(bounded.firstAt, bounded.lastAt);
      final bad = historyChartBucketMs(unbounded.firstAt, unbounded.lastAt);

      // 54 minutes of recording ⇒ the minute floor. 12 h 48 m ⇒ four minutes a
      // point, on a window that only spans two hours.
      expect(good, kHistoryListBucketMs);
      expect(bad, greaterThan(good));
      expect(bad, (unbounded.lastAt!.difference(unbounded.firstAt!).inMilliseconds) ~/
          kHistoryTargetBucketPoints);
    });

    test('T2c: the minute floor and the day ceiling still apply', () async {
      // The bound must not become a back door to a sub-minute bucket
      // (design 0081 Q5 ruled 分鐘, and design 0083 does not reopen it).
      await put(midnight);
      await put(midnight.add(const Duration(seconds: 30)));
      final a = await history.aggregate(
          since: midnight, until: midnight.add(h(1)), deviceId: 'AA');
      expect(historyChartBucketMs(a.firstAt, a.lastAt), kHistoryListBucketMs);
    });
  });

  // ==========================================================================
  group('R1 — the bound reaches ALL THREE queries, not two of them', () {
    // 🔴 design 0083 §7 R1 is the risk this whole group exists for: missing the
    // bound on ONE of the three produces a chart, a stats strip and a list that
    // cover different spans of one unit, with every number looking plausible
    // (design 0065 §6 R5). Asserting on `loadHistorySlice`'s OUTPUT rather than
    // on which arguments it forwarded is deliberate — a test that checked the
    // call would pass on a controller that accepted `until` and dropped it.
    test('stats, buckets and list all stop at `until`', () async {
      for (var i = 0; i < 4; i++) {
        await put(midnight.add(h(7)).add(Duration(minutes: i * 10)));
      }
      // Well outside, and far enough away to move every aggregate if it leaks.
      await put(midnight.add(h(20)));
      await put(midnight.add(h(21)));

      final slice = await loadHistorySlice(
        tele,
        since: midnight.add(h(7)),
        until: midnight.add(h(9)),
        deviceId: 'AA',
      );

      expect(slice.stats.count, 4, reason: 'stats');
      expect(slice.stats.lastAt, midnight.add(h(7)).add(const Duration(minutes: 30)));

      final lastBucket = slice.buckets.last.at;
      expect(lastBucket.isBefore(midnight.add(h(9))), isTrue, reason: 'chart');
      expect(slice.buckets.fold<int>(0, (n, b) => n + b.count), 4);

      expect(slice.rows.length, 4, reason: 'list');
      for (final r in slice.rows) {
        expect(r.sample.timestamp.isBefore(midnight.add(h(9))), isTrue);
      }
    });

    test('`until: null` still sees everything — the three presets are intact',
        () async {
      await put(midnight.add(h(7)));
      await put(midnight.add(h(20)));

      final slice = await loadHistorySlice(tele,
          since: null, until: null, deviceId: 'AA');
      expect(slice.stats.count, 2);
      expect(slice.rows.length, 2);
      expect(slice.buckets.fold<int>(0, (n, b) => n + b.count), 2);
    });
  });
}
