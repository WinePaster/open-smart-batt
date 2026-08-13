// FB-66 / FB-67 — the autoConnect watchdog when the isolate is not running.
//
// ⚠️ THIS FILE CHANGED MEANING ON 2026-08-13. ⚠️
//
// It began as a characterization test: every assertion pinned the DEFECT, so a
// green run meant "the bug is still exactly the bug we documented". FB-66 has
// now been FIXED, and group 甲 has been inverted accordingly — it asserts the
// remedy. Group 乙 has NOT been fixed (that is FB-67, a separate number, not
// ruled on) and is still characterization: green there still means "the defect
// is unchanged".
//
// ---------------------------------------------------------------------------
// 甲 — the event loop is frozen (FB-66, FIXED)
// ---------------------------------------------------------------------------
//
// `_armAutoConnect` hands a dropped healthy link to CoreBluetooth and gives the
// hand-off a deadline (`connection_controller.dart`, `autoConnectWatchdog` =
// 180 s). That deadline used to be a plain `Timer` and nothing else. A `Timer`
// is a promise made by the Dart isolate's own event loop, and iOS suspends that
// event loop the moment the app leaves the foreground — the timer was not
// "late", it was not running at all, and it resumed only when the process was
// next scheduled. Field measurements put the overshoot at 1.5× to 23× the
// nominal 180 s, the worst being a process that was demonstrably alive,
// backgrounded for 68.8 minutes, and had still not fired at 4,132 s.
//
// The fix keeps the timer for the foreground case and adds three things, and
// this group tests all three (they are FB-66's three acceptance criteria):
//
//   ①  a wall-clock stamp (`clock.now()` at arm time) that every verdict
//      recomputes against, plus a check at `onAppResumed` — the one moment the
//      isolate is guaranteed to run again, and previously the one moment the
//      watchdog was blind to, because `onAppResumed` opened with
//      `if (!isOnline) return;`.
//   ②  a short grace on any verdict reached at a thaw, so a `connected` that is
//      in flight from the platform when the overdue callback runs is not
//      cancelled by it. `2026-08-12 10:10:38` is the case: the late verdict
//      dropped a link that arrived 4 ms later.
//   ③  the give-up line reports the MEASURED wait. It used to interpolate the
//      constant and print `gave up after 180s` for a 935 s wait.
//
// The freeze itself is modelled with `package:fake_async`'s `elapseBlocking`,
// the only primitive available that advances the clock without running
// anything. It is also why `clock.now()` was the clock chosen in `lib/`:
// `fake_async` substitutes `package:clock`'s clock, so the fix is observable
// here at all. See `_autoConnectArmedAt`'s doc comment for why a monotonic
// `Stopwatch` was rejected.
//
// ---------------------------------------------------------------------------
// 乙 — the process is reclaimed (FB-67 — FIXED by design 0060; these tests now
//      pin the NO-PERSISTENCE boundary, not the product)
// ---------------------------------------------------------------------------
//
// ⚠️ READ THIS BEFORE BELIEVING THE `DEFECT:` LABELS BELOW. They were written
// on 2026-08-13 while FB-67 was still open, and they are still green — but NOT
// because the product still behaves this way. `ConnectionController` now takes
// an optional `autoConnectArm` repo (design 0060 Phase 0); the harness in THIS
// file does not wire one, and a controller without that repo is exactly the
// pre-0060 controller. So what these three tests pin today is the BOUNDARY
// CASE — "with no persistence layer, an armed hand-off dies with the process"
// — which is worth keeping precisely because it is the thing the repo has to
// defeat.
//
// 🔑 The product path — arm row written, cold start reconciled, adoption,
// silence when the hand-off converged — is covered in
// `autoconnect_arm_persistence_test.dart`. If you are here to ask "is FB-67
// fixed?", that file is the answer, not this group.
//
// The original defect, for context: iOS kills a suspended app under memory
// pressure; the next launch is a cold start. There was no state anywhere — not
// in memory, not on disk, not read back from the diagnostic log — from which a
// fresh `ConnectionController` could learn that an autoConnect was ever armed,
// so the deadline was not late, it was gone. FB-66's remedy is of no help whatsoever: there is no process to wake up
// and compare a stamp. These three tests are unchanged and still pin a defect.
//
// ---------------------------------------------------------------------------
// Why the existing tests could not see any of this
// ---------------------------------------------------------------------------
//
// `test/phantom_disconnect_test.dart` §R4 has nine tests on this same watchdog
// and all nine are `testWidgets` + `await tester.pump(autoConnectWatchdog ± 1s)`.
// `pump(d)` advances the `AutomatedTestWidgetsFlutterBinding` fake clock AND
// runs everything that came due during `d`, in one indivisible step. Under that
// API a timer is punctual by construction: there is no way to express "three
// hundred seconds passed and no callback ran". Before this file, the string
// `elapseBlocking` did not appear anywhere in `test/`.
//
// That is the real finding. The R4 tests are not wrong — the reducer logic they
// pin is fine, and all nine still pass against the fix — they are simply blind
// to the axis the bug lives on, and their green had been read as coverage of a
// deadline that had never once been observed firing on a backgrounded iPhone.
//
// CLEAN-ROOM: every expectation derives from this project's own source and its
// own field captures.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';

// ---------------------------------------------------------------------------
// Harness — deliberately the same shape and the same names as the one in
// `phantom_disconnect_test.dart`, so the two files read as one body of work.
// It is copied rather than shared because those declarations are file-private
// there and this change was scoped to adding a single test file; if a third
// file ever needs them, that is the moment to lift all three into
// `test/support/`.
//
// The one deliberate difference: `_Harness` here accepts an existing log repo,
// because scenario 乙 needs one store to outlive the controller that wrote to
// it — that is what makes it a model of a process restart rather than of two
// unrelated apps.
// ---------------------------------------------------------------------------

/// Records the always-on event lines instead of writing them.
class _CapturingLogRepo implements LogRepo {
  final List<String> notes = <String>[];

  @override
  Future<int> insertLog(LogEntry entry, {int? maxBytes}) async {
    notes.add(entry.note ?? '');
    return notes.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubSettingsRepo implements SettingsRepo {
  @override
  Future<AppSettings> loadSettings() async => AppSettings.defaults;

  @override
  Future<void> saveSettings(AppSettings settings) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  int connectCalls = 0;
  int autoConnectCalls = 0;
  int disconnectCalls = 0;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<String> get diagnostics => const Stream<String>.empty();

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    connectCalls++;
    if (autoConnect) autoConnectCalls++;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

/// Everything one controller test needs, and nothing that needs an event loop
/// of its own — here the point is stronger than in `phantom_disconnect_test`:
/// the fake clock must be the only clock, because the whole subject is what
/// happens when that clock and the event loop come apart.
class _Harness {
  _Harness({_CapturingLogRepo? logs})
      : ble = _FakeBle(),
        logs = logs ?? _CapturingLogRepo() {
    conn = ConnectionController(
      ble,
      settings: SettingsController(_StubSettingsRepo()),
      logs: this.logs,
    );
  }

  final _FakeBle ble;
  final _CapturingLogRepo logs;
  late final ConnectionController conn;
  bool _disposed = false;

  /// Every `gave up` line this controller has written. One per episode is the
  /// contract `phantom_disconnect_test` §R3/§R4 pins; counting them is how a
  /// missing episode and a doubled one are told apart.
  Iterable<String> get gaveUpLines =>
      logs.notes.where((n) => n.startsWith('auto-reconnect: autoConnect '
          'gave up'));

  /// Bring the link up and hand it to the OS, the way `_armAutoConnect`'s only
  /// production caller does (a healthy link that dropped, on iOS). The platform
  /// gate is unreachable on a test host, so `armAutoConnect` is that same call
  /// by hand — see its `@visibleForTesting` doc.
  void armAfterHealthyDrop(FakeAsync async, {String id = 'AA'}) {
    unawaited(conn.connect(id));
    async.flushMicrotasks();
    ble.emitLink(BleLinkState.connecting);
    async.flushMicrotasks();
    ble.emitLink(BleLinkState.connected);
    async.flushMicrotasks();
    ble.emitLink(BleLinkState.ready);
    async.flushMicrotasks();
    ble.emitLink(BleLinkState.disconnected);
    async.flushMicrotasks();
    conn.armAutoConnect();
    async.flushMicrotasks();
  }

  /// Idempotent — a test whose watchdog is still armed has to shut down inside
  /// its own `fakeAsync` body, and the registered tear-down then arrives second.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    conn.dispose();
    unawaited(ble.dispose());
  }
}

/// The worst overshoot on record: process demonstrably alive, backgrounded
/// 68.8 minutes, watchdog still had not fired. 4,132 s is 22.96 × the 180 s
/// that was nominally promised — and, before FB-66, 22.96 × the figure the log
/// line reported.
const _fieldFreeze = Duration(seconds: 4132);

/// The `2026.08.12/003` freeze whose give-up was written as `gave up after
/// 180s`. Used by the criterion ③ test precisely because it is the capture that
/// proves the instrument was lying: 935.6 s of waiting, reported as 180.
const _fieldFreeze936 = Duration(seconds: 936);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  group('甲 — the event loop is frozen (FB-66: the deadline is judged on the '
      'wall clock)', () {
    test(
        '① a freeze that spans the deadline is settled at the RESUME, by the '
        'wall clock, without waiting for the timer', () {
      // WHAT THIS PINS: acceptance criterion ①, at its strongest point. The
      // isolate is frozen for 4,132 s — twenty-two whole watchdog periods —
      // and the only thing that happens next is the app coming back to the
      // foreground. `onAppResumed()` is an ordinary synchronous call from the
      // lifecycle observer; no timer has run and none needs to, because the
      // verdict is `clock.now() - armedAt >= 180 s` and that is answerable
      // immediately.
      //
      // Before the fix this test read the other way round: nothing was
      // reported, because `onAppResumed` began with `if (!isOnline) return;`
      // and an armed hand-off is by definition not online. The frozen half is
      // unchanged and still asserted — nothing CAN run while the isolate is
      // suspended, and no remedy in Dart can change that. What changed is that
      // the first instant of running time now settles it.
      fakeAsync((async) {
        final h = _Harness();
        h.armAfterHealthyDrop(async);
        expect(h.ble.autoConnectCalls, 1,
            reason: 'the hand-off is armed — this is the state the watchdog is '
                'supposed to be guarding');

        // The app goes to the background. `elapseBlocking` is the model:
        // the clock moves, no microtask and no timer runs. There is no other
        // way to express this in the Flutter test APIs — `tester.pump(d)` and
        // `FakeAsync.elapse(d)` both RUN what came due, which is exactly the
        // assumption iOS breaks.
        async.elapseBlocking(_fieldFreeze);

        expect(async.elapsed, _fieldFreeze);
        expect(
            async.elapsed,
            greaterThan(ConnectionController.autoConnectWatchdog * 22),
            reason: 'twenty-two whole watchdog periods have gone by');
        expect(h.gaveUpLines, isEmpty,
            reason: 'still nothing, and that is not the defect: a suspended '
                'isolate runs no code at all. The question is what happens at '
                'the first instant it runs again');

        // The user opens the app. This is the checkpoint FB-66 added; it runs
        // to completion before any timer gets a turn.
        h.conn.onAppResumed();

        expect(h.logs.notes.last, contains('woke 4132s into a 180s deadline'),
            reason: '① the deadline was judged by comparing the wall clock '
                'against the arm stamp — synchronously, inside the resume '
                'call, with the overdue timer still sitting unrun');
        expect(h.logs.notes.last, contains('(by resume)'),
            reason: 'and the log says WHICH checkpoint reached the verdict, so '
                'a capture can tell "the user came back" from "the OS finally '
                'ran our timer"');
        expect(h.ble.disconnectCalls, 0,
            reason: '② a verdict reached at a thaw is held briefly first — see '
                'the 10:10:38 test below for why');

        async.elapse(ConnectionController.autoConnectThawGrace);

        expect(h.conn.lastError, 'autoconnect_timeout',
            reason: 'and then it converges: the UI gets the one signal it has '
                'that the hand-off died');
        expect(h.ble.disconnectCalls, 1,
            reason: 'and the pending connect is cancelled');
        expect(h.gaveUpLines, hasLength(1));

        h.dispose();
      });
    });

    test(
        '① the timer thawing late reaches the same verdict, once, and ③ it '
        'reports the wait it actually measured', () {
      // WHAT THIS PINS: the other thaw path. Sometimes nothing calls
      // `onAppResumed` — the OS simply schedules the isolate again (delivering
      // the pending connect is itself such a moment) and the overdue timer runs.
      // That callback no longer trusts its own lateness: it recomputes against
      // the stamp, sees 4,132 s where 180 were promised, and takes the thaw
      // path rather than acting on the spot.
      //
      // "Exactly one" is kept from the characterization version and matters
      // more now than it did then: there are two checkpoints in the code where
      // there was one, and a resume sweep that double-reports would be a new
      // bug. The grace timer is what serialises them.
      //
      // ③ is asserted here in its strongest form: the line must NOT say 180.
      fakeAsync((async) {
        final h = _Harness();
        Duration? firedAt;
        h.conn.addListener(() {
          if (h.conn.lastError == 'autoconnect_timeout') {
            firedAt ??= async.elapsed;
          }
        });
        h.armAfterHealthyDrop(async);

        async.elapseBlocking(_fieldFreeze);
        expect(firedAt, isNull);

        // The process is scheduled again. Zero further wall time is needed:
        // `elapse(Duration.zero)` runs everything already overdue, which is
        // what the first turn of the event loop after a resume does.
        async.elapse(Duration.zero);
        expect(firedAt, isNull, reason: 'held for the grace, not dropped');
        async.elapse(ConnectionController.autoConnectThawGrace);

        expect(firedAt, _fieldFreeze + ConnectionController.autoConnectThawGrace,
            reason: 'settled at the first opportunity plus the grace — the '
                '4,132 s before it were not the app deciding to wait, they '
                'were the app not existing');
        expect(h.conn.lastError, 'autoconnect_timeout');
        expect(h.ble.disconnectCalls, 1,
            reason: 'the pending connect is cancelled — an hour after the '
                'moment that decision was supposed to be made, which is the '
                'part no in-process remedy can fix');
        expect(h.gaveUpLines, hasLength(1),
            reason: 'exactly one episode is reported. Two checkpoints must not '
                'turn one missed deadline into several');
        expect(h.gaveUpLines.single, contains('gave up after 4134s'),
            reason: '③ the MEASURED wall wait. Before the fix this line '
                'interpolated `autoConnectWatchdog.inSeconds` and said '
                '`gave up after 180s` no matter what actually happened');
        expect(h.gaveUpLines.single, isNot(contains('after 180s')),
            reason: 'the nominal value may still appear as the deadline, but '
                'never as the answer to "how long did it wait"');
        expect(h.gaveUpLines.single, contains('deadline 180s'),
            reason: 'both numbers, so one line states the promise and what was '
                'actually delivered');

        h.dispose();
      });
    });

    test(
        'CONTROL: with the event loop running it IS punctual — the freeze is '
        'the variable, not the harness', () {
      // WHAT THIS PINS: that the two tests above fail for the reason claimed.
      // Same harness, same controller, same clock object, one difference:
      // `elapse` runs the queue and `elapseBlocking` does not. Without this
      // control, "the watchdog did not fire" could just as well mean the
      // harness never armed it.
      //
      // AFTER THE FIX: this one stays green and unchanged. It is the
      // foreground behaviour, which is correct today and must remain so.
      fakeAsync((async) {
        final h = _Harness();
        Duration? firedAt;
        h.conn.addListener(() {
          if (h.conn.lastError == 'autoconnect_timeout') {
            firedAt ??= async.elapsed;
          }
        });
        h.armAfterHealthyDrop(async);

        // FB-20 (2026-08-13): the wait has to be VISIBLE to the UI layer for
        // the whole of it, not just describable afterwards in the log. Neither
        // `isBusy` nor `isRetrying` is true here — that pair is exactly why the
        // screen used to show the idle copy — so this getter is the only thing
        // a widget can ask.
        expect(h.conn.isAutoConnectArmed, isTrue,
            reason: 'armed, and the UI has to be able to see it');
        expect(h.conn.isBusy || h.conn.isRetrying, isFalse,
            reason: 'and neither existing flag covers it — the hole this fills');

        async.elapse(ConnectionController.autoConnectWatchdog -
            const Duration(seconds: 1));
        expect(firedAt, isNull, reason: 'not a second early');
        expect(h.conn.isAutoConnectArmed, isTrue,
            reason: 'still waiting one second before the deadline');

        async.elapse(const Duration(seconds: 1));
        expect(firedAt, ConnectionController.autoConnectWatchdog,
            reason: 'and not a second late — while the app is in front of the '
                'user, this works exactly as documented');
        expect(h.gaveUpLines, hasLength(1));
        // Once it has given up, the failure card owns the screen; leaving this
        // true would stack "waiting for it to come back" on top of "could not
        // connect", which are opposite claims.
        expect(h.conn.isAutoConnectArmed, isFalse,
            reason: 'and the wait is over the moment the verdict lands');

        h.dispose();
      });
    });

    test(
        'a freeze that ENDS before the deadline costs nothing — the defect '
        'needs the freeze to span the deadline', () {
      // WHAT THIS PINS: the boundary, so nobody reads this file as "timers are
      // broken". A 60 s glance at another app, then back: the remaining 120 s
      // are served on a running event loop and the watchdog is punctual. What
      // makes the field cases fatal is that iOS keeps a BLE-only app suspended
      // for far longer than 180 s at a stretch.
      //
      // AFTER THE FIX: unchanged, and still useful — it is the case a naive
      // "fire on every resume" remedy would break by giving up at 60 s.
      fakeAsync((async) {
        final h = _Harness();
        h.armAfterHealthyDrop(async);

        async.elapseBlocking(const Duration(seconds: 60)); // backgrounded
        expect(h.gaveUpLines, isEmpty);

        async.elapse(const Duration(seconds: 119)); // resumed, t = 179 s
        expect(h.conn.lastError, isNull);

        async.elapse(const Duration(seconds: 2)); // t = 181 s
        expect(h.conn.lastError, 'autoconnect_timeout');
        expect(h.gaveUpLines, hasLength(1));

        h.dispose();
      });
    });

    test(
        'the freeze stops the WHOLE controller, not just the watchdog — and at '
        'thaw the queued link event wins the race (NOT a defect, and NOT '
        'verified on a device)', () {
      // ⚠️ This test asserts the OPPOSITE of what it was written to assert, and
      // the correction is the most useful thing in this file.
      //
      // The premise was: a peripheral that comes back while the app is
      // suspended is delivered at thaw alongside a watchdog callback that has
      // been overdue since t=180 s, so the watchdog would fire first and report
      // a timeout for a hand-off that had already succeeded — a false give-up,
      // survivable only because `phantom_disconnect_test` §R4 pins the
      // un-give-up ("a hand-off that arrives LATE un-gives-up").
      //
      // WHAT ACTUALLY HAPPENS: no false give-up. `FakeAsync.elapse` drains the
      // microtask queue before it fires any timer (`_fireTimersWhile` calls
      // `flushMicrotasks` first), and a non-`sync` broadcast `StreamController`
      // delivers through a microtask. So the `connected` that was waiting in
      // the queue reaches `_onLinkState` first, which cancels the watchdog, and
      // the overdue timer is never dispatched at all.
      //
      // ⚠️ THE LIMIT OF THAT RESULT: microtasks-before-timers is what THIS
      // MODEL does. On a real iPhone the `connected` arrives over a platform
      // channel from the CoreBluetooth delegate, and whether that crosses into
      // the isolate before or after an overdue `Timer` at resume is not
      // something this code controls and not something any capture in hand
      // measures. `fake_async` cannot express the other ordering — there is no
      // API for "fire the overdue timer first" — so the false-give-up scenario
      // is NOT REFUTED here, merely not reproducible in a unit test. It needs a
      // device.
      //
      // What the test does establish, and what is worth keeping: the freeze is
      // not a property of one timer. Nothing in the controller advances — a
      // link that the OS re-established over an hour ago is still, as far as
      // the app is concerned, disconnected.
      //
      // KEPT AFTER THE FIX, unchanged, for exactly the reason above: a remedy
      // that reports on resume must not report before draining the events it
      // arrived with, and this is the case that catches one that does. The
      // ordering `fake_async` cannot express — overdue verdict first, platform
      // `connected` second — is the field's 10:10:38 case, and it is covered by
      // the test immediately below with the grace window instead of the
      // microtask queue doing the work.
      fakeAsync((async) {
        final h = _Harness();
        h.armAfterHealthyDrop(async);

        async.elapseBlocking(_fieldFreeze);
        // The OS re-established the link while the app was suspended; the
        // event is sitting in the queue, undelivered.
        h.ble.emitLink(BleLinkState.connected);
        expect(h.conn.linkState, BleLinkState.disconnected,
            reason: 'the controller is as frozen as the watchdog is — an hour '
                'of link activity is invisible to it');

        async.elapse(Duration.zero);

        expect(h.conn.linkState, BleLinkState.connected,
            reason: 'the queued event is delivered first');
        expect(h.gaveUpLines, isEmpty,
            reason: 'and delivering it cancels the watchdog before the overdue '
                'callback can run — see phantom_disconnect_test §R4 "the '
                'hand-off delivering `connected` cancels it"');
        expect(h.ble.disconnectCalls, 0,
            reason: 'the recovered link is not dropped');
        expect(h.conn.lastError, isNull);

        h.dispose();
      });
    });

    test(
        '② the 10:10:38 case: a late verdict does NOT cancel a `connected` that '
        'lands 4 ms behind it', () {
      // WHAT THIS PINS: acceptance criterion ②, against the exact field
      // sequence that motivated it. `2026-08-12 10:10:38`, and it is the one
      // concrete HARM in FB-66 — the rest is a user waiting longer than the
      // screen implies:
      //
      //     link: disconnecting             ← the 502 s-late watchdog acting
      //     link: connected (sub=502804ms)  ← 4 ms later, the hand-off landing
      //     connection canceled
      //
      // The thing that thawed the isolate WAS the hand-off completing. So the
      // watchdog cancelled the reconnection it was armed to protect, and it
      // took 502 s to do it. `_onLinkState` cancelling the watchdog at
      // `connected` cannot help here: at the instant the verdict runs, that
      // event has not reached the isolate yet.
      //
      // The remedy is `autoConnectThawGrace` — a verdict reached at a thaw is
      // held for two seconds and then re-asked. Two seconds is 500× the
      // observed 4 ms gap and a rounding error against the 502 s already lost.
      //
      // Note the ordering here is the reverse of the test above: there the
      // `connected` was already queued and won on the microtask rule, which
      // proves nothing about a platform event that has not arrived yet. Here it
      // is emitted AFTER the overdue callback has already run.
      fakeAsync((async) {
        final h = _Harness();
        h.armAfterHealthyDrop(async);

        async.elapseBlocking(const Duration(milliseconds: 502801));

        // Thaw. The overdue callback runs, finds itself 502 s late, and holds.
        async.elapse(Duration.zero);
        expect(h.ble.disconnectCalls, 0,
            reason: 'this is the whole fix: the late verdict has NOT acted yet. '
                'Before FB-66 the `_ble.disconnect()` happened right here, and '
                'that is the `link: disconnecting` in the capture');
        expect(h.conn.lastError, isNull);

        // 4 ms later, the OS delivers the connection it has been holding.
        h.ble.emitLink(BleLinkState.connected);
        async.elapse(const Duration(milliseconds: 4));
        expect(h.conn.linkState, BleLinkState.connected);

        // Well past the point the held verdict would have acted.
        async.elapse(ConnectionController.autoConnectThawGrace * 2);

        expect(h.ble.disconnectCalls, 0,
            reason: '② the recovered link is NOT dropped. `connection canceled` '
                'must not appear in this sequence again');
        expect(h.gaveUpLines, isEmpty,
            reason: 'and no timeout is reported for a hand-off that succeeded');
        expect(h.conn.lastError, isNull,
            reason: 'nor does the UI show a failure over a live link');
        expect(h.conn.linkState, BleLinkState.connected,
            reason: 'the link survives — what happens to a `connected` that '
                'never reaches `ready` is FB-51/FB-52 territory, bounded by '
                '`isSetupStalled`, and deliberately not this watchdog\'s job');

        h.dispose();
      });
    });

    test(
        '③ the give-up line reports the wait that was measured — the 935.6 s '
        'capture that said "180s"', () {
      // WHAT THIS PINS: acceptance criterion ③ on its own, on the capture that
      // made FB-66 so hard to find. The only instrument this failure has in the
      // field is that one log line, and it was hard-coded to the answer it was
      // supposed to be measuring: `autoConnectWatchdog.inSeconds`. Every
      // backgrounded timeout in every capture said 180 s — 270 s, 502 s and
      // 935 s waits all reported identically — so the 1.5×–23× range had to be
      // reconstructed from SURROUNDING timestamps, and the defect was invisible
      // to anyone grepping for it.
      //
      // A number that is always the same is not a measurement. This asserts the
      // line carries a real one, and that the real one is not silently the
      // constant.
      fakeAsync((async) {
        final h = _Harness();
        h.armAfterHealthyDrop(async);

        async.elapseBlocking(_fieldFreeze936);
        h.conn.onAppResumed();
        async.elapse(ConnectionController.autoConnectThawGrace);

        expect(h.gaveUpLines, hasLength(1));
        final line = h.gaveUpLines.single;
        expect(line, contains('gave up after 938s'),
            reason: '936 s frozen plus the 2 s grace, and every second of it '
                'was real waiting');
        expect(line, isNot(contains('after 180s')),
            reason: 'the exact string a capture of this used to contain');
        expect(
            RegExp(r'gave up after (\d+)s')
                .firstMatch(line)!
                .group(1),
            (_fieldFreeze936 + ConnectionController.autoConnectThawGrace)
                .inSeconds
                .toString(),
            reason: 'and it is the wall-clock delta, not a rounding of the '
                'constant — parsed the way a field triage would parse it');

        h.dispose();
      });
    });
  });

  // -------------------------------------------------------------------------
  group('乙 — the process is reclaimed, with NO arm repo wired (the pre-0060 '
      'boundary; FB-67 itself is fixed — see autoconnect_arm_persistence_test)',
      () {
    test(
        'DEFECT: disposing mid-flight cancels the deadline and the give-up is '
        'never reported, ever', () {
      // WHAT THIS PINS: `dispose()` calls `_cancelAutoConnectWatchdog()`, which
      // is right for a controller being torn down and is also, on iOS, the
      // shape of the process being killed under memory pressure while
      // suspended. The episode simply ends. Nothing is written, so nothing can
      // be counted: "how often does an armed autoConnect never come back?" is
      // unanswerable from the field logs, because the captures that would
      // answer it are the ones where the process did not live to write the
      // line.
      //
      // AFTER THE FIX: this is the test that decides whether the remedy has to
      // touch persistence. If the answer is "on a cold start, an armed
      // hand-off that predates the launch is reported once", this test asserts
      // that the record needed to do so is written BEFORE the process can die
      // — i.e. at arm time, not at give-up time.
      fakeAsync((async) {
        final logs = _CapturingLogRepo();
        final first = _Harness(logs: logs);
        first.armAfterHealthyDrop(async);
        async.elapse(const Duration(seconds: 60)); // 120 s still to run

        first.dispose(); // ← the process is killed here

        // No amount of subsequent time produces the give-up: the timer that
        // would have written it no longer exists.
        async.elapse(ConnectionController.autoConnectWatchdog * 10);
        expect(
            logs.notes.where((n) => n.contains('autoConnect gave up')), isEmpty,
            reason: 'DEFECT: 30 minutes later there is still no record that a '
                'hand-off was abandoned');
        expect(logs.notes, contains('auto-reconnect: autoConnect armed (iOS)'),
            reason: 'the arm IS on record — so the diagnostic log holds an '
                '"armed" with no matching outcome, and always will');
      });
    });

    test('DEFECT: a cold start inherits nothing — no residual state at all', () {
      // WHAT THIS PINS: the substance of 乙. A second controller built over the
      // same store — the model of the next launch, where the sqflite diag log
      // is the one thing that survived — starts pristine: no error, no retry
      // pending, no attempt count, and no deadline. It cannot know it is
      // resuming anything, because nothing reads the "armed" line back and
      // there is no other record.
      //
      // Whether it SHOULD know is an open question, not a decided one. The
      // honest statement of today's behaviour is: the app forgets, silently,
      // and the user meets a device list with no explanation of why the thing
      // they left connecting is not connected.
      //
      // AFTER THE FIX: if the ruling is that a cold start must reconcile, these
      // expectations invert (a fresh controller reads the orphaned arm and
      // reports it once). If the ruling is that forgetting is acceptable, this
      // test stays exactly as it is and stops being labelled a defect — the
      // label, not the assertions, is what changes.
      fakeAsync((async) {
        final logs = _CapturingLogRepo();
        final first = _Harness(logs: logs);
        first.armAfterHealthyDrop(async);
        async.elapse(const Duration(seconds: 60));
        first.dispose();
        final notesAtDeath = logs.notes.length;

        final next = _Harness(logs: logs); // cold start, same store
        expect(next.conn.lastError, isNull,
            reason: 'DEFECT: `autoconnect_timeout` is never reported for the '
                'episode that was in flight when the process died');
        expect(next.conn.isRetrying, isFalse);
        expect(next.conn.reconnectAttempts, 0);
        expect(next.conn.linkState, BleLinkState.disconnected);

        // And it stays that way. Ten watchdog periods is 30 minutes.
        async.elapse(ConnectionController.autoConnectWatchdog * 10);
        expect(next.gaveUpLines, isEmpty);
        expect(next.ble.disconnectCalls, 0);
        expect(logs.notes.length, notesAtDeath,
            reason: 'DEFECT: the new controller wrote nothing at all — it has '
                'no idea there is an episode to close');

        next.dispose();
      });
    });

    test(
        'DEFECT: even reconnecting to the SAME device after the restart does '
        'not close the old episode', () {
      // WHAT THIS PINS: the one moment where the app has every piece of
      // information it would need — the user is back, pointing at the same
      // unit, and the orphaned `armed` line is in the store — and it still does
      // not connect the two. A manual `connect` deliberately does not arm a
      // watchdog (that is by design; `_armAutoConnect` is the only arming path,
      // reached only from a healthy link dropping on iOS), so the fresh attempt
      // has no deadline of its own either, and the previous one is never
      // mentioned.
      //
      // AFTER THE FIX: whatever reconciliation is chosen, this is its cue —
      // same target, previous episode unresolved. Assert here that it fires
      // once and only once, and that it does not disturb the connect the user
      // just asked for.
      fakeAsync((async) {
        final logs = _CapturingLogRepo();
        final first = _Harness(logs: logs);
        first.armAfterHealthyDrop(async);
        async.elapse(const Duration(seconds: 60));
        first.dispose();

        final next = _Harness(logs: logs);
        unawaited(next.conn.connect('AA')); // the same unit, by hand
        async.flushMicrotasks();
        expect(next.ble.connectCalls, 1);

        async.elapse(ConnectionController.autoConnectWatchdog * 10);
        expect(next.gaveUpLines, isEmpty,
            reason: 'DEFECT: the abandoned hand-off to AA is never closed out, '
                'not even by the user connecting to AA again');
        expect(next.conn.lastError, isNull);

        next.dispose();
      });
    });
  });

  // -------------------------------------------------------------------------
  group('what the watchdog now promises', () {
    test(
        'the deadline is 180 s of WALL time, and the bound on the verdict is '
        '"the first moment the app runs, plus the thaw grace"', () {
      // A summary assertion, so the point survives even if someone reads only
      // one test. `autoConnectWatchdog`'s doc comment argues 180 s is
      // "one comfortable order above the ladder and still inside what somebody
      // will sit through" — a claim about the USER'S wait. A `Timer` alone
      // could only bound the ISOLATE'S running time, and on a backgrounded
      // iPhone those diverged by a measured 1.5× to 22.96×.
      //
      // ⚠️ WHAT FB-66 DID AND DID NOT BUY. The DEADLINE is now honest: 180 s of
      // wall clock, recomputed from a stamp, so no amount of suspension can
      // stretch it. The VERDICT still cannot be delivered while the app is not
      // running — no in-process remedy can change that, and a give-up that
      // nobody is there to read is worth nothing anyway. What is bounded is the
      // delay from the app running again to the verdict landing: the resume
      // checkpoint plus `autoConnectThawGrace`. Anything that wants the verdict
      // to arrive DURING the suspension needs the OS (a background task, or
      // CoreBluetooth state restoration — see FB-67), and neither is
      // implemented.
      expect(ConnectionController.autoConnectWatchdog,
          const Duration(seconds: 180));
      expect(ConnectionController.autoConnectThawGrace,
          lessThan(ConnectionController.autoConnectWatchdog * 0.05),
          reason: 'the grace is a rounding error against the deadline, so it '
              'can protect a landing hand-off without changing what 180 s '
              'means');
      expect(ConnectionController.autoConnectPunctualitySlack,
          lessThan(ConnectionController.autoConnectThawGrace),
          reason: 'ordinary timer jitter must not be mistaken for a thaw, and '
              'a thaw must not be mistaken for jitter');
      const worstObserved = _fieldFreeze;
      expect(worstObserved.inSeconds / 180, closeTo(22.96, 0.01),
          reason: 'the worst overshoot the field ever recorded, kept as the '
              'yardstick the fix is measured against');
    });
  });
}
