/// OpenSmartBatt — inbound notification frame model + stream reassembler.
///
/// PURE Dart, no IO. The BLE layer feeds raw notification chunks into
/// [FrameReassembler.addBytes]; sub-frames fragment across ATT packets, so the
/// receiver MUST reassemble one byte stream and frame by LEN (live HCI capture
/// §1). Per-packet `byte[1]=selector` parsing is invalid.
///
/// Inbound frame (live HCI capture):
///     [0xB8, selector, 0x01, LEN, payload(LEN bytes), XOR]
///   * byte[0] = 0xB8 sync
///   * byte[1] = selector (dispatch key)
///   * byte[2] = 0x01 (constant on every inbound frame)
///   * byte[3] = LEN (payload length)
///   * byte[4..] = payload; 16-bit values big-endian
///   * trailing = XOR-fold of all preceding bytes
///   * total length = LEN + 5
library;

import 'dart:typed_data';

import 'frame.dart';

/// One parsed, checksum-validated inbound notification frame.
class InboundFrame {
  /// Dispatch key: byte[1]. See [Selectors].
  final int selector;

  /// byte[2] flag (0x01 on every inbound frame observed).
  final int flag;

  /// Declared payload length (byte[3]).
  final int len;

  /// Payload bytes (`payload[0]` is the spec's `b4`).
  final Uint8List payload;

  /// True if the trailing XOR matched the fold of the preceding bytes.
  final bool checksumOk;

  const InboundFrame({
    required this.selector,
    required this.flag,
    required this.len,
    required this.payload,
    required this.checksumOk,
  });

  /// Spec-indexed byte access: `b(4)` == `payload[0]`. Returns 0 if out of range.
  int b(int specIndex) {
    final i = specIndex - 4;
    if (i < 0 || i >= payload.length) return 0;
    return payload[i];
  }

  /// Big-endian 16-bit read at spec index: `b(i)*256 + b(i+1)`.
  int u16(int specIndex) => b(specIndex) * 256 + b(specIndex + 1);

  @override
  String toString() =>
      'InboundFrame(selector=0x${selector.toRadixString(16)}, '
      'len=$len, payload=${payload.map((e) => e.toRadixString(16).padLeft(2, '0')).join()}, '
      'crc=${checksumOk ? 'ok' : 'BAD'})';
}

/// Accumulates raw BLE notification bytes and emits complete [InboundFrame]s.
///
/// Stateful but pure (no IO): deterministic for a given byte sequence. Tolerant
/// of fragmentation and of leading garbage — it resyncs on the next 0xB8.
class FrameReassembler {
  final List<int> _buf = <int>[];

  /// Drop everything buffered (e.g. on disconnect / reconnect).
  void reset() => _buf.clear();

  /// Number of bytes currently buffered awaiting a full frame.
  int get buffered => _buf.length;

  /// Feed one notification chunk; returns every complete frame now decodable.
  ///
  /// Frames whose XOR fails are still returned, with [InboundFrame.checksumOk]
  /// = false, so the diagnostics layer can surface corruption rather than
  /// silently dropping bytes.
  List<InboundFrame> addBytes(List<int> chunk) {
    _buf.addAll(chunk.map((b) => b & 0xFF));
    final out = <InboundFrame>[];

    while (true) {
      // Resync: discard until a sync byte leads the buffer.
      final sync = _buf.indexOf(kSyncByte);
      if (sync < 0) {
        _buf.clear();
        break;
      }
      if (sync > 0) {
        _buf.removeRange(0, sync);
      }
      // Need at least header (4 bytes) to read LEN.
      if (_buf.length < 4) break;
      final len = _buf[3];
      final total = len + 5; // sync+sel+flag+len + payload + xor
      if (_buf.length < total) break; // wait for more bytes

      final frameBytes = _buf.sublist(0, total);
      final expectedXor = xorFold(frameBytes.sublist(0, total - 1));
      final actualXor = frameBytes[total - 1];
      var ok = expectedXor == actualXor;
      if (ok) {
        // A passing XOR is not proof the frame is real — see [_boundary].
        final verdict = _boundary(total);
        if (verdict == _Boundary.undecided) break; // wait for more bytes
        if (verdict == _Boundary.hijacked) ok = false;
      }
      out.add(InboundFrame(
        selector: frameBytes[1],
        flag: frameBytes[2],
        len: len,
        payload: Uint8List.fromList(frameBytes.sublist(4, 4 + len)),
        checksumOk: ok,
      ));
      // 🔴 FB-117. A bad XOR (or a hijacked frame, see [_boundary]) means LEN
      // cannot be trusted to say where this frame ends: the usual cause is a lost notification fragment, and then
      // the "frame" above was completed out of the NEXT frame's opening bytes.
      // Consuming all `total` bytes used to throw that next frame away with it
      // (field `2026.10.14/001`: PVLT survived 11 of 3,041 in a background
      // stretch). Drop only the sync byte and resync — the same rule
      // `tools/fbparse.py` uses, which kept all 3,041.
      _buf.removeRange(0, ok ? total : 1);
    }
    return out;
  }

  /// Does the XOR-passing frame at `[0, total)` really end where it says?
  ///
  /// A truncated fragment — sync, selector, flag, LEN, payload lost — can be
  /// completed by the NEXT frame's opening bytes and still pass the XOR,
  /// because only one byte has to come out right. Field: CSV rows with TWF
  /// `184` (`0x20` = `b8`) and cells 3.68 / 0.64 V (`0x24` ending `b8 20`),
  /// 28 of them across four batteries, while 178 million logged frames never
  /// carried `0x20` = `b8` (feedback `2026.11.26/006` §2). `tools/fbparse.py`
  /// has rejected these since 2026-08-26 (`_hijacks_next_frame`); this is the
  /// same rule, and BOTH conditions are needed:
  ///
  /// 1. the stream does not continue on a frame boundary (the next byte is
  ///    not a sync byte), and
  /// 2. a sync byte inside the frame's own body starts a well-formed frame
  ///    that does end on a boundary — the reading that keeps the stream
  ///    aligned.
  ///
  /// Condition 2 keeps a real frame whose payload holds `0xB8`, and a real
  /// frame followed by stray bytes, from being thrown away. Only the payload
  /// is searched, not the XOR byte: a frame whose XOR happens to be `0xB8`
  /// (`0x21` at 33 °C is `b8 21 01 01 21 b8`) is ordinary.
  ///
  /// A frame that ends exactly where the buffer does is accepted at once, as
  /// fbparse does at end of input — otherwise the last frame of a
  /// notification would wait for the next one. A hijack needs the next
  /// notification to start with a real frame, so in the field the fake is
  /// followed by that frame in the same buffer and is caught. Only when the
  /// frame is followed by a non-sync byte AND a sync byte in its payload
  /// starts a frame that has not fully arrived is it too early to tell: then
  /// it waits for the next chunk ([_Boundary.undecided]).
  _Boundary _boundary(int total) {
    final n = _buf.length;
    if (total >= n || _buf[total] == kSyncByte) return _Boundary.real;
    var undecided = false;
    for (var k = 4; k < total - 1; k++) {
      if (_buf[k] != kSyncByte) continue;
      final end = _wellFormedEnd(k);
      if (end == _incomplete) {
        undecided = true;
      } else if (end != null && (end == n || _buf[end] == kSyncByte)) {
        return _Boundary.hijacked;
      }
    }
    return undecided ? _Boundary.undecided : _Boundary.real;
  }

  static const int _incomplete = -1;

  /// End offset of a well-formed frame (sync, flag 0x01, LEN fits, XOR) at
  /// [i]; [_incomplete] if the buffer stops before it can tell; null if not.
  int? _wellFormedEnd(int i) {
    final n = _buf.length;
    if (i + 4 > n) return _incomplete;
    if (_buf[i + 2] != 0x01) return null;
    final end = i + 4 + _buf[i + 3] + 1;
    if (end > n) return _incomplete;
    return xorFold(_buf.sublist(i, end - 1)) == _buf[end - 1] ? end : null;
  }
}

enum _Boundary { real, hijacked, undecided }
