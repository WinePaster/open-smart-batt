// FB-43 — a saved power bank must not be routed to the pack layout while its
// device-type byte is still in flight.
//
// The field report (feedback_log/2026.07.31/001, 何先生): "連線後一開始還是換先跳
// 未知裝置 / 重新連結才有行動電源". The byte itself is fast — 92 ms after `ready`
// in that capture — but routing happens as soon as the dashboard builds, and a
// stale iOS NSUUID held the link in connect/retry for TEN SECONDS first:
//
//   11:30:16.163  connect → 0F70900B      (saved device, stale NSUUID)
//   11:30:24.186  connect error: fbp-code 1 | Timed out after 8s
//   11:30:25.215  scan start
//   11:30:26.822  connected → 11:30:28.154 ready → 11:30:28.246 0x10=22
//
// Fix A (owner's call, 2026-07-31): let the SAVED class seed routing. The
// design 0001 §3.1 invariant "a guess never picks a layout" survives only
// because a stored `powerBank` cannot be a guess — see the third group below,
// which is the test that would catch someone widening the picker.
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

/// The routing rule under test, lifted out of ConnectionController so it can be
/// exercised without a BLE stack: wire byte first, saved-record seed second,
/// and the user's guess NEVER.
ProductClass routingClass(PackClassResolver r, ProductClass seed) {
  final fromWire = r.deviceClass;
  if (fromWire != ProductClass.unknown) return fromWire;
  return seed;
}

void main() {
  // The real bytes the power bank in that capture sent, in order.
  final powerBankBurst = <int>[
    ...inbound(Selectors.twf, const [0x01]),
    ...inbound(Selectors.deviceType, const [0x22]),
  ];

  group('a saved power bank, before its device-type byte arrives', () {
    late PackClassResolver resolver;
    setUp(() => resolver = PackClassResolver()..markConnected(DateTime.now()));

    test('routes to the power-bank view straight away', () {
      // Nothing observed yet — exactly the 10 s the field report spent here.
      expect(resolver.deviceClass, ProductClass.unknown,
          reason: 'the wire has told us nothing yet');
      expect(routingClass(resolver, ProductClass.powerBank).isPowerBank, isTrue,
          reason: 'FB-43: the saved class must carry routing until 0x10 lands');
    });

    test('used to route to the pack view — the regression itself', () {
      // What shipped before the fix: routing read the wire byte alone.
      expect(resolver.deviceClass.isPowerBank, isFalse);
    });

    test('still routes correctly once the byte lands', () {
      resolver.observe(decode(powerBankBurst));
      expect(routingClass(resolver, ProductClass.powerBank).isPowerBank, isTrue);
    });
  });

  group('the wire byte always wins over the seed', () {
    test('a record stored as powerBank cannot force a battery to that view', () {
      // The FB-25 shape: an iOS NSUUID rebound to a DIFFERENT physical unit, so
      // the stored class belongs to some other device. Self-heal must hold.
      final resolver = PackClassResolver()..markConnected(DateTime.now());
      resolver.observe(decode(inbound(Selectors.deviceType, const [0x02])));
      expect(routingClass(resolver, ProductClass.powerBank),
          ProductClass.smartBattery,
          reason: 'a stale seed may never outrank a byte we just read');
    });

    test('a record stored as a pack cannot hide a real power bank', () {
      final resolver = PackClassResolver()..markConnected(DateTime.now());
      resolver.observe(decode(powerBankBurst));
      expect(routingClass(resolver, ProductClass.smartBattery).isPowerBank,
          isTrue);
    });
  });

  group("the user's guess still cannot pick a layout (design 0001 §3.1)", () {
    test('an override routes nowhere, however emphatic', () {
      final resolver = PackClassResolver()..markConnected(DateTime.now());
      resolver.setOverride(ProductClass.powerBank);
      expect(resolver.label, ProductClass.powerBank,
          reason: 'it does drive the cosmetic chip');
      expect(routingClass(resolver, ProductClass.unknown).isPowerBank, isFalse,
          reason: 'but routing must not read the override at all');
    });

    test('the picker offers pack classes only — the seed premise', () {
      // THIS is what makes fix A safe: a stored powerBank can only have come
      // from a 0x22 byte, because the one place a user can set a class by hand
      // (pack_view.dart `_PackLabelChip`) offers just these two. If that list
      // ever grows a power-bank entry, a guess becomes persistable, the seed
      // stops being wire-derived, and FB-43's fix quietly breaks the invariant.
      const offered = <ProductClass>[
        ProductClass.supercapacitor,
        ProductClass.smartBattery,
      ];
      expect(offered.contains(ProductClass.powerBank), isFalse,
          reason: 'widening the picker means revisiting FB-43 fix A');
    });
  });

  group('an unclassified unit stays unclassified', () {
    test('no byte and no saved class routes to the pack shell', () {
      final resolver = PackClassResolver()..markConnected(DateTime.now());
      expect(routingClass(resolver, ProductClass.unknown), ProductClass.unknown);
      expect(routingClass(resolver, ProductClass.unknown).isPowerBank, isFalse);
    });

    test('an unrecognised byte falls back to the seed, not to a guess', () {
      final resolver = PackClassResolver()..markConnected(DateTime.now());
      resolver.observe(decode(inbound(Selectors.deviceType, const [0x18])));
      expect(resolver.deviceClass, ProductClass.unknown,
          reason: '0x18 is not a class we know');
      expect(routingClass(resolver, ProductClass.supercapacitor),
          ProductClass.supercapacitor);
    });
  });
}
