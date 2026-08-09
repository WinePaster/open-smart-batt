// One row per (device, minute) — design 0048.
//
// The controller flushes a partial minute whenever the app may lose control of
// its own execution (`app paused` / `app hidden` / `link: disconnected`), so a
// single minute reaches storage in several segments. Each segment used to
// become its own row with the same timestamp, and since the history screen
// renders `HH:mm:ss` — and every segment carries `:00` — the user saw identical
// duplicate lines. A real capture (0.7.5, iOS) held four rows stamped
// `09:50:00` with samples 3 / 27 / 3 / 272, matching three flush triggers plus
// the minute rollover.
//
// Corpus-wide this was 447 duplicate groups over 10,425 (4.29 %), present in
// every build that has ever been sampled — it was never a regression.
//
// What is pinned here: segments merge, the merge is weighted so it is exact,
// nulls carry no weight, the (device, minute) key is respected in both
// directions, and rows written by older builds are left alone.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
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

  final minute = DateTime.utc(2026, 8, 8, 9, 50);

  Future<List<Map<String, Object?>>> rows() =>
      db.db.query(Db.tableHistory, orderBy: 'id');

  group('segments of one minute become one row', () {
    test('two segments merge, and `samples` is their total', () async {
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA', samples: 3);
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 14.0),
          deviceId: 'AA', samples: 1);

      final r = await rows();
      expect(r, hasLength(1));
      expect(r.single['samples'], 4);
      // Weighted, not the arithmetic mean of the two segment means: a weighted
      // mean of the segments IS the mean of the whole minute, so the merge is
      // exact rather than an approximation. (13*3 + 14*1) / 4.
      expect(r.single['pvlt'], closeTo(13.25, 1e-9));
    });

    test('the real capture: 3 + 27 + 3 + 272 lands as one row of 305', () async {
      for (final (n, v) in [(3, 13.35), (27, 13.3526), (3, 13.35), (272, 13.325)]) {
        await history.insertSample(
            TelemetrySample(timestamp: minute, pvlt: v, temperatureC: 30),
            deviceId: 'AA', samples: n);
      }

      final r = await rows();
      expect(r, hasLength(1));
      expect(r.single['samples'], 305);
      // Dominated by the 272-sample segment, which is the point: the old
      // unweighted view gave a 3-sample segment the same say as a 272-sample
      // one.
      expect(r.single['pvlt'] as double, closeTo(13.3277, 1e-3));
    });

    test('an INTEGER mean is rounded back to an integer', () async {
      await history.insertSample(
          TelemetrySample(timestamp: minute, temperatureC: 30),
          deviceId: 'AA', samples: 3);
      await history.insertSample(
          TelemetrySample(timestamp: minute, temperatureC: 34),
          deviceId: 'AA', samples: 1);

      // (30*3 + 34*1) / 4 = 31.
      expect((await rows()).single['temperature'], 31);
    });
  });

  group('nulls carry no weight', () {
    test('a segment that measured nothing cannot dilute one that did', () async {
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA', samples: 3);
      await history.insertSample(
          TelemetrySample.empty().copyWith(timestamp: minute),
          deviceId: 'AA', samples: 272);

      final r = await rows();
      expect(r, hasLength(1));
      // Untouched — a null is not a zero, and 272 samples of "no reading" must
      // not drag a real 13.0 towards nothing.
      expect(r.single['pvlt'], closeTo(13.0, 1e-9));
      // The count still grows: those samples happened, they just measured no
      // pack voltage.
      expect(r.single['samples'], 275);
    });

    test('a value arriving later fills a column the first segment lacked',
        () async {
      await history.insertSample(
          TelemetrySample.empty().copyWith(timestamp: minute),
          deviceId: 'AA', samples: 3);
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA', samples: 1);

      expect((await rows()).single['pvlt'], closeTo(13.0, 1e-9));
    });

    test('a minute with no GPS sample stays null, never 0.0', () async {
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA', samples: 3);
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA', samples: 3);

      final r = await rows();
      expect(r.single['speed'], isNull);
      expect(r.single['accel'], isNull);
      expect(r.single['g_long'], isNull);
      expect(r.single['g_lat'], isNull);
    });

    test('`samples` is null only when neither side counted', () async {
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA');
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA');

      // Never 0, which would claim the row averaged nothing.
      expect((await rows()).single['samples'], isNull);
    });
  });

  group('metadata', () {
    test('a pause-flush row missing serial/mode gets them from the next segment',
        () async {
      // The §R3 side-effect: the segment flushed on pause had not yet seen the
      // frames carrying identity, so its row showed blank serial and mode while
      // its twin showed them.
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA', samples: 3);
      await history.insertSample(
          TelemetrySample(
              timestamp: minute, pvlt: 13.0, serial: '000013', mode: 0),
          deviceId: 'AA', samples: 27);

      final r = await rows();
      expect(r, hasLength(1));
      expect(r.single['serial'], '000013');
      expect(r.single['mode'], 0);
    });

    test('a later segment does not erase metadata the first one carried',
        () async {
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0, serial: '000013'),
          deviceId: 'AA', samples: 3);
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA', samples: 27);

      expect((await rows()).single['serial'], '000013');
    });
  });

  group('the (device, minute) key', () {
    test('two units in the same minute stay two rows', () async {
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA', samples: 3);
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 9.0),
          deviceId: 'BB', samples: 3);

      expect(await rows(), hasLength(2));
    });

    test('consecutive minutes stay two rows', () async {
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA', samples: 3);
      await history.insertSample(
          TelemetrySample(
              timestamp: minute.add(const Duration(minutes: 1)), pvlt: 13.0),
          deviceId: 'AA', samples: 3);

      expect(await rows(), hasLength(2));
    });

    test('unattributed rows merge with each other, never with an attributed one',
        () async {
      // SQL equality never matches NULL, so the lookup has to say `IS NULL`
      // explicitly or every unattributed segment becomes its own row again.
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: null, samples: 3);
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: null, samples: 4);
      await history.insertSample(
          TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA', samples: 5);

      final r = await rows();
      expect(r, hasLength(2));
      final orphan = r.firstWhere((e) => e['device_id'] == null);
      expect(orphan['samples'], 7);
    });
  });

  test('rows written by older builds are merged into, never rewritten', () async {
    // Design 0048 G2 (2026-08-07 ruling): no migration, "以前的數據錯就錯了".
    // Past minutes may already hold several rows; a new segment joins the
    // newest one and the rest are left exactly as they are.
    final legacy = TelemetrySample(timestamp: minute, pvlt: 13.0);
    for (var i = 0; i < 2; i++) {
      await db.db.insert(Db.tableHistory, {
        ...legacy.toMap(),
        'device_id': 'AA',
        'samples': 10,
      });
    }

    await history.insertSample(
        TelemetrySample(timestamp: minute, pvlt: 14.0),
        deviceId: 'AA', samples: 10);

    final r = await rows();
    expect(r, hasLength(2), reason: 'the duplicate pair is not cleaned up');
    expect(r.first['samples'], 10, reason: 'the older row is untouched');
    expect(r.first['pvlt'], closeTo(13.0, 1e-9));
    expect(r.last['samples'], 20, reason: 'only the newest row absorbed it');
    expect(r.last['pvlt'], closeTo(13.5, 1e-9));
  });
}
