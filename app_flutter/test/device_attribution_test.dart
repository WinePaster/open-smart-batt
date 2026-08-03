// Device attribution starts at `connecting`, and exports admit what they hide.
//
// FB-21. `_session.begin()` used to run only on `link: ready`.
// Notifications are subscribed before `setNotifyValue()` returns, and that call
// can take its full 15 s timeout — so every frame in between was written with
// `device_id = NULL`. In one field capture that was 11.3 % of history samples
// (564 of 5009) plus the entire connect-time block: `connect →`, the GATT dump
// and the characteristic property flags.
//
// Both `_scope()` helpers filter with `device_id = ?`, which excludes NULL. So a
// per-device export dropped all of it and said nothing — the same class of
// silent loss the export-provenance work set out to end — a file has to be able
// to say what it is missing — entering through a different door.
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

    test('a live session is not re-numbered when its unit comes round again',
        () {
      // A session is one CONNECTION, not one begin() call. Without an
      // intervening end(), returning to a unit that still has an open session
      // must reuse its number: with several links alive their interleaved
      // connecting/connected/ready transitions arrive in exactly this pattern,
      // and re-allocating would split one connection into several numbered
      // sessions — section headers for connections that never happened (FB-41).
      final s = SessionContext();
      final ids = <String, int>{};
      for (final id in ['AA', 'BB', 'AA', 'CC', 'AA']) {
        s.begin(id);
        ids.putIfAbsent(id, () => s.sessionId!);
        expect(s.sessionId, ids[id], reason: '$id was re-numbered');
      }
      expect(ids.values.toSet().length, 3, reason: 'three units, three ids');
    });

    test('attempts to the same unit still get distinct ids', () {
      // This is what makes `connections=N` count attempts rather than
      // successes, and it does NOT come from begin(): it comes from end()
      // running on every `disconnected`, which closes the session before the
      // retry begins a new one. Pinned separately from the case above because
      // the two used to be entangled in one condition — a failed attempt and a
      // re-emitted `ready` are not the same event and must not share a rule.
      final s = SessionContext();
      final seen = <int>[];
      for (var attempt = 0; attempt < 3; attempt++) {
        s.begin('AA');
        seen.add(s.sessionId!);
        s.end(); // the attempt failed, or the link dropped
      }
      expect(seen.toSet().length, 3, reason: 'three attempts, three ids');
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

    // The door the attribution fix left open in the CSV exporter, mirroring the
    // same fix in LogRepo: `_scope` filters `device_id = ?`, so ANOTHER unit's rows
    // were dropped and — unlike the unattributed ones — reported nowhere.

    test('a per-device CSV names the rows belonging to other units', () async {
      final t = DateTime.utc(2026, 7, 29, 12);
      await history.insertSample(sample(t), deviceId: 'AA', samples: 10);
      await history.insertSample(sample(t), deviceId: 'BB', samples: 3);
      await history.insertSample(sample(t), deviceId: 'CC', samples: 4);

      final out = await history.exportCsv(
        deviceId: 'AA',
        header: const ['scope: device=AA'],
      );
      expect(out.rows, 1);
      expect(out.text, contains('excluded: 2 rows from other devices'));
      // No unattributed rows here, so that line must stay away rather than
      // appear as "excluded: 0".
      expect(out.text, isNot(contains('unattributed rows')));
    });

    test('the two CSV exclusions are counted separately and account for every '
        'row exactly once', () async {
      final t = DateTime.utc(2026, 7, 29, 12);
      await history.insertSample(sample(t), deviceId: 'AA', samples: 10);
      await history.insertSample(sample(t), deviceId: null, samples: 3);
      await history.insertSample(sample(t), deviceId: null, samples: 4);
      await history.insertSample(sample(t), deviceId: 'BB', samples: 5);

      final out = await history.exportCsv(
        deviceId: 'AA',
        header: const ['scope: device=AA'],
      );
      expect(out.rows, 1);
      expect(out.text, contains('excluded: 2 unattributed rows'));
      expect(out.text, contains('excluded: 1 rows from other devices'));
      // 1 exported + 2 unattributed + 1 other = 4 stored. The partition has to
      // be exact, or the header understates the loss it exists to admit.
      expect(await history.count(), 4);
    });

    test('the other-devices count respects the export time window', () async {
      final t = DateTime.utc(2026, 7, 29, 12);
      final old = t.subtract(const Duration(days: 2));
      await history.insertSample(sample(t), deviceId: 'AA', samples: 10);
      await history.insertSample(sample(t), deviceId: 'BB', samples: 3);
      // Outside the window: it was never going to be in this file, so counting
      // it would describe a loss that did not happen.
      await history.insertSample(sample(old), deviceId: 'BB', samples: 9);

      final out = await history.exportCsv(
        deviceId: 'AA',
        since: t.subtract(const Duration(hours: 1)),
        header: const ['scope: device=AA'],
      );
      expect(out.text, contains('excluded: 1 rows from other devices'));
    });

    test('an all-devices CSV claims no other-device exclusion', () async {
      final t = DateTime.utc(2026, 7, 29, 12);
      await history.insertSample(sample(t), deviceId: 'AA', samples: 10);
      await history.insertSample(sample(t), deviceId: 'BB', samples: 3);

      final out = await history.exportCsv(header: const ['scope: all devices']);
      expect(out.rows, 2);
      expect(out.text, isNot(contains('excluded')));
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

    test('a per-device log export names the OTHER units it dropped too',
        () async {
      // The remaining door. The attribution fix closed the NULL case and left
      // this one:
      // `_scope()` filters `device_id = ?`, so a phone that has watched two
      // packs exported one of them and the file read as if the other had never
      // been connected. Nothing in the preamble said otherwise.
      await logs.insertLog(LogEntry.event('a1', deviceId: 'AA', sessionId: 1));
      await logs.insertLog(LogEntry.event('b1', deviceId: 'BB', sessionId: 2));
      await logs.insertLog(LogEntry.event('b2', deviceId: 'BB', sessionId: 2));

      final out =
          await logs.exportLog(deviceId: 'AA', header: const ['scope: AA']);
      expect(out, contains('rows: 1'));
      expect(out, contains('excluded: 2 rows from other devices'));
      // No unattributed rows exist here, so that line must stay away rather
      // than appear as "excluded: 0".
      expect(out, isNot(contains('unattributed')));
    });

    test('the two exclusions are counted separately, never summed', () async {
      // Collapsing them would hide which is which: "recorded before we knew the
      // unit" is a defect of ours, "belongs to a different unit" is not, and
      // they lead to opposite follow-up questions.
      await logs.insertLog(LogEntry.event('a1', deviceId: 'AA', sessionId: 1));
      await logs.insertLog(LogEntry.event('scan start'));
      await logs.insertLog(LogEntry.event('GATT dump: 2 service(s)'));
      await logs.insertLog(LogEntry.event('b1', deviceId: 'BB', sessionId: 2));

      final out =
          await logs.exportLog(deviceId: 'AA', header: const ['scope: AA']);
      expect(out, contains('excluded: 2 unattributed rows'));
      expect(out, contains('excluded: 1 rows from other devices'));
      // Every row is accounted for exactly once: 1 exported + 2 + 1 = 4 stored.
      expect(await logs.count(), 4);
    });

    test('an all-devices log export drops nothing, so it claims nothing',
        () async {
      await logs.insertLog(LogEntry.event('a1', deviceId: 'AA', sessionId: 1));
      await logs.insertLog(LogEntry.event('b1', deviceId: 'BB', sessionId: 2));
      await logs.insertLog(LogEntry.event('scan start'));

      final out = await logs.exportLog(header: const ['scope: all']);
      expect(out, contains('rows: 3'));
      expect(out, isNot(contains('excluded')));
    });

    test('a session-scoped export still reports the other units', () async {
      // The scope narrows to one connection, but the device-level exclusion is
      // reported scope-wide on purpose: this device's OWN other sessions are
      // already visible as `connections=N`, whereas another unit's rows are not
      // represented anywhere else in the file.
      await logs.insertLog(LogEntry.event('a1', deviceId: 'AA', sessionId: 1));
      await logs.insertLog(LogEntry.event('a2', deviceId: 'AA', sessionId: 2));
      await logs.insertLog(LogEntry.event('b1', deviceId: 'BB', sessionId: 3));

      final out = await logs.exportLog(
        deviceId: 'AA',
        sessionId: 1,
        header: const ['scope: AA session=1'],
      );
      expect(out, contains('rows: 1'));
      expect(out, contains('excluded: 1 rows from other devices'));
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
