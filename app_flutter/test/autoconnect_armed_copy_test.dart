// FB-20 (2026-08-13 re-report) — the armed autoConnect must not read as idle.
//
// WHAT THIS PINS. `connectionFailureCopy` is a pure function whose BRANCH ORDER
// is its semantics, and for the whole of `autoConnectWatchdog` the controller
// is in a state none of its branches described: the link really is
// `disconnected` (so `isBusy` is false) and no retry timer of ours is pending
// (so `isRetrying` is false). The copy therefore fell through to the idle
// branch, and the screen said "No device connected" — the same words it shows
// when nothing whatsoever is happening.
//
// THE FIELD CASE. `2026.08.13/006`: the link dropped at 21:42:54, the arm
// expired on time at 21:45:55, and the user exported a diagnostic capture 11 s
// later. Three minutes of a screen that said nothing was going on, abandoned
// just before the failure card would have appeared. Note what this is NOT: the
// give-up card has existed since v0.6.16 (`4b5ed62`) and that user was on
// 0.7.15, so the gap was never "no exit at the end" — it was the silence
// before it.
//
// ⚠️ This is the SAME defect FB-53 fixed for the backoff ladder, one path over.
// The comments in `connection_failure.dart` describe it in the ladder's words
// already ("the copy falls back to 'no device connected', the same words shown
// before anyone had tapped anything"); the autoConnect hand-off simply never
// got the same treatment.
//
// CLEAN-ROOM: expectations derive from this project's own source and field
// captures.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/ui/devices/connection_failure.dart';

/// Every argument off, so each test turns on exactly the one it is about.
ConnectionFailureCopy _copy(
  AppLocalizations l10n, {
  String? lastError,
  bool working = false,
  bool isBusy = false,
  bool isRetrying = false,
  bool autoConnectArmed = false,
  bool setupStalled = false,
  int setupFailures = 0,
  int reconnectAttempts = 0,
}) =>
    connectionFailureCopy(
      l10n: l10n,
      lastError: lastError,
      working: working,
      isBusy: isBusy,
      isRetrying: isRetrying,
      autoConnectArmed: autoConnectArmed,
      setupStalled: setupStalled,
      setupFailures: setupFailures,
      reconnectAttempts: reconnectAttempts,
    );

void main() {
  late AppLocalizations en;

  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('an armed autoConnect', () {
    test('does not read as the idle state — the defect, stated', () {
      final idle = _copy(en);
      final armed = _copy(en, autoConnectArmed: true);

      expect(armed.title, isNot(idle.title),
          reason: 'BEFORE THE FIX these were the same string, and a user '
              'three minutes into a wait could not tell the app was doing '
              'anything at all');
      expect(armed.body, isNot(idle.body));
    });

    test('says how long the wait can last, from the constant itself', () {
      final armed = _copy(en, autoConnectArmed: true);

      // Not a hard-coded "3": the copy has to follow the deadline it is
      // describing. If somebody retunes `autoConnectWatchdog`, a stale promise
      // on screen is worse than none.
      expect(armed.body,
          contains('${ConnectionController.autoConnectWatchdog.inMinutes}'));
    });

    test('offers the way out that does not depend on waiting', () {
      // The give-up card's remedy is "scan for it below". A user who does not
      // want to wait out the deadline should not have to discover that by
      // waiting out the deadline.
      expect(_copy(en, autoConnectArmed: true).body, contains('scan'));
    });
  });

  group('branch order — what outranks the armed wait', () {
    test("the user's own tap wins: `connecting` still says Connecting", () {
      // A manual connect during the hand-off puts the link into `connecting`.
      // "Connecting…" is then the truer sentence — our attempt is live, the
      // OS's standing offer is not the thing the user is watching.
      final busy = _copy(en, isBusy: true, working: true);
      final both = _copy(en, isBusy: true, working: true, autoConnectArmed: true);

      expect(both.title, busy.title);
    });

    test('the backoff ladder wins: it can name the attempt, this cannot', () {
      final retrying =
          _copy(en, isRetrying: true, working: true, reconnectAttempts: 2);
      final both = _copy(en,
          isRetrying: true,
          working: true,
          reconnectAttempts: 2,
          autoConnectArmed: true);

      expect(both.title, retrying.title);
    });

    test('a verdict already delivered wins over "still waiting"', () {
      // `autoconnect_timeout` IS this state's own ending. Showing "waiting for
      // the device to come back" next to "could not connect to this device"
      // would be two opposite claims about one episode.
      final gaveUp = _copy(en, lastError: 'autoconnect_timeout');
      final both =
          _copy(en, lastError: 'autoconnect_timeout', autoConnectArmed: true);

      expect(both.title, gaveUp.title);
      expect(both.title, en.disconnectedGaveUpTitle);
    });

    test('the stalled latch still outranks everything', () {
      final stalled = _copy(en, setupStalled: true, setupFailures: 3);
      final both = _copy(en,
          setupStalled: true, setupFailures: 3, autoConnectArmed: true);

      expect(both.title, stalled.title);
      expect(both.title, en.disconnectedStalledTitle);
    });
  });
}
