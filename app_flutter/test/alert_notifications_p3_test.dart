// Design 0080 P3 — the evaluator wired to the telemetry loop, and the gate
// between what it decides and what the phone does about it.
//
// WHAT THIS FILE IS PROTECTING, stated once because most groups below are an
// instance of it: **evaluating and notifying are two steps, and only the second
// one is gated** (§0.2.1, ruling Q3). Every shortcut that collapses them passes
// the obvious tests. An unsaved unit that is never evaluated still renders a
// dashboard; a mute implemented by not folding still goes quiet; a gate checked
// before `fold` still stops the notification. What each of those silently loses
// is the on-screen warning an unsaved unit has had since long before this
// design existed — and nothing turns red when it goes.
//
// The other half is design 0038's honesty rule at the disconnect edge: when the
// link drops, everything is forgotten and NOTHING is said. There is no "back to
// normal" message, because we did not watch it come back — we stopped watching.
// A test that only counted notifications would be satisfied by an
// implementation that posted one; hence the explicit zero.
//
// CLEAN-ROOM: expectations derive from this project's own source and design 0080.
import 'dart:async';

import 'package:clock/clock.dart';
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
import 'package:open_smart_batt/ui/alerts/alert_event_banner.dart';
import 'package:open_smart_batt/ui/alerts/alert_settings_page.dart';
import 'package:open_smart_batt/ui/widgets/industrial.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _unitA = 'AA:BB:CC:DD:EE:01';
const String _unitB = 'AA:BB:CC:DD:EE:02';

/// t0 for every clock in this file. Fixed rather than `DateTime.now()` so a
/// failure reads the same on every machine and at every hour of the day.
final DateTime _t0 = DateTime.utc(2026, 8, 22, 14, 32);

class _FakeBle extends BleService {
  final _telemetry = StreamController<TelemetrySample>.broadcast();
  final _links = StreamController<BleLinkState>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetry.stream;

  @override
  Stream<BleLinkState> get linkState => _links.stream;

  void emit(TelemetrySample s) => _telemetry.add(s);

  void link(BleLinkState s) => _links.add(s);

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<void> dispose() async {
    await _telemetry.close();
    await _links.close();
    await super.dispose();
  }
}

/// A `0x02` battery that reports its own `0x2B` — layer ②, the ordinary case.
///
/// `deviceType` is not optional decoration: without it the wire class is
/// `unknown` and §7.5.6 C-2 switches the whole unit off, so every assertion
/// below would pass for the wrong reason.
TelemetrySample _battery({
  double? pvlt,
  int? temperatureC,
  double warnOv = 15.0,
  double warnUv = 11.0,
  double warnOt = 80,
}) =>
    TelemetrySample(
      timestamp: _t0,
      deviceType: 0x02,
      pvlt: pvlt,
      temperatureC: temperatureC,
      warnOv: warnOv,
      warnUv: warnUv,
      warnOt: warnOt,
      mode: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  // =========================================================================
  // The state machine, now that it has a caller
  // =========================================================================
  group('AlertController: fold, gate, notify', () {
    late AppServices services;
    late NoopAlertNotifier notifier;

    /// Boot with the feature ON — the tests below are about what happens after
    /// the switch, and ruling Q4's default OFF has its own test in the P2 file.
    Future<void> boot({
      List<SavedDevice> seed = const [],
      bool enabled = true,
    }) async {
      final db = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      notifier = NoopAlertNotifier();
      services = await AppServices.create(
          appDatabase: db, ble: _FakeBle(), alertNotifier: notifier);
      for (final d in seed) {
        await services.devices.save(d);
      }
      if (enabled) await services.settings.setAlertsEnabled(true);
    }

    tearDown(() async => services.dispose());

    /// Feed one frame as if the wall clock read `_t0 + [at]`.
    ///
    /// `withClock` rather than a real delay: the machine measures wall-clock
    /// persistence through `package:clock` (FB-66's手法), so a test can put
    /// 4.9 s and 5.0 s either side of the boundary exactly, in microseconds of
    /// real time.
    void feed(String deviceId, TelemetrySample s, Duration at) =>
        withClock(Clock.fixed(_t0.add(at)),
            () => services.alerts.onSample(deviceId, s));

    test('a sustained breach produces exactly ONE notification', () async {
      await boot(seed: const [SavedDevice(id: _unitA, alias: '阿福的機車')]);

      feed(_unitA, _battery(pvlt: 10.82), Duration.zero);
      expect(notifier.posted, isEmpty, reason: 'the first sample only starts the stopwatch');

      // 4.9 s: still inside the debounce. This is the whole of ruling C1 — a
      // momentary bad contact must not wake anybody.
      feed(_unitA, _battery(pvlt: 10.82), const Duration(milliseconds: 4900));
      expect(notifier.posted, isEmpty);

      feed(_unitA, _battery(pvlt: 10.82), const Duration(seconds: 5));
      expect(notifier.posted, hasLength(1));

      // …and the frames that keep arriving in the next second do not each add
      // one. The repeat interval is 15 minutes.
      for (var i = 1; i <= 5; i++) {
        feed(_unitA, _battery(pvlt: 10.80),
            Duration(seconds: 5, milliseconds: 200 * i));
      }
      expect(notifier.posted, hasLength(1));
    });

    test('§3.5.3 — the body carries the reading AND the limit', () async {
      await boot(seed: const [SavedDevice(id: _unitA, alias: '阿福的機車')]);
      services.alerts.setNotificationStrings(_englishStrings());

      feed(_unitA, _battery(pvlt: 10.82), Duration.zero);
      feed(_unitA, _battery(pvlt: 10.82), const Duration(seconds: 5));

      final n = notifier.posted.single;
      // The alias comes from `saved_devices` — which is exactly why an unsaved
      // unit cannot be notified about (ruling Q3).
      expect(n.title, '阿福的機車 · voltage too low');
      // Both numbers, so severity is readable without opening the app.
      expect(n.body, contains('10.82'));
      expect(n.body, contains('11.00'));
      // …and the time it was decided, in a form that needs no locale.
      expect(n.body, contains('14:32'));
      // The tap has to reach THIS unit's settings, so the payload is its id.
      expect(n.payload, _unitA);
    });

    test('🔴 Q3 — an UNSAVED unit is evaluated and drawn, and never notified',
        () async {
      // The implementation discipline of §3.6.3 in one test. An unsaved unit's
      // thresholds can only come from layer ② (its own `0x2B`), which is
      // exactly what the advisory line has always read — so its on-screen
      // behaviour must be unchanged by this feature, "只多不少".
      await boot();

      feed(_unitA, _battery(pvlt: 10.82), Duration.zero);
      feed(_unitA, _battery(pvlt: 10.82), const Duration(seconds: 5));

      expect(notifier.posted, isEmpty, reason: 'ruling Q3: no notification');
      expect(services.alerts.evaluator.activeAlerts(_unitA),
          contains(AlertKind.underVoltage),
          reason: 'the state machine still ran — the gate is on the OUTPUT');
      expect(services.alerts.eventsFor(_unitA), hasLength(1),
          reason: 'and the banner still has something to draw');
    });

    test('the per-device switch and the 1-hour mute both stop it', () async {
      await boot(seed: const [
        SavedDevice(id: _unitA, alias: 'off', alertEnabled: false),
      ]);
      feed(_unitA, _battery(pvlt: 10.82), Duration.zero);
      feed(_unitA, _battery(pvlt: 10.82), const Duration(seconds: 5));
      expect(notifier.posted, isEmpty);
      expect(services.alerts.eventsFor(_unitA), hasLength(1),
          reason: 'switched off is still watched, just not announced');
    });

    test('🔴 a mute expires and the alarm comes back', () async {
      // §7.5.3: a suppressed emission still spends its budget, so "which one,
      // and when" stays a pure function of the reading and the clock. The
      // consequence is stated in the design and pinned here: the mute does not
      // shift the schedule, it only silences whatever the schedule produced.
      await boot(seed: [
        SavedDevice(
          id: _unitA,
          alias: '阿福的機車',
          alertMutedUntilMs:
              _t0.add(const Duration(minutes: 10)).millisecondsSinceEpoch,
        ),
      ]);

      feed(_unitA, _battery(pvlt: 10.82), Duration.zero);
      feed(_unitA, _battery(pvlt: 10.82), const Duration(seconds: 5));
      expect(notifier.posted, isEmpty, reason: 'muted');

      // The repeat falls after the mute ran out.
      feed(_unitA, _battery(pvlt: 10.82),
          const Duration(minutes: 15, seconds: 5));
      expect(notifier.posted, hasLength(1));
    });

    test('🔴 the notification id is per (unit, kind) — a repeat UPDATES',
        () async {
      await boot(seed: const [SavedDevice(id: _unitA, alias: '阿福的機車')]);

      feed(_unitA, _battery(pvlt: 10.82), Duration.zero);
      feed(_unitA, _battery(pvlt: 10.82), const Duration(seconds: 5));
      feed(_unitA, _battery(pvlt: 10.70),
          const Duration(minutes: 15, seconds: 5));

      expect(notifier.posted, hasLength(2));
      expect(notifier.posted[0].id, notifier.posted[1].id,
          reason: 'one row on the shade, updated — not a growing pile');
      expect(notifier.posted[1].body, contains('10.70'),
          reason: 'and the update carries the CURRENT reading');
    });

    test('🔴 disconnect clears everything and says NOTHING (§3.3.2)', () async {
      await boot(seed: const [SavedDevice(id: _unitA, alias: '阿福的機車')]);

      feed(_unitA, _battery(pvlt: 10.82), Duration.zero);
      feed(_unitA, _battery(pvlt: 10.82), const Duration(seconds: 5));
      expect(notifier.posted, hasLength(1));

      services.alerts.onLinkLost();

      expect(services.alerts.eventsFor(_unitA), isEmpty);
      expect(services.alerts.evaluator.activeAlerts(_unitA), isEmpty);
      // 🔴 The zero that matters. We did not see it recover; we stopped
      // looking, and a "back to normal" message would be a claim about data we
      // do not have.
      expect(notifier.posted, hasLength(1), reason: 'no "all clear" was sent');
      // The already-delivered one is left alone: it is a record of something
      // that was true when it was written, unlike the foreground service's
      // ongoing row, which design 0038 §1.2 dismisses precisely because it
      // claims to be live.
      expect(notifier.cancelled, isEmpty);

      // …and the budget went with it: a reconnecting unit that is still
      // breaching opens a NEW event rather than inheriting a spent one.
      feed(_unitA, _battery(pvlt: 10.82), const Duration(minutes: 30));
      feed(_unitA, _battery(pvlt: 10.82),
          const Duration(minutes: 30, seconds: 5));
      expect(notifier.posted, hasLength(2));
    });

    test('🔴 "not again this connection" survives the page and dies with the link',
        () async {
      // §7.6.4 hand-over 1. P2 parked this on the settings page's State, so it
      // died when the user popped the page — and reading the mute controls is
      // the most likely reason to leave. It now lives beside the evaluator.
      await boot(seed: const [SavedDevice(id: _unitA, alias: '阿福的機車')]);
      services.alerts.setSessionSilenced(_unitA, true);

      feed(_unitA, _battery(pvlt: 10.82), Duration.zero);
      feed(_unitA, _battery(pvlt: 10.82), const Duration(seconds: 5));
      expect(notifier.posted, isEmpty);
      expect(services.alerts.isSessionSilenced(_unitA), isTrue);

      services.alerts.onLinkLost();
      expect(services.alerts.isSessionSilenced(_unitA), isFalse,
          reason: 'the promise was about a connection, and it is over');
    });

    test('the global switch is the outermost gate', () async {
      await boot(
          seed: const [SavedDevice(id: _unitA, alias: '阿福的機車')],
          enabled: false);
      feed(_unitA, _battery(pvlt: 10.82), Duration.zero);
      feed(_unitA, _battery(pvlt: 10.82), const Duration(seconds: 5));
      expect(notifier.posted, isEmpty);
      // Still evaluated. Ruling Q4's default OFF must not cost the screen its
      // advisory, which predates the whole feature.
      expect(services.alerts.eventsFor(_unitA), hasLength(1));
    });

    test('the three tunables follow the settings without resetting an event',
        () async {
      await boot(seed: const [SavedDevice(id: _unitA, alias: '阿福的機車')]);
      await services.settings.setAlertSustainSec(2);

      feed(_unitA, _battery(pvlt: 10.82), Duration.zero);
      feed(_unitA, _battery(pvlt: 10.82), const Duration(seconds: 2));
      expect(notifier.posted, hasLength(1), reason: 'the shorter sustain applied');

      // Moving a parameter mid-event must not silently clear the machine —
      // §7.5.5's answer for a threshold, carried to the config.
      await services.settings.setAlertRepeatMin(1);
      feed(_unitA, _battery(pvlt: 10.82), const Duration(seconds: 3));
      expect(notifier.posted, hasLength(1), reason: 'still inside the new interval');
      feed(_unitA, _battery(pvlt: 10.82), const Duration(seconds: 63));
      expect(notifier.posted, hasLength(2));
    });

    test('an unrecognised device type is watched for nothing at all', () async {
      // §7.5.6 C-2, from the caller's side: no evaluation, no event, no
      // notification — even though the unit reported a perfectly good `0x2B`.
      await boot(seed: const [SavedDevice(id: _unitA, alias: '阿福的機車')]);
      final alien = TelemetrySample(
        timestamp: _t0,
        deviceType: 0x7e,
        pvlt: 10.82,
        warnUv: 11.0,
        mode: 0,
      );
      feed(_unitA, alien, Duration.zero);
      feed(_unitA, alien, const Duration(seconds: 5));
      expect(notifier.posted, isEmpty);
      expect(services.alerts.eventsFor(_unitA), isEmpty);
    });

    test('a tap on a notification arrives as the unit it was about', () async {
      await boot();
      final seen = <String>[];
      final sub = services.alerts.onNotificationTapped.listen(seen.add);
      notifier.tap(_unitB);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(seen, [_unitB]);
    });
  });

  test('alertNotificationId: one id per (unit, kind), and it never moves', () {
    // The de-duplication is only as good as the key, and nothing else in the
    // app would notice these colliding — a collision shows up as one battery's
    // alert silently overwriting another's.
    final ids = <int>{
      for (final id in [_unitA, _unitB])
        for (final k in AlertKind.values) alertNotificationId(id, k),
    };
    expect(ids, hasLength(6));
    // 🔴 And it is STABLE. `Object.hash` / `String.hashCode` promise nothing
    // across runs, and the failure that would cause is silent: a phone that
    // restarted stops REPLACING the row and starts stacking new ones.
    expect(alertNotificationId(_unitA, AlertKind.underVoltage), 812216677,
        reason: 'FNV-1a over "<id>#underVoltage", masked to 31 bits');
  });

  // =========================================================================
  // The wiring — that `_onTelemetry` and `_onLinkState` actually call it
  // =========================================================================
  group('TelemetryController drives the alert layer', () {
    late AppDatabase db;
    late _FakeBle ble;
    late SessionContext session;
    late TelemetryController tele;
    late _RecordingSink sink;

    setUp(() async {
      db = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      ble = _FakeBle();
      session = SessionContext();
      tele = TelemetryController(
        ble,
        settings: SettingsController(SettingsRepo(db.db)),
        history: HistoryRepo(db.db),
        logs: LogRepo(db.db),
        session: session,
      );
      sink = _RecordingSink();
      tele.bindAlerts(sink);
    });

    tearDown(() async {
      await tele.pendingWrites.drain();
      tele.dispose();
      await ble.dispose();
      await db.close();
    });

    test('every decoded frame reaches the sink, attributed to the session',
        () async {
      session.begin(_unitA);
      ble.emit(_battery(pvlt: 13.31));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sink.samples, hasLength(1));
      expect(sink.samples.single.$1, _unitA);
    });

    test('🔴 a frame from the PREVIOUS unit never reaches it (FB-88 / 0078)',
        () async {
      // The guard at the top of `_onTelemetry` is design 0078's, and this is
      // why the alert hook lives INSIDE that method rather than on its own
      // subscription: a second listener would see the frames it drops and judge
      // them against the wrong unit's limits.
      session.begin(_unitB);
      ble.emit(_battery(pvlt: 10.0).copyWith(deviceId: _unitA));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sink.samples, isEmpty);
    });

    test('a disconnect calls onLinkLost exactly once', () async {
      session.begin(_unitA);
      ble.link(BleLinkState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sink.lost, 1);
    });
  });

  // =========================================================================
  // The screen
  // =========================================================================
  group('the event banner and the session mute', () {
    late AppServices services;
    late NoopAlertNotifier notifier;
    late _FakeBle ble;

    Future<void> boot(WidgetTester tester, List<SavedDevice> seed) async {
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
            path: inMemoryDatabasePath, factory: databaseFactoryFfi);
        notifier = NoopAlertNotifier();
        ble = _FakeBle();
        services = await AppServices.create(
            appDatabase: db, ble: ble, alertNotifier: notifier);
        for (final d in seed) {
          await services.devices.save(d);
        }
        await services.settings.setAlertsEnabled(true);
      });
    }

    Future<void> pump(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<AppServices>.value(value: services),
            Provider<BleService>.value(value: services.ble),
            Provider<DeviceRepo>.value(value: services.deviceRepo),
            ChangeNotifierProvider<SettingsController>.value(
                value: services.settings),
            ChangeNotifierProvider<DeviceController>.value(
                value: services.devices),
            ChangeNotifierProvider<DeviceFactsController>.value(
                value: services.facts),
            ChangeNotifierProvider<ConnectionController>.value(
                value: services.connection),
            ChangeNotifierProvider<TelemetryController>.value(
                value: services.telemetry),
            ChangeNotifierProvider<AlertController>.value(
                value: services.alerts),
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

    /// Raise a real event, through the real controller, and put the same frame
    /// on the telemetry stream.
    ///
    /// Both halves are needed because the banner reads them from two places on
    /// purpose: what is RAISED comes from [AlertController], the live READING
    /// from [TelemetryController] — see [AlertEvent] for why the reading is not
    /// carried on the event.
    Future<void> raise(WidgetTester tester, String deviceId) async {
      final s = _battery(pvlt: 10.82);
      withClock(Clock.fixed(_t0), () => services.alerts.onSample(deviceId, s));
      withClock(Clock.fixed(_t0.add(const Duration(seconds: 5))),
          () => services.alerts.onSample(deviceId, s));
      await tester.runAsync(() async {
        ble.emit(s);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
    }

    /// Raise BOTH kinds — used to test that a NEW kind reopens a collapsed
    /// banner (design 0086 Q3).
    Future<void> raiseBoth(WidgetTester tester, String deviceId) async {
      final s = _battery(pvlt: 10.82, temperatureC: 95);
      withClock(Clock.fixed(_t0), () => services.alerts.onSample(deviceId, s));
      withClock(Clock.fixed(_t0.add(const Duration(seconds: 5))),
          () => services.alerts.onSample(deviceId, s));
      await tester.runAsync(() async {
        ble.emit(s);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
    }

    tearDown(() async => services.dispose());

    testWidgets('nothing raised ⇒ nothing drawn', (tester) async {
      await boot(tester, const [SavedDevice(id: _unitA, alias: 'a')]);
      await pump(tester, const AlertEventBanner(deviceId: _unitA));
      expect(find.text('Warning raised'), findsNothing);
    });

    testWidgets('🔴 an UNSAVED unit gets the banner too (ruling Q3)',
        (tester) async {
      await boot(tester, const []);
      await raise(tester, _unitA);
      await pump(tester, const AlertEventBanner(deviceId: _unitA));

      expect(find.text('Warning raised'), findsOneWidget);
      // Reading AND limit — two of the three are useless on their own.
      expect(find.textContaining('10.82'), findsOneWidget);
      expect(find.textContaining('11.00'), findsOneWidget);
      // …and it says WHY the phone stayed quiet, rather than leaving the user
      // to notice an absence.
      //
      // 🔵 design 0086 S3 changed WHICH sentence does that. It used to read
      // "This device is not saved, so …"; the unsaved card is drawn directly
      // below the banner and already says that, and the screenshot that
      // started 0086 had the line twice on one screen. The banner now keeps
      // only the half that card does not carry — the phone staying silent.
      expect(find.textContaining('will not ring'), findsOneWidget);
      expect(find.textContaining('not saved'), findsNothing);
      expect(notifier.posted, isEmpty);
    });

    testWidgets('a saved unit gets the duration and a way to the settings',
        (tester) async {
      await boot(tester, const [SavedDevice(id: _unitA, alias: '阿福的機車')]);
      await raise(tester, _unitA);
      await pump(tester, const AlertEventBanner(deviceId: _unitA));
      expect(find.text('Warning raised'), findsOneWidget);
      expect(find.textContaining('for '), findsOneWidget);
      expect(find.text('Warnings'), findsOneWidget);
      // Nothing suppressed it, so there is no explanation to give.
      expect(find.textContaining('not saved'), findsNothing);
      expect(find.textContaining('will not ring'), findsNothing);
    });

    // ── design 0086：可收合，但不可關閉 ────────────────────────────────

    testWidgets('0086 — ✕ 收合成一行，但警告沒有消失', (tester) async {
      await boot(tester, const [SavedDevice(id: _unitA, alias: 'a')]);
      await raise(tester, _unitA);
      await pump(tester, const AlertEventBanner(deviceId: _unitA));
      expect(find.text('Warning raised'), findsOneWidget);

      await tester.tap(find.byTooltip('Collapse'));
      await tester.pump();

      // 標題與「已持續」不見了 —— 那是「縮小」。
      expect(find.text('Warning raised'), findsNothing);
      expect(find.textContaining('for '), findsNothing);
      // 🔴 但 wire 讀數那一行還在：收合 ≠ 關閉。這條就是 design 0080 §5
      // 「不用捲就看得到有事」在收合態仍然成立的證據。
      expect(find.textContaining('10.82'), findsOneWidget);
    });

    testWidgets('0086 — 再點那一行就跳回來（擁有者原話）', (tester) async {
      await boot(tester, const [SavedDevice(id: _unitA, alias: 'a')]);
      await raise(tester, _unitA);
      await pump(tester, const AlertEventBanner(deviceId: _unitA));
      await tester.tap(find.byTooltip('Collapse'));
      await tester.pump();
      expect(find.text('Warning raised'), findsNothing);

      // 「再點警告會跳出來」—— 目標是警告那一行本身，不是另一顆按鈕。
      await tester.tap(find.textContaining('10.82'));
      await tester.pump();
      expect(find.text('Warning raised'), findsOneWidget);
    });

    testWidgets('0086 Q2 🔴 收合只活在這條連線裡 —— 斷線後回到展開', (tester) async {
      await boot(tester, const [SavedDevice(id: _unitA, alias: 'a')]);
      await raise(tester, _unitA);
      await pump(tester, const AlertEventBanner(deviceId: _unitA));
      await tester.tap(find.byTooltip('Collapse'));
      await tester.pump();
      expect(services.alerts.isBannerCollapsed(_unitA), isTrue);

      // 擁有者逐字「只有這次連線有效」⇒ 與 _sessionSilenced 同一個清除點。
      services.alerts.onLinkLost();
      expect(services.alerts.isBannerCollapsed(_unitA), isFalse);
    });

    testWidgets('0086 Q3 — 收合中又升起新的一種，自動展開', (tester) async {
      await boot(tester, const [SavedDevice(id: _unitA, alias: 'a')]);
      await raise(tester, _unitA);                 // 只有欠壓
      services.alerts.setBannerCollapsed(_unitA, true);
      expect(services.alerts.isBannerCollapsed(_unitA), isTrue);

      await raiseBoth(tester, _unitA);             // ＋過溫
      // 收合表達的是「這一則我看過了」，不是靜音 ⇒ 新資訊要跳出來。
      expect(services.alerts.isBannerCollapsed(_unitA), isFalse);
    });

    testWidgets('0086 Q3 — 少一種不算新資訊，維持收合', (tester) async {
      await boot(tester, const [SavedDevice(id: _unitA, alias: 'a')]);
      await raiseBoth(tester, _unitA);             // 兩種都在
      services.alerts.setBannerCollapsed(_unitA, true);
      expect(services.alerts.isBannerCollapsed(_unitA), isTrue);

      await raise(tester, _unitA);                 // 過溫解除，只剩欠壓
      // 警告解除不是新資訊 —— 不該把使用者收好的東西再彈開。
      expect(services.alerts.isBannerCollapsed(_unitA), isTrue);
    });

    testWidgets('0086 — 多於一則時，收合列要說出還有幾則', (tester) async {
      await boot(tester, const [SavedDevice(id: _unitA, alias: 'a')]);
      await raiseBoth(tester, _unitA);
      await pump(tester, const AlertEventBanner(deviceId: _unitA));
      await tester.tap(find.byTooltip('Collapse'));
      await tester.pump();
      // 收合絕不隱藏「還有幾則」這個事實。
      expect(find.text('+1'), findsOneWidget);
    });

    testWidgets(
        '🔴 §7.6.4 — 「本次連線不再提醒」 survives leaving the page',
        (tester) async {
      await boot(tester, const [SavedDevice(id: _unitA, alias: '阿福的機車')]);
      await pump(tester, const _PageOpener(deviceId: _unitA));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final sw = find.descendant(
        of: find.ancestor(
          of: find.text('Not again this connection'),
          matching: find.byType(SettingsRow),
        ),
        matching: find.byType(Switch),
      );
      await tester.tap(sw);
      await tester.pumpAndSettle();
      expect(services.alerts.isSessionSilenced(_unitA), isTrue);

      // Leave and come back — P2's version died right here.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(sw).value, isTrue);
    });
  });
}

/// A `AlertSettingsPage` behind a button, so a test can pop back to something.
class _PageOpener extends StatelessWidget {
  const _PageOpener({required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => AlertSettingsPage(deviceId: deviceId),
        )),
        child: const Text('open'),
      );
}

class _RecordingSink implements TelemetryAlertSink {
  final List<(String?, TelemetrySample)> samples = [];
  int lost = 0;

  @override
  void onSample(String? deviceId, TelemetrySample sample) =>
      samples.add((deviceId, sample));

  @override
  void onLinkLost() => lost++;
}

/// The strings `main.dart` hands over on the first frame, restated here so the
/// notification-content test asserts against real copy rather than the neutral
/// placeholder.
AlertNotificationStrings _englishStrings() => AlertNotificationStrings(
      channelName: 'Warnings',
      channelDescription: 'A reading passed a limit you set',
      overVoltage: 'voltage too high',
      underVoltage: 'voltage too low',
      overTemperature: 'temperature too high',
      title: (alias, kind) => '$alias · $kind',
      bodyVolts: (r, t, time) => 'Now $r V, limit $t V · $time',
      bodyCelsius: (r, t, time) => 'Now $r °C, limit $t °C · $time',
    );
