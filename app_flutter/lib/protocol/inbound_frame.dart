/// Open-RCE-Batt — inbound notification frame model + stream reassembler.
///
/// PURE Dart, no IO. The BLE layer feeds raw notification chunks into
/// [FrameReassembler.addBytes]; sub-frames fragment across ATT packets, so the
/// receiver MUST reassemble one byte stream and frame by LEN (CAPTURE_VERIFIED
/// §1). Per-packet `byte[1]=selector` parsing is invalid.
///
/// Inbound frame (CAPTURE_VERIFIED §1):
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
      out.add(InboundFrame(
        selector: frameBytes[1],
        flag: frameBytes[2],
        len: len,
        payload: Uint8List.fromList(frameBytes.sublist(4, 4 + len)),
        checksumOk: expectedXor == actualXor,
      ));
      _buf.removeRange(0, total);
    }
    return out;
  }
}
