/// OpenSmartBatt — in-flight fire-and-forget database work.
///
/// Several hot paths write to SQLite without awaiting the result: telemetry
/// samples, diagnostic log rows, device `lastSeen` touches. Awaiting them would
/// stall the BLE notification handler for no benefit, so they are fired and
/// forgotten — but "forgotten" then means *nobody can tell when they finish*,
/// and shutdown closes the database out from under them.
///
/// 🔴 **The bug this exists to fix.** `LogRepo.insertLog` is a two-step
/// operation: insert the row, suspend, then `trimToBytes` → `approxBytes`,
/// which issues a second query. Fired via a bare `unawaited(...)`, it could
/// resume its second step *after* `AppServices.dispose()` had already run
/// `appDb.close()`, and sqflite threw:
///
/// ```
/// DatabaseException(error database_closed)
///   LogRepo.approxBytes  (log_repo.dart:95)
///   LogRepo.trimToBytes  (log_repo.dart:238)
///   LogRepo.insertLog    (log_repo.dart:29)
///   <asynchronous suspension>
/// ```
///
/// It surfaced as an intermittent test failure — ~2 runs in 13 of the full
/// suite, never when a file ran alone, and blamed on whichever test happened to
/// be running when the stray future landed. That made it look like a haunted
/// test rather than what it is: a real teardown race, one that also drops the
/// final log rows on app shutdown.
///
/// Register such a write with [add] and shutdown can [drain] before closing the
/// database.
library;

import 'dart:async';

/// Tracks fire-and-forget database writes so teardown can wait for them.
///
/// Not a queue and not a scheduler: registered futures are already running.
/// This only remembers which ones have not finished yet.
class PendingWrites {
  final Set<Future<void>> _inFlight = <Future<void>>{};

  /// How many registered writes are still in flight. For tests and diagnostics.
  int get length => _inFlight.length;

  /// Whether anything is still running.
  bool get isEmpty => _inFlight.isEmpty;

  /// How long [drain] waits before giving up and letting teardown proceed.
  static const Duration defaultTimeout = Duration(seconds: 5);

  /// Register an already-started [future] so [drain] will wait for it.
  ///
  /// **While no drain is running**, error semantics are identical to the bare
  /// `unawaited(future)` this replaces: a failure surfaces as an unhandled
  /// error on the current [Zone], so nothing that used to be reported becomes
  /// silent. See [drain] for the one case where that is not true.
  void add(Future<void> future) {
    late final Future<void> tracked;
    tracked = future.whenComplete(() => _inFlight.remove(tracked));
    _inFlight.add(tracked);
    // Keep the old unobserved-error behaviour rather than swallowing it here.
    unawaited(tracked);
  }

  /// Wait until no registered write is in flight. Returns `true` if everything
  /// finished, `false` if [timeout] elapsed first.
  ///
  /// Loops rather than awaiting one batch: a write may register another as it
  /// completes, and returning while that successor is live would reopen the
  /// very race this class closes.
  ///
  /// ⚠️ **The timeout is not optional in spirit.** Without a deadline the loop
  /// is unbounded, so one wedged write would hang `AppServices.dispose()`
  /// forever — trading an intermittent exception for a hung shutdown, which is
  /// worse. On expiry we give up and let the caller close the database; the
  /// stray write may then throw exactly the `database_closed` this class
  /// exists to prevent, but bounded to the case where something was already
  /// broken.
  ///
  /// ⚠️ **Errors landing during a drain are swallowed**, unlike at any other
  /// time: attaching `catchError` here observes the failure, so it does not
  /// reach the [Zone]. That is deliberate — a write failing *because* we are
  /// shutting down should not crash the app on its way out — but it is a real
  /// difference from [add]'s behaviour, not the "semantics unchanged" this
  /// class claimed when it was first written.
  Future<bool> drain({Duration timeout = defaultTimeout}) async {
    final elapsed = Stopwatch()..start();
    while (_inFlight.isNotEmpty) {
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) return false;
      try {
        await Future.wait(
          _inFlight.map((f) => f.catchError((Object _) {})).toList(),
        ).timeout(remaining);
      } on TimeoutException {
        return false;
      }
    }
    return true;
  }
}
