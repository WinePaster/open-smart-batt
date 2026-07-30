/// OpenSmartBatt — non-identifying stand-in for a BLE device id.
///
/// PURE Dart. Lives in `models/` because BOTH the export filename builder (UI)
/// and the diagnostic-log exporter (data) need it: on Android the device id is
/// the MAC address, so anything that ends up in a file a user shares must use
/// this instead of the id itself.
library;

/// 8-hex-char FNV-1a digest of [deviceId] — stable, non-reversible.
///
/// FNV-1a rather than a crypto hash on purpose: no new dependency, and the goal
/// is only "same unit → same fragment", not collision resistance.
String shortDeviceHash(String deviceId) {
  var hash = 0x811c9dc5;
  for (final unit in deviceId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// Six colon-separated hex pairs — an Android BLE device id (a MAC address).
///
/// Anchored on non-hex/non-colon boundaries so it cannot bite a longer run of
/// hex. Deliberately NOT extended to the `8-4-4-4-12` UUID shape: on iOS the
/// device id has that form, but so does every **GATT service/characteristic
/// UUID**, and the GATT dump is load-bearing diagnostic data (it is what showed
/// `ace3` to be write-only, closing FB-01). A pattern that cannot tell the two
/// apart would shred the dump to redact an install-scoped random identifier
/// that is not a hardware address. Known ids are hashed at the call site
/// instead — see [shortDeviceHash].
final RegExp _macPattern = RegExp(
  r'(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:])',
);

/// Replaces every MAC address in [text] with its [shortDeviceHash].
///
/// The safety net for log notes built from text we do not control — chiefly
/// `'$e'` exception messages, which `flutter_blue_plus` populates with the
/// remote id. Call sites that hold the id already hash it themselves; this
/// catches the ones that cannot.
///
/// Idempotent: a digest is 8 bare hex chars and can never re-match.
String redactMacAddresses(String text) => text.replaceAllMapped(
      _macPattern,
      (m) => shortDeviceHash(m[0]!),
    );
