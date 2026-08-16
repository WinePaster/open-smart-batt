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
    // 🔴 A fresh scan CLEARS THE ROSTER, because the real one does:
    // `BleService.startScan` opens with `_scanSeen.clear(); _scan.add(const
    // [])`. This fake used to leave the previous results standing, and that
    // infidelity is the whole reason the 2026-08-12 defect shipped — every
    // test here saw a nearby list that could only ever grow, so no test could
    // notice a row that only the LAST scan was holding on screen.
    _scanOut.add(const []);
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

  /// Pump the page. [active] is the shell's "this is the tab on screen" flag —
  /// pumping again with a different value is how a test leaves for another tab
  /// and comes back, since the State survives and only `didUpdateWidget` runs.
  Future<void> pumpPage(WidgetTester tester, AppServices s,
      {bool active = true}) async {
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
          // design 0058 §3.3: the save flow writes its own diagnostic trail
          // straight to LogRepo, so it needs the service locator the shell
          // already provides (`main.dart:204`).
          Provider<AppServices>.value(value: s),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: DevicesPage(active: active)),
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
            // 🔴 FB-75 (2026-08-14) made this the one case that needs setting
            // up rather than left alone: opening a SAVED unit's page now starts
            // a connection by itself, so with the radio clear and no prior
            // error the page the badge leads to is 「Connecting…」, not the idle
            // report. Turning the switch off is the user state in which the
            // idle report is still what they get — and it keeps this test about
            // what it has always been about (the badge is a DOOR), instead of
            // silently becoming a test of the new auto-connect.
            await tester.runAsync(() => s.settings.setAutoReconnect(false));
            await tester.pump();
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
  // 「儲存」 must SAVE — reported 2026-08-11 on v0.7.12 / v0.7.13 as「儲存裝置後
  // 沒反應」, and the most likely reading of a dealer's「新儲存的也不會顯示」the
  // same day.
  //
  // `_submit` popped null for a blank field, and null is how every caller spells
  // "the user declined". So 儲存 with nothing typed did precisely what 跳過 does,
  // silently — no record, no message, and a filled amber button that looked like
  // it had worked. Then the unit is missing from the saved list and has no page,
  // because it was never saved at all.
  //
  // 🔑 This is also why N5b could not reproduce that report: every existing test
  // types a name first.
  // ---------------------------------------------------------------------------
  group('the naming dialog: two buttons, two outcomes', () {
    Future<void> connectNearby(WidgetTester tester) async {
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
      expect(find.byType(TextField), findsOneWidget,
          reason: 'the naming prompt follows the connect');
    }

    testWidgets('儲存 with an EMPTY name still saves the device', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await connectNearby(tester);

      // Type nothing at all, and press the save button.
      await tester.tap(find.text('Save alias'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400)); // tab transition

      expect(s.devices.isSaved('DEV-NEW'), isTrue,
          reason: 'pressing 儲存 must produce a record — silently doing nothing '
              'is what the v0.7.12/0.7.13 reports are');
      expect(s.devices.deviceFor('DEV-NEW')!.alias, '');
      // An empty alias has always been renderable; it just had no way in.
      expect(find.text('Unnamed device'), findsOneWidget);
      // …and the advertised name is still captured, so a rename is not the only
      // way to tell it apart later.
      expect(s.devices.deviceFor('DEV-NEW')!.name, 'RCE-CarBatt');
    });

    testWidgets('tapping OUTSIDE the dialog cannot lose the save', (tester) async {
      // The second silent path, found 2026-08-11 while analysing FB batch
      // `08.11/005`. `showDialog`'s `barrierDismissible` DEFAULTS TO TRUE, so a
      // tap on the scrim popped null — the same "user declined" answer, given by
      // a gesture nobody means as an answer.
      //
      // It is also the gesture this dialog invites: the field is `autofocus`, so
      // the keyboard is up, and tapping outside a field to dismiss a keyboard is
      // a reflex — on the reporter's 375 pt iPhone X there is nowhere else for
      // that tap to land.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await connectNearby(tester);

      await tester.enterText(find.byType(TextField), 'Car #3');
      await tester.pump();
      // Top-left corner: outside the 300 pt-wide centred dialog, on the scrim.
      await tester.tapAt(const Offset(8, 8));
      await settle(tester);

      expect(find.byType(TextField), findsOneWidget,
          reason: 'the prompt must survive a stray tap — dismissing it there is '
              'indistinguishable from the empty-field bug we just fixed');

      // …and the answer the user actually typed still lands.
      await tester.tap(find.text('Save alias'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(s.devices.deviceFor('DEV-NEW')?.alias, 'Car #3');
    });


    testWidgets('T58-1/T58-2: the save flow leaves a trail, without the name',
        (tester) async {
      // design 0058 §3.3. Before this, `saveNew` wrote no event at all, so a
      // phone's log could not tell an empty-name 儲存 from a barrier tap from a
      // deliberate 跳過 from a prompt that never appeared — which is why the
      // FB `08.11/005` analysis could only reach "compatible with the defect".
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await connectNearby(tester);

      await tester.enterText(find.byType(TextField), '老王的機車');
      await tester.pump();
      await tester.tap(find.text('Save alias'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(s.pending.drain);

      // 🔴 `runAsync`: `queryLog` is real (ffi) I/O, and a widget test's fake
      // async zone never completes it otherwise — the same reason `settle` and
      // `makeServices` are wrapped.
      final notes = await tester.runAsync(() async =>
          (await s.logRepo.queryLog())
              .map((e) => e.note ?? '')
              .where((n) => n.startsWith('save-device:'))
              .toList()) as List<String>;

      expect(notes, contains('save-device: prompt'),
          reason: 'Q2: "the dialog never opened" and "it opened and was '
              'declined" must not collapse into one silence');
      expect(notes, contains('save-device: result=named'));

      // 🔴 T58-2. The alias is free text about someone's own vehicle — names
      // and plate numbers land in it — and a diagnostic log gets emailed to us.
      for (final n in notes) {
        expect(n, isNot(contains('老王')), reason: 'the outcome, never the name');
      }
      final leaked = await tester.runAsync(() async => (await s.logRepo.queryLog())
          .where((e) => (e.note ?? '').contains('老王'))
          .toList());
      expect(leaked, isEmpty);
    });

    testWidgets('T58-1: 跳過 is recorded as declined, not as silence',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await connectNearby(tester);

      await tester.tap(find.text('Skip'));
      await settle(tester);
      await tester.runAsync(s.pending.drain);

      // 🔴 `runAsync`: `queryLog` is real (ffi) I/O, and a widget test's fake
      // async zone never completes it otherwise — the same reason `settle` and
      // `makeServices` are wrapped.
      final notes = await tester.runAsync(() async =>
          (await s.logRepo.queryLog())
              .map((e) => e.note ?? '')
              .where((n) => n.startsWith('save-device:'))
              .toList()) as List<String>;
      expect(notes, containsAll(<String>[
        'save-device: prompt',
        'save-device: result=declined',
      ]));
      expect(s.devices.isSaved('DEV-NEW'), isFalse);
    });

    testWidgets('T58-1: an empty name is recorded as `unnamed`, not `named`',
        (tester) async {
      // The two outcomes 儲存 can produce are distinguishable in the log —
      // otherwise the very defect this trail was added for stays invisible.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await connectNearby(tester);

      await tester.tap(find.text('Save alias'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(s.pending.drain);

      // 🔴 `runAsync`: `queryLog` is real (ffi) I/O, and a widget test's fake
      // async zone never completes it otherwise — the same reason `settle` and
      // `makeServices` are wrapped.
      final notes = await tester.runAsync(() async =>
          (await s.logRepo.queryLog())
              .map((e) => e.note ?? '')
              .where((n) => n.startsWith('save-device:'))
              .toList()) as List<String>;
      expect(notes, contains('save-device: result=unnamed'));
      expect(notes, isNot(contains('save-device: result=named')));
    });

    testWidgets('跳過 still saves NOTHING', (tester) async {
      // The other half. Without this the fix would just move the defect: a
      // device the user declined to name is one they declined to remember
      // (`DeviceController.setDisplayLayout`'s rule), and quietly saving it
      // would put a row in their list they never asked for.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await connectNearby(tester);

      await tester.tap(find.text('Skip'));
      await settle(tester);

      expect(s.devices.isSaved('DEV-NEW'), isFalse);
    });
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
    // 🔴 Scoped to the confirmation dialog's [TextButton] (2026-08-13): the row
    // control was a bare glyph and is now a LABELLED button, so the word
    // "Remove" is on screen twice while the dialog is up. An unscoped
    // `find.text('Remove')` matches both.
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await settle(tester);

    expect(s.devices.isSaved('DEV-A'), isFalse);
    expect(ble.connectedId, isNull,
        reason: 'a peripheral we are still connected to never advertises, so '
            'leaving the link up makes the deleted unit unfindable in the very '
            'scan the delete kicks off');
  });

  // ---------------------------------------------------------------------------
  // The same family as the delete bug above, one step further along: there the
  // link was one the user did NOT want and the fix was to release it. Here it
  // is a link they DO want, and releasing it would be wrong — so the row has to
  // come back instead.
  //
  // Owner, 2026-08-12, on v0.7.14: 「我先連線一個電池裝置　然後我沒有儲存　然後
  // 我跳到主頁再回去　我就沒辦法再搜尋裝置看到他了」.
  // ---------------------------------------------------------------------------
  testWidgets('a connected-but-unnamed unit survives leaving the tab and '
      'coming back', (tester) async {
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

    // Connect it, then DECLINE the name. "A device the user declined to name is
    // one they declined to remember" — so nothing is written, and 已儲存 will
    // never list it.
    await tester.tap(find.text('Connect').last);
    await settle(tester);
    await tester.tap(find.text('Skip'));
    await settle(tester);
    expect(s.devices.isSaved('DEV-NEW'), isFalse, reason: 'the precondition');
    expect(s.connection.connectedDeviceId, 'DEV-NEW',
        reason: '…and the link is up on a unit no list owns');

    // 主頁 and back. `active` goes false (stopScan) then true (startScan), and
    // a fresh scan starts from an empty roster — while the unit, being
    // connected, is not advertising for it to find.
    await pumpPage(tester, s, active: false);
    await settle(tester);
    await pumpPage(tester, s, active: true);
    await settle(tester);

    expect(find.text('RCE-CarBatt'), findsOneWidget,
        reason: 'a connected peripheral does not advertise, so no scan can '
            'ever bring this row back — the page has to keep it. Without it '
            'the unit is on neither tab, has no home tile (those are built '
            'from SAVED devices), and the only control that could release the '
            'link is the 中斷 button on the row that just disappeared.');
    expect(find.text('Disconnect'), findsOneWidget,
        reason: 'and the way out has to be on it');

    // The row is a door too: 儲存 lives behind the detail page, which is the
    // only route left to naming this unit without dropping the link first.
    await tester.tap(find.text('RCE-CarBatt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.byType(DeviceDetailPage), findsOneWidget);
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
    ///
    /// [openTab] exists for the second half of a test that is ALREADY on 搜尋
    /// 裝置: tapping a tab you are standing on is a no-op the framework still
    /// hit-tests, and it warns when a route is on its way out over the tab bar.
    /// Saying "I am already here" beats tapping and ignoring the miss.
    Future<void> seeNearby(
      WidgetTester tester, {
      String id = 'DEV-NEW',
      String name = 'RCE-CarBatt',
      bool openTab = true,
    }) async {
      await tester.runAsync(() async {
        ble._scanOut.add([
          DiscoveredDevice(id: id, name: name, rssi: -55, isVendor: true),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      if (openTab) {
        await openScanTab(tester);
      } else {
        // The tap is skipped; the FRAMES are not. `openScanTab`'s value on a
        // tab you are already standing on was never the tap — it was the
        // 400 ms it pumps afterwards, which is what lets the TabBarView finish
        // sliding back into place once a route stops covering it.
        await tester.pump(const Duration(milliseconds: 400));
        await settle(tester);
      }
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
      // The route's exit animation, then the frame that follows it. `settle`
      // alone pumps once, which leaves it mid-fade over the tab bar.
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);

      // (b) no advertised name ⇒ the id stands in. A MAC-shaped id is shown
      // whole; only a UUID gets shortened (design 0055 §4.2). Already on the
      // scan tab from (a) — see `seeNearby`'s [openTab].
      await seeNearby(tester,
          id: 'C4:D5:66:12:1A:2B', name: '', openTab: false);
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
    // 🔴 A second drain, added with FB-75 (2026-08-14). Opening a saved unit's
    // page now starts a connection by itself, and that writes an EVT line — a
    // real (ffi) insert whose lock timer is created inside the fake-async zone
    // AFTER the last pump. Without this the assertions above still pass and the
    // test fails at teardown with "a Timer is still pending", which reads like a
    // leak in the page rather than one more database write.
    //
    // Twice, because `settle` drains and THEN pumps: the resumed scan's own EVT
    // insert is issued by the pump at the end of the previous settle, so it
    // needs a drain that comes after it.
    await settle(tester);
    await settle(tester);
  });

  // ---------------------------------------------------------------------------
  // RENAMING — reported 2026-08-13 by a community member:「主面板已加入RCE產品，
  // 目前如果要更改名稱，刪除再重新設定！請問是否可以直接更改名稱？」
  //
  // 🔑 The feature was NEVER missing. `DeviceRepo.updateAlias`,
  // `DeviceController.rename`, `showAliasDialog(isRename: true)` and both
  // locales' strings have all shipped for months, and `data_test.dart` pins the
  // repo layer. What was missing was any test that went through the UI — and
  // the UI was a 14 px `Icons.edit_outlined` in an unpadded `InkWell` (a 14×14
  // dp target, no tooltip, no label) with the DELETE key 7 px to its right. So
  // the reporter deleted the device and set it up again, and nothing in this
  // suite could have noticed, because nothing in this suite ever pressed it.
  //
  // That is the second time: `home_page.dart`'s `onEdit` records 2026-08-07's
  // 「沒有這個功能呢」about an 18 px grey `Icons.tune`. These tests exist so the
  // third time cannot be silent — they assert the WORD and the TARGET SIZE, not
  // just that a callback is wired, because "wired but unfindable" is precisely
  // the defect.
  // ---------------------------------------------------------------------------
  group('rename: a control that can be found', () {
    /// The saved row's rename button. Anchored on its [Tooltip] because the
    /// whole card is an [InkWell] too, so an ancestor-InkWell finder is
    /// ambiguous by construction.
    Finder rowAction(String label) => find.ancestor(
          of: find.text(label),
          matching: find.byType(Tooltip),
        );

    testWidgets('the saved row carries the WORD 重新命名, on a hittable target',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);

      final rename = rowAction('Rename');
      expect(rename, findsOneWidget,
          reason: 'a control nobody finds is a control that does not exist — '
              'the word is the fix, not a louder glyph');
      expect(tester.widget<Tooltip>(rename).message, 'Rename');

      final size = tester.getSize(rename);
      expect(size.height, greaterThanOrEqualTo(40),
          reason: 'it was 14×14 dp. Material asks for 48, HIG for 44; 40 is '
              'the floor this row can carry');
      expect(size.width, greaterThanOrEqualTo(40));

      // …and it is nowhere near the destructive one any more. 7 px is what the
      // reporter most likely mis-tapped.
      final gap = tester.getRect(rowAction('Remove')).left -
          tester.getRect(rename).right;
      expect(gap, greaterThan(40),
          reason: 'rename and delete sit at opposite ends of the row');
    });

    testWidgets('…and both words still fit a 320 pt phone', (tester) async {
      // The row was restructured to carry two labels where it used to carry two
      // glyphs, so the 320 pt case is the one that has to be checked — see
      // `toolbar_narrow_screen_test.dart` for the last time a control was
      // silently clipped there and shipped.
      tester.view.physicalSize = const Size(320 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);

      // 🔴 This used to be `while (tester.takeException() != null) {}`, added
      // 2026-08-14 to swallow two pre-existing RenderFlex overflows found while
      // writing this test: `_Header`'s title/rescan row (37 px) and
      // `_StatusBadge` squeezed by the row's narrow middle column (80 px).
      // Both were fixed the same day (Flexible + ellipsis on each), so the
      // swallow is now an assertion — and it has to be, because a blanket
      // `takeException` loop would also eat the THIRD overflow nobody has
      // written yet. In release builds a RenderFlex overflow paints no stripes;
      // it is a silent clip. This line is the only thing that would say so.
      expect(tester.takeException(), isNull,
          reason: 'no RenderFlex overflow at 320 pt');

      final rename = rowAction('Rename');
      final remove = rowAction('Remove');
      expect(rename, findsOneWidget);
      expect(remove, findsOneWidget);
      // Not clipped: both boxes lie inside the surface.
      expect(tester.getRect(rename).left, greaterThanOrEqualTo(0));
      expect(tester.getRect(remove).right, lessThanOrEqualTo(320));

      // 🔴 AMENDED 2026-08-17, when design 0066 put a third action between
      // these two. This used to read `remove.left > rename.right`, which is a
      // statement about ONE LINE and stopped being the right question the
      // moment the row became a [Wrap]: at 320 pt the three actions no longer
      // fit side by side, so 移除 drops to a second run — where its `left` is
      // near zero and the old assertion fails while the property it was
      // protecting is better satisfied than before.
      //
      // What that property actually is, from the comment at the call site: the
      // 2026-08-13 report was most likely a mis-tap of the DESTRUCTIVE control
      // 7 px from the one the user wanted, so rename and remove must never be
      // adjacent. Stated directly — on the same run they are far apart, on
      // different runs they are not neighbours at all — it survives the layout
      // change instead of pinning one particular way of achieving it.
      final r = tester.getRect(rename);
      final x = tester.getRect(remove);
      final sameRun = (x.top - r.top).abs() < 1;
      expect(
        sameRun ? x.left - r.right > 40 : true,
        isTrue,
        reason: 'rename and the destructive action must never end up 7 px '
            'apart on one line — that mis-tap is what this row was rebuilt for',
      );
      // …and whichever way it laid out, no third action is wedged on top of
      // either of them.
      expect(r.overlaps(x), isFalse);
    });

    testWidgets('tapping it renames the device, in place', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      expect(find.text('Cap #1'), findsOneWidget);

      await tester.tap(rowAction('Rename'));
      await settle(tester);

      // The RENAME copy, pre-filled with the alias it is replacing — not the
      // "save a new device" copy.
      expect(find.text('Set a new alias for this device.'), findsOneWidget);
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      expect(tester.widget<TextField>(field).controller?.text, 'Cap #1');

      await tester.enterText(field, 'Cap #1 rear');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(s.devices.deviceFor('DEV-A')?.alias, 'Cap #1 rear',
          reason: 'the rename must reach `updateAlias`');
      expect(find.text('Cap #1 rear'), findsOneWidget,
          reason: '…and the list must say so without a reload');
      expect(find.text('Cap #1'), findsNothing);
      // R22's rule holds for this control too: nothing navigates.
      expect(find.byType(DevicesPage), findsOneWidget);
      expect(find.byType(DeviceDetailPage), findsNothing);
    });

    testWidgets('cancelling changes nothing', (tester) async {
      // The other half — and the one that matters, because the flow now runs
      // through `promptAndRenameDevice`, which must keep cancel (null) and an
      // emptied field ('') different answers.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);

      await tester.tap(rowAction('Rename'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'discarded');
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(s.devices.deviceFor('DEV-A')?.alias, 'Cap #1');
      expect(find.text('Cap #1'), findsOneWidget);
    });

    testWidgets('an EMPTIED name is saved as empty, not read as a cancel',
        (tester) async {
      // `alias_dialog.dart`'s 2026-08-11 rule, one layer up: '' is an answer
      // and the list renders it as 未命名裝置. A `if (alias.isEmpty) return`
      // anywhere in the rename path would rebuild that bug.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);

      await tester.tap(rowAction('Rename'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(s.devices.deviceFor('DEV-A')?.alias, '');
      expect(find.text('Unnamed device'), findsOneWidget);
    });

    // -------------------------------------------------------------------------
    // design 0066 §3.7 — 設定型號, beside 重新命名. The two live in one group
    // because they share a row and a condition, and because the entrance is the
    // half of this feature that can silently not exist: the form, the columns
    // and the migration can all be perfect while nobody can reach them.
    // -------------------------------------------------------------------------
    testWidgets('T66: the saved row carries 型號, on a hittable target',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);

      final declare = rowAction('Model');
      expect(declare, findsOneWidget,
          reason: 'the owner placed it beside 重新命名 (§3.7)');
      final size = tester.getSize(declare);
      expect(size.height, greaterThanOrEqualTo(40));
      expect(size.width, greaterThanOrEqualTo(40));
      // It sits BETWEEN rename and the destructive one, so 移除 keeps the far
      // edge — the 2026-08-13 mis-tap this row was rebuilt for.
      expect(tester.getRect(declare).left,
          greaterThan(tester.getRect(rowAction('Rename')).left));
      expect(tester.getRect(declare).right,
          lessThan(tester.getRect(rowAction('Remove')).right));
    });

    testWidgets('T66: it opens the form and the answer reaches the row',
        (tester) async {
      // End to end through the real controller and a real database — the layers
      // between the dialog and the column are each covered in
      // `declared_model_test.dart`, and what is left to check is that they are
      // actually joined up.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);

      await tester.tap(rowAction('Model'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('declared-category-car-battery')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('declared-capacity')), '40B19L');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('declared-save')));
      await settle(tester);

      final d = s.devices.deviceFor('DEV-A')!;
      expect(d.declared.category, DeclaredCategory.carBattery);
      expect(d.declared.capacity, '40B19L');
      // 🔴 And the measured class is exactly where it was (§3.5). The unit
      // reported nothing, so it is still `unknown` — declaring a car battery
      // must not have "helpfully" resolved it.
      expect(d.productClass, ProductClass.unknown);
      // R22 holds for this control too: nothing navigates.
      expect(find.byType(DevicesPage), findsOneWidget);
      expect(find.byType(DeviceDetailPage), findsNothing);
    });

    testWidgets('T66: an UNSAVED row has no 型號 entrance', (tester) async {
      // §3.7's condition, checked where a user would meet it: an unsaved unit
      // has no row for the seven columns, so offering the form would produce a
      // dialog whose Save does nothing — the 2026-08-11「儲存裝置後沒反應」shape.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await openScanTab(tester);
      await tester.runAsync(() async {
        ble._scanOut.add([
          const DiscoveredDevice(
              id: 'DEV-NEW', name: 'RCE-CarBatt', rssi: -55, isVendor: true),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();

      expect(find.text('RCE-CarBatt'), findsOneWidget);
      expect(rowAction('Model'), findsNothing,
          reason: 'the saved tab is not on screen, and the nearby row carries '
              'no per-row actions at all');
    });

    // -------------------------------------------------------------------------
    // The device's OWN page. Every home tile lands there
    // (`home_tiles.dart`), and until 2026-08-13 it had no route to a rename at
    // all — so a user who never opens the 裝置 tab had none either.
    // -------------------------------------------------------------------------
    Future<void> openDetail(WidgetTester tester, String rowLabel) async {
      await tester.tap(find.text(rowLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // route transition
      await settle(tester);
      expect(find.byType(DeviceDetailPage), findsOneWidget);
    }

    testWidgets('the device page has one too, and it is a WORD not an icon',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpPage(tester, s);
      await settle(tester);
      await openDetail(tester, 'Cap #1');

      // 🔴 A [TextButton] carrying the word. The page's own discipline
      // (`device_detail_page.dart`: "A SENTENCE with a button, not an AppBar
      // icon") bars a bare glyph here, and this test is what holds the line:
      // swap it for an `IconButton` and this fails.
      final entry = find.descendant(
        of: find.byType(DeviceDetailPage),
        matching: find.widgetWithText(TextButton, 'Rename'),
      );
      expect(entry, findsOneWidget);

      await tester.tap(entry);
      await settle(tester);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Cap #1 front');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(s.devices.deviceFor('DEV-A')?.alias, 'Cap #1 front');
      // The page titles itself from the alias, so the new name lands here.
      expect(
        find.descendant(
          of: find.byType(DeviceDetailPage),
          matching: find.text('Cap #1 front'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an UNSAVED unit\'s page offers 儲存, not 重新命名',
        (tester) async {
      // There is no alias to change on a unit with no record, and that state
      // already has its own sentence-with-a-button (`_UnsavedNotice`). Two
      // entrances to two different things would be worse than one.
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
      await openDetail(tester, 'RCE-CarBatt');

      expect(
        find.descendant(
          of: find.byType(DeviceDetailPage),
          matching: find.widgetWithText(TextButton, 'Rename'),
        ),
        findsNothing,
      );
    });
  });
}
