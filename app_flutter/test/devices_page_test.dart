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
// 🔴 OVERTURNED IN PART, 2026-08-21 — FB-92 / pro design 0075, owner's ruling
// (§8 Q1–Q5). Everything above is kept word for word: the harm 林陳裕 reported
// is real, the measurement is real, and R22 still governs `_disconnect`. What
// the owner ruled (Q1) is that R22's sentence 「UI 留在裝置頁」 carries two
// readings it never separated, and the NARROW one is the rule — do not drop the
// user onto a screen that cannot show them the connect is happening. The sheet
// did exactly that. A push that waits for `ready` does not: the list keeps a
// spinner on the pressed row for the whole wait, and the page that finally
// appears has telemetry on it rather than an empty state.
//
// So N4 no longer pins an absence. It pins a PRESENCE with four conditions
// attached, and the conditions are what the `FB-92` group below tests one at a
// time: a failure must not navigate (C1/C4), the wrong unit's `ready` must not
// navigate (C2), a user who moved on must not be navigated (C3), and a link
// that died behind the naming dialog must not navigate (C6). The absence this
// file used to protect now lives in those four, which is the honest place for
// it — the danger was never "a Navigator call exists", it was "the user is
// taken somewhere that cannot answer them".
//
// ⛔ Red line carried down from design 0075 §3.3: nothing here fixes
// 「連線一樣還是要點兩次」. FB-88 is the heaviest cause of that and is untouched.
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

  /// How many times a connect was asked for.
  ///
  /// FB-92 §6.1 is a claim about a button REFUSING a second press, and the only
  /// evidence for that is the count not going up. `connectedId` cannot show it:
  /// a second connect to the same unit leaves it exactly as it was.
  int connects = 0;

  /// Stop the fake link at `connected` instead of running on to `ready`.
  ///
  /// 🔴 This is the FB-51/FB-52 shape, and after FB-92 it is also the ONLY way
  /// to observe the window the report is about. The default path emits all
  /// three states in one go, so `connected` and `ready` are the same instant to
  /// every test written before this: the 1.5–2.0 s the field spends between
  /// them — the window in which the old button turned back into a live 連線 and
  /// invited the second tap (`2026.08.18-008.md` §3.3 mechanism ③) — did not
  /// exist in this harness at all. It does now, and a test that wants to look
  /// at it has to ask for it.
  bool stopAtConnected = false;

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
    connects++;
    connectedId = deviceId;
    _linkOut.add(BleLinkState.connecting);
    _linkOut.add(BleLinkState.connected);
    if (stopAtConnected) return;
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

  /// FB-86 (second half): whose stall it is. Null — the default — means the
  /// latch belongs to no unit in particular, which is what the tests about
  /// COPY want; a test about attribution states it.
  String? stalledDeviceId;

  @override
  bool isSetupStalledFor(String? deviceId) =>
      stalledLatch && stalledDeviceId == deviceId;

  @override
  bool get isSetupStalledUnattributed => stalledLatch;

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

  /// [settle], and then let a pushed route actually get on screen.
  ///
  /// 🔴 Needed since FB-92, and the reason is a trap worth stating: a
  /// `Navigator.push` that happens inside an `await` chain is RECORDED by the
  /// navigator and BUILT by the next frame. `settle` gives the database its
  /// real time and pumps once, which is enough to run the push and not enough
  /// to build what it pushed — so every assertion written against `settle`
  /// alone reads a tree the new route is not in yet, and `findsNothing` passes
  /// for the wrong reason. The first N4 rewrite went green against the OLD
  /// expectation for exactly this, which is how it was found. Two more pumps:
  /// one to start the transition, one long enough to finish it.
  Future<void> settleRoute(WidgetTester tester) async {
    // Twice, and it is not superstition: the push is started from an `await`
    // chain, so the first cycle is what RUNS it and the second is what lets the
    // 300 ms transition it starts finish. `pumpAndSettle` is not available as a
    // shortcut here — this page's controller keeps periodic timers alive, so it
    // would spin until its own timeout.
    for (var i = 0; i < 2; i++) {
      await settle(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    await settle(tester);
  }

  /// Come back from the page FB-92 now pushes.
  ///
  /// Several tests below are about what the LIST does after a connect, and
  /// since FB-92 a successful connect puts a route in front of it. They are not
  /// wrong and they have not been weakened — the list is one back gesture away,
  /// exactly as it is for the user — so they take that gesture rather than
  /// asserting against a tree the route is covering.
  Future<void> popBack(WidgetTester tester) async {
    await tester.pageBack();
    await settleRoute(tester);
    expect(find.byType(DeviceDetailPage, skipOffstage: false), findsNothing,
        reason: 'the helper has to actually get back to the list, or every '
            'assertion after it reads the wrong screen — a covered route is '
            'still findable, so this is not self-evident');
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

  // 🔴 N4 — OVERTURNED IN PLACE, 2026-08-21 (FB-92 / design 0075, owner's
  // ruling Q1 + Q2). The original test is kept below, commented out and
  // unedited, because this repo marks a reversal rather than erasing it: if
  // FB-92 ever has to be rolled back, the criterion it displaced has to be
  // readable in the file that displaced it, not reconstructed from git.
  //
  //   testWidgets('N4: connecting a saved device leaves the user on this page',
  //       (tester) async {
  //     // FB `2026.08.02/004`'s closing criterion, stated as an absence.
  //     …
  //     expect(s.connection.isOnline, isTrue);
  //     // THE assertion: the page is still the one the tap happened on. Before
  //     // design 0046 this was a modal sheet that popped itself here, dropping
  //     // the user onto the dashboard's empty state for ~5 s.
  //     expect(find.byType(DevicesPage), findsOneWidget);
  //     expect(find.byType(DeviceDetailPage), findsNothing);
  //     // …and the row says so in place.
  //     expect(find.text('Disconnect'), findsOneWidget);
  //     expect(find.text('Connected'), findsOneWidget);
  //   });
  //
  // 🔑 WHY THE ABSENCE STOPPED BEING THE RIGHT CRITERION. 林陳裕's report was
  // 「切換裝置會先跳回主頁面 3～4 秒，以為藍牙斷線」 — and every word of the
  // damage is in the SECOND half. The sheet did not merely move him; it moved
  // him to the dashboard's empty state and left him there for the 3.1–5.3 s
  // (median 4.97 s over 12) a switch takes, with nothing on screen that could
  // distinguish "working on it" from "the link died". `findsNothing` was a
  // proxy for that, and a good one while the only way to leave this page was to
  // leave it too early.
  //
  // FB-92 leaves LATE instead: not on the `await` (that is GATT `connected`,
  // 0.54 s, and design 0075 §4 rejected it as plan B2 — two spinners in two
  // places), but on `ready`, when telemetry is flowing and the destination has
  // something to show. Until then the user is on this list watching the row
  // they pressed. There is no empty state anywhere in the sequence, so the
  // proxy no longer stands in for the thing it was proxying.
  //
  // The absence is not abandoned — it is now stated four times, once per
  // condition, in the `FB-92` group below. Those are the assertions that would
  // catch a regression which took the user somewhere useless.
  testWidgets(
      'N4′ (FB-92): connecting a saved device opens THAT device\'s page',
      (tester) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    await pumpPage(tester, s);
    await settle(tester);

    expect(find.text('Cap #1'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.byType(DeviceDetailPage), findsNothing,
        reason: 'the precondition: the tap is what opens it');

    await tester.tap(find.text('Connect'));
    await settleRoute(tester);

    // The link is up — and it is up BEFORE the navigation, which is the whole
    // of plan B3. A page that arrives on the `await` arrives 1.5–2.0 s early
    // and spends them drawing `_OfflineBody`.
    expect(s.connection.isOnline, isTrue);
    expect(s.connection.connectedDeviceId, 'DEV-A');
    expect(find.byType(DeviceDetailPage), findsOneWidget,
        reason: 'FB-92: the connect button is a door now, on the one outcome '
            'design 0046 R22 was never about — a link that is ready');
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
    // 🔴 UPDATED FOR FB-92 (design 0075 §6.3, owner's Q4 ⇒ (c)). The half of
    // N5 that matters is asserted ABOVE and is untouched: the prompt appears on
    // THIS page, with the list still behind it. What changed is only what
    // happens after the prompt is answered — C5/C8 add a third beat, and the
    // unit's own page is it. The old line here (`DevicesPage, findsOneWidget`
    // as the last word) would now pass or fail on how many frames the test
    // pumped rather than on any behaviour, which is not an assertion.
    await settleRoute(tester);
    expect(find.byType(DeviceDetailPage), findsOneWidget,
        reason: 'C5/C8: naming is a step on the way to the device, not an '
            'alternative to arriving');
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
    await settleRoute(tester);
    expect(s.devices.isSaved('DEV-NEW'), isTrue);

    // 🔴 RULE 2 IS STILL PINNED HERE — by a different mechanism, on purpose.
    // Design 0075 C7 retires the `_revealSavedTab()` that used to run on this
    // path, because a tab switch covered by a pushed page in the very next
    // frame is a switch nobody can see. It is NOT retired from the app: the
    // tail of `_openDetail` performs it on the way BACK, which is the moment
    // the user can actually see a list. So the assertion moves behind a back
    // gesture; the guarantee — "a device you just named is on the tab you are
    // looking at" — is word for word the one the 2026-08-11 dealer report
    // 「新儲存的不會顯示」 is about, and it still holds.
    expect(find.byType(DeviceDetailPage), findsOneWidget,
        reason: 'FB-92 C5: naming ends on the device, not on the list');
    await popBack(tester);

    expect(find.text('Car #2'), findsOneWidget,
        reason: 'naming a device must reveal the tab that now holds it');
    await tester.tap(find.text('Car #2'));
    await settleRoute(tester);

    expect(find.byType(DeviceDetailPage), findsOneWidget);
  });

  testWidgets('N6: disconnecting leaves the user on this page too',
      (tester) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    await pumpPage(tester, s);
    await settle(tester);

    await tester.tap(find.text('Connect'));
    await settleRoute(tester);
    expect(s.connection.isOnline, isTrue);
    // 🔴 The detour FB-92 adds, and the reason N6 survives it unchanged in
    // substance: the connect now ends on the device's page, so getting back to
    // the row's 中斷 button takes a back gesture. Design 0075 §7 rules
    // `_disconnect` UNTOUCHED — 中斷 means "I am done with this unit", and
    // answering it with that unit's page is the opposite of the request — so
    // what N6 pins is unchanged: pressing it moves nobody anywhere.
    await popBack(tester);
    expect(find.byType(DevicesPage), findsOneWidget);

    await tester.tap(find.text('Disconnect'));
    await settleRoute(tester);

    expect(s.connection.isOnline, isFalse);
    expect(find.byType(DevicesPage), findsOneWidget);
    expect(find.byType(DeviceDetailPage), findsNothing,
        reason: 'R22 in full on this control: a disconnect navigates nowhere');
    expect(find.text('Connect'), findsOneWidget);
  });

  // ==========================================================================
  // FB-92 — the four conditions the navigation is allowed under
  // ==========================================================================
  //
  // N4′ above pins that the page opens. Everything here pins that it does NOT,
  // and that is the harder half: design 0046 R22 was overturned narrowly (Q1),
  // and "narrowly" is only a real distinction if the cases outside the narrow
  // reading still behave the way R22 demanded. Each test below removes one
  // guard's justification and states what the user would suffer without it.
  //
  // 🔴 The heaviest of them is C1's THIRD condition, which design 0075 does not
  // list — see `無人在跑 backstop` below.
  group('FB-92: connect → ready → that unit\'s page (design 0075 §6.2/§6.3)',
      () {
    late _StateConn conn;

    /// Pump with a controller whose error and stall latch a test can state.
    ///
    /// [active] is the shell's "this tab is on screen" flag; pumping again with
    /// a different value is how a test leaves for another tab and comes back,
    /// exactly as `pumpPage` does.
    Future<void> pumpStated(WidgetTester tester, AppServices s,
        {bool active = true}) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<BleService>.value(value: s.ble),
            ChangeNotifierProvider<SettingsController>.value(value: s.settings),
            ChangeNotifierProvider<DeviceController>.value(value: s.devices),
            ChangeNotifierProvider<ConnectionController>.value(value: conn),
            ChangeNotifierProvider<TelemetryController>.value(
                value: s.telemetry),
            ChangeNotifierProvider<GForceController>.value(value: s.gforce),
            ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
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

    /// A saved row whose connect stops at `connected` — i.e. the 1.5–2.0 s the
    /// field spends between the `await` returning and the link being usable,
    /// which is the window every one of these tests is about.
    Future<AppServices> pressConnectAndHang(WidgetTester tester) async {
      final s = await makeServices(tester);
      conn = _StateConn(ble, settings: s.settings);
      addTearDown(() {
        conn.dispose();
        return teardown(tester, s);
      });
      ble.stopAtConnected = true;
      await pumpStated(tester, s);
      await settle(tester);
      await tester.tap(find.text('Connect'));
      await settleRoute(tester);
      expect(find.byType(DeviceDetailPage), findsNothing,
          reason: 'the precondition for all of these: `connected` is NOT '
              '`ready`, and design 0075 rejected leaving on it (plan B2)');
      return s;
    }

    testWidgets('C1/C4: a connect that FAILS keeps the user on the list',
        (tester) async {
      await pressConnectAndHang(tester);

      // The failure lands DURING the wait, which is the case
      // `lastErrorUnattributed` cannot be trusted for and the case a plain
      // `await` never sees at all.
      conn.errorDeviceId = 'DEV-A';
      conn.state(error: 'device_unreachable');
      await settleRoute(tester);

      expect(find.byType(DeviceDetailPage), findsNothing,
          reason: 'design 0075 Q3: a failed connect must not carry the user '
              'anywhere. FB-88 takes out 2 of 6 cross-device switches and is '
              'unfixed — navigating on the attempt would push a third of them '
              'into a detail page nobody asked for');
      expect(find.byType(DevicesPage), findsOneWidget);
      // C1: and the spinner is over. The button is a button again.
      expect(find.text('Connect'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget,
          reason: 'staying put is only acceptable if the page says why');
    });

    testWidgets('C1: a setup that STALLS keeps the user on the list',
        (tester) async {
      await pressConnectAndHang(tester);

      // FB-52's shape: the link comes up and says nothing, three times, and the
      // controller latches. `ready` is never coming.
      conn.stalledDeviceId = 'DEV-A';
      conn.state(stalled: true);
      await settleRoute(tester);

      expect(find.byType(DeviceDetailPage), findsNothing);
      expect(find.text('Connect'), findsOneWidget,
          reason: 'C1: a spinner with no terminating condition is the defect '
              'v0.6.15 shipped a fix for; the stall latch is one of its ends');
      expect(find.byType(SnackBar), findsNothing,
          reason: 'nothing new to say — the row badge already reads 沒有回應, '
              'and a snackbar saying "connection failed" over a link that IS '
              'connected would contradict it');
    });

    testWidgets(
        'C1 backstop: 自動重連 off + a drop before `ready` ends the wait '
        '(design 0075 does NOT list this one)', (tester) async {
      final s = await pressConnectAndHang(tester);
      await tester.runAsync(() => s.settings.setAutoReconnect(false));
      await tester.pump();

      // 🔴 THE HOLE IN C1. With the setting off, a link that reached
      // `connected` and then dropped produces:
      //   * no error   — `connect()` returned long ago, a stream event cannot
      //                  throw;
      //   * no retry   — `_scheduleReconnect` is gated on `autoReconnect`;
      //   * no stall   — that needs THREE silent connections; this is the first.
      // Both of design 0075 C1's conditions are false and stay false, so a
      // literal implementation of the doc spins until the app is killed.
      ble.connectedId = null;
      ble._linkOut.add(BleLinkState.disconnected);
      await settleRoute(tester);

      expect(find.byType(DeviceDetailPage), findsNothing);
      expect(find.text('Connect'), findsOneWidget,
          reason: 'nothing is running any more, so nothing is being waited '
              'for — without the backstop this row spins forever');
    });

    testWidgets('C2: ANOTHER unit reaching `ready` does not open this one',
        (tester) async {
      await pressConnectAndHang(tester);

      // `isOnline` is `_link == ready` and says nothing about whose link it is.
      // Here DEV-A is the row that was pressed and DEV-B is what came up.
      ble.connectedId = 'DEV-B';
      ble._linkOut.add(BleLinkState.ready);
      await settleRoute(tester);

      expect(conn.isOnline, isTrue, reason: 'the precondition: SOMETHING is up');
      expect(conn.connectedDeviceId, 'DEV-B');
      expect(find.byType(DeviceDetailPage), findsNothing,
          reason: 'C2: an `isOnline`-only test opens the pressed row\'s page '
              'off another unit\'s link — the design 0068 confusion, '
              'manufactured by our own navigation');
    });

    testWidgets(
        'C4: ANOTHER unit\'s failure does not cancel this unit\'s navigation',
        (tester) async {
      await pressConnectAndHang(tester);

      // 🔴 The half of C4 that only a per-unit read gets right. `wrong_device`
      // is filed against the unit it happened to (`_setError('wrong_device',
      // deviceId: …)`), and design 0075 §4 B2 measured such a code landing
      // within 20 ms of the `await` returning. Read UNATTRIBUTED and this is
      // "the last error there was" — DEV-A's own connect would be abandoned on
      // the strength of something that happened to DEV-B, and the user would
      // press 連線 again on a row that was about to come up.
      conn.errorDeviceId = 'DEV-B';
      conn.state(error: 'wrong_device');
      await settle(tester);
      expect(conn.lastErrorUnattributed, isNotNull, reason: 'the precondition');
      expect(conn.lastErrorFor('DEV-A'), isNull,
          reason: '…and it is not a fact about DEV-A');

      ble._linkOut.add(BleLinkState.ready);
      await settleRoute(tester);

      expect(find.byType(DeviceDetailPage), findsOneWidget,
          reason: 'C4: the decision is scoped to the unit the user pressed');
    });

    testWidgets('C3: leaving the tab mid-connect cancels the navigation',
        (tester) async {
      final s = await pressConnectAndHang(tester);

      // The user goes to another tab. This page stays MOUNTED behind it (it
      // lives in the shell's IndexedStack), so nothing here is torn down and
      // the connect keeps going — they asked for the link, they just stopped
      // watching it happen.
      await pumpStated(tester, s, active: false);
      await settle(tester);

      // …and now it comes up.
      ble._linkOut.add(BleLinkState.ready);
      await settleRoute(tester);

      expect(conn.isOnline, isTrue, reason: 'the connect was NOT cancelled');
      await pumpStated(tester, s, active: true);
      await settleRoute(tester);
      expect(find.byType(DeviceDetailPage), findsNothing,
          reason: 'C3 is the last of R22 that survives intact: once the user '
              'has moved on, the screen must not move for them. A page that '
              'shoves itself in front of whatever they went to do is the same '
              'harm FB `2026.08.02/004` reported, aimed somewhere else');
    });

    // ⚠️ NAME CHANGED 2026-08-21 with the ruling below. It was 「…and the
    // button is inert for all of it」; the button is no longer inert (it is a
    // door), and what the test still pins — that a second press cannot reach
    // the radio — was always the part worth having.
    testWidgets('§6.1: the spinner runs to `ready`, and the RADIO is out of '
        'reach for all of it', (tester) async {
      await pressConnectAndHang(tester);

      // 🔴 The whole of `2026.08.18-008.md` §3.3 mechanism ③ is this instant.
      // Before FB-92 the spinner stopped when the `await` returned — GATT
      // `connected`, ~0.5 s — and for the next 1.5–2.0 s the row showed a live
      // 連線 button over a link that was still forming. 何先生 pressed it again
      // 1.0–1.1 s in and killed the link he was waiting for; one episode took
      // four taps. He was not being impatient, the screen invited him.
      expect(find.text('Connect'), findsNothing,
          reason: 'the row must still be spinning at `connected`');
      expect(find.text('Disconnect'), findsNothing,
          reason: '…and must not be claiming success either');

      final spinner = find.byWidgetPredicate(
          (w) => w is CircularProgressIndicator && w.strokeWidth == 1.8);
      expect(spinner, findsOneWidget);

      // 🔴 OVERTURNED IN PLACE, 2026-08-21 — owner's ruling (c) on the same
      // day this test was written. THE ORIGINAL ASSERTION AND ITS REASONING
      // ARE KEPT BELOW, WORD FOR WORD AND COMMENTED OUT:
      //
      //   // ⚠️ ASSERTED ON THE WIDGET, NOT BY TAPPING, and this is not
      //   // fussiness. `_ConnectButton` locks itself with `onTap: connecting ?
      //   // null : onTap`, which makes the InkWell inert — it does NOT absorb
      //   // the gesture. The row BODY underneath is a door (design 0055 §4.1),
      //   // so a tap on the spinning button falls through and opens the detail
      //   // page. That is pre-existing behaviour, it is not FB-92's to change
      //   // (whether it is even wrong under B3 is an open question for the
      //   // owner), and a `tester.tap` here would quietly assert the
      //   // fall-through instead of the lock. See the report.
      //   final button = tester.widget<InkWell>(find
      //       .ancestor(of: spinner, matching: find.byType(InkWell))
      //       .first);
      //   expect(button.onTap, isNull,
      //       reason: 'the button must refuse a second press for the WHOLE '
      //           'wait, not for the first half second of it');
      //
      // 🔑 WHY IT WAS THE WRONG ASSERTION. It is a true statement about the
      // code and a FALSE statement about the product: what the user got from a
      // second press was never "nothing", it was the detail page, because the
      // press fell through to the row. The comment above says so itself and
      // then pins the `null` anyway — so the file was pinning the mechanism
      // while the shipped behaviour lived one layer down, unnamed and unpinned.
      // The owner's answer to the open question it flags is (c): KEEP THE
      // BEHAVIOUR, LOSE THE ACCIDENT. 「還在連的時候再按一次 ＝ 我不想等，
      // 現在就過去」.
      //
      // What the `null` was actually protecting is untouched and is now stated
      // as itself below: the second press must not reach the radio.
      final button = tester.widget<InkWell>(find
          .ancestor(of: spinner, matching: find.byType(InkWell))
          .first);
      expect(button.onTap, isNotNull,
          reason: 'FB-92 (c): the spinning button ANSWERS the second press — '
              'and it has to be the BUTTON that answers, not the row body it '
              'used to leak the gesture to');
      expect(ble.connects, 1);

      // …and it ends where it should.
      ble._linkOut.add(BleLinkState.ready);
      await settleRoute(tester);
      expect(find.byType(DeviceDetailPage), findsOneWidget);
      expect(ble.connects, 1, reason: 'one press, one connect');
    });

    // ------------------------------------------------------------------
    // FB-92 (c) — 「我不想等，現在就過去」 (owner, 2026-08-21).
    //
    // 🔴 READ THIS BEFORE CHANGING EITHER TEST BELOW. Both are written against
    // the button's OWN callback (`button.onTap!()`), never with `tester.tap`,
    // and that is the only construction that can tell the ruling apart from
    // the accident it replaced. A `null` `onTap` leaves the InkWell inert but
    // does not absorb the gesture, so a `tester.tap` on the spinner lands on
    // the row body — which is a door (design 0055 §4.1) and opens the very
    // same page. Revert the implementation and a tap-based test STAYS GREEN.
    // Verified, not assumed: that is exactly how the assertion above was found
    // to be pinning the wrong thing.
    // ------------------------------------------------------------------

    /// Press connect, hang at `connected`, and hand back the spinning button.
    Future<AppServices> spinningButton(
      WidgetTester tester,
      void Function(InkWell button) use,
    ) async {
      final s = await pressConnectAndHang(tester);
      final spinner = find.byWidgetPredicate(
          (w) => w is CircularProgressIndicator && w.strokeWidth == 1.8);
      expect(spinner, findsOneWidget, reason: 'the premise: it is turning');
      use(tester.widget<InkWell>(
          find.ancestor(of: spinner, matching: find.byType(InkWell)).first));
      return s;
    }

    testWidgets('(c): the spinning button opens the page WITHOUT dialling '
        'again', (tester) async {
      await spinningButton(tester, (button) => button.onTap!());
      await settleRoute(tester);

      expect(find.byType(DeviceDetailPage), findsOneWidget,
          reason: 'the ruling: a second press means 「我不想等，現在就過去」, '
              'so it goes — the link is still forming, and the destination '
              'shows that forming (design 0075 §3.1: `_OfflineBody` is a '
              'progress report, not the empty dashboard R22 was about)');

      // 🔴 THE HALF THAT MATTERS MORE THAN THE NAVIGATION. `connect()` opens by
      // tearing down whatever link is there, so a second dial at ~1.0 s kills
      // the link that is forming — `2026.08.18-008.md` §3.3 mechanism ③, wire
      // evidence, four taps for one link. FB-92 exists to close that window,
      // and a door that dialled on the way through would reopen it while
      // looking like an improvement.
      expect(ble.connects, 1,
          reason: 'the door must NOT dial: a second connect here is mechanism '
              '③, the defect this whole report is about');
      expect(ble.connectedId, 'DEV-A');

      // And the link it did not touch is still there to come up.
      ble._linkOut.add(BleLinkState.ready);
      await settleRoute(tester);
      expect(conn.isOnline, isTrue,
          reason: 'the forming link survived the press');
    });

    testWidgets('(c): going early CANCELS the wait — `ready` does not push a '
        'second page', (tester) async {
      await spinningButton(tester, (button) => button.onTap!());
      await settleRoute(tester);
      expect(find.byType(DeviceDetailPage), findsOneWidget);

      // Back to the list, deliberately, while the link is still coming up.
      await popBack(tester);

      // …and NOW it becomes usable. The pending §6.2 navigation must be gone:
      // this user has already been to that page and has just chosen to leave
      // it. Shoving them back in two seconds later is FB `2026.08.02/004`'s
      // harm with a different destination — the screen moving on its own after
      // the user has moved on. `_openDetail` settles the wait as
      // `_ConnectOutcome.abandoned` for exactly this.
      ble._linkOut.add(BleLinkState.ready);
      await settleRoute(tester);

      expect(conn.isOnline, isTrue, reason: 'the premise: the link DID come up');
      expect(conn.connectedDeviceId, 'DEV-A');
      expect(find.byType(DeviceDetailPage, skipOffstage: false), findsNothing,
          reason: 'C3: the promise was kept early, so it must not be kept '
              'again — one press, one page');
      expect(find.text('Disconnect'), findsOneWidget,
          reason: 'and the list says so in place, which is all that is left '
              'to do here');
    });

    // ------------------------------------------------------------------
    // PER-DEVICE SCOPING — WHICH ROW TURNS, AND ON WHOSE AUTHORITY.
    //
    // 📌 Ported from the parallel branch `fix/fb-92-spinner-until-ready`
    // (`5cb543e`), whose IMPLEMENTATION was not adopted: it rebuilt the spinner
    // out of the controller (`_rowConnecting(conn, id)`), where this branch
    // keeps `_connectingId` and hangs a wait state machine off it so that
    // §6.1's lock and §6.2's navigation are the same object rather than two
    // things that have to agree. These two tests outlive the branch that wrote
    // them because they are about the CONTRACT and not about either
    // implementation — and because a controller-driven spinner is the obvious
    // simplification for a later reader to reach for, which is precisely when
    // both of these break.
    //
    // Rewritten against this harness rather than copied: `stopAtConnected`
    // instead of that branch's `readyAfterConnect`, and the REAL controller
    // (`pumpPage`) rather than `_StateConn`, since what is being asked here is
    // which row draws a spinner and nothing about error attribution.
    // ------------------------------------------------------------------

    /// The row spinner: 1.8 px stroke, which is `_ConnectButton`'s and nothing
    /// else's on this page.
    final rowSpinner = find.byWidgetPredicate(
        (w) => w is CircularProgressIndicator && w.strokeWidth == 1.8);

    testWidgets('PER DEVICE: another unit connecting leaves this row alone',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(
          () => s.devices.saveNew('DEV-B', 'Cap #2', name: 'RCE-SCAP_II'));
      ble.stopAtConnected = true;
      await pumpPage(tester, s);
      await settle(tester);
      expect(find.text('Connect'), findsNWidgets(2), reason: 'two saved rows');

      // Press one row and hold its link in the connected-but-not-ready window.
      // Which row the list puts last is not this test's subject, so the busy
      // unit is READ rather than assumed.
      await tester.tap(find.text('Connect').last);
      await settleRoute(tester);
      final busy = ble.connectedId;
      expect(busy, anyOf('DEV-A', 'DEV-B'));
      final other = busy == 'DEV-A' ? 'DEV-B' : 'DEV-A';

      // 🔴 EXACTLY ONE ROW TURNS. A spinner read off the controller's global
      // `isBusy` would turn both — and since FB-92 the spinner is also the lock
      // and the promise of a page, so a spinner on the wrong row locks the row
      // the user might have wanted instead and promises them a page about a
      // unit they never pressed.
      expect(rowSpinner, findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);

      // And the surviving button is the OTHER unit's — still live, and still
      // aimed at the unit its own row is about.
      await tester.tap(find.text('Connect'));
      await settleRoute(tester);
      expect(ble.connectedId, other);
      expect(ble.connects, 2);
    });

    // The other half of "per device", and the half the test above cannot see:
    // there, the spinner is off because the busy unit is a DIFFERENT row. Here
    // it is THIS row's unit that is coming up — and the user never asked for
    // it, so the button is not this page's to take away.
    //
    // 🔴 This is what `_connectingId` is for and nothing else pins it: an
    // auto-reconnect after a drop, a connect started from the detail page, or
    // an iOS hand-off drives `isBusy` and `connectedDeviceId` exactly as a
    // pressed button does. Under FB-92 the stakes went up — a spinner built
    // from the controller alone would lock a list the user merely walked back
    // into AND then push a detail page at them, with no press of theirs
    // anywhere in the story. That is R22's harm reconstructed out of §6.2.
    testWidgets('a connect the user did NOT ask for takes no button away',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      ble.stopAtConnected = true;
      await pumpPage(tester, s);
      await settle(tester);

      // Straight at the controller — the shape of every connect this page did
      // not start.
      await tester.runAsync(
          () => s.connection.connectToSaved(s.devices.deviceFor('DEV-A')!));
      await settleRoute(tester);
      expect(s.connection.connectedDeviceId, 'DEV-A');
      expect(s.connection.isBusy, isTrue, reason: 'the precondition: busy…');
      expect(s.connection.isOnline, isFalse, reason: '…and not ready');

      expect(rowSpinner, findsNothing);
      expect(find.text('Connect'), findsOneWidget);
      expect(find.byType(DeviceDetailPage, skipOffstage: false), findsNothing,
          reason: 'and no page either: §6.2 navigates for a press, not for '
              'every link that happens to come up');

      // "Not taken away" has to mean the button still WORKS, not merely that
      // the word is still painted there.
      await tester.tap(find.text('Connect'));
      await settleRoute(tester);
      expect(ble.connects, 2);
      expect(rowSpinner, findsOneWidget,
          reason: 'and NOW it is this page\'s connect, so now it turns');
    });

    // ------------------------------------------------------------------
    // §6.3 — the unsaved path. Owner's Q4 ⇒ (c): the naming dialog stays,
    // it stays on THIS page, and it is not allowed to become a cancel.
    // ------------------------------------------------------------------

    Future<AppServices> connectNearbyUnsaved(WidgetTester tester) async {
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
      expect(find.byType(TextField), findsOneWidget,
          reason: 'Q4 ⇒ (c): the prompt is kept, and kept on this page');
      expect(find.byType(DeviceDetailPage), findsNothing,
          reason: 'C8: three beats — spinner, dialog, page — in that order');
      return s;
    }

    testWidgets('C5: 跳過 declines the RECORD, not the device — it still opens '
        'the page', (tester) async {
      final s = await connectNearbyUnsaved(tester);

      await tester.tap(find.text('Skip'));
      await settleRoute(tester);

      expect(s.devices.isSaved('DEV-NEW'), isFalse,
          reason: 'a device the user declined to name is one they declined to '
              'remember — 跳過 still writes nothing');
      expect(find.byType(DeviceDetailPage), findsOneWidget,
          reason: 'C5: binding "do not save this" to "do not show me this" '
              'turns 跳過 into a cancel the user never asked for. The field '
              'declines it 42 times out of 42 (何先生, 2026.08.18/008), so on '
              'that phone the whole feature would be dead');
    });

    testWidgets('C6: a unit that DROPS while the dialog is up opens nothing',
        (tester) async {
      final s = await connectNearbyUnsaved(tester);

      // The dialog has no deadline. A user can put the phone down on it, walk
      // away from the vehicle, and answer it five minutes later.
      ble.connectedId = null;
      ble._linkOut.add(BleLinkState.disconnected);
      await settle(tester);

      await tester.tap(find.text('Skip'));
      await settleRoute(tester);

      expect(s.connection.isOnline, isFalse, reason: 'the precondition');
      expect(find.byType(DeviceDetailPage), findsNothing,
          reason: 'C6: `ready` was a fact about a moment that has passed. '
              'Opening a device page for a link that no longer exists is the '
              'empty-state landing FB `2026.08.02/004` is about, arriving two '
              'minutes late');
      expect(find.byType(DevicesPage), findsOneWidget);
    });

    testWidgets('C6 + rule 2: when the drop blocks the page, the saved tab is '
        'revealed instead', (tester) async {
      // 🔴 A REFINEMENT OF C7, and the one place this implementation does not
      // do what design 0075 says literally. C7 retires `_revealSavedTab()` from
      // `_connectNew` on the grounds that a tab switch covered by a pushed page
      // is invisible — true, and true only when the page is actually pushed.
      // On the C6 branch it is not: the user stays on 搜尋裝置, and the row
      // they just named has this instant moved to the other tab. That is
      // 「新儲存的不會顯示」 (dealer, 2026-08-11) word for word — the complaint
      // design 0055 §7.1 rule 2 exists to prevent and which the sub-tab split
      // would otherwise manufacture. So C7 is applied to the success path only.
      final s = await connectNearbyUnsaved(tester);

      ble.connectedId = null;
      ble._linkOut.add(BleLinkState.disconnected);
      await settle(tester);

      await tester.enterText(find.byType(TextField), 'Car #4');
      await tester.pump();
      await tester.tap(find.text('Save alias'));
      await settleRoute(tester);

      expect(s.devices.deviceFor('DEV-NEW')?.alias, 'Car #4');
      expect(find.byType(DeviceDetailPage), findsNothing, reason: 'C6');
      expect(find.text('Car #4'), findsOneWidget,
          reason: 'rule 2: a device you just named must be on the tab you are '
              'looking at');
    });
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
            conn.stalledDeviceId = 'DEV-A';
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
      await settleRoute(tester);
      // FB-92: the save now ends on the unit's page. This test is about the
      // ROW the save produced, so come back to where rows are.
      await popBack(tester);

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
    await settleRoute(tester);
    expect(ble.connectedId, 'DEV-A');
    // FB-92 puts the unit's page in front of the list on a successful connect;
    // the delete control this test is about lives on the row.
    await popBack(tester);

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
    await settleRoute(tester);
    // FB-92 C5: 跳過 declines the RECORD, not the device — so it lands on the
    // unit's page just as 儲存 does. This test is about the list behind it.
    await popBack(tester);
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
      await settleRoute(tester);
      // FB-92 C5 again. T55-5's subject is the way OUT that the row offers, so
      // it starts from the row.
      await popBack(tester);
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
