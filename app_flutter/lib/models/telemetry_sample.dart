/// Open-RCE-Batt — telemetry snapshot model.
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
  final List<double>? dvol;

  /// Voltage-precision adjust factor — selector 0x30 (DVOL multiplier).
  final double? vadj;

  /// Main current (A) — selector 0x2E.
  final double? current;

  /// Warning over-voltage threshold (V) — selector 0x2B.
  final double? warnOv;

  /// Warning under-voltage threshold (V) — selector 0x2B.
  final double? warnUv;

  /// Warning over-temperature threshold (°C) — selector 0x2B.
  final double? warnOt;

  /// Charge info v1 / v2 — selector 0x41.
  final double? chargeV1;
  final double? chargeV2;

  /// Discharge info v1 / v2 — selector 0x4A.
  final double? dischargeV1;
  final double? dischargeV2;

  /// Raw capacity byte (b6) — selector 0x96.
  final int? capacityRaw;

  /// Capacity / SOH bucket = (n-1)*10 + 5 — selector 0x96. Semantics unverified.
  final int? sohBucket;

  /// Device-type byte (b4) — selector 0x10. 0x44 ('D') => power bank.
  final int? deviceType;

  /// Battery serial (zero-padded decimal string) — selector 0x25 / 0x26.
  final String? serial;

  /// Dealer code / field_cb string (e.g. "01680104") — selector 0x27.
  final String? dealerCode;

  /// Reported mode/status code (b4) — selector 0x23 (e.g. 0x05 baseline,
  /// transient 0x06; documented status space 0/2/4).
  final int? mode;

  /// Raw TWF status byte (b4) — selector 0x20. Bit semantics unverified.
  final int? twfRaw;

  const TelemetrySample({
    required this.timestamp,
    this.pvlt,
    this.pvltGaugeIndex,
    this.svlt,
    this.temperatureC,
    this.dvol,
    this.vadj,
    this.current,
    this.warnOv,
    this.warnUv,
    this.warnOt,
    this.chargeV1,
    this.chargeV2,
    this.dischargeV1,
    this.dischargeV2,
    this.capacityRaw,
    this.sohBucket,
    this.deviceType,
    this.serial,
    this.dealerCode,
    this.mode,
    this.twfRaw,
  });

  /// An empty sample stamped [at] (defaults to now).
  factory TelemetrySample.empty([DateTime? at]) =>
      TelemetrySample(timestamp: at ?? DateTime.now());

  /// True when device-type byte is 0x44 ('D').
  bool get isPowerBank => deviceType == 0x44;

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
    double? vadj,
    double? current,
    double? warnOv,
    double? warnUv,
    double? warnOt,
    double? chargeV1,
    double? chargeV2,
    double? dischargeV1,
    double? dischargeV2,
    int? capacityRaw,
    int? sohBucket,
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
      vadj: vadj ?? this.vadj,
      current: current ?? this.current,
      warnOv: warnOv ?? this.warnOv,
      warnUv: warnUv ?? this.warnUv,
      warnOt: warnOt ?? this.warnOt,
      chargeV1: chargeV1 ?? this.chargeV1,
      chargeV2: chargeV2 ?? this.chargeV2,
      dischargeV1: dischargeV1 ?? this.dischargeV1,
      dischargeV2: dischargeV2 ?? this.dischargeV2,
      capacityRaw: capacityRaw ?? this.capacityRaw,
      sohBucket: sohBucket ?? this.sohBucket,
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
      );
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
