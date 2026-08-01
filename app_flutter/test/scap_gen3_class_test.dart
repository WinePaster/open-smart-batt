// A third-generation super-capacitor (device-type 0x18) is a capacitor.
//
// Until 2026-08-01 the byte was unmapped, so `fromDeviceType` returned
// `unknown` for it. That is the safe default and it did its job — nothing was
// mislabelled — but it is not free. Three owners connected `RCE-SCAP_III` units
// and got "unclassified", and the bounded fallback in `DeviceCapabilities`
// offered every one of them 解除斷電: a cut-off release, on hardware with no
// cut-off. The wrong button on the right hardware.
//
// The byte was held back until it was measured, then landed on three
// independent units at once (serials 145 / 373 / 416, firmware 1.02 and 1.03,
// three unrelated reporters), whose identity and threshold registers agree
// byte for byte with each other and disagree with every 0x17 unit in the
// corpus. Payloads below are those actual bytes.
//
// The last test is the one that keeps this honest: 0x19 must still be unknown.
// The rule is "one measured byte at a time", and a test that only checks the
// happy path would not notice it being traded away.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/state/pack_class_resolver.dart';

/// One inbound frame `[0xB8, selector, flag, LEN, payload..., XOR]`.
List<int> inbound(int selector, List<int> payload, {int flag = 0x01}) {
  final body = <int>[0xB8, selector, flag, payload.length, ...payload];
  return <int>[...body, xorFold(body)];
}

TelemetrySample decode(List<int> bytes) {
  var sample = TelemetrySample.empty();
  for (final f in FrameReassembler().addBytes(bytes)) {
    sample = TelemetryDecoder.apply(sample, f);
  }
  return sample;
}

void main() {
  group('device-type 0x18', () {
    test('maps to supercapacitor, not unknown', () {
      expect(ProductClass.fromDeviceType(kSuperCapacitorGen3DeviceType),
          ProductClass.supercapacitor);
      expect(kSuperCapacitorGen3DeviceType, 0x18);
    });

    test('shares the class with 0x17 rather than getting one of its own', () {
      // Two generations, one class. They differ in the VALUES of registers the
      // app reads off the wire, not in what the unit can do, so a separate
      // class would add a branch everywhere and have both sides do the same.
      expect(ProductClass.fromDeviceType(0x17),
          ProductClass.fromDeviceType(0x18));
    });

    test('an unmeasured neighbouring byte still falls to unknown', () {
      for (final byte in const [0x16, 0x19, 0x20, 0x21]) {
        expect(ProductClass.fromDeviceType(byte), ProductClass.unknown,
            reason: '0x${byte.toRadixString(16)} has not been seen on the '
                'wire; mapping it would be a guess');
      }
    });
  });

  group('capabilities of a 0x18 unit', () {
    final caps = DeviceCapabilities.fromDeviceType(0x18);

    test('offers 檢測電容', () {
      expect(caps.isCapacitor, isTrue);
    });

    // The regression this file exists for.
    test('does NOT offer 解除斷電', () {
      expect(caps.hasCutOff, isFalse,
          reason: 'a capacitor has no run mode to be cut off from; before '
              '0x18 was mapped, the unknown fallback handed it this button');
      expect(DeviceCapabilities.unknown.hasCutOff, isTrue,
          reason: 'the fallback itself is unchanged — what changed is that a '
              '0x18 unit no longer lands in it');
    });

    test('does NOT offer 防盜', () {
      expect(caps.hasAntiTheft, isFalse);
    });

    test('is not a power bank', () {
      expect(caps.isPowerBank, isFalse);
    });
  });

  group('a real 0x18 burst', () {
    // Serial 373 (MAC 6C:79:B8:35:10:62), captured 2026-08-01. The 0x2B
    // threshold payload is the one that distinguishes the generation: every
    // 0x17 unit answers 102c28xx, every 0x18 unit answers 402c2814.
    final burst = <int>[
      ...inbound(Selectors.deviceType, const [0x18]),
      ...inbound(Selectors.thresholds, const [0x40, 0x2C, 0x28, 0x14]),
      ...inbound(Selectors.current, const [0x02, 0x00]),
    ];

    test('decodes to device-type 0x18 and 0.0 A', () {
      final sample = decode(burst);
      expect(sample.deviceType, 0x18);
      // Same as the 0x17 generation: the register is present and pinned, so
      // its presence must never imply a class. See deterministic_class_test.
      expect(sample.current, 0.0);
    });

    test('resolves to a capacitor', () {
      final resolver = PackClassResolver()..markConnected(DateTime.now());
      resolver.observe(decode(burst));
      expect(resolver.label, ProductClass.supercapacitor);
    });

    test('routes to the pack shell, not to unclassified', () {
      final sample = decode(burst);
      final decision = RoutingDecision.from(
        resolved: ProductClass.fromDeviceType(sample.deviceType),
        sawDeviceType: sample.deviceType != null,
      );
      expect(decision, RoutingDecision.pack);
      expect(decision.isPending, isFalse);
    });
  });

  test('an unrecognised byte routes to unclassified, never to pending', () {
    // The distinction 0x18 used to sit on the wrong side of: a byte ARRIVED,
    // so this is a resting state the user can resolve — not a wait.
    final decision = RoutingDecision.from(
      resolved: ProductClass.unknown,
      sawDeviceType: true,
    );
    expect(decision, RoutingDecision.unclassified);
    expect(decision.isPending, isFalse);
  });
}
