// design 0087 / FB-58 — 連不上也要有常駐出口。
//
// WHAT THIS PINS. FB-52 gave a run of failures a card that STAYS. But its
// counter only moves for an attempt that reached `connected` and then never
// said `ready`; a connect that times out eight seconds in never gets that far.
// So a user whose unit simply cannot be found sat in front of the same endless
// spinner FB-52 was built to end — `2026.08.09/003`, four 8 s timeouts out of
// five attempts, `gatt_setup_stalled` at zero throughout.
//
// WHY A STRING WAS NOT ENOUGH. `device_unreachable` already had copy. The
// give-up card is gated on `!working`, and `connect()` clears `lastError` and
// sets `isBusy` — so each manual retry wiped the card mid-read. What was
// missing was a LATCH, and that is what these tests are about.
//
// ⛔ THE ONE THING THIS CARD MUST NOT SAY is the stalled card's remedy
// ("close the app fully and reopen it"). It points the opposite way, and only
// the stalled one has field evidence behind it (ruled 2026-08-03).
//
// CLEAN-ROOM: expectations derive from this project's own source and captures.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/ui/devices/connection_failure.dart';

ConnectionFailureCopy _copy(
  AppLocalizations l10n, {
  String? lastError,
  bool working = false,
  bool setupStalled = false,
  int setupFailures = 0,
  bool unreachableRun = false,
  int reachFailures = 0,
}) =>
    connectionFailureCopy(
      l10n: l10n,
      lastError: lastError,
      working: working,
      isBusy: false,
      isRetrying: false,
      autoConnectArmed: false,
      setupStalled: setupStalled,
      setupFailures: setupFailures,
      reconnectAttempts: 0,
      unreachableRun: unreachableRun,
      reachFailures: reachFailures,
    );

void main() {
  late AppLocalizations en;
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('design 0087 — the unreachable-run card', () {
    test('🔴 the defect, stated: a run of unreachable attempts used to read as idle',
        () {
      final idle = _copy(en);
      final run = _copy(en, unreachableRun: true, reachFailures: 3);
      expect(run.title, isNot(idle.title),
          reason: 'three failures in a row must not look like nothing happening');
      expect(run.adviceHint, isNotNull, reason: 'a stopped attempt owes an exit');
    });

    test('says what to check, and the count', () {
      final c = _copy(en, unreachableRun: true, reachFailures: 3);
      expect(c.body, contains('3'));
      expect(c.adviceHint, contains('nearby'));
      expect(c.adviceHint, contains('powered'));
    });

    test('⛔ never tells the user to restart the app', () {
      final c = _copy(en, unreachableRun: true, reachFailures: 4);
      final all = '${c.title} ${c.body} ${c.adviceHint}'.toLowerCase();
      // That remedy belongs to the stalled card and points the other way.
      expect(all, isNot(contains('reopen')));
      expect(all, isNot(contains('restart')));
      expect(all, isNot(contains('close the app')));
    });

    test('🔑 a manual retry hides it, and it comes back when the retry fails too',
        () {
      // `working` is the whole reason a latch was needed: this is the state
      // during the retry, and the card must yield to it…
      expect(_copy(en, unreachableRun: true, reachFailures: 3, working: true).title,
          isNot(_copy(en, unreachableRun: true, reachFailures: 3).title));
      // …but the LATCH is still set, so it returns the moment work stops —
      // which is exactly what `lastError` alone could not do.
      expect(_copy(en, unreachableRun: true, reachFailures: 3).adviceHint,
          isNotNull);
    });

    test('🔴 the stalled card wins when both latches are set', () {
      final both = _copy(en,
          setupStalled: true,
          setupFailures: 3,
          unreachableRun: true,
          reachFailures: 3);
      final stalledOnly = _copy(en, setupStalled: true, setupFailures: 3);
      expect(both.title, stalledOnly.title,
          reason: 'only the stalled remedy has field evidence behind it');
    });

    test('off by default — a call site that never heard of 0087 gets no card',
        () {
      // The parameters are optional on purpose: a third call site added later
      // fails safe (no card) rather than compiling into a wrong one.
      final c = connectionFailureCopy(
        l10n: en,
        lastError: null,
        working: false,
        isBusy: false,
        isRetrying: false,
        autoConnectArmed: false,
        setupStalled: false,
        setupFailures: 0,
        reconnectAttempts: 0,
      );
      expect(c.title, _copy(en).title);
    });
  });

  group('design 0087 §3.4 — which codes may latch', () {
    test('the three reach failures are counted, the radio refusals are not', () {
      // ⛔ Bluetooth off / permission denied must never raise this card: its
      // advice is three things you cannot do with the radio down.
      expect(ConnectionController.kReachFailureCodes,
          {'device_unreachable', 'connect_failed', 'device_stale'});
      for (final refusal in ['bluetooth_off', 'permission_denied', 'unauthorized']) {
        expect(ConnectionController.kReachFailureCodes.contains(refusal), isFalse,
            reason: '$refusal is about the phone, not the unit');
      }
    });

    test('the threshold matches the setup latch, so both kinds give up together',
        () {
      expect(ConnectionController.maxReachFailures,
          ConnectionController.maxSetupFailures,
          reason:
              'a user should not have to know WHICH kind of failure they hit');
    });
  });
}
