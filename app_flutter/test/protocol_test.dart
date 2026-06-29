// Pure-Dart unit tests for the protocol layer. No Flutter binding needed.
//
// CLEAN-ROOM: every expected value below is hand-derived ONLY from
// docs/PROTOCOL.md, docs/CAPTURE_VERIFIED.md, and mockup/index.html. No
// decompiled / original-app source was consulted.
//
// Coverage:
//   * xorFold checksum correctness (incl. edge cases).
//   * outbound frame builders -> exact [0xB8, CMD, flag, LEN, payload..., XOR].
//   * inbound reassembly across fragmented / merged / garbage-prefixed chunks.
//   * selector dispatch (each selector folds into the right field; unknowns no-op).
//   * telemetry decode formulas with hand-computed expected values.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_rce_batt/models/models.dart';
import 'package:open_rce_batt/protocol/protocol.dart';

// ---------------------------------------------------------------------------
// Test helpers — build inbound frames with a correct (or deliberately broken)
// XOR so we can exercise the reassembler + decoder against known bytes.
// ---------------------------------------------------------------------------

/// Raw bytes of one inbound frame `[0xB8, selector, flag, LEN, payload..., XOR]`.
/// [flag] defaults to 0x01 (the constant inbound flag per CAPTURE_VERIFIED §1).
/// Pass [badXor] to force a wrong checksum; pass [len] to override the LEN byte.
List<int> inboundBytes(
  int selector,
  List<int> payload, {
  int flag = 0x01,
  int? len,
  int? badXor,
}) {
  final l = len ?? payload.length;
  final body = <int>[0xB8, selector, flag, l, ...payload];
  return <int>[...body, badXor ?? xorFold(body)];
}

/// Decode exactly one inbound frame from selector + payload.
InboundFrame decodeOne(int selector, List<int> payload) =>
    FrameReassembler().addBytes(inboundBytes(selector, payload)).single;

void main() {
  // =========================================================================
  // 1. xorFold checksum correctness
  // =========================================================================
  group('xorFold', () {
    test('folds a multi-byte list (mode sub-frame -> 0x9C)', () {
      // B8 ^ 23 ^ 00 ^ 01 ^ 06 = 0x9C  (CAPTURE_VERIFIED §1 mode frame).
      expect(xorFold([0xB8, 0x23, 0x00, 0x01, 0x06]), 0x9C);
    });

    test('single byte folds to itself', () {
      expect(xorFold([0x23]), 0x23);
      expect(xorFold([0xB8]), 0xB8);
    });

    test('a value XORed with itself cancels to 0', () {
      expect(xorFold([0xAB, 0xAB]), 0x00);
      expect(xorFold([0x12, 0x34, 0x12, 0x34]), 0x00);
    });

    test('order-independent (XOR is commutative/associative)', () {
      expect(xorFold([0x01, 0x02, 0x04, 0x08]),
          xorFold([0x08, 0x04, 0x02, 0x01]));
      expect(xorFold([0x01, 0x02, 0x04, 0x08]), 0x0F);
    });

    test('masks each input to a byte before folding', () {
      // 0x1B8 & 0xFF == 0xB8, so this must equal folding 0xB8 alone-ish.
      expect(xorFold([0x1B8]), 0xB8);
      expect(xorFold([0x123, 0x100]), (0x23) ^ (0x00));
    });

    test('result is always a single byte (0..255)', () {
      final v = xorFold([0xFF, 0x00, 0xAA, 0x55]);
      expect(v, inInclusiveRange(0, 255));
      expect(v, 0xFF ^ 0x00 ^ 0xAA ^ 0x55);
    });

    test('throws on empty list', () {
      expect(() => xorFold(<int>[]), throwsArgumentError);
    });
  });

  // =========================================================================
  // 2. Outbound frame builders -> [0xB8, CMD, flag, LEN, payload..., XOR]
  // =========================================================================
  group('buildFrame / concatFrames primitives', () {
    test('buildFrame lays out sync, cmd, flag, len, payload, xor', () {
      final f = buildFrame(0x2B, [0x10, 0x2C, 0x28, 0x14]);
      expect(f.sublist(0, 4), [0xB8, 0x2B, 0x00, 0x04]);
      expect(f.sublist(4, 8), [0x10, 0x2C, 0x28, 0x14]);
      expect(f.last, xorFold(f.sublist(0, f.length - 1)));
      // Hand-folded XOR: B8^2B^00^04^10^2C^28^14 = 0x97.
      expect(f.last, 0x97);
      expect(f.length, 9);
    });

    test('buildFrame honours an explicit (mismatched) len byte', () {
      final f = buildFrame(0x23, [0x06], len: 0x05);
      expect(f[3], 0x05); // LEN says 5 though payload is 1 byte
      expect(f.last, xorFold(f.sublist(0, f.length - 1)));
    });

    test('buildFrame masks cmd/flag/payload bytes to 8 bits', () {
      final f = buildFrame(0x123, [0x1FF], flag: 0x101);
      expect(f[1], 0x23);
      expect(f[2], 0x01);
      expect(f[4], 0xFF);
    });

    test('concatFrames joins sub-frames in order', () {
      final out = concatFrames([
        [0xB8, 0x23, 0x00, 0x01, 0x06, 0x9C],
        [0xB8, 0x2A, 0x01, 0x04],
      ]);
      expect(out.length, 10);
      expect(out.sublist(0, 6), [0xB8, 0x23, 0x00, 0x01, 0x06, 0x9C]);
      expect(out.sublist(6), [0xB8, 0x2A, 0x01, 0x04]);
    });

    test('frame constants', () {
      expect(kSyncByte, 0xB8);
      expect(kKeepAliveByte, 0x23);
    });
  });

  group('CommandBuilder outbound frames', () {
    const cb = CommandBuilder();

    test('keep-alive is the single byte 0x23 (NOT 2-byte !#)', () {
      expect(cb.keepAlive(), [0x23]);
      expect(cb.keepAlive().length, 1);
    });

    test('modeSet -> [B8,23,flag,01,mode,XOR] with correct checksum', () {
      final f = cb.modeSet(0x06);
      expect(f, [0xB8, 0x23, 0x00, 0x01, 0x06, 0x9C]); // capture-verified
      // Structure assertions independent of the hand value.
      expect(f[0], 0xB8);
      expect(f[1], Commands.modeSet);
      expect(f[2], 0x00);
      expect(f[3], 0x01);
      expect(f[4], 0x06);
      expect(f.last, xorFold(f.sublist(0, f.length - 1)));
    });

    test('modeSet honours a non-zero flag and re-folds the XOR', () {
      final f = cb.modeSet(0x00, flag: 0x01);
      expect(f.sublist(0, 5), [0xB8, 0x23, 0x01, 0x01, 0x00]);
      expect(f.last, xorFold(f.sublist(0, 5)));
    });

    test('auth standalone -> [B8,2A,00,04,cbHi,cbLo,pwHi,pwLo,XOR]', () {
      const creds = AuthCredentials(cb: 0x0011, pwSum: 0x0022);
      final f = cb.auth(creds);
      expect(f.sublist(0, 4), [0xB8, 0x2A, 0x00, 0x04]);
      expect(f.sublist(4, 8), [0x00, 0x11, 0x00, 0x22]);
      // Hand-folded: B8^2A^00^04^00^11^00^22 = 0xA5.
      expect(f.last, 0xA5);
      expect(f.last, xorFold(f.sublist(0, 8)));
      expect(f.length, 9);
    });

    test('bundled auth (flag 0x01) flips the XOR by exactly 0x01', () {
      const creds = AuthCredentials(cb: 0x0011, pwSum: 0x0022);
      final standalone = cb.auth(creds, flag: 0x00);
      final bundled = cb.auth(creds, flag: 0x01);
      expect(bundled[2], 0x01);
      expect(bundled.last, standalone.last ^ 0x01); // 0xA5 -> 0xA4
      expect(bundled.last, 0xA4);
    });

    test('auth byte order is big-endian hi-then-lo', () {
      const creds = AuthCredentials(cb: 0x1234, pwSum: 0xABCD);
      final f = cb.auth(creds);
      expect(f.sublist(4, 8), [0x12, 0x34, 0xAB, 0xCD]);
    });

    test('switchMode = modeSet(flag0) ++ auth(flag1), 15 bytes', () {
      const creds = AuthCredentials(cb: 0x0011, pwSum: 0x0022);
      final w = cb.switchMode(0x06, creds);
      expect(w.length, 15); // CAPTURE_VERIFIED: 6 + 9, no trailing payload
      // First sub-frame: mode (flag 0x00).
      expect(w.sublist(0, 6), [0xB8, 0x23, 0x00, 0x01, 0x06, 0x9C]);
      // Second sub-frame: auth (flag 0x01).
      expect(w.sublist(6, 10), [0xB8, 0x2A, 0x01, 0x04]);
      expect(w.sublist(10, 14), [0x00, 0x11, 0x00, 0x22]);
      expect(w[14], xorFold(w.sublist(6, 14)));
      expect(w[14], 0xA4);
      // Each sub-frame is independently a valid frame.
      expect(w[5], xorFold(w.sublist(0, 5)));
    });

    test('thresholdsRaw -> [B8,2B,00,04,ov,uv,ot,trailing,XOR]', () {
      final f = cb.thresholdsRaw(0x10, 0x2C, 0x28, trailing: 0x14);
      expect(f.sublist(0, 4), [0xB8, 0x2B, 0x00, 0x04]);
      expect(f.sublist(4, 8), [0x10, 0x2C, 0x28, 0x14]);
      expect(f.last, 0x97); // hand-folded
      expect(f.last, xorFold(f.sublist(0, 8)));
    });

    test('thresholds(physical) inverts the read scaling', () {
      // OV 14.8 V -> (14.8-14.4)/0.025 = 16 (0x10)
      // UV 11.5 V -> (11.5-10.4)/0.025 = 44 (0x2C)
      // OT 100 C  -> 100-60            = 40 (0x28)
      final f =
          cb.thresholds(ovVolts: 14.8, uvVolts: 11.5, otCelsius: 100, trailing: 0x14);
      expect(f.sublist(4, 8), [0x10, 0x2C, 0x28, 0x14]);
      expect(f.last, xorFold(f.sublist(0, 8)));
    });

    test('changeCutOffPassword uses the new password checksum on 0x2A', () {
      // 'AB' -> 0x41 + 0x42 = 0x83.
      final f = cb.changeCutOffPassword(0x0011, 'AB');
      expect(f.sublist(0, 4), [0xB8, 0x2A, 0x00, 0x04]);
      expect(f.sublist(4, 8), [0x00, 0x11, 0x00, 0x83]);
      expect(f.last, xorFold(f.sublist(0, 8)));
    });
  });

  group('CommandBuilder static helpers + AuthCredentials', () {
    test('passwordChecksum = sum of UTF-16 code units (16-bit)', () {
      expect(CommandBuilder.passwordChecksum('AB'), 0x41 + 0x42); // 131
      expect(CommandBuilder.passwordChecksum(''), 0);
      expect(CommandBuilder.passwordChecksum('0000'),
          0x30 * 4); // '0' is 0x30
    });

    test('passwordChecksum masks the sum to 16 bits', () {
      // 1000 chars of code unit 0xFF -> 255000; & 0xFFFF = 58392.
      final pw = String.fromCharCodes(List<int>.filled(1000, 0xFF));
      expect(CommandBuilder.passwordChecksum(pw), 255000 & 0xFFFF);
      expect(CommandBuilder.passwordChecksum(pw), 58392);
    });

    test('cbFromFieldCb parses first 8 chars in BASE 10', () {
      // '01680104' parsed decimal -> 1680104 (NOT hex).
      expect(CommandBuilder.cbFromFieldCb('01680104'), 1680104);
      expect(CommandBuilder.cbFromFieldCb('01680104300001'), 1680104);
    });

    test('cbFromFieldCb throws when shorter than 8 chars', () {
      expect(() => CommandBuilder.cbFromFieldCb('0168'), throwsArgumentError);
    });

    test('AuthCredentials hi/lo getters split big-endian', () {
      const c = AuthCredentials(cb: 0x1234, pwSum: 0xABCD);
      expect(c.cbHi, 0x12);
      expect(c.cbLo, 0x34);
      expect(c.pwHi, 0xAB);
      expect(c.pwLo, 0xCD);
    });

    test('AuthCredentials cbHi is NOT byte-masked (spec quirk)', () {
      // field_cb '01680104' -> 1680104; cbHi = 1680104>>8 = 6562 (>255).
      const c = AuthCredentials(cb: 1680104, pwSum: 0);
      expect(c.cbHi, 6562);
      expect(c.cbLo, 1680104 & 0xFF); // 0xE8
      // ...but the frame builder truncates it to a byte on the wire.
      final f = const CommandBuilder().auth(c);
      expect(f[4], 6562 & 0xFF); // 0xA2
      expect(f[5], 0xE8);
    });
  });

  // =========================================================================
  // 3. Inbound reassembly across fragmented chunks
  // =========================================================================
  group('FrameReassembler', () {
    test('reassembles a frame fragmented across two chunks', () {
      final full = inboundBytes(0x19, [0x04, 0xD4]); // PVLT 12.36 V
      final r = FrameReassembler();
      expect(r.addBytes(full.sublist(0, 3)), isEmpty);
      expect(r.buffered, 3);
      final frames = r.addBytes(full.sublist(3));
      expect(frames.length, 1);
      expect(frames.single.selector, 0x19);
      expect(frames.single.checksumOk, isTrue);
      expect(r.buffered, 0);
    });

    test('reassembles a frame fed one byte at a time', () {
      final full = inboundBytes(0x21, [0x2D]); // temp 45
      final r = FrameReassembler();
      InboundFrame? got;
      for (final b in full) {
        final fr = r.addBytes([b]);
        if (fr.isNotEmpty) got = fr.single;
      }
      expect(got, isNotNull);
      expect(got!.selector, 0x21);
      expect(got.b(4), 0x2D);
    });

    test('emits two complete frames from one merged chunk', () {
      final merged = [
        ...inboundBytes(0x19, [0x04, 0xD4]),
        ...inboundBytes(0x37, [0x04, 0xCF]),
      ];
      final frames = FrameReassembler().addBytes(merged);
      expect(frames.length, 2);
      expect(frames[0].selector, 0x19);
      expect(frames[1].selector, 0x37);
    });

    test('handles a second frame split across the chunk boundary', () {
      final f1 = inboundBytes(0x19, [0x04, 0xD4]);
      final f2 = inboundBytes(0x21, [0x2E]);
      // First chunk = f1 + first 2 bytes of f2.
      final r = FrameReassembler();
      var out = r.addBytes([...f1, ...f2.sublist(0, 2)]);
      expect(out.length, 1);
      expect(out.single.selector, 0x19);
      out = r.addBytes(f2.sublist(2));
      expect(out.length, 1);
      expect(out.single.selector, 0x21);
    });

    test('resyncs past leading garbage to the next 0xB8', () {
      final full = inboundBytes(0x19, [0x04, 0xD4]);
      final frames =
          FrameReassembler().addBytes([0x00, 0xFF, 0x42, ...full]);
      expect(frames.length, 1);
      expect(frames.single.selector, 0x19);
    });

    test('drops a buffer with no sync byte', () {
      final r = FrameReassembler();
      expect(r.addBytes([0x00, 0x01, 0x02, 0x03]), isEmpty);
      expect(r.buffered, 0); // cleared, nothing to keep
    });

    test('a bad-CRC frame is still returned with checksumOk=false', () {
      final bad = inboundBytes(0x19, [0x04, 0xD4], badXor: 0x00);
      final fr = FrameReassembler().addBytes(bad).single;
      expect(fr.selector, 0x19);
      expect(fr.checksumOk, isFalse);
    });

    test('reset() clears buffered partial bytes', () {
      final full = inboundBytes(0x19, [0x04, 0xD4]);
      final r = FrameReassembler();
      r.addBytes(full.sublist(0, 4));
      expect(r.buffered, 4);
      r.reset();
      expect(r.buffered, 0);
    });

    test('waits for full payload before emitting (LEN-driven framing)', () {
      // LEN says 6 (serial); feed header + 4 of 6 payload bytes -> nothing yet.
      final full = inboundBytes(0x26, [0, 0, 0, 0, 0x12, 0x34]);
      final r = FrameReassembler();
      expect(r.addBytes(full.sublist(0, 8)), isEmpty);
      expect(r.addBytes(full.sublist(8)).length, 1);
    });

    test('masks incoming bytes to 8 bits', () {
      final full = inboundBytes(0x21, [0x2D]);
      final frames =
          FrameReassembler().addBytes(full.map((b) => b | 0x100).toList());
      expect(frames.single.selector, 0x21);
      expect(frames.single.b(4), 0x2D);
    });
  });

  group('InboundFrame accessors', () {
    test('b(4) is the first payload byte; spec indexing', () {
      final fr = decodeOne(0x2B, [0x10, 0x2C, 0x28, 0x14]);
      expect(fr.b(4), 0x10);
      expect(fr.b(5), 0x2C);
      expect(fr.b(6), 0x28);
      expect(fr.b(7), 0x14);
      expect(fr.len, 4);
      expect(fr.flag, 0x01);
    });

    test('b() returns 0 out of range; u16 is big-endian', () {
      final fr = decodeOne(0x19, [0x04, 0xD4]);
      expect(fr.u16(4), 0x04 * 256 + 0xD4); // 1236
      expect(fr.b(99), 0);
      expect(fr.b(3), 0); // before payload
    });
  });

  // =========================================================================
  // 4. Telemetry decode formulas (static, hand-computed expected values)
  // =========================================================================
  group('Telemetry formulas', () {
    test('PVLT 0x19 = u16/100', () {
      expect(TelemetryDecoder.pvlt(decodeOne(0x19, [0x04, 0xD4])),
          closeTo(12.36, 1e-9));
      expect(TelemetryDecoder.pvlt(decodeOne(0x19, [0x00, 0x00])),
          closeTo(0.0, 1e-9));
    });

    test('SVLT 0x37 = u16/100', () {
      expect(TelemetryDecoder.svlt(decodeOne(0x37, [0x04, 0xCF])),
          closeTo(12.31, 1e-9));
    });

    test('temperature 0x21 = signed int8 (positive)', () {
      expect(TelemetryDecoder.temperature(decodeOne(0x21, [0x2D])), 45);
      expect(TelemetryDecoder.temperature(decodeOne(0x21, [0x2E])), 46);
      expect(TelemetryDecoder.temperature(decodeOne(0x21, [0x7F])), 127);
    });

    test('temperature 0x21 = signed int8 (negative + boundaries)', () {
      expect(TelemetryDecoder.temperature(decodeOne(0x21, [0xFB])), -5);
      expect(TelemetryDecoder.temperature(decodeOne(0x21, [0xFF])), -1);
      expect(TelemetryDecoder.temperature(decodeOne(0x21, [0x80])), -128);
      expect(TelemetryDecoder.temperature(decodeOne(0x21, [0x00])), 0);
    });

    test('current 0x2E = 512 - u16 (zero / positive / negative)', () {
      expect(TelemetryDecoder.current(decodeOne(0x2E, [0x02, 0x00])), 0);
      // u16 = 500 -> 12 A
      expect(TelemetryDecoder.current(decodeOne(0x2E, [0x01, 0xF4])), 12);
      // u16 = 600 -> -88 A (discharge sign)
      expect(TelemetryDecoder.current(decodeOne(0x2E, [0x02, 0x58])), -88);
    });

    test('VADJ 0x30 = u16/100', () {
      expect(TelemetryDecoder.vadj(decodeOne(0x30, [0x00, 0x64])),
          closeTo(1.0, 1e-9));
      expect(TelemetryDecoder.vadj(decodeOne(0x30, [0x00, 0x6E])),
          closeTo(1.10, 1e-9));
    });

    test('DVOL 0x24 = (b[i]/1000)*VADJ for i=4..7', () {
      // bytes 10,20,30,40 with scale 2.0 -> 0.02,0.04,0.06,0.08
      final f = decodeOne(0x24, [0x0A, 0x14, 0x1E, 0x28]);
      final d = TelemetryDecoder.dvol(f, 2.0);
      expect(d.length, 4);
      expect(d[0], closeTo(0.02, 1e-9));
      expect(d[1], closeTo(0.04, 1e-9));
      expect(d[2], closeTo(0.06, 1e-9));
      expect(d[3], closeTo(0.08, 1e-9));
    });

    test('thresholds 0x2B: OV/UV/OT (capture values)', () {
      // payload 10 2C 28 14 -> OV 14.8 V, UV 11.5 V, OT 100 C.
      final f = decodeOne(0x2B, [0x10, 0x2C, 0x28, 0x14]);
      expect(TelemetryDecoder.warnOv(f), closeTo(14.8, 1e-9));
      expect(TelemetryDecoder.warnUv(f), closeTo(11.5, 1e-9));
      expect(TelemetryDecoder.warnOt(f), closeTo(100.0, 1e-9));
    });

    test('charge 0x41 / discharge 0x4A = u16/1000 (v1,v2)', () {
      final f = decodeOne(0x41, [0x04, 0xD4, 0x04, 0xCF]);
      expect(TelemetryDecoder.scaled1000(f, 4), closeTo(1.236, 1e-9));
      expect(TelemetryDecoder.scaled1000(f, 6), closeTo(1.231, 1e-9));
    });

    test('capacity 0x96: raw byte b6 and SOH bucket (n-1)*10+5', () {
      final f = decodeOne(0x96, [0x00, 0x00, 0x05, 0x00]);
      expect(TelemetryDecoder.capacityRaw(f), 5);
      expect(TelemetryDecoder.sohBucket(f), 45); // (5-1)*10+5
      final f2 = decodeOne(0x96, [0x00, 0x00, 0x0A, 0x00]);
      expect(TelemetryDecoder.sohBucket(f2), 95); // (10-1)*10+5
    });

    test('serial 0x25/0x26: 48-bit BE packed, padLeft(6)', () {
      // 00 00 00 00 12 34 -> 0x1234 = 4660 -> "004660"
      final f = decodeOne(0x26, [0, 0, 0, 0, 0x12, 0x34]);
      expect(TelemetryDecoder.serial(f), '004660');
    });

    test('dealerCode 0x27: "%04d%02X%02X"', () {
      // b4*256+b5 = 168 -> "0168"; b6=01 -> "01"; b7=02 -> "02"
      final f = decodeOne(0x27, [0x00, 0xA8, 0x01, 0x02]);
      expect(TelemetryDecoder.dealerCode(f), '01680102');
    });

    test('dealerCode 0x27: hex bytes upper-cased', () {
      final f = decodeOne(0x27, [0x00, 0xA8, 0xAB, 0xCD]);
      expect(TelemetryDecoder.dealerCode(f), '0168ABCD');
    });

    test('pvltGaugeIndex = trunc((PVLT-8)*3.5), clamp 0..28', () {
      expect(TelemetryDecoder.pvltGaugeIndex(12.36), 15); // 4.36*3.5=15.26
      expect(TelemetryDecoder.pvltGaugeIndex(8.0), 0);
      expect(TelemetryDecoder.pvltGaugeIndex(16.0), 28); // 8*3.5=28
      expect(TelemetryDecoder.pvltGaugeIndex(20.0), 28); // clamp high
      expect(TelemetryDecoder.pvltGaugeIndex(7.0), 0); // clamp low
    });
  });

  // =========================================================================
  // 5. Selector dispatch (apply / ingest fold into the right field)
  // =========================================================================
  group('Selector dispatch', () {
    final at = DateTime.utc(2026, 6, 29);
    final base = TelemetrySample.empty(at);

    test('0x19 PVLT sets pvlt AND derived gauge index', () {
      final s =
          TelemetryDecoder.apply(base, decodeOne(0x19, [0x04, 0xD4]), at: at);
      expect(s.pvlt, closeTo(12.36, 1e-9));
      expect(s.pvltGaugeIndex, 15);
    });

    test('0x37 -> svlt, 0x21 -> temperatureC, 0x2E -> current', () {
      expect(
          TelemetryDecoder.apply(base, decodeOne(0x37, [0x04, 0xCF]), at: at)
              .svlt,
          closeTo(12.31, 1e-9));
      expect(
          TelemetryDecoder.apply(base, decodeOne(0x21, [0xFB]), at: at)
              .temperatureC,
          -5);
      expect(
          TelemetryDecoder.apply(base, decodeOne(0x2E, [0x02, 0x00]), at: at)
              .current,
          0);
    });

    test('0x30 -> vadj, 0x2B -> warn OV/UV/OT', () {
      expect(
          TelemetryDecoder.apply(base, decodeOne(0x30, [0x00, 0x64]), at: at)
              .vadj,
          closeTo(1.0, 1e-9));
      final t =
          TelemetryDecoder.apply(base, decodeOne(0x2B, [0x10, 0x2C, 0x28, 0x14]),
              at: at);
      expect(t.warnOv, closeTo(14.8, 1e-9));
      expect(t.warnUv, closeTo(11.5, 1e-9));
      expect(t.warnOt, closeTo(100.0, 1e-9));
    });

    test('0x41 -> chargeV1/V2, 0x4A -> dischargeV1/V2', () {
      final c = TelemetryDecoder.apply(
          base, decodeOne(0x41, [0x04, 0xD4, 0x04, 0xCF]),
          at: at);
      expect(c.chargeV1, closeTo(1.236, 1e-9));
      expect(c.chargeV2, closeTo(1.231, 1e-9));
      final d = TelemetryDecoder.apply(
          base, decodeOne(0x4A, [0x04, 0xD4, 0x04, 0xCF]),
          at: at);
      expect(d.dischargeV1, closeTo(1.236, 1e-9));
      expect(d.dischargeV2, closeTo(1.231, 1e-9));
    });

    test('0x96 -> capacityRaw + sohBucket', () {
      final s =
          TelemetryDecoder.apply(base, decodeOne(0x96, [0, 0, 0x05, 0]), at: at);
      expect(s.capacityRaw, 5);
      expect(s.sohBucket, 45);
    });

    test('0x10 device-type -> deviceType + isPowerBank', () {
      final pb =
          TelemetryDecoder.apply(base, decodeOne(0x10, [0x44]), at: at);
      expect(pb.deviceType, 0x44);
      expect(pb.isPowerBank, isTrue);
      final notPb =
          TelemetryDecoder.apply(base, decodeOne(0x10, [0x17]), at: at);
      expect(notPb.deviceType, 0x17);
      expect(notPb.isPowerBank, isFalse);
    });

    test('0x25/0x26 -> serial, 0x27 -> dealerCode', () {
      expect(
          TelemetryDecoder.apply(
                  base, decodeOne(0x25, [0, 0, 0, 0, 0x12, 0x34]), at: at)
              .serial,
          '004660');
      expect(
          TelemetryDecoder.apply(
                  base, decodeOne(0x26, [0, 0, 0, 0, 0x12, 0x34]), at: at)
              .serial,
          '004660');
      expect(
          TelemetryDecoder.apply(
                  base, decodeOne(0x27, [0x00, 0xA8, 0x01, 0x02]), at: at)
              .dealerCode,
          '01680102');
    });

    test('0x23 -> mode, 0x20 -> twfRaw', () {
      expect(TelemetryDecoder.apply(base, decodeOne(0x23, [0x05]), at: at).mode,
          0x05);
      expect(TelemetryDecoder.apply(base, decodeOne(0x23, [0x06]), at: at).mode,
          0x06);
      expect(
          TelemetryDecoder.apply(base, decodeOne(0x20, [0x00]), at: at).twfRaw,
          0x00);
    });

    test('unknown selector (0x2F secondary current) is a no-op', () {
      final s =
          TelemetryDecoder.apply(base, decodeOne(0x2F, [0x01, 0x02]), at: at);
      expect(identical(s, base), isTrue);
    });

    test('undocumented selectors (0x28/0x29/0x2C) are no-ops', () {
      for (final sel in [0x28, 0x29, 0x2C]) {
        final s =
            TelemetryDecoder.apply(base, decodeOne(sel, [0x00, 0x00]), at: at);
        expect(identical(s, base), isTrue,
            reason: 'selector 0x${sel.toRadixString(16)} should not store');
      }
    });
  });

  // =========================================================================
  // 6. TelemetryDecoder accumulator (stateful folding; DVOL needs prior VADJ)
  // =========================================================================
  group('TelemetryDecoder accumulator', () {
    final at = DateTime.utc(2026, 6, 29);

    test('folds successive frames into one sample', () {
      final dec = TelemetryDecoder();
      dec.ingest(decodeOne(0x19, [0x04, 0xD4]), at: at); // PVLT
      dec.ingest(decodeOne(0x21, [0x2D]), at: at); // temp
      dec.ingest(decodeOne(0x2E, [0x02, 0x00]), at: at); // current
      final s = dec.sample;
      expect(s.pvlt, closeTo(12.36, 1e-9));
      expect(s.temperatureC, 45);
      expect(s.current, 0);
    });

    test('DVOL uses the previously-seen VADJ from state', () {
      final dec = TelemetryDecoder();
      dec.ingest(decodeOne(0x30, [0x00, 0x6E]), at: at); // VADJ = 1.10
      dec.ingest(decodeOne(0x24, [0xC8, 0x64, 0x32, 0x19]), at: at);
      // 200,100,50,25 -> /1000 * 1.10
      final d = dec.sample.dvol!;
      expect(d[0], closeTo(0.22, 1e-9));
      expect(d[1], closeTo(0.11, 1e-9));
      expect(d[2], closeTo(0.055, 1e-9));
      expect(d[3], closeTo(0.0275, 1e-9));
    });

    test('DVOL before any VADJ falls back to scale 1.0', () {
      final dec = TelemetryDecoder();
      dec.ingest(decodeOne(0x24, [0x0A, 0x14, 0x1E, 0x28]), at: at);
      final d = dec.sample.dvol!;
      expect(d[0], closeTo(0.010, 1e-9)); // 10/1000 * 1.0
      expect(d[3], closeTo(0.040, 1e-9));
    });

    test('ingest is a no-op on a bad-checksum frame', () {
      final dec = TelemetryDecoder();
      final bad = FrameReassembler()
          .addBytes(inboundBytes(0x19, [0x04, 0xD4], badXor: 0x00))
          .single;
      expect(bad.checksumOk, isFalse);
      final before = dec.sample;
      final after = dec.ingest(bad, at: at);
      expect(after.pvlt, isNull);
      expect(identical(after, before), isTrue);
    });

    test('ingest is a no-op on an unknown selector', () {
      final dec = TelemetryDecoder();
      final before = dec.sample;
      dec.ingest(decodeOne(0x2F, [0x01, 0x02]), at: at);
      expect(identical(dec.sample, before), isTrue);
    });

    test('reset() returns to an empty sample', () {
      final dec = TelemetryDecoder();
      dec.ingest(decodeOne(0x19, [0x04, 0xD4]), at: at);
      expect(dec.sample.pvlt, isNotNull);
      dec.reset();
      expect(dec.sample.pvlt, isNull);
    });
  });

  // =========================================================================
  // 7. GATT transport constants (barrel surface)
  // =========================================================================
  group('Gatt constants', () {
    test('UUIDs, CCCD enable value, default MTU', () {
      expect(Gatt.serviceUuid, '07b9fff0-d55f-5e82-ba44-81c0da86c46c');
      expect(Gatt.writeCharUuid, '07b9ace3-d55f-5e82-ba44-81c0da86c46c');
      expect(Gatt.notifyCharUuid, '07b9ace4-d55f-5e82-ba44-81c0da86c46c');
      expect(Gatt.cccdUuid, '00002902-0000-1000-8000-00805f9b34fb');
      expect(Gatt.enableNotifyValue, [0x01, 0x00]);
      expect(Gatt.defaultMtu, 23);
    });
  });
}
