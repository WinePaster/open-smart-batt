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
// 🔴 A10–A14 are the iOS half, and they are the reason `autoConnectTargetVisible`
// is a pure top-level function: `Platform.isIOS` is false on the host that runs
// this suite, so the branch WITH the failure mode would otherwise be the one
// branch no test could reach. Opening this page stops the scan, and iOS resolves
// a saved unit by re-binding its per-install NSUUID against live scan results —
// so coming in from a home tile can leave nothing to resolve against. Connecting
// anyway would replace today's honest "not connected + a button" with a spinner
// that ends in `device_unreachable`: the exact direction FB-52 and FB-53 were
// fixed away from.
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

  @override
  List<DiscoveredDevice> get scanResults => results;

  @override
  Future<void> connectToSaved(SavedDevice device) async {
    connectToSavedCalls++;
    lastTargetId = device.id;
  }

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

  // ── the iOS half ────────────────────────────────────────────────────────

  test('A11: Android never blocks — its MAC needs no resolving', () {
    expect(
      autoConnectTargetVisible(
        useNameKey: false,
        savedId: 'AA:BB:CC:DD:EE:FF',
        savedName: 'RCE-SCAP_II',
        candidates: const {},
      ),
      isTrue,
    );
  });

  test('A12: iOS with nothing scanned does NOT connect', () {
    expect(
      autoConnectTargetVisible(
        useNameKey: true,
        savedId: 'NSUUID-OLD',
        savedName: 'RCE-SCAP_II',
        candidates: const {},
      ),
      isFalse,
      reason:
          'opening this page stops the scan, so arriving from a home tile '
          'can leave an empty candidate set — connecting anyway buys a '
          'device_unreachable in place of an honest button',
    );
  });

  test('A13: iOS with the saved id still visible connects', () {
    expect(
      autoConnectTargetVisible(
        useNameKey: true,
        savedId: 'NSUUID-A',
        savedName: 'RCE-SCAP_II',
        candidates: const {'NSUUID-A': 'RCE-SCAP_II'},
      ),
      isTrue,
    );
  });

  test('A14: iOS rebinds on a UNIQUE name match', () {
    expect(
      autoConnectTargetVisible(
        useNameKey: true,
        savedId: 'NSUUID-OLD',
        savedName: 'RCE-SCAP_II',
        candidates: const {'NSUUID-NEW': 'RCE-SCAP_II', 'OTHER': 'RCE_RSPB-01'},
      ),
      isTrue,
    );
  });

  test('A15: iOS refuses to guess between duplicate advertised names', () {
    expect(
      autoConnectTargetVisible(
        useNameKey: true,
        savedId: 'NSUUID-OLD',
        savedName: 'RCE_RSPB-01',
        candidates: const {'ONE': 'RCE_RSPB-01', 'TWO': 'RCE_RSPB-01'},
      ),
      isFalse,
      reason:
          'two power banks really do both advertise RCE_RSPB-01 '
          '(2026-07-29 capture); filing one unit\'s telemetry under the '
          'other\'s alias is silent and unrecoverable',
    );
  });
}
