// design 0097 P1 — the demo units and the demo link.
//
// T1: a demo unit's frames, read by the REAL decoder, route to the right
//     class and carry the readings [DemoPeripheral.readingAt] promises.
// T2: a demo link comes up and goes down through [BleService] without the
//     plugin, so it works with Bluetooth denied, off, or absent.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/demo/demo.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

/// Run [frames] through the reassembler and decoder a real link uses.
TelemetrySample _decode(List<List<int>> frames, {TelemetryDecoder? decoder}) {
  final d = decoder ?? TelemetryDecoder();
  final r = FrameReassembler();
  for (final f in r.addBytes([for (final x in frames) ...x])) {
    expect(f.checksumOk, isTrue, reason: 'demo frame with a bad XOR: $f');
    d.ingest(f);
  }
  return d.sample;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const cmd = CommandBuilder();
  const creds = AuthCredentials(cb: 0, pwSum: 0);

  group('demo ids', () {
    test('every demo id carries the prefix, and real-shaped ids do not', () {
      for (final k in DemoKind.values) {
        expect(isDemoDeviceId(k.id), isTrue);
        expect(DemoKind.fromId(k.id), k);
      }
      expect(isDemoDeviceId('6F1A2B3C-0000-4000-8000-00AABBCCDDEE'), isFalse);
      expect(isDemoDeviceId('AA:BB:CC:DD:EE:FF'), isFalse);
      expect(isDemoDeviceId(null), isFalse);
      expect(DemoKind.fromId('DEMO-SOMETHING-ELSE'), isNull);
    });
  });

  group('T1 DemoPeripheral', () {
    final at = DateTime.utc(2026, 11, 5, 9, 0, 0);

    test('battery routes to smartBattery with its own readings', () {
      final p = DemoPeripheral(DemoKind.battery, clock: () => at);
      final s = _decode(p.answer(cmd.extendedPoll()));
      final r = DemoPeripheral.readingAt(DemoKind.battery, at);
      expect(ProductClass.fromDeviceType(s.deviceType),
          ProductClass.smartBattery);
      expect(s.pvlt, closeTo(r.pvlt, 0.005));
      expect(s.temperatureC, r.temperatureC);
      expect(s.current, r.currentA.toDouble());
      expect(s.mode, ReportedStatus.normal);
      expect(s.dvol, isNotNull);
      expect(s.dvol!.length, 4);
      for (var i = 0; i < 4; i++) {
        expect(s.dvol![i], closeTo(r.cellsV![i], 0.0005));
      }
      // 🔵 2026-11-09 (design 0098): the demo battery streams the most common
      // real payload, `18401414` (~~OV 15.0 / UV 10.8 / OT 75~~).
      expect(s.warnOv, closeTo(15.0, 1e-9));
      expect(s.warnUv, closeTo(12.0, 1e-9));
      expect(s.warnOt, 80.0);
    });

    test('capacitor routes to supercapacitor, healthy, zero current', () {
      final p = DemoPeripheral(DemoKind.capacitor, clock: () => at);
      final s = _decode(p.answer(cmd.keepAlive()));
      final r = DemoPeripheral.readingAt(DemoKind.capacitor, at);
      expect(ProductClass.fromDeviceType(s.deviceType),
          ProductClass.supercapacitor);
      expect(s.pvlt, closeTo(r.pvlt, 0.005));
      expect(s.svlt, closeTo(r.svlt!, 0.005));
      expect(s.current, 0.0);
      expect(s.mode, CapacitorStatus.healthy);
      expect(s.dvol, isNull);
    });

    test('readings are a pure function of the clock', () {
      for (final k in DemoKind.values) {
        final a = DemoPeripheral.readingAt(k, at);
        final b = DemoPeripheral.readingAt(k, at);
        expect(a.pvlt, b.pvlt);
        expect(a.currentA, b.currentA);
      }
    });

    test('a demo day has drives and rests (the charts need shape)', () {
      final midnight = DateTime(2026, 11, 5);
      final charging = [
        for (var m = 0; m < 24 * 60; m += 5)
          DemoPeripheral.readingAt(
                  DemoKind.battery, midnight.add(Duration(minutes: m)))
              .currentA,
      ];
      // Mostly at rest: two drives, not a charge every few minutes.
      expect(charging.where((a) => a > 0).length, lessThan(charging.length ~/ 8));
      expect(charging.any((a) => a > 0), isTrue);
      expect(charging.any((a) => a == 0), isTrue);
      // Never a discharge: the demo must not look like a load on the unit.
      expect(charging.every((a) => a >= 0), isTrue);
    });

    test('battery: cut-off then release, with and without auth', () {
      final p = DemoPeripheral(DemoKind.battery, clock: () => at);
      final d = TelemetryDecoder();
      _decode(p.answer(cmd.switchMode(ModeArg.cutOff, creds)), decoder: d);
      expect(d.sample.mode, ReportedStatus.cutOffActive);
      _decode(p.answer(cmd.keepAlive()), decoder: d);
      expect(d.sample.mode, ReportedStatus.cutOffActive,
          reason: 'the state must persist, not just echo once');
      _decode(p.answer(cmd.modeSet(ModeArg.unlock)), decoder: d);
      expect(d.sample.mode, ReportedStatus.normal);
    });

    test('any credential is accepted', () {
      final p = DemoPeripheral(DemoKind.battery, clock: () => at);
      const other = AuthCredentials(cb: 0x1234, pwSum: 0x0567);
      final s = _decode(p.answer(cmd.switchMode(ModeArg.cutOff, other)));
      expect(s.mode, ReportedStatus.cutOffActive);
    });

    test('mode read-back answers the current status', () {
      final p = DemoPeripheral(DemoKind.battery, clock: () => at);
      p.answer(cmd.modeSet(ModeArg.antiTheft));
      final s = _decode(p.answer(cmd.modeReadBack()));
      expect(s.mode, ReportedStatus.antiTheftActive);
    });

    test('capacitor: cut-off is ignored, self-check runs and ends', () {
      var now = at;
      final p = DemoPeripheral(DemoKind.capacitor, clock: () => now);
      p.answer(cmd.switchMode(ModeArg.cutOff, creds));
      expect(p.statusByte, CapacitorStatus.healthy);
      p.answer(cmd.switchMode(ModeArg.capacitorSelfCheck, creds));
      expect(p.statusByte, CapacitorStatus.selfCheckStarting);
      now = at.add(const Duration(seconds: 6));
      expect(p.statusByte, CapacitorStatus.selfCheckRunning);
      now = at.add(const Duration(seconds: 16));
      expect(p.statusByte, CapacitorStatus.healthy);
    });

    // ⛔ 2026-11-09 (design 0098 Q2) — ~~'thresholds write is kept and
    // echoed'~~: the app has no `0x2B` write any more, so neither does the demo.
    test('the demo capacitor streams a real capacitor 0x2B (102c2814)', () {
      final p = DemoPeripheral(DemoKind.capacitor, clock: () => at);
      final d = TelemetryDecoder();
      _decode(p.answer(cmd.keepAlive()), decoder: d);
      expect(d.sample.warnOv, closeTo(14.8, 1e-9));
      expect(d.sample.warnOt, 80.0,
          reason: 'class-aware OT decode: a capacitor 0x28 is 80 °C');
    });

    test('unknown writes get no answer', () {
      final p = DemoPeripheral(DemoKind.battery, clock: () => at);
      expect(p.answer(const []), isEmpty);
      expect(p.answer(const [0x55, 0x66]), isEmpty);
    });
  });

  group('T2 BleService demo link', () {
    final pluginCalls = <String>[];
    const channel = MethodChannel('flutter_blue_plus/methods');

    setUp(() {
      pluginCalls.clear();
      BleService.demoConnectDelay = Duration.zero;
      BleService.demoReplyDelay = Duration.zero;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        pluginCalls.add(call.method);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    for (final kind in DemoKind.values) {
      test('${kind.id}: connect → ready → telemetry → disconnect', () async {
        final ble = BleService();
        final states = <BleLinkState>[];
        final samples = <TelemetrySample>[];
        final subs = [
          ble.linkState.listen(states.add),
          ble.telemetry.listen(samples.add),
        ];

        await ble.connect(kind.id);
        // Let the first keep-alive's answer arrive.
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(states, [
          BleLinkState.connecting,
          BleLinkState.connected,
          BleLinkState.ready,
        ]);
        expect(ble.connectedDeviceId, kind.id);
        expect(ble.connectedDeviceName, kind.advertisedName);
        expect(ble.isDemoLink, isTrue);
        expect(samples, isNotEmpty);
        expect(samples.last.deviceId, kind.id);
        expect(samples.last.deviceType, kind.deviceType);

        // Writes go to the simulated unit, not to a characteristic.
        await ble.writeCommand(const CommandBuilder().modeReadBack());

        await ble.disconnect();
        await Future<void>.delayed(Duration.zero); // broadcast delivery
        expect(states.last, BleLinkState.disconnected);
        expect(ble.connectedDeviceId, isNull);
        expect(ble.isDemoLink, isFalse);

        // Nothing speaks after teardown.
        final after = samples.length;
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        expect(samples.length, after);

        expect(pluginCalls.where((m) => m != 'flutterRestart'), isEmpty,
            reason: 'a demo link must not touch the plugin: $pluginCalls');
        for (final s in subs) {
          await s.cancel();
        }
        await ble.dispose();
      });
    }

    test('connecting a demo unit replaces the previous demo link', () async {
      final ble = BleService();
      await ble.connect(DemoKind.battery.id);
      await ble.connect(DemoKind.capacitor.id);
      expect(ble.connectedDeviceId, DemoKind.capacitor.id);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ProductClass.fromDeviceType(ble.currentSample.deviceType),
          ProductClass.supercapacitor);
      await ble.disconnect();
      await ble.dispose();
    });
  });
}
