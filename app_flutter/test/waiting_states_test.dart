// Two screens that show a wait, and the holes they used to leave in it.
//
// DisconnectedState — it read `isBusy`, which is false during the backoff wait
// between two auto-reconnect attempts, because the link really is
// `disconnected` then. So a phone working through the five-attempt sequence
// showed a spinner that ran for a fraction of a second, vanished for two,
// ran again, vanished for four. A field capture spent 15.7 s of a 16.2 s wait
// in that state. Nothing about the reconnect policy changes here: the state was
// always there, it was simply not drawn.
//
// ClassPendingView — past its timeout it can say WHY, and a non-zero keep-alive
// failure count is the difference worth saying. The one interval in the corpus
// that ran to 43.9 s had keep-alive writes timing out and recovering underneath
// it the whole time, on a link that never disconnected. "Connection unstable"
// is actionable; "cannot determine device type" is not.
//
// CLEAN-ROOM: expectations derive from this project's own source and captures.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/class_pending_view.dart';
import 'package:open_smart_batt/ui/dashboard/disconnected_state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// No radio; the test drives link transitions and the failure counter directly.
class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  /// Overridden so a test can put the poll counter where it wants it without
  /// running a real keep-alive loop.
  int failures = 0;

  @override
  int get keepAliveFailures => failures;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  /// Controllable so a test can make the unit SPEAK while its writes are
  /// failing — the FB-20 shape, and the one case the failure counter alone
  /// gets wrong.
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);

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
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
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

  /// Puts the controller in the gap: an auto-reconnect is SCHEDULED, the link
  /// is `disconnected`, and no attempt is in flight.
  ///
  /// The `connected` in the middle is load-bearing since FB-53: the backoff
  /// ladder now serves connections that existed, so a link that never once
  /// reached `connected` reports its failure instead of retrying. That is a
  /// policy change, not a change to what these screens draw — the gap they are
  /// about is still the gap, and it is still entered by the case it was always
  /// about (a link that came up and then went away).
  Future<void> enterBackoffGap(WidgetTester tester, AppServices s) async {
    await tester.runAsync(() async {
      await s.connection.connect('AA'); // sets the reconnect target
      ble.emitLink(BleLinkState.connecting);
      await Future<void>.delayed(Duration.zero);
      ble.emitLink(BleLinkState.connected);
      await Future<void>.delayed(Duration.zero);
      ble.emitLink(BleLinkState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
  }

  group('DisconnectedState during the backoff gap', () {
    testWidgets('the controller reports retrying while isBusy is false',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      await pumpUnder(tester, s, const DisconnectedState());
      await enterBackoffGap(tester, s);

      // The whole point: the old signal says "idle", the new one says "working".
      expect(s.connection.isBusy, isFalse,
          reason: 'between attempts the link genuinely is disconnected');
      expect(s.connection.isRetrying, isTrue);
      expect(s.connection.reconnectAttempts, 1);
    });

    testWidgets('a progress indicator stays on screen in the gap',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      await pumpUnder(tester, s, const DisconnectedState());

      // Idle: no indicator. Establishing the baseline matters — an indicator
      // that is always on says nothing.
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await enterBackoffGap(tester, s);
      expect(find.byType(CircularProgressIndicator), findsWidgets,
          reason: 'this is the frame that used to be blank');
    });

    testWidgets('it names the attempt instead of the idle prompt',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      await pumpUnder(tester, s, const DisconnectedState());
      expect(find.text('No device connected'), findsOneWidget);

      await enterBackoffGap(tester, s);
      expect(find.text('No device connected'), findsNothing);
      expect(
          find.text('Reconnecting… (attempt 1 of '
              '${ConnectionController.maxReconnectAttempts})'),
          findsOneWidget);
    });
  });

  group('ClassPendingView past the timeout', () {
    /// Pins `pendingFor` past [kClassPendingTimeout] by reaching `ready` and
    /// letting the clock run, with no device-type byte ever arriving.
    ///
    /// Two clocks are in play and both have to be moved. `pendingFor` is
    /// wall-clock, so only `runAsync` advances it; the view's own 250 ms
    /// repaint timer is a test timer, so only `pump(duration)` fires it. Real
    /// time alone leaves the last frame on screen with nothing marked dirty.
    Future<void> stall(WidgetTester tester, AppServices s) async {
      await tester.runAsync(() async {
        ble.emitLink(BleLinkState.ready);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(
          kClassPendingTimeout + const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('a healthy poll loop gets the neutral copy', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      ble.failures = 0;
      await pumpUnder(tester, s, const ClassPendingView(deviceId: 'DEV-TEST'));
      await stall(tester, s);

      expect(find.text('Device type unavailable'), findsOneWidget);
      expect(find.text('Connection unstable'), findsNothing);
      await tester.pumpWidget(const SizedBox()); // dispose the repaint timer
    });

    testWidgets('unanswered polls change the copy to say why', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      ble.failures = 3;
      await pumpUnder(tester, s, const ClassPendingView(deviceId: 'DEV-TEST'));
      await stall(tester, s);

      expect(find.text('Connection unstable'), findsOneWidget);
      expect(find.text('Device type unavailable'), findsNothing);
      expect(
          find.textContaining('3 polls have gone unanswered'), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); // dispose the repaint timer
    });

    testWidgets('a unit that is answering does not get blamed for slow writes',
        (tester) async {
      // FB-20. A power bank's single GATT write takes 3.96-4.95 s to complete
      // and our write timeout is 5 s, so ~11.6 per 1000 of its writes fail
      // while the unit is streaming 0x19/0x20/0x21/0x37 at 1.3-1.65 Hz. The
      // failure counter is therefore non-zero on a link that is demonstrably
      // alive, and "connection unstable" is the wrong thing to tell that user.
      //
      // The class cannot gate this — the view exists because the class is
      // unknown — so the discriminator is whether any frame has arrived at all.
      final s = await makeServices(tester);
      addTearDown(() => tester.runAsync(s.dispose));
      ble.failures = 3;
      await pumpUnder(tester, s, const ClassPendingView(deviceId: 'DEV-TEST'));
      await tester.runAsync(() async {
        ble.emitLink(BleLinkState.ready);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        ble.emitTelemetry(TelemetrySample(timestamp: DateTime.now()));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(
          kClassPendingTimeout + const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Connection unstable'), findsNothing,
          reason: 'the unit answered — the slow writes are not instability');
      expect(find.text('Device type unavailable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); // dispose the repaint timer
    });
  });

  group('the grace window', () {
    test('is 500 ms, and the timeout is an order of magnitude past it', () {
      // 500 ms was a product call, not a reading of the distribution — the
      // sample that once favoured it (slowest interval 0.301 s) was superseded
      // by one whose slowest is 43.9 s, which no sub-second threshold covers.
      expect(kClassPendingGrace, const Duration(milliseconds: 500));
      // The timeout is NOT tuned to the typical case (p50 0.061 s); it is held
      // wide because two verified samples sit far beyond it.
      expect(kClassPendingTimeout, const Duration(seconds: 6));
      expect(kClassPendingTimeout > kClassPendingGrace * 10, isTrue);
    });
  });
}
