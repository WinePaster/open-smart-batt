// The History list is a per-MINUTE aggregation over per-SECOND storage
// (design 0061 T3a/T3b), and this file pins the two ways that aggregation can
// quietly destroy the thing it was built to expose.
//
// 🔴 **V2 of design 0061 §6.0 lives here.** The failure it guards is the one
// the design calls the most easily missed defect in the whole change: if the
// list classified a minute on its MEAN, one second of over-voltage inside sixty
// ordinary ones would average away, the minute would be marked `normal`, and it
// would vanish from the "warnings only" filter. The user would have paid 60×
// the storage for an instantaneous event that the READ path then deletes — and
// the SQL doing it looks completely normal. The rule is: thresholds are judged
// on MIN/MAX, never on AVG.
//
// The second one is older and the corpus has measured it four times: a stored
// minute can be SEVERAL rows with wildly different `samples` counts (design
// 0048 G2 leaves old segments alone), so an unweighted `AVG` over them is not
// the minute's mean. `conventions.md` records a 19:26 minute stored as
// 405 / 69 / 3 / 56 whose unweighted `ampere` mean comes out with the WRONG
// SIGN. A brand-new aggregation that ignored the standing "always weight by
// `samples`" rule would have re-introduced that defect inside the app itself.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late HistoryRepo history;

  setUp(() async {
    db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    history = HistoryRepo(db.db);
  });

  tearDown(() async => db.close());

  // UTC so the fixtures are readable; every query below pins `tzOffsetMs`
  // explicitly, so the machine's own zone never enters into it.
  final minute = DateTime.utc(2026, 8, 14, 9, 50);

  /// One stored row, written straight to the table so the test can choose the
  /// granularity and the sample count the repo's own writers would not.
  Future<void> put({
    required DateTime at,
    required int bucketS,
    double? pvlt,
    double? ampere,
    int? temperature,
    int? mode,
    int samples = 5,
    String deviceId = 'AA',
  }) async {
    await db.db.insert(Db.tableHistory, <String, Object?>{
      'timestamp': at.millisecondsSinceEpoch,
      'pvlt': pvlt,
      'ampere': ampere,
      'temperature': temperature,
      'mode': mode,
      'device_id': deviceId,
      'samples': samples,
      'bucket_s': bucketS,
    });
  }

  group('a one-second spike survives the minute it lands in (V2)', () {
    test('one over-voltage second keeps the minute in "warnings only"',
        () async {
      // Sixty seconds of an entirely ordinary 13.2 V, and ONE second at
      // 15.5 V. The mean of that minute is 13.24 V — below any threshold
      // anyone would set.
      for (var s = 0; s < 60; s++) {
        await put(
          at: minute.add(Duration(seconds: s)),
          bucketS: 1,
          pvlt: s == 37 ? 15.5 : 13.2,
        );
      }

      final rows = await history.queryListBuckets(
          bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0);
      expect(rows, hasLength(1), reason: 'sixty seconds are one minute window');
      final w = rows.single;
      expect(w.rows, 60);
      expect(w.samples, 300, reason: 'SUM(samples): 60 seconds x 5 snapshots');

      const ov = 15.0;

      // The mean is unremarkable — this is the number an `AVG`-based
      // classification would have judged, and it does NOT cross the threshold.
      expect(w.sample.pvlt, closeTo(13.238, 1e-3));
      expect(w.sample.pvlt! > ov, isFalse,
          reason: 'this is exactly why classifying on AVG loses the spike');

      // The extreme does cross it, and the extreme is what the screen reads.
      expect(w.maxPvlt, 15.5);
      expect(historyWindowIsFlagged(w, ov: ov), isTrue,
          reason: 'the minute must still reach the "warnings only" list');
    });

    test('one under-voltage second does the same, from the other side',
        () async {
      for (var s = 0; s < 60; s++) {
        await put(
          at: minute.add(Duration(seconds: s)),
          bucketS: 1,
          pvlt: s == 5 ? 10.4 : 13.2,
        );
      }
      final w = (await history.queryListBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;
      expect(w.sample.pvlt! < 11.5, isFalse);
      expect(w.minPvlt, 10.4);
      expect(historyWindowIsFlagged(w, uv: 11.5), isTrue);
    });

    test('one hot second does the same for temperature', () async {
      for (var s = 0; s < 60; s++) {
        await put(
          at: minute.add(Duration(seconds: s)),
          bucketS: 1,
          pvlt: 13.2,
          temperature: s == 11 ? 71 : 28,
        );
      }
      final w = (await history.queryListBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;
      expect(w.sample.temperatureC, 29, reason: 'the mean is unremarkable');
      expect(w.maxTemp, 71);
      expect(historyWindowIsFlagged(w, ot: 60), isTrue);
    });

    test('a quiet minute is still quiet — the rule does not flag everything',
        () async {
      for (var s = 0; s < 60; s++) {
        await put(at: minute.add(Duration(seconds: s)), bucketS: 1, pvlt: 13.2);
      }
      final w = (await history.queryListBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;
      expect(historyWindowIsFlagged(w, ov: 15.0, uv: 11.5, ot: 60), isFalse);
    });

    test('one second of cut-off makes the whole minute an event', () async {
      // Discrete, so the question is "did it happen", never "on average".
      for (var s = 0; s < 60; s++) {
        await put(
          at: minute.add(Duration(seconds: s)),
          bucketS: 1,
          pvlt: 13.2,
          mode: s == 44 ? ReportedStatus.cutOffActive : ReportedStatus.normal,
        );
      }
      final w = (await history.queryListBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;
      expect(w.sample.mode, ReportedStatus.cutOffActive);
      expect(historyWindowIsFlagged(w), isTrue);
    });
  });

  group('window means are weighted by `samples`', () {
    test('the 19:26 shape: an unweighted mean would flip the sign', () async {
      // conventions.md's recorded case — one minute stored as four segments
      // with sample counts 405 / 69 / 3 / 56. The three short segments carry a
      // large positive current; the long one carries a small negative current.
      // Unweighted, the four values average POSITIVE; weighted, the minute is
      // negative, which is what actually happened.
      await put(
          at: minute, bucketS: 60, pvlt: 13.0, ampere: -8.0, samples: 405);
      await put(at: minute, bucketS: 60, pvlt: 13.0, ampere: 9.0, samples: 69);
      await put(at: minute, bucketS: 60, pvlt: 13.0, ampere: 12.0, samples: 3);
      await put(at: minute, bucketS: 60, pvlt: 13.0, ampere: 11.0, samples: 56);

      final w = (await history.queryListBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;
      expect(w.rows, 4, reason: 'four stored rows, one displayed window');
      expect(w.samples, 533);

      const unweighted = (-8.0 + 9.0 + 12.0 + 11.0) / 4; // +6.0
      expect(unweighted > 0, isTrue);
      // (-8*405 + 9*69 + 12*3 + 11*56) / 533
      expect(w.sample.current, closeTo(-1967 / 533, 1e-9));
      expect(w.sample.current! < 0, isTrue,
          reason: 'weighting by `samples` is what keeps the sign honest');
    });

    test('a segment with no reading contributes no weight', () async {
      await put(at: minute, bucketS: 60, pvlt: 13.0, samples: 100);
      await put(at: minute, bucketS: 60, pvlt: null, samples: 900);
      final w = (await history.queryListBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;
      expect(w.sample.pvlt, closeTo(13.0, 1e-9),
          reason: 'a null is not a zero — it dilutes nothing');
    });
  });

  group('mixed granularity', () {
    test('a legacy minute row and new second rows share one window', () async {
      await put(at: minute, bucketS: 60, pvlt: 13.0, samples: 500);
      for (var s = 30; s < 40; s++) {
        await put(
            at: minute.add(Duration(seconds: s)),
            bucketS: 1,
            pvlt: 14.0,
            samples: 5);
      }
      final w = (await history.queryListBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;
      expect(w.rows, 11);
      expect(w.samples, 550);
      // 500 snapshots at 13 V against 50 at 14 V.
      expect(w.sample.pvlt, closeTo((13.0 * 500 + 14.0 * 50) / 550, 1e-9));
    });

    test('two units in the same minute never merge', () async {
      await put(at: minute, bucketS: 1, pvlt: 13.6, deviceId: 'AA');
      await put(at: minute, bucketS: 1, pvlt: 3.9, deviceId: 'BB');
      final rows =
          await history.queryListBuckets(bucketMs: 60000, tzOffsetMs: 0);
      expect(rows, hasLength(2));
      expect(rows.map((r) => r.deviceId).toSet(), {'AA', 'BB'});
    });
  });

  group('buckets align to the LOCAL day (T13 / Q6)', () {
    // 2026-08-01 23:30 UTC. At UTC+8 that is 2026-08-02 07:30 local, so a
    // 24-hour bucket must file it under 08/02 — the defect this fixes filed it
    // under 08/01, because the boundary was UTC midnight.
    final late = DateTime.utc(2026, 8, 1, 23, 30);
    const day = 24 * 3600000;
    const utcPlus8 = 8 * 3600000;

    test('the same row lands in different days seen from different zones',
        () async {
      await put(at: late, bucketS: 1, pvlt: 13.0);

      final utc = await history
          .queryBuckets(bucketMs: day, deviceId: 'AA', tzOffsetMs: 0);
      final taipei = await history
          .queryBuckets(bucketMs: day, deviceId: 'AA', tzOffsetMs: utcPlus8);

      expect(utc.single.at.toUtc(), DateTime.utc(2026, 8, 1));
      // 2026-08-02 00:00 local == 2026-08-01 16:00 UTC.
      expect(taipei.single.at.toUtc(), DateTime.utc(2026, 8, 1, 16));

      // 🔑 Both are correct. "The same data buckets differently in another time
      // zone" is the intended behaviour (design 0061 §3.13.1 (b)) — the chart
      // answers "which day did I, HERE, see this on".
    });

    test('a local day is cut at local midnight, not at 08:00', () async {
      // One row just before local midnight and one just after, at UTC+8.
      await put(
          at: DateTime.utc(2026, 8, 1, 15, 59), bucketS: 1, pvlt: 13.0); // 23:59
      await put(
          at: DateTime.utc(2026, 8, 1, 16, 1), bucketS: 1, pvlt: 14.0); // 00:01
      final b = await history
          .queryBuckets(bucketMs: day, deviceId: 'AA', tzOffsetMs: utcPlus8);
      expect(b, hasLength(2), reason: 'they belong to two different local days');
      expect(b.first.at.toUtc(), DateTime.utc(2026, 7, 31, 16));
      expect(b.last.at.toUtc(), DateTime.utc(2026, 8, 1, 16));
    });

    test('the list groups on the same boundary the chart does', () async {
      await put(
          at: DateTime.utc(2026, 8, 1, 15, 59, 30), bucketS: 1, pvlt: 13.0);
      await put(
          at: DateTime.utc(2026, 8, 1, 15, 59, 50), bucketS: 1, pvlt: 13.4);
      final rows = await history.queryListBuckets(
          bucketMs: 60000, deviceId: 'AA', tzOffsetMs: utcPlus8);
      expect(rows, hasLength(1));
      // A whole-minute window is unaffected by a whole-hour offset — asserted
      // so that a future offset in minutes (there are such zones) is a visible
      // change rather than a silent one.
      expect(rows.single.sample.timestamp.toUtc(),
          DateTime.utc(2026, 8, 1, 15, 59));
    });
  });

  test('newest window first, and the cap counts WINDOWS', () async {
    for (var m = 0; m < 5; m++) {
      for (var s = 0; s < 60; s++) {
        await put(
            at: minute.add(Duration(minutes: m, seconds: s)),
            bucketS: 1,
            pvlt: 13.0 + m);
      }
    }
    final rows = await history.queryListBuckets(
        bucketMs: 60000, limit: 2, deviceId: 'AA', tzOffsetMs: 0);
    expect(rows, hasLength(2),
        reason: '300 stored rows, 5 windows, capped at 2 WINDOWS');
    expect(rows.first.sample.timestamp.toUtc(),
        minute.add(const Duration(minutes: 4)));
    expect(rows.last.sample.timestamp.toUtc(),
        minute.add(const Duration(minutes: 3)));
  });
}
