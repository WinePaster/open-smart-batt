// A truncated fragment completed out of the NEXT frame's opening bytes can
// pass the XOR. The app used to accept it: CSV rows with TWF 184 (`0x20` =
// `b8`) and cells 3.68 / 0.64 V (`0x24` ending `b8 20`), while no logged frame
// ever carried `0x20` = `b8` (feedback `2026.11.26/006` §2). `tools/fbparse.py`
// rejects these since 2026-08-26; the reassembler now applies the same rule.
//
// CLEAN-ROOM: expectations derive from this project's own framing rules.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

List<int> frame(int selector, List<int> payload) {
  final body = <int>[0xB8, selector, 0x01, payload.length, ...payload];
  return <int>[...body, xorFold(body)];
}

List<String> good(List<InboundFrame> out) => [
      for (final f in out)
        if (f.checksumOk)
          '${f.selector.toRadixString(16)}:'
              '${f.payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'
    ];

void main() {
  final twf = frame(0x20, [0x00]); // b8 20 01 01 00 98
  final cells = frame(0x24, [0xA6, 0xA6, 0xA5, 0xA7]);
  final pvlt = frame(0x19, [0x05, 0x32]);

  group('fragment completed by the next frame', () {
    test('0x20 head + real 0x20: one TWF 00, never b8', () {
      // Field shape (2026.08.26/004): `b8 20 01 01` then `b8 20 01 01 00 98`.
      // `b8 20 01 01 b8 20` passes the XOR on its own.
      final head = twf.sublist(0, 4);
      final out = FrameReassembler().addBytes([...head, ...twf, ...pvlt]);
      expect(good(out), ['20:00', '19:0532']);
    });

    test('0x24 head + real 0x20: no 0.64 V cell', () {
      // `b8 24 01 04 a6 a6` + `b8 20` would read cells a6 a6 b8 20.
      final head = cells.sublist(0, 6);
      final out = FrameReassembler().addBytes([...head, ...twf, ...pvlt]);
      expect(good(out), ['20:00', '19:0532']);
    });

    test('same when the real frame arrives in a later notification', () {
      final r = FrameReassembler();
      final got = <String>[];
      // The head waits (LEN says more is coming); the next notification
      // starts with the real frame and completes the fake.
      for (final chunk in [twf.sublist(0, 4), [...twf, ...pvlt]]) {
        got.addAll(good(r.addBytes(chunk)));
      }
      expect(got, ['20:00', '19:0532']);
      expect(r.buffered, 0);
    });
  });

  group('real frames are not thrown away', () {
    test('payload holding 0xB8, followed by a frame', () {
      final withSync = frame(0x2B, [0xB8, 0x01, 0x02, 0x14]);
      final out = FrameReassembler().addBytes([...withSync, ...pvlt]);
      expect(good(out), ['2b:b8010214', '19:0532']);
    });

    test('a frame followed by stray bytes is still delivered', () {
      final odd = frame(0x14, [0x00, 0x00, 0xC3, 0x50]);
      final out = FrameReassembler().addBytes([...odd, 0x00, 0x11]);
      expect(good(out), ['14:0000c350']);
    });

    test('a frame at the end of the buffer is delivered at once', () {
      final r = FrameReassembler();
      expect(good(r.addBytes(twf)), ['20:00']);
      expect(r.buffered, 0);
    });

    test('0xB8 in the payload at the end of a chunk: delivered at once', () {
      final withSync = frame(0x24, [0xB8, 0xB8, 0xB7, 0xB8]);
      final r = FrameReassembler();
      expect(good(r.addBytes(withSync)), ['24:b8b8b7b8']);
      expect(r.buffered, 0);
    });

    test('an XOR byte of 0xB8 is not a sync byte (0x21 at 33 °C)', () {
      final t33 = frame(0x21, [0x21]);
      expect(t33.last, 0xB8);
      final r = FrameReassembler();
      expect(good(r.addBytes(t33)), ['21:21']);
      expect(good(r.addBytes([...t33, 0x00, 0x11])), ['21:21']);
    });

    test('stray byte after a frame whose payload starts an unfinished frame: '
        'waits, then delivers', () {
      // Payload `b8 21 01 05` then a stray `00`: from the payload's `b8` a
      // LEN-5 frame could still be arriving, so it is too early to tell.
      final withSync = frame(0x2B, [0xB8, 0x21, 0x01, 0x05]);
      final r = FrameReassembler();
      expect(good(r.addBytes([...withSync, 0x00])), isEmpty);
      expect(good(r.addBytes([0x00, 0x00, ...pvlt])),
          ['2b:b8210105', '19:0532']);
    });

    test('back-to-back frames in one chunk', () {
      final out = FrameReassembler().addBytes([...pvlt, ...twf, ...cells]);
      expect(good(out), ['19:0532', '20:00', '24:a6a6a5a7']);
    });
  });
}
