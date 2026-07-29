/// OpenSmartBatt — BLE-layer value types.
///
/// Small, Flutter-free-ish models that the State/UI layers consume instead of
/// depending on `flutter_blue_plus` types directly. This keeps the rest of the
/// app decoupled from the BLE plugin surface (only [BleService] touches it).
library;

import '../models/log_entry.dart' show LogDirection;

/// Lifecycle of the single BLE link [BleService] manages.
///
///   * [disconnected] — no device / link torn down.
///   * [connecting]   — `connect()` issued, awaiting the connected callback.
///   * [connected]    — link up; discovering services / enabling notify.
///   * [ready]        — notify enabled + keep-alive running; telemetry flowing.
///   * [disconnecting]— teardown in progress.
enum BleLinkState { disconnected, connecting, connected, ready, disconnecting }

/// A device found while scanning on the vendor service UUID (mockup screen 3).
class DiscoveredDevice {
  /// Platform remote id (Android: MAC; iOS: an install-scoped NSUUID). On
  /// Android this is globally stable; on iOS it is volatile (changes on
  /// reinstall / differs per phone), so [SavedDevice] rebinds it against the
  /// stable advertised [name] on each fresh discovery (D.3). Used by
  /// [BleService.connect].
  final String id;

  /// Advertised local name (may be empty — the protocol does not filter by
  /// name). On iOS this is the STABLE secondary key used to rebind a volatile
  /// NSUUID (D.3).
  final String name;

  /// Signal strength (dBm); larger (closer to 0) is stronger.
  final int rssi;

  /// True if the advertisement includes the vendor service UUID (07b9fff0) —
  /// i.e. very likely an RCE device. (Some units may not advertise it, so a
  /// false value does NOT rule out an RCE device.)
  final bool isVendor;

  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.rssi,
    this.isVendor = false,
  });

  @override
  bool operator ==(Object other) =>
      other is DiscoveredDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A raw wire event surfaced for the diagnostics packet log (Settings →
/// diagnostics, DEFAULT OFF). Direction + the exact bytes on the wire.
class BlePacketEvent {
  /// tx = app→battery write, rx = battery→app notification chunk.
  final LogDirection direction;

  /// Raw bytes (a TX command/keep-alive, or one RX notification chunk before
  /// reassembly).
  final List<int> bytes;

  /// App clock at the moment the event crossed the BLE layer.
  final DateTime at;

  /// Optional diagnostic note (e.g. source-characteristic UUID for a multi-notify
  /// RX chunk, or a GATT-table dump line for an [LogDirection.event]).
  final String? note;

  BlePacketEvent(this.direction, this.bytes, {DateTime? at, this.note})
      : at = at ?? DateTime.now();
}

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
  for (final token
      in advertisedName.toUpperCase().split(RegExp(r'[^A-Z0-9]+'))) {
    if (token.isEmpty) continue;
    for (final marker in kVendorNameMarkers) {
      if (token.startsWith(marker)) return true;
    }
  }
  return false;
}
