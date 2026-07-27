/// End-to-end check that the shipping pipeline (FrameReassembler +
/// TelemetryDecoder) resolves DVOL from the real car-battery connect burst.
///
/// Bytes are the actual `RCE-CarBatt` connect-time metadata burst captured via
/// HCI snoop (PROTOCOL.md §8.5), delivered as the exact multi-fragment BLE
/// notification chunks. This locks the answer to "does the current version solve
/// VADJ": the burst's 0x30 must set VADJ=20.36, after which a streamed 0x24 gives
/// per-cell ≈ 3.3 V (not pending, not the bogus ~0.16 V).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/protocol/inbound_frame.dart';
import 'package:open_smart_batt/protocol/telemetry_decoder.dart';

void main() {
  // Real connect burst (conn0x0012), as 4 BLE notification chunks. 0x30 VADJ is
  // split across chunk 3 boundary — reassembly is required.
  const burstChunks = <String>[
    'b82001010098b810010102aab8230101009bb827',
    '010600a80102000033b82601060000000004b62b',
    'b830010207f478b82b0104184014',
    '14ce',
  ];

  // A normal fast-telemetry cycle that carries DVOL (0x24 raw a4 a4 a4 a5), as
  // the device streams it after the burst. Chunks mirror the real fragmentation.
  const dvolChunks = <String>[
    'b8190102053592b8240104a4a4a4', // 0x19 PVLT + 0x24 starts (truncated)
    'a598b821010120b9', // 0x24 completes (a4 a4 a4 a5) + 0x21 temp (0x20=32C)
  ];

  List<int> hx(String s) {
    final out = <int>[];
    for (var i = 0; i < s.length; i += 2) {
      out.add(int.parse(s.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  test('connect burst sets VADJ=20.36 and metadata', () {
    final re = FrameReassembler();
    final dec = TelemetryDecoder();
    for (final c in burstChunks) {
      for (final f in re.addBytes(hx(c))) {
        dec.ingest(f, at: DateTime.utc(2026, 7, 6));
      }
    }
    final s = dec.sample;
    expect(s.vadj, closeTo(20.36, 1e-9), reason: '0x30 => VADJ');
    expect(s.deviceType, 0x02, reason: '0x10 => car battery');
    expect(s.isSmartBattery, isTrue);
    expect(s.serial, '001206', reason: '0x26 => serial 1206');
    expect(s.dealerCode, '01680102', reason: '0x27 => dealer');
    expect(s.fullSerial, '016801020001206',
        reason: 'full = dealer(0x27) + product serial(0x26) padded to 7');
    expect(s.warnOv, closeTo(15.0, 1e-9));
    expect(s.warnUv, closeTo(12.0, 1e-9));
    expect(s.warnOt, closeTo(80.0, 1e-9));
    expect(s.warnUtByte, 0x14, reason: '0x2B b7 => UT byte preserved');
  });

  test('after the burst, a streamed 0x24 yields real per-cell V (not pending)',
      () {
    final re = FrameReassembler();
    final dec = TelemetryDecoder();
    // Burst first (sets VADJ)...
    for (final c in burstChunks) {
      for (final f in re.addBytes(hx(c))) {
        dec.ingest(f, at: DateTime.utc(2026, 7, 6));
      }
    }
    // ...then a DVOL-bearing telemetry cycle.
    for (final c in dvolChunks) {
      for (final f in re.addBytes(hx(c))) {
        dec.ingest(f, at: DateTime.utc(2026, 7, 6));
      }
    }
    final s = dec.sample;
    expect(s.dvolPending, isFalse, reason: 'VADJ known => not pending');
    expect(s.dvol, isNotNull);
    // raw a4 (164) * 20.36 / 1000 = 3.339 V ; last cell a5 (165) => 3.359 V.
    expect(s.dvol![0], closeTo(0.164 * 20.36, 1e-6));
    expect(s.dvol![3], closeTo(0.165 * 20.36, 1e-6));
    for (final v in s.dvol!) {
      expect(v, inInclusiveRange(3.0, 3.6), reason: 'plausible LiFePO4 cell');
    }
  });

  test('DVOL before the burst is pending (guards the old bogus 0.16 V)', () {
    final re = FrameReassembler();
    final dec = TelemetryDecoder();
    for (final c in dvolChunks) {
      for (final f in re.addBytes(hx(c))) {
        dec.ingest(f, at: DateTime.utc(2026, 7, 6));
      }
    }
    expect(dec.sample.vadj, isNull);
    expect(dec.sample.dvol, isNull);
    expect(dec.sample.dvolPending, isTrue);
  });
}
