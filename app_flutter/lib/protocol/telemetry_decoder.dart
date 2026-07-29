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
import 'metadata_parser.dart';
import 'selectors.dart';

/// Pure per-selector decode helpers. `b(i)` is the spec byte index (b4 = first
/// payload byte). 16-bit values are big-endian.
class TelemetryDecoder {
  TelemetrySample _sample;

  /// Injected device-metadata parser. The open build
  /// gets [NoopMetadataParser], which handles nothing — so the side-accumulator
  /// below stays [EmptyDeviceMetadata] and no closed selector is touched.
  final MetadataParser parser;

  /// Side-accumulator for device metadata, kept OUT of [TelemetrySample] so it
  /// never pollutes the open telemetry model. Opaque to the open side.
  DeviceMetadata _info = const EmptyDeviceMetadata();

  TelemetryDecoder({
    TelemetrySample? initial,
    this.parser = const NoopMetadataParser(),
  }) : _sample = initial ?? TelemetrySample.empty();

  /// Current accumulated snapshot.
  TelemetrySample get sample => _sample;

  /// Current accumulated device metadata (opaque marker on the open side;
  /// a closed parser folds it into its own concrete subtype).
  DeviceMetadata get deviceMetadata => _info;

  /// Reset the accumulator (e.g. on reconnect). Resets the metadata side-channel
  /// alongside the telemetry sample.
  void reset() {
    _sample = TelemetrySample.empty();
    _info = const EmptyDeviceMetadata();
  }

  /// Fold one frame into the accumulator and return the new snapshot. Unknown
  /// selectors and bad-checksum frames leave the snapshot unchanged (except the
  /// timestamp is NOT bumped on no-op).
  ///
  /// Selectors the injected [parser] claims are folded into the opaque
  /// [deviceMetadata] side-channel instead; the open build's
  /// Noop parser claims none, so this is a behavioural no-op there.
  TelemetrySample ingest(InboundFrame f, {DateTime? at}) {
    if (!f.checksumOk) return _sample;
    if (parser.handles(f.selector)) {
      _info = parser.fold(_info, f);
    }
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

  /// Per-cell voltages (V) — selector 0x47: 4 big-endian u16 mV values.
  /// Already scaled by the device, so no VADJ is involved.
  static List<double> cellVoltagesMv(InboundFrame f) =>
      [for (var i = 4; i <= 10; i += 2) f.u16(i) / 1000.0];

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

  /// SOC percent — selector 0x96: b6 read DIRECTLY as a 0..100 percentage
  /// (PROTOCOL.md §9.1). The device reports SOC straight; there is no
  /// voltage->SOC curve. Clamped to 0..100. Distinct from [sohBucket].
  static int socPercent(InboundFrame f) {
    final v = f.b(6);
    if (v < 0) return 0;
    if (v > 100) return 100;
    return v;
  }

  /// USB dual-port status — the power-bank "Command 7" frame (PROTOCOL.md §9.1).
  ///
  /// TODO(design 0001 §7 Q1): the exact SELECTOR value AND the bit offsets of
  /// the Type-A/Type-C supply bits and the input/output fast-charge value fields
  /// are UNKNOWN pending a live `!#` capture on a power bank (the value->label
  /// tables in PROTOCOL.md §9.1 are certain, but the bit positions are not).
  /// We deliberately do NOT decode here — returning [base] unchanged — rather
  /// than invent bit positions. Wire this up (and add a case in [apply]) once
  /// the selector + bit layout is confirmed.
  static TelemetrySample applyPortStatus(
    TelemetrySample base,
    InboundFrame f, {
    DateTime? at,
  }) {
    // Intentionally unimplemented — see TODO above.
    return base;
  }

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
      case Selectors.cellVoltagesMv:
        // Four big-endian u16s = 8 payload bytes. Anything shorter is refused
        // outright: InboundFrame.b() returns 0 out of range, so a truncated
        // frame would decode to 0.000 V per cell AND clear `dvolPending` —
        // publishing "we measured zero" where the truth is "we did not
        // receive it". That is the FB-13 mistake (a plausible number instead
        // of a pending state) arriving through a different door, and the
        // evidence base here is three frames, which is not enough to assume
        // the length is always right.
        if (f.len < 8) return base;
        // The device did the scaling for us, so this clears `dvolPending`
        // WITHOUT needing 0x30 — a unit that streams 0x47 can show per-cell
        // voltages even if the VADJ frame never arrives.
        return base.copyWith(
          timestamp: ts,
          dvol: cellVoltagesMv(f),
          dvolPending: false,
        );
      case Selectors.dvol:
        final scale = base.vadj;
        if (scale == null) {
          // 0x47 may already have published real per-cell voltages. Do NOT
          // pull them back to "pending" just because this lower-level frame
          // cannot be scaled yet — that would flicker a good reading away.
          if (base.dvol != null) return base;
          // VADJ (0x30) not yet seen: the raw cell bytes are valid but the
          // volts scaling is unknown, so a `?? 1.0` default would publish a
          // bogus ~0.16 V per cell. Surface a pending state instead of a wrong
          // number. PROTOCOL.md §8.2 / §10 — resolve VADJ on-device.
          return base.copyWith(timestamp: ts, dvolPending: true);
        }
        return base.copyWith(
            timestamp: ts, dvol: dvol(f, scale), dvolPending: false);
      case Selectors.thresholds:
        return base.copyWith(
          timestamp: ts,
          warnOv: warnOv(f),
          warnUv: warnUv(f),
          warnOt: warnOt(f),
          // b7: observed 4th field (UT / under-temp). Scaling unverified —
          // keep the raw byte so the write path can preserve it (§10.2).
          warnUtByte: f.b(7),
        );
      case Selectors.charge:
        return base.copyWith(
          timestamp: ts,
          chargeV1: scaled1000(f, 4),
          chargeV2: scaled1000(f, 6),
        );
      case Selectors.discharge:
        // Same 4 bytes, two readings — this is the per-class register map
        // (design 0007 made the class deterministic off the 0x10 byte, which
        // arrives EARLIER in the same burst than 0x4A, so the gate is settled
        // by the time we get here).
        //
        // But "earlier in the burst" is an observation, not a guarantee: a
        // truncated connect burst leaves the class unresolved, and eight such
        // segments exist in the field corpus. With no 0x10 the pack branch
        // below would run on a power bank and read 3955 mV / 1081 mA as
        // "3.955 / 1.081" — two numbers that look entirely reasonable. That is
        // the FB-22 failure mode exactly: a class-agnostic formula on an
        // unattributed frame. design 0012 §5 says both 0x4A and 0x4B no-op
        // while the class is unknown; 0x4B did and this did not.
        if (base.deviceType == null) return base;
        if (base.isPowerBank) {
          // `[u16 mV][u16 mA]`. Only the current is taken: the mV field tracks
          // PVLT (0x19) to ±10 mV, so decoding it again would just be a second
          // name for the same number. Magnitude only — see Selectors.discharge.
          return base.copyWith(timestamp: ts, current: f.u16(6) / 1000.0);
        }
        return base.copyWith(
          timestamp: ts,
          dischargeV1: scaled1000(f, 4),
          dischargeV2: scaled1000(f, 6),
        );
      case Selectors.powerBankCapacity:
        // Class-gated for the same reason: nothing else in our captures sends
        // 0x4B, and a wrong SOC is worse than no SOC.
        if (!base.isPowerBank) return base;
        return base.copyWith(
          timestamp: ts,
          // b6, the same byte position 0x96 uses on a pack — read directly as
          // a percentage, no voltage->SOC curve.
          socPercent: socPercent(f),
          designCapacityMah: f.u16(4),
        );
      case Selectors.capacity:
        return base.copyWith(
          timestamp: ts,
          capacityRaw: capacityRaw(f),
          sohBucket: sohBucket(f),
          socPercent: socPercent(f),
        );
      case Selectors.deviceType:
        return base.copyWith(timestamp: ts, deviceType: f.b(4));
      case Selectors.serialB:
        return base.copyWith(timestamp: ts, serial: serial(f));
      case Selectors.year:
        // 0x25 is 年份 (year), NOT the serial high-word — observed
        // §10.2. Byte layout not yet captured, so decode is deferred rather
        // than mis-folding it into `serial` (which corrupted the serial).
        return base;
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
