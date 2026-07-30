// Design 0020 — manual cut-off (FB-35) and cut-off/release state gating (FB-34).
//
// THE REPORT THIS PINS DOWN. A field capture (feedback_log/2026.07.30/006,
// 23 hours, 63,375 XOR-clean frames) carries five mode-0x06 writes and a `0x23`
// byte that reads `0x00` on 2131/2131 frames — the battery was never cut off, so
// "release" could not possibly do anything. The app nevertheless offered a large
// permanently-enabled 解除斷電 button and answered every press with "sent". The
// owner wrote: 「剛有測試斷電功能，無作動」.
//
// Two rules come out of that, and both are asserted here:
//   1. The gate is ASYMMETRIC (design 0020 §3.1). Cut-off is offered only when
//      the device positively reports normal; release is refused only then. An
//      unreadable state leaves release available — locking an owner out of a
//      vehicle is worse than one wasted write.
//   2. A mode write is reported as SENT, never as done. PROTOCOL.md §6.2: the
//      wire carries no acknowledgement of any kind.
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

/// Inert BleService with a drivable link state, so a body can be pumped online.
class _FakeBleService extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  void emit(TelemetrySample s) => _telemetryOut.add(s);
  void emitLink(BleLinkState s) => _linkOut.add(s);

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
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(sqfliteFfiInit);

  // =========================================================================
  // Pure gating — the truth table from design 0020 §3.1
  // =========================================================================

  // Kept although the community build renders no cut-off button: the gate and
  // its action still exist in status_controls_shared.dart for the distributor
  // build, and an untested destructive path is exactly what should not be
  // waiting there when someone wires it up (design 0020 §9).
  group('cutOffActionEnabled — only on a provably normal pack', () {
    test('normal is the ONLY state that enables it', () {
      expect(cutOffActionEnabled(ReportedStatus.normal), isTrue);
      expect(cutOffActionEnabled(ReportedStatus.cutOffActive), isFalse);
      expect(cutOffActionEnabled(ReportedStatus.antiTheftActive), isFalse);
    });

    test('an unreadable state refuses it — we do not lock what we cannot read',
        () {
      expect(cutOffActionEnabled(null), isFalse);
      // A capacitor answers 0x23 in a different code space entirely.
      expect(cutOffActionEnabled(CapacitorStatus.healthy), isFalse);
      for (final b in [5, 6, 7, 12, 13, 0xFF]) {
        expect(cutOffActionEnabled(b), isFalse, reason: 'byte $b');
      }
    });
  });

  group('releaseActionEnabled — refused ONLY on a provably normal pack', () {
    test('normal is the only state that disables it (FB-34)', () {
      expect(releaseActionEnabled(ReportedStatus.normal), isFalse);
      expect(releaseActionEnabled(ReportedStatus.cutOffActive), isTrue);
      expect(releaseActionEnabled(ReportedStatus.antiTheftActive), isTrue);
    });

    test('an unreadable state KEEPS it — the escape hatch stays open', () {
      expect(releaseActionEnabled(null), isTrue);
      expect(releaseActionEnabled(CapacitorStatus.healthy), isTrue);
      for (final b in [5, 6, 7, 12, 13, 0xFF]) {
        expect(releaseActionEnabled(b), isTrue, reason: 'byte $b');
      }
    });
  });

  test('the two gates are NOT each other negated — the asymmetry is the point',
      () {
    // On every byte outside the pack space both are false/true respectively,
    // which is only possible because the unknown case is handled differently.
    var bothOffCount = 0;
    for (final b in <int?>[null, 5, 6, 7, 12, 13, 0xFF]) {
      expect(cutOffActionEnabled(b), isFalse);
      expect(releaseActionEnabled(b), isTrue);
      if (!cutOffActionEnabled(b) && releaseActionEnabled(b)) bothOffCount++;
    }
    expect(bothOffCount, 7);
    // And they are genuinely opposite on the two provable states.
    expect(cutOffActionEnabled(ReportedStatus.normal),
        isNot(releaseActionEnabled(ReportedStatus.normal)));
    expect(cutOffActionEnabled(ReportedStatus.cutOffActive),
        isNot(releaseActionEnabled(ReportedStatus.cutOffActive)));
  });

  // =========================================================================
  // Frame — the cut-off write is mode 0x02, bundled with auth (PROTOCOL §6.2)
  // =========================================================================

  group('cut-off command frame', () {
    test('switchMode(cutOff) is the documented 15-byte mode+auth write', () {
      const b = CommandBuilder();
      const creds = AuthCredentials(cb: 0x00A9, pwSum: 0x0135);
      final f = b.switchMode(ModeArg.cutOff, creds);

      expect(f.length, 15, reason: 'PROTOCOL.md §6.2: exactly 15 bytes');
      // Mode sub-frame: [B8, 23, 00, 01, mode, XOR]
      expect(f.sublist(0, 5), [0xB8, 0x23, 0x00, 0x01, 0x02]);
      // Auth sub-frame carries flag byte[2] = 0x01 when bundled.
      expect(f.sublist(6, 12), [0xB8, 0x2A, 0x01, 0x04, 0x00, 0xA9]);
    });

    test('the write encoding is the vendor\'s: 0 normal, 1 anti-theft, 2 cut-off',
        () {
      expect(ModeArg.unlock, 0x00);
      expect(ModeArg.antiTheft, 0x01);
      expect(ModeArg.cutOff, 0x02);
    });

    test('release writes NORMAL, not 0x06 (design 0024)', () {
      // Eight 0x06 writes against two batteries genuinely in cut-off — across
      // both cb derivation rules and with auth omitted entirely — moved 0x23
      // exactly zero times. The only wire sighting of 0x06 was a capacitor,
      // which has no cut-off feature and answers 0x23 in its own space.
      const b = CommandBuilder();
      const creds = AuthCredentials(cb: 0x00A8, pwSum: 0x00A8);
      final f = b.switchMode(ModeArg.unlock, creds);
      expect(f.sublist(0, 5), [0xB8, 0x23, 0x00, 0x01, 0x00]);
      expect(f[4], isNot(0x06), reason: 'the code that never worked');
    });
  });

  // =========================================================================
  // Widget — the buttons follow the gate, and say why when they do not
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
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> goOnline(WidgetTester tester, int mode) async {
    await tester.runAsync(() async {
      fakeBle.emitLink(BleLinkState.ready);
      await Future<void>.delayed(Duration.zero);
      fakeBle.emit(TelemetrySample(timestamp: DateTime.now(), mode: mode));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  ControlButton buttonNamed(WidgetTester tester, String label) =>
      tester.widget<ControlButton>(
        find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == label,
        ),
      );

  group('BatteryControls — release only in the community build', () {
    testWidgets('there is NO cut-off button, in any state', (tester) async {
      // Owner's decision 2026-07-30 (design 0020 §9): the build that reaches
      // the general public only ever moves a pack toward normal. Both the
      // states that would have enabled it and the one that would have disabled
      // it must render nothing.
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());
      for (final mode in [
        ReportedStatus.normal,
        ReportedStatus.cutOffActive,
        ReportedStatus.antiTheftActive,
      ]) {
        await goOnline(tester, mode);
        expect(
          find.byWidgetPredicate(
            (w) => w is ControlButton && w.label == 'Cut Off',
          ),
          findsNothing,
          reason: 'mode 0x${mode.toRadixString(16)}',
        );
      }
    });

    testWidgets('normal: release refused and explained', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());
      await goOnline(tester, ReportedStatus.normal);

      expect(buttonNamed(tester, 'Restore Power').onPressed, isNull,
          reason: 'FB-34: nothing to release on a normal pack');
      // A greyed-out button must say why (design 0020 §3.2).
      expect(find.textContaining('nothing to restore'), findsOneWidget);
    });

    testWidgets('cut-off active: release offered', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());
      await goOnline(tester, ReportedStatus.cutOffActive);

      expect(buttonNamed(tester, 'Restore Power').onPressed, isNotNull);
      // An enabled button explains nothing: the note exists to justify a
      // disabled one, and a live pack in cut-off has nothing to justify.
      expect(find.textContaining('nothing to restore'), findsNothing);
    });

    testWidgets('unreadable status: release stays available', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());
      // A capacitor's byte — outside the pack code space entirely.
      await goOnline(tester, CapacitorStatus.healthy);

      expect(buttonNamed(tester, 'Restore Power').onPressed, isNotNull,
          reason: 'never block the escape hatch on an unreadable state');
    });
  });

  group('PackControls — no cut-off button at all (design 0020 §7 Q3)', () {
    testWidgets('an unclassified pack is never offered cut-off',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const PackControls());
      await goOnline(tester, ReportedStatus.normal);

      expect(
        find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Cut Off',
        ),
        findsNothing,
        reason: 'we did not even read its device type',
      );
    });
  });
}
