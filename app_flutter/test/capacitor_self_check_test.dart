// 檢測電容 — the button that used to send nothing (design 0082 Q1), and the two
// false alarms a self-check used to raise on our own screen (FB-102).
//
// ---------------------------------------------------------------------------
// What was wrong
// ---------------------------------------------------------------------------
//
//   1. 檢測電容 sent NO COMMAND. It reprinted the SOH / voltage numbers already
//      on screen into a snackbar. Confirmed on the wire as late as 2026-08-27:
//      a whole session with the button pressed carries no outbound write except
//      the routine polls.
//
//   2. `CapacitorStatus` named only `healthy = 5`, so a unit sitting in its
//      self-check (`0x23` = `0x07`) was badged 「無法辨識」 in amber, with an
//      advisory telling its owner to export a diagnostic log — about a unit
//      that was working. FB-102 (1).
//
//   3. A self-check drops the unit's voltage far below its resting value, so
//      the alert machine duly notified the owner
//      「欠壓・目前 5.73 V，門檻 11.47 V，已持續 3 分」. The reading was real;
//      calling it a fault was not, because the threshold it was measured
//      against was set for a unit that is not being checked. FB-102 (2).
//
// ---------------------------------------------------------------------------
// The three rules this file pins down
// ---------------------------------------------------------------------------
//
//   * the write is EXACTLY the documented mode ++ auth pair, byte for byte;
//   * the self-check phase suppresses VOLTAGE alerts, and only those, and only
//     on a unit positively read as a super-capacitor;
//   * 🔴 the app NEVER writes a unit back out of self-check — not on give-up,
//     not on any path (owner's ruling 2026-08-28). Giving up unlocks OUR
//     button and says so; it does not touch the device.
//
// CLEAN-ROOM: every expectation derives from docs/PROTOCOL.md, this project's
// own source, and our own field captures.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
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

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// 🔵 2026-11-10 (analysis 2026.11.10-002 §8–§9): every self-check / restore
/// attempt opens with a standalone auth ++ its `0x2A` read-back, byte for byte
/// the engineering-app capture.
const _authA8 = 'b82a000400a801e4db';
const _authA9 = 'b82a000400a901e4da';
const _authPoll = 'b82a01009326';
const _modeRead = 'b82301009a26';
const _checkA8 = 'b8230001069cb82a010400a801e4da';
const _checkA9 = 'b8230001069cb82a010400a901e4db';
const _restoreA8 = 'b8230001059fb82a010400a801e4da';

/// The four frames of one attempt, in wire order.
List<String> _attempt(String auth, String write) =>
    [auth, _authPoll, write, _modeRead];

/// Inert BleService that RECORDS every outbound write and can answer one, the
/// way the hardware does — the `0x23` read-back follows a mode write.
class _FakeBleService extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  /// Every frame this app tried to put on the wire, in order.
  ///
  /// 🔑 The whole point of the file: the ruling is about what is NOT written,
  /// and "not written" is only checkable against a full list.
  final List<List<int>> writes = <List<int>>[];

  /// Mode byte to report back after the next write, or null to stay silent.
  int? answerWriteWithMode;

  /// 🔵 FB-111. The `0x3A` register every emitted sample carries.
  ///
  /// 🔑 Defaults to NULL — "this unit has never answered that register" — so
  /// every test written before FB-111 keeps describing exactly the device it
  /// described then. The `0x3A`-aware paths set it explicitly.
  int? funcFlags;

  /// The dealer code every emitted sample carries — auth is derived from it.
  /// `0168…` by default; FB-115 tests switch it to a `0169…` unit.
  String dealerCode = '01680217';

  /// When set, a write answers [answerWriteWithMode] only if its auth carries
  /// this cb — a unit that accepts one credential and ignores the other.
  int? answerOnlyCb;

  /// Mode byte to report after a RESTORE write (`0x23` <- `0x05`), or null for
  /// a unit that ignores it (2026-11-10).
  int? answerRestoreWithMode;

  /// What the unit reports now, as far as this fake knows — the `0x23`
  /// read-back answers with it.
  int? _current;

  /// Extra fields every emitted sample carries, so the body under test sees a
  /// classified capacitor with a dealer code (auth is derived from it).
  TelemetrySample _sampleWith(int? mode) => TelemetrySample(
        timestamp: DateTime.now(),
        mode: mode,
        funcFlagsRaw: funcFlags,
        deviceType: kSuperCapacitorDeviceType,
        dealerCode: dealerCode,
        pvlt: 13.2,
      );

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  void emitMode(int? mode) => _telemetryOut.add(_sampleWith(mode));
  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> writeCommand(List<int> bytes, {Duration? timeout}) async {
    writes.add(List<int>.unmodifiable(bytes));
    // Only a `0x23` frame (the mode write or its read-back) moves the mode.
    // The standalone auth and its `0x2A` read-back (2026-11-10) are answered
    // by the hardware on `0x2A`, which this fake does not model.
    final hex = _hex(bytes);
    if (!hex.startsWith('b823')) return;
    if (hex.startsWith('b82301')) {
      // Read-back: report the current state, if a write ever set one.
      final now = _current;
      if (now != null) emitMode(now);
      return;
    }
    if (hex.startsWith('b8230001059f')) {
      final r = answerRestoreWithMode;
      if (r != null) {
        _current = r;
        emitMode(r);
      }
      return;
    }
    final answer = answerWriteWithMode;
    final only = answerOnlyCb;
    if (only != null) {
      final cb = only.toRadixString(16).padLeft(4, '0');
      if (!_hex(bytes).contains('b82a0104${cb}01e4')) return;
    }
    if (answer != null) {
      _current = answer;
      emitMode(answer);
    }
  }

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
  // (3) The bytes. Golden, and not paraphrased.
  // =========================================================================

  group('the self-check frame is the documented mode ++ auth pair', () {
    test('golden: b8230001069c ++ b82a010400a801e4da', () {
      // Same shape as every other mode write this app makes — one 15-byte
      // write, mode sub-frame with byte[2] = 0x00, auth sub-frame with
      // byte[2] = 0x01. Auth is derived from the unit's own dealer code, so
      // the owner types nothing (`releaseAuthFromDealerCode`).
      final creds = releaseAuthFromDealerCode('01680217')!;
      final bytes =
          const CommandBuilder().switchMode(ModeArg.capacitorSelfCheck, creds);
      expect(_hex(bytes), 'b8230001069cb82a010400a801e4da');
      expect(bytes, hasLength(15));
    });

    test('the two sub-frames, split where the capture splits them', () {
      final creds = releaseAuthFromDealerCode('01680217')!;
      final bytes =
          const CommandBuilder().switchMode(ModeArg.capacitorSelfCheck, creds);
      expect(_hex(bytes.sublist(0, 6)), 'b8230001069c', reason: '0x23 LEN 1');
      expect(_hex(bytes.sublist(6)), 'b82a010400a801e4da', reason: '0x2A LEN 4');
    });

    test('the mode argument is 0x06 — not symbolic only', () {
      // A symbolic-only assertion would still pass if the constant were
      // renumbered, and this number IS the command.
      expect(ModeArg.capacitorSelfCheck, 0x06);
      // And it is not one of the pack codes, which is what lets the read side
      // key on it safely.
      expect(ModeArg.capacitorSelfCheck, isNot(ModeArg.unlock));
      expect(ModeArg.capacitorSelfCheck, isNot(ModeArg.antiTheft));
      expect(ModeArg.capacitorSelfCheck, isNot(ModeArg.cutOff));
    });

    test('auth is NOT optional on this write', () {
      // Every capture of this command carries the auth sub-frame in the same
      // write. A bare mode frame is 6 bytes; the thing we send is 15.
      final creds = releaseAuthFromDealerCode('01680217')!;
      expect(const CommandBuilder().modeSet(ModeArg.capacitorSelfCheck),
          hasLength(6));
      expect(
          const CommandBuilder().switchMode(ModeArg.capacitorSelfCheck, creds),
          hasLength(15));
    });
  });

  // =========================================================================
  // (2) FB-102 (2) — the self-check phase must not raise an under-voltage
  // =========================================================================

  group('FB-102 (2) — a self-check is not an under-voltage', () {
    const dev = 'B4:52:A9:AB:AC:0F';
    final wrongClock = DateTime.utc(2026, 3, 1);

    TelemetrySample sample({
      required double pvlt,
      required int mode,
      int deviceType = kSuperCapacitorDeviceType,
      int? tempC,
    }) =>
        TelemetrySample(
          timestamp: wrongClock,
          pvlt: pvlt,
          temperatureC: tempC,
          mode: mode,
          deviceType: deviceType,
        );

    /// The unit from the field report: its own `0x2B` puts under-voltage at
    /// 11.47 V, and during the check it read 5.83.
    final capacitor = resolveThresholds(
      reported: TelemetrySample(
        timestamp: wrongClock,
        warnOv: 15.0,
        warnUv: 11.47,
        warnOt: 80,
        deviceType: kSuperCapacitorDeviceType,
      ),
      wireClass: ProductClass.supercapacitor,
    );
    final battery = resolveThresholds(
      reported: TelemetrySample(
        timestamp: wrongClock,
        warnOv: 15.0,
        warnUv: 11.47,
        warnOt: 80,
        deviceType: kSmartBatteryDeviceType,
      ),
      wireClass: ProductClass.smartBattery,
    );

    const open = AlertGate(alertsEnabled: true, deviceSaved: true);

    List<AlertEmission> feed(
      AlertEvaluator e,
      TelemetrySample s, {
      AlertThresholds? thresholds,
    }) =>
        e.fold(
          deviceId: dev,
          sample: s,
          thresholds: thresholds ?? capacitor,
          gate: open,
        );

    test('the fixture is not vacuous: 5.83 V DOES fire when not self-checking',
        () {
      // 🔑 Without this the suppression test would pass by evaluating nothing.
      expect(capacitor[AlertKind.underVoltage].isSet, isTrue);
      fakeAsync((async) {
        final e = AlertEvaluator();
        expect(feed(e, sample(pvlt: 5.83, mode: CapacitorStatus.healthy)),
            isEmpty);
        async.elapse(const Duration(seconds: 6));
        final out = feed(e, sample(pvlt: 5.83, mode: CapacitorStatus.healthy));
        expect(out, hasLength(1));
        expect(out.single.kind, AlertKind.underVoltage);
      });
    });

    test('the same reading during a self-check says NOTHING, ever', () {
      for (final mode in [
        CapacitorStatus.selfCheckStarting,
        CapacitorStatus.selfCheckStarting,
      ]) {
        fakeAsync((async) {
          final e = AlertEvaluator();
          for (var i = 0; i < 40; i++) {
            expect(feed(e, sample(pvlt: 5.83, mode: mode)), isEmpty,
                reason: 'mode 0x${mode.toRadixString(16)}');
            async.elapse(const Duration(seconds: 10));
          }
          expect(e.phaseOf(dev, AlertKind.underVoltage), AlertPhase.normal);
          expect(e.activeAlerts(dev), isEmpty);
        });
      }
    });

    test('an event already OPEN closes when the check starts', () {
      // Reset, not merely skip: the banner is driven by the phase, so a
      // skipped kind would keep showing a warning nothing is feeding.
      fakeAsync((async) {
        final e = AlertEvaluator();
        feed(e, sample(pvlt: 5.83, mode: CapacitorStatus.healthy));
        async.elapse(const Duration(seconds: 6));
        expect(feed(e, sample(pvlt: 5.83, mode: CapacitorStatus.healthy)),
            hasLength(1));
        expect(e.activeAlerts(dev), {AlertKind.underVoltage});

        feed(e, sample(pvlt: 5.83, mode: CapacitorStatus.selfCheckStarting));
        expect(e.phaseOf(dev, AlertKind.underVoltage), AlertPhase.normal);
        expect(e.activeAlerts(dev), isEmpty);
      });
    });

    test('temperature is NOT suppressed — the check does not heat the unit',
        () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        feed(
            e,
            sample(
                pvlt: 5.83,
                tempC: 95,
                mode: CapacitorStatus.selfCheckStarting));
        async.elapse(const Duration(seconds: 6));
        final out = feed(
            e,
            sample(
                pvlt: 5.83,
                tempC: 95,
                mode: CapacitorStatus.selfCheckStarting));
        expect(out.map((e) => e.kind), [AlertKind.overTemperature],
            reason: 'an over-temperature during a self-check is still one');
      });
    });

    test('a BATTERY is never suppressed, whatever byte it reports', () {
      // Defensive, and deliberately so: a battery cannot report 0x06/0x07 (its
      // code space is 0/1/2), but the suppression must not be reachable by a
      // byte alone. Erring LOUD is the right direction for an alarm.
      fakeAsync((async) {
        final e = AlertEvaluator();
        final s = sample(
          pvlt: 5.83,
          mode: CapacitorStatus.selfCheckStarting,
          deviceType: kSmartBatteryDeviceType,
        );
        feed(e, s, thresholds: battery);
        async.elapse(const Duration(seconds: 6));
        expect(feed(e, s, thresholds: battery), hasLength(1));
      });
    });

    test('an UNCLASSIFIED unit is never suppressed either', () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        final s = TelemetrySample(
          timestamp: wrongClock,
          pvlt: 5.83,
          mode: CapacitorStatus.selfCheckStarting,
          // No device-type byte: nothing has been positively read.
        );
        // Thresholds still come from a capacitor's registers, so the only
        // thing under test is the class half of the gate.
        feed(e, s);
        async.elapse(const Duration(seconds: 6));
        expect(feed(e, s), hasLength(1));
      });
    });
  });

  // =========================================================================
  // (1)+(3) The button — widget level
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
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
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
      fakeBle.emitMode(mode);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  ControlButton buttonNamed(WidgetTester tester, String label) =>
      tester.widget<ControlButton>(
        find.byWidgetPredicate((w) => w is ControlButton && w.label == label),
      );

  /// Advance the flow's 500 ms polls on the fake clock. 120 steps is 72 s of
  /// clock, which runs the whole give-up window out — and costs no real time,
  /// which is exactly why `_waitFor` reads `clock.now()`.
  Future<void> step(WidgetTester tester, {int times = 6}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
  }

  group('檢測電容 — the button now sends the command', () {
    testWidgets('cancelling writes NOTHING', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, CapacitorStatus.healthy);
      fakeBle.writes.clear();

      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Check Capacitor'));
      await tester.pumpAndSettle();
      // Q6: a confirmation that names the consequence, in the same AlertDialog
      // shape the cut-off confirmation uses — not a snackbar.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Start capacitor self-check'), findsOneWidget);
      expect(find.textContaining('voltage drops'), findsOneWidget);
      // ⚠️ and it must NOT promise a duration — see `_selfCheckWatchLimit`.
      expect(find.textContaining('10 seconds'), findsNothing);
      expect(find.textContaining('ten seconds'), findsNothing);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fakeBle.writes, isEmpty,
          reason: 'backing out of the dialog is not a command');
    });

    testWidgets('confirming writes the mode ++ auth pair, and its read-back',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, CapacitorStatus.healthy);
      fakeBle.writes.clear();
      // The device answers the write the way the hardware does.
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckStarting;

      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Check Capacitor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I understand — start it'));
      await tester.pump();
      await step(tester, times: 120);

      // Standalone auth ++ its read-back first (2026-11-10), then the
      // documented pair, then the `0x23` read-back the release path also pairs
      // with — two READS, neither can take the device anywhere.
      expect(fakeBle.writes.map(_hex), _attempt(_authA8, _checkA8),
          reason: 'byte for byte, the engineering-app sequence');
    });

    testWidgets(
        '🔴 Q9: giving up unlocks OUR button and writes nothing to the device',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, CapacitorStatus.healthy);
      fakeBle.writes.clear();
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckStarting;

      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Check Capacitor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I understand — start it'));
      await tester.pump();
      // The unit stays in self-check — the outcome two of three captures had,
      // one of them across three reconnections and 23 minutes. Let the watch
      // run its whole course without the device ever coming back, and stop the
      // moment it gives up (a snackbar has its own lifetime, so overshooting
      // would dismiss the very message under test).
      final gaveUp = find.textContaining('has not reported normal yet');
      for (var i = 0; i < 200 && gaveUp.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }

      // 🔴 THE ruling (still in force for a RUNNING check — 2026-11-10 only
      // opened a FAILED one). Exactly one attempt left this app. Nothing wrote
      // `0x23` <- `0x05`.
      expect(fakeBle.writes.map(_hex), _attempt(_authA8, _checkA8),
          reason: 'the app must never take a unit out of self-check');
      for (final w in fakeBle.writes) {
        expect(_hex(w), isNot(contains('b8230001059f')),
            reason: 'that frame is the one this ruling forbids');
      }

      // 🔲 And the copy has to be honest about it. "Finished" and "cancelled"
      // are both claims about a device that is, as far as we can tell, still
      // in self-check — the accepted cost of the ruling, stated rather than
      // hidden.
      expect(find.textContaining('has not reported normal yet'), findsOneWidget);
      expect(find.textContaining('has not sent anything to take it out'),
          findsOneWidget);
      expect(find.textContaining('finished'), findsNothing);
      expect(find.textContaining('cancelled'), findsNothing);
    });

    testWidgets('the badge says busy, not broken, and the button locks',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, CapacitorStatus.selfCheckStarting);

      // FB-102 (1): this is the badge a working unit was shown as
      // 「無法辨識」 in amber.
      expect(find.text('Self-check'), findsOneWidget);
      expect(find.text('Unrecognised'), findsNothing);
      // Q5: no second `0x06` on top of a check that is already running.
      expect(buttonNamed(tester, 'Check Capacitor').onPressed, isNull);
      // And the advisory explains the low readings without claiming a fault.
      expect(find.textContaining('self-check is running'), findsOneWidget);
    });

    testWidgets('a healthy unit gets the button back', (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, CapacitorStatus.healthy);

      expect(buttonNamed(tester, 'Check Capacitor').onPressed, isNotNull);
      expect(find.text('Normal'), findsOneWidget);
    });
  });

  // =========================================================================
  // 🔵 FB-115, extended — the self-check takes the release's auth plan
  // =========================================================================
  //
  // WHAT WAS WRONG. The self-check derived cb from the dealer code and sent
  // only that. On a `0169…` unit it is `0x00A9`, the value FB-115 had shown
  // never releases a `0169…` pack; FB-115 fixed 復電 and left this writer
  // behind. Capture 2026.11.10/001 — a `0169…` capacitor — ended in
  // 「沒有回報進入檢測模式」. Owner's ruling 2026-11-10: fold into FB-115.

  group('FB-115 — self-check auth: 0x00A8 first, derived cb once after', () {
    final noResponse = find.textContaining('did not enter self-check');

    Future<void> press(WidgetTester tester) async {
      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Check Capacitor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I understand — start it'));
      await tester.pump();
    }

    Future<void> untilNoResponse(WidgetTester tester) async {
      for (var i = 0; i < 60 && noResponse.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
    }

    Future<AppServices> online(WidgetTester tester, String dealer) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });
      fakeBle.dealerCode = dealer;
      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, CapacitorStatus.healthy);
      fakeBle.writes.clear();
      return s;
    }

    testWidgets('0168 unit that ignores it: one attempt — 4 frames',
        (tester) async {
      await online(tester, '01680217');
      await press(tester);
      await untilNoResponse(tester);

      expect(fakeBle.writes.map(_hex), _attempt(_authA8, _checkA8),
          reason: 'derived cb IS 0x00A8 on 0168 — no second credential');
      expect(noResponse, findsOneWidget);
    });

    testWidgets('0169 unit: the FIRST frame carries 0x00A8, not 0x00A9',
        (tester) async {
      await online(tester, '01690217');
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckStarting;
      fakeBle.answerOnlyCb = 0x00A8;
      await press(tester);
      await step(tester, times: 120);

      expect(fakeBle.writes.map(_hex), _attempt(_authA8, _checkA8),
          reason: 'entered on A8 ⇒ the derived A9 is never sent');
      expect(noResponse, findsNothing);
    });

    testWidgets('0169 unit that only takes the derived cb: A8, then A9 once',
        (tester) async {
      await online(tester, '01690217');
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckStarting;
      fakeBle.answerOnlyCb = 0x00A9;
      await press(tester);
      await step(tester, times: 120);

      expect(fakeBle.writes.map(_hex), [
        ..._attempt(_authA8, _checkA8),
        ..._attempt(_authA9, _checkA9),
      ]);
      expect(noResponse, findsNothing);
    });

    testWidgets('🔴 0169 unit that ignores both: 2 credentials, no third, '
        'and nothing writes it back to 0x05', (tester) async {
      await online(tester, '01690217');
      await press(tester);
      await untilNoResponse(tester);

      expect(fakeBle.writes, hasLength(8),
          reason: 'one attempt (4 frames) per credential — not retried');
      for (final w in fakeBle.writes) {
        expect(_hex(w), isNot(contains('b8230001059f')));
      }
      expect(noResponse, findsOneWidget);
    });
  });

  // =========================================================================
  // 🔵 FB-111 — 「檢測完成」 while the output was still cut
  // =========================================================================
  //
  // WHAT WAS WRONG. The unlock read `0x23` alone. `docs/devices/supercapacitor.md`
  // recorded `0x23`=`05` ⟺ `0x3A` in its bit-0 group at **166/166, zero
  // counter-examples**, so one register was believed to stand for both. Capture
  // 2026.09.03/002 — the first in the corpus where OUR app sent the self-check —
  // has five counter-examples in one connection:
  //
  //     12:35:17.526  TX   self-check command
  //     12:35:17.948  RX   0x3A = 5800   → bit-3 group
  //     12:35:23.166  RX   0x23 = 05     "normal" again   ← we unlocked here
  //     12:35:28.779  RX   0x3A = 5100   → bit-0 group again  ← 5.61 s LATER
  //
  // For those 5.61 seconds the app told the owner 「檢測結束 —— 裝置已回報正常」
  // about a unit that was still reporting a state it had not been in when the
  // check started. ⛔ What that state IS remains unestablished (B1): the corpus
  // shows the two groups exist and that `0x23` cannot see the difference, and
  // says nothing about which one means the output is carrying its load.
  //
  // 🔑 THE SHAPE, so it is not re-learned a third time: two independent
  // registers describing one physical event do not move together, and an
  // equivalence with no counter-example is not an equivalence — it is a
  // sample. The one the user acts on is the one carrying the load.

  group('FB-111 — CapacitorFunctionFlags reads only the shapes we observed',
      () {
    // 🔑 These pin VALUE → GROUP, which is a fact our own captures establish,
    // and deliberately nothing beyond it. ~~value → output live / output cut~~
    // was what this group used to assert; the polarity behind those labels came
    // from outside our captures and has been removed (B1). Swapping the two bit
    // constants still turns every expectation here red, because the partition
    // itself is measured — 396,205 of 396,205 frames carry exactly one bit.
    test('every capacitor 0x3A value in the corpus decodes to its group', () {
      // Left column is the wire value as stored (big-endian u16 of the two
      // payload bytes). These five are the complete observed set.
      expect(CapacitorFunctionFlags.group(0x5100), CapacitorFlagGroup.bit0,
          reason: '0x5100 — device type 0x17');
      expect(CapacitorFunctionFlags.group(0x4100), CapacitorFlagGroup.bit0,
          reason: '0x4100 — device type 0x18');
      expect(CapacitorFunctionFlags.group(0x7101), CapacitorFlagGroup.bit0,
          reason: '0x7101 — byte 0 = 0x71, byte 1 = 0x01');
      expect(CapacitorFunctionFlags.group(0x5800), CapacitorFlagGroup.bit3,
          reason: '0x5800 — device type 0x17');
      expect(CapacitorFunctionFlags.group(0x7801), CapacitorFlagGroup.bit3,
          reason: '0x7801 — byte 0 = 0x78, byte 1 = 0x01');
    });

    test('the two groups are exclusive, and named after their own bit', () {
      // The one structural claim the corpus supports: bit 0 and bit 3 partition
      // the observed set. Nothing here says which group is which physically.
      expect(CapacitorFunctionFlags.bitGroup0, 0x01);
      expect(CapacitorFunctionFlags.bitGroup3, 0x08);
      expect(
          CapacitorFunctionFlags.bitGroup0 &
              CapacitorFunctionFlags.bitGroup3,
          0,
          reason: 'the two bits must be distinct, or the partition is not one');
      expect(CapacitorFlagGroup.values, hasLength(2));
    });

    test('anything outside those shapes is UNKNOWN, never guessed', () {
      // 🔑 Null is a third answer, not a failure. "We have no reading" and "it
      // is in the other group" lead to opposite copy on screen.
      expect(CapacitorFunctionFlags.group(null), isNull,
          reason: 'never reported');
      expect(CapacitorFunctionFlags.group(0x0000), isNull,
          reason: 'neither bit');
      expect(CapacitorFunctionFlags.group(0x0900), isNull, reason: 'both bits');
    });

    test('it reads byte 0, not the whole word', () {
      // Byte 1 varies independently (`7101` vs `7100`) and carries nothing we
      // have decoded, so it must not reach the answer.
      expect(CapacitorFunctionFlags.group(0x5100),
          CapacitorFunctionFlags.group(0x51FF));
      expect(CapacitorFunctionFlags.group(0x5800),
          CapacitorFunctionFlags.group(0x58FF));
    });
  });

  group('FB-111 — 0x3A reaches the sample without touching storage', () {
    TelemetrySample decode(List<int> payload) {
      final d = TelemetryDecoder();
      final frame = InboundFrame(
        selector: Selectors.functionFlags,
        flag: 0x01,
        len: payload.length,
        payload: Uint8List.fromList(payload),
        checksumOk: true,
      );
      return d.ingest(frame);
    }

    test('the two payload bytes arrive as one big-endian word', () {
      expect(decode([0x51, 0x00]).funcFlagsRaw, 0x5100);
      expect(decode([0x58, 0x00]).funcFlagsRaw, 0x5800);
      expect(decode([0x71, 0x01]).funcFlagsRaw, 0x7101);
    });

    test('a short frame is dropped rather than zero-padded', () {
      // A fabricated `0x0000` would decode to "neither group bit", i.e. a state
      // the app would then have to explain. Better to have no reading.
      expect(decode([0x51]).funcFlagsRaw, isNull);
      expect(decode(const []).funcFlagsRaw, isNull);
    });

    test('it is NOT persisted — no schema change, no history column', () {
      // It is a live-link fact ("is this unit's output cut right now"), and
      // nothing reads it back out of a stored row.
      final s = decode([0x51, 0x00]);
      expect(s.funcFlagsRaw, 0x5100);
      expect(s.toMap().containsKey('func_flags'), isFalse);
      expect(s.toMap().values.contains(0x5100), isFalse);
    });
  });

  group('FB-111 — the unlock waits for BOTH registers', () {
    testWidgets(
        '🔴 0x23 says normal while 0x3A is still in the other group ⇒ '
        'NOT "finished"',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      fakeBle.funcFlags = 0x5100; // bit-0 group, before anything happens
      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, CapacitorStatus.healthy);
      fakeBle.writes.clear();
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckStarting;

      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Check Capacitor'));
      await tester.pumpAndSettle();
      // The command goes out with 0x3A about to leave its baseline group,
      // exactly as the wire shows it (0x3A = 5800 arrives 422 ms after the
      // write).
      fakeBle.funcFlags = 0x5800;
      await tester.tap(find.text('I understand — start it'));
      await tester.pump();
      await step(tester, times: 4);

      // The unit reports normal again — and the old code stopped here.
      fakeBle.emitMode(CapacitorStatus.healthy);
      await step(tester, times: 4);
      expect(find.textContaining('Self-check finished'), findsNothing,
          reason: '0x3A is still in the other group; "finished" would claim '
              'every register we can see is back where the check found it');

      // Let the watch run out with `0x3A` never returning to its earlier group.
      final notBack =
          find.textContaining('has not gone back to the value it had');
      for (var i = 0; i < 200 && notBack.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(notBack, findsOneWidget);
      // ⛔ Not silent, and not a claim of success — but also NOT a write. Rule 3
      // is untouched by FB-111.
      expect(find.textContaining('finished'), findsNothing);
      expect(fakeBle.writes, hasLength(4),
          reason: 'the self-check pair and its read-back, and nothing else');
    });

    testWidgets('both registers back ⇒ finished, without waiting out the window',
        (tester) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      fakeBle.funcFlags = 0x5100;
      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, CapacitorStatus.healthy);
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckStarting;

      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Check Capacitor'));
      await tester.pumpAndSettle();
      fakeBle.funcFlags = 0x5800;
      await tester.tap(find.text('I understand — start it'));
      await tester.pump();
      await step(tester, times: 4);

      // The captured order: 0x23 first, 0x3A back to its baseline group about
      // five seconds later.
      fakeBle.emitMode(CapacitorStatus.healthy);
      await step(tester, times: 4);
      fakeBle.funcFlags = 0x5100;
      fakeBle.emitMode(CapacitorStatus.healthy);

      final done = find.textContaining('Self-check finished');
      // Well inside the 30 s limit: ~12 s of clock. If the unlock had started
      // depending on the window expiring, this is what would catch it.
      for (var i = 0; i < 20 && done.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(done, findsOneWidget);
      expect(find.textContaining('has not gone back to the value it had'),
          findsNothing);
    });

    testWidgets(
        '🔑 the gate is SYMMETRIC — it needs no polarity at all',
        (tester) async {
      // 🔴 The reason B1 could remove the polarity without losing FB-111. This
      // unit rests in the bit-3 group and moves to bit-0 during the check —
      // the exact mirror of the captured unit. The old code read bit-0 as
      // "output live" and would have called this **finished**; comparing
      // against the pre-check reading calls it what it is: a register that has
      // not come back.
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      fakeBle.funcFlags = 0x5800; // baseline: the bit-3 group
      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, CapacitorStatus.healthy);
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckStarting;

      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Check Capacitor'));
      await tester.pumpAndSettle();
      fakeBle.funcFlags = 0x5100; // it leaves the baseline group…
      await tester.tap(find.text('I understand — start it'));
      await tester.pump();
      await step(tester, times: 4);

      // …and `0x23` comes back while it is still away, exactly as in the
      // captured order — only with the two groups the other way round.
      fakeBle.emitMode(CapacitorStatus.healthy);
      await step(tester, times: 4);
      expect(find.textContaining('Self-check finished'), findsNothing,
          reason: 'whichever group it rested in, it has not returned to it');

      final notBack =
          find.textContaining('has not gone back to the value it had');
      for (var i = 0; i < 200 && notBack.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(notBack, findsOneWidget);
      expect(fakeBle.writes, hasLength(4),
          reason: 'the self-check pair and its read-back, and nothing else');
    });

    testWidgets('🔑 back to the baseline group ⇒ finished, either way round',
        (tester) async {
      // The same mirrored unit, this time returning. Pins that "back where it
      // started" unlocks for BOTH groups — a gate that only unlocked on bit-0
      // would leave this owner watching the whole window run out.
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      fakeBle.funcFlags = 0x5800;
      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, CapacitorStatus.healthy);
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckStarting;

      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Check Capacitor'));
      await tester.pumpAndSettle();
      fakeBle.funcFlags = 0x5100;
      await tester.tap(find.text('I understand — start it'));
      await tester.pump();
      await step(tester, times: 4);

      fakeBle.emitMode(CapacitorStatus.healthy);
      await step(tester, times: 4);
      fakeBle.funcFlags = 0x5800; // back to where the check found it
      fakeBle.emitMode(CapacitorStatus.healthy);

      final done = find.textContaining('Self-check finished');
      for (var i = 0; i < 20 && done.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(done, findsOneWidget);
      expect(find.textContaining('has not gone back to the value it had'),
          findsNothing);
    });

    testWidgets(
        '🔑 a unit that never reports 0x3A is not held hostage by it',
        (tester) async {
      // The FB-50 / FB-52 shape, and the reason `allOpen` is three-valued: a
      // gate keyed on a register the device does not answer is a state with no
      // exit. Batteries and older firmware are exactly that case.
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      fakeBle.funcFlags = null; // never answers 0x3A
      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, CapacitorStatus.healthy);
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckStarting;

      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Check Capacitor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I understand — start it'));
      await tester.pump();
      await step(tester, times: 4);
      fakeBle.emitMode(CapacitorStatus.healthy);

      final done = find.textContaining('Self-check finished');
      for (var i = 0; i < 20 && done.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(done, findsOneWidget,
          reason: 'no 0x3A reading must mean "do not gate", never "not back"');
    });

    testWidgets('🔴 the watch still ENDS — the button never locks forever',
        (tester) async {
      // The give-up path with BOTH registers stuck. Whatever the copy, the
      // guarantee is that the user gets an answer and the control comes back.
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });

      fakeBle.funcFlags = 0x5800;
      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, CapacitorStatus.healthy);
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckStarting;

      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Check Capacitor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I understand — start it'));
      await tester.pump();

      final gaveUp = find.textContaining('has not reported normal yet');
      for (var i = 0; i < 200 && gaveUp.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
      // `stillRunning`, not `flagNotBack`: `0x23` never came back either, and
      // `0x3A` never LEFT the group it started in, so the honest sentence is
      // the older one.
      expect(gaveUp, findsOneWidget);
      expect(find.textContaining('has not gone back to the value it had'),
          findsNothing);
      expect(fakeBle.writes, hasLength(4));
    });
  });


  // =========================================================================
  // 🔵 2026-11-10 — a FAILED check (0x07 / 0x0A) and restoring the output
  // =========================================================================
  //
  // Owner's ruling 2026-11-10, narrowing 2026-08-28's "never write a unit
  // back": A — a check THIS app started that ends in a fail code is followed
  // once, automatically, by `0x23` <- `0x05`; B — a unit FOUND holding a fail
  // code gets a button, and nothing is sent until the user confirms. A unit in
  // self-check (`0x06`) is still never written back (the Q9 test above).
  group('2026-11-10 — failed self-check: restore A (auto) / B (button)', () {
    Future<AppServices> onlineAt(WidgetTester tester, int mode) async {
      final s = await makeServices(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await s.dispose();
      });
      await pumpUnder(tester, s, const CapacitorControls());
      await goOnline(tester, mode);
      fakeBle.writes.clear();
      return s;
    }

    Future<void> pressCheck(WidgetTester tester) async {
      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Check Capacitor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I understand — start it'));
      await tester.pump();
    }

    Future<void> until(WidgetTester tester, Finder f) async {
      for (var i = 0; i < 80 && f.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    final restored = find.textContaining('output has been restored');
    final notRestored = find.textContaining('has not returned to normal output');

    for (final fail in [
      CapacitorStatus.selfCheckFailedGen2,
      CapacitorStatus.selfCheckFailedGen3,
    ]) {
      testWidgets('A: fail code 0x${fail.toRadixString(16)} ⇒ one restore, '
          'then "restored"', (tester) async {
        await onlineAt(tester, CapacitorStatus.healthy);
        fakeBle.answerWriteWithMode = fail;
        fakeBle.answerRestoreWithMode = CapacitorStatus.healthy;
        await pressCheck(tester);
        await until(tester, restored);

        expect(fakeBle.writes.map(_hex), [
          ..._attempt(_authA8, _checkA8),
          ..._attempt(_authA8, _restoreA8),
        ], reason: 'the check, then exactly one restore with the same auth');
        expect(restored, findsOneWidget);
      });
    }

    testWidgets('A: a unit that ignores the restore ⇒ ONE restore, honest copy',
        (tester) async {
      await onlineAt(tester, CapacitorStatus.healthy);
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckFailedGen2;
      await pressCheck(tester);
      await until(tester, notRestored);

      final restores =
          fakeBle.writes.map(_hex).where((w) => w == _restoreA8).length;
      expect(restores, 1, reason: 'the restore is not retried');
      expect(notRestored, findsOneWidget);
      expect(restored, findsNothing);
    });

    testWidgets('A: a check that PASSES writes no restore', (tester) async {
      await onlineAt(tester, CapacitorStatus.healthy);
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckStarting;
      await pressCheck(tester);
      await step(tester, times: 4);
      // The unit comes back on its own.
      await tester.runAsync(() async {
        fakeBle.emitMode(CapacitorStatus.healthy);
        await Future<void>.delayed(Duration.zero);
      });
      await until(tester, find.textContaining('Self-check finished'));

      expect(fakeBle.writes.map(_hex), _attempt(_authA8, _checkA8));
    });

    testWidgets('B: a unit found failed shows the button and locks the check',
        (tester) async {
      await onlineAt(tester, CapacitorStatus.selfCheckFailedGen2);

      expect(find.text('Self-check failed'), findsOneWidget);
      expect(buttonNamed(tester, 'Restore capacitor output').onPressed,
          isNotNull);
      expect(buttonNamed(tester, 'Check Capacitor').onPressed, isNull,
          reason: 'restore first; a fail code would read as an instant verdict');
      expect(fakeBle.writes, isEmpty, reason: 'nothing is sent on its own');
    });

    testWidgets('B: cancelling the restore dialog writes NOTHING',
        (tester) async {
      await onlineAt(tester, CapacitorStatus.selfCheckFailedGen2);
      await tester.tap(find.byWidgetPredicate((w) =>
          w is ControlButton && w.label == 'Restore capacitor output'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(fakeBle.writes, isEmpty);
    });

    testWidgets('B: confirming sends one restore and says so', (tester) async {
      await onlineAt(tester, CapacitorStatus.selfCheckFailedGen2);
      fakeBle.answerRestoreWithMode = CapacitorStatus.healthy;
      await tester.tap(find.byWidgetPredicate((w) =>
          w is ControlButton && w.label == 'Restore capacitor output'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore output'));
      await tester.pump();
      final done = find.text('Capacitor output restored.');
      await until(tester, done);

      expect(fakeBle.writes.map(_hex), _attempt(_authA8, _restoreA8));
      expect(done, findsOneWidget);
    });

    testWidgets('a healthy or running unit has no restore button',
        (tester) async {
      await onlineAt(tester, CapacitorStatus.selfCheckStarting);
      expect(
          find.byWidgetPredicate((w) =>
              w is ControlButton && w.label == 'Restore capacitor output'),
          findsNothing,
          reason: '0x06 is a running check — never written back');
    });
  });
}
