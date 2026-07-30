/// OpenSmartBatt — BLE-layer value types.
///
/// Small, Flutter-free-ish models that the State/UI layers consume instead of
/// depending on `flutter_blue_plus` types directly. This keeps the rest of the
/// app decoupled from the BLE plugin surface (only [BleService] touches it).
library;

import 'dart:async' show TimeoutException;

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

/// Guards work that spans an `await` against a newer connect superseding it.
///
/// FB-39 (design 0021). `_setupConnection()` reads `_device` once and then
/// awaits service discovery and CCCD enable — but everything it writes
/// afterwards (`_writeChar`, `_notifyChar`, the link state, the keep-alive
/// timer) is OBJECT-level state, unrelated to the local it captured. A field
/// capture caught the consequence: three `discoverServices` timeouts stretched
/// one unit's connect across a minute, the owner gave up and tapped a different
/// device, and the first unit's `ready` landed five seconds later — so the app
/// came online as a device the user had already moved away from.
///
/// The counter is bumped by every `connect()` and `disconnect()`. Work that
/// started under an older value must abandon itself, and — see [isCurrent] —
/// must abandon itself QUIETLY: a newer connection now owns the shared state,
/// so tearing down would break the connection the user actually wants.
class ConnectEpoch {
  int _v = 0;

  /// The value in force right now. Capture this before the first `await`.
  int get current => _v;

  /// Open a new epoch, invalidating every in-flight caller. Returns the new
  /// value (callers rarely need it; it exists to make tests explicit).
  int begin() => ++_v;

  /// Whether work captured at [epoch] may still touch shared state.
  bool isCurrent(int epoch) => epoch == _v;
}

/// Human-readable reason for a failed GATT setup, for the diagnostic log.
///
/// FB-23 (design 0021). The old code rethrew out of a stream listener, where no
/// caller can catch it, so a routine discovery timeout reached the user as an
/// `Uncaught: FlutterBluePlusException` line — 101 of them in a single field
/// capture. The exception text is kept verbatim at the end, because it is still
/// the most specific thing we have; the prefix exists so a reader who is not
/// holding the source can tell the three cases apart.
String gattSetupFailureReason(Object error) {
  if (error is TimeoutException) {
    return 'service discovery timed out';
  }
  if (error is StateError && error.message.contains('GATT characteristics')) {
    return 'required characteristics missing: ${error.message}';
  }
  return 'setup failed: $error';
}
