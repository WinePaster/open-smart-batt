// design 0035 Phase 1 — the energy-path row on screen.
//
// One line, three segments (direction → port → readings), driven from ONE
// sample so the port shown cannot disagree with the direction shown (§4.5). The
// invariants pinned here are the ones the design calls out as the easy mistakes:
//
//   * the port is Type-C (b7 bit1) or "path undetermined" — NEVER Type-A, and
//     never inferred from bit0 (§4.3, Q10(a));
//   * "PD" is positive-only, from bit3 (input) / bit5 (output), never crossed
//     and never negated into a "standard"/"non-PD" label (§4.4);
//   * b7 == 0x00 **corroborated by an idle current** is standby (rail off),
//     decided BEFORE any port test (§4.3); b7 == 0x00 that the same burst's
//     current contradicts claims neither standby nor a port (2026-08-05);
//   * the §4.8 hook shows ONLY on the "path undetermined" row while energy is
//     moving, is dismissible, and changes no display decision.
//
// The exhaustive T1–T13 wording table is Phase 3; this file is the Phase-1
// pump-the-vectors guard that the row builds and decides correctly.
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
import 'package:open_smart_batt/ui/dashboard/power_path_row.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService that can push one telemetry snapshot.
class _FakeBleService extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  @override
  String? get connectedDeviceId => 'DEV-A';

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
      await services.devices.saveNew('DEV-A', 'unit A');
    });
    return services;
  }

  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => s.pending.drain());
    await s.dispose();
  }

  /// Pump the row alone with one snapshot already applied.
  ///
  /// [portFlagsRaw] null means "0x4B has not arrived" — the waiting case, which
  /// must stay distinct from a decoded zero. [cls] lets the non-power-bank guard
  /// be exercised (T10).
  Future<AppServices> pumpRow(
    WidgetTester tester, {
    int? portFlagsRaw,
    double? current,
    double? svlt,
    ProductClass cls = ProductClass.powerBank,
    bool emitSample = true,
  }) async {
    final s = await makeServices(tester);
    addTearDown(() => teardown(tester, s));
    s.connection.setPackLabelOverride(cls);
    tester.view.physicalSize = const Size(900, 1600);
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
          home: const Scaffold(body: PowerPathRow()),
        ),
      ),
    );
    await tester.pump();
    if (emitSample) {
      // No device-type byte: the class is set by [setPackLabelOverride] above,
      // so the wire cannot override the non-power-bank case (T10) out from under
      // the test. The row reads the class from the connection, not the sample.
      ble.emit(TelemetrySample(
        timestamp: DateTime(2026, 8, 4, 14, 43),
        pvlt: 3.95,
        svlt: svlt,
        current: current,
        portFlagsRaw: portFlagsRaw,
      ));
      await tester.pump();
      await tester.pump();
    }
    return s;
  }

  // =========================================================================
  // §3.3 ground-truth vectors — the port ladder
  // =========================================================================
  group('§3.3 port ladder', () {
    testWidgets('0x0a (bit1+bit3) charging: Type-C + PD, never Type-A',
        (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x0a, current: -0.42, svlt: 9.14);

      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('Type-C'), findsOneWidget);
      expect(find.text('PD'), findsOneWidget);
      expect(find.text('9.14 V'), findsOneWidget);
      expect(find.text('0.42 A'), findsOneWidget);
      // Q10(a): no Type-A anywhere, and this is not "undetermined".
      expect(find.text('Type-A'), findsNothing);
      expect(find.text('Path undetermined'), findsNothing);
    });

    testWidgets('0x05 (bit1 clear) discharging: Type-A BY ELIMINATION',
        (tester) async {
      // A real discharge current (> dead-band) so the direction is unambiguous.
      // With no Type-C cable and energy leaving the bank there is no other path
      // it can take: 29,114 agree / 0 disagree over every port-marked capture,
      // three units (feedback-analysis/2026.08.04-014.md §1).
      await pumpRow(tester, portFlagsRaw: 0x05, current: 0.42, svlt: 5.12);

      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('Type-A'), findsOneWidget);
      expect(find.text('Path undetermined'), findsNothing);
      expect(find.text('Type-C'), findsNothing);
    });

    testWidgets('...and bit0 is NOT what decided it', (tester) async {
      // Same elimination with bit0 CLEAR (only bit2, the rail, is set). If this
      // ever starts reading "path undetermined" while the case above reads
      // Type-A, someone has quietly wired bit0 back in — the reading that four
      // field captures refuted (§4.3).
      await pumpRow(tester, portFlagsRaw: 0x04, current: 0.42, svlt: 5.12);

      expect(find.text('Type-A'), findsOneWidget);
    });

    testWidgets('bit1 clear but NOT discharging: still undetermined',
        (tester) async {
      // Standby has nothing to eliminate from. The elimination is a statement
      // about where a current is going, not about the port itself — bit1 clear
      // on its own says only "no Type-C cable".
      await pumpRow(tester, portFlagsRaw: 0x05, current: 0.0, svlt: 5.12);

      expect(find.text('Type-A'), findsNothing);
    });

    testWidgets('0x00 + in-band current: standby, before any port test',
        (tester) async {
      // A GENUINE rail-off: −0.039 A is the 36–39 mA `0x49` offset a rail-off
      // unit always reports, which the ±0.05 A dead-band swallows. Flag and
      // current corroborate, so standby is claimed. Unchanged behaviour.
      await pumpRow(tester, portFlagsRaw: 0x00, current: -0.03, svlt: 3.95);

      expect(find.text('Standby · output off'), findsOneWidget);
      expect(find.text('Type-C'), findsNothing);
      expect(find.text('Path undetermined'), findsNothing);
      expect(find.text('Type-A'), findsNothing);
    });

    testWidgets('spurious 0x00 (2,718 mA discharge): neither standby nor Type-A',
        (tester) async {
      // The 13:08:26 vector from the 36,151-burst capture: b7 read 0x00 while
      // `0x4A` carried the batch's HIGHEST discharge (2,718 mA) and the port
      // voltage held ≥ 5.17 V across ±2 s. The flag contradicts the current, so
      // the row must claim neither.
      //
      // The Type-A assertion is the load-bearing one: b7 == 0x00 has bit1
      // clear, so a fall-through to the normal ladder would print "Type-A" with
      // full confidence — on a sample the operator had marked Type-C.
      await pumpRow(tester, portFlagsRaw: 0x00, current: 2.718, svlt: 5.22);

      expect(find.text('Standby · output off'), findsNothing);
      expect(find.text('Type-A'), findsNothing);
      expect(find.text('Type-C'), findsNothing);
      expect(find.text('PD'), findsNothing);
      // What we DO still know comes from 0x49/0x4A, not from b7.
      expect(find.text('Path undetermined'), findsOneWidget);
      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('5.22 V'), findsOneWidget);
      expect(find.text('2.72 A'), findsOneWidget);
    });

    testWidgets('spurious 0x00 on the charge side is treated the same',
        (tester) async {
      // The 23:25:27 vector: b7 = 0x00 with `0x49` at 2,712 mA charging.
      await pumpRow(tester, portFlagsRaw: 0x00, current: -2.712, svlt: 4.92);

      expect(find.text('Standby · output off'), findsNothing);
      expect(find.text('Type-A'), findsNothing);
      expect(find.text('Path undetermined'), findsOneWidget);
      expect(find.text('CHARGING'), findsOneWidget);
    });

    testWidgets('0x03 (bit0+bit1): bit1 wins → Type-C, never Type-A',
        (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x03, current: -0.30, svlt: 9.0);

      expect(find.text('Type-C'), findsOneWidget);
      expect(find.text('Type-A'), findsNothing);
      expect(find.text('Path undetermined'), findsNothing);
    });

    testWidgets('0x12 (bit1+bit4): Type-C, and bit4 needs no special case',
        (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x12, current: -0.30, svlt: 9.0);

      expect(find.text('Type-C'), findsOneWidget);
      // bit3 is clear here → no PD, and NO negative label (§4.4).
      expect(find.text('PD'), findsNothing);
    });
  });

  // =========================================================================
  // §4.4 — PD is positive-only and never crossed
  // =========================================================================
  group('§4.4 PD badge', () {
    testWidgets('bit3 clear while charging shows no PD and no negative label',
        (tester) async {
      // 0x02 = bit1 only. Charging, but bit3 clear.
      await pumpRow(tester, portFlagsRaw: 0x02, current: -0.42, svlt: 9.0);

      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('PD'), findsNothing);
      // We never fabricate the negative claim.
      for (final s in ['non-PD', 'Non-PD', 'standard', 'Standard', '一般']) {
        expect(find.text(s), findsNothing);
      }
    });

    testWidgets('charging reads bit3 only — bit5 set must NOT cross to PD',
        (tester) async {
      // 0x22 = bit1 + bit5 (output-PD). While CHARGING we look at bit3 (clear).
      await pumpRow(tester, portFlagsRaw: 0x22, current: -0.42, svlt: 9.0);

      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('PD'), findsNothing);
    });

    testWidgets('discharging reads bit5 → PD from output', (tester) async {
      // 0x22 = bit1 + bit5. Discharging, so bit5 is the one that counts.
      await pumpRow(tester, portFlagsRaw: 0x22, current: 1.2, svlt: 5.1);

      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('PD'), findsOneWidget);
    });
  });

  // =========================================================================
  // waiting / non-power-bank
  // =========================================================================
  group('waiting and gating', () {
    testWidgets('0x4B not yet arrived: waiting, not a decoded zero',
        (tester) async {
      await pumpRow(tester, portFlagsRaw: null, current: -0.42, svlt: 9.0);

      expect(find.textContaining('Waiting for device'), findsOneWidget);
      expect(find.text('0.42 A'), findsNothing);
      expect(find.text('Path undetermined'), findsNothing);
    });

    testWidgets('non-power-bank renders nothing (T10)', (tester) async {
      await pumpRow(tester,
          portFlagsRaw: 0x0a,
          current: -0.42,
          svlt: 9.0,
          cls: ProductClass.smartBattery);

      expect(find.byType(PowerPathRow), findsOneWidget);
      // The card heading is the tell that the row drew anything at all.
      expect(find.text('Energy Path'), findsNothing);
      expect(find.text('CHARGING'), findsNothing);
    });
  });

  // =========================================================================
  // §4.8 — the feedback hook, only where we truly do not know the port
  // =========================================================================
  group('§4.8 feedback hook', () {
    testWidgets('appears on the undetermined row and records a tag once',
        (tester) async {
      // CHARGING with bit1 clear. Discharge is no longer hooked — it is derived
      // as Type-A above — so what is left is the one combination the corpus has
      // never produced: energy coming IN with no Type-C cable detected. A user
      // who reaches it is exactly who we want to hear from.
      final s =
          await pumpRow(tester, portFlagsRaw: 0x01, current: -0.42, svlt: 5.1);

      final hook = find.text('Which port is this?');
      expect(hook, findsOneWidget);

      await tester.tap(hook);
      await tester.pumpAndSettle();
      // The chooser offers the three tags.
      expect(find.text('Type-A'), findsOneWidget);
      expect(find.text('Other / not sure'), findsWidgets);

      await tester.tap(find.text('Type-A').last);
      await tester.pumpAndSettle();

      // Handled once: the affordance is gone for this connection (non-nagging).
      expect(find.text('Which port is this?'), findsNothing);

      // The tag rides the design 0029 event channel, which writes to the log DB
      // (real async) — drain it, then run out the SnackBar's dismiss timer, so
      // neither outlives the widget tree.
      await tester.runAsync(() => s.pending.drain());
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });

    testWidgets('never shown for a known Type-C port', (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x0a, current: -0.42, svlt: 9.14);
      expect(find.text('Which port is this?'), findsNothing);
    });

    testWidgets('never shown in standby', (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x00, current: -0.03, svlt: 3.95);
      expect(find.text('Which port is this?'), findsNothing);
    });

    testWidgets('never shown on a contradicted 0x00 burst', (tester) async {
      // Undetermined AND charging, which is normally the one hooked state —
      // but we do not ask the user to label a burst whose flag byte we have
      // just decided not to believe.
      await pumpRow(tester, portFlagsRaw: 0x00, current: -2.712, svlt: 4.92);
      expect(find.text('Path undetermined'), findsOneWidget);
      expect(find.text('Which port is this?'), findsNothing);
    });
  });

  // =========================================================================
  // Reading ORDER — the direction word must sit immediately before the numbers
  // it qualifies (2026-08-05).
  //
  // This group exists because the change that introduced it broke NOTHING: the
  // whole suite passed unchanged after the segments were reordered, since every
  // other assertion is `find.text(...)`, which is order-blind. The defect being
  // fixed is *purely* spatial — "9.04 V" with no word near it saying which way
  // the energy goes — so a presence check cannot protect it and the next
  // refactor would silently put it back. These assert x-positions, i.e. what a
  // reader's eye actually does.
  // =========================================================================
  group('the direction word reads as the readings\' label', () {
    /// Left edge of the first widget matching [f], in logical pixels.
    double x(WidgetTester tester, Finder f) => tester.getTopLeft(f.first).dx;

    testWidgets('charging: port → PD → direction → V → A', (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x0a, current: -0.42, svlt: 9.14);

      final port = x(tester, find.text('Type-C'));
      final pd = x(tester, find.text('PD'));
      final dir = x(tester, find.text('CHARGING'));
      final volts = x(tester, find.text('9.14 V'));
      final amps = x(tester, find.text('0.42 A'));

      expect(port, lessThan(pd), reason: 'port before protocol');
      expect(pd, lessThan(dir), reason: 'protocol before direction');
      expect(dir, lessThan(volts), reason: 'THE POINT: direction before volts');
      expect(volts, lessThan(amps), reason: 'volts before amps');
    });

    testWidgets('discharging: the same order, Type-A by elimination',
        (tester) async {
      await pumpRow(tester, portFlagsRaw: 0x05, current: 0.42, svlt: 5.12);

      expect(x(tester, find.text('Type-A')),
          lessThan(x(tester, find.text('DISCHARGING'))));
      expect(x(tester, find.text('DISCHARGING')),
          lessThan(x(tester, find.text('5.12 V'))));
    });

    testWidgets('nothing separates the direction from the readings',
        (tester) async {
      // A `·` between them would undo the grouping this change is for: the
      // separators mark the boundaries BETWEEN clauses, and the direction plus
      // its numbers are one clause. Three dots, not four.
      await pumpRow(tester, portFlagsRaw: 0x0a, current: -0.42, svlt: 9.14);
      expect(find.text('·'), findsNWidgets(1),
          reason: 'one separator: [port PD] · [direction V A]');
    });
  });
}
