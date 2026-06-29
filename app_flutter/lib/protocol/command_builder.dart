/// Open-RCE-Batt — outbound command builders (PROTOCOL.md §5 / §6, plus
/// CAPTURE_VERIFIED §6 replay).
///
/// PURE Dart. Every builder returns the exact bytes that go on the wire to the
/// write characteristic (07b9ace3-…, Write-Without-Response). All deterministic
/// and unit-testable.
library;

import 'dart:typed_data';

import 'frame.dart';
import 'selectors.dart';

/// Battery-specific auth credentials (CAPTURE_VERIFIED §6).
///
/// `cb`    — 16-bit echo derived from the device's dealer code (selector 0x27),
///           broadcast in the clear by the device itself.
/// `pwSum` — 16-bit sum of the cut-off password's char-code units. Never the
///           plaintext password; only its checksum travels on the wire.
///
/// Both are redacted/unknown in the spec — they are accepted as runtime inputs.
class AuthCredentials {
  /// 16-bit dealer-derived echo value (`cb`).
  final int cb;

  /// 16-bit password char-code checksum (`pwSum`).
  final int pwSum;

  const AuthCredentials({required this.cb, required this.pwSum});

  /// High byte of `cb`. PROTOCOL.md §6.1 notes the app does NOT mask this byte
  /// (decimal int.parse may exceed 255); we expose the raw shift and let the
  /// frame builder truncate to a byte on the wire. For the observed 3-digit
  /// field_cb the high byte is 0x00.
  int get cbHi => cb >> 8;

  /// Low byte of `cb`.
  int get cbLo => cb & 0xFF;

  /// High byte of `pwSum`.
  int get pwHi => pwSum >> 8;

  /// Low byte of `pwSum`.
  int get pwLo => pwSum & 0xFF;
}

/// Stateless factory for every outbound frame.
class CommandBuilder {
  const CommandBuilder();

  /// 16-bit password checksum = sum of `password`'s UTF-16 code units
  /// (PROTOCOL.md §6.1). Caller may then pass it as [AuthCredentials.pwSum].
  static int passwordChecksum(String password) {
    var sum = 0;
    for (final c in password.codeUnits) {
      sum += c;
    }
    return sum & 0xFFFF;
  }

  /// Derives the auth echo `cb` from a field_cb string (PROTOCOL.md §6.1):
  /// `v = int.parse(fieldCb.substring(0,8))` in BASE 10, then `cbHi = v >> 8`,
  /// `cbLo = v & 0xFF`. Returns the raw 16-bit-ish value `v & 0xFFFF`-equivalent
  /// pairing as a [cb] where cbHi may exceed a byte; see [AuthCredentials.cbHi].
  static int cbFromFieldCb(String fieldCb) {
    if (fieldCb.length < 8) {
      throw ArgumentError.value(fieldCb, 'fieldCb', 'need >= 8 chars');
    }
    return int.parse(fieldCb.substring(0, 8));
  }

  /// Keep-alive: the single byte 0x23 ('#'). Not a framed command.
  Uint8List keepAlive() => Uint8List.fromList(const [kKeepAliveByte]);

  /// Mode-set sub-frame: `[B8, 23, flag, 01, mode, XOR]` (PROTOCOL.md §5.1).
  /// [flag] is byte[2]; 0x00 for a standalone mode write.
  Uint8List modeSet(int mode, {int flag = 0x00}) =>
      buildFrame(Commands.modeSet, [mode & 0xFF], flag: flag);

  /// Auth sub-frame: `[B8, 2A, flag, 04, cbHi, cbLo, pwHi, pwLo, XOR]`.
  ///
  /// [flag] is byte[2]: 0x00 standalone (verify-auth), 0x01 when bundled with a
  /// mode change (CAPTURE_VERIFIED §1).
  Uint8List auth(AuthCredentials creds, {int flag = 0x00}) => buildFrame(
        Commands.auth,
        [creds.cbHi, creds.cbLo, creds.pwHi, creds.pwLo],
        flag: flag,
      );

  /// switchMode: mode sub-frame ++ auth sub-frame in ONE write (PROTOCOL.md §6.2,
  /// CAPTURE_VERIFIED §6 — 15 bytes, no trailing context payload).
  ///
  /// The bundled auth carries flag byte[2] = 0x01 (the captured bundled variant).
  Uint8List switchMode(int mode, AuthCredentials creds) => concatFrames([
        modeSet(mode, flag: 0x00),
        auth(creds, flag: 0x01),
      ]);

  /// Threshold-set frame from raw bytes:
  /// `[B8, 2B, flag, 04, ovByte, uvByte, otByte, trailing, XOR]`.
  Uint8List thresholdsRaw(
    int ovByte,
    int uvByte,
    int otByte, {
    int trailing = 0x00,
    int flag = 0x00,
  }) =>
      buildFrame(
        Commands.thresholds,
        [ovByte & 0xFF, uvByte & 0xFF, otByte & 0xFF, trailing & 0xFF],
        flag: flag,
      );

  /// Threshold-set frame from physical units (PROTOCOL.md §8.3 write inverse):
  ///   OV_byte = round((ovVolts - 14.4) / 0.025)
  ///   UV_byte = round((uvVolts - 10.4) / 0.025)
  ///   OT_byte = round(otCelsius - 60)
  Uint8List thresholds({
    required double ovVolts,
    required double uvVolts,
    required double otCelsius,
    int trailing = 0x00,
    int flag = 0x00,
  }) {
    final ov = ((ovVolts - 14.4) / 0.025).round();
    final uv = ((uvVolts - 10.4) / 0.025).round();
    final ot = (otCelsius - 60).round();
    return thresholdsRaw(ov, uv, ot, trailing: trailing, flag: flag);
  }

  /// changeCutOffPassword (PROTOCOL.md §6.3): same 0x2A channel, but pwSum is the
  /// checksum of the NEW password. Identical frame shape to [auth].
  Uint8List changeCutOffPassword(int cb, String newPassword, {int flag = 0x00}) {
    final creds =
        AuthCredentials(cb: cb, pwSum: passwordChecksum(newPassword));
    return auth(creds, flag: flag);
  }
}
