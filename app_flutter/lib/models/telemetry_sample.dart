/// OpenSmartBatt — telemetry snapshot model.
///
/// PURE Dart (no Flutter imports) so the protocol decoder and unit tests can use
/// it freely. Immutable; the decoder accumulates via [copyWith]. Each inbound
/// frame typically updates ONE field, so most fields are nullable until seen.
library;

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
  /// TWO sources with DIFFERENT sign conventions, because the two product
  /// classes use different registers:
  /// * pack (battery / capacitor) — selector 0x2E, `512 - u16`, **signed**
  ///   (negative while charging).
  /// * power bank — selector 0x4A second field, mA, **unsigned magnitude**.
  ///   Direction is not established (see [Selectors.discharge]), so no sign is
  ///   invented. Anything reasoning about charge/discharge direction must not
  ///   read this field on a power bank.
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

  /// Charge info v1 / v2 — selector 0x41.
  final double? chargeV1;
  final double? chargeV2;

  /// Discharge info v1 / v2 — selector 0x4A.
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

  // ---- USB dual-port status ------------------------------------------------
  // These four fields have never been populated, and the register they were
  // waiting for has since been found: it is 0x4B byte b7 (PROTOCOL.md §9.1),
  // where bit1 = Type-C, bit2 = output active, bit3 = PD input, bit5 = PD
  // output. bit0 and bit4 are still open.
  //
  // They stay NULL because wiring them up is a UI change, not a decode change:
  // the two-port card these were shaped for is being replaced by a single
  // energy-path line, since only one path is ever live at a time and half a
  // card spent saying "idle" states nothing. Do NOT populate them piecemeal:
  // the port shown must agree with the direction shown, and that is one
  // decision, not four fields.
  //
  // The fast-charge value->label table these were originally shaped around
  // (0 none / 2 PD / 4 QC2.0 / ...) came from analysis of the reference app and
  // has NO wire evidence. Do not treat it as certain.

  /// USB Type-A port is currently supplying power (供電). NULL until decoded.
  final bool? isTypeAOutput;

  /// USB Type-C port is currently supplying power (供電). NULL until decoded.
  final bool? isTypeCOutput;

  /// Input (charge) fast-charge protocol code (PROTOCOL.md §9.1: 0 none / 2 PD
  /// / 4 other). NULL until decoded.
  final int? inputFastChargeType;

  /// Output (supply) fast-charge protocol code (PROTOCOL.md §9.1: 0 none / 2 PD
  /// / 4 QC2.0 / 6 QC3.0 / 8 FCP / 10 PE / 12 SFCP / 14 AFC). NULL until decoded.
  final int? outputFastChargeType;

  /// Device-type byte (b4) — selector 0x10. 0x22 (34) => power bank. PROTOCOL.md
  /// §8.2/§9: 0x44 was the Dart Smi-tag (34<<1), NOT the wire byte.
  final int? deviceType;

  /// Product serial **tail** (zero-padded decimal string) — selector 0x26. This
  /// is only the low part; the full serial is [fullSerial] (dealer code + this).
  final String? serial;

  /// Dealer code / field_cb string (e.g. "01680000") — selector 0x27. Its own
  /// layout is `0168` + dealer number, so it is the prefix of [fullSerial].
  final String? dealerCode;

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
    this.chargeV1,
    this.chargeV2,
    this.dischargeV1,
    this.dischargeV2,
    this.chargeCurrent,
    this.capacityRaw,
    this.designCapacityMah,
    this.sohBucket,
    this.socPercent,
    this.isTypeAOutput,
    this.isTypeCOutput,
    this.inputFastChargeType,
    this.outputFastChargeType,
    this.deviceType,
    this.serial,
    this.dealerCode,
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
    final prod = (int.tryParse(s) ?? 0).toString().padLeft(7, '0');
    return '$d$prod';
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
    double? chargeV1,
    double? chargeV2,
    double? dischargeV1,
    double? dischargeV2,
    double? chargeCurrent,
    int? capacityRaw,
    int? designCapacityMah,
    int? sohBucket,
    int? socPercent,
    bool? isTypeAOutput,
    bool? isTypeCOutput,
    int? inputFastChargeType,
    int? outputFastChargeType,
    int? deviceType,
    String? serial,
    String? dealerCode,
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
      chargeV1: chargeV1 ?? this.chargeV1,
      chargeV2: chargeV2 ?? this.chargeV2,
      dischargeV1: dischargeV1 ?? this.dischargeV1,
      dischargeV2: dischargeV2 ?? this.dischargeV2,
      chargeCurrent: chargeCurrent ?? this.chargeCurrent,
      capacityRaw: capacityRaw ?? this.capacityRaw,
      designCapacityMah: designCapacityMah ?? this.designCapacityMah,
      sohBucket: sohBucket ?? this.sohBucket,
      socPercent: socPercent ?? this.socPercent,
      isTypeAOutput: isTypeAOutput ?? this.isTypeAOutput,
      isTypeCOutput: isTypeCOutput ?? this.isTypeCOutput,
      inputFastChargeType: inputFastChargeType ?? this.inputFastChargeType,
      outputFastChargeType: outputFastChargeType ?? this.outputFastChargeType,
      deviceType: deviceType ?? this.deviceType,
      serial: serial ?? this.serial,
      dealerCode: dealerCode ?? this.dealerCode,
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
