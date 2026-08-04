// FB-53 — what the app says when it has stopped trying.
//
// Two separate silences, both on the same screen.
//
// The first is the classification. `connectFailureError` labelled every failure
// the adapter state could not explain `device_stale` on iOS — "this unit could
// not be found, scan again". The commonest failure of all is a unit that is
// simply out of range, and for that one the instruction is not just unhelpful,
// it is a dead end: the user scans, the unit is not in the scan either, and
// they have learned nothing. flutter_blue_plus says which it was, in a typed
// field: `FlutterBluePlusException.code` is an index into `FbpErrorCode`
// whenever `platform == ErrorPlatform.fbp` (`utils.dart:19`,
// `bluetooth_device.dart:157`). Read by type and code, never by message —
// FB-44 was a message match, and it told ten `CBManagerStatePoweredOff`
// episodes in one 40-hour capture that their hardware no longer existed.
//
// The second is the rendering. Whichever way an attempt ends — the ladder
// exhausted, the autoConnect watchdog expired, the id gone stale, the unit out
// of range — `DisconnectedState` fell through to "No device connected", the
// same words it shows before anybody has tapped anything. In `2026.08.03/004`
// that is 60 s of backoff followed by a screen that reports nothing happened.
//
// R7 is pinned here too. `disconnectedRetryingBody` says "this is normal on a
// link that has just dropped", which was false while the ladder ran for first
// connects that never landed; R3 made it true, so the copy stands and this
// file holds it to that.
//
// CLEAN-ROOM: expectations derive from this project's own source, the published
// flutter_blue_plus sources, and this project's own field captures.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show
        BluetoothAdapterState,
        ErrorPlatform,
        FbpErrorCode,
        FlutterBluePlusException;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/disconnected_state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// What the plugin throws when it gives up on its own timer.
FlutterBluePlusException _fbpTimeout() => FlutterBluePlusException(
    ErrorPlatform.fbp, 'connect', FbpErrorCode.timeout.index,
    'Timed out after 15s');

/// No radio. [connectError], when set, is what `connect` throws.
class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  Object? connectError;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    final e = connectError;
    if (e != null) throw e;
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

class _StubSettingsRepo implements SettingsRepo {
  @override
  Future<AppSettings> loadSettings() async => AppSettings.defaults;

  @override
  Future<void> saveSettings(AppSettings settings) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A controller whose `lastError` a test can simply state.
///
/// Two of the three give-up codes are reached only by waiting: the ladder needs
/// its full 60 s and the autoConnect watchdog 180 s, both on the wall clock a
/// widget test cannot fake while a real database is in play. Which failure
/// produces which code is a pure function and is pinned by the group above; all
/// this screen has to be asked is what it draws once the code exists.
class _ErrorConn extends ConnectionController {
  _ErrorConn(super.ble, {required super.settings});

  String? error;

  @override
  String? get lastError => error;

  void setError(String? e) {
    error = e;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  // -------------------------------------------------------------------------
  group('R6 — the failure is classified by type, not by prose', () {
    test('a plugin timeout is a device out of range, on either platform', () {
      for (final isIOS in [true, false]) {
        expect(
          ConnectionController.connectFailureError(
              adapter: BluetoothAdapterState.on,
              isIOS: isIOS,
              error: _fbpTimeout()),
          'device_unreachable',
          reason: 'a connect that ran its budget out with nothing answering '
              'says nothing about the saved id — and on Android, where this '
              'used to return null, it says nothing at all today',
        );
      }
    });

    test('a stale iOS id is still a stale iOS id', () {
      // The narrowing must not take the diagnosis away from the case it was
      // built for: an id that no longer resolves fails without the plugin
      // raising anything of its own.
      expect(
        ConnectionController.connectFailureError(
            adapter: BluetoothAdapterState.on,
            isIOS: true,
            error: StateError('unreachable peripheral')),
        'device_stale',
      );
      // And the no-error call sites (the FB-44 preflight) are untouched.
      expect(
        ConnectionController.connectFailureError(
            adapter: BluetoothAdapterState.on, isIOS: true),
        'device_stale',
      );
    });

    test('a NATIVE code that collides with the enum is not decoded', () {
      // The trap this is here for: `code` is an index into FbpErrorCode only
      // when the plugin raised the exception itself. On the relaying path
      // (`bluetooth_device.dart:169-172`, `platform: _nativeError`) it is the
      // native disconnect reason — Android GATT status 1 is 0x01, which is
      // also `FbpErrorCode.timeout.index`. Two entirely different facts, one
      // integer.
      final native = FlutterBluePlusException(
          ErrorPlatform.android, 'connect', FbpErrorCode.timeout.index,
          'GATT_INVALID_HANDLE');
      expect(ConnectionController.fbpErrorCodeOf(native), isNull);
      expect(
        ConnectionController.connectFailureError(
            adapter: BluetoothAdapterState.on, isIOS: true, error: native),
        'device_stale',
        reason: 'unclassified, so it falls back — it must not be promoted to a '
            'timeout it never was',
      );
      // And on the platform it actually comes from. GATT 133 is the ordinary
      // Android connect failure and arrives exactly like this; leaving it null
      // is what put a raw exception string in `lastError`, where nothing
      // matches it.
      expect(
        ConnectionController.connectFailureError(
            adapter: BluetoothAdapterState.on, isIOS: false, error: native),
        'connect_failed',
      );
    });

    test('the message text is not consulted', () {
      // FB-44's fix in one assertion. A description that reads exactly like a
      // timeout, carrying a code that is not one.
      final lookalike = FlutterBluePlusException(ErrorPlatform.fbp, 'connect',
          FbpErrorCode.deviceIsDisconnected.index, 'Timed out after 15s');
      expect(
        ConnectionController.connectFailureError(
            adapter: BluetoothAdapterState.on, isIOS: false, error: lookalike),
        isNot('device_unreachable'),
        reason: 'prose is not an API; the code said disconnected',
      );
      expect(
        ConnectionController.connectFailureError(
            adapter: BluetoothAdapterState.on, isIOS: true, error: lookalike),
        isNot('device_unreachable'),
      );
    });

    test('the radio still outranks whatever the plugin threw', () {
      for (final radio in [
        BluetoothAdapterState.off,
        BluetoothAdapterState.unauthorized,
      ]) {
        expect(
          ConnectionController.connectFailureError(
              adapter: radio, isIOS: true, error: _fbpTimeout()),
          isNot('device_unreachable'),
          reason: 'a radio that is off explains the timeout completely, and '
              'the remedy is the radio',
        );
      }
    });

    test('a radio that went down mid-connect is named for what it is', () {
      // The residual case the preflight cannot catch: the adapter stream has
      // not caught up, so `adapter` still reads `on` while the plugin has
      // already aborted the operation for exactly that reason
      // (`utils.dart:63`).
      final adapterOff = FlutterBluePlusException(ErrorPlatform.fbp, 'connect',
          FbpErrorCode.adapterIsOff.index, 'Bluetooth adapter is off');
      expect(
        ConnectionController.connectFailureError(
            adapter: BluetoothAdapterState.on, isIOS: true, error: adapterOff),
        'bluetooth_off',
      );
    });

    test('a connect WE cancelled is nobody else\'s fault', () {
      // The FB-53 watchdog is the first thing in this app that cancels a
      // pending connect, so this exception can now actually reach here. The
      // canceller has already said why in `lastError`; overwriting that with
      // "this unit could not be found" would blame the device for our decision.
      final cancelled = FlutterBluePlusException(ErrorPlatform.fbp, 'connect',
          FbpErrorCode.connectionCanceled.index, 'connection canceled');
      for (final isIOS in [true, false]) {
        expect(
          ConnectionController.connectFailureError(
              adapter: BluetoothAdapterState.on,
              isIOS: isIOS,
              error: cancelled),
          isNull,
        );
      }
    });

    test('a code this build does not know is left alone', () {
      // A future plugin version growing the enum, and a null code, both land
      // on the same answer: unclassified.
      final beyond = FlutterBluePlusException(
          ErrorPlatform.fbp, 'connect', FbpErrorCode.values.length, 'new');
      expect(ConnectionController.fbpErrorCodeOf(beyond), isNull);
      expect(
          ConnectionController.fbpErrorCodeOf(
              FlutterBluePlusException(ErrorPlatform.fbp, 'connect', null, '')),
          isNull);
      expect(ConnectionController.fbpErrorCodeOf(null), isNull);
      expect(ConnectionController.fbpErrorCodeOf(StateError('x')), isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('R6 — the dashboard says so instead of falling silent', () {
    late _FakeBle ble;
    late SettingsController settings;
    late _ErrorConn conn;

    setUp(() {
      ble = _FakeBle();
      settings = SettingsController(_StubSettingsRepo());
      conn = _ErrorConn(ble, settings: settings);
    });

    tearDown(() {
      conn.dispose();
      unawaited(ble.dispose());
    });

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<ConnectionController>.value(
          value: conn,
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const Scaffold(body: DisconnectedState()),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('an exhausted ladder is reported, not just stopped',
        (tester) async {
      await pump(tester);
      expect(find.text('No device connected'), findsOneWidget);

      conn.setError('reconnect_exhausted');
      await tester.pump();

      expect(find.text('No device connected'), findsNothing,
          reason: 'the words shown before anyone tapped anything are the wrong '
              'report on 60 s of failed retries');
      expect(find.text('Could not connect to this device'), findsOneWidget);
      expect(
          find.text('Several attempts went by without a connection, so it has '
              'stopped trying.'),
          findsOneWidget);
      // …and the card, with the way out.
      expect(find.textContaining('Nothing more happens on its own'),
          findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('an out-of-range unit is told to go and look at it',
        (tester) async {
      await pump(tester);
      conn.setError('device_unreachable');
      await tester.pump();

      expect(
          find.text(
              'This device could not be found. Check it is nearby and switched '
              'on'),
          findsOneWidget);
      expect(find.text('This unit could not be found — scan again, then '
          'reconnect'), findsNothing,
          reason: 'the scan instruction is the dead end this code was split '
              'out of — the unit is not in the scan either');
    });

    testWidgets('a stale id keeps the instruction that works for it',
        (tester) async {
      await pump(tester);
      conn.setError('device_stale');
      await tester.pump();

      expect(
          find.text('This unit could not be found — scan again, then reconnect'),
          findsOneWidget);
    });

    testWidgets('the retry button reaches the controller', (tester) async {
      await pump(tester);
      conn.setError('reconnect_exhausted');
      await tester.pump();

      // Nothing to reconnect TO yet, so the observable effect is that the tap
      // is wired at all and swallows its own failure rather than reaching the
      // zone handler (the FB-44 `Uncaught:` family).
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a code with a retry already under way keeps the spinner',
        (tester) async {
      // Same `!working` gate the stalled card has. A manual retry must look
      // like progress — and `connect()` clears `lastError`, so the give-up
      // message only comes back once the retry has failed too.
      await pump(tester);
      conn.setError('device_unreachable');
      ble._linkOut.add(BleLinkState.connecting);
      await tester.pump();
      await tester.pump();

      expect(conn.isBusy, isTrue);
      expect(find.text('Could not connect to this device'), findsNothing);
      expect(find.text('Connecting…'), findsOneWidget);
    });

    testWidgets('a failure nobody could classify still gets a card',
        (tester) async {
      // The Android residual. `connectFailureError` has nothing specific for a
      // GATT 133, and that used to mean it said nothing at all — which, once
      // R3 stopped wrapping a failed first connect in a minute of
      // "Reconnecting…", left the tap and the no-tap looking identical. A
      // vague correct sentence is the floor; a wrong specific one is still
      // forbidden, which is why this code gets the generic remedy and not the
      // "scan again" or "go and look at it" ones.
      await pump(tester);
      conn.setError('connect_failed');
      await tester.pump();

      expect(find.text('No device connected'), findsNothing);
      expect(find.text('Could not connect to this device'), findsOneWidget);
      expect(find.text('Connection failed, please try again'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(
          find.text('This unit could not be found — scan again, then reconnect'),
          findsNothing);
      expect(
          find.text('This device could not be found. Check it is nearby and '
              'switched on'),
          findsNothing);
    });

    testWidgets('and it does not claim attempts that R3 no longer makes',
        (tester) async {
      // `disconnectedGaveUpBody` — "several attempts went by without a
      // connection" — is the right report on an exhausted ladder and a lie
      // about a single manual tap that failed once. R3 is exactly the change
      // that stopped that tap from making several attempts, so the two cases
      // can no longer share one sentence.
      await pump(tester);
      conn.setError('connect_failed');
      await tester.pump();

      expect(
          find.text('Several attempts went by without a connection, so it has '
              'stopped trying.'),
          findsNothing);
    });

    testWidgets('the branch is still a set, not a catch-all', (tester) async {
      // A wrong specific claim is worse than a vague correct one, which is the
      // same rule the device sheet's snackbar follows — so this stays keyed on
      // known codes rather than on "lastError is not null". The group above
      // pins the other half of the contract: the connect paths can no longer
      // put a raw exception string here, so nothing real falls down this hole.
      await pump(tester);
      conn.setError('PlatformException(something we have never seen)');
      await tester.pump();

      expect(find.text('No device connected'), findsOneWidget);
      expect(find.text('Could not connect to this device'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  group('R6 — end to end from the quick-pick tap', () {
    testWidgets('a timed-out saved device lands on the unreachable copy',
        (tester) async {
      late final AppServices s;
      late final _FakeBle ble;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        ble = _FakeBle()..connectError = _fbpTimeout();
        s = await AppServices.create(appDatabase: db, ble: ble);
        await s.devices.saveNew('AA', 'Cap #1', name: 'RCE-SCAP_II');
      });
      addTearDown(() => tester.runAsync(s.dispose));

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsController>.value(value: s.settings),
            ChangeNotifierProvider<DeviceController>.value(value: s.devices),
            ChangeNotifierProvider<ConnectionController>.value(
                value: s.connection),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const Scaffold(body: DisconnectedState()),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Cap #1'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('Cap #1'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      // The whole chain: plugin exception → typed classifier → `lastError` →
      // a branch on this screen. Every link of it was missing.
      expect(s.connection.lastError, 'device_unreachable');
      expect(tester.takeException(), isNull,
          reason: 'the tap handler absorbs the rethrow — deliberately, and now '
              'without cost, because the screen shows the reason');
      expect(
          find.text(
              'This device could not be found. Check it is nearby and switched '
              'on'),
          findsOneWidget);
    });

    testWidgets('and so does an Android GATT failure nobody can name',
        (tester) async {
      // The path the first version of this fix left silent. The plugin relays
      // the native status rather than raising anything of its own
      // (`platform: _nativeError`, `bluetooth_device.dart:169-172`), so there
      // is no `FbpErrorCode` to read and no iOS stale-id fallback to land on.
      // Every other failure on this branch reaches the screen; this one used to
      // reach `lastError` as the exception's own `toString()` and match nothing
      // there. With the ladder now reserved for links that existed, the tap
      // produced no attempt count, no card, and no change on screen at all.
      late final AppServices s;
      late final _FakeBle ble;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        ble = _FakeBle()
          ..connectError = FlutterBluePlusException(
              ErrorPlatform.android, 'connect', 133, 'GATT_ERROR');
        s = await AppServices.create(appDatabase: db, ble: ble);
        await s.devices.saveNew('AA', 'Cap #1', name: 'RCE-SCAP_II');
      });
      addTearDown(() => tester.runAsync(s.dispose));

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsController>.value(value: s.settings),
            ChangeNotifierProvider<DeviceController>.value(value: s.devices),
            ChangeNotifierProvider<ConnectionController>.value(
                value: s.connection),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const Scaffold(body: DisconnectedState()),
          ),
        ),
      );
      await tester.pump();

      await tester.runAsync(() async {
        await tester.tap(find.text('Cap #1'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(s.connection.lastError, 'connect_failed');
      expect(s.connection.isRetrying, isFalse,
          reason: 'R3: a first connect that never landed does not get the '
              'ladder, so the card is the ONLY thing left to say it failed');
      expect(tester.takeException(), isNull);
      expect(find.text('No device connected'), findsNothing);
      expect(find.text('Connection failed, please try again'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  group('R7 — the retrying copy, re-read after R1 and R3', () {
    testWidgets('it is not reachable from a first connect that never landed',
        (tester) async {
      // "The device did not answer. Waiting before the next attempt — this is
      // normal on a link that has just dropped." That sentence was false for
      // the case it was most often shown in: a manual connect to a unit that
      // had never been up, wrapped in 2+4+8+16+30 s of it. R3 removed that
      // case from the ladder, so the words are now only shown when a link
      // really did just drop, and they stand unchanged.
      //
      // Pinned as literal text so that changing it is a decision someone makes
      // on purpose rather than a drive-by.
      late final AppServices s;
      late final _FakeBle ble;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        ble = _FakeBle();
        s = await AppServices.create(appDatabase: db, ble: ble);
      });
      addTearDown(() => tester.runAsync(s.dispose));

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsController>.value(value: s.settings),
            ChangeNotifierProvider<DeviceController>.value(value: s.devices),
            ChangeNotifierProvider<ConnectionController>.value(
                value: s.connection),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const Scaffold(body: DisconnectedState()),
          ),
        ),
      );

      await tester.runAsync(() async {
        await s.connection.connect('AA');
        ble._linkOut.add(BleLinkState.connecting);
        await Future<void>.delayed(Duration.zero);
        ble._linkOut.add(BleLinkState.disconnected);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();

      expect(s.connection.isRetrying, isFalse);
      expect(
          find.textContaining('this is normal on a link that has just dropped'),
          findsNothing);
    });

    testWidgets('and it is still the copy shown when one really did drop',
        (tester) async {
      late final AppServices s;
      late final _FakeBle ble;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        ble = _FakeBle();
        s = await AppServices.create(appDatabase: db, ble: ble);
      });
      addTearDown(() => tester.runAsync(s.dispose));

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsController>.value(value: s.settings),
            ChangeNotifierProvider<DeviceController>.value(value: s.devices),
            ChangeNotifierProvider<ConnectionController>.value(
                value: s.connection),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const Scaffold(body: DisconnectedState()),
          ),
        ),
      );

      await tester.runAsync(() async {
        await s.connection.connect('AA');
        ble._linkOut.add(BleLinkState.connecting);
        await Future<void>.delayed(Duration.zero);
        ble._linkOut.add(BleLinkState.connected);
        await Future<void>.delayed(Duration.zero);
        ble._linkOut.add(BleLinkState.disconnected);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();

      expect(s.connection.isRetrying, isTrue);
      expect(
          find.text('The device did not answer. Waiting before the next '
              'attempt — this is normal on a link that has just dropped.'),
          findsOneWidget);
    });
  });
}
