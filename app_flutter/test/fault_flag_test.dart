// Device-reported fault flag (TWF selector 0x20, bit 0x20).
//
// The bit→meaning mapping is UNVERIFIED (PROTOCOL.md §10). Basis for picking
// this bit: across the field captures TWF only ever held 0x00 / 0x01 / 0x20,
// and 0x20 appeared exclusively while PVLT sat at ~4 V.
//
// Known counter-example, asserted below so nobody mistakes this for full
// coverage: the 2026-07-19 capacitor that the VENDOR app flagged as faulty
// reported TWF 0x00 the whole session — this bit does not catch that failure.
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
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _StubBle extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;
  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;

  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);
  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('TelemetrySample.hasDeviceFaultFlag', () {
    TelemetrySample withTwf(int? twf) =>
        TelemetrySample(timestamp: DateTime.utc(2026), twfRaw: twf);

    test('set only when bit 0x20 is present', () {
      expect(withTwf(0x20).hasDeviceFaultFlag, isTrue);
      expect(withTwf(0x21).hasDeviceFaultFlag, isTrue, reason: 'other bits may ride along');
      expect(withTwf(0x00).hasDeviceFaultFlag, isFalse);
      expect(withTwf(0x01).hasDeviceFaultFlag, isFalse,
          reason: '0x01 was seen on healthy units too');
      expect(withTwf(null).hasDeviceFaultFlag, isFalse,
          reason: 'no frame yet is not a fault');
    });

    test('does NOT catch the 2026-07-19 capacitor the vendor app flagged', () {
      // That unit reported TWF 0x00 for all 278 frames while the vendor app
      // showed its red indicator. Documented here so the coverage gap is
      // explicit rather than discovered in the field.
      expect(withTwf(0x00).hasDeviceFaultFlag, isFalse);
    });
  });

  group('fault banner', () {
    Future<(AppServices, _StubBle)> boot(WidgetTester tester) async {
      late AppServices services;
      late _StubBle ble;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        ble = _StubBle();
        services = await AppServices.create(appDatabase: db, ble: ble);
      });
      return (services, ble);
    }

    Future<void> pump(WidgetTester tester, AppServices s) async {
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: s.settings),
          ChangeNotifierProvider<DeviceController>.value(value: s.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: s.connection),
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const Scaffold(body: DashboardPage()),
        ),
      ));
      await tester.pump();
    }

    testWidgets('appears with the raw code when the device sets the bit',
        (tester) async {
      final (s, ble) = await boot(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        // Let the controllers' in-flight log writes land before the DB closes;
        // `link: ready` is written asynchronously.
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await s.dispose();
      });

      await pump(tester, s);
      await tester.runAsync(() async {
        ble.emitLink(BleLinkState.ready);
        ble.emitTelemetry(
            TelemetrySample(timestamp: DateTime.now(), pvlt: 4.0, twfRaw: 0x20));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(find.textContaining('Suspected fault'), findsOneWidget);
      // The raw byte must be visible: the semantics are unverified, so a field
      // report of the actual value is how we pin them down.
      expect(find.textContaining('0x20'), findsOneWidget);
    });

    testWidgets('stays hidden for a healthy status byte', (tester) async {
      final (s, ble) = await boot(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        // Let the controllers' in-flight log writes land before the DB closes;
        // `link: ready` is written asynchronously.
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await s.dispose();
      });

      await pump(tester, s);
      await tester.runAsync(() async {
        ble.emitLink(BleLinkState.ready);
        ble.emitTelemetry(TelemetrySample(
            timestamp: DateTime.now(), pvlt: 12.5, twfRaw: 0x00));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(find.textContaining('Suspected fault'), findsNothing);
    });
  });
}
