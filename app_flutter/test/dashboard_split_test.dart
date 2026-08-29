// Widget tests for the per-class control split + pack-shell body selection.
//
//   * controls-subset: CapacitorControls shows ONLY 檢測電容; BatteryControls
//     shows 復電 and NOT 檢測電容. A capacitor has no run mode, so it must never
//     be handed a cut-off control; a battery has no capacitor to self-check.
//   * pack-shell body: PackView picks CapacitorView / BatteryView by the
//     COSMETIC label, and the bounded fallback (union minus anti-theft) while
//     still unclassified. All three render the SAME shell — the label chooses
//     controls, never layout.
//
// Controllers are assembled via AppServices over an in-memory sqflite (ffi) DB
// with an inert BleService (mirrors widget_test.dart), so this runs headless.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/pack_view.dart';
import 'package:open_smart_batt/ui/dashboard/readouts_card.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService: never reaches the (unsupported) flutter_blue_plus platform.
///
/// [emit] pushes a telemetry snapshot through the same stream the real service
/// uses, so a test can drive the readouts without a device.
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

  setUpAll(() {
    sqfliteFfiInit();
  });

  /// Build the full controller graph over an in-memory DB (real IO → runAsync).
  late _FakeBleService fakeBle;

  Future<AppServices> makeServices(WidgetTester tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      fakeBle = _FakeBleService();
      services = await AppServices.create(
        appDatabase: appDb,
        ble: fakeBle,
      );
    });
    return services;
  }

  /// Pump [child] under the controller providers + English localization.
  Future<void> pumpUnder(
      WidgetTester tester, AppServices s, Widget child) async {
    // A TALL surface. The pack shell is a ListView, so it builds only what
    // fits — and since design 0051 the drawn face carries the trend chart,
    // which pushes the control card past the bottom of the default 800x600.
    // "the controls are absent" would then pass by never building them.
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: s.settings),
          ChangeNotifierProvider<DeviceController>.value(value: s.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: s.connection),
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
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
    // design 0065: the pack shell now ends with the embedded history block,
    // which fires its three queries on mount. Real database IO cannot settle
    // under the widget tester's fake clock, so it is drained here — otherwise
    // every test in this file ends holding a pending timer.
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
  }

  group('controls subset — each body shows only what its class has', () {
    testWidgets('CapacitorControls shows 檢測電容 but not 解除斷電',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());

      expect(find.text('Check Capacitor'), findsOneWidget);
      expect(find.text('Restore Power'), findsNothing);
      expect(find.text('Anti-theft'), findsNothing);
    });

    testWidgets('BatteryControls shows 復電 but not 檢測電容',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());

      expect(find.text('Restore Power'), findsOneWidget);
      expect(find.text('Check Capacitor'), findsNothing);
      // Anti-theft is model-gated (no override wired) → hidden by default.
      expect(find.text('Anti-theft'), findsNothing);
    });
  });

  group('pack-shell body chosen by cosmetic label (gating, not routing)', () {
    testWidgets('super-capacitor label → CapacitorView', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));

      expect(find.byType(CapacitorView), findsOneWidget);
      expect(find.byType(BatteryView), findsNothing);
      // Capacitor body → 檢測電容 only.
      expect(find.text('Check Capacitor'), findsOneWidget);
      expect(find.text('Restore Power'), findsNothing);
    });

    testWidgets('smart-battery label → BatteryView', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));

      expect(find.byType(BatteryView), findsOneWidget);
      expect(find.byType(CapacitorView), findsNothing);
      expect(find.text('Restore Power'), findsOneWidget);
      expect(find.text('Check Capacitor'), findsNothing);
    });

    testWidgets('unclassified pack → bounded fallback (release only)',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      // No override, not connected → packLabel is unknown.
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));

      expect(find.byType(CapacitorView), findsNothing);
      expect(find.byType(BatteryView), findsNothing);
      // 🔵 The bounded fallback is 復電 alone since 2026-08-28 (design 0082
      // Q8). 檢測電容 sends `0x23` <- `0x06` now, and the fallback's licence to
      // err lenient is precisely that nothing in it changes device state.
      expect(find.text('Check Capacitor'), findsNothing);
      expect(find.text('Restore Power'), findsOneWidget);
      expect(find.text('Anti-theft'), findsNothing);
    });
  });

  // REWRITTEN 2026-08-04 (design 0034 §5.4 ruling, Phase 2). This group used
  // to assert that each body renders its own permanent "this unit is a …"
  // note, and those three notes have now been removed — they fired on every
  // render and told the owner nothing they could act on.
  //
  // Rewritten rather than deleted, because the bug the group was built for is
  // still reachable. Before the notes were split per class there was ONE
  // string saying "this unit is detected as a Supercapacitor", rendered under
  // all three control sets, so a battery owner was told their battery was a
  // capacitor. Deleting the copy removes today's instance of that bug; it does
  // not remove the way back to it, since the next line of copy added to a
  // shared helper lands in all three bodies again.
  //
  // So the assertion is INVERTED: a body must never render the other class's
  // vocabulary. That holds now (nothing names a class at all) and keeps
  // holding the day any class-specific copy returns — which is the protection
  // the original tests were really providing.
  group('no control body speaks another class\'s vocabulary', () {
    testWidgets('a battery body never says capacitor', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const BatteryControls());

      // The body did render — otherwise "no capacitor text" would be vacuous.
      expect(find.text('Restore Power'), findsOneWidget);
      // Nothing capacitor-flavoured, in any casing: this body has no capacitor
      // control and no capacitor status to report.
      expect(find.textContaining(RegExp('capacitor', caseSensitive: false)),
          findsNothing);
    });

    testWidgets('a capacitor body never says battery', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());

      expect(find.text('Check Capacitor'), findsOneWidget);
      expect(find.textContaining(RegExp('battery', caseSensitive: false)),
          findsNothing);
    });

    testWidgets('the unclassified fallback claims neither class',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const PackControls());

      // This body offers the release — that is what is left of the "bounded
      // union" after design 0082 Q8 — so the check here is narrower: it hands
      // you an escape hatch, but it may never assert which class the unit is.
      expect(find.text('Restore Power'), findsOneWidget);
      expect(
          find.textContaining(
              RegExp('super-capacitor|smart battery', caseSensitive: false)),
          findsNothing);
      expect(find.textContaining('This unit is'), findsNothing);
    });
  });

  group('capacitor current readout is class-gated, not data-driven', () {
    testWidgets('hidden on a capacitor even when a 0.0 A register arrives',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      // The field unit: device-type 0x17 plus the 0x2E register pinned at 0.0 A.
      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));
      await tester.runAsync(() async {
        fakeBle.emit(TelemetrySample(timestamp: DateTime.now(), current: 0.0));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(find.byType(CapacitorView), findsOneWidget);
      // A capacitor cannot measure current; a permanent 0.0 A would be a lie.
      expect(find.text('MAIN CURRENT'), findsNothing);
    });

    testWidgets('still shown for a battery streaming the same register',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));
      await tester.runAsync(() async {
        fakeBle.emit(TelemetrySample(timestamp: DateTime.now(), current: 1.5));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(find.byType(BatteryView), findsOneWidget);
      // Same register, different class → shown here, hidden on the capacitor.
      expect(find.text('MAIN CURRENT'), findsOneWidget);
    });
  });

  group('readout precision follows the register, not the layout (FB-81)', () {
    testWidgets('voltages carry two decimals, current keeps one',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));
      await tester.runAsync(() async {
        // 13.28 is the owner's own 2026-08-17 sighting: the chart track above
        // the grid drew 13.28 while the grid rounded it to 13.3.
        fakeBle.emit(TelemetrySample(
          timestamp: DateTime.now(),
          pvlt: 13.28,
          svlt: 13.11,
          current: -35,
        ));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      // `findRichText`: a readout's value and unit share one `Text.rich`, so a
      // plain-text finder sees the label and nothing else.
      Finder inGrid(String s) => find.descendant(
            of: find.byType(ReadoutsCard),
            matching: find.textContaining(s, findRichText: true),
          );

      // `0x19` is `u16/100`, so both digits are measured.
      expect(inGrid('13.28'), findsOneWidget);
      expect(inGrid('13.3'), findsNothing);

      // 🔴 The `0x37` half of this assertion moved to the capacitor case below
      // (FB-106, 2026-08-30): a battery no longer prints SVLT at all, so
      // asserting its precision here would only be asserting that a tile is
      // gone — which the FB-106 group does directly, and by NAME rather than by
      // a value that could vanish for an unrelated reason.
      expect(inGrid('13.11'), findsNothing);

      // `0x2E` is `512 - u16` — integer amps. The magnitude is shown (the sign
      // is spent on the direction badge, design 0056), and the lone decimal
      // stays as it was: widening it would invent a precision, and this test
      // exists to keep the FB-81 sweep from taking the current cell with it.
      expect(inGrid('35.0'), findsOneWidget);
    });

    testWidgets('SVLT keeps its two decimals on the class that still shows it',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      // The FB-81 guarantee is about the REGISTER (`u16/100`), not about the
      // battery, so it has to keep being pinned somewhere after FB-106 took
      // the tile off the battery. This is that somewhere.
      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));
      await tester.runAsync(() async {
        fakeBle.emit(TelemetrySample(
          timestamp: DateTime.now(),
          pvlt: 13.28,
          svlt: 13.11,
        ));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      Finder inGrid(String s) => find.descendant(
            of: find.byType(ReadoutsCard),
            matching: find.textContaining(s, findRichText: true),
          );

      expect(inGrid('13.11'), findsOneWidget);
      expect(inGrid('13.1'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------
  // FB-106 — 「電池類型不用顯示次電壓，就是主電壓跟分串電壓就好」
  //
  // Dealer suggestion relayed by the owner on 2026-08-30, whose stated reason
  // is confusion rather than correctness: two near-identical voltages under two
  // names on one screen is a question ("which one is my battery?"), and the
  // corpus agrees it is not an informative question — `0x37` is the sum of the
  // DVOL card below it (`knowledges/voltage-chains.md` §2) and matches PVLT to
  // within 0.10 V on 98.1% of 526,887 battery minutes.
  //
  // 🔑 These tests assert a CLASS difference, which is the part that could
  // regress silently: "the battery hides it" is only safe while "the capacitor
  // keeps it" is also true, and a class-wide deletion would still pass any test
  // that only looked at the battery.
  // ---------------------------------------------------------------------
  group('SVLT readout is class-gated (FB-106)', () {
    Future<void> pumpWith(
      WidgetTester tester,
      AppServices s,
      ProductClass cls,
    ) async {
      s.connection.setPackLabelOverride(cls);
      await pumpUnder(tester, s, const PackView(deviceId: 'DEV-TEST'));
      await tester.runAsync(() async {
        // A REAL value, deliberately: the tile is not being hidden because the
        // register is missing. It is being removed from a class that has the
        // same number twice already, so the register arriving must not bring
        // it back.
        fakeBle.emit(TelemetrySample(
          timestamp: DateTime.now(),
          pvlt: 13.19,
          svlt: 13.22,
        ));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
    }

    testWidgets('absent on a smart battery even with 0x37 streaming',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpWith(tester, s, ProductClass.smartBattery);

      expect(find.byType(BatteryView), findsOneWidget);
      expect(find.text('SECONDARY VOLTAGE'), findsNothing);
      // What the suggestion asked to KEEP. Without this the test would also
      // pass on a grid that had lost every voltage.
      expect(find.text('PRIMARY VOLTAGE'), findsOneWidget);
      // And the value itself is gone from the card, not merely the label.
      expect(
          find.descendant(
            of: find.byType(ReadoutsCard),
            matching: find.textContaining('13.22', findRichText: true),
          ),
          findsNothing);
    });

    testWidgets('still shown on a capacitor — it has no DVOL card',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpWith(tester, s, ProductClass.supercapacitor);

      expect(find.byType(CapacitorView), findsOneWidget);
      expect(find.text('SECONDARY VOLTAGE'), findsOneWidget);
    });
  });
}
