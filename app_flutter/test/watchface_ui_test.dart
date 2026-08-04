// The watchface, on screen (design 0034 Phase 5 — tests T1 / T7 / T8 / T9).
//
// THE INVARIANT WORTH THE MOST HERE IS G4: a user who never opens the setting
// must see the screen they saw yesterday, card for card, in order. Every other
// test in this file is about what changes; T1 is about what must not.
//
// The second is §6, and it is an INVARIANT rather than a default: the control
// card is last, always, and cannot be moved or removed. It is enforced
// structurally — there is no `DisplayModule` for it, so no watchface can name
// it — but "structurally impossible" is a claim that has to be executed, not
// asserted in a comment.
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
import 'package:open_smart_batt/ui/dashboard/dvol_bars.dart';
import 'package:open_smart_batt/ui/dashboard/pack_view.dart';
import 'package:open_smart_batt/ui/dashboard/power_bank_view.dart';
import 'package:open_smart_batt/ui/dashboard/pvlt_gauge.dart';
import 'package:open_smart_batt/ui/dashboard/readouts_card.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:open_smart_batt/ui/widgets/industrial_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService with a settable connected id — the layout is bound to a
/// device, so "which device" is an input to every test here.
class _FakeBleService extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  String? connectedId = 'DEV-A';

  @override
  String? get connectedDeviceId => connectedId;

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

  late _FakeBleService ble;

  Future<AppServices> makeServices(WidgetTester tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _FakeBleService();
      services = await AppServices.create(appDatabase: appDb, ble: ble);
      // Two saved units: the second exists so that "the setting follows the
      // device" can be tested against something, not asserted against nothing.
      await services.devices.saveNew('DEV-A', 'unit A');
      await services.devices.saveNew('DEV-B', 'unit B');
    });
    return services;
  }

  /// Tear a test down WITHOUT tripping "used after being disposed".
  ///
  /// `AppServices.dispose()` disposes the controllers and only then drains the
  /// pending writes — and those writes call back into [DeviceController]
  /// (`touch`, `setProductClass`). Every test here has a connected device id,
  /// which is exactly what makes those writes fire, so the queue is drained
  /// first, while the controllers are still alive.
  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => s.pending.drain());
    await s.dispose();
  }

  Future<void> pumpUnder(
      WidgetTester tester, AppServices s, Widget child) async {
    // A TALL surface, on purpose. Every page here is a ListView, which builds
    // only the children it can show — on the default 800x600 the control card
    // is simply not in the tree, and "the controls are last" would pass by
    // never finding them at all.
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppServices>.value(value: s),
          Provider<BleService>.value(value: s.ble),
          Provider<HistoryRepo>.value(value: s.historyRepo),
          Provider<DeviceRepo>.value(value: s.deviceRepo),
          Provider<SettingsRepo>.value(value: s.settingsRepo),
          Provider<LogRepo>.value(value: s.logRepo),
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

  /// Push one telemetry snapshot carrying per-cell voltages, so the DVOL card
  /// has data and its DATA gate is satisfied (the card's own condition, which
  /// the watchface never overrides).
  Future<void> feedDvol(WidgetTester tester) async {
    ble.emit(TelemetrySample(
      timestamp: DateTime(2026, 8, 4, 9, 30),
      pvlt: 13.2,
      svlt: 13.1,
      temperatureC: 31,
      dvol: const [3.30, 3.31, 3.29, 3.30],
    ));
    await tester.pump();
    await tester.pump();
  }

  /// Let a real database write started by a tap actually finish.
  ///
  /// The picker writes through sqflite, which needs real async; inside a widget
  /// test the clock is faked, so a plain `pump()` returns before the row is
  /// updated and the assertion reads the value from before the tap.
  Future<void> settleWrite(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump();
  }

  /// Vertical position of the first match — the page is a ListView, so "which
  /// card comes first" is a y comparison.
  double dy(WidgetTester tester, Finder f) =>
      tester.getTopLeft(f.first).dy;

  /// The pack shell's top-level children, in order.
  List<Widget> shellChildren(WidgetTester tester) {
    final lv = tester.widget<ListView>(find.descendant(
      of: find.byType(PackScaffold),
      matching: find.byType(ListView),
    ));
    return (lv.childrenDelegate as SliverChildListDelegate).children;
  }

  Future<void> setFace(AppServices s, String id, Watchface f) =>
      s.devices.setDisplayLayout(id, DisplayLayout(watchface: f));

  // =========================================================================
  // T1 — the default IS today's screen
  // =========================================================================
  group('T1: the standard face reproduces the pre-0034 dashboard', () {
    testWidgets('battery: gauge → readouts → DVOL → controls', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(s.devices.layoutFor('DEV-A'), DisplayLayout.defaults,
          reason: 'nobody opened the setting');
      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(ReadoutsCard))));
      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(DvolBars))));
      expect(dy(tester, find.byType(DvolBars)),
          lessThan(dy(tester, find.byType(BatteryControls))));
    });

    testWidgets('capacitor: the same order, with the capacitor body',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await pumpUnder(
          tester, s, const PackScaffold(controls: CapacitorControls()));
      await feedDvol(tester);

      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(ReadoutsCard))));
      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(DvolBars))));
      expect(dy(tester, find.byType(DvolBars)),
          lessThan(dy(tester, find.byType(CapacitorControls))));
    });

    testWidgets('power bank: SOC ring → readouts (USB card retired)',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpUnder(tester, s, const PowerBankView());

      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(ReadoutsCard))));
      // design 0035 Phase 2: the two-port USB card is gone and its slot now
      // holds the energy-path row [PowerPathRow]. That row renders nothing here
      // (this harness leaves the class un-overridden, so it is not a power bank
      // to the row's own gate), so the pinned order is the surviving two cards.
    });

    testWidgets('an unclassified pack keeps the standard order even with a '
        'diagnostic face stored (Q4)', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(
          () => setFace(s, 'DEV-A', Watchface.diagnostic));
      // No label override and no wire byte → unclassified.
      await pumpUnder(tester, s, const PackScaffold(controls: PackControls()));
      await feedDvol(tester);

      expect(s.connection.packLabel, ProductClass.unknown);
      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(ReadoutsCard))),
          reason: 'a page that is asking the user what this device is must not '
              'also be rearranged under them');
    });
  });

  // =========================================================================
  // The other two faces actually do something
  // =========================================================================
  group('the non-default faces change the page', () {
    testWidgets('compact drops the DVOL card even when DVOL has data',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.compact));
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(find.byType(PvltGauge), findsOneWidget);
      expect(find.byType(ReadoutsCard), findsOneWidget);
      expect(find.byType(DvolBars), findsNothing,
          reason: 'the card is off the page by choice, not for want of data — '
              'which is exactly why the export preamble still records it');
      // And the controls are still there, and still last.
      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(BatteryControls))));
    });

    testWidgets('diagnostic puts the numbers first and the instrument last',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.diagnostic));
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);

      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(DvolBars))));
      expect(dy(tester, find.byType(DvolBars)),
          lessThan(dy(tester, find.byType(PvltGauge))));
      expect(dy(tester, find.byType(PvltGauge)),
          lessThan(dy(tester, find.byType(BatteryControls))));
    });

    testWidgets('a power bank on the diagnostic face puts numbers before the '
        'instrument', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.diagnostic));
      await pumpUnder(tester, s, const PowerBankView());

      // Diagnostic leads with the readouts and ends with the SOC ring. The
      // energy-path row (design 0035 Phase 2) renders nothing in this harness
      // (the class is not overridden to power bank), so the pinned order is the
      // surviving two.
      expect(dy(tester, find.byType(ReadoutsCard)),
          lessThan(dy(tester, find.byType(PvltGauge))));
    });
  });

  // =========================================================================
  // T7 / T8 — the control card
  // =========================================================================
  group('T7: the control card is last on every face, and unremovable', () {
    for (final face in Watchface.values) {
      testWidgets('${face.slug}: the protection card is the final child',
          (tester) async {
        final s = await makeServices(tester);
        addTearDown(() => teardown(tester, s));
        s.connection.setPackLabelOverride(ProductClass.smartBattery);
        await tester.runAsync(() => setFace(s, 'DEV-A', face));
        await pumpUnder(
            tester, s, const PackScaffold(controls: BatteryControls()));
        await feedDvol(tester);

        // Structural: it is the LAST entry of the shell's child list, not
        // merely the lowest thing that happened to render.
        expect(shellChildren(tester).last, isA<IndustrialCard>());
        expect(find.byType(BatteryControls), findsOneWidget,
            reason: 'no face may remove it');
        for (final other in [
          find.byType(PvltGauge),
          find.byType(ReadoutsCard),
        ]) {
          expect(dy(tester, other),
              lessThan(dy(tester, find.byType(BatteryControls))));
        }
      });
    }
  });

  group('T8: a power bank grows no empty control card', () {
    for (final face in Watchface.values) {
      testWidgets('${face.slug}: no protection card, no pack controls',
          (tester) async {
        final s = await makeServices(tester);
        addTearDown(() => teardown(tester, s));
        await tester.runAsync(() => setFace(s, 'DEV-A', face));
        await pumpUnder(tester, s, const PowerBankView());

        // The page did render — otherwise "no controls" would be vacuous.
        expect(find.byType(ReadoutsCard), findsOneWidget);
        expect(find.byType(BatteryControls), findsNothing);
        expect(find.byType(CapacitorControls), findsNothing);
        expect(find.byType(PackControls), findsNothing);
        // And no heading was borrowed from the pack page to hold an empty one.
        expect(find.text('Protection Status'), findsNothing);
      });
    }
  });

  // =========================================================================
  // The binding: the layout belongs to the DEVICE (Q3)
  // =========================================================================
  group('switching devices switches the layout with them', () {
    testWidgets('the same widget draws two different pages for two units',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      await tester.runAsync(() async {
        await setFace(s, 'DEV-A', Watchface.compact);
        await setFace(s, 'DEV-B', Watchface.standard);
      });

      ble.connectedId = 'DEV-A';
      await pumpUnder(tester, s, const PackScaffold(controls: BatteryControls()));
      await feedDvol(tester);
      expect(find.byType(DvolBars), findsNothing, reason: 'A is compact');

      // Same telemetry, same widget, different unit.
      ble.connectedId = 'DEV-B';
      await tester.runAsync(() => s.devices.load()); // notifies → rebuild
      await tester.pump();
      expect(find.byType(DvolBars), findsOneWidget, reason: 'B is standard');
    });
  });

  // =========================================================================
  // The settings entry point (Q6)
  // =========================================================================
  group('the Display card carries the picker and the restore', () {
    Future<void> pumpSettings(WidgetTester tester, AppServices s) async {
      await pumpUnder(tester, s, const SettingsScreen());
      await tester.scrollUntilVisible(find.text('Watchface'), 60,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();
    }

    testWidgets('picking a face writes it against the connected device',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await pumpSettings(tester, s);

      expect(find.text('Standard'), findsOneWidget);
      expect(find.text('Compact'), findsOneWidget);
      expect(find.text('Diagnostic'), findsOneWidget);

      await tester.tap(find.text('Diagnostic'));
      await settleWrite(tester);
      expect(s.devices.layoutFor('DEV-A').watchface, Watchface.diagnostic);
      expect(s.devices.layoutFor('DEV-B'), DisplayLayout.defaults,
          reason: 'the other saved unit is untouched');
    });

    // T9 — one tap back to T1.
    testWidgets('T9: restore defaults puts the standard face back',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      await tester.runAsync(() => setFace(s, 'DEV-A', Watchface.diagnostic));
      await pumpSettings(tester, s);

      await tester.tap(find.text('Restore default display'));
      await settleWrite(tester);
      expect(s.devices.layoutFor('DEV-A'), DisplayLayout.defaults);
    });

    testWidgets('with no device the row is disabled and says why',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      ble.connectedId = null;
      await pumpSettings(tester, s);

      // Kept visible rather than hidden — the background-monitoring precedent:
      // a user who has heard of the feature needs to see WHY it is off.
      expect(find.text('Watchface'), findsOneWidget);
      expect(
        find.textContaining('This setting belongs to a device'),
        findsOneWidget,
      );
      // Inert, not merely dimmed: tapping writes nothing anywhere.
      await tester.tap(find.text('Diagnostic'), warnIfMissed: false);
      await settleWrite(tester);
      expect(s.devices.layoutFor('DEV-A'), DisplayLayout.defaults);
      expect(s.devices.layoutFor('DEV-B'), DisplayLayout.defaults);
    });

    testWidgets('a connected but UNSAVED device also disables the row',
        (tester) async {
      // The layout lives in the saved_devices row. A unit the user declined to
      // name has nowhere to put one, and adding it to their device list as a
      // side effect of a display setting would be a surprise.
      final s = await makeServices(tester);
      addTearDown(() => teardown(tester, s));
      ble.connectedId = 'DEV-UNSAVED';
      await pumpSettings(tester, s);

      expect(
        find.textContaining('This setting belongs to a device'),
        findsOneWidget,
      );
      await tester.tap(find.text('Compact'), warnIfMissed: false);
      await settleWrite(tester);
      expect(s.devices.isSaved('DEV-UNSAVED'), isFalse);
    });
  });
}
