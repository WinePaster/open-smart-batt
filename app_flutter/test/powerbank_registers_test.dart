// Power-bank register decode (FB-15 current, FB-16 state of charge).
//
// A power bank does NOT send the registers a pack does: no 0x2E current, no
// 0x96 capacity. It sends its own block, so the app used to drop both readings
// on the floor (`default: return base`) and show a blank current and `-- %`.
//
// Every frame below is a VERBATIM sub-frame from a real capture, and every
// expectation is anchored to what the unit's OWN display showed at the same
// moment — not to a formula we invented:
//   * 0x4A `0f73 0439` → 1081 mA, while the unit displayed 1.05 A.
//   * 0x4B `2710 5c 262c` → SOC 92 %, design capacity 10000 mAh on a unit
//     rated 10000 mAh; a sibling frame read SOC 94 while the display showed
//     94 %.
//
// The decode is CLASS-GATED. 0x4A already had a pack meaning (discharge v1/v2,
// PROTOCOL.md §8.2), so reading it as current on every device would corrupt a
// pack. The gate is safe because the device-type frame (0x10) arrives earlier
// in the same burst than 0x4A.
//
// CLEAN-ROOM: expectations derive from docs/PROTOCOL.md plus our own captures.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

/// One inbound frame `[0xB8, selector, flag, LEN, payload..., XOR]`.
List<int> inbound(int selector, List<int> payload, {int flag = 0x01}) {
  final body = <int>[0xB8, selector, flag, payload.length, ...payload];
  return <int>[...body, xorFold(body)];
}

InboundFrame decodeOne(int selector, List<int> payload) =>
    FrameReassembler().addBytes(inbound(selector, payload)).single;

void main() {
  final at = DateTime.utc(2026, 7, 29, 11, 36);

  /// A sample that already knows it is a power bank (0x10 = 0x22), which is the
  /// real ordering: the device-type frame leads the burst.
  final pb = TelemetrySample.empty().copyWith(deviceType: 0x22);
  final pack = TelemetrySample.empty();

  group('0x4A on a power bank → current (FB-15)', () {
    test('the captured frame yields the ampere value the unit displayed', () {
      // Verbatim: b8 4a 01 04 0f 73 04 39 b6
      final s = TelemetryDecoder.apply(
          pb, decodeOne(0x4A, [0x0F, 0x73, 0x04, 0x39]),
          at: at);
      expect(s.current, closeTo(1.081, 1e-9));
    });

    test('a pack is UNAFFECTED — 0x4A keeps its documented meaning', () {
      // The class must be RESOLVED for either branch to run: an unattributed
      // 0x4A is refused outright (see 'class gate ordering'). A real pack
      // always sends 0x10 earlier in the same burst, so this is faithful.
      final s = TelemetryDecoder.apply(
          TelemetrySample.empty().copyWith(deviceType: 0x02),
          decodeOne(0x4A, [0x04, 0xD4, 0x04, 0xCF]),
          at: at);
      expect(s.dischargeV1, closeTo(1.236, 1e-9));
      expect(s.dischargeV2, closeTo(1.231, 1e-9));
      // And it must NOT be mistaken for a current reading.
      expect(s.current, isNull);
    });

    test('the power-bank branch does not write the pack discharge fields', () {
      final s = TelemetryDecoder.apply(
          pb, decodeOne(0x4A, [0x0F, 0x73, 0x04, 0x39]),
          at: at);
      expect(s.dischargeV1, isNull);
      expect(s.dischargeV2, isNull);
    });

    test('the mV field is not published again — PVLT already carries it', () {
      // 0x0F73 = 3955 mV, which is the same quantity as 0x19 (3.95 V).
      final s = TelemetryDecoder.apply(
          pb, decodeOne(0x4A, [0x0F, 0x73, 0x04, 0x39]),
          at: at);
      expect(s.pvlt, isNull, reason: 'PVLT must come from 0x19, not 0x4A');
    });
  });

  group('0x4B on a power bank → SOC + design capacity (FB-16)', () {
    test('the captured frame yields the percentage the unit displayed', () {
      // Verbatim: b8 4b 01 05 27 10 5e 26 30  (the 94 % sample)
      final s = TelemetryDecoder.apply(
          pb, decodeOne(0x4B, [0x27, 0x10, 0x5E, 0x26, 0x30]),
          at: at);
      expect(s.socPercent, 94);
      expect(s.designCapacityMah, 10000);
    });

    test('a later sample tracks the unit down to 63 %', () {
      // Verbatim: 27 10 3f 06 1c — five hours later, 5 V output.
      final s = TelemetryDecoder.apply(
          pb, decodeOne(0x4B, [0x27, 0x10, 0x3F, 0x06, 0x1C]),
          at: at);
      expect(s.socPercent, 63);
      expect(s.designCapacityMah, 10000);
    });

    test('the two trailing bytes produce NO field', () {
      // b7/b8 differ between the two captured samples above (0x26/0x30 vs
      // 0x06/0x1C). One is a strong second-temperature candidate, but a lone
      // sample jumped 29 -> 65 -> 28 in five seconds, so neither is named.
      final a = TelemetryDecoder.apply(
          pb, decodeOne(0x4B, [0x27, 0x10, 0x5E, 0x26, 0x30]),
          at: at);
      final b = TelemetryDecoder.apply(
          pb, decodeOne(0x4B, [0x27, 0x10, 0x5E, 0x06, 0x1C]),
          at: at);
      // Same SOC + same capacity => the samples must be indistinguishable.
      // If someone later decodes b7/b8 into a field, this fails and they must
      // come back and justify the naming.
      expect(a.socPercent, b.socPercent);
      expect(a.designCapacityMah, b.designCapacityMah);
      expect(a.temperatureC, b.temperatureC);
      expect(a.temperatureC, isNull);
    });

    test('a pack ignores 0x4B entirely', () {
      final s = TelemetryDecoder.apply(
          pack, decodeOne(0x4B, [0x27, 0x10, 0x5E, 0x26, 0x30]),
          at: at);
      expect(s.socPercent, isNull);
      expect(s.designCapacityMah, isNull);
    });
  });

  group('0x49 is the charging direction', () {
    // This group used to assert 0x49 published nothing, on the strength of "its
    // mA field read zero across 97 frames". Every one of those frames came from
    // a capture the reporter had labelled OUTPUT. Adding the charging captures
    // shows the two registers are complementary: while charging, 0x49 carries
    // up to 1875 mA and 0x4A is zero on 99 % of frames; while discharging it is
    // the other way round. So the reading was never absent — we had only looked
    // at the half of the corpus where it is quiet.
    test('a lone 0x49 stores the charge side but publishes no current yet', () {
      // Verbatim: b8 49 01 04 23 cc 00 00 1b, from an output capture.
      final s = TelemetryDecoder.apply(
          pb, decodeOne(0x49, [0x23, 0xCC, 0x00, 0x00]),
          at: at);
      // 0x49 arrives BEFORE 0x4A in every burst. Publishing here would show a
      // value for one frame and then have 0x4A overwrite it.
      expect(s.current, isNull);
      expect(s.chargeCurrent, closeTo(0.0, 1e-9));
      expect(s.svlt, isNull, reason: 'the mV field duplicates SVLT');
    });

    test('charging reads negative: 0x49 carries the mA, 0x4A is idle', () {
      // 0x49 mV 5.160 V / mA 1875, then 0x4A idle — the shape of a charging
      // burst in 2026.08.01/009.
      final a = TelemetryDecoder.apply(
          pb, decodeOne(0x49, [0x14, 0x28, 0x07, 0x53]),
          at: at);
      final b = TelemetryDecoder.apply(
          a, decodeOne(0x4A, [0x0F, 0xA3, 0x00, 0x00]),
          at: at);
      expect(b.current, closeTo(-1.875, 1e-9));
    });

    test('discharging stays positive once the charge side is idle', () {
      final a = TelemetryDecoder.apply(
          pb, decodeOne(0x49, [0x14, 0x28, 0x00, 0x00]),
          at: at);
      final b = TelemetryDecoder.apply(
          a, decodeOne(0x4A, [0x0F, 0x73, 0x04, 0x39]),
          at: at);
      expect(b.current, closeTo(1.081, 1e-9),
          reason: 'the value the unit\'s own display showed');
    });

    test('both idle is 0.0 A, not a stale reading', () {
      final a = TelemetryDecoder.apply(
          pb, decodeOne(0x49, [0x14, 0x28, 0x07, 0x53]),
          at: at);
      final b = TelemetryDecoder.apply(
          a, decodeOne(0x4A, [0x0F, 0xA3, 0x00, 0x00]),
          at: at);
      final c = TelemetryDecoder.apply(
          b, decodeOne(0x49, [0x14, 0x28, 0x00, 0x00]),
          at: at);
      final d = TelemetryDecoder.apply(
          c, decodeOne(0x4A, [0x0F, 0xA3, 0x00, 0x00]),
          at: at);
      expect(d.current, closeTo(0.0, 1e-9));
    });

    test('a pack is untouched by 0x49', () {
      final s = TelemetryDecoder.apply(
          pack.copyWith(deviceType: 0x02), decodeOne(0x49, [0x14, 0x28, 0x07, 0x53]),
          at: at);
      expect(s.chargeCurrent, isNull);
      expect(s.current, isNull);
    });

    test('an unattributed frame publishes nothing', () {
      // FB-22's failure mode: a class-agnostic formula on a frame that arrived
      // before 0x10 settled the class.
      final s = TelemetryDecoder.apply(
          TelemetrySample.empty(), decodeOne(0x49, [0x14, 0x28, 0x07, 0x53]),
          at: at);
      expect(s.chargeCurrent, isNull);
    });
  });

  group('end-to-end over the raw notification chunks', () {
    test('three verbatim BLE notifications decode to the displayed values', () {
      // Copied byte-for-byte from a capture at 11:36:05. Note the split: the
      // 0x49 frame ends with `1b` at the START of the second notification, so a
      // per-notification parser would drop it and desynchronise the rest.
      const chunks = [
        'b82001010098b8100101228ab849010423cc0000',
        '1bb84a01040f730439b6b84b010527105e263088',
        'b84c01023c0ac1b8290102010093',
      ];

      final reassembler = FrameReassembler();
      final decoder = TelemetryDecoder();
      for (final hex in chunks) {
        for (final frame in reassembler.addBytes(_hex(hex))) {
          expect(frame.checksumOk, isTrue,
              reason: 'selector 0x${frame.selector.toRadixString(16)}');
          decoder.ingest(frame, at: at);
        }
      }

      final s = decoder.sample;
      expect(s.isPowerBank, isTrue, reason: '0x10 = 0x22 leads the burst');
      // What the unit's own display showed at this moment: 94 %, 1.05 A.
      expect(s.socPercent, 94);
      expect(s.current, closeTo(1.081, 1e-9));
      expect(s.designCapacityMah, 10000);
      // 0x49 and the 0x4B tail bytes still publish nothing.
      expect(s.svlt, isNull);
      expect(s.temperatureC, isNull);
    });
  });

  group('class gate ordering', () {
    test('before 0x10 arrives, 0x4A/0x4B are ignored rather than misread', () {
      // Errs toward showing nothing: the next burst carries 0x10 first.
      final a = TelemetryDecoder.apply(
          pack, decodeOne(0x4B, [0x27, 0x10, 0x5E, 0x26, 0x30]),
          at: at);
      expect(a.socPercent, isNull);

      // 0x4A is the one that bites, because BOTH branches produce a number.
      // The pack formula on this power-bank payload yields 3.955 / 1.081 —
      // values a reviewer would wave through. With the class unresolved the
      // frame must produce nothing at all, not a defensible-looking guess.
      final b = TelemetryDecoder.apply(
          pack, decodeOne(0x4A, [0x0F, 0x73, 0x04, 0x39]),
          at: at);
      expect(b.current, isNull, reason: 'no class => no current');
      expect(b.dischargeV1, isNull,
          reason: 'the pack formula must not run on an unattributed frame');
      expect(b.dischargeV2, isNull);

      // Once the class IS known, the pack branch is still reachable.
      final packKnown =
          TelemetrySample.empty().copyWith(deviceType: 0x02);
      final c = TelemetryDecoder.apply(
          packKnown, decodeOne(0x4A, [0x0F, 0x73, 0x04, 0x39]),
          at: at);
      expect(c.dischargeV1, isNotNull,
          reason: 'the guard is about an UNKNOWN class, not about packs');

      // The real burst order — 0x10 leads, so one burst is enough.
      final d = TelemetryDecoder();
      d.ingest(decodeOne(0x10, [0x22]), at: at);
      d.ingest(decodeOne(0x4A, [0x0F, 0x73, 0x04, 0x39]), at: at);
      d.ingest(decodeOne(0x4B, [0x27, 0x10, 0x5E, 0x26, 0x30]), at: at);
      expect(d.sample.isPowerBank, isTrue);
      expect(d.sample.current, closeTo(1.081, 1e-9));
      expect(d.sample.socPercent, 94);
    });
  });
}

/// Parse a lower-case hex blob (one BLE notification) into bytes.
List<int> _hex(String s) => [
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ];
