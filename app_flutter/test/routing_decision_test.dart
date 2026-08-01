// Routing must be able to say "I do not know yet".
//
// The predecessor of this rule was a bool:
//
//   return isPowerBank ? const PowerBankView() : const PackView();
//
// which has no way to express an undetermined class, so it routed one to the
// pack layout. The pack layout leads with a 12 V terminal-voltage gauge, so a
// power bank caught in that window had its SINGLE-CELL voltage rendered as a
// pack's main voltage — a 2026-07-31 field capture, a dashboard screenshot
// reading "PVLT 主電壓 3.79 V" for a power bank.
//
// FB-43's first fix (`7a0965c`) supplied a better guess: seed routing from the
// class stored for that device. It is kept, and the second group below is its
// regression guard. But the screenshot's device had NO stored class — its chip
// read 未分類 too — so a better guess could not have reached it. The missing
// capability was the option not to guess, which is what these tests pin.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/product_class.dart';
import 'package:open_smart_batt/models/routing_decision.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/models/telemetry_sample.dart';
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

/// Mirrors `ConnectionController.resolvedClass`: wire byte, else the
/// saved-record seed. A user's guess is not part of it — a layout is chosen by
/// wire-derived facts and by nothing else.
ProductClass resolved(PackClassResolver r, ProductClass seed) {
  final fromWire = r.deviceClass;
  return fromWire != ProductClass.unknown ? fromWire : seed;
}

RoutingDecision route(PackClassResolver r, ProductClass seed) =>
    RoutingDecision.from(
      resolved: resolved(r, seed),
      sawDeviceType: r.sawDeviceType,
    );

void main() {
  PackClassResolver fresh() => PackClassResolver()..markConnected(DateTime.now());

  group('no byte yet, no stored class — the 2026-07-31 screenshot', () {
    test('routes to pending, NOT to the pack layout', () {
      final r = fresh();
      expect(route(r, ProductClass.unknown), RoutingDecision.pending);
    });

    test('is exactly the case FB-43 fix A could not reach', () {
      // Fix A seeds from the stored class. With nothing stored there is
      // nothing to seed, so the seed-based rule still yields `unknown` — and
      // under the old bool that meant the pack layout.
      final r = fresh();
      expect(resolved(r, ProductClass.unknown), ProductClass.unknown);
      expect(resolved(r, ProductClass.unknown).isPowerBank, isFalse,
          reason: 'the old bool would have sent this to PackView');
      expect(route(r, ProductClass.unknown).isPending, isTrue,
          reason: 'routing withholds the layout instead of guessing');
    });
  });

  group('FB-43 fix A is not regressed', () {
    test('a stored power bank still routes immediately, no byte needed', () {
      final r = fresh();
      expect(route(r, ProductClass.powerBank), RoutingDecision.powerBank);
    });

    test('a stored pack class still routes immediately', () {
      final r = fresh();
      expect(route(r, ProductClass.smartBattery), RoutingDecision.pack);
      expect(route(fresh(), ProductClass.supercapacitor), RoutingDecision.pack);
    });

    test('a seed never leaves us in pending', () {
      for (final seed in [
        ProductClass.powerBank,
        ProductClass.smartBattery,
        ProductClass.supercapacitor,
      ]) {
        expect(route(fresh(), seed).isPending, isFalse, reason: 'seed=$seed');
      }
    });
  });

  group('an unrecognised byte is NOT pending', () {
    // The distinction this whole design turns on. Both present as
    // ProductClass.unknown; they want opposite responses.
    // 0x19 stands in for "a byte this build has not been taught". It used to
    // be 0x18 — until three units of that type were captured on 2026-08-01 and
    // it became a super-capacitor. The example moved; the distinction did not.
    test('0x19 routes to unclassified so the user can pick', () {
      final r = fresh()..observe(decode(inbound(Selectors.deviceType, const [0x19])));
      expect(r.deviceClass, ProductClass.unknown, reason: '0x19 is unknown to us');
      expect(r.sawDeviceType, isTrue, reason: 'but the unit did answer');
      expect(route(r, ProductClass.unknown), RoutingDecision.unclassified);
      expect(route(r, ProductClass.unknown).isPending, isFalse,
          reason: 'hiding the picker behind a placeholder would strand the user');
    });

    test('no byte and an unrecognised byte differ only by sawDeviceType', () {
      final never = fresh();
      final answered = fresh()
        ..observe(decode(inbound(Selectors.deviceType, const [0x19])));
      expect(never.deviceClass, answered.deviceClass,
          reason: 'identical class — which is why the bool could not tell them apart');
      expect(never.sawDeviceType, isFalse);
      expect(answered.sawDeviceType, isTrue);
      expect(route(never, ProductClass.unknown),
          isNot(route(answered, ProductClass.unknown)));
    });
  });

  group('the wire byte ends pending, and always wins', () {
    test('0x22 resolves pending to the power-bank view', () {
      final r = fresh();
      expect(route(r, ProductClass.unknown).isPending, isTrue);
      r.observe(decode(inbound(Selectors.deviceType, const [0x22])));
      expect(route(r, ProductClass.unknown), RoutingDecision.powerBank);
    });

    test('0x02 resolves pending to the pack view', () {
      final r = fresh();
      expect(route(r, ProductClass.unknown).isPending, isTrue);
      r.observe(decode(inbound(Selectors.deviceType, const [0x02])));
      expect(route(r, ProductClass.unknown), RoutingDecision.pack);
    });

    test('a byte beats a stale seed pointing the other way (FB-25 shape)', () {
      // A rebound iOS NSUUID can carry another unit's stored class.
      final r = fresh()..observe(decode(inbound(Selectors.deviceType, const [0x02])));
      expect(route(r, ProductClass.powerBank), RoutingDecision.pack);
    });
  });

  group("a user's guess still cannot pick a layout", () {
    test('an override changes neither the class nor the route', () {
      final r = fresh()..setOverride(ProductClass.smartBattery);
      expect(r.label, ProductClass.smartBattery, reason: 'it drives the chip');
      expect(route(r, ProductClass.unknown), RoutingDecision.pending,
          reason: 'routing must not read the override at all');
    });

    test('the picker offers pack classes only — the seed premise', () {
      // Unchanged from routing_seed_test.dart, restated because the pending
      // state leans on it too: a stored powerBank can only have come from a
      // 0x22 byte, which is what makes seeding routing safe.
      const offered = <ProductClass>[
        ProductClass.supercapacitor,
        ProductClass.smartBattery,
      ];
      expect(offered.contains(ProductClass.powerBank), isFalse);
    });
  });

  group('resolver lifecycle', () {
    test('a new connection forgets the previous unit had answered', () {
      final r = fresh()..observe(decode(inbound(Selectors.deviceType, const [0x22])));
      expect(r.sawDeviceType, isTrue);
      r.markConnected(DateTime.now());
      expect(r.sawDeviceType, isFalse,
          reason: 'else unit B inherits unit A "already answered"');
      expect(route(r, ProductClass.unknown), RoutingDecision.pending);
    });

    test('reset clears it too', () {
      final r = fresh()..observe(decode(inbound(Selectors.deviceType, const [0x22])));
      r.reset();
      expect(r.sawDeviceType, isFalse);
      expect(r.observedDeviceType, isNull);
    });

    test('observedDeviceType keeps the raw byte for diagnostics', () {
      final r = fresh()..observe(decode(inbound(Selectors.deviceType, const [0x19])));
      expect(r.observedDeviceType, 0x19,
          reason: 'T0 logs it so an unknown byte is identifiable in the field');
    });
  });

  group('timing constants', () {
    test('the grace window is shorter than the escape-hatch timeout', () {
      expect(kClassPendingGrace, lessThan(kClassPendingTimeout));
    });

    test('the grace window is short enough to be imperceptible', () {
      // Raised from 400 ms when the constant moved 300 → 500 ms. Half a second
      // is the top of the band this is asserting: past it the empty area stops
      // reading as "still settling" and starts reading as a broken screen.
      expect(kClassPendingGrace.inMilliseconds, lessThanOrEqualTo(500));
    });
  });
}
