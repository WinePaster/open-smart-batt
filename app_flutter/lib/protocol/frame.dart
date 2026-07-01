/// OpenSmartBatt — binary frame primitives.
///
/// PURE Dart. No Flutter / no IO imports. Everything here is a deterministic
/// pure function so it can be unit-tested directly.
///
/// Outbound binary command frame layout (PROTOCOL.md §4.1):
///
///     [0xB8, CMD, flag, LEN, payload(0..LEN-1)..., XOR]
///
///   * 0xB8 (184) — sync / start byte.
///   * CMD       — command code (0x23 mode, 0x2A auth, 0x2B thresholds).
///   * flag      — byte[2]. PROTOCOL.md calls it "reserved 0x00"; CAPTURE_VERIFIED
///                 shows it is a role/flag bit: 0x00 on a standalone auth or a
///                 mode sub-frame, 0x01 on an auth sub-frame bundled with a mode
///                 change. NOT a length-high byte (LEN lives in byte[3]).
///   * LEN       — number of payload bytes.
///   * payload   — LEN bytes; multi-byte fields are big-endian (hi first).
///   * XOR       — checksum = XOR-fold of ALL preceding bytes in the frame.
library;

import 'dart:typed_data';

/// The sync / start byte for every binary frame (inbound and outbound).
const int kSyncByte = 0xB8;

/// The single-byte ASCII keep-alive token `#` (0x23). Written ~1 Hz / bursty to
/// the write characteristic to make the battery stream telemetry.
const int kKeepAliveByte = 0x23;

/// XOR-fold checksum used by every binary frame (PROTOCOL.md §7).
///
/// `getCheckSum(list) = list.reduce((a, b) => a ^ b)` over all bytes given.
/// The single-byte result is appended as the final element of an outbound frame.
/// Throws [ArgumentError] on an empty list (matching `reduce` semantics).
int xorFold(List<int> bytes) {
  if (bytes.isEmpty) {
    throw ArgumentError.value(bytes, 'bytes', 'xorFold requires >= 1 byte');
  }
  var acc = bytes.first & 0xFF;
  for (var i = 1; i < bytes.length; i++) {
    acc ^= bytes[i] & 0xFF;
  }
  return acc & 0xFF;
}

/// Builds one outbound binary frame `[0xB8, cmd, flag, len, ...payload, xor]`.
///
/// [len] defaults to `payload.length`. Pass an explicit [len] only to reproduce
/// a deliberately mismatched header (e.g. for tests). The XOR is folded over the
/// header + payload, then appended.
Uint8List buildFrame(
  int cmd,
  List<int> payload, {
  int flag = 0x00,
  int? len,
}) {
  final length = len ?? payload.length;
  final head = <int>[kSyncByte, cmd & 0xFF, flag & 0xFF, length & 0xFF];
  final body = <int>[...head, ...payload.map((b) => b & 0xFF)];
  final xor = xorFold(body);
  return Uint8List.fromList([...body, xor]);
}

/// Concatenates several byte sequences into one outbound write payload.
///
/// Used by `switchMode`, which writes the mode sub-frame immediately followed by
/// the auth sub-frame in a single Write-Without-Response (CAPTURE_VERIFIED: the
/// 15-byte mode++auth packet, no trailing context payload).
Uint8List concatFrames(Iterable<List<int>> frames) {
  final out = <int>[];
  for (final f in frames) {
    out.addAll(f);
  }
  return Uint8List.fromList(out);
}
