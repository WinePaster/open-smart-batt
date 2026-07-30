// Design 0022 — device scope on the History screen (FB-38).
//
// THE REPORT THIS PINS DOWN. feedback_log/2026.07.30/009: "等接回電容時電壓歷史
// 就會有異常". The data was not corrupt — per-device ranges were clean (a
// capacitor 12.42–14.26 V, a power bank 3.77–4.15 V). The SCREEN had no device
// scope: _load() called historyStats / historyBuckets / historyWithDevice with
// no deviceId, so the chart drew 3.7 V beside 14 V and the stats strip reported
// min 3.72 / max 14.26 across both. Scope existed only in the export dialog.
//
// Two properties are locked down here:
//   1. The chart and the stats now honour deviceId, as the list already did.
//      They previously built their own WHERE instead of going through _scope(),
//      which is exactly how the dimension came to exist on one and not the
//      others.
//   2. Scoping must not invent attribution. 23 of that capture's 79 rows (29 %)
//      have no device_id, they span BOTH units' voltages, and they must belong
//      to neither — while remaining countable, so the screen can say how many
//      it is hiding rather than repeating FB-21 one layer up.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  const capacitor = 'DEV-CAP';
  const powerBank = 'DEV-PB';

  late AppDatabase db;
  late HistoryRepo repo;

  // The 009 shape in miniature: a ~14 V unit, a ~4 V unit, and unattributed
  // rows drawn from both.
  setUp(() async {
    db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repo = HistoryRepo(db.db);
    final t0 = DateTime.utc(2026, 7, 30, 10);
    Future<void> add(double pvlt, String? dev, int minute) => repo.insertSample(
          TelemetrySample(
            timestamp: t0.add(Duration(minutes: minute)),
            pvlt: pvlt,
            temperatureC: 30,
          ),
          deviceId: dev,
        );
    await add(14.2, capacitor, 0);
    await add(13.8, capacitor, 1);
    await add(12.9, capacitor, 2);
    await add(4.1, powerBank, 3);
    await add(3.8, powerBank, 4);
    await add(3.7, null, 5); // unattributed, power-bank-shaped
    await add(14.0, null, 6); // unattributed, capacitor-shaped
  });

  tearDown(() async => db.close());

  group('aggregate — the stats strip', () {
    test('unscoped spans every unit, which is what the report showed', () {
      // Reproduces the screenshot: min 3.7 next to max 14.2 on one strip.
      return repo.aggregate().then((s) {
        expect(s.minPvlt, closeTo(3.7, 0.001));
        expect(s.maxPvlt, closeTo(14.2, 0.001));
        expect(s.count, 7);
      });
    });

    test('scoped to one unit stays inside that unit\'s range', () async {
      final cap = await repo.aggregate(deviceId: capacitor);
      expect(cap.minPvlt, closeTo(12.9, 0.001));
      expect(cap.maxPvlt, closeTo(14.2, 0.001));
      expect(cap.count, 3);

      final pb = await repo.aggregate(deviceId: powerBank);
      expect(pb.minPvlt, closeTo(3.8, 0.001));
      expect(pb.maxPvlt, closeTo(4.1, 0.001));
      expect(pb.count, 2);
    });

    test('the unattributed rows belong to NEITHER unit', () async {
      // The one property that must never be traded for a tidier chart: 3.7 V
      // is power-bank-shaped, but nothing licenses attributing it.
      final cap = await repo.aggregate(deviceId: capacitor);
      final pb = await repo.aggregate(deviceId: powerBank);
      expect(cap.count + pb.count, 5, reason: '7 rows, 2 unattributed');
      expect(pb.maxPvlt, lessThan(14.0), reason: 'no 14 V row leaked in');
      expect(cap.minPvlt, greaterThan(4.5), reason: 'no 3.7 V row leaked in');
    });
  });

  group('queryBuckets — the chart', () {
    test('scoping the chart matches scoping the list', () async {
      const oneMinute = 60000;
      final capBuckets =
          await repo.queryBuckets(bucketMs: oneMinute, deviceId: capacitor);
      final capRows = await repo.querySamples(deviceId: capacitor);
      expect(capBuckets.fold<int>(0, (a, b) => a + b.count), capRows.length,
          reason: 'chart and list must cover the same rows');
      for (final b in capBuckets) {
        expect(b.maxPvlt, greaterThan(4.5),
            reason: 'a power-bank voltage reached the capacitor chart');
      }
    });

    test('unscoped still returns everything — no behaviour change by default',
        () async {
      final all = await repo.queryBuckets(bucketMs: 60000);
      expect(all.fold<int>(0, (a, b) => a + b.count), 7);
    });
  });

  group('countUnattributed — say what the scope hides', () {
    test('counts exactly the rows a device scope drops', () async {
      expect(await repo.countUnattributed(), 2);
    });

    test('honours the time range, so the note matches the visible span',
        () async {
      final since = DateTime.utc(2026, 7, 30, 10, 6);
      expect(await repo.countUnattributed(since: since), 1);
    });

    test('a device scope hides exactly the rows this counts', () async {
      final total = (await repo.aggregate()).count;
      final cap = (await repo.aggregate(deviceId: capacitor)).count;
      final pb = (await repo.aggregate(deviceId: powerBank)).count;
      expect(total - cap - pb, await repo.countUnattributed(),
          reason: 'the note must not under-report');
    });
  });
}
