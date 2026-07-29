// Device attribution starts at `connecting`, and exports admit what they hide.
//
// FB-21 / design 0019. `_session.begin()` used to run only on `link: ready`.
// Notifications are subscribed before `setNotifyValue()` returns, and that call
// can take its full 15 s timeout — so every frame in between was written with
// `device_id = NULL`. In one field capture that was 11.3 % of history samples
// (564 of 5009) plus the entire connect-time block: `connect →`, the GATT dump
// and the characteristic property flags.
//
// Both `_scope()` helpers filter with `device_id = ?`, which excludes NULL. So a
// per-device export dropped all of it and said nothing — the same class of
// silent loss design 0009 set out to end, entering through a different door.
// Worse, those orphan rows are what made the TWF misreading possible: they are
// the "mixed units, no attribution" capture that FB-22 was derived from.
//
// Two properties are pinned here: attribution begins early enough to catch the
// subscribe window, and it does NOT begin so early that packets from a previous
// device get filed under the next one.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/session_context.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('SessionContext semantics the early start relies on', () {
    test('re-entering with the same device keeps one session', () {
      // `connecting` → `connected` → `ready` all call begin(). One connection
      // must not become three sessions.
      final s = SessionContext();
      s.begin('AA');
      final first = s.sessionId;
      s.begin('AA');
      s.begin('AA');
      expect(s.sessionId, first);
      expect(s.deviceId, 'AA');
    });

    test('switching device allocates a new session immediately', () {
      // This is the self-correction that makes an early start safe when two
      // connects interleave.
      final s = SessionContext();
      s.begin('AA');
      final first = s.sessionId;
      s.begin('BB');
      expect(s.deviceId, 'BB');
      expect(s.sessionId, isNot(first));
    });

    test('end() clears attribution so later rows are not misfiled', () {
      final s = SessionContext();
      s.begin('AA');
      s.end();
      expect(s.deviceId, isNull);
      expect(s.sessionId, isNull);
    });

    test('session ids never repeat across attempts', () {
      // Failed attempts now get ids too, so `connections=N` finally counts
      // attempts rather than successes. Ids must stay unique for the export's
      // per-session sectioning to hold.
      final s = SessionContext();
      final seen = <int>{};
      for (final id in ['AA', 'BB', 'AA', 'CC', 'AA']) {
        s.begin(id);
        seen.add(s.sessionId!);
      }
      expect(seen.length, 5);
    });
  });

  group('exports state what they excluded', () {
    late AppDatabase db;
    late HistoryRepo history;
    late LogRepo logs;

    setUp(() async {
      db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      history = HistoryRepo(db.db);
      logs = LogRepo(db.db);
    });

    tearDown(() async => db.close());

    TelemetrySample sample(DateTime at) =>
        TelemetrySample(timestamp: at, pvlt: 13.2, twfRaw: 0x00);

    test('a per-device CSV names the orphan rows it cannot show', () async {
      final t = DateTime.utc(2026, 7, 29, 12);
      await history.insertSample(sample(t), deviceId: 'AA', samples: 10);
      // Two rows written before attribution existed — the pre-fix state.
      await history.insertSample(sample(t), deviceId: null, samples: 3);
      await history.insertSample(sample(t), deviceId: null, samples: 4);

      final out = await history.exportCsv(
        deviceId: 'AA',
        header: const ['scope: device=AA'],
      );
      expect(out.rows, 1, reason: 'only the attributed row is in the body');
      expect(out.text, contains('excluded: 2 unattributed rows'));
    });

    test('a clean export says nothing rather than "excluded: 0"', () async {
      final t = DateTime.utc(2026, 7, 29, 12);
      await history.insertSample(sample(t), deviceId: 'AA', samples: 10);

      final out = await history.exportCsv(
        deviceId: 'AA',
        header: const ['scope: device=AA'],
      );
      expect(out.text, isNot(contains('excluded')));
    });

    test('an all-devices CSV keeps the orphans, so it reports none excluded',
        () async {
      final t = DateTime.utc(2026, 7, 29, 12);
      await history.insertSample(sample(t), deviceId: 'AA', samples: 10);
      await history.insertSample(sample(t), deviceId: null, samples: 3);

      final out = await history.exportCsv(header: const ['scope: all devices']);
      expect(out.rows, 2);
      expect(out.text, isNot(contains('excluded')));
      // It already had a way to say this, and still does.
      expect(out.text, contains('(+unattributed)'));
    });

    test('the log export gained a row count and the same exclusion note',
        () async {
      await logs.insertLog(LogEntry.event('link: ready', deviceId: 'AA'));
      await logs.insertLog(LogEntry.event('scan start'));
      await logs.insertLog(LogEntry.event('GATT dump: 2 service(s)'));

      final scoped =
          await logs.exportLog(deviceId: 'AA', header: const ['scope: AA']);
      expect(scoped, contains('rows: 1'));
      expect(scoped, contains('excluded: 2 unattributed rows'));

      final all = await logs.exportLog(header: const ['scope: all']);
      expect(all, contains('rows: 3'));
      expect(all, isNot(contains('excluded')));
    });

    test('no header means no summary — a raw blob stays a raw blob', () async {
      await logs.insertLog(LogEntry.event('link: ready', deviceId: 'AA'));
      await logs.insertLog(LogEntry.event('scan start'));
      final out = await logs.exportLog(deviceId: 'AA');
      expect(out, isNot(contains('rows:')));
      expect(out, isNot(contains('excluded')));
    });
  });
}
