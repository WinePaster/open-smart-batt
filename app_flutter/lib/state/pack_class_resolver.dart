/// OpenSmartBatt — pack-class label resolver (design 0001 §3.4).
///
/// PURE Dart (no Flutter imports) so it is trivially unit-testable. Watches the
/// telemetry stream over a short settling window after connect and produces a
/// COSMETIC pack label (super-capacitor vs smart battery). This label is TEXT
/// ONLY — routing is decided elsewhere purely by the deterministic power-bank
/// device-type (design 0001 §3.1); the label NEVER selects a layout.
library;

import '../models/product_class.dart';
import '../models/telemetry_sample.dart';

/// Accumulates the telemetry fingerprint needed to label a non-power-bank pack.
///
/// A capacitor streams only PVLT/SVLT/Temp; a smart battery additionally streams
/// current (0x2E) and per-cell DVOL (0x24). We therefore label a pack
/// [ProductClass.smartBattery] as soon as either of those registers arrives, and
/// [ProductClass.supercapacitor] once the settling window elapses without them
/// (PROTOCOL.md §12.1). The user may override the guess at any time.
class PackClassResolver {
  PackClassResolver({this.settlingWindow = const Duration(seconds: 6)});

  /// How long to wait after connect before defaulting a fingerprint-less pack
  /// to super-capacitor. Design 0001 §7 Q4 leaves this tunable.
  final Duration settlingWindow;

  DateTime? _connectedAt;
  bool _batteryFingerprint = false;
  int? _deviceType;
  ProductClass? _override;

  /// Begin a fresh settling window for a new connection.
  void markConnected(DateTime at) {
    _connectedAt = at;
    _batteryFingerprint = false;
    _deviceType = null;
    _override = null;
  }

  /// Drop all state (on disconnect).
  void reset() {
    _connectedAt = null;
    _batteryFingerprint = false;
    _deviceType = null;
    _override = null;
  }

  /// Fold one telemetry snapshot into the fingerprint. Seeing a main-current or
  /// DVOL reading marks the unit as a battery.
  void observe(TelemetrySample sample) {
    final dt = sample.deviceType;
    if (dt != null) _deviceType = dt;
    if (sample.current != null ||
        (sample.dvol != null && sample.dvol!.isNotEmpty) ||
        // A DVOL frame that is only "pending" (arrived before VADJ) is still a
        // battery-only register — fingerprint on it regardless of scaling.
        sample.dvolPending ||
        // Explicit device-type byte 0x02 = car smart battery (§8.5).
        sample.isSmartBattery) {
      _batteryFingerprint = true;
    }
  }

  /// Apply (or clear, with null) an explicit user choice of pack label.
  void setOverride(ProductClass? label) => _override = label;

  /// The current user override, if any.
  ProductClass? get override => _override;

  /// True once a battery-only register (current / DVOL) has been observed.
  bool get batteryFingerprintSeen => _batteryFingerprint;

  /// The DETERMINISTIC routing class from the device-type byte: power bank, or
  /// [ProductClass.unknown] for any pack (design 0001 §3.1).
  ProductClass get deviceClass => ProductClass.fromDeviceType(_deviceType);

  /// Whether the post-connect settling window has elapsed as of [now].
  bool settlingElapsed(DateTime now) {
    final at = _connectedAt;
    if (at == null) return false;
    return now.difference(at) >= settlingWindow;
  }

  /// The cosmetic label to show for this unit as of [now]. A power bank always
  /// reports [ProductClass.powerBank]; a pack reports the inferred / overridden
  /// label (design 0001 §3.4). TEXT ONLY.
  ProductClass label(DateTime now) {
    if (deviceClass.isPowerBank) return ProductClass.powerBank;
    return ProductClass.inferPackLabel(
      batteryFingerprintSeen: _batteryFingerprint,
      settlingElapsed: settlingElapsed(now),
      userOverride: _override,
    );
  }
}
