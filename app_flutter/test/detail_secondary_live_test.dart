// design 0106 Phase 1 — the device page of a unit live on a SECONDARY link
// reads that link instead of switching the primary over to it.
//
// What is pinned here:
//   P1-1 opening it makes no connect and shows no offline body: the dashboard
//        draws the secondary link's own sample (2.9–4.1 s double drop on iOS,
//        2026.11.13/009, /011; 1.1–3.5 s on Android, /016 — gone)
//   P1-2 a control pressed there asks first (ruling T1); Cancel sends nothing
//        and connects nothing
//   P1-3 confirming hands the unit over (the existing primary connect), and
//        only then does the action itself run (its own confirmation appears)
//   P1-4 `liveSourceFor` / stall / paused at the controller level
//   P1-5 no scope ⇒ `ensurePrimaryFor` lets the write through untouched (the
//        single-link path)
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/device_live_scope.dart';
import 'package:open_smart_batt/ui/devices/device_detail_page.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The primary link. Records connects; a connect comes up `ready` at once and
/// reports a healthy capacitor's run mode, like the real transport would.
class _FakePrimary extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _teleOut = StreamController<TelemetrySample>.broadcast();
  final List<String> connects = <String>[];
  String? connectedId;

  @override
  String? get connectedDeviceId => connectedId;
  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<TelemetrySample> get telemetry => _teleOut.stream;
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      Stream<BluetoothAdapterState>.value(BluetoothAdapterState.on);
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
  @override
  Stream<List<DiscoveredDevice>> get scanResults =>
      Stream<List<DiscoveredDevice>>.value(const [
        DiscoveredDevice(id: 'A', name: 'A', rssi: -60),
        DiscoveredDevice(id: 'B', name: 'B', rssi: -60),
      ]);

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    connects.add(deviceId);
    connectedId = deviceId;
    _linkOut.add(BleLinkState.connecting);
    _linkOut.add(BleLinkState.ready);
    _teleOut.add(TelemetrySample(
        timestamp: DateTime.now(), pvlt: 13.30, mode: 5, deviceId: deviceId));
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _teleOut.close();
    await super.dispose();
  }
}

class _FakeSecondary extends BleService {
  _FakeSecondary(this.all) {
    all.add(this);
  }
  final List<_FakeSecondary> all;
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _teleOut = StreamController<TelemetrySample>.broadcast();
  String? id;
  bool disconnected = false;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<TelemetrySample> get telemetry => _teleOut.stream;
  @override
  Stream<BlePacketEvent> get packets => const Stream<BlePacketEvent>.empty();
  @override
  Stream<String> get diagnostics => const Stream<String>.empty();

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    id = deviceId;
    _linkOut.add(BleLinkState.ready);
  }

  @override
  Future<void> disconnect() async {
    disconnected = true;
    _linkOut.add(BleLinkState.disconnected);
  }

  void sample(double pvlt, {int mode = 5, String? mac}) => _teleOut.add(
      TelemetrySample(
          timestamp: DateTime.now(),
          pvlt: pvlt,
          mode: mode,
          mac: mac,
          deviceId: id));

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _teleOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late Directory markers;
  late _FakePrimary primary;
  late List<_FakeSecondary> secs;
  late AppServices s;
  late DateTime now;

  _FakeSecondary sec(String id) => secs.lastWhere((b) => b.id == id);

  setUp(() {
    markers = Directory.systemTemp.createTempSync('osb_p1');
    AckMarker.debugDirectoryOverride = markers;
    secs = <_FakeSecondary>[];
    now = DateTime(2026, 11, 15, 12);
  });

  tearDown(() {
    AckMarker.debugDirectoryOverride = null;
    markers.deleteSync(recursive: true);
  });

  /// Two saved capacitors A and B, both live on secondary links, A reading
  /// 13.61 V. Nothing on the primary.
  Future<void> bootServices() async {
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    primary = _FakePrimary();
    s = await AppServices.create(
      appDatabase: db,
      ble: primary,
      multiLinkBuild: true,
      multiLinkBleFactory: () => _FakeSecondary(secs),
      multiLinkClock: () => now,
    );
    for (final d in const [
      SavedDevice(
          id: 'A', alias: 'Cap A', productClass: ProductClass.supercapacitor),
      SavedDevice(
          id: 'B', alias: 'Cap B', productClass: ProductClass.supercapacitor),
    ]) {
      await s.devices.save(d);
    }
    await s.multiLink!.setEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    sec('A').sample(13.61, mac: 'AA:BB:CC:DD:EE:01');
    sec('B').sample(12.20);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  Future<void> disposeServices() async {
    await s.pending.drain();
    await s.dispose();
  }

  Future<void> pumpPage(WidgetTester tester, String id) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
          ChangeNotifierProvider<AlertController>.value(value: s.alerts),
          ChangeNotifierProvider<MultiLinkController>.value(
              value: s.multiLink!),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: DeviceDetailPage(deviceId: id),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(disposeServices);
  }

  testWidgets(
      'P1-1: a secondary-live unit opens on its own link — no connect, no '
      'offline body', (tester) async {
    await tester.runAsync(bootServices);
    await pumpPage(tester, 'A');
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(primary.connects, isEmpty,
        reason: 'opening the page must not hand the unit to the primary');
    expect(sec('A').disconnected, isFalse,
        reason: 'and must not release its secondary link');
    expect(find.text('13.61 V'), findsOneWidget, reason: "A's own link");
    expect(find.text('12.20 V'), findsNothing, reason: "never B's reading");
    expect(find.text('AA:BB:CC:DD:EE:01'), findsOneWidget,
        reason: 'the subtitle is the MAC this secondary link reported');
    expect(find.text('Check Capacitor'), findsOneWidget,
        reason: 'the dashboard (not the offline body) is drawn');
    await unmount(tester);
  });

  testWidgets('P1-2: a control on a secondary asks first; Cancel sends nothing',
      (tester) async {
    await tester.runAsync(bootServices);
    await pumpPage(tester, 'A');
    await tester.tap(find.text('Check Capacitor'));
    await tester.pumpAndSettle();
    expect(find.text('Switch connection first'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(primary.connects, isEmpty);
    expect(sec('A').disconnected, isFalse);
    expect(find.text('Start capacitor self-check'), findsNothing,
        reason: 'the action never started');
    await unmount(tester);
  });

  testWidgets(
      'P1-3: confirming hands the unit to the primary, then the action runs',
      (tester) async {
    await tester.runAsync(bootServices);
    await pumpPage(tester, 'A');
    await tester.tap(find.text('Check Capacitor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch and run'));
    await tester.pump();
    // §2.5: mid-hand-over the page keeps the dashboard with the frozen values
    // and says so — it never flashes the offline body.
    expect(find.text('Switching · making this the main connection'),
        findsOneWidget);
    expect(find.text('13.61 V'), findsOneWidget);
    // The hand-over runs real async (database, stream hops).
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }

    expect(sec('A').disconnected, isTrue,
        reason: 'beforePrimaryConnect released the secondary first');
    expect(primary.connects, ['A'], reason: 'one primary connect, to A');
    expect(s.connection.connectedDeviceId, 'A');
    expect(find.text('Start capacitor self-check'), findsOneWidget,
        reason: 'only after the hand-over does the action open its own '
            'confirmation');
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  test('P1-4: liveSourceFor — values, stall, release', () async {
    await bootServices();
    final ml = s.multiLink!;
    final a = ml.liveSourceFor('A')!;
    expect(a.deviceId, 'A');
    expect(a.isOnline, isTrue);
    expect(a.isPrimary, isFalse);
    expect(a.pvlt, 13.61);
    expect(a.mode, 5);
    expect(a.liveMac, 'AA:BB:CC:DD:EE:01');
    expect(a.packLabel, ProductClass.supercapacitor);
    expect(a.routing, RoutingDecision.pack);
    expect(a.hasTelemetry, isTrue);
    expect(a.telemetryStalled, isFalse);
    expect(ml.liveSourceFor('nope'), isNull);

    // Stall: past the threshold on the controller's clock, the flag flips and
    // listeners hear about it; a new frame clears it.
    var notified = 0;
    void onChange() => notified++;
    a.addListener(onChange);
    now = now.add(ml.stallThreshold + const Duration(seconds: 1));
    ml.checkStalls();
    expect(a.telemetryStalled, isTrue);
    expect(notified, greaterThan(0));
    sec('A').sample(13.50);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(a.telemetryStalled, isFalse);
    expect(a.pvlt, 13.50);
    a.removeListener(onChange);

    // Released ⇒ no source (the page then falls back to its offline body).
    await ml.beforePrimaryConnect('A');
    expect(ml.liveSourceFor('A'), isNull);
    await disposeServices();
  });

  test('P1-4b: a unit saved without a class gets no secondary source', () async {
    await bootServices();
    await s.devices.save(const SavedDevice(id: 'B', alias: 'Cap B'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(s.multiLink!.liveSourceFor('B'), isNull,
        reason: 'nothing to route its dashboard by — that page keeps the '
            'pre-Phase-1 primary connect, where the wire byte decides');
    await disposeServices();
  });

  testWidgets('P1-5: without a scope ensurePrimaryFor lets the write through',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }));
    expect(await ensurePrimaryFor(ctx, action: 'x'), isTrue);

    await tester.pumpWidget(DeviceLiveScope(
      source: null,
      ensurePrimary: (_, _) async => false,
      child: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    expect(await ensurePrimaryFor(ctx, action: 'x'), isTrue,
        reason: 'a null source is the primary path: the hook is not consulted');
  });
}
