// design 0106 Phase 4 — the vehicle UI, against the real AppServices (real
// VehicleController / VehicleRepo on an in-memory database, the real
// MultiLinkController with fake links).
//
// The owner's example throughout: car A = a + b, car B = c + d, the personal
// group = power bank e. Pinned here:
//   ⑦/⑧  switch off, or no car ⇒ NO vehicle UI anywhere (today's page)
//   ①    home title = current vehicle, only its units on the grid
//   ①b   the picker: cars, 個人裝置 last, add (n/5), manage; picking switches
//   ①c   personal home
//   ③    car absent ⇒ offline tag + banner, no switching (Q3)
//   ④    saved list grouped by vehicle, shared unit under each, 未分車
//   ⑤    F3: one owner ⇒ follow + toast; shared ⇒ stay; power bank ⇒ personal
//   ⑥    editor: name, ≤3 units, power banks hidden, rule messages
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
import 'package:open_smart_batt/ui/devices/devices_page.dart';
import 'package:open_smart_batt/ui/home/home_page.dart';
import 'package:open_smart_batt/ui/vehicles/vehicle_editor_page.dart';
import 'package:open_smart_batt/ui/vehicles/vehicle_ui.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePrimary extends BleService {
  _FakePrimary(this.nearby);
  final Set<String> nearby;

  @override
  Stream<List<DiscoveredDevice>> get scanResults =>
      Stream<List<DiscoveredDevice>>.value([
        for (final id in nearby) DiscoveredDevice(id: id, name: id, rssi: -60),
      ]);
  @override
  String? get connectedDeviceId => null;
  @override
  Stream<BleLinkState> get linkState => const Stream<BleLinkState>.empty();
  @override
  Stream<TelemetrySample> get telemetry =>
      const Stream<TelemetrySample>.empty();
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)}) async {}
}

class _FakeSecondary extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<TelemetrySample> get telemetry =>
      const Stream<TelemetrySample>.empty();
  @override
  Stream<BlePacketEvent> get packets => const Stream<BlePacketEvent>.empty();
  @override
  Stream<String> get diagnostics => const Stream<String>.empty();
  @override
  Future<void> connect(String deviceId,
          {Duration? timeout, bool autoConnect = false}) async =>
      _linkOut.add(BleLinkState.ready);
  @override
  Future<void> disconnect() async => _linkOut.add(BleLinkState.disconnected);
  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

const _bat = ProductClass.smartBattery;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late Directory markers;
  setUp(() {
    markers = Directory.systemTemp.createTempSync('osb_vehicle_ui');
    AckMarker.debugDirectoryOverride = markers;
  });
  tearDown(() {
    AckMarker.debugDirectoryOverride = null;
    markers.deleteSync(recursive: true);
  });

  late String carA;
  late String carB;
  var dbSeq = 0;

  /// [cars]: create A{a,b}, B{c,d}, personal{e}. [enable]: the switch.
  Future<AppServices> boot(WidgetTester tester,
      {bool cars = true,
      bool enable = true,
      Set<String> nearby = const {'a', 'b', 'c', 'd', 'e'},
      bool sharedA = false}) async {
    late AppServices s;
    await tester.runAsync(() async {
      // Its own file per test: a failed test never reaches [done], and a
      // shared in-memory database would then hand its cars to the next test.
      final db = await AppDatabase.open(
        path: '${markers.path}/v${++dbSeq}.db',
        factory: databaseFactoryFfi,
      );
      s = await AppServices.create(
        appDatabase: db,
        ble: _FakePrimary(nearby),
        multiLinkBuild: true,
        multiLinkBleFactory: _FakeSecondary.new,
      );
      for (final d in [
        const SavedDevice(id: 'a', alias: 'Bat a', productClass: _bat),
        const SavedDevice(id: 'b', alias: 'Bat b', productClass: _bat),
        const SavedDevice(id: 'c', alias: 'Bat c', productClass: _bat),
        const SavedDevice(id: 'd', alias: 'Bat d', productClass: _bat),
        const SavedDevice(
            id: 'e', alias: 'Bank e', productClass: ProductClass.powerBank),
      ]) {
        await s.devices.save(d);
      }
      if (cars) {
        carA = (await s.vehicles.createCar('Car A')).id;
        await s.vehicles.setDevices(carA, ['a', 'b']);
        carB = (await s.vehicles.createCar('Car B')).id;
        await s.vehicles
            .setDevices(carB, sharedA ? ['a', 'c', 'd'] : ['c', 'd']);
        await s.vehicles.setDevices(VehicleRepo.personalId, ['e']);
      }
      if (enable) await s.multiLink!.setEnabled(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    return s;
  }

  Future<void> pump(WidgetTester tester, AppServices s, Widget home,
      {Size size = const Size(420, 1600), double textScale = 1.0}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<BleService>.value(value: s.ble),
          Provider<AppServices>.value(value: s),
          ChangeNotifierProvider<SettingsController>.value(value: s.settings),
          ChangeNotifierProvider<DeviceController>.value(value: s.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: s.connection),
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
          ChangeNotifierProvider<AlertController>.value(value: s.alerts),
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
          ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
          ChangeNotifierProvider<VehicleController>.value(value: s.vehicles),
          ChangeNotifierProvider<MultiLinkController>.value(
              value: s.multiLink!),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(body: home),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> done(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await s.pending.drain();
      await s.dispose();
    });
  }

  final title = find.byKey(const ValueKey('vehicle-title'));

  group('⑦ / ⑧ inert', () {
    testWidgets('switch OFF with cars: no vehicle title, every unit on the grid',
        (tester) async {
      final s = await boot(tester, enable: false);
      await pump(tester, s, const HomePage());
      expect(title, findsNothing);
      for (final n in ['Bat a', 'Bat c']) {
        expect(find.text(n), findsWidgets, reason: n);
      }
      await done(tester, s);
    });

    testWidgets('switch ON but no car: exactly today (no title)',
        (tester) async {
      final s = await boot(tester, cars: false);
      await pump(tester, s, const HomePage());
      expect(title, findsNothing);
      await done(tester, s);
    });

    testWidgets('switch OFF: the saved list is not grouped', (tester) async {
      final s = await boot(tester, enable: false);
      await pump(tester, s, const DevicesPage(active: true));
      await settle(tester);
      expect(find.byKey(const ValueKey('saved-group-none')), findsNothing);
      expect(find.text('Car A'), findsNothing);
      await done(tester, s);
    });
  });

  testWidgets('① home = current vehicle: title and only its units',
      (tester) async {
    final s = await boot(tester);
    await pump(tester, s, const HomePage());
    expect(title, findsOneWidget);
    expect(find.descendant(of: title, matching: find.text('Car A')),
        findsOneWidget);
    expect(find.text('Bat a'), findsWidgets);
    expect(find.text('Bat b'), findsWidgets);
    expect(find.text('Bat c'), findsNothing);
    expect(find.text('Bank e'), findsNothing);
    await done(tester, s);
  });

  testWidgets('①b picker lists cars, Personal last, add n/5, manage; picking '
      'switches (source=home)', (tester) async {
    final s = await boot(tester);
    await pump(tester, s, const HomePage());
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('vehicle-option-$carA')), findsOneWidget);
    expect(find.byKey(ValueKey('vehicle-option-$carB')), findsOneWidget);
    expect(find.byKey(const ValueKey('vehicle-option-personal')),
        findsOneWidget);
    expect(find.text('Add vehicle (2/5)'), findsOneWidget);
    expect(find.text('Manage vehicles…'), findsOneWidget);
    // Personal is below every car.
    expect(
        tester.getTopLeft(find.byKey(const ValueKey('vehicle-option-personal'))).dy,
        greaterThan(
            tester.getTopLeft(find.byKey(ValueKey('vehicle-option-$carB'))).dy));
    await tester.tap(find.byKey(ValueKey('vehicle-option-$carB')));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(s.vehicles.current?.id, carB);
    expect(find.descendant(of: title, matching: find.text('Car B')),
        findsOneWidget);
    expect(find.text('Bat c'), findsWidgets);
    expect(find.text('Bat a'), findsNothing);
    final notes = await tester.runAsync(() async {
      await s.pending.drain();
      return [for (final e in await s.logRepo.queryLog()) e.note ?? ''];
    });
    expect(notes, contains('vehicle: switch car1→car2 source=home'));
    await done(tester, s);
  });

  testWidgets('①c personal home shows the power bank under 「Personal devices」',
      (tester) async {
    final s = await boot(tester);
    await tester.runAsync(() => s.vehicles.select(VehicleRepo.personalId));
    await pump(tester, s, const HomePage());
    await settle(tester);
    expect(find.descendant(of: title, matching: find.text('Personal devices')),
        findsOneWidget);
    expect(find.text('Bank e'), findsWidgets);
    expect(find.text('Bat a'), findsNothing);
    await done(tester, s);
  });

  testWidgets('③ car absent: offline tag + banner, and no switching (Q3)',
      (tester) async {
    final s = await boot(tester, nearby: const {'c', 'd'});
    await pump(tester, s, const HomePage());
    await settle(tester);
    expect(s.vehicles.current?.id, carA);
    expect(find.descendant(of: title, matching: find.text('offline')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('vehicle-offline-banner')),
        findsOneWidget);
    expect(find.textContaining("None of Car A's devices are nearby"),
        findsOneWidget);
    await done(tester, s);
  });

  testWidgets('④ saved list grouped: cars, Personal, No vehicle; shared unit '
      'under each car', (tester) async {
    final s = await boot(tester, sharedA: true);
    await tester.runAsync(() async {
      await s.devices.save(const SavedDevice(
          id: 'f', alias: 'Bat f', productClass: _bat));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await pump(tester, s, const DevicesPage(active: true));
    await settle(tester);
    expect(find.byKey(ValueKey('saved-group-$carA')), findsOneWidget);
    expect(find.byKey(ValueKey('saved-group-$carB')), findsOneWidget);
    expect(find.byKey(const ValueKey('saved-group-personal')), findsOneWidget);
    expect(find.byKey(const ValueKey('saved-group-none')), findsOneWidget);
    expect(find.text('Bat a'), findsNWidgets(2), reason: 'in A and in B');
    expect(find.text('Bat f'), findsOneWidget, reason: 'No vehicle');
    double y(Finder f) => tester.getTopLeft(f).dy;
    expect(y(find.byKey(const ValueKey('saved-group-none'))),
        greaterThan(y(find.byKey(const ValueKey('saved-group-personal')))));
    await done(tester, s);
  });

  group('discovery hint (owner 2026-11-15: tell existing users)', () {
    final hint = find.byKey(const ValueKey('vehicle-hint'));
    final go = find.byKey(const ValueKey('vehicle-hint-go'));
    final close = find.byKey(const ValueKey('vehicle-hint-close'));

    testWidgets('switch OFF, no car, 4 units: shown; action opens Settings '
        'and never shows again', (tester) async {
      final s = await boot(tester, cars: false, enable: false);
      var opened = 0;
      await pump(tester, s, DevicesPage(active: true, onOpenSettings: () {
        opened++;
      }));
      await settle(tester);
      expect(hint, findsOneWidget);
      expect(find.text('Open Settings →'), findsOneWidget);
      await tester.tap(go);
      await settle(tester);
      expect(opened, 1);
      expect(hint, findsNothing);
      expect(s.multiLink!.enabled, isFalse,
          reason: 'the hint never turns the experiment on by itself');
      expect(await tester.runAsync(vehicleHintMarker.acknowledged), isTrue);
      await pump(tester, s, const SizedBox());
      await pump(tester, s, const DevicesPage(active: true));
      await settle(tester);
      expect(hint, findsNothing, reason: 'once only');
      await done(tester, s);
    });

    testWidgets('close button dismisses for good', (tester) async {
      final s = await boot(tester, cars: false, enable: false);
      await pump(tester, s, const DevicesPage(active: true));
      await settle(tester);
      expect(go, findsNothing, reason: 'no Settings entry handed down');
      await tester.tap(close);
      await settle(tester);
      expect(hint, findsNothing);
      expect(await tester.runAsync(vehicleHintMarker.acknowledged), isTrue);
      await done(tester, s);
    });

    testWidgets('switch ON, no car: action opens the vehicle list',
        (tester) async {
      final s = await boot(tester, cars: false);
      await pump(tester, s, const DevicesPage(active: true));
      await settle(tester);
      expect(find.text('Set up vehicles →'), findsOneWidget);
      await tester.tap(go);
      await settle(tester);
      expect(find.byKey(const ValueKey('vehicles-add')), findsOneWidget);
      await done(tester, s);
    });

    testWidgets('not shown once a car exists', (tester) async {
      final s = await boot(tester, enable: false);
      await pump(tester, s, const DevicesPage(active: true));
      await settle(tester);
      expect(hint, findsNothing);
      await done(tester, s);
    });

    testWidgets('not shown with fewer than two car-able units (power bank '
        'does not count)', (tester) async {
      final s = await boot(tester, cars: false, enable: false);
      await tester.runAsync(() async {
        for (final id in ['b', 'c', 'd']) {
          await s.devices.remove(id);
        }
      });
      await pump(tester, s, const DevicesPage(active: true));
      await settle(tester);
      expect(find.text('Bank e'), findsOneWidget);
      expect(hint, findsNothing);
      await done(tester, s);
    });
  });

  group('⑤ F3', () {
    Future<void> open(WidgetTester tester, String id, String alias) async {
      final ctx = tester.element(find.byType(HomePage));
      followDeviceToVehicle(ctx, id, alias: alias);
      await tester.pump();
      await settle(tester);
    }

    testWidgets('a unit with ONE owner switches home there, with a toast',
        (tester) async {
      final s = await boot(tester);
      await pump(tester, s, const HomePage());
      await open(tester, 'c', 'Bat c');
      expect(s.vehicles.current?.id, carB);
      expect(find.text('Home switched to Car B (Bat c belongs to it)'),
          findsOneWidget);
      await done(tester, s);
    });

    testWidgets('a unit shared by two cars changes nothing (Q2)',
        (tester) async {
      final s = await boot(tester, sharedA: true);
      await tester.runAsync(() => s.vehicles.select(carB));
      await pump(tester, s, const HomePage());
      await open(tester, 'a', 'Bat a');
      expect(s.vehicles.current?.id, carB);
      expect(find.textContaining('Home switched'), findsNothing);
      await done(tester, s);
    });

    testWidgets('a power bank goes to Personal devices', (tester) async {
      final s = await boot(tester);
      await pump(tester, s, const HomePage());
      await open(tester, 'e', 'Bank e');
      expect(s.vehicles.current?.id, VehicleRepo.personalId);
      await done(tester, s);
    });

    testWidgets('inert while the switch is off', (tester) async {
      final s = await boot(tester, enable: false);
      await pump(tester, s, const HomePage());
      await open(tester, 'c', 'Bat c');
      expect(s.vehicles.current?.id, carA);
      expect(find.textContaining('Home switched'), findsNothing);
      await done(tester, s);
    });
  });

  group('⑥ editor', () {
    testWidgets('new car: power banks hidden, a 4th unit cannot be ticked, '
        'saving creates it', (tester) async {
      final s = await boot(tester);
      await pump(tester, s, const VehicleEditorPage(vehicleId: null));
      await settle(tester);
      expect(find.byKey(const ValueKey('vehicle-device-e')), findsNothing,
          reason: 'R6');
      await tester.enterText(
          find.byKey(const ValueKey('vehicle-name')), 'Car C');
      for (final id in ['a', 'b', 'c']) {
        await tester.tap(find.byKey(ValueKey('vehicle-device-$id')));
        await tester.pump();
      }
      final fourth = tester.widget<VehicleCheckRow>(
          find.byKey(const ValueKey('vehicle-device-d')));
      expect(fourth.onChanged, isNull, reason: 'Q6: at most 3');
      expect(find.text('Devices in this vehicle (3/3)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('vehicle-editor-done')));
      await tester.pump();
      await settle(tester);
      final c = s.vehicles.cars.firstWhere((v) => v.name == 'Car C');
      expect(c.deviceIds, ['a', 'b', 'c']);
      await done(tester, s);
    });

    testWidgets('the personal editor offers power banks only, no name, no '
        'delete', (tester) async {
      final s = await boot(tester);
      await pump(
          tester, s, const VehicleEditorPage(vehicleId: VehicleRepo.personalId));
      await settle(tester);
      expect(find.byKey(const ValueKey('vehicle-device-e')), findsOneWidget);
      expect(find.byKey(const ValueKey('vehicle-device-a')), findsNothing);
      expect(find.byKey(const ValueKey('vehicle-name')), findsNothing);
      expect(find.byKey(const ValueKey('vehicle-delete')), findsNothing);
      await done(tester, s);
    });

    testWidgets('the first car puts saved power banks into Personal devices',
        (tester) async {
      final s = await boot(tester, cars: false);
      await tester.runAsync(
          () => createCarWithDefaults(s.vehicles, s.devices, 'Only'));
      expect(s.vehicles.personal?.deviceIds, ['e']);
      await tester.pumpWidget(const SizedBox());
      await done(tester, s);
    });

    testWidgets('every rule code has its own sentence', (tester) async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(builder: (context) {
          final l10n = AppLocalizations.of(context);
          final codes = [
            'vehicle_limit',
            'vehicle_device_limit',
            'power_bank_in_car',
            'personal_only_power_banks',
            'unknown_class',
            'personal_fixed',
            'not_found',
          ];
          final texts = {for (final c in codes) vehicleRuleMessage(l10n, c)};
          expect(texts.length, codes.length);
          return const SizedBox();
        }),
      ));
    });
  });

  group('layout', () {
    for (final w in [320.0, 390.0]) {
      for (final ts in [1.0, 1.3, 2.0]) {
        testWidgets('title with a long name: no overflow at ${w}pt ×$ts',
            (tester) async {
          final s = await boot(tester, nearby: const {});
          await tester.runAsync(() =>
              s.vehicles.rename(carA, 'A very long vehicle name for testing'));
          await pump(tester, s, const HomePage(),
              size: Size(w, 1600), textScale: ts);
          await settle(tester);
          expect(tester.takeException(), isNull);
          expect(title, findsOneWidget);
          await done(tester, s);
        });
      }
    }

    testWidgets('landscape: title and picker lay out', (tester) async {
      final s = await boot(tester);
      await pump(tester, s, const HomePage(), size: const Size(844, 390));
      await settle(tester);
      expect(title, findsOneWidget);
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Manage vehicles…'), findsOneWidget);
      await done(tester, s);
    });
  });
}
