// FB-53 watchdog — a CHARACTERIZATION TEST. Everything it pins is a DEFECT.
//
// ⚠️ READ THIS BEFORE TRUSTING A GREEN RUN. ⚠️
//
// This file does not assert that `ConnectionController.autoConnectWatchdog`
// works. It asserts, in detail, the way it FAILS today, so that the failure
// cannot be changed by accident and cannot go on hiding behind a fake clock.
// A green run here means "the defect is still exactly the defect we documented",
// NOT "the watchdog is correct". When the defect is fixed, most of these tests
// are SUPPOSED to go red; each one carries its own note saying what it should
// then be rewritten to say.
//
// ---------------------------------------------------------------------------
// The defect
// ---------------------------------------------------------------------------
//
// `_armAutoConnect` hands a dropped healthy link to CoreBluetooth and gives the
// hand-off a deadline (`connection_controller.dart`, `autoConnectWatchdog` =
// 180 s). That deadline is a plain `Timer`. A `Timer` is a promise made by the
// Dart isolate's own event loop, and iOS suspends that event loop the moment
// the app leaves the foreground — the timer is not "late", it is not running at
// all, and it resumes only when the process is next scheduled.
//
// So the one situation the watchdog exists for — a peripheral that never comes
// back while the user is not looking at the screen — is precisely the situation
// in which it cannot fire. Field measurements put the overshoot at 1.5× to 23×
// the nominal 180 s, with the worst observation being a process that was
// demonstrably alive, backgrounded for 68.8 minutes, and had still not fired at
// 4,132 s.
//
// Two ways the deadline is lost, and this file covers both:
//
//   甲  the event loop is FROZEN. The wall clock runs, the isolate does not.
//       Modelled with `package:fake_async`'s `elapseBlocking`, which is the
//       only primitive available that advances time without running anything.
//
//   乙  the process is RECLAIMED. iOS kills a suspended app under memory
//       pressure; the next launch is a cold start. There is no state anywhere —
//       not in memory, not on disk, not read back from the diagnostic log —
//       from which a fresh `ConnectionController` could learn that an
//       autoConnect was ever armed, so the deadline is not late, it is gone.
//
// ---------------------------------------------------------------------------
// Why the existing tests cannot see any of this
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
// pin is fine — they are simply blind to the axis the bug lives on, and their
// green has been read as coverage of a deadline that has never once been
// observed firing on a backgrounded iPhone.
//
// ---------------------------------------------------------------------------
// Scope
// ---------------------------------------------------------------------------
//
// No fix is attempted here; `lib/` is untouched. Which of the available
// remedies to take (a wall-clock check on resume, `BGProcessingTask`, an
// `onAppResumed` sweep, or accepting the behaviour and changing what the app
// SAYS) is an owner decision that has not been made. Tests only.
//
// TODO(unassigned): no FB number is claimed for the background-timer defect —
// it has not been triaged. References below are to `FB-53 watchdog`, the
// feature these tests characterise, not to a bug number.
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
/// 68.8 minutes, watchdog still had not fired. 4,132 s is 22.96 × the 180 s the
/// log line will nevertheless claim.
const _fieldFreeze = Duration(seconds: 4132);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  group('甲 — the event loop is frozen (DEFECT: the deadline does not exist)',
      () {
    test(
        'DEFECT: 4,132 s of wall clock pass with the isolate suspended and the '
        '180 s watchdog does not fire', () {
      // WHAT THIS PINS: `Timer` measures event-loop time, not wall time, so a
      // suspended isolate suspends the deadline with it. The user is looking at
      // a screen that says "connecting…" to a peripheral that went away over an
      // hour ago, and the code whose entire job is to notice that has not run.
      //
      // AFTER THE FIX: this test must be INVERTED. Whatever the remedy —
      // comparing `clock.now()` against an armed-at stamp on resume, an OS
      // background task, a sweep in `onAppResumed` — the assertion becomes
      // "once 180 s of WALL time have passed, the give-up is reported at the
      // first opportunity", and the `isNull` expectations below become the
      // opposite. Do not merely delete it: the freeze is the scenario, and it
      // is the one no other test in the suite constructs.
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
        expect(async.elapsed, greaterThan(ConnectionController.autoConnectWatchdog * 22),
            reason: 'twenty-two whole watchdog periods have gone by');
        expect(h.conn.lastError, isNull,
            reason: 'DEFECT: nothing has been reported. `autoconnect_timeout` '
                'is the only signal the UI has that the hand-off died, and it '
                'is not set');
        expect(h.ble.disconnectCalls, 0,
            reason: 'DEFECT: the pending connect is still registered with '
                'CoreBluetooth. Cancelling it is the watchdog\'s other job');
        expect(h.gaveUpLines, isEmpty,
            reason: 'DEFECT: and the always-on log has no trace either, so a '
                'field capture of this cannot be distinguished from a capture '
                'where the watchdog was never armed at all');

        h.dispose();
      });
    });

    test(
        'DEFECT: thawing the isolate fires it once, 22.96× late, and it still '
        'reports "180s"', () {
      // WHAT THIS PINS: the give-up is not lost forever, it is deferred to
      // whenever the OS next runs the isolate — and the message it then writes
      // is `gave up after 180s`, because the string interpolates the CONSTANT
      // and nothing measures the elapsed wall time.
      //
      // That second half is the part worth being angry about: the log line is
      // the only instrument there is for measuring this defect in the field,
      // and it is hard-coded to report the nominal value. Every capture of a
      // backgrounded timeout says 180 s no matter whether the true figure was
      // 270 s or 4,132 s. The 1.5×–23× range had to be reconstructed from
      // SURROUNDING timestamps.
      //
      // AFTER THE FIX: keep the "exactly one" assertion — a resume sweep that
      // double-reports would be a new bug — and change the two below to assert
      // that the give-up lands promptly on resume and that the line states the
      // OBSERVED interval (a wall-clock delta) rather than the constant.
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

        expect(firedAt, _fieldFreeze,
            reason: 'DEFECT: the 180 s deadline was honoured at t=4132 s. '
                'A deadline that fires when the OS gets round to it is a '
                'notification, not a deadline');
        expect(firedAt!.inSeconds ~/ 180, 22,
            reason: 'twenty-two full watchdog periods late — the worst '
                'overshoot on record, and nothing in the code caps it');
        expect(h.conn.lastError, 'autoconnect_timeout');
        expect(h.ble.disconnectCalls, 1,
            reason: 'the pending connect is cancelled — an hour after the '
                'moment that decision was supposed to be made');
        expect(h.gaveUpLines, hasLength(1),
            reason: 'exactly one episode is reported, late. A thaw must not '
                'turn one missed deadline into several');
        expect(h.gaveUpLines.single, contains('gave up after 180s'),
            reason: 'DEFECT: the line interpolates '
                '`autoConnectWatchdog.inSeconds`, so it reports the constant, '
                'not the 4,132 s that actually elapsed. This is why no field '
                'capture can measure the overshoot directly');

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

        async.elapse(ConnectionController.autoConnectWatchdog -
            const Duration(seconds: 1));
        expect(firedAt, isNull, reason: 'not a second early');

        async.elapse(const Duration(seconds: 1));
        expect(firedAt, ConnectionController.autoConnectWatchdog,
            reason: 'and not a second late — while the app is in front of the '
                'user, this works exactly as documented');
        expect(h.gaveUpLines, hasLength(1));

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
      // AFTER THE FIX: keep this. Any remedy that reports on resume must
      // consult the live link state first, and this is the case that catches a
      // remedy which reports before draining the events it arrived with.
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
  });

  // -------------------------------------------------------------------------
  group('乙 — the process is reclaimed (DEFECT: the deadline is not deferred, '
      'it is gone)', () {
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
  group('the gap this file exists to close', () {
    test(
        'the watchdog is a wall-clock promise implemented with an event-loop '
        'timer, and 180 s is only its lower bound', () {
      // A summary assertion, so the point survives even if someone reads only
      // one test. `autoConnectWatchdog`'s doc comment argues 180 s is
      // "one comfortable order above the ladder and still inside what somebody
      // will sit through" — a claim about the USER'S wait. The implementation
      // can only bound the ISOLATE'S running time. On a foregrounded phone the
      // two coincide, which is why this went unnoticed; on a backgrounded one
      // they do not, and the observed ratio ranges from 1.5× to 22.96×.
      //
      // AFTER THE FIX: replace with the real bound the remedy provides.
      expect(ConnectionController.autoConnectWatchdog,
          const Duration(seconds: 180));
      const worstObserved = _fieldFreeze;
      expect(worstObserved.inSeconds / 180, closeTo(22.96, 0.01));
      expect(worstObserved, greaterThan(ConnectionController.autoConnectWatchdog),
          reason: 'the constant names a minimum, and the code offers no '
              'maximum. Any user-facing copy or doc line that presents 180 s '
              'as "how long the app waits" is wrong for the background case');
    });
  });
}
