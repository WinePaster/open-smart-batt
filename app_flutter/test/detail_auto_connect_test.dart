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

  @override
  bool get isOnline => online;

  @override
  bool get isBusy => busy;

  @override
  bool get isRetrying => retrying;

  @override
  bool get isAutoConnectArmed => armed;

  @override
  bool get isSetupStalled => stalled;

  @override
  bool get isAdapterOn => adapterOn;

  @override
  String? get lastError => error;

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
    await boot(tester, configure: (c) => c.error = 'device_unreachable');

    expect(
      conn.connectToSavedCalls,
      0,
      reason:
          'the page is showing a failure report WITH a retry button; '
          'pressing it for the user is the page arguing with them',
    );
  });

  testWidgets('A5: never once setup has stalled (FB-50)', (tester) async {
    await boot(tester, configure: (c) => c.stalled = true);

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
}
