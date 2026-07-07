/// OpenSmartBatt — device capability gating, DERIVED from [ProductClass].
///
/// PURE Dart. Design 0004 §3.2 gates controls PER CLASS (replacing the old
/// `!isPowerBank` blanket that handed a capacitor and a battery the same control
/// set — the bug in docs/devices.md's capability matrix):
///
/// | ProductClass     | 檢測電容 | 解除斷電 | 防盜        |
/// |------------------|:------:|:------:|:-----------|
/// | [powerBank]      |   —    |   —    |     —      |
/// | [supercapacitor] |   ✅   |   ❌   |     ❌     |
/// | [smartBattery]   |   ❌   |   ✅   | model-gated |
/// | [unknown]        | bounded fallback: union EXCEPT anti-theft (§3.3)       |
///
/// The [unknown] row is a lenient-but-bounded fallback for a pack that has not
/// been classified yet: it shows the UNION of pack controls except anti-theft,
/// converging the moment a label resolves. Mis-gating here is safe — every
/// gated control is read-only or auth-gated (status_controls.dart), so the
/// fallback never fires a destructive command; it just avoids hiding 解除斷電
/// from a battery that urgently needs it (design 0004 §3.3).
///
/// DVOL stays DATA-DRIVEN (`dvol != null`), NOT gated here — the old
/// `supportsDvol` getter had no consumer and was removed (design 0004 §3.5/Q1).
library;

import 'product_class.dart';

/// What a connected battery model supports, derived from its [ProductClass].
class DeviceCapabilities {
  /// The unit's product class — the single source of truth for gating.
  final ProductClass productClass;

  /// Optional per-model override for anti-theft (防盜). Anti-theft is model-
  /// gated and not derivable from the class alone (design 0001 §3.1); null means
  /// "use the class default" (off).
  final bool? antiTheftOverride;

  const DeviceCapabilities({
    this.productClass = ProductClass.unknown,
    this.antiTheftOverride,
  });

  /// Bounded fallback for an unidentified pack (design 0004 §3.3): the UNION of
  /// pack controls EXCEPT anti-theft — i.e. both 檢測電容 ([isCapacitor]) and
  /// 解除斷電 ([hasCutOff]) are shown, but 防盜 ([hasAntiTheft]) is not. Not a
  /// power bank. Converges to a single class as soon as the label resolves.
  static const DeviceCapabilities unknown = DeviceCapabilities();

  /// Capabilities for an explicit [ProductClass].
  factory DeviceCapabilities.fromClass(ProductClass productClass) =>
      DeviceCapabilities(productClass: productClass);

  /// Capabilities inferred from the telemetry device-type byte (selector 0x10).
  factory DeviceCapabilities.fromDeviceType(int? deviceType) =>
      DeviceCapabilities(productClass: ProductClass.fromDeviceType(deviceType));

  /// Device-type byte marks a power bank (0x22). Routes to the power-bank view.
  bool get isPowerBank => productClass.isPowerBank;

  /// 檢測電容 (capacitor self-check) available — a [supercapacitor] only, PLUS
  /// the bounded [unknown] fallback (design 0004 §3.2/§3.3).
  bool get isCapacitor =>
      productClass == ProductClass.supercapacitor ||
      productClass == ProductClass.unknown;

  /// 解除斷電 (cut-off release) available — a [smartBattery] only, PLUS the
  /// bounded [unknown] fallback (design 0004 §3.2/§3.3).
  bool get hasCutOff =>
      productClass == ProductClass.smartBattery ||
      productClass == ProductClass.unknown;

  /// 防盜 (anti-theft) available — [smartBattery] AND a per-model override
  /// (model-gated, design 0004 §3.2). NEVER in the [unknown] fallback.
  bool get hasAntiTheft =>
      productClass == ProductClass.smartBattery && (antiTheftOverride ?? false);

  DeviceCapabilities copyWith({
    ProductClass? productClass,
    bool? antiTheftOverride,
  }) =>
      DeviceCapabilities(
        productClass: productClass ?? this.productClass,
        antiTheftOverride: antiTheftOverride ?? this.antiTheftOverride,
      );

  @override
  bool operator ==(Object other) =>
      other is DeviceCapabilities &&
      other.productClass == productClass &&
      other.antiTheftOverride == antiTheftOverride;

  @override
  int get hashCode => Object.hash(productClass, antiTheftOverride);
}
