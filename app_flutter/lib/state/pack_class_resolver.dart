/// OpenSmartBatt — product-class resolver (design 0007).
///
/// PURE Dart (no Flutter imports) so it is trivially unit-testable.
///
/// It used to GUESS: watch telemetry over a settling window and label a
/// non-power-bank pack capacitor-vs-battery by fingerprint ("a current 0x2E or
/// DVOL 0x24 frame means battery"). The 2026-07-27 capture falsified that — an
/// owner-confirmed super-capacitor streams 0x2E every second, with a constant
/// payload decoding to 0.0 A, so it was branded a battery and handed the
/// battery controls. The fingerprint's premise came from earlier capacitor logs
/// recorded while the write-mode bug suppressed the metadata burst entirely.
///
/// Since all three device-type bytes are now wire-verified (0x22 / 0x02 / 0x17),
/// the guessing is gone. This class only:
///   * remembers the last device-type byte seen, and
///   * holds a user's explicit choice for units whose byte we do not recognise.
library;

import '../models/product_class.dart';
import '../models/telemetry_sample.dart';

/// Resolves the product class of the connected unit.
class PackClassResolver {
  PackClassResolver();

  int? _deviceType;
  ProductClass? _override;

  /// Begin a new connection. Kept as an explicit call site so the resolver's
  /// lifecycle still mirrors the link's.
  void markConnected(DateTime at) {
    _deviceType = null;
    _override = null;
  }

  /// Drop all state (on disconnect).
  void reset() {
    _deviceType = null;
    _override = null;
  }

  /// Record the device-type byte from a telemetry snapshot, when present.
  void observe(TelemetrySample sample) {
    final dt = sample.deviceType;
    if (dt != null) _deviceType = dt;
  }

  /// Apply (or clear, with null) an explicit user choice. Only consulted for a
  /// unit whose device-type byte is unrecognised — a verified byte always wins,
  /// so a stale or mistaken choice can never re-hide a known class.
  ///
  /// A user choice is a GUESS and must never pick a layout. Routing therefore
  /// does not read this at all; see [ConnectionController.resolvedClass], which
  /// falls back to the saved-record seed instead (FB-43).
  void setOverride(ProductClass? label) => _override = label;

  /// The current user override, if any.
  ProductClass? get override => _override;

  /// The DETERMINISTIC class from the device-type byte, or
  /// [ProductClass.unknown] when the byte is absent/unrecognised.
  ProductClass get deviceClass => ProductClass.fromDeviceType(_deviceType);

  /// True only for a confirmed power bank — the routing signal.
  bool get isPowerBank => deviceClass.isPowerBank;

  /// The class to show and gate on: the wire byte when we recognise it, else
  /// the user's choice, else [ProductClass.unknown] ("unclassified").
  ProductClass get label {
    final fromWire = deviceClass;
    if (fromWire != ProductClass.unknown) return fromWire;
    return _override ?? ProductClass.unknown;
  }
}
