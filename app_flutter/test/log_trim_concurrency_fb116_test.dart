// FB-116 — the diagnostic log was wiped to zero the first time it hit its cap.
//
// `insertLog` is fired without `await` on the hot path, and each call that
// crossed the cap started its own `trimToBytes`. Every trim read the same
// not-yet-deleted total and deleted ~10 % of it, so the deletions stacked: 20
// in flight ⇒ 0 rows left, and the FB-110 fallback took the capture marks too.
// Field: `2026.10.20/001` (`dropped=1503474`, ~10 MB left of ~100 MiB).
// The pre-existing tests awaited every insert, so trims never overlapped.
//
// CLEAN-ROOM: expectations derive from this project's own source.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late LogRepo logs;

  setUp(() async {
    db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    logs = LogRepo(db.db);
  });
  tearDown(() async => db.close());

  LogEntry packet(int i) => LogEntry.fromBytes(
        LogDirection.rx,
        const [0xB8, 0x19, 0x01, 0x02, 0x04, 0xD4],
        at: DateTime.utc(2026, 10, 20).add(Duration(milliseconds: i)),
      );

  /// 5 marks, then [rows] packets bulk-inserted outside the budget path.
  Future<void> seed(int rows) async {
    for (var m = 0; m < 5; m++) {
      await logs.insertLog(LogEntry.event('${LogRepo.markNotePrefix}m$m'));
    }
    final batch = db.db.batch();
    for (var i = 0; i < rows; i++) {
      batch.insert(Db.tableDiagLog, Map.of(packet(i).toMap())..remove('id'));
    }
    await batch.commit(noResult: true);
  }

  Future<int> marks() async => (await db.db.rawQuery(
          'SELECT COUNT(*) n FROM ${Db.tableDiagLog} '
          "WHERE substr(note, 1, 6) = 'mark: '"))
      .first['n']! as int;

  for (final burst in [1, 20, 50]) {
    test('$burst concurrent inserts crossing the cap trim once, not $burst times',
        () async {
      await seed(20000);
      final cap = await logs.approxBytes();
      await Future.wait([
        for (var i = 0; i < burst; i++)
          logs.insertLog(packet(20000 + i), maxBytes: cap),
      ]);
      final left = await logs.approxBytes();
      // One trim lands just under 90 % of the cap. Stacked trims went to 0.
      expect(left, lessThanOrEqualTo(cap));
      expect(left, greaterThan(cap * 0.85));
      expect(await marks(), 5);
    });
  }

  test('a trim to a different cap queues behind the running one', () async {
    await seed(20000);
    final cap = await logs.approxBytes();
    await Future.wait([
      logs.trimToBytes(cap ~/ 2),
      logs.trimToBytes(cap ~/ 4),
    ]);
    final left = await logs.approxBytes();
    expect(left, lessThanOrEqualTo(cap ~/ 4));
    expect(left, greaterThan((cap ~/ 4) * 0.85));
    expect(await marks(), 5);
  });
}
