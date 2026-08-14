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

  /// ## Not-ready frames (2026-08-05)
  ///
  /// A power bank that reboots mid-session sends one telemetry group whose
  /// values are not yet populated — `0x19 = 0000`, `0x37 = 0000`, `0x21`
  /// temperature `= 00` — while the frame itself is perfectly well formed
  /// (`0x21`'s trailing byte still reads its usual `0xe2`, and the XOR checks
  /// out). **The frame is legal; the values are not ready.** 180 ms later the
  /// same registers read normally. Observed three times in one capture, each
  /// alongside two other independent reboot fingerprints (`0x3B` rewinding to
  /// a checkpoint, `0x34`'s last byte incrementing).
  ///
  /// Published as-is it renders "0.00 V / 0.00 V / 0 °C" on the dashboard: a
  /// plausible-looking wrong reading, which this project treats as strictly
  /// worse than a blank — the same rule that gates `0x4A` on the device class
  /// below.
  ///
  /// The guard is a PHYSICAL argument, not a statistical one: a device whose
  /// primary cell reads 0 V cannot be powering the radio that just delivered
  /// the frame. That is why `pvlt == 0` is dropped for every class, while
  /// `svlt == 0` is dropped only on a power bank.
  ///
  /// ⚠️ Not a protocol claim, so not subject to the corpus's multi-unit bar:
  /// it asserts nothing new about the wire, it only declines to render a frame
  /// the device has not finished filling in. Same character as the same-burst
  /// corroboration in `power_path_row.dart`.

  /// SOC percent — selector 0x96: b6 read DIRECTLY as a 0..100 percentage
  /// (PROTOCOL.md §9.1). The device reports SOC straight; there is no
  /// voltage->SOC curve. Clamped to 0..100. Distinct from [sohBucket].
  static int socPercent(InboundFrame f) {
    final v = f.b(6);
    if (v < 0) return 0;
    if (v > 100) return 100;
    return v;
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

  /// Device BLE address — selector 0x38: the payload is **ASCII text** (not
  /// packed bytes — PROTOCOL.md §8.2.3), e.g. the 17 bytes `41 41 3a … 46 46`
  /// spell `"AA:BB:CC:DD:EE:FF"`. Normalised to an upper-case, colon-separated
  /// MAC. Returns null when the payload does not yield 12 hex nibbles, so a
  /// truncated or malformed frame never fabricates an address.
  static String? mac(InboundFrame f) {
    final sb = StringBuffer();
    for (final byte in f.payload) {
      // Keep only printable ASCII; the field is text, and stray control bytes
      // (or a padded tail) must not leak into the identity.
      if (byte >= 0x20 && byte < 0x7F) sb.writeCharCode(byte);
    }
    final hex = RegExp(r'[0-9A-Fa-f]')
        .allMatches(sb.toString())
        .map((m) => m[0]!)
        .join()
        .toUpperCase();
    if (hex.length != 12) return null;
    return [for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2)].join(':');
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
        // NOT-READY frame, not a reading — see the note above [socPercent].
        if (v == 0) return base;
        return base.copyWith(
            timestamp: ts, pvlt: v, pvltGaugeIndex: pvltGaugeIndex(v));
      case Selectors.svlt:
        final sv = svlt(f);
        // Same guard, power banks only: a capacitor's SECONDARY voltage does
        // legitimately reach 0 V when it is discharged, so this one cannot be
        // class-blind the way pvlt can.
        if (sv == 0 && base.isPowerBank) return base;
        return base.copyWith(timestamp: ts, svlt: sv);
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
      // Selectors.charge (0x41) is deliberately NOT decoded, and falls through
      // to `default`. It used to publish chargeV1/chargeV2 by reading b4..b5 and
      // b6..b7 as two millivolt words — the §8.2 pair formula. The v2 half is
      // now positively refuted rather than merely unverified: on device-type
      // 0x17 the last payload byte mirrors the 0x21 temperature in °C (seven
      // units, 85.9-99.4% against the nearest-in-time 0x21, every miss off by
      // exactly one degree), and a byte carrying degrees cannot be half of a
      // millivolt word. Every rate in that range is a per-capture slice, not a
      // unit's lifetime rate: the 100% upper bound this comment used to quote
      // was one capture's subset of one unit, whose longer capture reads 97.9%
      // (corrected 2026-08-14 alongside the public docs).
      // On 0x18 units it is 0% and constant while 0x21 moves,
      // so that generation uses a different layout again. See PROTOCOL.md §10.1.
      //
      // Nothing read chargeV1/chargeV2 — no UI, and the CSV/DB `toMap` is a
      // whitelist that never included them — so this removes a wrong number
      // before something started reading it, not after. The fields are gone
      // from TelemetrySample for the same reason: a permanently-null field is
      // an invitation to wire it up.
      case Selectors.chargeCurrent:
        // Power banks only, and class-gated for the same reason as
        // Selectors.discharge below: on a pack these four bytes are not this.
        if (!base.isPowerBank) return base;
        // Stored, not published. 0x49 arrives BEFORE 0x4A in every burst, so
        // signing here and letting 0x4A overwrite would put the charge current
        // on screen for a millisecond and then replace it with 0x4A's idle
        // zero. The combination happens in 0x4A, which is the register that has
        // always driven `current`.
        //
        // u16(4), this register's mV field, is the PORT voltage — identified
        // 2026-08-05 on five units — and is deliberately NOT read. Doing so
        // would be a display change (it is same-burst with 0x4B where 0x37 free
        // -runs), and that needs a ruling; see [Selectors.chargeCurrent].
        return base.copyWith(timestamp: ts, chargeCurrent: f.u16(6) / 1000.0);
      case Selectors.discharge:
        // Same 4 bytes, two readings — this selector means different things on
        // different product classes. Gating on the class is safe because the
        // class itself is deterministic (the 0x10 device-type byte), and 0x10
        // arrives EARLIER in the same burst than 0x4A, so the gate is settled
        // by the time we get here.
        //
        // But "earlier in the burst" is an observation, not a guarantee: a
        // truncated connect burst leaves the class unresolved, and eight such
        // segments exist in the field corpus. With no 0x10 the pack branch
        // below would run on a power bank and read 3955 mV / 1081 mA as
        // "3.955 / 1.081" — two numbers that look entirely reasonable. That is
        // the FB-22 failure mode exactly: a class-agnostic formula on an
        // unattributed frame. The rule is that BOTH 0x4A and 0x4B no-op while
        // the class is unknown — blank beats a plausible wrong number; 0x4B
        // already did and this one did not.
        if (base.deviceType == null) return base;
        if (base.isPowerBank) {
          // `[u16 mV][u16 mA]`. Only the current is taken: the mV field is the
          // CELL voltage and tracks PVLT (0x19) — five physical units, median
          // +4 mV, 96–100 % of samples within ±30 mV, against a deliberately
          // mis-paired control at +1,634 mV (2026-08-05) — so decoding it again
          // would just be a second name for the same number.
          //
          // ⚠️ 0x49's mV field is NOT the same quantity: it is the PORT voltage
          // (0x37). See [Selectors.chargeCurrent], which also records why we do
          // not read it yet.
          //
          // SIGNED, from both registers: this one is the discharging direction
          // and 0x49 the charging one, and they are complementary — whichever
          // is carrying the reading is the direction (see
          // [Selectors.chargeCurrent] for the counts). Both idle gives 0.0 A,
          // which is what an idle bank is. Publishing a magnitude, as this line
          // used to, made a bank that was charging read 0.00 A forever, because
          // the only register the app looked at is the one that goes quiet
          // while charging.
          final discharging = f.u16(6) / 1000.0;
          return base.copyWith(
            timestamp: ts,
            current: discharging - (base.chargeCurrent ?? 0),
          );
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
          // b7: the port / protocol flag byte (design 0035 §3.2). Stored raw;
          // TelemetrySample derives usbPort (bit1) / isOutputActive (bit2) /
          // isPdIn (bit3) / isPdOut (bit5) / isRailOff (== 0x00). bit0 and bit4
          // are decoded to NOTHING. No view reads these yet — Phase 0 changes
          // no pixels — so this only widens what a field capture can be read for.
          portFlagsRaw: f.b(7),
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
      case Selectors.bleAddress:
        // The device's own MAC, as ASCII (§8.2.3). A malformed payload decodes
        // to null and is dropped rather than overwriting a good address with a
        // fabricated one (design 0027 §3.2.1). Not gated on rawPacketLog.
        final m = mac(f);
        return m == null ? base : base.copyWith(timestamp: ts, mac: m);
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
