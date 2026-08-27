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
/// | [unknown]        |   ❌   |   ✅   |     ❌     |
///
/// The [unknown] row is a lenient-but-bounded fallback for a pack that has not
/// been classified yet: 解除斷電 only, converging the moment a class resolves.
/// Erring lenient is safe HERE and only here, because every control in that
/// fallback is read-only or auth-gated (status_controls.dart) — the fallback
/// cannot fire a destructive command. It is chosen over "hide everything until
/// classified" so that a battery whose owner urgently needs 解除斷電 is not
/// left with no button at all. Anti-theft is excluded because it is the one
/// entry that can immobilise a vehicle.
///
/// 🔵 **檢測電容 left that fallback on 2026-08-28, and the sentence above is
/// the reason** (design 0082 Q8). It used to be in the union on the strength of
/// "every control in the union is read-only" — which was true while the button
/// sent nothing at all. Making it a real self-check made it a state-changing
/// write, and the safety argument would have become false the same day. Note
/// which way that was resolved: the control left the fallback so the argument
/// stays TRUE, rather than the argument being softened so the control could
/// stay.
///
/// ⚠️ Who actually lost a button: nobody who could use it. A unit whose
/// device-type byte is unrecognised, and one whose byte has not arrived yet,
/// are drawn by `UnidentifiedView` / `ClassPendingView` and get no controls at
/// all. The route that reaches this fallback WITH controls is a pack shell
/// whose cosmetic label is a power bank — the one class that has no capacitor
/// to check.
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

  /// Bounded fallback for an unidentified pack: 解除斷電 ([hasCutOff]) only.
  /// Neither 檢測電容 ([isCapacitor], since 2026-08-28 — see the library doc)
  /// nor 防盜 ([hasAntiTheft]) is shown. Not a power bank. Converges to a
  /// single class as soon as the class resolves.
  static const DeviceCapabilities unknown = DeviceCapabilities();

  /// Capabilities for an explicit [ProductClass].
  factory DeviceCapabilities.fromClass(ProductClass productClass) =>
      DeviceCapabilities(productClass: productClass);

  /// Capabilities inferred from the telemetry device-type byte (selector 0x10).
  factory DeviceCapabilities.fromDeviceType(int? deviceType) =>
      DeviceCapabilities(productClass: ProductClass.fromDeviceType(deviceType));

  /// Device-type byte marks a power bank (0x22). Routes to the power-bank view.
  bool get isPowerBank => productClass.isPowerBank;

  /// 檢測電容 (capacitor self-check) available — a [supercapacitor] and NOTHING
  /// else. A smart battery must not get this (no capacitor to self-check), and
  /// as of 2026-08-28 neither does the [unknown] fallback: the control writes
  /// `0x23` <- `0x06` now, and a write that changes device state has no place
  /// being aimed at hardware we could not identify. See the library doc.
  ///
  /// ⚠️ The `hasCutOff` fallback below is NOT the same question and must not be
  /// "tidied up" to match. Release sends `0x00` to a class that has the mode,
  /// and it is the escape hatch this file's asymmetry exists to protect.
  bool get isCapacitor => productClass == ProductClass.supercapacitor;

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
