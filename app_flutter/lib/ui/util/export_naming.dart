/// OpenSmartBatt — identifiable export filenames (design 0006 §3.3).
///
/// PURE Dart (no Flutter imports) so every rule here is unit-testable.
///
/// The dealer services several units and used to receive files called
/// `opensmartbatt-20260708-190410.log` — indistinguishable from each other. A
/// name now carries the product class plus a human identity:
///
///     opensmartbatt-battery-1206-20260727-113000.log
///     opensmartbatt-history-capacitor-a3f1c2d4-20260727-113000.csv
///
/// **The raw BLE device id NEVER appears in a filename.** On Android it is the
/// MAC address (personal data that would leak the moment the file is shared),
/// so an unnamed unit falls back to a short non-reversible hash instead.
library;

import '../../models/product_class.dart';

/// Stable, locale-independent slug for a product class.
///
/// Deliberately NOT the localized label: filenames travel between phones,
/// mail clients and Windows machines, so they must not change with the UI
/// language nor contain CJK characters.
String productClassSlug(ProductClass? c) => switch (c) {
      ProductClass.powerBank => 'powerbank',
      ProductClass.supercapacitor => 'capacitor',
      ProductClass.smartBattery => 'battery',
      _ => 'unknown',
    };

/// Maximum identity fragment length; long aliases would otherwise blow past
/// filesystem name limits once the class + timestamp are added.
const int kMaxIdentLength = 24;

/// Keeps only characters that survive every filesystem + mail client, collapses
/// the rest to `-`, and trims to [kMaxIdentLength]. Returns '' when nothing
/// usable remains (e.g. a purely CJK alias).
String sanitizeIdent(String raw) {
  final cleaned = raw
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return cleaned.length <= kMaxIdentLength
      ? cleaned
      : cleaned.substring(0, kMaxIdentLength).replaceAll(RegExp(r'-+$'), '');
}

/// 8-hex-char FNV-1a digest of [deviceId] — a stable, non-reversible stand-in
/// used when the unit has neither a serial nor a usable alias.
///
/// FNV-1a is chosen over a crypto hash on purpose: no new dependency, and the
/// goal is only "same unit → same fragment", not collision resistance.
String shortDeviceHash(String deviceId) {
  var hash = 0x811c9dc5;
  for (final unit in deviceId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// The human identity fragment for a unit, in priority order:
/// serial → sanitized alias → short hash of the device id.
///
/// Returns null when nothing at all is known (caller then omits the fragment).
String? deviceIdentFragment({
  String? serial,
  String? alias,
  String? deviceId,
}) {
  final s = serial == null ? '' : sanitizeIdent(serial);
  if (s.isNotEmpty) return s;
  final a = alias == null ? '' : sanitizeIdent(alias);
  if (a.isNotEmpty) return a;
  if (deviceId != null && deviceId.isNotEmpty) return shortDeviceHash(deviceId);
  return null;
}

/// Assemble an export filename.
///
/// [base] is `opensmartbatt` or `opensmartbatt-history`; [stamp] comes from
/// `exportStamp()`. When [classSlug]/[ident] are null (an all-devices export)
/// the name collapses to the pre-0006 format, so existing recipients and any
/// tooling built on it keep working.
String exportFileName({
  required String base,
  required String stamp,
  required String extension,
  String? classSlug,
  String? ident,
}) {
  final parts = <String>[
    base,
    if (classSlug != null && classSlug.isNotEmpty) classSlug,
    if (ident != null && ident.isNotEmpty) ident,
    stamp,
  ];
  return '${parts.join('-')}.$extension';
}
