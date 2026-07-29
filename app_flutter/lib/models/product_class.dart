/// OpenSmartBatt — product-class model (single source of truth for routing).
///
/// PURE Dart (no Flutter imports). Design 0004 §3.1 (revising 0001 §3.1): the
/// invariant is refined from "label never picks a layout" to **gating (soft:
/// show/hide buttons) ≠ routing (hard: pick a layout)**.
///
/// Design 0007: ALL THREE device-type bytes are now wire-verified, so the class
/// is read off the wire and never inferred:
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
/// (docs/devices.md §智慧電池; observed "device id = 02", §10.2).
const int kSmartBatteryDeviceType = 0x02;

/// Device-type byte (selector 0x10 b4) that identifies a super-capacitor —
/// wire-verified 2026-07-27 on a 旗艦電容 the owner confirmed by hand
/// (`feedback_log/2026.07.27`: 488 `0x10` frames, payload `17`, no other value).
///
/// Design 0004 §3.1 withheld this mapping "until a capacitor 0x10 capture
/// confirms it"; design 0007 lands it because that capture now exists. Other
/// capacitor models are ASSUMED to share the byte (owner's call) — an unverified
/// model reporting something else falls to [unknown], never to a wrong class.
const int kSuperCapacitorDeviceType = 0x17;

/// The product class a connected RCE unit belongs to.
enum ProductClass {
  /// Portable power bank (RSPB) — device-type 0x22 (verified). Routes to its own
  /// view via the deterministic [isPowerBank] signal.
  powerBank,

  /// Super-capacitor pack — device-type 0x17 (verified 2026-07-27, design 0007).
  /// A DETERMINISTIC class: it gates controls (檢測電容 only) straight from the
  /// wire byte. Shares the pack shell with [smartBattery].
  supercapacitor,

  /// Smart battery pack — device-type 0x02 (verified for the car battery). A
  /// DETERMINISTIC class: [fromDeviceType] returns it from the wire byte, so it
  /// gates controls directly and may route without consulting a label.
  smartBattery,

  /// Not yet determined: no device-type frame seen yet, or a byte this build
  /// does not recognise. The user resolves it (design 0007) — nothing is
  /// inferred from telemetry.
  unknown;

  /// True only for [powerBank] — the sole deterministic *routing* signal that
  /// selects the power-bank view. (Design 0004 §3.1: [smartBattery] is also
  /// deterministic from 0x02, but it is a pack and shares the pack shell.)
  bool get isPowerBank => this == ProductClass.powerBank;

  /// Maps a device-type byte (selector 0x10 b4) to a class. Deterministic:
  ///   * 0x22 => [powerBank] (verified);
  ///   * 0x02 => [smartBattery] (verified — docs/devices.md §智慧電池);
  ///   * 0x17 => [supercapacitor] (verified 2026-07-27 — design 0007);
  ///   * every other value => [unknown], which the UI presents as "unclassified"
  ///     and lets the user resolve. All three classes now have a wire-verified
  ///     byte, so nothing is inferred from telemetry any more (design 0007).
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
  /// pre-migration rows (design 0001 §5 Phase 5) read back safely.
  static ProductClass fromStorageKey(String? key) {
    for (final c in ProductClass.values) {
      if (c.name == key) return c;
    }
    return ProductClass.unknown;
  }
}
