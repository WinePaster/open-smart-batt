/// OpenSmartBatt — product-class model (single source of truth for routing).
///
/// PURE Dart (no Flutter imports). Design 0004 §3.1 (revising 0001 §3.1): the
/// invariant is refined from "label never picks a layout" to **gating (soft:
/// show/hide buttons) ≠ routing (hard: pick a layout)**.
///
/// Two device-type bytes are wire-verified and therefore DETERMINISTIC:
///   * `0x22` → [powerBank] (verified, PROTOCOL.md §8.2/§12.1);
///   * `0x02` → [smartBattery] (verified via the connect burst HCI snoop
///     2026-07-06, docs/devices.md §智慧電池).
/// The super-capacitor device-type `0x17` is NOT yet wire-verified, so it stays
/// [unknown] (it must NOT be mapped to
/// [supercapacitor] until a capacitor `0x10` capture confirms it). Until then a
/// [supercapacitor] classification is an inferred/user-set COSMETIC label that
/// may gate controls (design 0004 §3.1/§3.2) but must NEVER pick a layout.
library;

/// Device-type byte (selector 0x10 b4) that identifies a power bank —
/// PROTOCOL.md §8.2/§12.1. On the wire the byte is 0x22 (34); note an earlier
/// recon mislabeled it `0x44`, which is the Dart Smi-tag (34 << 1).
const int kPowerBankDeviceType = 0x22;

/// Device-type byte (selector 0x10 b4) that identifies a smart battery —
/// verified for the car battery (`RCE-CarBatt`) via the connect-burst HCI snoop
/// (docs/devices.md §智慧電池; observed "device id = 02", §8.5).
const int kSmartBatteryDeviceType = 0x02;

/// The product class a connected RCE unit belongs to.
enum ProductClass {
  /// Portable power bank (RSPB) — device-type 0x22 (verified). Routes to its own
  /// view via the deterministic [isPowerBank] signal.
  powerBank,

  /// Super-capacitor pack. The device-type `0x17` is NOT yet wire-verified, so
  /// this remains an inferred/user-set COSMETIC label — it may gate controls
  /// (design 0004 §3.2) but must NEVER pick a layout (routing).
  supercapacitor,

  /// Smart battery pack — device-type 0x02 (verified for the car battery). A
  /// DETERMINISTIC class: [fromDeviceType] returns it from the wire byte, so it
  /// gates controls directly and may route without consulting a label.
  smartBattery,

  /// Not yet determined (no device-type frame seen, or a non-power-bank unit
  /// whose pack label has not been inferred).
  unknown;

  /// True only for [powerBank] — the sole deterministic *routing* signal that
  /// selects the power-bank view. (Design 0004 §3.1: [smartBattery] is also
  /// deterministic from 0x02, but it is a pack and shares the pack shell.)
  bool get isPowerBank => this == ProductClass.powerBank;

  /// Maps a device-type byte (selector 0x10 b4) to a class. Deterministic:
  ///   * 0x22 => [powerBank] (verified);
  ///   * 0x02 => [smartBattery] (verified — docs/devices.md §智慧電池);
  ///   * every other value (including the UNVERIFIED super-capacitor 0x17) =>
  ///     [unknown]. We do NOT map 0x17 to [supercapacitor] here until it is
  ///     wire-verified (design 0004 §3.1); the cosmetic label handles that case.
  static ProductClass fromDeviceType(int? deviceType) {
    switch (deviceType) {
      case kPowerBankDeviceType:
        return ProductClass.powerBank;
      case kSmartBatteryDeviceType:
        return ProductClass.smartBattery;
      default:
        return ProductClass.unknown;
    }
  }

  /// Infers the COSMETIC pack label (super-capacitor vs smart battery) from a
  /// telemetry fingerprint — design 0001 §3.4. This is TEXT ONLY: it must NEVER
  /// select a layout (the protocol cannot deterministically tell a capacitor
  /// from a battery; only [isPowerBank] routes).
  ///
  /// Rules, in priority order:
  ///   1. a [userOverride] always wins;
  ///   2. once a battery-only register has been seen ([batteryFingerprintSeen]
  ///      — a current 0x2E or DVOL 0x24 frame) the unit is labelled
  ///      [smartBattery];
  ///   3. otherwise, once the post-connect settling window has elapsed
  ///      ([settlingElapsed]) with no such register, it is labelled
  ///      [supercapacitor];
  ///   4. before the window elapses (and with no fingerprint yet) the label is
  ///      still [unknown] — the UI shows an "identifying…" chip rather than
  ///      guessing.
  static ProductClass inferPackLabel({
    required bool batteryFingerprintSeen,
    required bool settlingElapsed,
    ProductClass? userOverride,
  }) {
    if (userOverride != null) return userOverride;
    if (batteryFingerprintSeen) return ProductClass.smartBattery;
    if (settlingElapsed) return ProductClass.supercapacitor;
    return ProductClass.unknown;
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
