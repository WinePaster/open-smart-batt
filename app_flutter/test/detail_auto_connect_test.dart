// FB-75 — opening a SAVED unit's page connects to it, once.
//
// 🔑 What this file is really guarding is the list of reasons NOT to connect.
// The feature itself is one call; every defect it could cause lives in a gate:
//
//   * the service is single-connection, so auto-connecting from B's page would
//     tear down A's live link (A2);
//   * two connects 1.9 s apart once ran GATT setup twice on one link and
//     doubled 18 minutes of telemetry — 2026.08.13/001 — so the latch and the
//     busy/retrying/armed gates are not belt-and-braces (A3, A9);
//   * FB-50 units reach `connected` and never `ready` (42.4 % of connections in
//     one capture). Without the stall gate each visit to the page would start a
//     fresh doomed attempt (A5);
//   * a page showing a failure report with a retry button on it must not retry
//     by itself (A4).
//
// 🔴 THE SCAN-VISIBILITY GATE IS GONE (FB-82 Q2, ruled 2026-08-17), and A11–A15
// now pin its ABSENCE. It used to refuse whenever the saved unit was not in the
// current scan results, which on iOS meant: opening this page stops the scan, so
// a page opened before the list had discovered anything never connected on that
// trip — the owner's own report on v0.7.22. It was retired because the retry
// button on this same screen never had it, because iOS resolves a saved
// remoteId through `retrievePeripheralsWithIdentifiers` and needs no scan, and
// because the FB-52/FB-53 regression it guarded against is bounded on both ends
// (an id iOS does not know fails immediately; a failed FIRST connect starts no
// ladder). The duplicate-name safety that used to be tested through it did not
// live in it — it is `rebindSavedDeviceId`'s unique-match rule, pinned in
// `ios_port_test.dart`.
//
// 📌 THE GATES ARE NOW TESTED IN TWO FILES — the other half is
// `devices_page_test.dart`, in the `FB-92` group's ARRIVING block. FB-92
// (2026-08-21, pro design 0075) turned the list's 連線 button into a door, so
// this page is now ENTERED on links the list itself started: once on `ready`
// (§6.2 pushes when it is usable ⇒ `already online`) and once on GATT
// `connected` (owner's ruling (c): pressing the spinning button means 「我不想
// 等，現在就過去」 ⇒ `link busy`). Neither entrance existed when design 0072
// wrote these gates, and neither can be pumped here: they need the list, a real
// `Navigator.push` and a link driven into a stated phase, where this file
// states each gate directly against a page pumped as `home`. Nothing below is
// weakened by that — but a reader who assumes all nine gates' coverage is in
// this file will be wrong about two doors, so it is said here rather than left
// to be discovered.
//
// CLEAN-ROOM: expectations derive from this project's own source and field
// captures.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/l10n/app_localizations_en.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/devices/device_detail_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// No radio. Nothing here may reach the (unsupported) platform channel.
class _FakeBle extends BleService {
  @override
  String? get connectedDeviceId => null;

  @override
  Stream<BleLinkState> get linkState => const Stream<BleLinkState>.empty();

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<TelemetrySample> get telemetry =>
      const Stream<TelemetrySample>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? timeout,
    bool autoConnect = false,
  }) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> stopScan() async {}
}

/// A controller whose gate answers a test can simply state, and which counts
/// what the page asked it to do.
class _CountingConn extends ConnectionController {
  _CountingConn(super.ble, {required super.settings});

  int connectToSavedCalls = 0;
  String? lastTargetId;

  bool online = false;
  bool busy = false;
  bool retrying = false;
  bool armed = false;
  bool stalled = false;
  bool adapterOn = true;
  String? error;
  List<DiscoveredDevice> results = const [];

  /// Whose error/stall the controller's singular fields belong to. `_OfflineBody`
  /// gates the whole failure report on this matching the page's unit, so a test
  /// about a card that must STAY on screen (A27/A28) has to set it.
  String? current;

  @override
  String? get connectedDeviceId => current;

  @override
  bool get isOnline => online;

  @override
  bool get isBusy => busy;

  @override
  bool get isRetrying => retrying;

  @override
  bool get isAutoConnectArmed => armed;

  /// Whose stall it is (FB-86, second half) — stated for the same reason
  /// [errorDeviceId] is: the gate now asks per unit, so a test that leaves this
  /// null is asserting about a latch belonging to nobody.
  String? stalledDeviceId;

  @override
  bool isSetupStalledFor(String? deviceId) =>
      stalled && stalledDeviceId == deviceId;

  @override
  bool get isSetupStalledUnattributed => stalled;

  @override
  bool get isAdapterOn => adapterOn;

  /// Whose error it is (FB-86). Null means RADIO-LEVEL — true of every unit —
  /// which is the default these copy tests want: they are about what a code
  /// draws, not about which unit it belongs to.
  String? errorDeviceId;

  @override
  String? lastErrorFor(String? deviceId) {
    final e = error;
    return e == null
        ? null
        : ConnectionError(e, deviceId: errorDeviceId).codeFor(deviceId);
  }

  @override
  String? get lastErrorUnattributed => error;

  /// 🔴 COUNTED, and that counter is the only host-independent way to pin
  /// FB-82 Q2 (see A11/A12). `Platform.isIOS` is false on this host, so the
  /// gate that was removed would have PASSED here whatever the scan list held
  /// — a test asserting "empty list and it still connected" would stay green
  /// with the gate put back. What cannot stay green is the page touching this
  /// getter at all: the old call site built its candidate map from it eagerly,
  /// before any platform check.
  int scanReads = 0;

  @override
  List<DiscoveredDevice> get scanResults {
    scanReads++;
    return results;
  }

  @override
  Future<void> connectToSaved(SavedDevice device) async {
    connectToSavedCalls++;
    lastTargetId = device.id;
  }

  /// FB-82. Captured rather than written: the real one goes to the diagnostic
  /// log, which this suite has no `LogRepo` for — and the question these tests
  /// ask is whether the PAGE decided to say something, not whether sqlite
  /// stored it.
  final List<String> skips = <String>[];

  @override
  void noteAutoConnectSkipped(String reason, {String? deviceId}) =>
      skips.add(reason);

  /// Make the page's `didChangeDependencies` run again, which is what the
  /// one-shot latch has to survive.
  void bump() => notifyListeners();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late _FakeBle ble;
  late AppServices services;
  late _CountingConn conn;

  /// Boot with DEV-A saved. [configure] runs BEFORE the page is pumped, so a
  /// gate is already in the state the test is about when the page first asks.
  Future<void> boot(
    WidgetTester tester, {
    String deviceId = 'DEV-A',
    void Function(_CountingConn conn)? configure,
    bool saveDevice = true,
  }) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _FakeBle();
      services = await AppServices.create(appDatabase: db, ble: ble);
      if (saveDevice) {
        await services.devices.saveNew('DEV-A', 'Cap #1', name: 'RCE-SCAP_II');
      }
    });
    conn = _CountingConn(ble, settings: services.settings);
    configure?.call(conn);
    addTearDown(() {
      conn.dispose();
      return tester.runAsync(services.dispose);
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(
            value: services.settings,
          ),
          ChangeNotifierProvider<DeviceController>.value(
            value: services.devices,
          ),
          ChangeNotifierProvider<ConnectionController>.value(value: conn),
          ChangeNotifierProvider<TelemetryController>.value(
            value: services.telemetry,
          ),
          ChangeNotifierProvider<GForceController>.value(
            value: services.gforce,
          ),
          ChangeNotifierProvider<GpsSpeedController>.value(
            value: services.speed,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: DeviceDetailPage(deviceId: deviceId),
        ),
      ),
    );
    // The attempt is deferred to the end of the frame, for the same reason
    // `_setVisible` is: it notifies listeners, and `didChangeDependencies` runs
    // inside the build phase.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('A1: a saved unit connects once when nothing is in the way', (
    tester,
  ) async {
    await boot(tester);

    expect(conn.connectToSavedCalls, 1);
    expect(conn.lastTargetId, 'DEV-A');
  });

  testWidgets('A2: never while a link is up — the service holds only one', (
    tester,
  ) async {
    await boot(tester, configure: (c) => c.online = true);

    expect(
      conn.connectToSavedCalls,
      0,
      reason:
          'BleService._links holds 0 or 1 and connect() awaits '
          'disconnect() first, so this would silently drop the unit the '
          'user is actually watching',
    );
  });

  testWidgets('A3: never while one is already in flight', (tester) async {
    await boot(tester, configure: (c) => c.busy = true);
    expect(conn.connectToSavedCalls, 0);
  });

  testWidgets('A4: never on top of a failure the user is reading', (
    tester,
  ) async {
    // FB-86: and the failure has to BE this unit's, which is now stated rather
    // than assumed. Leaving `errorDeviceId` null would say "the radio", which
    // is true of every unit and would pass for the wrong reason.
    await boot(
      tester,
      configure: (c) => c
        ..error = 'device_unreachable'
        ..errorDeviceId = 'DEV-A',
    );

    expect(
      conn.connectToSavedCalls,
      0,
      reason:
          'the page is showing a failure report WITH a retry button; '
          'pressing it for the user is the page arguing with them',
    );
  });

  testWidgets('A5: never once setup has stalled (FB-50)', (tester) async {
    // FB-86 (second half): and the stall has to BE this unit's, stated rather
    // than assumed — exactly as A4 states the error's owner.
    await boot(
      tester,
      configure: (c) => c
        ..stalled = true
        ..stalledDeviceId = 'DEV-A',
    );

    expect(
      conn.connectToSavedCalls,
      0,
      reason:
          'a unit that reaches connected and never ready would get a '
          'fresh doomed attempt on every visit',
    );
  });

  testWidgets('A6: never with the setting off', (tester) async {
    await boot(tester);
    // Re-boot semantics: the setting is read at the moment the page asks, so
    // flip it and rebuild the page rather than trusting a stale read.
    expect(conn.connectToSavedCalls, 1);

    await tester.runAsync(() => services.settings.setAutoReconnect(false));
    conn.connectToSavedCalls = 0;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(
            value: services.settings,
          ),
          ChangeNotifierProvider<DeviceController>.value(
            value: services.devices,
          ),
          ChangeNotifierProvider<ConnectionController>.value(value: conn),
          ChangeNotifierProvider<TelemetryController>.value(
            value: services.telemetry,
          ),
          ChangeNotifierProvider<GForceController>.value(
            value: services.gforce,
          ),
          ChangeNotifierProvider<GpsSpeedController>.value(
            value: services.speed,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          // A new key forces a fresh State, i.e. a fresh latch.
          home: const DeviceDetailPage(
            key: ValueKey('second'),
            deviceId: 'DEV-A',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // design 0065 mounts a history block on this page, and re-pumping a fresh
    // page builds a fresh one with a fresh set of queries. Real
    // database IO cannot settle under the fake clock, so it is drained here.
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();

    expect(conn.connectToSavedCalls, 0);
  });

  testWidgets('A7: never with the adapter off', (tester) async {
    await boot(tester, configure: (c) => c.adapterOn = false);
    expect(conn.connectToSavedCalls, 0);
  });

  testWidgets('A8: an unsaved unit is left to the user (design 0055)', (
    tester,
  ) async {
    await boot(tester, deviceId: 'DEV-UNSAVED');
    expect(conn.connectToSavedCalls, 0);
  });

  testWidgets('A9: armed or retrying counts as in flight', (tester) async {
    await boot(
      tester,
      configure: (c) => c
        ..armed = true
        ..retrying = true,
    );
    expect(conn.connectToSavedCalls, 0);
  });

  testWidgets('A10: at most one attempt per page, however often it rebuilds', (
    tester,
  ) async {
    await boot(tester);
    expect(conn.connectToSavedCalls, 1);

    // `didChangeDependencies` re-runs on any inherited-widget change. Notifying
    // the controllers the page depends on is the cheapest honest way to make
    // that happen; without the latch this is a connect loop.
    for (var i = 0; i < 3; i++) {
      conn.bump();
      await tester.pump();
      await tester.pump();
    }

    expect(
      conn.connectToSavedCalls,
      1,
      reason:
          '2026.08.13/001: two connects 1.9 s apart ran GATT setup twice '
          'on one link and doubled 18 minutes of telemetry',
    );
  });

  // ── FB-82 Q2: nothing scanned is no longer a reason not to connect ───────

  testWidgets('A11: NOTHING scanned and it still connects — the owner\'s own '
      'report (iPhone, v0.7.22)', (tester) async {
    // `scanResults` is empty here, which is the real state of this page on
    // iOS: opening it stops the scan (W-3), and a page opened straight after
    // launch never had results to begin with. Before FB-82 Q2 this was the one
    // gate that refused, and it refused silently.
    await boot(tester, configure: (c) => c.results = const []);

    expect(conn.connectToSavedCalls, 1);
    expect(conn.skips, isEmpty);
    expect(
      conn.scanReads,
      0,
      reason: 'this page no longer asks what is visible before connecting — '
          'and the reading, not the answer, is what a non-iOS host can see',
    );
  });

  testWidgets('A12: the page hands over the SAVED RECORD and lets the '
      'controller resolve it', (tester) async {
    // The page deliberately does not pre-resolve the id against the scan list
    // any more. `connectToSaved` re-binds a stale iOS NSUUID itself — and it is
    // also where the refusal to guess between two units advertising the same
    // name lives (`rebindSavedDeviceId`, unique match only). Splitting that
    // decision across two places is how one power bank's telemetry ends up
    // under the other's alias.
    await boot(
      tester,
      configure: (c) => c.results = const [
        DiscoveredDevice(id: 'SOMEONE-ELSE', name: 'RCE_RSPB-01', rssi: -60),
      ],
    );

    expect(conn.connectToSavedCalls, 1);
    expect(conn.lastTargetId, 'DEV-A');
    expect(conn.scanReads, 0);
  });

  // ── FB-82, on the page itself ───────────────────────────────────────────

  testWidgets('A22: a blocked page WRITES the reason (it used to say nothing)',
      (tester) async {
    await boot(tester, configure: (c) => c.adapterOn = false);

    expect(conn.connectToSavedCalls, 0);
    expect(conn.skips, hasLength(1));
    expect(conn.skips.single, contains('adapter'));
  });

  testWidgets('A23: a page that DID connect writes no skip line', (
    tester,
  ) async {
    await boot(tester);

    expect(conn.connectToSavedCalls, 1);
    expect(conn.skips, isEmpty,
        reason: 'the successful path already has `connect → X`; a second '
            'sentence about the same event is noise in the file a user exports');
  });

  testWidgets('A24: the same reason is written ONCE, however often the page '
      'is rebuilt', (tester) async {
    // 🔴 This is the defect the de-duplication exists for, and it produces no
    // error and nothing on screen: `didChangeDependencies` re-runs on every
    // notification from the two controllers this page watches, so an unguarded
    // line buries the one that matters under tens of copies of itself.
    await boot(tester, configure: (c) => c.adapterOn = false);
    for (var i = 0; i < 20; i++) {
      conn.bump();
      await tester.pump();
    }

    expect(conn.skips, hasLength(1));
  });

  testWidgets('A25: a gate that starts blocking LATER is still recorded', (
    tester,
  ) async {
    // The counterpart to A24: de-duplication is per REASON, not "log once and
    // stop". A page that arrives with the radio off and later picks up a stale
    // error has two different things to say.
    await boot(tester, configure: (c) => c.adapterOn = false);
    conn
      ..adapterOn = true
      ..error = 'device_stale'
      ..bump();
    await tester.pump();

    expect(conn.connectToSavedCalls, 0);
    expect(conn.skips, hasLength(2));
    expect(conn.skips.last, contains('device_stale'));
  });

  // ── FB-82: the gate that refused has to be sayable ──────────────────────
  //
  // 🔴 Why these exist. The owner reported on v0.7.22 that opening a saved
  // unit's page did not connect. Every gate above returned silently, so the
  // report could not be answered from an export — only by reading source and
  // guessing which platform the phone was. A2–A15 pin the DECISIONS; these pin
  // that the decision is legible afterwards.

  /// Everything open. Each test below flips exactly one input.
  String? blockerWith({
    bool isSaved = true,
    bool autoReconnect = true,
    bool isOnline = false,
    bool isBusy = false,
    bool isRetrying = false,
    bool isAutoConnectArmed = false,
    String? lastError,
    bool isSetupStalled = false,
    bool isAdapterOn = true,
  }) =>
      autoConnectBlocker(
        isSaved: isSaved,
        autoReconnect: autoReconnect,
        isOnline: isOnline,
        isBusy: isBusy,
        isRetrying: isRetrying,
        isAutoConnectArmed: isAutoConnectArmed,
        lastError: lastError,
        isSetupStalled: isSetupStalled,
        isAdapterOn: isAdapterOn,
      );

  test('A16: nothing in the way ⇒ no blocker, i.e. it connects', () {
    expect(blockerWith(), isNull);
  });

  test('A17: every gate names ITSELF, and no two share a sentence', () {
    final reasons = <String>[
      blockerWith(isSaved: false)!,
      blockerWith(autoReconnect: false)!,
      blockerWith(isOnline: true)!,
      blockerWith(isBusy: true)!,
      blockerWith(isRetrying: true)!,
      blockerWith(isAutoConnectArmed: true)!,
      blockerWith(lastError: 'bluetooth_off')!,
      blockerWith(isSetupStalled: true)!,
      blockerWith(isAdapterOn: false)!,
    ];
    expect(reasons.toSet(), hasLength(reasons.length),
        reason: 'two gates sharing one sentence would send the reader of an '
            'export to the wrong place — the whole point of FB-82');
  });

  test('A18: no gate is about scanning any more (FB-82 Q2)', () {
    // The counterpart to A11, one level down: the tenth gate was removed, not
    // merely stopped from firing. A re-added visibility check would show up
    // here as a tenth sentence, and on a phone it would show up as the owner's
    // original report — a page that quietly never connects.
    final reasons = <String>[
      blockerWith(isSaved: false)!,
      blockerWith(autoReconnect: false)!,
      blockerWith(isOnline: true)!,
      blockerWith(isBusy: true)!,
      blockerWith(isRetrying: true)!,
      blockerWith(isAutoConnectArmed: true)!,
      blockerWith(lastError: 'bluetooth_off')!,
      blockerWith(isSetupStalled: true)!,
      blockerWith(isAdapterOn: false)!,
    ];
    expect(reasons, hasLength(9));
    for (final r in reasons) {
      expect(r, isNot(contains('scan')));
    }
  });

  test('A19: the error CODE travels, not just the word "error"', () {
    expect(blockerWith(lastError: 'device_stale'), contains('device_stale'));
    expect(blockerWith(lastError: 'bluetooth_off'), contains('bluetooth_off'));
  });

  test('A20: busy / retrying / armed are three answers, not one', () {
    // They shared a single `if` before FB-82. "The link is busy" and "an iOS
    // hand-off is still outstanding" are three minutes apart in real time and
    // send whoever reads the log to different places.
    expect(
      {
        blockerWith(isBusy: true),
        blockerWith(isRetrying: true),
        blockerWith(isAutoConnectArmed: true),
      },
      hasLength(3),
    );
  });

  test('A21: gate ORDER is behaviour — an offline unsaved unit reports '
      'unsaved, not adapter', () {
    // Reordering would change which sentence a given phone writes, and the
    // first match is the one the reader acts on.
    expect(
      blockerWith(isSaved: false, isAdapterOn: false, isSetupStalled: true),
      blockerWith(isSaved: false),
    );
    // ...and the setting outranks every state gate below it, because "the user
    // switched this off" is never something to go and debug.
    expect(
      blockerWith(autoReconnect: false, isOnline: true, isSetupStalled: true),
      blockerWith(autoReconnect: false),
    );
  });

  // ── FB-82 Q4: two of the nine are also said ON SCREEN ───────────────────
  //
  // 🔴 What these pin is NARROWER than it looks, and the distinction is the
  // ruling itself. When these two gates fire, the screen is ALREADY showing a
  // specific failure card — the stalled copy with "close the app fully", or the
  // give-up copy branched on the error code. The user is not staring at
  // nothing. What no part of the app said, until now, is that THIS VISIT made
  // no attempt at all: FB-75 promised an automatic connect, the previous
  // attempt's `lastError` / stall latch was never cleared, and so the card on
  // screen is an OLD one. The notice reports that, and only that — a notice
  // reading "could not connect, because…" would be the card above said twice.

  test('A26: exactly two gates are loud, and they are the two that were ruled '
      'loud', () {
    // The gatekeeper, in `give_up_visibility_test.dart`'s spirit: it derives the
    // sentences from `autoConnectBlocker` itself, so rewording a gate cannot
    // silently drop its notice, and adding a notice to one of the silent seven
    // cannot pass unnoticed. Seven of nine staying quiet IS the ruling —
    // `already online` / `link busy` / `reconnect already pending` /
    // `autoconnect hand-off armed` describe a screen that is visibly doing
    // something; `device not saved` is design 0055's manual flow;
    // `bluetooth adapter not on` has its own prompt. `auto-connect setting off`
    // was left blank ON PURPOSE (a product judgement, reserved as its own
    // future line) — if it ever gains a notice, this test is where it is
    // declared, not somewhere it slipped in.
    final loud = <String, AutoConnectSkipNotice?>{
      for (final r in <String>[
        blockerWith(isSaved: false)!,
        blockerWith(autoReconnect: false)!,
        blockerWith(isOnline: true)!,
        blockerWith(isBusy: true)!,
        blockerWith(isRetrying: true)!,
        blockerWith(isAutoConnectArmed: true)!,
        blockerWith(lastError: 'device_stale')!,
        blockerWith(isSetupStalled: true)!,
        blockerWith(isAdapterOn: false)!,
      ])
        r: autoConnectSkipNotice(r),
    };

    expect(loud, hasLength(9));
    expect(
      loud.values.where((n) => n != null).toList(),
      hasLength(2),
      reason: 'the ruling was two, not nine — nine notices is a page that '
          'nags about states the user can already see',
    );
    expect(
      autoConnectSkipNotice(blockerWith(lastError: 'device_stale')),
      AutoConnectSkipNotice.lastError,
    );
    expect(
      autoConnectSkipNotice(blockerWith(isSetupStalled: true)),
      AutoConnectSkipNotice.setupStalled,
    );
    // The one gate whose sentence VARIES: it carries the code, so the mapping
    // has to be a prefix and every code has to land on the same notice.
    for (final code in <String>[
      'device_unreachable',
      'bluetooth_off',
      'gatt_setup_stalled',
      'connect_failed',
    ]) {
      expect(
        autoConnectSkipNotice(blockerWith(lastError: code)),
        AutoConnectSkipNotice.lastError,
        reason: 'the code varies, the notice does not',
      );
    }
    // Nothing in the way ⇒ nothing to say.
    expect(autoConnectSkipNotice(blockerWith()), isNull);
  });

  testWidgets('A27: a stale error blocks the attempt, and the page SAYS so — '
      'without touching the failure card', (tester) async {
    final en = AppLocalizationsEn();
    await boot(
      tester,
      configure: (c) => c
        ..error = 'device_unreachable'
        ..current = 'DEV-A',
    );

    expect(conn.connectToSavedCalls, 0);
    expect(find.text(en.devicesAutoConnectSkippedTitle), findsOneWidget);
    expect(find.text(en.devicesAutoConnectSkippedLastError), findsOneWidget);

    // 🔴 THE OTHER HALF, and the reason the notice is a separate widget rather
    // than a different `connectionFailureCopy` branch. The gate that produced
    // it exists because "the page is showing a failure report WITH a retry
    // button; pressing it for the user is the page arguing with them" — so a
    // notice that REPLACED that report would be doing the very thing the gate
    // was written to prevent, only in words instead of in radio traffic.
    expect(find.text(en.disconnectedGaveUpTitle), findsOneWidget);
    expect(find.text(en.devicesConnectFailedUnreachable), findsOneWidget);
    expect(find.text(en.disconnectedGaveUpHint), findsOneWidget);
    expect(find.text(en.disconnectedStalledRetry), findsOneWidget);
  });

  testWidgets('A28: the stalled gate gets its OWN sentence, over the stalled '
      'card', (tester) async {
    final en = AppLocalizationsEn();
    await boot(
      tester,
      configure: (c) => c
        ..stalled = true
        ..stalledDeviceId = 'DEV-A'
        ..current = 'DEV-A',
    );

    expect(conn.connectToSavedCalls, 0);
    expect(find.text(en.devicesAutoConnectSkippedStalled), findsOneWidget);
    // Not the other one: FB-50's "linked but never ready" and "the last attempt
    // failed" send the reader to different places, exactly as the gates do.
    expect(find.text(en.devicesAutoConnectSkippedLastError), findsNothing);
    // The card underneath is untouched, hint and all.
    expect(find.text(en.disconnectedStalledTitle), findsOneWidget);
    expect(find.text(en.disconnectedStalledHint), findsOneWidget);
  });

  testWidgets('A29: the silent seven stay silent — the radio being off says '
      'nothing here', (tester) async {
    final en = AppLocalizationsEn();
    await boot(tester, configure: (c) => c.adapterOn = false);

    expect(conn.connectToSavedCalls, 0);
    // It is still WRITTEN (A22) — the log and the screen are different
    // audiences, and that split is the whole shape of this ruling.
    expect(conn.skips.single, contains('adapter'));
    expect(find.text(en.devicesAutoConnectSkippedTitle), findsNothing);
  });

  testWidgets('A30: a page that DID connect says nothing about not connecting',
      (tester) async {
    final en = AppLocalizationsEn();
    await boot(tester);

    expect(conn.connectToSavedCalls, 1);
    expect(find.text(en.devicesAutoConnectSkippedTitle), findsNothing);
  });

  testWidgets('A31: the notice does not come BACK after the user retried by '
      'hand', (tester) async {
    // 🔴 The failure mode that needs a latch of its own. A manual retry clears
    // `lastError`, so the gate opens; if the retry then fails, the gate closes
    // again and "this visit made no automatic attempt" is still literally true
    // — and completely wrong to show. The user pressed a button and is looking
    // at its result; telling them nothing was tried reads as the screen denying
    // what they just did.
    final en = AppLocalizationsEn();
    await boot(
      tester,
      configure: (c) => c
        ..error = 'device_unreachable'
        ..current = 'DEV-A',
    );
    expect(find.text(en.devicesAutoConnectSkippedTitle), findsOneWidget);

    // The retry: `connect()` clears the error and the link goes busy.
    conn
      ..error = null
      ..busy = true
      ..bump();
    await tester.pump();
    expect(find.text(en.devicesAutoConnectSkippedTitle), findsNothing);

    // ...and it fails, putting the very same gate back in the way.
    conn
      ..busy = false
      ..error = 'device_unreachable'
      ..bump();
    await tester.pump();

    expect(conn.connectToSavedCalls, 0);
    expect(find.text(en.devicesAutoConnectSkippedTitle), findsNothing);
    expect(find.text(en.disconnectedGaveUpTitle), findsOneWidget,
        reason: 'the failure report is still the answer to "what happened"');
  });

  testWidgets('A32: the notice is recomputed, not latched — a gate that clears '
      'takes its sentence with it', (tester) async {
    final en = AppLocalizationsEn();
    await boot(
      tester,
      configure: (c) => c
        ..error = 'device_unreachable'
        ..current = 'DEV-A',
    );
    expect(find.text(en.devicesAutoConnectSkippedTitle), findsOneWidget);

    // Whatever cleared it — switching device, a `ready` elsewhere — the one-shot
    // latch has not been spent, so the automatic connect now happens. The claim
    // "no automatic attempt was made" stops being true at that instant.
    conn
      ..error = null
      ..bump();
    await tester.pump();
    await tester.pump();

    expect(conn.connectToSavedCalls, 1);
    expect(find.text(en.devicesAutoConnectSkippedTitle), findsNothing);
  });

  // ── FB-86: the error is per-unit, so ANOTHER unit's is not in the way ────
  //
  // 🔴 This is the gate that had no attribution at all. `lastError` was read
  // straight off the controller — one slot belonging to whichever unit it last
  // worked on — three hundred lines above an `_OfflineBody` that gated the very
  // same field on `mine`. So A's failed connect blocked B's page from trying,
  // B's own failure card was correctly suppressed, and what the user got was a
  // clean "not connected" on a page that had deliberately made no attempt.
  //
  // ⚠️ `current` is DEV-A here as well as `errorDeviceId`, because that is the
  // reported situation: `_desiredDeviceId` is only cleared by a user-initiated
  // disconnect, so after a failed connect to A the controller still names A.

  testWidgets('A33: another unit\'s failure does not block this one', (
    tester,
  ) async {
    await boot(
      tester,
      deviceId: 'DEV-A',
      configure: (c) => c
        ..error = 'device_unreachable'
        ..errorDeviceId = 'DEV-B'
        ..current = 'DEV-B',
    );

    expect(
      conn.connectToSavedCalls,
      1,
      reason:
          'FB-86: DEV-B failed, not this unit — refusing to try would be the '
          'app silently declining to do the one thing opening this page '
          'promises, with nothing on screen saying so',
    );
    expect(conn.lastTargetId, 'DEV-A');
  });

  testWidgets('A34: ...and it is not reported under this one\'s name either', (
    tester,
  ) async {
    // The other half, and the reason A33 is not enough on its own: the fix must
    // not buy the attempt back by leaking DEV-B's failure onto DEV-A's page.
    // FB-41/FB-42 is that mistake in the history table; this is it on screen.
    final en = AppLocalizationsEn();
    await boot(
      tester,
      deviceId: 'DEV-A',
      configure: (c) => c
        ..error = 'device_unreachable'
        ..errorDeviceId = 'DEV-B'
        ..current = 'DEV-B',
    );

    expect(find.text(en.devicesConnectFailedUnreachable), findsNothing);
    expect(find.text(en.devicesAutoConnectSkippedTitle), findsNothing,
        reason: 'nothing was skipped — the attempt was made');
  });

  testWidgets('A35: a RADIO failure still blocks, and still explains itself', (
    tester,
  ) async {
    // The line FB-86 does not cross. `bluetooth_off` belongs to no unit because
    // it is true of all of them, so it must keep blocking every unit's page —
    // and now, unlike before, the card underneath says which radio it is
    // waiting on rather than showing the plain idle copy.
    final en = AppLocalizationsEn();
    await boot(
      tester,
      deviceId: 'DEV-A',
      configure: (c) => c
        ..error = 'bluetooth_off'
        ..errorDeviceId = null
        ..current = 'DEV-B',
    );

    expect(conn.connectToSavedCalls, 0);
    expect(find.text(en.devicesConnectFailedBluetoothOff), findsOneWidget);
    expect(find.text(en.devicesAutoConnectSkippedTitle), findsOneWidget,
        reason: 'FB-82 Q4 — the visit made no attempt, and this notice needs '
            'no `mine` gate now that its trigger is already per-unit');
  });

  testWidgets('A36: another unit\'s STALL does not block this one either', (
    tester,
  ) async {
    // 🔴 FB-86's SECOND HALF, and the reason A33 was not the end of it. When the
    // error was scoped, this gate one line below still read the stall latch
    // globally — so the identical defect survived on the identical screen: DEV-B
    // stalls, the user opens DEV-A, DEV-A never tries, and DEV-A's own stalled
    // card is not on screen to say why.
    final en = AppLocalizationsEn();
    await boot(
      tester,
      deviceId: 'DEV-A',
      configure: (c) => c
        ..stalled = true
        ..stalledDeviceId = 'DEV-B'
        ..current = 'DEV-B',
    );

    expect(
      conn.connectToSavedCalls,
      1,
      reason:
          'the run of silent connections belongs to DEV-B — refusing here is '
          'the FB-50 gate firing on a unit it has no evidence about',
    );
    // And the other half, as A34 is to A33: not borrowed onto this page either.
    expect(find.text(en.disconnectedStalledTitle), findsNothing);
    expect(find.text(en.devicesAutoConnectSkippedStalled), findsNothing);
  });

  testWidgets('A37: a stall on a unit the controller no longer targets still '
      'reports — notice AND card', (tester) async {
    // The case the FB-82 Q4 re-judgement turns on. `disconnect()` nulls the
    // desired id but the latch is deliberately kept until a `ready`, so `mine`
    // is false while the stall is still this unit's fact. The card is scoped to
    // the unit now, not to `mine`, so it renders — and a `mine` gate on the
    // notice would have hidden the sentence explaining the card beside it.
    final en = AppLocalizationsEn();
    await boot(
      tester,
      deviceId: 'DEV-A',
      configure: (c) => c
        ..stalled = true
        ..stalledDeviceId = 'DEV-A'
        ..current = null,
    );

    expect(conn.connectToSavedCalls, 0);
    expect(find.text(en.disconnectedStalledTitle), findsOneWidget,
        reason: 'the unit HAS stalled; `mine` being false is a fact about the '
            'link, not about whose run this was');
    expect(find.text(en.devicesAutoConnectSkippedStalled), findsOneWidget,
        reason: 'FB-82 Q4 re-judged: the notice explains the card above it, so '
            'gating it on `mine` could only hide the explanation');
  });
}
