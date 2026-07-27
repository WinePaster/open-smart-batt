// design 0007 — the class comes off the wire; nothing is inferred.
//
// The regression this locks down: on 2026-07-27 an owner-confirmed
// super-capacitor was shown the BATTERY body and the 解除斷電 control, because
//   * its device-type byte 0x17 was deliberately mapped to `unknown`, and
//   * the fallback fingerprint keyed on "a 0x2E current frame means battery",
//     while that capacitor streams 0x2E every second pinned at 0.0 A.
//
// Frame payloads below are the ACTUAL bytes from
// feedback_log/2026.07.27/opensmartbatt-20260727-214022.log.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/state/pack_class_resolver.dart';

/// One inbound frame `[0xB8, selector, flag, LEN, payload..., XOR]`.
List<int> inbound(int selector, List<int> payload, {int flag = 0x01}) {
  final body = <int>[0xB8, selector, flag, payload.length, ...payload];
  return <int>[...body, xorFold(body)];
}

void main() {
  group('the 2026-07-27 field capacitor', () {
    // Exactly what the unit sent, in order: device-type 0x17, then the current
    // register that used to mislabel it.
    final burst = <int>[
      ...inbound(Selectors.deviceType, const [0x17]),
      ...inbound(Selectors.current, const [0x02, 0x00]),
    ];

    test('decodes to device-type 0x17 with a current of exactly 0.0 A', () {
      var sample = TelemetrySample.empty();
      for (final f in FrameReassembler().addBytes(burst)) {
        sample = TelemetryDecoder.apply(sample, f);
      }
      expect(sample.deviceType, 0x17);
      // 512 - 0x0200 = 0. The register exists but the unit cannot measure
      // current — which is why presence must never imply a class.
      expect(sample.current, 0.0);
    });

    test('is classified as a super-capacitor, not a battery', () {
      var sample = TelemetrySample.empty();
      for (final f in FrameReassembler().addBytes(burst)) {
        sample = TelemetryDecoder.apply(sample, f);
      }
      final resolver = PackClassResolver()..markConnected(DateTime.now());
      resolver.observe(sample);
      expect(resolver.label, ProductClass.supercapacitor);
    });

    test('is therefore NOT offered 解除斷電 or 防盜', () {
      final caps = DeviceCapabilities.fromClass(ProductClass.supercapacitor);
      expect(caps.isCapacitor, isTrue, reason: '檢測電容 is the one it has');
      expect(caps.hasCutOff, isFalse,
          reason: 'owner confirmed a capacitor has no 解除斷電');
      expect(caps.hasAntiTheft, isFalse);
      // Not even an override may surface anti-theft on a non-battery.
      expect(caps.copyWith(antiTheftOverride: true).hasAntiTheft, isFalse);
    });
  });

  group('no inference remains', () {
    test('a battery-looking telemetry stream with no device-type stays unknown',
        () {
      final resolver = PackClassResolver()..markConnected(DateTime.now());
      resolver.observe(TelemetrySample(
        timestamp: DateTime.now(),
        current: 3.2,
        dvol: const [3.31, 3.30, 3.29, 3.32],
      ));
      expect(resolver.label, ProductClass.unknown,
          reason: 'registers are not evidence of a class');
    });

    test('an unrecognised byte is unknown, and the user can resolve it', () {
      final resolver = PackClassResolver()..markConnected(DateTime.now());
      resolver.observe(TelemetrySample(timestamp: DateTime.now(), deviceType: 0x99));
      expect(resolver.label, ProductClass.unknown);
      resolver.setOverride(ProductClass.supercapacitor);
      expect(resolver.label, ProductClass.supercapacitor);
    });

    test('a stale saved class cannot survive a recognised byte (self-heal)', () {
      // Reconnect seeds the saved (wrong) class, then the burst arrives.
      final resolver = PackClassResolver()..markConnected(DateTime.now());
      resolver.setOverride(ProductClass.smartBattery); // saved while guessing
      resolver.observe(
          TelemetrySample(timestamp: DateTime.now(), deviceType: 0x17));
      expect(resolver.label, ProductClass.supercapacitor);
    });
  });
}
