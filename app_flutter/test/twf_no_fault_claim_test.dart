// TWF (selector 0x20): we record the byte, we no longer interpret it.
//
// The app used to read value `0x20` as "the device is reporting a fault" and
// raise a banner. Field captures on 2026-07-29 showed that value appears ONLY
// on power banks, and only while charging — 449 occurrences on power banks,
// 0 across 13,535 battery/capacitor samples. Users were told their healthy
// power bank was faulty every time they plugged in a charger.
//
// The rule also never caught what it claimed to: two independently confirmed
// faults (a 2026-07-19 capacitor the vendor app flagged, and a 2026-07-28
// battery with a 1.75 V cell imbalance) both reported something OTHER than
// `0x20`.
//
// So this file replaces `fault_flag_test.dart`, and it pins the opposite
// property: what the app must NOT claim, and what it must still record.
// Assertions are deliberately negative — the deliverable is a thing that no
// longer happens.
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

  group('the dashboard makes no fault claim', () {
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

    /// Every wording the removed banner could produce, in both locales.
    void expectNoFaultClaim() {
      for (final s in ['fault', 'Fault', 'Suspected', 'suspected',
                       '疑似', '異常']) {
        expect(find.textContaining(s), findsNothing, reason: 'must not say "$s"');
      }
      // And never the raw byte: the readers are vehicle owners.
      expect(find.textContaining('0x20'), findsNothing);
      expect(find.textContaining('0x'), findsNothing);
    }

    Future<void> connect(WidgetTester tester, _StubBle ble,
        TelemetrySample sample) async {
      await tester.runAsync(() async {
        ble.emitLink(BleLinkState.ready);
        ble.emitTelemetry(sample);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
    }

    // T1 — the reported symptom itself (005 / 007 / 009).
    testWidgets('a power bank CHARGING (twf 0x20) raises nothing',
        (tester) async {
      final (s, ble) = await boot(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await s.dispose();
      });
      await pump(tester, s);
      await connect(
          tester,
          ble,
          TelemetrySample(
            timestamp: DateTime.utc(2026, 7, 29),
            deviceType: 0x22,
            pvlt: 4.09,
            svlt: 9.06,
            temperatureC: 31,
            twfRaw: 0x20,
          ));
      expectNoFaultClaim();
    });

    // T2 — the case class-gating could never have fixed: two of the three
    // field screenshots showed the device still UNCLASSIFIED, because 0x10
    // trails the first burst and power banks poll every ~8 s.
    testWidgets('same byte while still UNCLASSIFIED raises nothing',
        (tester) async {
      final (s, ble) = await boot(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await s.dispose();
      });
      await pump(tester, s);
      await connect(
          tester,
          ble,
          TelemetrySample(
            timestamp: DateTime.utc(2026, 7, 29),
            // deviceType deliberately absent.
            pvlt: 4.23,
            twfRaw: 0x20,
          ));
      expectNoFaultClaim();
    });

    // T4 — the other two classes are unaffected. Two separate tests, NOT one
    // loop: each needs its own AppServices/DB, and booting a second one inside
    // the same testWidgets deadlocks until the 10-minute timeout. Learned the
    // slow way; left as a comment so the next person does not retry it.
    testWidgets('a battery (twf 0x01) raises nothing', (tester) async {
      final (s, ble) = await boot(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await s.dispose();
      });
      await pump(tester, s);
      await connect(
          tester,
          ble,
          TelemetrySample(
            timestamp: DateTime.utc(2026, 7, 29),
            deviceType: 0x02,
            pvlt: 13.3,
            twfRaw: 0x01,
          ));
      expectNoFaultClaim();
    });

    testWidgets('a capacitor (twf 0x00) raises nothing', (tester) async {
      final (s, ble) = await boot(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await s.dispose();
      });
      await pump(tester, s);
      await connect(
          tester,
          ble,
          TelemetrySample(
            timestamp: DateTime.utc(2026, 7, 29),
            deviceType: 0x17,
            pvlt: 13.3,
            twfRaw: 0x00,
          ));
      expectNoFaultClaim();
    });
  });

  // T3 — THE GUARD. "Stop interpreting the byte" and "stop recording the byte"
  // are a few lines apart in the diff, and the second one would cost us the
  // material that made this fix findable: it was the `twf` column in the
  // 005/007/009 CSVs that exposed the misreading.
  group('the byte is still recorded', () {
    test('twfRaw survives into toMap under the stable csv key', () {
      final s = TelemetrySample(timestamp: DateTime.utc(2026), twfRaw: 0x20);
      expect(s.twfRaw, 0x20);
      expect(s.toMap()['twf'], 0x20);
    });

    test('the csv column set still carries twf, at an unmoved index', () {
      // Recipients build spreadsheets on this order, so new columns are only
      // ever appended and existing ones never move.
      expect(HistoryRepo.csvColumns.contains('twf'), isTrue);
      expect(HistoryRepo.csvColumns.indexOf('twf'),
          HistoryRepo.csvColumns.indexOf('twf'));
      expect(HistoryRepo.csvColumns.indexOf('mode') + 1,
          HistoryRepo.csvColumns.indexOf('twf'),
          reason: 'twf must stay immediately after mode');
    });

    test('a value we cannot explain is preserved verbatim, not clamped', () {
      for (final v in [0x00, 0x01, 0x20, 0x41, 0xFF]) {
        expect(TelemetrySample(timestamp: DateTime.utc(2026), twfRaw: v)
            .toMap()['twf'], v);
      }
    });
  });
}
