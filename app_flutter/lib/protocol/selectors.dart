/// OpenSmartBatt — inbound notification selectors (PROTOCOL.md §5.2 / §8).
///
/// An inbound frame is `[0xB8, selector, 0x01, LEN, payload(LEN), XOR]`. The
/// dispatch key is `byteList[1]` (the selector). These constants name the ones
/// we decode; unknown selectors are tolerated and ignored.
library;

/// Inbound selector codes (the 2nd byte of a notification frame).
class Selectors {
  Selectors._();

  /// Device type. b4; == 0x44 ('D') -> power-bank flag.
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

  /// Battery serial number (variant A).
  static const int serialA = 0x25;

  /// Battery serial number (variant B).
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

  /// VADJ voltage-precision adjust; multiplier for DVOL.
  static const int vadj = 0x30;

  /// Secondary voltage SVLT (V).
  static const int svlt = 0x37;

  /// Charge info (v1 / v2).
  static const int charge = 0x41;

  /// Discharge info (v1 / v2).
  static const int discharge = 0x4A;

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
  /// the write. CAPTURE_VERIFIED uses this value (0x06) as the cut-off release.
  static const int release = 6;
}

/// Reported mode/status code, stored device-side at offset 0x113 (PROTOCOL.md
/// §6.2) and echoed via selector 0x23. NOTE: the live capture shows a baseline
/// of 0x05 with a transient pulse to 0x06; the documented 0/2/4 status space and
/// the captured 0x05/0x06 echo space are distinct and not fully reconciled.
class ReportedStatus {
  ReportedStatus._();

  /// Normal (lock icon).
  static const int normal = 0;

  /// Anti-theft active (防盜模式已啟動).
  static const int antiTheftActive = 2;

  /// Cut-off active (斷電模式已啟動).
  static const int cutOffActive = 4;
}
