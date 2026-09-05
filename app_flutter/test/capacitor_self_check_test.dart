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
  /// described then. The MOS-aware paths set it explicitly.
  int? funcFlags;

  /// Extra fields every emitted sample carries, so the body under test sees a
  /// classified capacitor with a dealer code (auth is derived from it).
  TelemetrySample _sampleWith(int? mode) => TelemetrySample(
        timestamp: DateTime.now(),
        mode: mode,
        funcFlagsRaw: funcFlags,
        deviceType: kSuperCapacitorDeviceType,
        dealerCode: '01680217',
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
    final answer = answerWriteWithMode;
    if (answer != null) emitMode(answer);
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
        CapacitorStatus.selfCheckRunning,
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

        feed(e, sample(pvlt: 5.83, mode: CapacitorStatus.selfCheckRunning));
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
                mode: CapacitorStatus.selfCheckRunning));
        async.elapse(const Duration(seconds: 6));
        final out = feed(
            e,
            sample(
                pvlt: 5.83,
                tempC: 95,
                mode: CapacitorStatus.selfCheckRunning));
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
          mode: CapacitorStatus.selfCheckRunning,
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
          mode: CapacitorStatus.selfCheckRunning,
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
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckRunning;

      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Check Capacitor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I understand — start it'));
      await tester.pump();
      await step(tester, times: 120);

      expect(_hex(fakeBle.writes.first), 'b8230001069cb82a010400a801e4da',
          reason: 'byte for byte, the documented pair');
      // Second is the `0x23` read-back the release path also pairs with — a
      // READ, so it cannot take the device anywhere.
      expect(_hex(fakeBle.writes[1]), 'b82301009a26');
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
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckRunning;

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

      // 🔴 THE ruling. Exactly two frames left this app: the self-check pair
      // and its read-back. Nothing wrote `0x23` <- `0x05`, on any path.
      expect(fakeBle.writes, hasLength(2),
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
      await goOnline(tester, CapacitorStatus.selfCheckRunning);

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

  group('FB-111 — CapacitorMos reads only the shapes we have observed', () {
    // 🔑 These pin VALUE → GROUP, which is a fact our own captures establish,
    // and deliberately nothing beyond it. ~~value → output live / output cut~~
    // was what this group used to assert; the polarity behind those labels came
    // from outside our captures and has been removed (B1). Swapping the two bit
    // constants still turns every expectation here red, because the partition
    // itself is measured — 396,205 of 396,205 frames carry exactly one bit.
    test('every capacitor 0x3A value in the corpus decodes to its group', () {
      // Left column is the wire value as stored (big-endian u16 of the two
      // payload bytes). These five are the complete observed set.
      expect(CapacitorMos.group(0x5100), CapacitorMosGroup.bit0,
          reason: '0x5100 — device type 0x17');
      expect(CapacitorMos.group(0x4100), CapacitorMosGroup.bit0,
          reason: '0x4100 — device type 0x18');
      expect(CapacitorMos.group(0x7101), CapacitorMosGroup.bit0,
          reason: '0x7101 — byte 0 = 0x71, byte 1 = 0x01');
      expect(CapacitorMos.group(0x5800), CapacitorMosGroup.bit3,
          reason: '0x5800 — device type 0x17');
      expect(CapacitorMos.group(0x7801), CapacitorMosGroup.bit3,
          reason: '0x7801 — byte 0 = 0x78, byte 1 = 0x01');
    });

    test('the two groups are exclusive, and named after their own bit', () {
      // The one structural claim the corpus supports: bit 0 and bit 3 partition
      // the observed set. Nothing here says which group is which physically.
      expect(CapacitorMos.bitGroup0, 0x01);
      expect(CapacitorMos.bitGroup3, 0x08);
      expect(CapacitorMos.bitGroup0 & CapacitorMos.bitGroup3, 0,
          reason: 'the two bits must be distinct, or the partition is not one');
      expect(CapacitorMosGroup.values, hasLength(2));
    });

    test('anything outside those shapes is UNKNOWN, never guessed', () {
      // 🔑 Null is a third answer, not a failure. "We have no reading" and "it
      // is in the other group" lead to opposite copy on screen.
      expect(CapacitorMos.group(null), isNull, reason: 'never reported');
      expect(CapacitorMos.group(0x0000), isNull, reason: 'neither bit');
      expect(CapacitorMos.group(0x0900), isNull, reason: 'both bits');
    });

    test('it reads byte 0, not the whole word', () {
      // Byte 1 varies independently (`7101` vs `7100`) and carries nothing we
      // have decoded, so it must not reach the answer.
      expect(CapacitorMos.group(0x5100), CapacitorMos.group(0x51FF));
      expect(CapacitorMos.group(0x5800), CapacitorMos.group(0x58FF));
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
      // A fabricated `0x0000` would decode to "neither MOS bit", i.e. a state
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
        '🔴 0x23 says normal while the MOS is still cut ⇒ NOT "finished"',
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
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckRunning;

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

      // Let the watch run out with the MOS never reopening.
      final notBack =
          find.textContaining('has not gone back to the value it had');
      for (var i = 0; i < 200 && notBack.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(notBack, findsOneWidget);
      // ⛔ Not silent, and not a claim of success — but also NOT a write. Rule 3
      // is untouched by FB-111.
      expect(find.textContaining('finished'), findsNothing);
      expect(fakeBle.writes, hasLength(2),
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
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckRunning;

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
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckRunning;

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
      expect(fakeBle.writes, hasLength(2),
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
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckRunning;

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
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckRunning;

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
      fakeBle.answerWriteWithMode = CapacitorStatus.selfCheckRunning;

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
      expect(fakeBle.writes, hasLength(2));
    });
  });

}
