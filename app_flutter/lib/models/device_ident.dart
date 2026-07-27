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
