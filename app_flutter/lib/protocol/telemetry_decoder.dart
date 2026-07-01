/// OpenSmartBatt — telemetry decoder (PROTOCOL.md §8 formulas).
///
/// PURE Dart, deterministic, no IO. Two surfaces:
///   * static per-selector pure functions — easy to unit-test against a frame.
///   * [TelemetryDecoder] — a stateful accumulator that folds successive frames
///     into one [TelemetrySample] (DVOL needs the last-seen VADJ, so state is
///     required there).
library;

import '../models/telemetry_sample.dart';
import 'inbound_frame.dart';
import 'selectors.dart';

/// Pure per-selector decode helpers. `b(i)` is the spec byte index (b4 = first
/// payload byte). 16-bit values are big-endian.
class TelemetryDecoder {
  TelemetrySample _sample;

  TelemetryDecoder([TelemetrySample? initial])
      : _sample = initial ?? TelemetrySample.empty();

  /// Current accumulated snapshot.
  TelemetrySample get sample => _sample;

  /// Reset the accumulator (e.g. on reconnect).
  void reset() => _sample = TelemetrySample.empty();

  /// Fold one frame into the accumulator and return the new snapshot. Unknown
  /// selectors and bad-checksum frames leave the snapshot unchanged (except the
  /// timestamp is NOT bumped on no-op).
  TelemetrySample ingest(InboundFrame f, {DateTime? at}) {
    if (!f.checksumOk) return _sample;
    final updated = apply(_sample, f, at: at);
    _sample = updated;
    return updated;
  }

  // ---- static formulas (PROTOCOL.md §8.2) ----

  /// PVLT (V) — selector 0x19: (b4*256+b5)/100.
  static double pvlt(InboundFrame f) => f.u16(4) / 100.0;

  /// PVLT gauge index 0..28 — selector 0x19: trunc((PVLT-8)*3.5), clamp 0..28.
  static int pvltGaugeIndex(double pvltVolts) {
    final idx = ((pvltVolts - 8.0) * 3.5).truncate();
    if (idx < 0) return 0;
    if (idx > 28) return 28;
    return idx;
  }

  /// SVLT (V) — selector 0x37: (b4*256+b5)/100.
  static double svlt(InboundFrame f) => f.u16(4) / 100.0;

  /// Temperature (°C) — selector 0x21: signed int8 of b4.
  static int temperature(InboundFrame f) {
    final v = f.b(4);
    return v >= 0x80 ? v - 0x100 : v;
  }

  /// Main current (A) — selector 0x2E: 512 - (b4*256+b5).
  static double current(InboundFrame f) => (512 - f.u16(4)).toDouble();

  /// VADJ scale — selector 0x30: (b4*256+b5)/100.
  static double vadj(InboundFrame f) => f.u16(4) / 100.0;

  /// DVOL cell voltages (4) — selector 0x24: (b[i]/1000)*vadjScale, i=4..7.
  static List<double> dvol(InboundFrame f, double vadjScale) =>
      [for (var i = 4; i <= 7; i++) (f.b(i) / 1000.0) * vadjScale];

  /// Warning over-voltage (V) — selector 0x2B: b4*0.025 + 14.4.
  static double warnOv(InboundFrame f) => f.b(4) * 0.025 + 14.4;

  /// Warning under-voltage (V) — selector 0x2B: b5*0.025 + 10.4.
  static double warnUv(InboundFrame f) => f.b(5) * 0.025 + 10.4;

  /// Warning over-temperature (°C) — selector 0x2B: b6 + 60.
  static double warnOt(InboundFrame f) => f.b(6) + 60.0;

  /// Charge / discharge value at spec index — /100 then /10 (= /1000).
  static double scaled1000(InboundFrame f, int specIndex) =>
      f.u16(specIndex) / 100.0 / 10.0;

  /// Capacity raw byte — selector 0x96: b6.
  static int capacityRaw(InboundFrame f) => f.b(6);

  /// Capacity / SOH bucket — selector 0x96: from b6, int.tryParse digits then
  /// (n-1)*10 + 5. PROTOCOL.md §8.2 (bucket semantics unverified).
  static int? sohBucket(InboundFrame f) {
    final raw = f.b(6);
    final n = int.tryParse(raw.toString());
    if (n == null) return null;
    return (n - 1) * 10 + 5;
  }

  /// Battery serial — selector 0x25/0x26: b4..b9 packed big-endian into a 48-bit
  /// int, stringified, padLeft(6, '0').
  static String serial(InboundFrame f) {
    var v = 0;
    for (var i = 4; i <= 9; i++) {
      v = (v << 8) | f.b(i);
    }
    return v.toString().padLeft(6, '0');
  }

  /// Dealer code / field_cb — selector 0x27: "%04d%02X%02X" of
  /// (b4*256+b5), b6, b7 (PROTOCOL.md §4.4). b8/b9 unused.
  static String dealerCode(InboundFrame f) {
    final dec = (f.u16(4)).toString().padLeft(4, '0');
    final h6 = f.b(6).toRadixString(16).toUpperCase().padLeft(2, '0');
    final h7 = f.b(7).toRadixString(16).toUpperCase().padLeft(2, '0');
    return '$dec$h6$h7';
  }

  /// Folds a single frame into [base], returning a new sample. Pure.
  static TelemetrySample apply(
    TelemetrySample base,
    InboundFrame f, {
    DateTime? at,
  }) {
    final ts = at ?? DateTime.now();
    switch (f.selector) {
      case Selectors.pvlt:
        final v = pvlt(f);
        return base.copyWith(
            timestamp: ts, pvlt: v, pvltGaugeIndex: pvltGaugeIndex(v));
      case Selectors.svlt:
        return base.copyWith(timestamp: ts, svlt: svlt(f));
      case Selectors.temperature:
        return base.copyWith(timestamp: ts, temperatureC: temperature(f));
      case Selectors.current:
        return base.copyWith(timestamp: ts, current: current(f));
      case Selectors.vadj:
        return base.copyWith(timestamp: ts, vadj: vadj(f));
      case Selectors.dvol:
        return base.copyWith(timestamp: ts, dvol: dvol(f, base.vadj ?? 1.0));
      case Selectors.thresholds:
        return base.copyWith(
          timestamp: ts,
          warnOv: warnOv(f),
          warnUv: warnUv(f),
          warnOt: warnOt(f),
        );
      case Selectors.charge:
        return base.copyWith(
          timestamp: ts,
          chargeV1: scaled1000(f, 4),
          chargeV2: scaled1000(f, 6),
        );
      case Selectors.discharge:
        return base.copyWith(
          timestamp: ts,
          dischargeV1: scaled1000(f, 4),
          dischargeV2: scaled1000(f, 6),
        );
      case Selectors.capacity:
        return base.copyWith(
          timestamp: ts,
          capacityRaw: capacityRaw(f),
          sohBucket: sohBucket(f),
        );
      case Selectors.deviceType:
        return base.copyWith(timestamp: ts, deviceType: f.b(4));
      case Selectors.serialA:
      case Selectors.serialB:
        return base.copyWith(timestamp: ts, serial: serial(f));
      case Selectors.dealerCode:
        return base.copyWith(timestamp: ts, dealerCode: dealerCode(f));
      case Selectors.mode:
        return base.copyWith(timestamp: ts, mode: f.b(4));
      case Selectors.twf:
        return base.copyWith(timestamp: ts, twfRaw: f.b(4));
      default:
        // Unknown / not-stored selector (e.g. 0x2F secondary current): no-op.
        return base;
    }
  }
}
