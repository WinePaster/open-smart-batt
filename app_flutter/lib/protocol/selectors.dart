/// OpenSmartBatt — inbound notification selectors (PROTOCOL.md §5.2 / §8).
///
/// An inbound frame is `[0xB8, selector, 0x01, LEN, payload(LEN), XOR]`. The
/// dispatch key is `byteList[1]` (the selector). These constants name the ones
/// we decode; unknown selectors are tolerated and ignored.
library;

/// Inbound selector codes (the 2nd byte of a notification frame).
class Selectors {
  Selectors._();

  /// Device type (裝置識別). b4. Observed values: 0x02 = car smart
  /// battery, 0x22 (34) = power bank, 0x17 (23) = super-cap. (0x44 was the Dart
  /// Smi-tag of 34, not the wire byte.)
  static const int deviceType = 0x10;

  /// Main / primary battery voltage PVLT (V).
  static const int pvlt = 0x19;

  /// TWF warning / status bitfield. b4 (bit semantics unverified).
  ///
  /// Decoded and recorded, never interpreted. An earlier build read value
  /// `0x20` as a device fault; field captures showed it appears ONLY on power
  /// banks and only while charging, never once across 13,535 pack samples.
  ///
  /// ⚠️ It is NOT a usable charge/discharge signal either: trickle charging
  /// reports `0x00`, so the byte is incomplete. Direction comes from the
  /// 0x49 / 0x4A current fields, which are mutually exclusive across the whole
  /// capture corpus.
  static const int twf = 0x20;

  /// Temperature (°C), signed int8 of b4.
  static const int temperature = 0x21;

  /// Mode register echo. b4 -> reported mode/status code.
  static const int mode = 0x23;

  /// DVOL per-series cell voltages (4 cells). **Not gated** on any field_cb
  /// label — it streams unconditionally (PROTOCOL.md §5.2). The earlier claim of
  /// a `0168…`-prefixed gate was wrong; a client that implements it never shows
  /// per-cell voltages at all.
  static const int dvol = 0x24;

  /// Year (年份) — §10.2. NOT the serial high-word (earlier
  /// recon mislabelled it). Byte layout pending capture; not decoded yet.
  static const int year = 0x25;

  /// Battery serial number (電池序號) — e.g. 0001.
  static const int serialB = 0x26;

  /// Dealer code (經銷商代號); builds field_cb and seeds the auth `cb` value.
  static const int dealerCode = 0x27;

  /// Password / auth response label.
  static const int password = 0x2A;

  /// Warning-parameter readback (OV / UV / OT).
  static const int thresholds = 0x2B;

  /// Main current (A).
  static const int current = 0x2E;

  /// Secondary current (mA); logged only, not stored.
  static const int secondaryCurrent = 0x2F;

  /// VADJ = 分串電壓精度 (per-cell voltage precision, mV/LSB); multiplier for
  /// DVOL. Observed ~20.36 (§10.2). Not seen on the passive
  /// poll — see PROTOCOL.md §10.
  static const int vadj = 0x30;

  /// Secondary voltage SVLT (V).
  static const int svlt = 0x37;

  /// The device's own BLE address, sent as **ASCII text** (LEN 17, e.g.
  /// `"AA:BB:CC:DD:EE:FF"` — PROTOCOL.md §8.2.3). Declassified 2026-07-30: it has
  /// its own wire evidence and is documented openly, so it is decoded here, not
  /// behind the closed [MetadataParser] seam. On iOS — where the platform device
  /// id is an install-scoped NSUUID and CoreBluetooth never reveals the MAC —
  /// this register is the only stable cross-platform device identity (design
  /// 0027 §3.2). NOT gated on `rawPacketLog`: the decode path runs on every
  /// notification, the raw-log switch only gates whether the bytes are also
  /// written to the diagnostic log.
  static const int bleAddress = 0x38;

  /// Charge info (v1 / v2).
  static const int charge = 0x41;

  /// Per-cell voltages in mV, 8 bytes = 4 x u16 big-endian.
  ///
  /// The same quantity as [dvol] (0x24), but already scaled BY THE DEVICE, so
  /// it needs no [vadj]. Cross-checked against 0x24 x VADJ on a live unit: five
  /// samples, all exactly `trunc(raw x VADJ)` — e.g. raw `0xB9`=185 x 20.30 =
  /// 3755.5 -> 3755. That both confirms our 0x24 scaling end to end AND makes
  /// this the authoritative source when it is present.
  ///
  /// Low rate: it rides the connect burst only (2 frames per session in the
  /// capture) while 0x24 streams every second — so it does not replace 0x24.
  static const int cellVoltagesMv = 0x47;

  /// Discharge info (v1 / v2) on a pack.
  ///
  /// On a POWER BANK the same 4-byte payload reads as `[u16 mV][u16 mA]`, and
  /// the second field is the ampere figure the unit itself reports: a live
  /// capture held 1042–1128 mA at the same moment the unit's own display showed
  /// 1.05 A. The first field tracks [pvlt] to within ±10 mV over 48 frames, so
  /// it is the same cell voltage and is not decoded again.
  ///
  /// Whether that current is measured cell-side or at the output port is NOT
  /// established.
  ///
  /// The sibling register [chargeCurrent] (0x49) carries the same shape for the
  /// charging direction. It used to be read as "always zero" and left
  /// undecoded; that held only because every capture examined was an output
  /// one. With the charging captures added the pair is complementary, so the
  /// app now publishes a SIGNED current: positive from this register,
  /// negative from 0x49. See [chargeCurrent] for the counts.
  static const int discharge = 0x4A;

  /// Charge-side current pair on a power bank: `[u16 mV][u16 mA]`, the mirror
  /// of [discharge].
  ///
  /// Left undecoded until 2026-08-03 on the strength of "its mA field read zero
  /// across 97 frames" — an observation drawn entirely from captures whose
  /// reporter had labelled them OUTPUT. Adding the charging captures completes
  /// it, and the two registers turn out to be cleanly complementary:
  ///
  /// | reporter said | 0x49 mA zero | 0x4A mA zero |
  /// |---|---|---|
  /// | discharging (9 captures) | 95–100 % | 0–4 % |
  /// | charging (2 captures) | 0–3 % | 96–99 % |
  ///
  /// The complementarity shows up WITHIN a single capture, which is why it does
  /// not rest on comparing units: whichever register is carrying the reading is
  /// the direction. `0x4B`'s port bits agree independently (bit 3 set only in
  /// the charging captures) but are not needed for this.
  ///
  /// ⚠️ Three physical units cover the discharging side; the charging side is
  /// so far ONE unit. Enough to sign a live reading — a unit's own two
  /// registers are complementary on their own — and not enough to write the
  /// attribution into the protocol document as settled.
  static const int chargeCurrent = 0x49;

  /// Power-bank capacity frame, 5 bytes:
  /// `[u16 design capacity mAh][u8 SOC %][u8 ?][u8 ?]`.
  ///
  /// The power-bank equivalent of [capacity] (0x96), which power banks do not
  /// send. SOC is byte b6, read directly as a percentage — a capture read 94 at
  /// the same moment the unit's own display showed 94 %, and the value fell
  /// monotonically 94 → 63 over five hours. Design capacity read 10000 on a
  /// unit rated 10000 mAh.
  ///
  /// The trailing two bytes are NOT decoded: one is a strong second-temperature
  /// candidate (it rises monotonically with output power across 100 samples)
  /// but a single sample jumped 29 → 65 → 28 within five seconds, which no
  /// temperature does. Naming it on that evidence would be a guess.
  static const int powerBankCapacity = 0x4B;

  /// Capacity / SOH bucket.
  static const int capacity = 0x96;
}

/// Outbound command codes (PROTOCOL.md §5.1).
class Commands {
  Commands._();

  /// Mode set. LEN 1, payload [mode].
  static const int modeSet = 0x23;

  /// Password / auth. LEN 4, payload [cbHi, cbLo, pwHi, pwLo].
  static const int auth = 0x2A;

  /// Warning thresholds. LEN 4, payload [OV, UV, OT, trailing].
  static const int thresholds = 0x2B;
}

/// Mode argument passed to `switchMode(mode)` (PROTOCOL.md §6.2).
class ModeArg {
  ModeArg._();

  /// Deactivate / unlock (normal).
  static const int unlock = 0;

  /// Activate anti-theft (防盜).
  static const int antiTheft = 1;

  /// Activate cut-off (斷電).
  static const int cutOff = 2;

  /// Detect special: triggers a 10 s detect keep-alive poller after the write.
  ///
  /// 🔴 **No longer used for release (2026-07-30).** The "live HCI
  /// capture uses this as the cut-off release" note this constant used to carry
  /// rested on one observation — of a **super-capacitor**, whose `0x23` reverted
  /// to `0x05`, its own status space, and which has no cut-off feature at all.
  /// Against two batteries genuinely in cut-off it did nothing across eight
  /// writes. What 0x06 actually is remains unknown; the constant is kept because
  /// the frame is documented, not because a use for it is established.
  static const int release = 6;
}

/// Reported mode/status code, stored device-side at offset 0x113 (PROTOCOL.md
/// §6.2) and echoed via selector 0x23.
///
/// 🔴 **Corrected 2026-07-30 from `0 / 2 / 4` to `0 / 1 / 2`.** The old values
/// were inferred from the reference app's decompiled UI logic (`currentMode !=
/// 2` / `!= 4`) and were never seen on the wire. Labelled ground truth now
/// falsifies them: an owner put two batteries through all three states and
/// annotated each export, and `0x23` tracked the labels exactly.
///
/// ```
/// unit 1441 (EU 50Ah)          unit 1261 (JIS 40Ah)
///   19:00  0x00                  18:58  0x02   ← UNLABELLED, see below
///   19:09  0x02  ← 斷電模式       19:16  0x01   ← exported as 防盜模式
///   19:19  0x01  ← 防盜模式       19:22  0x00   ← exported as 正常模式
///   19:24  0x00  ← 正常模式
/// ```
///
/// ⚠️ **Narrowed 2026-07-31.** The 1261 `0x02` row was previously written as
/// "exported as 斷電模式". It was not: batch `010`'s readme names the pack only
/// ("日規鋰鐵40AH") and states no mode, unlike `011`–`015` which all name one.
/// The owner has ruled that batch's mode unknown and not worth chasing, so this
/// row is **withdrawn as evidence** — the `0x02` reading stands, the label does
/// not.
///
/// Zero XOR failures across 705 frames. What survives is still decisive, but
/// state the count honestly: `0x02` = cut-off is labelled on **one** unit
/// (1441), `0x01` and `0x00` on **two**. The distributor independently states
/// the same numbering for the WRITE argument, so reported status and [ModeArg]
/// share one space — the previous "these are different code spaces, do not
/// compare them" note was wrong about packs.
///
/// What this cost while it was wrong: a battery sitting in cut-off (`0x02`) was
/// rendered as "anti-theft", with the cut-off badge reading "off" — the app told
/// an owner their pack was not cut off while it was.
///
/// `0x04` is NOT a pack state. It has never been observed, here or anywhere in
/// the corpus, and decodes to null.
///
/// A super-capacitor answers in a DIFFERENT space ([CapacitorStatus]) — that
/// part still holds; see the class doc there for the capture that proves it.
///
/// Compare with `==`, never with a bitmask. A mask is still provably wrong, and
/// on the corrected values it is wrong in a new way: a healthy capacitor reports
/// `5`, and `5 & 1 != 0` would report it as "anti-theft active".
class ReportedStatus {
  ReportedStatus._();

  /// Normal (lock icon). ✅ wire-verified.
  static const int normal = 0;

  /// Anti-theft active (防盜模式已啟動). ✅ wire-verified 2026-07-30.
  static const int antiTheftActive = 1;

  /// Cut-off active (斷電模式已啟動). ✅ wire-verified 2026-07-30.
  static const int cutOffActive = 2;
}

/// Super-capacitor status code space for selector `0x23`.
///
/// A capacitor does NOT have a run mode — it has no cut-off and no anti-theft
/// (it is a monitor-plus-self-check unit), so [ReportedStatus] does not apply to
/// it at all. Its `0x23` byte lives in its own space.
///
/// **Wire evidence** (our own captures, 2026-07-29 analysis):
/// * super-capacitor (device-type `0x17`): `0x23` = `0x05` on **1802 of 1802**
///   frames, no other value, on a unit the owner confirmed healthy.
/// * smart battery (device-type `0x02`): `0x23` = `0x00` on 531/531 and 112/112
///   frames across two different units.
///
/// Only the healthy value is named. Any other byte is reported as UNKNOWN
/// (raw byte surfaced for diagnosis) rather than guessed at — we have no
/// captured fault sample to name a code from.
class CapacitorStatus {
  CapacitorStatus._();

  /// The value a healthy super-capacitor reports (see class doc).
  static const int healthy = 5;
}
