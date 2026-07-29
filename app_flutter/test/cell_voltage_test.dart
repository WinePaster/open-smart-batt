// Per-cell voltage via selector 0x47 (FB-18).
//
// 0x24 carries ONE BYTE per cell and needs the VADJ factor (0x30) to become
// volts. Until VADJ arrives the app can only show a "pending" note — publishing
// `raw/1000` would render ~0.16 V per cell (the FB-13 regression).
//
// 0x47 carries the same four cells as u16 MILLIVOLTS, already scaled by the
// device. Two things follow, and both are pinned below:
//
//  1. It CONFIRMS our 0x24 scaling end to end. On a live unit, all five
//     captured samples were exactly `trunc(raw x VADJ)`:
//       raw 0xB9=185 x 20.30 = 3755.5 -> 3755      (0x0EAB)
//       raw 0xB0=176 x 20.30 = 3572.8 -> 3572      (0x0DF4)
//       raw 0xB3=179 x 20.30 = 3633.7 -> 3633      (0x0E31)
//       raw 0xBA=186 x 20.30 = 3775.8 -> 3775      (0x0EBF)
//       raw 0xA4=164 x 20.30 = 3329.2 -> 3329      (0x0D01)
//     Truncation, not rounding — every one of the five.
//  2. It gives a per-cell reading WITHOUT 0x30, so `dvolPending` gains an
//     escape route instead of a second dependency.
//
// It does NOT replace 0x24: 0x47 rode the connect burst twice in a session
// while 0x24 streamed 271 times (about once a second).
//
// CLEAN-ROOM: expectations derive from docs/PROTOCOL.md plus our own captures.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

List<int> inbound(int selector, List<int> payload, {int flag = 0x01}) {
  final body = <int>[0xB8, selector, flag, payload.length, ...payload];
  return <int>[...body, xorFold(body)];
}

InboundFrame decodeOne(int selector, List<int> payload) =>
    FrameReassembler().addBytes(inbound(selector, payload)).single;

void main() {
  final at = DateTime.utc(2026, 7, 29, 14, 37);
  final base = TelemetrySample.empty();

  // Verbatim from the capture: b8 47 01 08 0e ab 0d f4 0e 31 0e bf 24
  const capturedMv = [0x0E, 0xAB, 0x0D, 0xF4, 0x0E, 0x31, 0x0E, 0xBF];
  // The 0x24 frame from the same burst, and the VADJ that came with it.
  const capturedRaw = [0xB9, 0xB0, 0xB3, 0xBA];
  const capturedVadj = [0x07, 0xEE]; // 2030 / 100 = 20.30

  group('0x47 decodes to volts with no VADJ involved', () {
    test('the captured frame yields the four cell voltages', () {
      final s =
          TelemetryDecoder.apply(base, decodeOne(0x47, capturedMv), at: at);
      expect(s.dvol, isNotNull);
      expect(s.dvol!.length, 4);
      expect(s.dvol![0], closeTo(3.755, 1e-9));
      expect(s.dvol![1], closeTo(3.572, 1e-9));
      expect(s.dvol![2], closeTo(3.633, 1e-9));
      expect(s.dvol![3], closeTo(3.775, 1e-9));
    });

    test('it clears dvolPending even though 0x30 never arrived', () {
      // Arrive at the pending state the honest way: 0x24 with no VADJ.
      final pending =
          TelemetryDecoder.apply(base, decodeOne(0x24, capturedRaw), at: at);
      expect(pending.dvolPending, isTrue);
      expect(pending.dvol, isNull);

      final s =
          TelemetryDecoder.apply(pending, decodeOne(0x47, capturedMv), at: at);
      expect(s.dvolPending, isFalse);
      expect(s.dvol, isNotNull);
      expect(s.vadj, isNull, reason: '0x47 must not fabricate a VADJ');
    });
  });

  group('0x47 agrees with 0x24 x VADJ — the cross-check', () {
    test('all four cells match to within one truncated millivolt', () {
      var s = TelemetryDecoder.apply(base, decodeOne(0x30, capturedVadj),
          at: at);
      s = TelemetryDecoder.apply(s, decodeOne(0x24, capturedRaw), at: at);
      final viaVadj = s.dvol!;

      final viaDirect =
          TelemetryDecoder.apply(base, decodeOne(0x47, capturedMv), at: at)
              .dvol!;

      for (var i = 0; i < 4; i++) {
        // trunc() loses at most 1 mV, so 1 mV is the whole tolerance budget.
        expect((viaVadj[i] - viaDirect[i]).abs(), lessThan(0.001),
            reason: 'cell ${i + 1}: $viaVadj vs $viaDirect');
      }
    });

    test('the balanced resting sample matches too', () {
      // Second burst, at rest: 0x24 = a4 a4 a4 a4, 0x47 = 0d01 x4.
      var s = TelemetryDecoder.apply(base, decodeOne(0x30, capturedVadj),
          at: at);
      s = TelemetryDecoder.apply(
          s, decodeOne(0x24, [0xA4, 0xA4, 0xA4, 0xA4]),
          at: at);
      final direct = TelemetryDecoder.apply(
          base,
          decodeOne(0x47, [0x0D, 0x01, 0x0D, 0x01, 0x0D, 0x01, 0x0D, 0x01]),
          at: at);
      for (var i = 0; i < 4; i++) {
        expect((s.dvol![i] - direct.dvol![i]).abs(), lessThan(0.001));
      }
      expect(direct.dvol![0], closeTo(3.329, 1e-9));
    });
  });

  group('0x24 keeps its per-second job', () {
    test('with VADJ known, 0x24 still refreshes the reading', () {
      var s = TelemetryDecoder.apply(base, decodeOne(0x47, capturedMv), at: at);
      s = TelemetryDecoder.apply(s, decodeOne(0x30, capturedVadj), at: at);
      // A later, different per-second frame must win — 0x47 only comes twice a
      // session, so pinning the display to it would freeze the cells.
      s = TelemetryDecoder.apply(
          s, decodeOne(0x24, [0xA4, 0xA4, 0xA4, 0xA4]),
          at: at);
      expect(s.dvol![0], closeTo(3.3292, 1e-9));
    });

    test('a 0x24 that cannot be scaled must NOT erase a good 0x47 reading', () {
      // The ordering that made this necessary: 0x47 leads the burst, and the
      // per-second 0x24 frames follow before any 0x30 on a unit that omits it.
      final s47 =
          TelemetryDecoder.apply(base, decodeOne(0x47, capturedMv), at: at);
      final after =
          TelemetryDecoder.apply(s47, decodeOne(0x24, capturedRaw), at: at);
      expect(after.dvol, isNotNull, reason: 'must not flicker back to pending');
      expect(after.dvolPending, isFalse);
      expect(after.dvol![0], closeTo(3.755, 1e-9));
    });
  });

  group('FB-13 does not regress', () {
    test('0x24 alone, with no 0x30 and no 0x47, still refuses to guess', () {
      final s = TelemetryDecoder.apply(base, decodeOne(0x24, capturedRaw),
          at: at);
      expect(s.dvol, isNull, reason: 'raw/1000 would publish ~0.19 V per cell');
      expect(s.dvolPending, isTrue);
    });
  });
}
