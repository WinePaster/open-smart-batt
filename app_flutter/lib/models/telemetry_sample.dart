/// OpenSmartBatt — telemetry snapshot model.
///
/// PURE Dart (no Flutter imports) so the protocol decoder and unit tests can use
/// it freely. Immutable; the decoder accumulates via [copyWith]. Each inbound
/// frame typically updates ONE field, so most fields are nullable until seen.
library;

/// Physical USB port carrying the power-bank energy path, decoded from the
/// 0x4B port/protocol flag byte, **bit1 only** (Type-C cable / CC detect).
///
/// There is deliberately no `typeA`: bit0 was tested as a Type-A indicator in
/// four field readings and refuted in all four (design 0035 §3.2 / §4.3), so
/// the corpus holds no reliable Type-A signal and none is invented here. When
/// bit1 is clear the port is [unknown], never Type-A. This enum is derived from
/// the raw flag byte, so "Type-C cable present" is not the same claim as
/// "Type-C is the port currently supplying" — direction always comes from the
/// current sign, never from this.
enum UsbPort {
  /// bit1 set — a Type-C cable / CC is detected.
  typeC,

  /// bit1 clear — the port is not determined. Rendered as "路徑未定", NOT Type-A.
  unknown,
}

/// A point-in-time decode of the battery's telemetry registers (PROTOCOL.md §8).
class TelemetrySample {
  /// When this sample was assembled (app clock; not from the wire).
  final DateTime timestamp;

  /// Main / primary voltage PVLT (V) — selector 0x19.
  final double? pvlt;

  /// PVLT gauge index 0..28 = trunc((PVLT-8)*3.5), clamped — selector 0x19.
  final int? pvltGaugeIndex;

  /// Secondary voltage SVLT (V) — selector 0x37.
  final double? svlt;

  /// Temperature (°C), signed — selector 0x21.
  final int? temperatureC;

  /// Per-series cell voltages, 4 cells (V) — selector 0x24 (needs [vadj]).
  /// Stays null while [dvolPending] is true (DVOL frames arriving but [vadj]
  /// not yet known, so the volts scaling is undetermined).
  final List<double>? dvol;

  /// True when a DVOL frame (0x24) has arrived but [vadj] (0x30) has not, so the
  /// per-cell voltage scaling is unknown. The raw cell bytes are valid but their
  /// volts value cannot be computed yet — the UI shows a "pending" state instead
  /// of a bogus number. Cleared once [vadj] is seen and DVOL is scaled.
  /// See PROTOCOL.md §8.2 (DVOL scaling / VADJ) and §10 capture checklist.
  final bool dvolPending;

  /// Voltage-precision adjust factor — selector 0x30 (DVOL multiplier).
  final double? vadj;

  /// Main current (A).
  ///
  /// TWO sources with OPPOSITE sign conventions, because the two product
  /// families use different registers. Both are signed and both directions are
  /// established; what is NOT shared is which sign means what:
  /// * pack (battery / capacitor) — selector 0x2E, `512 - u16`. **Negative =
  ///   discharge, positive = charge** (`docs/protocol/telemetry-decoding.md`
  ///   §8.2, corrected 2026-08-11: five engine starts read −211…−446 A while
  ///   PVLT collapsed, then turned positive as PVLT climbed to 14.5 V).
  ///   Quantised to whole amps — 1 A per count, no fine structure near zero.
  /// * power bank — selector 0x4A minus 0x49, in amps. **Positive = discharge,
  ///   negative = charge** (design 0030; signed since FB-46, when publishing a
  ///   magnitude made a charging bank read 0.00 A forever).
  ///
  /// 🔴 Nothing may reason about direction from this field without knowing
  /// which family produced it. `ui/dashboard/power_flow.dart` has one
  /// derivation per family — `packFlowOf` and `powerFlowOf` — and they are not
  /// interchangeable.
  final double? current;

  /// Warning over-voltage threshold (V) — selector 0x2B.
  final double? warnOv;

  /// Warning under-voltage threshold (V) — selector 0x2B.
  final double? warnUv;

  /// Warning over-temperature threshold (°C) — selector 0x2B.
  final double? warnOt;

  /// Raw 4th byte (b7) of the 0x2B threshold frame. A 4th field is observed and
  /// labelled **UT (under-temp)**; its scaling is not byte-verified, so we keep
  /// the raw byte only (read-back). It is preserved on the write path instead of
  /// being forced to 0x00, so setting OV/UV/OT does not clobber the device's UT.
  /// PROTOCOL.md §10.2.
  final int? warnUtByte;

  /// Discharge info v1 / v2 — selector 0x4A.
  ///
  /// There is no charge-side counterpart. `0x41` ("charge info" in the vendor
  /// app) used to fill chargeV1/chargeV2 here; its v2 half was refuted in
  /// 2026-08 when the last payload byte turned out to carry the 0x21
  /// temperature. See TelemetryDecoder's note at Selectors.charge.
  final double? dischargeV1;
  final double? dischargeV2;

  /// Power-bank charge-side current (A) from `0x49`, magnitude as reported.
  ///
  /// Kept beside [current] rather than folded into it because the two registers
  /// arrive as separate frames — 0x49 first — and [current] has to be the
  /// combination of both. Storing only the combination would make the result
  /// depend on which frame landed last. Not exported: the CSV's `ampere` column
  /// already carries the signed value.
  final double? chargeCurrent;

  /// Raw capacity byte (b6) — selector 0x96.
  final int? capacityRaw;

  /// Design (nameplate) capacity in mAh — power-bank selector 0x4B, bytes b4b5.
  final int? designCapacityMah;

  /// Capacity / SOH bucket = (n-1)*10 + 5 — selector 0x96. Drives the battery
  /// fill-icon level (5% steps). Semantics unverified.
  final int? sohBucket;

  /// State-of-charge percent (0..100), read DIRECTLY from byte b6 of the
  /// capacity frame. This is the device-reported SOC; there is NO voltage->SOC
  /// curve. Distinct from [sohBucket], which is only the icon-level bucket.
  ///
  /// Two sources, and only one of them is evidenced:
  ///   * power bank, selector 0x4B — PROTOCOL.md §9.1. A capture read 94 at the
  ///     same minute the unit's own display showed 94 %. This is the real one.
  ///   * pack, selector 0x96 — kept for symmetry, but 0x96 has NEVER been
  ///     observed on the wire (0 of 206,516 frames, PROTOCOL.md §9). If it ever
  ///     arrives, treat the first reading as unverified.
  final int? socPercent;

  // ---- USB port / protocol status (power bank, 0x4B byte b7) ---------------
  // The four never-populated shell fields (isTypeAOutput / isTypeCOutput /
  // inputFastChargeType / outputFastChargeType) and the unverified fast-charge
  // value->label table they were shaped around are GONE (design 0035 §1.2). The
  // register that carries port status was found — 0x4B byte b7 — so this now
  // stores that raw byte and derives the display fields from it via the getters
  // below, keeping "the port shown agrees with the direction shown" a single
  // decision rather than four independently-null fields.

  /// Raw 0x4B byte b7 — the power-bank port / protocol flag byte
  /// (design 0035 §3.2). NULL until a 0x4B frame has been folded in.
  ///
  /// Stored raw (never shown to a user — clean-room string discipline, no raw
  /// bytes on screen) so the decoded getters below and the design 0035 §4.8
  /// feedback hook read from ONE source. Bit map: bit1 = Type-C cable/CC,
  /// bit2 = output active, bit3 = PD input, bit5 = PD output. **bit0 and bit4
  /// are decoded to NOTHING** — bit0 was refuted as a Type-A indicator in four
  /// field readings (§3.2), bit4 is a suspected firmware variant, and neither
  /// may influence any display decision.
  final int? portFlagsRaw;

  /// Device-type byte (b4) — selector 0x10. 0x22 (34) => power bank. PROTOCOL.md
  /// §8.2/§9: 0x44 was the Dart Smi-tag (34<<1), NOT the wire byte.
  final int? deviceType;

  /// Product serial **tail** (zero-padded decimal string) — selector 0x26. This
  /// is only the low part; the full serial is [fullSerial] (dealer code + this).
  final String? serial;

  /// Dealer code / field_cb string (e.g. "01680000") — selector 0x27. Its own
  /// layout is `0168` + dealer number, so it is the prefix of [fullSerial].
  final String? dealerCode;

  /// The device's own BLE address as an upper-case colon-separated MAC (e.g.
  /// `34:14:B5:B4:70:93`) — selector 0x38, sent as ASCII (PROTOCOL.md §8.2.3).
  /// NULL until a 0x38 frame arrives. This is the ONE identity that is stable
  /// across platforms and reinstalls (design 0027 §3.2); the platform device id
  /// is a MAC on Android but an install-scoped NSUUID on iOS.
  ///
  /// 🔴 CLEAN-ROOM: the raw MAC is personal data. It is fine to hold and persist
  /// it internally, but it must NEVER be written to any exported artifact — an
  /// export writes its [shortDeviceHash] instead. See design 0027 §3.1.
  final String? mac;

  /// Reported mode/status code (b4) — selector 0x23. Pack states are 0/1/2
  /// (normal / anti-theft / cut-off); a capacitor reports its own 0x05 baseline
  /// instead. Corrected 2026-08-01: this said "0/2/4", and `0x04` occurs
  /// nowhere in the corpus — see [ReportedStatus] for the wire-verified set.
  final int? mode;

  /// Raw TWF status byte (b4) — selector 0x20. Bit semantics unverified.
  ///
  /// Recorded, never interpreted. The app used to treat `0x20` as a device
  /// fault flag; field captures showed that value appears ONLY on power banks
  /// and only while charging — 0 occurrences across 13,535 pack samples — so
  /// the claim was removed. The rule had come from a single capture predating
  /// per-device attribution, where a charging power bank's 4 V reading was read
  /// as a 12 V battery collapsing. What is
  /// left here is a faithful transcription of the byte, which is exactly what
  /// let us find the mistake in the first place.
  ///
  /// ⚠️ Do NOT use this byte to decide charge/discharge direction — it is not
  /// complete (trickle charging reports `0x00`). Direction comes from the
  /// 0x49 / 0x4A current fields.
  final int? twfRaw;

  const TelemetrySample({
    required this.timestamp,
    this.pvlt,
    this.pvltGaugeIndex,
    this.svlt,
    this.temperatureC,
    this.dvol,
    this.dvolPending = false,
    this.vadj,
    this.current,
    this.warnOv,
    this.warnUv,
    this.warnOt,
    this.warnUtByte,
    this.dischargeV1,
    this.dischargeV2,
    this.chargeCurrent,
    this.capacityRaw,
    this.designCapacityMah,
    this.sohBucket,
    this.socPercent,
    this.portFlagsRaw,
    this.deviceType,
    this.serial,
    this.dealerCode,
    this.mac,
    this.mode,
    this.twfRaw,
  });

  /// An empty sample stamped [at] (defaults to now).
  factory TelemetrySample.empty([DateTime? at]) =>
      TelemetrySample(timestamp: at ?? DateTime.now());

  /// True when the device-type byte marks a power bank (0x22 = 34). PROTOCOL.md
  /// §9: the reference app's `cmp #0x44` compares the Smi-tagged value
  /// (34<<1), so the real wire byte is 0x22, not ASCII 'D'.
  bool get isPowerBank => deviceType == 0x22;

  /// True when the device-type byte marks a car smart battery (0x02). Observed
  /// `[10] 裝置識別 = 02 汽車智慧電池` (PROTOCOL.md §10.2).
  bool get isSmartBattery => deviceType == 0x02;

  // ---- decoded 0x4B b7 port / protocol fields (design 0035 §4.2) -----------
  // All null until [portFlagsRaw] is seen — a power bank takes up to ~10 s per
  // connection to send its first 0x4B, and "not decoded yet" must stay distinct
  // from any decoded state. bit0 and bit4 never appear here.

  /// USB port from b7 **bit1 only** (Type-C cable / CC). Never Type-A: bit0 is
  /// not consulted (design 0035 §4.3). Null until [portFlagsRaw] is seen.
  UsbPort? get usbPort {
    final b7 = portFlagsRaw;
    if (b7 == null) return null;
    return (b7 & 0x02) != 0 ? UsbPort.typeC : UsbPort.unknown;
  }

  /// b7 == 0x00 — the boost rail is off ("待機 · 輸出已關閉", design 0035
  /// §3.3 / §4.3; verified across 73 corpus frames). Null until b7 is seen.
  bool? get isRailOff {
    final b7 = portFlagsRaw;
    return b7 == null ? null : b7 == 0x00;
  }

  /// b7 bit2 — the boost rail is actively outputting. Null until b7 is seen.
  bool? get isOutputActive {
    final b7 = portFlagsRaw;
    return b7 == null ? null : (b7 & 0x04) != 0;
  }

  /// b7 bit3 — PD **input** negotiated.
  ///
  /// ONE-WAY (design 0035 §4.4): set implies PD input, but CLEAR does NOT imply
  /// "not PD" — a 9.05 V / 1.83 A charge reads bit3 clear (16 counter-examples).
  /// Consumers must render a positive "PD" badge only, never a "non-PD" label.
  /// Null until b7 is seen.
  bool? get isPdIn {
    final b7 = portFlagsRaw;
    return b7 == null ? null : (b7 & 0x08) != 0;
  }

  /// b7 bit5 — PD **output**. Null until b7 is seen.
  bool? get isPdOut {
    final b7 = portFlagsRaw;
    return b7 == null ? null : (b7 & 0x20) != 0;
  }

  /// Full product serial = **dealer code (0x27) + product serial (0x26)**, per
  /// field feedback (`0168` + 經銷商編號 + 產品序號, e.g. `016812340012345`).
  /// The dealer code already carries the `0168`+dealer prefix; the product serial
  /// is zero-padded to 7 digits. Null until both source frames arrive (they come
  /// in the connect burst, §10.2). Exact pad width is unverified — confirm vs the
  /// vendor app.
  String? get fullSerial {
    final d = dealerCode;
    final s = serial;
    if (d == null || s == null) return null;
    final prod = int.tryParse(s) ?? 0;
    // 🔴 design 0027 §3.2.2: an all-zero 0x26 means "no serial", NOT serial 0.
    // A second-generation super-capacitor (34:14:B5:4C:88:EF) reports
    // `000000` here; padding it would fabricate a very real-looking
    // `016802170000000`. Treat it as absent rather than invent one.
    if (prod == 0) return null;
    return '$d${prod.toString().padLeft(7, '0')}';
  }

  /// Gauge fill fraction 0..1 over the 8.0–16.0 V display range (mockup gauge).
  double get pvltGaugeFraction {
    final v = pvlt;
    if (v == null) return 0;
    final f = (v - 8.0) / 8.0;
    if (f < 0) return 0;
    if (f > 1) return 1;
    return f;
  }

  TelemetrySample copyWith({
    DateTime? timestamp,
    double? pvlt,
    int? pvltGaugeIndex,
    double? svlt,
    int? temperatureC,
    List<double>? dvol,
    bool? dvolPending,
    double? vadj,
    double? current,
    double? warnOv,
    double? warnUv,
    double? warnOt,
    int? warnUtByte,
    double? dischargeV1,
    double? dischargeV2,
    double? chargeCurrent,
    int? capacityRaw,
    int? designCapacityMah,
    int? sohBucket,
    int? socPercent,
    int? portFlagsRaw,
    int? deviceType,
    String? serial,
    String? dealerCode,
    String? mac,
    int? mode,
    int? twfRaw,
  }) {
    return TelemetrySample(
      timestamp: timestamp ?? this.timestamp,
      pvlt: pvlt ?? this.pvlt,
      pvltGaugeIndex: pvltGaugeIndex ?? this.pvltGaugeIndex,
      svlt: svlt ?? this.svlt,
      temperatureC: temperatureC ?? this.temperatureC,
      dvol: dvol ?? this.dvol,
      dvolPending: dvolPending ?? this.dvolPending,
      vadj: vadj ?? this.vadj,
      current: current ?? this.current,
      warnOv: warnOv ?? this.warnOv,
      warnUv: warnUv ?? this.warnUv,
      warnOt: warnOt ?? this.warnOt,
      warnUtByte: warnUtByte ?? this.warnUtByte,
      dischargeV1: dischargeV1 ?? this.dischargeV1,
      dischargeV2: dischargeV2 ?? this.dischargeV2,
      chargeCurrent: chargeCurrent ?? this.chargeCurrent,
      capacityRaw: capacityRaw ?? this.capacityRaw,
      designCapacityMah: designCapacityMah ?? this.designCapacityMah,
      sohBucket: sohBucket ?? this.sohBucket,
      socPercent: socPercent ?? this.socPercent,
      portFlagsRaw: portFlagsRaw ?? this.portFlagsRaw,
      deviceType: deviceType ?? this.deviceType,
      serial: serial ?? this.serial,
      dealerCode: dealerCode ?? this.dealerCode,
      mac: mac ?? this.mac,
      mode: mode ?? this.mode,
      twfRaw: twfRaw ?? this.twfRaw,
    );
  }

  /// Flat map for sqflite history rows / CSV export. Keys mirror the SQLite
  /// deviceData columns named in PROTOCOL.md §9.
  Map<String, Object?> toMap() => {
        'timestamp': timestamp.millisecondsSinceEpoch,
        'pvlt': pvlt,
        'svlt': svlt,
        'ampere': current,
        'temperature': temperatureC,
        'dvol1': dvol != null && dvol!.isNotEmpty ? dvol![0] : null,
        'dvol2': dvol != null && dvol!.length > 1 ? dvol![1] : null,
        'dvol3': dvol != null && dvol!.length > 2 ? dvol![2] : null,
        'dvol4': dvol != null && dvol!.length > 3 ? dvol![3] : null,
        'soh': sohBucket,
        'mode': mode,
        'twf': twfRaw,
        'serial': serial,
        // SOC was decoded and shown on the power-bank view but never persisted,
        // so it could not be exported — a dealer asked for the charge
        // percentage and the column simply did not exist. `device_id` is NOT
        // here — that
        // is a storage concern the repo stamps on, not sample data.
        'soc': socPercent,
      };

  static TelemetrySample fromMap(Map<String, Object?> m) => TelemetrySample(
        timestamp: DateTime.fromMillisecondsSinceEpoch(
            (m['timestamp'] as num?)?.toInt() ?? 0),
        pvlt: (m['pvlt'] as num?)?.toDouble(),
        svlt: (m['svlt'] as num?)?.toDouble(),
        current: (m['ampere'] as num?)?.toDouble(),
        temperatureC: (m['temperature'] as num?)?.toInt(),
        dvol: [
          (m['dvol1'] as num?)?.toDouble(),
          (m['dvol2'] as num?)?.toDouble(),
          (m['dvol3'] as num?)?.toDouble(),
          (m['dvol4'] as num?)?.toDouble(),
        ].whereType<double>().toList().let((l) => l.isEmpty ? null : l),
        sohBucket: (m['soh'] as num?)?.toInt(),
        mode: (m['mode'] as num?)?.toInt(),
        twfRaw: (m['twf'] as num?)?.toInt(),
        serial: m['serial'] as String?,
        socPercent: (m['soc'] as num?)?.toInt(),
      );
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
