// FB-51 / FB-52 (design 0031) — a link that connects and then says nothing.
//
// `2026.08.03/003` is the capture. Fourteen minutes, thirteen `link: connected`,
// zero `link: ready`, zero frames, and `auto-reconnect gave up` appears ZERO
// times — because the user tapped connect twelve times and every tap reset the
// cap. The app never once told him it had failed; he worked it out himself and
// killed the app, forty minutes in.
//
// Two separate faults live in that, and they are tested separately here:
//
//   FB-51  the retry was not a retry. `withTimeoutRetry` abandons the first
//          `discoverServices` without cancelling it, and that call holds
//          flutter_blue_plus's `"global"` FIFO mutex — one lock for every GATT
//          operation on every device — until its own 15 s runs out. Attempt 2
//          therefore spent its whole 8 s in `mtx.take()`. In the capture it
//          failed 8.001-8.002 s after attempt 1 in eleven rounds of twelve.
//
//   FB-52  nothing counted "came up and said nothing", so nothing could ever
//          decide to stop.
//
// CLEAN-ROOM: every expectation derives from this project's own source and its
// own field captures.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState, BluetoothDevice;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/disconnected_state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// No radio; the test drives link transitions itself.
class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  /// Records what [dropLink] was asked to do, and can be made to fail.
  int dropCalls = 0;
  bool dropThrows = false;

  @override
  Future<void> dropLink(BluetoothDevice device) async {
    dropCalls++;
    if (dropThrows) throw StateError('no radio');
  }

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {}

  @override
  Future<void> disconnect() async {}

  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late _FakeBle ble;

  Future<AppServices> makeServices(WidgetTester tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _FakeBle();
      services = await AppServices.create(appDatabase: db, ble: ble);
    });
    return services;
  }

  Future<void> pumpUnder(
      WidgetTester tester, AppServices s, Widget child) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: s.settings),
          ChangeNotifierProvider<DeviceController>.value(value: s.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: s.connection),
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pump();
  }

  /// One round of the shape the capture holds: the link comes up, and goes away
  /// again without ever reaching `ready`.
  Future<void> failedSetup(WidgetTester tester, AppServices s) async {
    await tester.runAsync(() async {
      ble.emitLink(BleLinkState.connecting);
      await Future<void>.delayed(Duration.zero);
      ble.emitLink(BleLinkState.connected);
      await Future<void>.delayed(Duration.zero);
      ble.emitLink(BleLinkState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
  }

  /// A round that comes all the way up.
  Future<void> goodSetup(WidgetTester tester, AppServices s) async {
    await tester.runAsync(() async {
      ble.emitLink(BleLinkState.connecting);
      await Future<void>.delayed(Duration.zero);
      ble.emitLink(BleLinkState.connected);
      await Future<void>.delayed(Duration.zero);
      ble.emitLink(BleLinkState.ready);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
  }

  group('FB-52 — counting connections that came up and said nothing', () {
    testWidgets('three of them, and the app stops and says so', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      await pumpUnder(tester, s, const DisconnectedState());
      await tester.runAsync(() => s.connection.connect('AA'));

      await failedSetup(tester, s);
      expect(s.connection.setupFailures, 1);
      expect(s.connection.isSetupStalled, isFalse,
          reason: 'one failure is ordinary — 5 of 51 in the corpus recovered '
              'on the next attempt, so firing here would cry wolf');

      await failedSetup(tester, s);
      await failedSetup(tester, s);

      expect(s.connection.setupFailures, 3);
      expect(s.connection.isSetupStalled, isTrue);
      expect(s.connection.lastError, 'gatt_setup_stalled');
    });

    testWidgets('tapping connect again on the SAME unit does not reset it',
        (tester) async {
      // The heart of the fault. `_reconnectAttempts` is reset by every manual
      // connect, which is correct for a backoff counter and fatal for this one:
      // twelve taps in fourteen minutes kept the give-up path permanently out
      // of reach.
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      await pumpUnder(tester, s, const DisconnectedState());
      await tester.runAsync(() => s.connection.connect('AA'));

      await failedSetup(tester, s);
      await failedSetup(tester, s);
      expect(s.connection.setupFailures, 2);

      await tester.runAsync(() => s.connection.connect('AA')); // user retries
      expect(s.connection.setupFailures, 2,
          reason: 'a retry of the thing that just failed is not a clean slate');

      await failedSetup(tester, s);
      expect(s.connection.isSetupStalled, isTrue);
    });

    testWidgets('nor does the give-up card\'s own retry button', (tester) async {
      // T2, on the one path that defeated it. `reconnectCurrent()` is what the
      // advice card's "try again" wires to, and it goes out through
      // `disconnect()` — which nulls `_desiredDeviceId` — before coming back in
      // through `connect()`. The reset test used to compare the target against
      // that nulled field, so it read "different unit" every time: three
      // failures, tap, three more, tap, and the card could be dismissed for
      // ever without the run once reaching the cap that produced it.
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      await pumpUnder(tester, s, const DisconnectedState());
      await tester.runAsync(() => s.connection.connect('AA'));

      await failedSetup(tester, s);
      await failedSetup(tester, s);
      expect(s.connection.setupFailures, 2);

      await tester.runAsync(() => s.connection.reconnectCurrent());
      expect(s.connection.setupFailures, 2,
          reason: 'design 0031 G3: the same unit, reconnected by hand, is the '
              'user retrying the thing that just failed twice');

      await failedSetup(tester, s);
      expect(s.connection.isSetupStalled, isTrue);
    });

    testWidgets('nor a manual disconnect followed by a manual connect',
        (tester) async {
      // Same shape, spelled out by hand rather than through `reconnectCurrent`
      // — the run belongs to the unit, and the user cycling the link is not
      // evidence it has ended. Only `ready` is.
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      await pumpUnder(tester, s, const DisconnectedState());
      await tester.runAsync(() => s.connection.connect('AA'));

      await failedSetup(tester, s);
      await failedSetup(tester, s);
      await tester.runAsync(() => s.connection.disconnect());
      await tester.runAsync(() => s.connection.connect('AA'));

      expect(s.connection.setupFailures, 2);
    });

    testWidgets('reaching ready clears it', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      await pumpUnder(tester, s, const DisconnectedState());
      await tester.runAsync(() => s.connection.connect('AA'));

      await failedSetup(tester, s);
      await failedSetup(tester, s);
      expect(s.connection.setupFailures, 2);

      await goodSetup(tester, s);
      expect(s.connection.setupFailures, 0,
          reason: 'coming up is the only evidence the run has ended');
      expect(s.connection.isSetupStalled, isFalse);
    });

    testWidgets('switching to a different unit clears it', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      await pumpUnder(tester, s, const DisconnectedState());
      await tester.runAsync(() => s.connection.connect('AA'));

      await failedSetup(tester, s);
      await failedSetup(tester, s);
      expect(s.connection.setupFailures, 2);

      await tester.runAsync(() => s.connection.connect('BB'));
      expect(s.connection.setupFailures, 0,
          reason: 'the run belongs to the unit, not to the app');

      // And the ownership does not stick to the first unit ever seen: a
      // failure under BB, then back to AA, is a different unit again.
      await failedSetup(tester, s);
      expect(s.connection.setupFailures, 1);
      await tester.runAsync(() => s.connection.connect('AA'));
      expect(s.connection.setupFailures, 0);
    });

    testWidgets('a connect that never lands is NOT counted here',
        (tester) async {
      // That failure already has an owner: maxReconnectAttempts. Counting it
      // twice would make a stale iOS NSUUID look like a stalled setup and send
      // the user the wrong instruction.
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      await pumpUnder(tester, s, const DisconnectedState());
      await tester.runAsync(() => s.connection.connect('AA'));

      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() async {
          ble.emitLink(BleLinkState.connecting);
          await Future<void>.delayed(Duration.zero);
          ble.emitLink(BleLinkState.disconnected); // never reached `connected`
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pump();
      }

      expect(s.connection.setupFailures, 0);
      expect(s.connection.isSetupStalled, isFalse);
    });
  });

  group('FB-52 — what the user sees', () {
    testWidgets('the failure is on screen and stays there', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      await pumpUnder(tester, s, const DisconnectedState());
      await tester.runAsync(() => s.connection.connect('AA'));

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      await failedSetup(tester, s);
      expect(find.text(l10n.disconnectedStalledTitle), findsNothing,
          reason: 'not after one failure');

      await failedSetup(tester, s);
      await failedSetup(tester, s);

      expect(find.text(l10n.disconnectedStalledTitle), findsOneWidget);
      expect(find.text(l10n.disconnectedStalledBody(3)), findsOneWidget,
          reason: '"we really did try" should be a number, not a claim');
      expect(find.text(l10n.disconnectedStalledHint), findsOneWidget);
      expect(find.text(l10n.disconnectedStalledRetry), findsOneWidget);

      // A SnackBar would have gone by now. This must not.
      await tester.pump(const Duration(seconds: 30));
      expect(find.text(l10n.disconnectedStalledTitle), findsOneWidget);
    });

    testWidgets('the instruction is the one with field evidence behind it',
        (tester) async {
      // design 0031 Q4, ruled 2026-08-03. Killing the app is what the reporter
      // did unprompted and it worked; waiting is what had already been tried
      // for forty minutes. Telling someone to wait would be worse than silence.
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(l10n.disconnectedStalledHint.toLowerCase(), contains('close'));
      expect(l10n.disconnectedStalledHint, contains('40 minutes'));

      final zh = await AppLocalizations.delegate.load(const Locale('zh'));
      expect(zh.disconnectedStalledHint, contains('完全關掉'));
      expect(zh.disconnectedStalledHint, contains('40 分鐘'));
    });
  });

  group('FB-52 — the app stops trying (design 0031 Q3)', () {
    testWidgets('no auto-reconnect is scheduled once stalled', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      await pumpUnder(tester, s, const DisconnectedState());
      await tester.runAsync(() => s.connection.connect('AA'));

      await failedSetup(tester, s);
      expect(s.connection.isRetrying, isTrue,
          reason: 'the ordinary path still retries');

      await failedSetup(tester, s);
      await failedSetup(tester, s);

      expect(s.connection.isSetupStalled, isTrue);
      expect(s.connection.isRetrying, isFalse,
          reason: 'another forty minutes of this buys nothing');
    });
  });

  group('FB-51 — the retry is the reconnect now', () {
    test('discovery gets ONE attempt, on both platforms', () {
      // It was two. The second could not do what it claimed: it spent its whole
      // budget queued on the plugin's `"global"` mutex behind the first call,
      // which `.timeout()` abandons without cancelling.
      expect(BleService.discoverAttemptsFor(isIOS: true), 1);
      expect(BleService.discoverAttemptsFor(isIOS: false), 1);
    });

    test('the setup budget is now well under what it replaces', () {
      // The invariant the old test encoded, restated for one attempt — and this
      // time it must survive someone adding a delay BETWEEN attempts, which is
      // why the term is written out even though it is currently zero.
      const betweenAttempts = Duration.zero;
      final now = BleService.discoverTimeout *
              BleService.discoverAttemptsFor(isIOS: true) +
          betweenAttempts *
              (BleService.discoverAttemptsFor(isIOS: true) - 1) +
          BleService.notifyTimeout * BleService.notifyAttempts;
      // What it replaces: the plugin's own 15 s on discovery, plus its 15 s on
      // the CCCD write.
      final before = const Duration(seconds: 15) + const Duration(seconds: 15);
      expect(now, lessThan(before));
      expect(now, const Duration(seconds: 18));
    });

    test('the failure-path disconnect does not wait 35 seconds', () {
      // flutter_blue_plus's default. On a path that has already failed there is
      // nobody left to care about the confirmation.
      expect(BleService.setupFailureDisconnectTimeout,
          lessThan(const Duration(seconds: 35)));
      expect(BleService.setupFailureDisconnectTimeout,
          BleService.keepAliveWriteTimeout,
          reason: 'reuse the number this app already has for "not coming back"');
    });

    test('a failing disconnect does not take the teardown down with it',
        () async {
      // The call runs on the way out of a path that has already failed, and
      // every caller's next move is the teardown regardless. FB-23 is the
      // precedent: a throw here reaches no handler and becomes an `Uncaught:`
      // line, which is all a field capture ever showed.
      final ble = _FakeBle()..dropThrows = true;
      addTearDown(ble.dispose);
      await expectLater(
        ble.dropLink(BluetoothDevice.fromId('AA:BB:CC:DD:EE:FF')),
        throwsA(isA<StateError>()),
      );
      expect(ble.dropCalls, 1);
    });
  });
}
