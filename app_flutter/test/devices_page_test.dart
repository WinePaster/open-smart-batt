// The devices tab (design 0046 §4.1 N4–N6, §4.2 T-new-6).
//
// 🔑 N4 IS THE CLOSING ARGUMENT FOR FB `2026.08.02/004`. The reporter (林陳裕)
// said switching devices "跳回主頁面 3～4 秒，以為藍牙斷線". Nothing was wrong
// with the link: the device-list SHEET popped itself the instant a connect
// returned, which put the dashboard's empty state on screen for the several
// seconds a switch takes — and an empty state is indistinguishable from a
// dropped link. Independent measurement put the median switch at 4.97 s over 12
// attempts.
//
// Design 0046 R22 ruled fix C — the UI stays put — so what this file pins is an
// ABSENCE: no navigation happens on a successful connect. An absence needs a
// test more than a presence does, because the way it regresses is somebody
// adding a `Navigator.pop()` back for a reason that looks good locally.
//
// CLEAN-ROOM: expectations derive from this project's own source, design docs
// and field reports.
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
import 'package:open_smart_batt/ui/dashboard/dashboard_page.dart';
import 'package:open_smart_batt/ui/devices/device_detail_page.dart';
import 'package:open_smart_batt/ui/devices/devices_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A BLE service whose link state and scan results a test can simply state.
class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _scanOut = StreamController<List<DiscoveredDevice>>.broadcast();

  String? connectedId;

  @override
  String get connectedDeviceName => connectedId == null ? '' : 'RCE-CarBatt';

  @override
  String? get connectedDeviceId => connectedId;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<List<DiscoveredDevice>> get scanResults => _scanOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      Stream<BluetoothAdapterState>.value(BluetoothAdapterState.on);

  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  /// Call counters. `isScanning` is stubbed false here, so "is the radio on"
  /// cannot be read off it — these are the hard evidence a scan-lifecycle test
  /// needs (W-3).
  int startScans = 0;
  int stopScans = 0;

  @override
  Future<void> startScan(
      {Duration timeout = const Duration(seconds: 15)}) async {
    startScans++;
  }

  @override
  Future<void> stopScan() async {
    stopScans++;
  }

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    connectedId = deviceId;
    _linkOut.add(BleLinkState.connecting);
    _linkOut.add(BleLinkState.connected);
    _linkOut.add(BleLinkState.ready);
  }

  @override
  Future<void> disconnect() async {
    connectedId = null;
    _linkOut.add(BleLinkState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _scanOut.close();
    await super.dispose();
  }
}

/// A controller whose `lastError` / stall latch a test can simply state.
///
/// Same device as `give_up_visibility_test.dart`'s `_ErrorConn`, and for the
/// same reason: two of these states are reached only by waiting (the backoff
/// ladder needs its full 60 s, the autoConnect watchdog 180 s) on a wall clock a
/// widget test cannot fake while a real database is in play. Which failure
/// produces which code is a pure function pinned elsewhere; all this page has to
/// be asked is what it draws once the code exists.
class _StateConn extends ConnectionController {
  _StateConn(super.ble, {required super.settings});

  String? error;
  bool stalledLatch = false;

  @override
  String? get lastError => error;

  @override
  bool get isSetupStalled => stalledLatch;

  void state({String? error, bool stalled = false}) {
    this.error = error;
    stalledLatch = stalled;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late _FakeBle ble;

  Future<AppServices> makeServices(WidgetTester tester) async {
    late final AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _FakeBle();
      s = await AppServices.create(appDatabase: db, ble: ble);
      await s.devices.saveNew('DEV-A', 'Cap #1', name: 'RCE-SCAP_II');
    });
    return s;
  }

  Future<void> teardown(WidgetTester tester, AppServices s) =>
      tester.runAsync(s.dispose);

  Future<void> pumpPage(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<BleService>.value(value: s.ble),
          ChangeNotifierProvider<SettingsController>.value(value: s.settings),
          ChangeNotifierProvider<DeviceController>.value(value: s.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: s.connection),
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
          ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const Scaffold(body: DevicesPage(active: true)),
        ),
      ),
    );
    await tester.pump();
  }

  /// Let the real (ffi) database finish whatever the last frame started.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump();
  }

  testWidgets('N4: connecting a saved device leaves the user on this page',
      (tester) async {
    // FB `2026.08.02/004`'s closing criterion, stated as an absence.
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    await pumpPage(tester, s);
    await settle(tester);

    expect(find.text('Cap #1'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    await settle(tester);

    expect(s.connection.isOnline, isTrue);
    // THE assertion: the page is still the one the tap happened on. Before
    // design 0046 this was a modal sheet that popped itself here, dropping the
    // user onto the dashboard's empty state for ~5 s.
    expect(find.byType(DevicesPage), findsOneWidget);
    expect(find.byType(DeviceDetailPage), findsNothing);
    // …and the row says so in place.
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets('N5: a new device is named without leaving either',
      (tester) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    await pumpPage(tester, s);
    await settle(tester);

    // A nearby, unsaved unit.
    await tester.runAsync(() async {
      ble._scanOut.add([
        const DiscoveredDevice(
            id: 'DEV-NEW', name: 'RCE-CarBatt', rssi: -55, isVendor: true),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    expect(find.text('RCE-CarBatt'), findsOneWidget);

    await tester.tap(find.text('Connect').last);
    await settle(tester);

    // The alias prompt appears IN PLACE — it used to belong to the sheet's
    // host, reached by popping with the new id.
    expect(find.byType(DevicesPage), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Car #2');
    await tester.pump();
    await tester.tap(find.text('Save alias'));
    await settle(tester);

    expect(s.devices.isSaved('DEV-NEW'), isTrue);
    expect(s.devices.deviceFor('DEV-NEW')!.alias, 'Car #2');
    // The stable advertised name is captured too (D.3): on iOS the saved id is
    // a volatile NSUUID and the name is what rebinds the record.
    expect(s.devices.deviceFor('DEV-NEW')!.name, 'RCE-CarBatt');
    expect(find.byType(DevicesPage), findsOneWidget);
  });

  testWidgets('N6: disconnecting leaves the user on this page too',
      (tester) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    await pumpPage(tester, s);
    await settle(tester);

    await tester.tap(find.text('Connect'));
    await settle(tester);
    expect(s.connection.isOnline, isTrue);

    await tester.tap(find.text('Disconnect'));
    await settle(tester);

    expect(s.connection.isOnline, isFalse);
    expect(find.byType(DevicesPage), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  // ==========================================================================
  // T-new-6 — the badge is a door, not a dead end
  // ==========================================================================
  //
  // Design 0046 R21 puts ONE WORD on the row and the full report on the device's
  // own page. That trade is only acceptable while the word is a LINK: FB-53's
  // complaint, word for word, was that the app had stopped trying and "the only
  // clue was that the spinner had gone". A badge that changes colour and does
  // nothing else is that same screen with a colour added.
  group('T-new-6: every badge state is a door, not a dead end', () {
    late _StateConn conn;

    Future<AppServices> pumpWithState(WidgetTester tester) async {
      final s = await makeServices(tester);
      conn = _StateConn(ble, settings: s.settings);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<BleService>.value(value: s.ble),
            ChangeNotifierProvider<SettingsController>.value(value: s.settings),
            ChangeNotifierProvider<DeviceController>.value(value: s.devices),
            ChangeNotifierProvider<ConnectionController>.value(value: conn),
            ChangeNotifierProvider<TelemetryController>.value(
                value: s.telemetry),
            ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const Scaffold(body: DevicesPage(active: true)),
          ),
        ),
      );
      await tester.pump();
      return s;
    }

    /// badge word -> the FULL sentence its page must carry. The empty string is
    /// the connected case, whose "full report" is the dashboard itself.
    const cases = <String, String>{
      'Not connected': 'No device connected',
      'Connecting': 'Connecting…',
      'Connection failed': 'Could not connect to this device',
      'Not answering': 'Connected, but the device is not answering',
      'Connected': '',
    };

    for (final entry in cases.entries) {
      testWidgets('${entry.key}: the badge opens the full text', (tester) async {
        final s = await pumpWithState(tester);
        addTearDown(() {
          conn.dispose();
          return teardown(tester, s);
        });

        switch (entry.key) {
          case 'Not connected':
            break;
          case 'Connecting':
            ble.connectedId = 'DEV-A';
            ble._linkOut.add(BleLinkState.connecting);
          case 'Connection failed':
            ble.connectedId = 'DEV-A';
            conn.state(error: 'connect_failed');
          case 'Not answering':
            ble.connectedId = 'DEV-A';
            conn.state(error: 'gatt_setup_stalled', stalled: true);
          case 'Connected':
            ble.connectedId = 'DEV-A';
            ble._linkOut.add(BleLinkState.ready);
        }
        await settle(tester);

        expect(find.text(entry.key), findsOneWidget,
            reason: 'the row must carry the one-word status');

        await tester.tap(find.text(entry.key));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400)); // route transition
        await settle(tester);

        expect(find.byType(DeviceDetailPage), findsOneWidget,
            reason: 'R21 puts the full report here; a badge that leads nowhere '
                'is FB-53 with a colour added');
        // Scoped to the pushed page's subtree: the list route stays mounted
        // underneath, so an unscoped finder would be reading the row we came
        // from rather than the page we arrived at.
        Finder onPage(String text) => find.descendant(
              of: find.byType(DeviceDetailPage),
              matching: find.text(text),
            );
        if (entry.value.isEmpty) {
          // Connected: the "full report" IS the dashboard, so what this asserts
          // is that the page is showing telemetry rather than a failure copy.
          expect(find.descendant(
                of: find.byType(DeviceDetailPage),
                matching: find.byType(DashboardPage),
              ), findsOneWidget);
        } else {
          expect(onPage(entry.value), findsOneWidget,
              reason: 'the page says it in full, not in the badge\'s one word');
          expect(onPage(entry.key), findsNothing,
              reason: 'the badge word is a summary; the page is the report');
        }
      });
    }
  });


  // ---------------------------------------------------------------------------
  // W-3 (2026-08-07 交付一查核): pushing the detail page left the BLE scan
  // running for as long as the user read it. The old bottom sheet stopped on
  // dispose the moment it closed; promoting it to a tab quietly took that away,
  // because `active` is derived from the TAB and the tab is still 裝置 with a
  // route on top of it.
  // ---------------------------------------------------------------------------
  testWidgets('W-3: opening a device page stops the scan, closing resumes it',
      (tester) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    await pumpPage(tester, s);
    await settle(tester);

    expect(ble.startScans, greaterThan(0),
        reason: 'the tab scans while shown');
    final beforeOpen = ble.stopScans;

    await tester.tap(find.text('Cap #1'));
    await settle(tester);
    expect(ble.stopScans, greaterThan(beforeOpen),
        reason: 'a detail page covers the list — the same window the GNSS gate '
            'calls "somebody is looking at one device". Leaving a radio on for '
            'it is the disagreement that only ever shows up as battery.');

    final beforeBack = ble.startScans;
    // Popped directly rather than via `pageBack()`: the detail page draws its
    // own back affordance, so the framework's stock finder sees nothing.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settle(tester);
    expect(ble.startScans, greaterThan(beforeBack),
        reason: 'and it comes back when the page does');
  });
}
