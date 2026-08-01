/// OpenSmartBatt — product-class model (single source of truth for routing).
///
/// PURE Dart (no Flutter imports).
///
/// The standing invariant is **gating (soft: show/hide buttons) ≠ routing
/// (hard: pick a layout)**. It started life as the blunter "a label never picks
/// a layout" and was refined once the two were seen to fail differently: every
/// gated control is read-only or auth-gated, so gating on weaker evidence is
/// bounded, whereas routing on weaker evidence renders one product's numbers in
/// another product's units.
///
/// ALL THREE device-type bytes are wire-verified, so the class is read off the
/// wire and never inferred:
///   * `0x22` → [powerBank] (PROTOCOL.md §8.2/§9);
///   * `0x02` → [smartBattery] (connect-burst HCI snoop 2026-07-06);
///   * `0x17` → [supercapacitor] (owner-confirmed unit, 2026-07-27).
///
/// The telemetry fingerprint that used to guess capacitor-vs-battery is GONE.
/// It keyed on "a current 0x2E frame means battery", which the 2026-07-27
/// capture falsified: that capacitor streams 0x2E every second with a constant
/// payload decoding to 0.0 A. The old premise came from capacitor logs recorded
/// while the write-mode bug suppressed the metadata burst entirely.
///
/// An unrecognised byte yields [unknown]; the UI says "unclassified" and lets
/// the user pick. Not guessing cannot guess wrong.
library;

/// Device-type byte (selector 0x10 b4) that identifies a power bank —
/// PROTOCOL.md §8.2/§9. On the wire the byte is 0x22 (34); note an earlier
/// recon mislabeled it `0x44`, which is the Dart Smi-tag (34 << 1).
const int kPowerBankDeviceType = 0x22;

/// Device-type byte (selector 0x10 b4) that identifies a smart battery —
/// verified for the car battery (`RCE-CarBatt`) via the connect-burst HCI snoop
/// (observed as "device id = 02", PROTOCOL.md §10.2).
const int kSmartBatteryDeviceType = 0x02;

/// Device-type byte (selector 0x10 b4) that identifies a super-capacitor —
/// wire-verified 2026-07-27 on a 旗艦電容 the owner confirmed by hand
/// (a 2026-07-27 field capture: 488 `0x10` frames, payload `17`, no other value).
///
/// This mapping was deliberately withheld — 0x17 was left falling through to
/// [unknown] — under a written condition: "not until a capacitor 0x10 capture
/// confirms it". It lands here because that capture now exists, which is the
/// condition being met rather than waived. Other
/// capacitor models are ASSUMED to share the byte (owner's call) — an unverified
/// model reporting something else falls to [unknown], never to a wrong class.
const int kSuperCapacitorDeviceType = 0x17;

/// The product class a connected RCE unit belongs to.
enum ProductClass {
  /// Portable power bank (RSPB) — device-type 0x22 (verified). Routes to its own
  /// view via the deterministic [isPowerBank] signal.
  powerBank,

  /// Super-capacitor pack — device-type 0x17 (wire-verified 2026-07-27).
  /// A DETERMINISTIC class: it gates controls (檢測電容 only) straight from the
  /// wire byte. Shares the pack shell with [smartBattery].
  supercapacitor,

  /// Smart battery pack — device-type 0x02 (verified for the car battery). A
  /// DETERMINISTIC class: [fromDeviceType] returns it from the wire byte, so it
  /// gates controls directly and may route without consulting a label.
  smartBattery,

  /// Not yet determined: no device-type frame seen yet, or a byte this build
  /// does not recognise. The user resolves it — nothing is inferred from
  /// telemetry, because not guessing cannot guess wrong.
  unknown;

  /// True only for [powerBank] — the sole deterministic *routing* signal that
  /// selects the power-bank view. ([smartBattery] is just as deterministic,
  /// from 0x02, but it is a pack and shares the pack shell, so it needs no
  /// routing signal of its own.)
  bool get isPowerBank => this == ProductClass.powerBank;

  /// Maps a device-type byte (selector 0x10 b4) to a class. Deterministic:
  ///   * 0x22 => [powerBank] (verified);
  ///   * 0x02 => [smartBattery] (verified on a car battery — see
  ///     [kSmartBatteryDeviceType]);
  ///   * 0x17 => [supercapacitor] (wire-verified 2026-07-27);
  ///   * every other value => [unknown], which the UI presents as "unclassified"
  ///     and lets the user resolve. All three classes now have a wire-verified
  ///     byte, so nothing is inferred from telemetry any more.
  static ProductClass fromDeviceType(int? deviceType) {
    switch (deviceType) {
      case kPowerBankDeviceType:
        return ProductClass.powerBank;
      case kSmartBatteryDeviceType:
        return ProductClass.smartBattery;
      case kSuperCapacitorDeviceType:
        return ProductClass.supercapacitor;
      default:
        return ProductClass.unknown;
    }
  }

  /// Stable key for persistence (SavedDevice / SQLite). Uses the enum [name]
  /// so it survives across app versions independent of declaration order.
  String get storageKey => name;

  /// Inverse of [storageKey]; unknown/absent keys default to [unknown] so
  /// rows written before `saved_devices` gained a `product_class` column read
  /// back safely.
  static ProductClass fromStorageKey(String? key) {
    for (final c in ProductClass.values) {
      if (c.name == key) return c;
    }
    return ProductClass.unknown;
  }
}
