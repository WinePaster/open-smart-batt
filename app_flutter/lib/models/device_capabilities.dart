/// OpenSmartBatt — device capability gating, DERIVED from [ProductClass].
///
/// PURE Dart. Controls are gated PER CLASS. The table below IS the rule — a
/// capacitor and a battery are different hardware with different features, and
/// an earlier version gated on a single `!isPowerBank` flag, which handed both
/// of them the same control set. That is how a super-capacitor ended up being
/// offered 解除斷電, a mode it has no concept of.
///
/// | ProductClass     | 檢測電容 | 解除斷電 | 防盜        |
/// |------------------|:------:|:------:|:-----------|
/// | [powerBank]      |   —    |   —    |     —      |
/// | [supercapacitor] |   ✅   |   ❌   |     ❌     |
/// | [smartBattery]   |   ❌   |   ✅   | model-gated |
/// | [unknown]        | bounded fallback: union EXCEPT anti-theft             |
///
/// The [unknown] row is a lenient-but-bounded fallback for a pack that has not
/// been classified yet: it shows the UNION of pack controls except anti-theft,
/// converging the moment a class resolves. Erring lenient is safe HERE and only
/// here, because every control in that union is read-only or auth-gated
/// (status_controls.dart) — the fallback cannot fire a destructive command. It
/// is chosen over "hide everything until classified" so that a battery whose
/// owner urgently needs 解除斷電 is not left with no button at all. Anti-theft
/// is excluded because it is the one entry that can immobilise a vehicle.
///
/// Note the asymmetry with LAYOUT: gating (soft — which buttons appear) may be
/// lenient, but routing (hard — which layout is drawn) must not. See
/// `RoutingDecision`: a unit that has not said what it is gets no layout at
/// all, but a unit that IS a pack of undetermined kind gets this bounded
/// control set.
///
/// DVOL stays DATA-DRIVEN (`dvol != null`), NOT gated here: the DVOL card
/// already renders only when values arrive, so a `supportsDvol` getter would
/// have been a second, untested gate in front of a gate. It was removed.
library;

import 'product_class.dart';

/// What a connected battery model supports, derived from its [ProductClass].
class DeviceCapabilities {
  /// The unit's product class — the single source of truth for gating.
  final ProductClass productClass;

  /// Optional per-model override for anti-theft (防盜). Anti-theft is fitted on
  /// some battery models and not others, and nothing on the wire distinguishes
  /// them — so it cannot be derived from the class alone the way every other
  /// capability here is. null means "use the class default", which is off.
  final bool? antiTheftOverride;

  const DeviceCapabilities({
    this.productClass = ProductClass.unknown,
    this.antiTheftOverride,
  });

  /// Bounded fallback for an unidentified pack: the UNION of pack controls
  /// EXCEPT anti-theft — i.e. both 檢測電容 ([isCapacitor]) and 解除斷電
  /// ([hasCutOff]) are shown, but 防盜 ([hasAntiTheft]) is not. Not a power
  /// bank. Converges to a single class as soon as the class resolves.
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
  /// the bounded [unknown] fallback. A smart battery must NOT get this: it has
  /// no capacitor to self-check.
  bool get isCapacitor =>
      productClass == ProductClass.supercapacitor ||
      productClass == ProductClass.unknown;

  /// 解除斷電 (cut-off release) available — a [smartBattery] only, PLUS the
  /// bounded [unknown] fallback. A super-capacitor must NOT get this: it has no
  /// run mode to be cut off from, so the control would be inert at best and, if
  /// the write were honoured, would be operating a mode the hardware does not
  /// define.
  bool get hasCutOff =>
      productClass == ProductClass.smartBattery ||
      productClass == ProductClass.unknown;

  /// 防盜 (anti-theft) available — [smartBattery] AND a per-model override.
  /// NEVER in the [unknown] fallback: anti-theft trips the battery's output, so
  /// offering it to a unit we cannot even identify has no justification.
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
