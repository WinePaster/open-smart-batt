// T-new-3 — a number on the home page is either LIVE or DATED. Never neither.
//
// A saved device stores two numeric facts and only two: `lastValue` and
// `lastSeen`. Everything else a card could show — current, temperature, per-cell
// voltage — simply does not exist while the unit is not connected, because the
// advertisement carries none of it.
//
// So the home page has exactly one way to be dishonest, and it is cheap to
// build by accident: print `lastValue` large, leave the age off, and the page
// reads as live. FB-43 is that mistake's ancestor — a power bank's single-cell
// 3.79 V rendered on a pack's 12 V dial — and design 0046 §4.7 explicitly
// exempts timestamps from the "say it with navigation, not words" discipline
// for this reason: a timestamp is not an explanation, it is provenance.
//
// CLEAN-ROOM: expectations derive from this project's own source and field
// reports.
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
import 'package:open_smart_batt/ui/home/home_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  String? connectedId;

  @override
  String? get connectedDeviceId => connectedId;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late _FakeBle ble;

  Future<AppServices> boot(WidgetTester tester,
      {required List<SavedDevice> devices}) async {
    late final AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _FakeBle();
      s = await AppServices.create(appDatabase: db, ble: ble);
      for (final d in devices) {
        await s.devices.save(d);
      }
    });
    return s;
  }

  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => s.pending.drain());
    await s.dispose();
  }

  Future<void> pumpHome(WidgetTester tester, AppServices s) async {
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
          ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const Scaffold(body: HomePage()),
        ),
      ),
    );
    await tester.pump();
  }

  group('T-new-3: an offline device card never shows a number without its age',
      () {
    testWidgets('the value and the age appear together', (tester) async {
      final s = await boot(tester, devices: [
        SavedDevice(
          id: 'A',
          alias: 'Cap #1',
          lastValue: 12.64,
          lastSeen: DateTime.now().subtract(const Duration(minutes: 3)),
        ),
        SavedDevice(
          id: 'B',
          alias: 'Cap #2',
          lastValue: 11.10,
          lastSeen: DateTime.now().subtract(const Duration(days: 2)),
        ),
      ]);
      addTearDown(() => teardown(tester, s));
      await pumpHome(tester, s);

      // Two devices ⇒ one card each (design 0046 §4.6).
      expect(find.text('Cap #1'), findsOneWidget);
      expect(find.text('12.64'), findsOneWidget);
      expect(find.text('3 minutes ago'), findsOneWidget);
      expect(find.text('11.10'), findsOneWidget);
      expect(find.text('2 days ago'), findsOneWidget);

      // Nothing on this page claims to be live.
      expect(find.text('LIVE'), findsNothing,
          reason: 'the LIVE marker is the only thing a connected card carries; '
              'an offline one must not borrow it');
    });

    testWidgets('with no lastSeen the number is withheld too', (tester) async {
      // The stricter of the two honest options: an undated number is the exact
      // shape of the mistake this test exists for, so it is not rendered at all.
      final s = await boot(tester, devices: [
        const SavedDevice(id: 'A', alias: 'Cap #1', lastValue: 12.64),
        const SavedDevice(id: 'B', alias: 'Cap #2', lastValue: 11.10),
      ]);
      addTearDown(() => teardown(tester, s));
      await pumpHome(tester, s);

      expect(find.text('Cap #1'), findsOneWidget);
      expect(find.text('12.64'), findsNothing,
          reason: 'there is no age to put beside it, so there is no honest way '
              'to show it');
      expect(find.text('Never connected'), findsWidgets);
    });

    testWidgets('an offline module tile waits, it does not borrow lastValue',
        (tester) async {
      // A single saved device generates [gauge, readouts] MODULE tiles
      // (design 0046 §4.6). Offline, those have nothing to draw: `SavedDevice`
      // stores no temperature and no current, and filling the gauge from
      // `lastValue` without an age would be the same defect one card along.
      final s = await boot(tester, devices: [
        SavedDevice(
          id: 'A',
          alias: 'Cap #1',
          lastValue: 12.64,
          lastSeen: DateTime.now().subtract(const Duration(minutes: 3)),
        ),
      ]);
      addTearDown(() => teardown(tester, s));
      await pumpHome(tester, s);

      expect(find.text('--'), findsWidgets);
      expect(find.text('12.64'), findsNothing,
          reason: 'a module tile has no timestamp to carry, so it shows the '
              'waiting state instead of a stored number');
      expect(find.text('LIVE'), findsNothing);
    });

    testWidgets('a card for a unit that is NOT the connected one still waits',
        (tester) async {
      // FB-41's attribution mistake, moved into the UI: with A connected, B's
      // card must not draw A's telemetry.
      final s = await boot(tester, devices: [
        SavedDevice(
          id: 'A',
          alias: 'Cap #1',
          lastValue: 12.64,
          lastSeen: DateTime.now(),
        ),
        SavedDevice(
          id: 'B',
          alias: 'Cap #2',
          lastValue: 11.10,
          lastSeen: DateTime.now().subtract(const Duration(hours: 2)),
        ),
      ]);
      addTearDown(() => teardown(tester, s));
      ble.connectedId = 'A';
      await pumpHome(tester, s);
      await tester.runAsync(() async {
        ble.emitLink(BleLinkState.ready);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();

      // A is live, B is not — and B still says when it was last seen.
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('2 hours ago'), findsOneWidget);
      expect(find.text('11.10'), findsOneWidget,
          reason: 'B keeps its dated last reading; what it must not do is take '
              "A's live one");
    });
  });

  group('the zero-device home page still has something on it (T-new-2)', () {
    testWidgets('an empty install shows the add-device card', (tester) async {
      final s = await boot(tester, devices: const []);
      addTearDown(() => teardown(tester, s));
      await pumpHome(tester, s);

      expect(find.text('Add your first device'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
