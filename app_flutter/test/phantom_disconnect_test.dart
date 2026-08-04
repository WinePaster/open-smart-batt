// FB-53 — the disconnect that never happened, and the reconnect policy built
// on top of it.
//
// flutter_blue_plus 1.36.8 builds `device.connectionState` with
// `newStreamWithInitialValue` over a cache it only ever writes
// (`bluetooth_device.dart:334-348`, `flutter_blue_plus.dart:447`), so every
// fresh subscription is handed the cached state on its first microtask —
// `disconnected` on a cold connect, before `device.connect()` has taken the
// plugin's global mutex. The app's only filter on that value was
// `link.retryingConnect`, which is `connectAttemptsFor(isIOS: true) > 1` —
// false on iOS. So iOS tore down every connection it was in the middle of
// making, one millisecond in.
//
// The corpus shape: 906 `link: connecting` → `link: disconnected` pairs, 906
// of them inside 1 ms. The user-visible shape, from `2026.08.03/004` at
// 19:50:09-19:50:25: a capacitor lying on the desk took 15.3 s to reach
// `ready`, of which 14.0 s was backoff spent recovering from three drops that
// were not drops, and the whole time the screen said "Reconnecting…".
//
// Four things are pinned here:
//
//   R1  the reducer: what a `connectionState` event means, decided from
//       whether the link was ever CONNECTED rather than from a platform
//       constant that only implied it.
//   R2  `_scheduleReconnect` is idempotent — a pending retry is already the
//       answer, and re-arming used to cancel the rung it was adding.
//   R3  the backoff ladder serves connections that existed. A manual connect
//       that never reached `connected` reports its failure instead.
//   R4  an armed autoConnect has a deadline. It never needed one while the
//       phantom disconnect was quietly ending it for us.
//
// CLEAN-ROOM: every expectation derives from this project's own source, the
// published flutter_blue_plus sources, and this project's own field captures.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState, BluetoothConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';

// ---------------------------------------------------------------------------
// R1 — the reducer
// ---------------------------------------------------------------------------

/// The rule this fix replaces, written out so the tests can compare against it
/// rather than describe it. Verbatim `ble_service.dart` before FB-53:
/// `if (link.retryingConnect) return; await _teardown(...)`.
LinkAction _legacyAction(
  BluetoothConnectionState s, {
  required bool retryingConnect,
}) {
  if (s == BluetoothConnectionState.connected) return LinkAction.setup;
  if (retryingConnect) return LinkAction.ignore;
  return LinkAction.teardown;
}

/// One link's worth of reducer state, so a sequence of events can be replayed
/// the way `_onConnectionState` sees it — including the part that matters most,
/// that `sawConnected` is set by the `connected` event itself.
class _Link {
  _Link({required this.retryingConnect});

  /// `connectAttemptsFor(isIOS:) > 1` — true on Android, false on iOS and on
  /// the autoConnect path.
  final bool retryingConnect;
  bool sawConnected = false;

  LinkAction step(BluetoothConnectionState s) {
    final action = BleService.linkActionFor(s,
        sawConnected: sawConnected, retryingConnect: retryingConnect);
    if (action == LinkAction.setup) sawConnected = true;
    return action;
  }
}

// ---------------------------------------------------------------------------
// Controller harness — no database, no radio, no plugin channels.
// ---------------------------------------------------------------------------

/// Records the always-on event lines instead of writing them.
///
/// Synchronous by design: the DB-backed tests elsewhere have to sleep 30 ms per
/// assertion to let an unawaited two-step round trip land, and the timers under
/// test here are measured in minutes.
class _CapturingLogRepo implements LogRepo {
  final List<String> notes = <String>[];

  @override
  Future<int> insertLog(LogEntry entry, {int? maxBytes}) async {
    notes.add(entry.note ?? '');
    return notes.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _StubSettingsRepo implements SettingsRepo {
  @override
  Future<AppSettings> loadSettings() async => AppSettings.defaults;

  @override
  Future<void> saveSettings(AppSettings settings) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _diagOut = StreamController<String>.broadcast();

  int connectCalls = 0;
  int autoConnectCalls = 0;
  int disconnectCalls = 0;
  String? lastConnectId;

  /// What `connect(autoConnect: true)` throws, when set. Only the hand-off
  /// path, so a test can fail the arming without also failing the ladder that
  /// is supposed to take over from it.
  Object? autoConnectError;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<String> get diagnostics => _diagOut.stream;

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
    lastConnectId = deviceId;
    if (autoConnect) {
      autoConnectCalls++;
      final e = autoConnectError;
      if (e != null) throw e;
    }
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  void emitLink(BleLinkState s) => _linkOut.add(s);
  void emitDiagnostic(String line) => _diagOut.add(line);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _diagOut.close();
    await super.dispose();
  }
}

/// Everything one controller test needs, and nothing that needs an event loop
/// of its own — the whole point is that `pump(Duration)` is the only clock.
class _Harness {
  _Harness()
      : ble = _FakeBle(),
        logs = _CapturingLogRepo() {
    conn = ConnectionController(
      ble,
      settings: SettingsController(_StubSettingsRepo()),
      logs: logs,
    );
  }

  final _FakeBle ble;
  final _CapturingLogRepo logs;
  late final ConnectionController conn;
  bool _disposed = false;

  /// Idempotent, because a test that ends with a backoff timer still armed has
  /// to shut down INSIDE its own body — the framework checks for pending
  /// timers before tear-downs run — and the registered tear-down then arrives
  /// second.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    conn.dispose();
    unawaited(ble.dispose());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  group('R1 — what a connectionState event means', () {
    test('the value replayed into a fresh subscription is ignored (iOS)', () {
      // iOS: `connectAttemptsFor(isIOS: true) == 1`, so `retryingConnect` is
      // false and this was the case that tore itself down.
      expect(BleService.connectAttemptsFor(isIOS: true), 1);
      expect(
        BleService.linkActionFor(BluetoothConnectionState.disconnected,
            sawConnected: false, retryingConnect: false),
        LinkAction.ignore,
      );
      // …and this is what it used to do instead.
      expect(
        _legacyAction(BluetoothConnectionState.disconnected,
            retryingConnect: false),
        LinkAction.teardown,
      );
    });

    test('Android keeps its retry window, unchanged', () {
      expect(BleService.connectAttemptsFor(isIOS: false), 3);
      for (final saw in [false, true]) {
        expect(
          BleService.linkActionFor(BluetoothConnectionState.disconnected,
              sawConnected: saw, retryingConnect: true),
          LinkAction.ignore,
          reason: 'a bounce between connect attempts is not a lost link',
        );
      }
    });

    test('the autoConnect path is the iOS case with no retry flag at all', () {
      // `connect(autoConnect: true)` sets `retryingConnect = false` before the
      // platform gate is even reached, so it was defenceless on BOTH platforms
      // — the branch is above the `Platform.isIOS` split.
      expect(
        BleService.linkActionFor(BluetoothConnectionState.disconnected,
            sawConnected: false, retryingConnect: false),
        LinkAction.ignore,
      );
    });

    test('a link that really was up really does tear down', () {
      expect(
        BleService.linkActionFor(BluetoothConnectionState.disconnected,
            sawConnected: true, retryingConnect: false),
        LinkAction.teardown,
      );
    });

    test('connected always means setup', () {
      for (final saw in [false, true]) {
        for (final retrying in [false, true]) {
          expect(
            BleService.linkActionFor(BluetoothConnectionState.connected,
                sawConnected: saw, retryingConnect: retrying),
            LinkAction.setup,
          );
        }
      }
    });

    test('GUARDRAIL: no disconnected without a connected before it tears down',
        () {
      // design 0033 R1 clause ④. "Android is unaffected" is true today only
      // because `connectAttemptsFor` happens to be 3; the moment somebody
      // tunes that to 1 the platform loses its accidental protection. This is
      // the invariant that should hold whatever that constant becomes, so it
      // is asserted independently of it.
      for (final retrying in [false, true]) {
        final link = _Link(retryingConnect: retrying);
        expect(link.step(BluetoothConnectionState.disconnected),
            isNot(LinkAction.teardown),
            reason: 'nothing has been connected yet — there is nothing to '
                'tear down, on either platform');
      }
    });

    test('the decision names are the three tokens the log is grepped for', () {
      // `_logConnectionState` interpolates `action.name` straight into the
      // `conn-state:` line, so these strings are a field-log interface, not an
      // implementation detail.
      expect(LinkAction.values.map((a) => a.name).toList(),
          ['setup', 'teardown', 'ignore']);
    });
  });

  // -------------------------------------------------------------------------
  group('R1 — the 19:50 field vector (2026.08.03/004)', () {
    // Verbatim from `opensmartbatt-20260803-221013.log`, iOS 26.5.2, 0.6.15,
    // the capacitor sitting on the desk:
    //
    //   19:50:09.878  connect → 154ab4f7
    //   19:50:09.878  link: connecting
    //   19:50:09.878  link: disconnected                      ← 0 ms, no code
    //   19:50:11.880  link: connecting                        ← after 2.002 s
    //   19:50:11.880  link: disconnected                      ← 0 ms
    //   19:50:15.883  link: connecting                        ← after 4.003 s
    //   19:50:15.883  link: disconnected (code=6 …timed out)  ← 0 ms, STALE code
    //   19:50:23.885  link: connecting                        ← after 8.002 s
    //   19:50:23.885  link: connected                         ← cache went warm
    //   19:50:25.197  link: ready
    //
    // Each `connecting` is a fresh `connect()`, hence a fresh `_LinkState` and
    // a fresh subscription — so each round starts with `sawConnected` false.
    // Rounds 1-3 replay `disconnected`; round 4 replays `connected`, because by
    // then one of the abandoned background connects had landed and the plugin's
    // cache had gone warm (nothing cancels those; `_teardown` nulls the handle,
    // so the next `connect()`'s opening `disconnect()` returns early).
    const rounds = <BluetoothConnectionState>[
      BluetoothConnectionState.disconnected,
      BluetoothConnectionState.disconnected,
      BluetoothConnectionState.disconnected,
      BluetoothConnectionState.connected,
    ];

    test('all three phantoms are ignored; the fourth round sets up', () {
      final decisions = [
        for (final replayed in rounds)
          _Link(retryingConnect: false).step(replayed),
      ];
      expect(decisions, [
        LinkAction.ignore,
        LinkAction.ignore,
        LinkAction.ignore,
        LinkAction.setup,
      ]);
    });

    test('the shipped 0.6.15 code tore all three down — that is the 14 s', () {
      final legacy = [
        for (final replayed in rounds)
          _legacyAction(replayed, retryingConnect: false),
      ];
      expect(legacy.where((a) => a == LinkAction.teardown).length, 3,
          reason: 'three teardowns, three rungs of backoff: '
              '2.002 + 4.003 + 8.002 = 14.007 s of the 15.319 s the user '
              'waited for a device on the desk');
    });

    test('a real drop after that connection is still a real drop', () {
      // The reducer must not have bought its silence by going deaf: once
      // 19:50:23.885 set `sawConnected`, the next `disconnected` on that same
      // link is the genuine article.
      final link = _Link(retryingConnect: false)
        ..step(BluetoothConnectionState.disconnected)
        ..step(BluetoothConnectionState.connected);
      expect(link.step(BluetoothConnectionState.disconnected),
          LinkAction.teardown);
    });
  });

  // -------------------------------------------------------------------------
  group('R2 — scheduling a reconnect is idempotent', () {
    testWidgets('a second disconnected does not burn a second rung',
        (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.conn.connect('AA');
      // A link that came all the way up and then dropped: the case the ladder
      // is for.
      h.ble.emitLink(BleLinkState.connecting);
      await tester.pump();
      h.ble.emitLink(BleLinkState.connected);
      await tester.pump();
      h.ble.emitLink(BleLinkState.disconnected);
      await tester.pump();

      expect(h.conn.isRetrying, isTrue);
      expect(h.conn.reconnectAttempts, 1);

      // The second scheduler call. In the field it arrives from the timer
      // callback's own `catch`; here a repeated `disconnected` is the same
      // arrival at the same moment in the same state.
      h.ble.emitLink(BleLinkState.disconnected);
      await tester.pump();
      expect(h.conn.reconnectAttempts, 1,
          reason: 'one failure, one rung — the ladder is 2/4/8/16/30 and the '
              'user is told which rung they are on');

      // And the pending rung still fires when it said it would, rather than
      // having been cancelled by its own reschedule.
      final before = h.ble.connectCalls;
      await tester.pump(const Duration(seconds: 2));
      expect(h.ble.connectCalls, before + 1,
          reason: 'the old first line of _scheduleReconnect was '
              '_reconnectTimer?.cancel(), which silently killed exactly this');
    });
  });

  // -------------------------------------------------------------------------
  group('R3 — the ladder serves connections that existed', () {
    testWidgets('a manual connect that never lands does not retry',
        (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.conn.connect('AA');
      h.ble.emitLink(BleLinkState.connecting);
      await tester.pump();
      h.ble.emitLink(BleLinkState.disconnected);
      await tester.pump();

      expect(h.conn.isRetrying, isFalse,
          reason: 'the connect threw, `lastError` already says why, and '
              '108 s of "Reconnecting… (attempt N of 5)" would replace an '
              'honest answer in seconds with a wrong-sounding one');
      expect(h.conn.reconnectAttempts, 0);

      final before = h.ble.connectCalls;
      await tester.pump(const Duration(seconds: 120));
      expect(h.ble.connectCalls, before,
          reason: 'no rung was ever armed, so none can fire');
    });

    testWidgets('a ladder already under way keeps going', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.conn.connect('AA');
      h.ble.emitLink(BleLinkState.connecting);
      await tester.pump();
      h.ble.emitLink(BleLinkState.connected);
      await tester.pump();
      h.ble.emitLink(BleLinkState.disconnected);
      await tester.pump();
      expect(h.conn.reconnectAttempts, 1);

      // Rung 1 fires and fails WITHOUT reaching `connected` — the ordinary
      // shape of a device that has gone away. `_reachedConnected` is false
      // here, so only the second term of the R3 condition keeps this moving.
      await tester.pump(const Duration(seconds: 2));
      h.ble.emitLink(BleLinkState.connecting);
      await tester.pump();
      h.ble.emitLink(BleLinkState.disconnected);
      await tester.pump();

      expect(h.conn.reconnectAttempts, 2);
      expect(h.conn.isRetrying, isTrue,
          reason: 'stopping here would strand the sequence after one attempt');
      h.dispose(); // rung 2 is still armed
    });

    testWidgets('an unexpected drop of a healthy link still retries',
        (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.conn.connect('AA');
      h.ble.emitLink(BleLinkState.connecting);
      await tester.pump();
      h.ble.emitLink(BleLinkState.connected);
      await tester.pump();
      h.ble.emitLink(BleLinkState.ready);
      await tester.pump();
      h.ble.emitLink(BleLinkState.disconnected);
      await tester.pump();

      expect(h.conn.isRetrying, isTrue);
      expect(h.conn.reconnectAttempts, 1);
      h.dispose(); // rung 1 is still armed
    });

    testWidgets('the terminal rung reports once, not once per caller',
        (tester) async {
      // The final failure reaches the exhausted branch twice — once via the
      // `disconnected` it emits, once via the timer callback's own catch —
      // and there is no armed timer for the idempotency guard to see. Without
      // a one-shot the log gets two `auto-reconnect gave up` lines for one
      // episode, and the count of how often the ladder actually exhausts is
      // inflated in the very capture used to verify FB-53.
      final h = _Harness();
      addTearDown(h.dispose);
      await h.conn.connect('AA');
      h.ble.emitLink(BleLinkState.connecting);
      await tester.pump();
      h.ble.emitLink(BleLinkState.connected);
      await tester.pump();
      h.ble.emitLink(BleLinkState.ready);
      await tester.pump();
      // Walk the whole ladder: each drop arms a rung, each pump fires it.
      for (var i = 0; i < ConnectionController.maxReconnectAttempts; i++) {
        h.ble.emitLink(BleLinkState.disconnected);
        await tester.pump();
        await tester
            .pump(reconnectBackoff(i) + const Duration(milliseconds: 1));
      }
      // Two terminal calls back to back — the double-caller shape.
      h.ble.emitLink(BleLinkState.disconnected);
      await tester.pump();
      h.ble.emitLink(BleLinkState.disconnected);
      await tester.pump();

      expect(h.conn.lastError, 'reconnect_exhausted');
      expect(
          h.logs.notes.where((n) => n.startsWith('auto-reconnect gave up')),
          hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  group('R4 — an armed autoConnect has a deadline', () {
    testWidgets('180 s, and it is longer than the ladder it replaces', (
      tester,
    ) async {
      // Stated as a relation, not a number: the hand-off is preferred over the
      // app-level ladder, so giving up sooner than the ladder would have would
      // make the preference a regression.
      var ladder = Duration.zero;
      for (var i = 0; i < ConnectionController.maxReconnectAttempts; i++) {
        ladder += reconnectBackoff(i);
      }
      expect(ladder, const Duration(seconds: 60));
      expect(ConnectionController.autoConnectWatchdog > ladder, isTrue);
      expect(ConnectionController.autoConnectWatchdog,
          const Duration(seconds: 180));
    });

    testWidgets('it gives up, cancels the pending connect, and says so',
        (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      // `_armAutoConnect` is reached only behind `Platform.isIOS`, which no
      // test host satisfies; `armAutoConnect` is the same call by hand.
      await h.conn.connect('AA');
      h.conn.armAutoConnect();
      await tester.pump();
      expect(h.ble.autoConnectCalls, 1);

      await tester.pump(ConnectionController.autoConnectWatchdog -
          const Duration(seconds: 1));
      expect(h.ble.disconnectCalls, 0,
          reason: 'a peripheral that comes back after two minutes should be '
              'picked up seamlessly, which is the whole point of the hand-off');
      expect(h.conn.lastError, isNull);

      await tester.pump(const Duration(seconds: 2));
      expect(h.conn.lastError, 'autoconnect_timeout',
          reason: 'not the ladder\'s code. `reconnect_exhausted` is a count, '
              'and this is one 180 s hand-off to the OS during which no '
              'attempt of ours was made — so "several attempts went by" would '
              'be a claim about work nobody did, and the field logs would show '
              'one string for two different diagnoses');
      expect(h.ble.disconnectCalls, 1,
          reason: 'the first place in this app that actually CANCELS a '
              'connect — everywhere else an abandoned one stays in flight '
              'inside the plugin');
      expect(
          h.logs.notes.where((n) => n.startsWith('auto-reconnect: autoConnect '
              'gave up')),
          hasLength(1),
          reason: 'greppable, or the count of how often this fires is '
              'unknowable');
    });

    testWidgets('an arming that FAILS falls back to the ladder', (tester) async {
      // The 180 s hole. `_ble.connect(autoConnect: true)` throwing was
      // swallowed by a bare `catchError`, and the `disconnected` its own
      // teardown emits arrives with BOTH terms of the R3 condition false —
      // `_reachedConnected` cleared by the drop that got us here,
      // `_reconnectAttempts` still 0 because the hand-off path never touches
      // the ladder. Nothing scheduled, nothing logged, and the only thing left
      // with an opinion was a watchdog on a connect that was never registered.
      final h = _Harness();
      addTearDown(h.dispose);
      h.ble.autoConnectError = StateError('CBCentralManager is not powered on');
      await h.conn.connect('AA');
      final before = h.ble.connectCalls;
      h.conn.armAutoConnect();
      await tester.pump();

      expect(h.ble.autoConnectCalls, 1);
      expect(h.conn.isRetrying, isTrue,
          reason: 'this path is only reached for a link that WAS healthy and '
              'dropped — exactly what R3 reserves the ladder for. A hand-off '
              'that could not be armed is not a hand-off to prefer over it');
      expect(h.conn.reconnectAttempts, 1);
      expect(
          h.logs.notes.where((n) =>
              n.startsWith('auto-reconnect: autoConnect could not be armed')),
          hasLength(1),
          reason: 'greppable, or a failure that leaves no trace is one nobody '
              'can count');

      // Rung 1 fires on schedule, and this time the connect lands.
      await tester.pump(const Duration(seconds: 2));
      expect(h.ble.connectCalls, before + 2);

      // …and the deadline on a connect that was never registered does not
      // outlive it and drop the link the ladder just made.
      await tester.pump(
          ConnectionController.autoConnectWatchdog + const Duration(seconds: 1));
      expect(h.logs.notes.where((n) => n.contains('autoConnect gave up')),
          isEmpty);
      expect(h.ble.disconnectCalls, 0);
    });

    testWidgets('a failed arming after a manual disconnect stays quiet',
        (tester) async {
      // The guards are re-read a microtask later on purpose: the user may have
      // moved on between the throw and its handler.
      final h = _Harness();
      addTearDown(h.dispose);
      h.ble.autoConnectError = StateError('no radio');
      await h.conn.connect('AA');
      h.conn.armAutoConnect();
      await h.conn.disconnect();
      await tester.pump();

      expect(h.conn.isRetrying, isFalse);
      expect(h.conn.reconnectAttempts, 0);
    });

    testWidgets('giving up does not start trying again', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.conn.connect('AA');
      h.conn.armAutoConnect();
      await tester.pump(ConnectionController.autoConnectWatchdog +
          const Duration(seconds: 1));

      // Dropping the link emits `disconnected`, and that is the event the
      // ladder hangs off. Without the suppression flag the act of giving up
      // would be the act of starting over.
      h.ble.emitLink(BleLinkState.disconnected);
      await tester.pump();
      expect(h.conn.isRetrying, isFalse);
      expect(h.conn.reconnectAttempts, 0);
      expect(h.conn.lastError, 'autoconnect_timeout');
    });

    testWidgets('the hand-off delivering `connected` cancels it',
        (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.conn.connect('AA');
      h.conn.armAutoConnect();
      await tester.pump(const Duration(seconds: 30));
      h.ble.emitLink(BleLinkState.connected);
      await tester.pump();

      await tester.pump(ConnectionController.autoConnectWatchdog +
          const Duration(seconds: 1));
      expect(h.ble.disconnectCalls, 0,
          reason: 'the OS produced a link; what happens to it next is '
              'FB-51/FB-52 territory, not a stale deadline\'s. Firing here '
              'would drop a link mid-setup, or double-report a failure the '
              'ladder already reported.');
      expect(h.conn.lastError, isNull);
    });

    testWidgets('reaching ready cancels it', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.conn.connect('AA');
      h.conn.armAutoConnect();
      await tester.pump(const Duration(seconds: 5));
      h.ble.emitLink(BleLinkState.ready);
      await tester.pump();

      await tester.pump(ConnectionController.autoConnectWatchdog +
          const Duration(seconds: 1));
      expect(h.ble.disconnectCalls, 0);
      expect(h.conn.lastError, isNull);
    });

    testWidgets('a manual connect cancels it', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.conn.connect('AA');
      h.conn.armAutoConnect();
      await tester.pump(const Duration(seconds: 5));
      await h.conn.connect('BB');
      await tester.pump();

      await tester.pump(ConnectionController.autoConnectWatchdog +
          const Duration(seconds: 1));
      expect(h.ble.disconnectCalls, 0,
          reason: 'the user has said what they want; a stale deadline must '
              'not drop the link they are now waiting on');
      expect(h.conn.lastError, isNull);
    });

    testWidgets('a manual disconnect cancels it', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.conn.connect('AA');
      h.conn.armAutoConnect();
      await tester.pump(const Duration(seconds: 5));
      await h.conn.disconnect();
      await tester.pump();
      final drops = h.ble.disconnectCalls;

      await tester.pump(ConnectionController.autoConnectWatchdog +
          const Duration(seconds: 1));
      expect(h.ble.disconnectCalls, drops);
      expect(h.conn.lastError, isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('R5 — the transport diagnostics reach the always-on log', () {
    testWidgets('a diagnostics line is written as an event', (tester) async {
      // The line this carries is the only trace an IGNORED event leaves, so it
      // cannot live on the raw-packet path: that is off by default, and a
      // capture that arrives with it off is exactly the one that needs it.
      final h = _Harness();
      addTearDown(h.dispose);
      const line =
          'conn-state: disconnected reason=null sub=0ms decision=ignore';
      h.ble.emitDiagnostic(line);
      await tester.pump();

      expect(h.logs.notes, contains(line));
    });

    testWidgets('it does not depend on the raw-packet log being on',
        (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(AppSettings.defaults.rawPacketLog, isFalse,
          reason: 'the condition this line has to survive');
      h.ble.emitDiagnostic('conn-state: connected reason=null sub=3ms '
          'decision=setup');
      await tester.pump();
      expect(h.logs.notes, hasLength(1));
    });
  });
}
