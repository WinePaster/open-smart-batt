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

  BlePacketEvent(this.direction, this.bytes, {DateTime? at})
      : at = at ?? DateTime.now();
}
