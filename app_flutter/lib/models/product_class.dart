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
/// EVERY device-type byte here is wire-verified, so the class is read off the
/// wire and never inferred:
///   * `0x22` → [powerBank] (PROTOCOL.md §8.2/§9);
///   * `0x02` → [smartBattery] (connect-burst HCI snoop 2026-07-06);
///   * `0x17` → [supercapacitor] (owner-confirmed unit, 2026-07-27);
///   * `0x18` → [supercapacitor] (three independent units, 2026-08-01);
///   * `0x12` → [blackBox] (one unit, 2026-11-22 — design 0108);
///   * `0x14` → [blackBox] (one unit, 2026-11-25 — owner ruling, see
///     [kMiniBlackBoxDeviceType]).
///
/// The list grows one measured byte at a time, and a byte nobody has measured
/// stays out. That has a visible cost — a new hardware generation shows up as
/// "unclassified" until someone captures it, which is exactly what `0x18` did
/// for a day — and it is the right cost: not guessing cannot guess wrong.
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

/// Device-type byte (selector 0x10 b4) for the THIRD-generation super-capacitor
/// (advertised as `RCE-SCAP_III`) — wire-verified 2026-08-01.
///
/// Held to the same bar as [kSuperCapacitorDeviceType], and cleared it on three
/// independent units at once: serials 145 / 373 / 416, three different MAC
/// prefixes, two firmware revisions (1.02 and 1.03), reported by three
/// unrelated people. All three answer 0x2B=402c2814, 0x42=07c8f005 and
/// 0x27=00a802180001 byte for byte, and share NONE of those values with the
/// four 0x17 units in the same corpus — so the difference tracks the
/// generation, not the individual unit, which is what a per-unit quirk would
/// have looked like. Two of the three were also caught advertising
/// `RCE-SCAP_III` with the scan-hit id matching the id actually connected.
///
/// Mapped to the SAME [ProductClass.supercapacitor] rather than a class of its
/// own: the two generations differ in the VALUES of their identity and
/// threshold registers, all of which are read from the wire, and not in what
/// the unit can do. A separate class would add a branch to every switch and
/// have both branches do the same thing.
///
/// Until this landed, a third-generation unit fell through to [unknown] — its
/// owner saw "unclassified" and, via the bounded fallback in
/// `DeviceCapabilities`, was offered 解除斷電, a mode a capacitor does not have.
const int kSuperCapacitorGen3DeviceType = 0x18;

/// Device-type byte (selector 0x10 b4) for the motorcycle BLACK BOX —
/// wire-verified 2026-11-22 on one unit (serial 016802120000017, design 0108).
///
/// One unit is below the bar the capacitor bytes cleared, and it lands anyway
/// because the byte does not stand alone: the serial's product field reads
/// `0212`, `0x27` carries `0212` in the same position a battery carries `0102`,
/// and the engineering app's own type picker lists `[12]機車黑盒子` beside
/// `[02]` and `[22]` — the two bytes we already know as battery and power bank.
///
/// What it is (owner, 2026-11-22): a pure monitor — voltage and current
/// sensing plus lock / cut-off / release, and NO battery or capacitor of its
/// own. On the wire that reads as `0x24` with an empty payload and no `0x37`.
/// Its `0x23` uses the battery's codes (the captured unit was cut off and read
/// `02` throughout).
const int kBlackBoxDeviceType = 0x12;

/// Device-type byte (selector 0x10 b4) of the second black-box model — the
/// unit its owner calls 「機車小黑盒」 (serial product field `0214`; feedback
/// `2026.11.25/001`, one unit, raw packet log off).
///
/// Mapped to [ProductClass.blackBox] by owner ruling (2026-11-25: show it as
/// the black box now; in OSB Pro it gets the controls, elsewhere it is the
/// same as `0x12`). What backs it is thin and stated here so nobody mistakes it
/// for a capture: the owner's name for it, and a history export whose columns
/// have the black box's shape (voltage, current, temperature, mode; no cells,
/// no SOH). No frame of it has been seen.
const int kMiniBlackBoxDeviceType = 0x14;

/// The product class a connected RCE unit belongs to.
enum ProductClass {
  /// Portable power bank (RSPB) — device-type 0x22 (verified). Routes to its own
  /// view via the deterministic [isPowerBank] signal.
  powerBank,

  /// Super-capacitor pack — device-type 0x17 (wire-verified 2026-07-27) or
  /// 0x18, its third generation (wire-verified 2026-08-01 on three units).
  /// A DETERMINISTIC class: it gates controls (檢測電容 only) straight from the
  /// wire byte. Shares the pack shell with [smartBattery].
  supercapacitor,

  /// Smart battery pack — device-type 0x02 (verified for the car battery). A
  /// DETERMINISTIC class: [fromDeviceType] returns it from the wire byte, so it
  /// gates controls directly and may route without consulting a label.
  smartBattery,

  /// Motorcycle black box — device-type 0x12 (one unit, 2026-11-22, design
  /// 0108). A pure monitor: voltage, current and temperature, no cells, no
  /// SOH, no capacitor. Shares the pack shell and the battery's mode codes, so
  /// it gets 復電 (and, where injected, 上鎖 / 斷電) — not the battery's cards.
  blackBox,

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
  ///   * 0x17, 0x18 => [supercapacitor] (wire-verified 2026-07-27 / 2026-08-01);
  ///   * 0x12 => [blackBox] (wire-verified 2026-11-22, design 0108);
  ///   * 0x14 => [blackBox] (owner ruling 2026-11-25, one unit, EVT only —
  ///     see [kMiniBlackBoxDeviceType]);
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
      case kSuperCapacitorGen3DeviceType:
        return ProductClass.supercapacitor;
      case kBlackBoxDeviceType:
      case kMiniBlackBoxDeviceType:
        return ProductClass.blackBox;
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
