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

  /// Firmware version: a **byte pair** `[major, minor]`, NOT a u16 — `0x0106` is
  /// firmware 1.06, not 262 (protocol/identity-and-rtc.md §8.2.3).
  /// Declassified 2026-07-30
  /// together with [bleAddress] and [rtc]: its semantics are documented openly
  /// in PROTOCOL.md §8.2.3, so keeping the constant out of this file only ever
  /// produced the worst combination — hidden in code, published in the docs.
  static const int firmwareVersion = 0x29;

  /// System counters. Two lengths, and the length identifies the class:
  /// LEN 11 `[u24 standby min][u24 connected min][u16 sleeps][u16 power-ons][u8 cut-offs]`,
  /// LEN 10 drops the trailing cut-off count. Decoded openly in
  /// protocol/telemetry-decoding.md §8.4; declassified 2026-08-09 on the same
  /// grounds as [bleAddress] — the semantics were already public while this
  /// constant was not.
  ///
  /// The two minute fields are since-wake, not lifetime (corrected 2026-08-07).
  static const int systemCounters = 0x34;

  /// Device RTC, 7 bytes: `[u16 year BE][MM][DD][hh][mm][ss]`.
  ///
  /// **`MM` and `DD` are 0-based** (verified 2026-08-01): `MM = 0x07` is August,
  /// `DD = 0x00` is the 1st. Decoding them as 1-based yields month 0 / day 0 on
  /// thousands of frames. See protocol/identity-and-rtc.md.
  static const int rtc = 0x3B;

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
  /// 1.05 A. The first field is the CELL voltage — it tracks [pvlt] (0x19), so
  /// it is not decoded again. Measured by same-burst pairing across **five
  /// physical units**: median difference **+4 mV**, and 96–100 % of samples
  /// within ±30 mV, against a deliberately mis-paired control at +1,634 mV
  /// (2026-08-05). The sibling [chargeCurrent]'s mV field is the PORT voltage
  /// instead — the two are NOT the same quantity.
  ///
  /// Whether that current is measured cell-side or at the output port is NOT
  /// established. That is a separate question from which voltage each mV field
  /// copies; knowing the latter says nothing about the former.
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
  /// ~~⚠️ Three physical units cover the discharging side; the charging side is
  /// so far ONE unit.~~ **Stale as of 2026-08-05 — the charging side now has a
  /// second unit**, and at 20× the sample count: 36,152 complete bursts over
  /// 10.5 h at 1 Hz, mutually exclusive in 36,145, both non-zero in **7**
  /// (0.02 %, every one inside the second a direction changes, at 2–5 mA), both
  /// zero in **0**. Both halves now clear the multi-unit bar, and the protocol
  /// document says so.
  ///
  /// 🔲 **This register's mV field is the PORT voltage** (the same quantity as
  /// `0x37`), not the cell voltage that [discharge]'s mV field carries: five
  /// units, median +4 mV against `0x37` and 85–95 % within ±30 mV, versus a
  /// mis-paired control at +1,634 mV. **Deliberately still not decoded here** —
  /// only `u16(6)`, the current, is read.
  ///
  /// Noted because there is an opportunity in it, and a ruling owed: this
  /// register arrives in the SAME BURST as `0x4B`, whereas `0x37` — the port
  /// voltage the energy-path row displays — free-runs on its own cadence.
  /// design 0035 §4.5 asked for same-burst coupling of the displayed voltage
  /// and the status line books not doing it as an accepted deviation. Reading
  /// this mV field would close that deviation. Do not do it on the strength of
  /// this comment.
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

  /// Start a super-capacitor's SELF-CHECK (檢測電容). Capacitor-only.
  ///
  /// 🔵 **Renamed from `release` on 2026-08-28, and it now has a caller.**
  /// The old name was the fossil of a 2026-07-30 misread: one super-capacitor
  /// was seen pulsing `0x23` to `0x06` and back to `0x05`, and that single
  /// observation was written down as "the cut-off release opcode" — a BATTERY
  /// feature. Against two batteries genuinely in cut-off it did nothing across
  /// eight writes, which is what a value that is not in the battery code space
  /// at all looks like. The old doc closed with "what 0x06 actually is remains
  /// unknown"; that sentence is what this change retires.
  ///
  /// What it is: writing `0x06` puts a super-capacitor into its self-check
  /// mode. The unit reads `0x06` back for a few seconds and then reports
  /// [CapacitorStatus.selfCheckRunning] — see that class for the read side and
  /// for what it does NOT promise about coming back on its own.
  ///
  /// 🔴 SAFETY, and it is not the same shape as the other three:
  ///   * this WRITE CHANGES DEVICE STATE, and while the check runs the unit's
  ///     own voltage readings fall well below their resting value. A caller
  ///     must confirm with the user first — see `capacitorSelfCheck` in
  ///     `ui/dashboard/status_controls_shared.dart`;
  ///   * it must be gated on the super-capacitor class
  ///     (`DeviceCapabilities.isCapacitor`). It is NOT in the unclassified
  ///     fallback, deliberately: that fallback's whole safety argument is that
  ///     nothing in it can change a device's state.
  static const int capacitorSelfCheck = 6;
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
/// A capacitor has no cut-off and no anti-theft (it is a monitor-plus-
/// self-check unit), so [ReportedStatus] does not apply to it at all. Its
/// `0x23` byte lives in its own space.
///
/// ⚠️ **Narrowed 2026-08-28.** This paragraph used to open "a capacitor does
/// NOT have a run mode", and that half is now falsified: a super-capacitor
/// accepts `0x23` mode WRITES and answers them — see
/// [ModeArg.capacitorSelfCheck]. What survives, and what the sentence was
/// really carrying, is that the two code spaces do not overlap.
///
/// **Wire evidence** (our own captures, 2026-07-29 analysis):
/// * super-capacitor (device-type `0x17`): `0x23` = `0x05` on **1802 of 1802**
///   frames, no other value, on a unit the owner confirmed healthy.
/// * smart battery (device-type `0x02`): `0x23` = `0x00` on 531/531 and 112/112
///   frames across two different units.
///
/// 🔵 **Two more values named 2026-08-28 (FB-102).** `0x06` and `0x07` are the
/// SELF-CHECK read-back, not fault codes: a unit that has been sent
/// [ModeArg.capacitorSelfCheck] reads `0x06` back for a few seconds and then
/// reports `0x07` while the check runs. Field capture 2026-08-27, one
/// super-capacitor, `0x23` = `0x07` on 99 frames.
///
/// 🔴 **What this cost while they were unnamed** — and it is the whole reason
/// they are named now: everything except `0x05` fell through to
/// `CapacitorHealth.unknown`, so a unit that had merely been put into
/// self-check was shown as 「無法辨識」 in an amber badge, with an advisory
/// asking its owner to export a diagnostic log. A working capacitor, reported
/// as a defect, on the strength of a byte that means "busy".
///
/// ⛔ **`0x07` does NOT promise to clear itself.** Two of the three observed
/// checks stayed at `0x07` — one of them across three reconnections and 23
/// minutes — while the third returned to [healthy] about six seconds in, with
/// nothing written to it in between. Anything that waits for `0x05` must
/// therefore have a way to stop waiting, and must not claim the check finished.
///
/// Beyond these three, any other byte is still reported as UNKNOWN (raw byte
/// surfaced to the diagnostic log) rather than guessed at — we hold no captured
/// fault sample to name a code from.
class CapacitorStatus {
  CapacitorStatus._();

  /// The value a healthy super-capacitor reports (see class doc).
  static const int healthy = 5;

  /// Self-check accepted — the read-back of a `0x23` ←
  /// [ModeArg.capacitorSelfCheck] write, held for roughly four to five seconds
  /// before the unit moves to [selfCheckRunning].
  static const int selfCheckStarting = 6;

  /// Self-check RUNNING. See the class doc: this state may persist
  /// indefinitely.
  static const int selfCheckRunning = 7;

  /// True while the unit reports either self-check byte.
  ///
  /// 🔑 The single source of that two-value set. It is read by the badge, by
  /// the button's own busy gate, and by the alert evaluator's under-voltage
  /// suppression, and three private copies of `mode == 6 || mode == 7` is
  /// exactly how the screen and the alarm end up disagreeing about whether a
  /// unit is busy.
  static bool isSelfCheck(int? mode) =>
      mode == selfCheckStarting || mode == selfCheckRunning;
}
