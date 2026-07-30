// Teardown race: fire-and-forget DB writes outliving the database.
//
// THE BUG THIS PINS DOWN. `flutter test` failed intermittently — ~2 runs in 13
// of the full suite, never when a file ran alone — with:
//
//   DatabaseException(error database_closed)
//     LogRepo.approxBytes  (log_repo.dart:95)
//     LogRepo.trimToBytes  (log_repo.dart:238)
//     LogRepo.insertLog    (log_repo.dart:29)
//     <asynchronous suspension>
//
// `insertLog` is two steps: insert the row, suspend, then trim the log back
// under its byte cap with a second query. Fired via a bare `unawaited(...)`
// from TelemetryController, it could resume that second step after
// `AppServices.dispose()` had already run `appDb.close()`.
//
// It looked like a haunted test — the framework blames whichever test is
// running when the stray future lands, so it moved around the suite. It is a
// real teardown race, and on a real device it silently drops the last log rows
// written before shutdown.
//
// The two halves are tested separately: PendingWrites as pure async plumbing,
// then the real AppServices teardown against a real (in-memory) database.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';

void main() {
  group('PendingWrites', () {
    test('drain waits for a registered write', () async {
      final pending = PendingWrites();
      var done = false;
      final c = Completer<void>();
      pending.add(c.future.then((_) => done = true));

      expect(pending.length, 1);
      expect(done, isFalse);

      // Nothing may finish the drain while the write is outstanding.
      var drained = false;
      unawaited(pending.drain().then((_) => drained = true));
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse, reason: 'drain returned before the write did');

      c.complete();
      await pending.drain();
      expect(done, isTrue);
      expect(pending.isEmpty, isTrue);
    });

    test('a completed write is forgotten', () async {
      final pending = PendingWrites();
      pending.add(Future<void>.value());
      await pending.drain();
      expect(pending.length, 0);
    });

    test('drain also waits for a write registered by a completing write',
        () async {
      // The reason drain loops instead of awaiting one batch: returning while a
      // successor is live would reopen the race.
      final pending = PendingWrites();
      var secondDone = false;
      final gate = Completer<void>();
      final second = Completer<void>();

      pending.add(gate.future.then((_) {
        pending.add(second.future.then((_) => secondDone = true));
      }));

      var drained = false;
      unawaited(pending.drain().then((_) => drained = true));

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse, reason: 'drain returned mid-chain');
      expect(secondDone, isFalse);

      second.complete();
      await pending.drain();
      expect(secondDone, isTrue);
      expect(pending.isEmpty, isTrue);
    });

    test('a failing write does not break drain', () async {
      final pending = PendingWrites();
      // Registered errors still reach the Zone (that is deliberate — see
      // PendingWrites.add), so run this where an unhandled one is tolerated.
      await runZonedGuarded(() async {
        pending.add(Future<void>.error(StateError('boom')));
        await pending.drain();
      }, (_, _) {});
      expect(pending.isEmpty, isTrue);
    });

    test('drain reports success when everything finished', () async {
      final pending = PendingWrites();
      pending.add(Future<void>.delayed(const Duration(milliseconds: 5)));
      expect(await pending.drain(), isTrue);
      expect(pending.isEmpty, isTrue);
    });

    test('drain gives up on a wedged write instead of hanging forever',
        () async {
      final pending = PendingWrites();
      final wedged = Completer<void>();
      pending.add(wedged.future);

      // Without a deadline this call never returns and takes app shutdown with
      // it — an intermittent exception traded for a permanent hang.
      final drained =
          await pending.drain(timeout: const Duration(milliseconds: 20));

      expect(drained, isFalse, reason: 'a wedged write must not report success');
      expect(pending.isEmpty, isFalse,
          reason: 'giving up does not un-register the write');

      // Release it so the test does not leak a pending future.
      wedged.complete();
      await pending.drain();
      expect(pending.isEmpty, isTrue);
    });

    test('the timeout is an overall deadline, not per-iteration', () async {
      final pending = PendingWrites();
      // Each write registers a successor as it completes, so a per-iteration
      // timeout would keep resetting and never expire.
      void chain(int depth) {
        if (depth == 0) return;
        pending.add(Future<void>.delayed(const Duration(milliseconds: 10))
            .whenComplete(() => chain(depth - 1)));
      }

      chain(50);
      final elapsed = Stopwatch()..start();
      final drained =
          await pending.drain(timeout: const Duration(milliseconds: 50));
      elapsed.stop();

      expect(drained, isFalse);
      expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 400)),
          reason: 'the deadline must bound the whole loop');
    });

    test('an error landing during a drain is swallowed, not sent to the Zone',
        () async {
      // This is the one place PendingWrites does NOT match `unawaited(...)`.
      // Asserted so the difference stays deliberate: no runZonedGuarded here,
      // so an escaping error would fail this test.
      final pending = PendingWrites();
      final late = Completer<void>();
      pending.add(late.future);

      final draining = pending.drain();
      late.completeError(StateError('failed on the way out'));

      expect(await draining, isTrue);
      expect(pending.isEmpty, isTrue);
    });
  });

  group('AppServices teardown', () {
    setUpAll(sqfliteFfiInit);

    test('an in-flight two-step insertLog survives dispose', () async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final logs = LogRepo(appDb.db);
      final pending = PendingWrites();

      // Exactly the shape from the stack trace: maxBytes forces the second
      // step (trimToBytes → approxBytes) to run after an await.
      for (var i = 0; i < 40; i++) {
        pending.add(logs.insertLog(
          LogEntry.event('row $i', appBuild: 'test'),
          maxBytes: 256,
        ));
      }

      // This is the fix: drain before close. Without it the writes resume
      // against a closed DB and throw database_closed.
      await pending.drain();
      await appDb.close();

      // Give any straggler a chance to land on the closed DB and blow up. If
      // the drain were incomplete, this is where it would surface.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(pending.isEmpty, isTrue);
    });

    test('closing without draining is what threw — the race is real', () async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final logs = LogRepo(appDb.db);

      // Deliberately NOT tracked, reproducing the old `unawaited(...)` path.
      // The handler is attached at creation, not after the close: an untracked
      // write is unobserved by definition, and letting it reach the Zone here
      // would fail this test with the very error it is documenting — which is
      // exactly how the bug presented in the first place.
      Object? caught;
      final stray = logs
          .insertLog(LogEntry.event('stray', appBuild: 'test'), maxBytes: 1)
          .then<void>((_) {}, onError: (Object e) => caught = e);

      await appDb.close();
      await stray;

      // Conditional by design: whether the second step lands before or after
      // close() is a scheduling question, which is why the suite flaked rather
      // than failing outright. What is asserted is the identity of the failure
      // when it does happen — nothing else may come out of this path.
      if (caught != null) {
        expect('$caught', contains('database_closed'));
      }
    });
  });
}
