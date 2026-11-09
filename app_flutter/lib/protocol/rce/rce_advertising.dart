/// RCE advertising evidence (moved from `ble/ble_models.dart`, design 0099
/// P2). Soft evidence only: it orders the scan list and sets the vendor
/// filter; it never decides what protocol a link speaks (that is the GATT
/// match, design 0099 §3.4).
library;

/// Advertised-name markers that flag a peripheral as vendor hardware.
///
/// Evidence per marker:
///   RCE     — 'RCE_RSPB-01' (power bank, seen in the vendor app's own scan
///             list, 2026-07-29), 'RCE-SCAP_II' / 'RCE-CarBatt' (product table).
///   RSPB    — defensive. A lowercase 'rspb' sighting is recorded in the
///             product notes, but that claim carries no citation and no
///             instance could be reproduced. Listed because it costs nothing
///             and the whole family carries the token; NOT because it is proven.
///   SCAP    — defensive, same family, same reasoning.
///   CARBATT — defensive, same family, same reasoning.
const List<String> kVendorNameMarkers = <String>[
  'RCE',
  'RSPB',
  'SCAP',
  'CARBATT',
];

/// True when [advertisedName] looks like vendor hardware.
///
/// Upper-cases the name, splits on non-alphanumerics, then matches every TOKEN
/// by PREFIX against [kVendorNameMarkers].
///
/// A plain `contains` was rejected: 'RCE' is an embedded syllable of ordinary
/// English words (foRCE, souRCE, pieRCE, commeRCE), and a single scan can hold
/// 30+ unrelated peripherals — substring matching would brand strangers as our
/// hardware. `startsWith` on the whole name was too narrow: it only inspects
/// the first token, so 'RSPB-01' would be missed.
///
/// This is a STRICT SUPERSET of the old whole-name `startsWith('RCE')` rule:
/// any name starting with 'RCE' has a first token starting with 'RCE'.
bool looksLikeVendorName(String advertisedName) {
  if (advertisedName.isEmpty) return false;
  for (final token in advertisedName.toUpperCase().split(
    RegExp(r'[^A-Z0-9]+'),
  )) {
    if (token.isEmpty) continue;
    for (final marker in kVendorNameMarkers) {
      if (token.startsWith(marker)) return true;
    }
  }
  return false;
}
