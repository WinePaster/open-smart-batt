// Regression tests for the per-class mode code space (selector 0x23).
//
// THE BUG THIS PINS DOWN. The run-mode badge used to test the reported mode
// word with a BITMASK (`mode & ReportedStatus.cutOffActive != 0`). A healthy
// super-capacitor reports `5`, and `5 & 4 != 0`, so every healthy capacitor was
// rendered as "Cut-off" in red — a fault state, on a unit with no cut-off
// feature at all.
//
// Evidence for the expectations below is our own wire capture, not the original
// app: a super-capacitor (device-type 0x17) answered `0x23` = `0x05` on
// 1802/1802 frames with no other value, while two smart batteries
// (device-type 0x02) answered `0x00` on 531/531 and 112/112 frames.
// PROTOCOL.md §6.2 independently records the reported-status space as 0/2/4 and
// the reference UI's own logic as EQUALITY (`currentMode != 2` / `!= 4`).
//
// CLEAN-ROOM: expectations derive only from docs/PROTOCOL.md and our captures.
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
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls_shared.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService (mirrors dashboard_split_test.dart) so this runs headless.
class _FakeBleService extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  void emit(TelemetrySample s) => _telemetryOut.add(s);

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(sqfliteFfiInit);

  // =========================================================================
  // Pure decode — the code spaces must not overlap
  // =========================================================================

  group('packRunModeOf — equality, never a bitmask', () {
    test('the three pack codes decode', () {
      expect(packRunModeOf(ReportedStatus.normal), PackRunMode.normal);
      expect(packRunModeOf(ReportedStatus.antiTheftActive),
          PackRunMode.antiTheft);
      expect(packRunModeOf(ReportedStatus.cutOffActive), PackRunMode.cutOff);
    });

    test('a healthy capacitor byte (5) is NOT a pack mode', () {
      // The regression: 5 & 4 != 0, so the old mask called this "cut-off".
      expect(packRunModeOf(CapacitorStatus.healthy), isNull);
      expect(isCutOffMode(CapacitorStatus.healthy), isFalse);
    });

    test('every other byte the mask would have misread stays null', () {
      // Each of these has bit 2 (0x04) or bit 1 (0x02) set, so the old mask
      // claimed cut-off / anti-theft for all of them.
      for (final b in [5, 6, 7, 12, 13, 14, 20, 0xFF]) {
        expect(packRunModeOf(b), isNull, reason: 'byte $b must not decode');
        expect(isCutOffMode(b), isFalse, reason: 'byte $b must not be cut-off');
      }
    });

    test('null (nothing received yet) decodes to null, not normal', () {
      expect(packRunModeOf(null), isNull);
      expect(isCutOffMode(null), isFalse);
    });
  });

  group('capacitorHealthOf — its own code space', () {
    test('the observed healthy value decodes', () {
      expect(capacitorHealthOf(CapacitorStatus.healthy),
          CapacitorHealth.healthy);
    });

    test('any other byte is UNKNOWN, never guessed at', () {
      // We hold no captured fault sample, so nothing else may be named.
      for (final b in [0, 2, 4, 6, 7, 10, 0xFF]) {
        expect(capacitorHealthOf(b), CapacitorHealth.unknown,
            reason: 'byte $b must not be named');
      }
    });

    test('null stays null so the badge can render `--`', () {
      expect(capacitorHealthOf(null), isNull);
    });
  });

  test('the two code spaces do not share a value', () {
    // If they ever overlapped, one byte would decode in both spaces and the
    // per-class routing would stop being safe.
    const packCodes = {
      ReportedStatus.normal,
      ReportedStatus.antiTheftActive,
      ReportedStatus.cutOffActive,
    };
    expect(packCodes.contains(CapacitorStatus.healthy), isFalse);
  });

  // =========================================================================
  // Widget — a capacitor must never render cut-off wording
  // =========================================================================

  late _FakeBleService fakeBle;

  Future<AppServices> makeServices(WidgetTester tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      fakeBle = _FakeBleService();
      services = await AppServices.create(appDatabase: appDb, ble: fakeBle);
    });
    return services;
  }

  Future<void> pumpUnder(
      WidgetTester tester, AppServices s, Widget child) async {
    await tester.pumpWidget(
      MultiProvider(
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
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> emitMode(WidgetTester tester, int mode) async {
    await tester.runAsync(() async {
      fakeBle.emit(TelemetrySample(timestamp: DateTime.now(), mode: mode));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  group('CapacitorControls (FB-14)', () {
    testWidgets('mode 5 renders NO cut-off wording anywhere', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());
      await emitMode(tester, CapacitorStatus.healthy);

      // The exact symptom users reported: a red "Cut-off" on a healthy unit.
      expect(find.textContaining('Cut-off'), findsNothing);
      // And the run-mode badge itself is gone — a capacitor has no run mode.
      expect(find.text('Run Mode'), findsNothing);
      expect(find.text('Anti-theft'), findsNothing);
    });

    testWidgets('mode 5 reports the device-said status as Normal',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());
      await emitMode(tester, CapacitorStatus.healthy);

      expect(find.text('Capacitor Status'), findsOneWidget);
      expect(find.text('Normal'), findsOneWidget);
    });

    testWidgets('an unrecognised byte surfaces the raw value, not a guess',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());
      await emitMode(tester, 7);

      // Reported verbatim so a user can pass it on — we have no fault sample.
      expect(find.text('Unknown 0x07'), findsOneWidget);
      expect(find.textContaining('Cut-off'), findsNothing);
    });
  });

  group('BatteryControls keeps working', () {
    testWidgets('mode 4 still reports cut-off', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());
      await emitMode(tester, ReportedStatus.cutOffActive);

      expect(find.text('Cut-off'), findsWidgets);
      expect(find.text('On'), findsOneWidget);
    });

    testWidgets('mode 0 reports normal', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());
      await emitMode(tester, ReportedStatus.normal);

      expect(find.text('Normal'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('nothing received yet renders `--`, not a state',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());

      // Two badges, both undecided: run mode and cut-off.
      expect(find.text('--'), findsNWidgets(2));
    });
  });
}
