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
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
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

  /// Move to the 搜尋裝置 sub-tab (design 0055 §4.5).
  ///
  /// The harness saves DEV-A before the first frame, so the page opens on 已儲存
  /// (rule 1) and the scan results are on the OTHER tab. Every test that wants a
  /// nearby row has to come here first — that is the split working, not a
  /// workaround for it.
  Future<void> openScanTab(WidgetTester tester) async {
    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // tab transition
    await settle(tester);
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
    await openScanTab(tester);
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

  // N5b: the gap N5 left. N5 stops at "the record exists"; what the user does
  // next is TAP THAT ROW, and nothing pinned that the row promoted from the
  // nearby list behaves like every other saved row. Reported 2026-08-11 (何先生,
  // 經銷商): 原來儲存的點得開、新儲存的點不開 — this is the assertion that
  // report is about, and it passes, so whatever he hit is not in this path.
  testWidgets('N5b: a just-named device opens its detail page like any saved row',
      (tester) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    await pumpPage(tester, s);
    await settle(tester);

    await tester.runAsync(() async {
      ble._scanOut.add([
        const DiscoveredDevice(
            id: 'DEV-NEW', name: 'RCE-CarBatt', rssi: -55, isVendor: true),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    await openScanTab(tester);

    await tester.tap(find.text('Connect').last);
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Car #2');
    await tester.pump();
    await tester.tap(find.text('Save alias'));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400)); // tab transition
    expect(s.devices.isSaved('DEV-NEW'), isTrue);

    // Rule 2 (design 0055 §7.1): the naming happened on the SCAN tab, and the
    // row it produced lives on the other one. Landing back on the scan tab
    // would show the user a list their new device just vanished from — which is
    // the 2026-08-11 dealer complaint, manufactured by our own layout.
    expect(find.text('Car #2'), findsOneWidget,
        reason: 'naming a device must reveal the tab that now holds it');
    await tester.tap(find.text('Car #2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);

    expect(find.byType(DeviceDetailPage), findsOneWidget);
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
            ChangeNotifierProvider<GForceController>.value(
                value: s.gforce),
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
  // Deleting a device must RELEASE ITS LINK — reported 2026-08-11 by the owner,
  // reproduced on v0.7.13: 「我刪除儲存的裝置就不見了　我沒辦法在附近裝置找回他」。
  //
  // The guard was `isOnline && …`, and `isOnline` is `_link == ready` and
  // nothing else. Delete during connecting / connected / disconnecting and the
  // link stayed up; a connected peripheral does not advertise, so the unit
  // vanished from the saved list AND from every scan. Unrecoverable, too: the
  // only control that drops a link lives on the row that was just deleted.
  //
  // The not-yet-`ready` window is where FB-51/FB-52 live — "connected but never
  // ready" — which is the state a user is most likely to delete from.
  // ---------------------------------------------------------------------------
  testWidgets('deleting a device drops its link even before `ready`',
      (tester) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    await pumpPage(tester, s);
    await settle(tester);

    await tester.tap(find.text('Connect'));
    await settle(tester);
    expect(ble.connectedId, 'DEV-A');

    // Fall back out of `ready` without dropping the link — the FB-51/52 shape.
    ble._linkOut.add(BleLinkState.connected);
    await settle(tester);
    expect(s.connection.isOnline, isFalse, reason: 'the precondition: NOT ready');
    expect(s.connection.connectedDeviceId, 'DEV-A',
        reason: '…but the link is still on this unit');

    await tester.tap(find.byIcon(Icons.delete_outline));
    await settle(tester);
    await tester.tap(find.text('Remove'));
    await settle(tester);

    expect(s.devices.isSaved('DEV-A'), isFalse);
    expect(ble.connectedId, isNull,
        reason: 'a peripheral we are still connected to never advertises, so '
            'leaving the link up makes the deleted unit unfindable in the very '
            'scan the delete kicks off');
  });

  // ---------------------------------------------------------------------------
  // Design 0055 (ruled 2026-08-11): every row is a door, saved or not, and the
  // devices tab is two sub-tabs sharing one scan.
  //
  // The rule these replace was not an oversight — 0046 R21 stated it and
  // `devices_page.dart` carried it in a comment ("an unsaved unit has no saved
  // row to hold a layout or a history, so there is no detail page for it to be a
  // door to"). What made it false was design 0051 emptying the detail page of
  // everything a saved record was needed for.
  // ---------------------------------------------------------------------------
  group('design 0055', () {
    /// Push one nearby unit and land on the tab that lists it.
    Future<void> seeNearby(
      WidgetTester tester, {
      String id = 'DEV-NEW',
      String name = 'RCE-CarBatt',
    }) async {
      await tester.runAsync(() async {
        ble._scanOut.add([
          DiscoveredDevice(id: id, name: name, rssi: -55, isVendor: true),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      await openScanTab(tester);
    }

    Future<void> tapRow(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // route transition
      await settle(tester);
    }

    testWidgets('T55-1: an UNSAVED row opens its detail page', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await seeNearby(tester);

      await tapRow(tester, 'RCE-CarBatt');

      expect(find.byType(DeviceDetailPage), findsOneWidget,
          reason: 'design 0055 §4.1: the row body looks at it, the button '
              'connects it — on every kind of row');
      expect(s.devices.isSaved('DEV-NEW'), isFalse,
          reason: 'looking at a unit must not silently remember it');
    });

    testWidgets('T55-2: an unsaved page is titled by name, else by id — never '
        '"unnamed"', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);

      // (a) advertised name present ⇒ it is the title.
      await seeNearby(tester);
      await tapRow(tester, 'RCE-CarBatt');
      Finder onPage(String t) => find.descendant(
          of: find.byType(DeviceDetailPage), matching: find.text(t));
      expect(onPage('RCE-CarBatt'), findsOneWidget);
      expect(onPage('Unnamed device'), findsNothing,
          reason: 'ruled 2026-08-11: 未命名裝置 names nothing in a room that may '
              'hold six of them');
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await settle(tester);

      // (b) no advertised name ⇒ the id stands in. A MAC-shaped id is shown
      // whole; only a UUID gets shortened (design 0055 §4.2).
      await seeNearby(tester, id: 'C4:D5:66:12:1A:2B', name: '');
      await tapRow(tester, 'Unknown');
      expect(onPage('C4:D5:66:12:1A:2B'), findsOneWidget);
      expect(onPage('Unnamed device'), findsNothing);
    });

    testWidgets('T55-3: the connect button on an unsaved page is LIVE',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await seeNearby(tester);
      await tapRow(tester, 'RCE-CarBatt');

      // Before 0055 this button disabled itself on `saved == null`, which made
      // the page's one action grey with no explanation.
      final btn = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byType(DeviceDetailPage),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(btn.onPressed, isNotNull,
          reason: 'design 0055 §4.3: an unsaved unit connects with a plain '
              'connect — there is no routing seed to carry, and a first '
              'connection never had one');

      await tester.tap(find.byType(OutlinedButton).last);
      await settle(tester);
      expect(ble.connectedId, 'DEV-NEW');
    });

    testWidgets('T55-4: connecting FROM the detail page still asks for a name',
        (tester) async {
      // The regression this file exists to prevent (design 0055 §4.4): 0055
      // built a second entrance to connecting, and the alias prompt lived
      // inside the first one. Leave it there and "save" becomes unreachable
      // through the new door.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await seeNearby(tester);
      await tapRow(tester, 'RCE-CarBatt');

      await tester.tap(find.byType(OutlinedButton).last);
      await settle(tester);

      expect(find.byType(TextField), findsOneWidget,
          reason: 'the naming prompt must follow the connect, not the caller');
      await tester.enterText(find.byType(TextField), 'Car #9');
      await tester.pump();
      await tester.tap(find.text('Save alias'));
      await settle(tester);
      expect(s.devices.deviceFor('DEV-NEW')?.alias, 'Car #9');
    });

    testWidgets('T55-5: connected-but-unnamed has a way out', (tester) async {
      // This state predates 0055 and had NO exit: cancel the prompt and the
      // unit stayed connected and unsaved until you disconnected.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await seeNearby(tester);

      await tester.tap(find.text('Connect').last);
      await settle(tester);
      await tester.tap(find.text('Skip')); // decline to name it
      await settle(tester);
      expect(s.devices.isSaved('DEV-NEW'), isFalse);

      await tapRow(tester, 'RCE-CarBatt');
      expect(find.text('This device is not saved'), findsOneWidget);

      await tester.tap(find.text('Save'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'Car #7');
      await tester.pump();
      await tester.tap(find.text('Save alias'));
      await settle(tester);
      expect(s.devices.deviceFor('DEV-NEW')?.alias, 'Car #7');
    });

    testWidgets('T55-6: an unsaved row still carries NO badge', (tester) async {
      // 0055 widened who has a detail page; it did not weaken 0046 R21. Five to
      // ten nearby units each captioned 未連線 is noise, not status.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await seeNearby(tester);

      expect(find.text('RCE-CarBatt'), findsOneWidget);
      for (final word in const ['Not connected', 'Connecting', 'Connected']) {
        expect(find.text(word), findsNothing, reason: 'design 0055 §4.6');
      }
    });

    testWidgets('rule 1: with nothing saved, the page opens on the scan tab',
        (tester) async {
      // A first run that lands on an empty saved list puts the only remedy on a
      // tab the user has no reason to look at (design 0055 §7.1).
      late final AppServices s;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        ble = _FakeBle();
        s = await AppServices.create(appDatabase: db, ble: ble); // NOTHING saved
      });
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);

      await tester.runAsync(() async {
        ble._scanOut.add([
          const DiscoveredDevice(
              id: 'DEV-NEW', name: 'RCE-CarBatt', rssi: -55, isVendor: true),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();

      // No tab tap anywhere above: the scan is what came up.
      expect(find.text('RCE-CarBatt'), findsOneWidget);
    });
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
