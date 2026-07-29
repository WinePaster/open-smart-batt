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
  static const int twf = 0x20;

  /// Temperature (°C), signed int8 of b4.
  static const int temperature = 0x21;

  /// Mode register echo. b4 -> reported mode/status code.
  static const int mode = 0x23;

  /// DVOL per-series cell voltages (4 cells). Gated by field_cb 0168/01690104.
  static const int dvol = 0x24;

  /// Year (年份) — §8.5. NOT the serial high-word (earlier
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
  /// DVOL. Observed ~20.36 (§8.5). Not seen on the passive
  /// poll — see PROTOCOL.md §10.
  static const int vadj = 0x30;

  /// Secondary voltage SVLT (V).
  static const int svlt = 0x37;

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
  /// established, and the sibling register 0x49 carries a second (voltage,
  /// current) pair whose current field read zero across 97 frames / 4 sessions
  /// / both output profiles. So the app publishes a MAGNITUDE and never a
  /// direction, and 0x49 is deliberately left undecoded.
  static const int discharge = 0x4A;

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

  /// Release / detect special: triggers a 10 s detect keep-alive poller after
  /// the write. live HCI capture uses this value (0x06) as the cut-off release.
  static const int release = 6;
}

/// Reported mode/status code, stored device-side at offset 0x113 (PROTOCOL.md
/// §6.2) and echoed via selector 0x23.
///
/// These three codes are the **smart-battery / pack** space. A super-capacitor
/// answers in a DIFFERENT space ([CapacitorStatus]) — see the class doc there
/// for the capture that proves it.
///
/// Compare with `==`, never with a bitmask. PROTOCOL.md §6.2 records the
/// reference app's own UI logic as equality (`currentMode != 2` / `!= 4`), and a
/// mask is provably wrong: `5 & 4 != 0` would report a healthy capacitor as
/// "cut-off active".
class ReportedStatus {
  ReportedStatus._();

  /// Normal (lock icon).
  static const int normal = 0;

  /// Anti-theft active (防盜模式已啟動).
  static const int antiTheftActive = 2;

  /// Cut-off active (斷電模式已啟動).
  static const int cutOffActive = 4;
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
