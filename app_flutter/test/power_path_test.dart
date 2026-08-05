// design 0035 Phase 3 — the full T1–T13 wording matrix for the energy-path row.
//
// power_path_row_test.dart (Phase 1) pumps the vectors to prove the row BUILDS
// and DECIDES correctly. This file is the exhaustive, wording-level contract the
// design's §9 test plan asks for: every string the row may or may NOT print, and
// the grep/l10n guards that keep the fabricated fast-charge table (N3) and the
// retired USB strings (§7) from creeping back.
//
// Two reconciliations, documented at their tests so a later reader does not
// "fix" a passing test back into a stale one:
//
//   * T1 / T4 (b7 == 0x00): §9's T4 line predates the 009–012 upgrade that made
//     b7 == 0x00 mean "boost rail off" (§3.3 obs 1, §4.3 ladder step 1, §4.6).
//     The authoritative, later, thrice-repeated ruling — and the shipped Phase-0
//     decoder + Phase-1 row — say b7 == 0x00 → a rail-off standby, decided
//     BEFORE any port test. The DURABLE invariant both readings share, and the
//     one pinned here, is: b7 == 0x00 never shows a FABRICATED port (never
//     Type-A, never Type-C).
//     ⚠️ **Revised 2026-08-05 (spurious-0x00 guard).** Standby now requires the
//     same burst's current to be idle as well. With a live current the flag is
//     contradicted, and the row claims neither standby nor a port — it shows
//     the direction, the readings, and "path undetermined". That lands T4 back
//     on §9's original "路徑未定, never 待機" wording for the nonzero-current
//     case, which is why T4 below now asserts the undetermined badge.
//   * The §3.3 discharge current for 0x05 (11–26 mA) sits INSIDE the ±0.05 A
//     dead-band, so the real vector reads "idle", not "discharging". To isolate
//     the PORT ladder (the point of T1/T7) these tests use a beyond-band current
//     the way Phase 1 did; the in-band behaviour is pinned separately in T8.
import 'dart:async';
import 'dart:io';

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
import 'package:open_smart_batt/ui/dashboard/display_modules.dart';
import 'package:open_smart_batt/ui/dashboard/power_path_row.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService that can push telemetry snapshots one at a time.
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

/// Resolve the Flutter package root regardless of the test runner's cwd, so the
/// l10n (T11) and grep (T13) guards can read source files.
Directory _packageRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate package root (pubspec.yaml) from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir;
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

  /// Mount the row alone. Returns the services and a function to emit one more
  /// sample (T5 feeds a second one). [portFlagsRaw] null means "0x4B has not
  /// arrived" (T9). [emitSample] false leaves the pre-sample state.
  Future<(AppServices, void Function(TelemetrySample))> mount(
    WidgetTester tester, {
    int? portFlagsRaw,
    double? current,
    double? svlt,
    ProductClass cls = ProductClass.powerBank,
    bool emitSample = true,
    int pumps = 2,
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

    void emit(TelemetrySample sample) {
      ble.emit(sample);
    }

    if (emitSample) {
      emit(TelemetrySample(
        timestamp: DateTime(2026, 8, 4, 14, 43),
        pvlt: 3.95,
        svlt: svlt,
        current: current,
        portFlagsRaw: portFlagsRaw,
      ));
      for (var i = 0; i < pumps; i++) {
        await tester.pump();
      }
    }
    return (s, emit);
  }

  // =========================================================================
  // T1 — the three §3.3 ground-truth vectors, exact wording.
  // =========================================================================
  group('T1 §3.3 vectors', () {
    testWidgets('0x0a charging: CHARGING · Type-C · PD · 9.14 V · 0.42 A',
        (tester) async {
      await mount(tester, portFlagsRaw: 0x0a, current: -0.42, svlt: 9.14);
      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('Type-C'), findsOneWidget);
      expect(find.text('PD'), findsOneWidget);
      expect(find.text('9.14 V'), findsOneWidget);
      expect(find.text('0.42 A'), findsOneWidget);
      expect(find.text('Type-A'), findsNothing);
      expect(find.text('Path undetermined'), findsNothing);
    });

    testWidgets('0x05 discharging: DISCHARGING · Type-A by elimination',
        (tester) async {
      // §3.3's 17 mA is in-band; a beyond-band discharge isolates the PORT.
      // Revised 2026-08-05: bit1 clear + discharging leaves Type-A as the only
      // path the energy can take (29,114/0 over every port-marked capture,
      // three units). Still no Type-A BIT — bit0 stays refuted and unread.
      await mount(tester, portFlagsRaw: 0x05, current: 0.42, svlt: 5.12);
      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('Type-A'), findsOneWidget);
      expect(find.text('5.12 V'), findsOneWidget);
      expect(find.text('Path undetermined'), findsNothing);
      expect(find.text('Type-C'), findsNothing);
    });

    testWidgets('0x00 + in-band current: plain STANDBY', (tester) async {
      // The §3.3 rail-off vector as it actually reads on the wire: −0.039 A,
      // the `0x49` offset a rail-off unit always reports, inside the ±0.05 A
      // dead-band. Flag and current corroborate ⇒ standby, and no port badge of
      // any kind.
      //
      // 🔴 design 0041 Q2: the words are now the plain "STANDBY" the SOC dial
      // uses, not a rail-specific phrase. The two standby STRINGS were merged;
      // the corroboration TEST that used to pick between them still runs and is
      // pinned by the spurious-0x00 group below.
      await mount(tester, portFlagsRaw: 0x00, current: -0.03, svlt: 3.95);
      expect(find.text('STANDBY'), findsOneWidget);
      expect(find.text('Standby · output off'), findsNothing);
      expect(find.text('Standby · no flow'), findsNothing);
      expect(find.text('CHARGING'), findsNothing);
      expect(find.text('Type-C'), findsNothing);
      expect(find.text('Type-A'), findsNothing);
      expect(find.text('Path undetermined'), findsNothing);
    });
  });

  // =========================================================================
  // Spurious b7 == 0x00 (2026-08-05) — the flag contradicted by its own burst.
  // =========================================================================
  group('spurious 0x00 guard', () {
    testWidgets('2,718 mA discharge: no standby, no Type-A, undetermined',
        (tester) async {
      // The 13:08:26 vector — b7 = 0x00 at the capture's highest discharge,
      // with `0x37` never dropping below 5.17 V across ±2 s. 5 such frames in
      // 36,152 bursts; at 1 Hz that is a visible flicker every ~2 hours.
      await mount(tester, portFlagsRaw: 0x00, current: 2.718, svlt: 5.22);
      expect(find.text('STANDBY'), findsNothing);
      // bit1 is clear at 0x00, so a fall-through would print Type-A with full
      // confidence — and the operator had this sample marked Type-C.
      expect(find.text('Type-A'), findsNothing);
      expect(find.text('Type-C'), findsNothing);
      // design 0041 Q3: withholding is drawing NO badge. The assertion is that
      // no port word of any kind reached the row.
      expect(find.text('Path undetermined'), findsNothing);
      // Direction and readings survive: they come from 0x49/0x4A, not from b7.
      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('5.22 V'), findsOneWidget);
      expect(find.text('2.72 A'), findsOneWidget);
    });

    testWidgets('68 mA discharge is still beyond the dead-band',
        (tester) async {
      // The 20:49:38 vector. 0.068 A > 0.05 A, so it is a contradiction too —
      // this is the sample that shows the guard is not merely a "large current"
      // rule; the dead-band is the whole test.
      await mount(tester, portFlagsRaw: 0x00, current: 0.068, svlt: 5.18);
      expect(find.text('STANDBY'), findsNothing);
      expect(find.text('Type-A'), findsNothing);
      expect(find.text('Type-C'), findsNothing);
      expect(find.text('DISCHARGING'), findsOneWidget);
    });

    testWidgets('no debounce was added: one sample still decides the frame',
        (tester) async {
      // A debounce was considered and rejected (state + latency on the genuine
      // transition). Nothing is waiting to flip this row a second later.
      await mount(tester, portFlagsRaw: 0x00, current: 2.718, svlt: 5.22);
      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('Type-A'), findsNothing);
      await tester.pump(const Duration(seconds: 15));
      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('Type-A'), findsNothing);
      expect(find.text('STANDBY'), findsNothing);
    });
  });

  // =========================================================================
  // T2 — bit3 clear is never a negative claim.
  // =========================================================================
  testWidgets('T2 no negative "non-PD" wording when bit3 is clear',
      (tester) async {
    // 0x02 = bit1 only. Charging, bit3 clear → PD simply absent.
    await mount(tester, portFlagsRaw: 0x02, current: -0.42, svlt: 9.0);
    expect(find.text('CHARGING'), findsOneWidget);
    expect(find.text('PD'), findsNothing);
    for (final s in [
      'non-PD',
      'Non-PD',
      'not PD',
      'standard',
      'Standard',
      'ordinary',
      '5V',
      '5 V charging',
      '一般',
      '普通',
      '非 PD',
    ]) {
      expect(find.text(s), findsNothing, reason: 'no fabricated negative: $s');
    }
  });

  // =========================================================================
  // T3 — bit3 (input) / bit5 (output) never cross.
  // =========================================================================
  group('T3 PD never crossed', () {
    testWidgets('charging + bit5 set + bit3 clear → no PD (reads bit3 only)',
        (tester) async {
      // 0x22 = bit1 + bit5 (output PD). While charging we look at bit3 (clear).
      await mount(tester, portFlagsRaw: 0x22, current: -0.42, svlt: 9.0);
      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('PD'), findsNothing);
    });

    testWidgets('discharging + bit5 set → PD (reads bit5)', (tester) async {
      await mount(tester, portFlagsRaw: 0x22, current: 1.2, svlt: 5.1);
      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('PD'), findsOneWidget);
    });

    testWidgets('discharging + bit3 set + bit5 clear → no PD (never crosses)',
        (tester) async {
      // 0x0a = bit1 + bit3 (input PD). While DISCHARGING we look at bit5 (clear).
      await mount(tester, portFlagsRaw: 0x0a, current: 1.2, svlt: 5.1);
      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('PD'), findsNothing);
    });
  });

  // =========================================================================
  // T4 — b7 all-clear + nonzero current: no port badge, ever.
  // =========================================================================
  testWidgets('T4 b7==0x00 + nonzero current shows no FABRICATED port',
      (tester) async {
    // The enduring invariant across every revision of this line: a fabricated
    // port is never shown. §9's original T4 wording ("路徑未定, never 待機") was
    // overtaken by the b7==0x00 = rail-off upgrade (§3.3 obs 1 / §4.3 / §4.6),
    // then came back for this vector via the spurious-0x00 guard (2026-08-05),
    // and design 0041 Q3 finally deleted the badge it named: the row now
    // withholds the port by drawing NOTHING there. The invariant is unchanged —
    // only how "I don't know" is spelled.
    await mount(tester, portFlagsRaw: 0x00, current: 0.30, svlt: 3.95);
    expect(find.text('Type-A'), findsNothing);
    expect(find.text('Type-C'), findsNothing);
    expect(find.text('Path undetermined'), findsNothing);
    expect(find.text('STANDBY'), findsNothing);
    expect(find.text('DISCHARGING'), findsOneWidget);
  });

  // =========================================================================
  // T5 — same-burst consistency: direction and b7 from ONE sample.
  // =========================================================================
  testWidgets('T5 a later sample replaces the row wholesale — no cross-mix',
      (tester) async {
    final (_, emit) = await mount(
        tester, portFlagsRaw: 0x0a, current: -0.42, svlt: 9.14);
    // First sample: CHARGING · Type-C · PD · 9.14 V.
    expect(find.text('CHARGING'), findsOneWidget);
    expect(find.text('9.14 V'), findsOneWidget);

    // A new sample with a DIFFERENT b7 and voltage arrives.
    emit(TelemetrySample(
      timestamp: DateTime(2026, 8, 4, 14, 44),
      pvlt: 3.95,
      svlt: 5.12,
      current: 0.42,
      portFlagsRaw: 0x05,
    ));
    await tester.pump();
    await tester.pump();

    // The row is entirely the SECOND sample. The old voltage must not survive
    // next to the new port, and vice versa — no "9.14 V with undetermined".
    expect(find.text('DISCHARGING'), findsOneWidget);
    expect(find.text('Type-A'), findsOneWidget);
    expect(find.text('5.12 V'), findsOneWidget);
    expect(find.text('CHARGING'), findsNothing);
    expect(find.text('9.14 V'), findsNothing);
    expect(find.text('Type-C'), findsNothing);
    expect(find.text('Type-C'), findsNothing);
    expect(find.text('PD'), findsNothing);
  });

  // =========================================================================
  // T6 — 0x12 (bit1+bit4): Type-C, no PD, no special case.
  // =========================================================================
  testWidgets('T6 0x12 shows Type-C, no PD, and needs no bit4 special case',
      (tester) async {
    await mount(tester, portFlagsRaw: 0x12, current: -0.30, svlt: 9.0);
    expect(find.text('Type-C'), findsOneWidget);
    expect(find.text('PD'), findsNothing);
    expect(find.text('Path undetermined'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // =========================================================================
  // T7 — 0x03 (bit0+bit1): bit1 wins → Type-C only (Q10(a)).
  // =========================================================================
  testWidgets('T7 0x03 → Type-C only; bit0 never yields Type-A',
      (tester) async {
    await mount(tester, portFlagsRaw: 0x03, current: -0.30, svlt: 9.0);
    expect(find.text('Type-C'), findsOneWidget);
    expect(find.text('Type-A'), findsNothing);
    expect(find.text('Path undetermined'), findsNothing);
  });

  // =========================================================================
  // T8 — no debounce: the FIRST sample decides the frame.
  // =========================================================================
  testWidgets('T8 first-11-seconds sample decides with no debounce/delay',
      (tester) async {
    // 0x02 = bit1 set (Type-C cable inserted), bit2 clear; 19 mA is IN-BAND
    // (idle). The honest face is "Type-C · STANDBY", NOT "Type-C supplying" —
    // the badge is drawn in its outline form, which is what says "cable
    // inserted" without claiming "cable in use".
    await mount(tester, portFlagsRaw: 0x02, current: 0.019, svlt: 5.16);
    expect(find.text('STANDBY'), findsOneWidget);
    expect(find.text('Type-C'), findsOneWidget);
    // No direction from an in-band current, and no supplying claim.
    expect(find.text('DISCHARGING'), findsNothing);
    expect(find.text('CHARGING'), findsNothing);

    // No debounce: advancing the clock well past the old "11 seconds" must NOT
    // flip the row to a supplying/direction state. There is no delayed gate —
    // the one sample already decided, and nothing is waiting to change it.
    await tester.pump(const Duration(seconds: 15));
    expect(find.text('STANDBY'), findsOneWidget);
    expect(find.text('DISCHARGING'), findsNothing);
    expect(find.text('CHARGING'), findsNothing);
  });

  // =========================================================================
  // T9 — 0x4B not arrived: waiting, not a decoded zero.
  // =========================================================================
  testWidgets('T9 pre-0x4B shows waiting, never 0.00 A or --', (tester) async {
    await mount(tester, portFlagsRaw: null, current: -0.42, svlt: 9.0);
    expect(find.textContaining('Waiting for device'), findsOneWidget);
    expect(find.text('0.00 A'), findsNothing);
    expect(find.text('-- A'), findsNothing);
    expect(find.text('0.42 A'), findsNothing);
    expect(find.text('Path undetermined'), findsNothing);
  });

  // =========================================================================
  // T10 — non-power-bank renders nothing.
  // =========================================================================
  group('T10 class gating', () {
    for (final cls in [
      ProductClass.smartBattery,
      ProductClass.supercapacitor,
      ProductClass.unknown,
    ]) {
      testWidgets('${cls.name} renders nothing', (tester) async {
        await mount(tester,
            portFlagsRaw: 0x0a, current: -0.42, svlt: 9.0, cls: cls);
        expect(find.byType(PowerPathRow), findsOneWidget);
        expect(find.text('Energy Path'), findsNothing);
        expect(find.text('CHARGING'), findsNothing);
        expect(find.text('Type-C'), findsNothing);
      });
    }
  });

  // =========================================================================
  // §4.8 hook — ONLY on the "path undetermined" row while energy moves.
  // =========================================================================
  group('§4.8 hook appears only on the undetermined moving row', () {
    testWidgets('shown on undetermined + moving', (tester) async {
      // Narrowed 2026-08-05: the undetermined-and-moving row is now CHARGING
      // with bit1 clear. Discharge with bit1 clear is derived as Type-A, so
      // hooking it would ask a question already answered — on the state a bank
      // spends most of its life in.
      await mount(tester, portFlagsRaw: 0x01, current: -0.42, svlt: 5.1);
      expect(find.text('Which port is this?'), findsOneWidget);
    });

    testWidgets('NOT shown on a derived Type-A row', (tester) async {
      await mount(tester, portFlagsRaw: 0x05, current: 0.42, svlt: 5.1);
      expect(find.text('Which port is this?'), findsNothing);
    });

    testWidgets('NOT shown on a known Type-C row', (tester) async {
      await mount(tester, portFlagsRaw: 0x0a, current: -0.42, svlt: 9.14);
      expect(find.text('Which port is this?'), findsNothing);
    });

    testWidgets('NOT shown in rail-off standby', (tester) async {
      await mount(tester, portFlagsRaw: 0x00, current: -0.03, svlt: 3.95);
      expect(find.text('Which port is this?'), findsNothing);
    });

    testWidgets('NOT shown on a contradicted 0x00 burst', (tester) async {
      // Undetermined AND charging — normally the one hooked state. Suppressed:
      // an answer here would be filed against a b7 we do not believe.
      await mount(tester, portFlagsRaw: 0x00, current: -2.712, svlt: 4.92);
      expect(find.text('Path undetermined'), findsNothing);
      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('Which port is this?'), findsNothing);
    });

    testWidgets('NOT shown for in-band standby (undetermined but not moving)',
        (tester) async {
      // 0x05, in-band current → idle. Port is undetermined (nothing to
      // eliminate from when nothing moves), but the hook rides only the MOVING
      // row, so it stays away.
      await mount(tester, portFlagsRaw: 0x05, current: 0.01, svlt: 5.1);
      expect(find.text('Which port is this?'), findsNothing);
    });

    testWidgets('NOT shown while waiting for 0x4B', (tester) async {
      await mount(tester, portFlagsRaw: null, current: -0.42, svlt: 9.0);
      expect(find.text('Which port is this?'), findsNothing);
    });

    testWidgets('records a tag once, then is gone for the connection',
        (tester) async {
      final (s, _) =
          await mount(tester, portFlagsRaw: 0x01, current: -0.42, svlt: 5.1);
      final hook = find.text('Which port is this?');
      expect(hook, findsOneWidget);

      await tester.tap(hook);
      await tester.pumpAndSettle();
      expect(find.text('Type-A'), findsOneWidget);
      expect(find.text('Type-C'), findsOneWidget);
      expect(find.text('Other / not sure'), findsWidgets);

      await tester.tap(find.text('Type-A').last);
      await tester.pumpAndSettle();
      // Non-nagging: gone for this connection after one answer.
      expect(find.text('Which port is this?'), findsNothing);

      await tester.runAsync(() => s.pending.drain());
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });
  });

  // =========================================================================
  // T12 — design 0034 registry: the slot survives, unconditional.
  // =========================================================================
  test('T12 energyPath is a power-bank module and is NOT data-gated', () {
    expect(DisplayModules.powerBank.has(DisplayModule.energyPath), isTrue);
    // Unconditional: it has a waiting state, so it is never gated OUT of view.
    expect(DisplayModules.powerBank.isDataGated(DisplayModule.energyPath),
        isFalse);
    // Other classes never offer it.
    expect(DisplayModules.battery.has(DisplayModule.energyPath), isFalse);
    expect(DisplayModules.capacitor.has(DisplayModule.energyPath), isFalse);
  });

  // =========================================================================
  // T11 — l10n: retired keys gone from both .arb, kept keys present.
  // =========================================================================
  test('T11 retired USB l10n keys removed, Type-A/C kept', () {
    final root = _packageRoot().path;
    for (final f in ['lib/l10n/app_zh.arb', 'lib/l10n/app_en.arb']) {
      final text = File('$root/$f').readAsStringSync();
      for (final removed in [
        'usbPortPendingNote',
        'usbPortStateUnknown',
        'usbPortStateSupplying',
        'usbPortStateIdle',
        'usbPortsHeading',
      ]) {
        expect(text.contains('"$removed"'), isFalse,
            reason: '$removed must be gone from $f (§7)');
      }
      for (final kept in ['usbPortTypeA', 'usbPortTypeC']) {
        expect(text.contains('"$kept"'), isTrue,
            reason: '$kept must remain in $f (§7)');
      }
    }
    // No dangling reference in generated localizations either.
    final gen = File('$root/lib/l10n/app_localizations.dart').readAsStringSync();
    for (final removed in [
      'usbPortPendingNote',
      'usbPortStateUnknown',
      'usbPortStateSupplying',
      'usbPortStateIdle',
      'usbPortsHeading',
    ]) {
      expect(gen.contains(removed), isFalse,
          reason: '$removed must be regenerated out of app_localizations.dart');
    }
  });

  // =========================================================================
  // T13 — the fabricated fast-charge code table (N3) is nowhere in lib/.
  // =========================================================================
  test('T13 no QC/FCP/AFC/SFCP fast-charge codes anywhere in lib/', () {
    final libDir = Directory('${_packageRoot().path}/lib');
    final banned = ['QC2.0', 'QC3.0', 'FCP', 'AFC', 'SFCP'];
    final hits = <String>[];
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final text = entity.readAsStringSync();
      for (final code in banned) {
        if (text.contains(code)) hits.add('${entity.path}: $code');
      }
    }
    expect(hits, isEmpty, reason: 'N3: fast-charge code table is fabricated');
  });
}
