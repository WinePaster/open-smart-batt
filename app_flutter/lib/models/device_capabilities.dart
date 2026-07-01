/// OpenSmartBatt — device capability gating (mockup dashboard controls).
///
/// PURE Dart. Drives which controls the dashboard shows: a capacitor exposes
/// 檢測電容 (detect) + 解除斷電 (release cut-off); anti-theft 防盜 appears only
/// when the model supports it.
///
/// NOTE: Capability detection beyond device-type 0x44 ('D' = power bank) is NOT
/// firmly established by the protocol facts. These flags are a best-effort
/// heuristic with explicit, overridable fields; treat as inference until a live
/// device confirms a capability register.
library;

/// What a connected battery model supports.
class DeviceCapabilities {
  /// Anti-theft (防盜) mode available (mode 1 / status 2).
  final bool hasAntiTheft;

  /// Unit behaves as a super-capacitor (shows 檢測電容 + 解除斷電).
  final bool isCapacitor;

  /// Cut-off (斷電) release available (mode 2/6).
  final bool hasCutOff;

  /// Device-type byte == 0x44 ('D') -> power bank.
  final bool isPowerBank;

  /// DVOL per-cell readout supported (selector 0x24 gated on field_cb).
  final bool supportsDvol;

  const DeviceCapabilities({
    this.hasAntiTheft = false,
    this.isCapacitor = true,
    this.hasCutOff = true,
    this.isPowerBank = false,
    this.supportsDvol = true,
  });

  /// Conservative default for an unidentified RCE unit: capacitor with cut-off
  /// release and DVOL, no anti-theft, not a power bank.
  static const DeviceCapabilities unknown = DeviceCapabilities();

  /// Heuristic from the telemetry device-type byte (selector 0x10).
  factory DeviceCapabilities.fromDeviceType(int? deviceType) {
    final powerBank = deviceType == 0x44;
    return DeviceCapabilities(
      isPowerBank: powerBank,
      isCapacitor: !powerBank,
      hasCutOff: true,
      supportsDvol: true,
      // Anti-theft is model-gated and not derivable from device-type alone;
      // default off until proven.
      hasAntiTheft: false,
    );
  }

  DeviceCapabilities copyWith({
    bool? hasAntiTheft,
    bool? isCapacitor,
    bool? hasCutOff,
    bool? isPowerBank,
    bool? supportsDvol,
  }) =>
      DeviceCapabilities(
        hasAntiTheft: hasAntiTheft ?? this.hasAntiTheft,
        isCapacitor: isCapacitor ?? this.isCapacitor,
        hasCutOff: hasCutOff ?? this.hasCutOff,
        isPowerBank: isPowerBank ?? this.isPowerBank,
        supportsDvol: supportsDvol ?? this.supportsDvol,
      );
}
