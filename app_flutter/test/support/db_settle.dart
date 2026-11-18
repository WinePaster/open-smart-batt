// Waiting for the database without guessing how long it takes.
//
// Widget tests run in fake time; sqflite_common_ffi answers in real time on
// another thread. The old way to bridge the two was a fixed real-time sleep —
// `tester.runAsync(() => Future.delayed(Duration(milliseconds: 20–200)))` —
// which is a guess, and on a slower machine (the 4-core CI runner, or this
// one with its CPU saturated) the guess loses: the result is not on screen
// yet, or the test ends with a query still queued behind the database lock
// (sqflite's 10 s lock-warning timer then shows up as "A Timer is still
// pending even after the widget tree was disposed").
//
// The barrier: every operation on one sqflite connection goes through the same
// lock, in order (`sqflite_common` `txnSynchronized`). So a `SELECT 1` sent
// now returns only after everything queued before it has finished — however
// long that takes. One round = wait for the barrier in real time, then pump so
// the results reach the tree; a rebuild may queue more, hence a few rounds.
//
// Root repo: docs/knowledges/flutter-test-db-timing.md.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Real time: wait until [pending] writes and every operation queued on [db]
/// so far have finished. Call it inside `tester.runAsync`, or directly from a
/// plain `test` (which already runs in real time).
///
/// A closed database has nothing queued: some tests dispose one set of
/// services and build another inside the same test.
Future<void> dbBarrier(Database db, {PendingWrites? pending}) async {
  if (pending != null) await pending.drain();
  if (!db.isOpen) return;
  try {
    await db.rawQuery('SELECT 1');
  } on DatabaseException catch (e) {
    // Closed between the check and the query (dispose is fire-and-forget).
    if (!e.toString().contains('database_closed')) rethrow;
  }
}

/// [dbBarrier] for an [AppServices].
Future<void> servicesBarrier(AppServices s) =>
    dbBarrier(s.appDb.db, pending: s.pending);

/// Widget tests: [rounds] × (database barrier in real time, then one pump of
/// [frame]). Replaces `runAsync(() => Future.delayed(...))` + `pump` pairs.
///
/// Each round carries a chain of awaits one hop further (the pump runs the
/// continuations the barrier released, which may queue the next query), so
/// [rounds] is the length of the longest chain, NOT a time — it does not
/// change with machine speed. Saving a new car (`createCarWithDefaults` →
/// `setDevices` → `load` → pop) needs 6; 10 leaves room. Each round costs
/// well under a millisecond when the queue is empty.
Future<void> settleDb(
  WidgetTester tester,
  AppServices s, {
  int rounds = 10,
  Duration frame = Duration.zero,
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => servicesBarrier(s));
    await tester.pump(frame);
  }
}

/// Widget tests, for waits that are NOT the database (a marker file, a plugin
/// call): pump until [condition] holds, giving real time a turn between
/// pumps; fails after [timeout] of real time, naming what it waited for.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String waitingFor,
  Duration timeout = const Duration(seconds: 10),
  Duration frame = Duration.zero,
}) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > timeout) {
      fail('pumpUntil: still waiting for $waitingFor after $timeout');
    }
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(frame);
  }
}

/// Plain `test`s (real time): [rounds] × (database barrier, then one turn of
/// the event loop so the continuations it released can queue the next
/// query). Replaces a fixed `Future.delayed(Duration(milliseconds: …))`.
Future<void> settleServices(AppServices s, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await servicesBarrier(s);
    await Future<void>.delayed(Duration.zero);
  }
}

/// The services the running test built, for helpers that do not have them in
/// scope (a file's `drain(tester)` / `settle(tester)`). Set it where the file
/// builds its [AppServices]. Each test file runs in its own isolate, so this
/// is per file; a stale (disposed) value is harmless — [dbBarrier] skips a
/// closed database.
AppServices? trackedServices;

/// [settleDb] on [trackedServices].
Future<void> settleTracked(
  WidgetTester tester, {
  int rounds = 10,
  Duration frame = Duration.zero,
}) {
  final s = trackedServices;
  if (s == null) {
    throw StateError('settleTracked: trackedServices is not set — assign it '
        'where this test file builds its AppServices');
  }
  return settleDb(tester, s, rounds: rounds, frame: frame);
}

/// [settleDb] for a test that holds a raw [Database] and no [AppServices].
Future<void> settleRawDb(
  WidgetTester tester,
  Database db, {
  int rounds = 10,
  Duration frame = Duration.zero,
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => dbBarrier(db));
    await tester.pump(frame);
  }
}

/// [settleServices] on [trackedServices] — plain `test`s whose shared
/// `settle()` helper has no services in scope.
Future<void> settleTrackedPlain({int rounds = 10}) {
  final s = trackedServices;
  if (s == null) {
    throw StateError('settleTrackedPlain: trackedServices is not set — assign '
        'it where this test file builds its AppServices');
  }
  return settleServices(s, rounds: rounds);
}
