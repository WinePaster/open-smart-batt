// FB-117 — a bad-XOR frame used to take the NEXT frame down with it.
//
// When a notification fragment is lost, the reassembler sees the surviving
// head of frame A (sync, selector, flag, LEN, part of the payload) followed
// directly by frame B. It trusted A's LEN, borrowed B's opening bytes to fill
// it, failed the XOR — and then consumed all of those bytes, so B was gone too.
// Field: `2026.10.14/001`, a 13-minute background stretch where PVLT survived
// 11 of 3,041 frames in the app while `tools/fbparse.py` (resync one byte in)
// kept all of them.
//
// CLEAN-ROOM: expectations derive from this project's own framing rules.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

List<int> frame(int selector, List<int> payload) {
  final body = <int>[0xB8, selector, 0x01, payload.length, ...payload];
  return <int>[...body, xorFold(body)];
}

void main() {
  group('FB-117 resync after a bad XOR', () {
    // A 0x37 frame (LEN 2) whose last payload byte + XOR were lost, then a
    // full PVLT frame. A's LEN pulls B's first two bytes in to "complete" it.
    final a = frame(0x37, [0x04, 0xCF]);
    final b = frame(0x19, [0x04, 0xD4]);
    final c = frame(0x21, [0x2D]);
    final aHead = a.sublist(0, a.length - 2);

    test('the frame after a lost fragment is recovered', () {
      final out = FrameReassembler().addBytes([...aHead, ...b, ...c]);
      final good = out.where((f) => f.checksumOk).map((f) => f.selector);
      expect(good, [0x19, 0x21]);
      // The damaged head is still surfaced, flagged, for diagnostics.
      expect(out.where((f) => !f.checksumOk), isNotEmpty);
    });

    test('same when the bytes arrive chunk by chunk', () {
      final r = FrameReassembler();
      final got = <int>[];
      for (final chunk in [aHead, b.sublist(0, 3), b.sublist(3), c]) {
        got.addAll(r.addBytes(chunk).where((f) => f.checksumOk).map((f) => f.selector));
      }
      expect(got, [0x19, 0x21]);
      expect(r.buffered, 0);
    });

    test('a good frame whose payload holds 0xB8 is still consumed whole', () {
      final withSync = frame(0x2B, [0xB8, 0x01, 0x02, 0x14]);
      final out = FrameReassembler().addBytes([...withSync, ...b]);
      expect(out.map((f) => f.selector), [0x2B, 0x19]);
      expect(out.every((f) => f.checksumOk), isTrue);
    });
  });
}
