/// OpenSmartBatt — the simulated unit behind a demo link (design 0097 §3.3).
///
/// PURE Dart (no Flutter imports).
///
/// It answers what the app WRITES with frames in the real wire format, built
/// by the same [buildFrame] the command path uses, so everything above the
/// transport — reassembler, decoder, class routing, controllers — runs the
/// code a real unit runs (design 0097 §1, option A).
///
/// Three rules this file is held to:
///
///   * **Synthetic only.** Every number comes from [readingAt]; nothing is
///     taken from a field capture. Those are other people's units.
///   * **No credential.** An auth frame is accepted whatever it carries and is
///     never compared with anything (design 0097 §3.4) — this file must not
///     become a second place that records a real one.
///   * **Deterministic.** [readingAt] is a pure function of the clock, so a
///     test can assert a value and a store screenshot can be retaken.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../protocol/protocol.dart';
import 'demo_device.dart';

/// One instant of a demo unit's telemetry, in display units.
class DemoReading {
  const DemoReading({
    required this.pvlt,
    required this.temperatureC,
    required this.currentA,
    this.svlt,
    this.cellsV,
  });

  /// Main (terminal) voltage, V.
  final double pvlt;

  /// Secondary voltage, V — capacitor only.
  final double? svlt;

  final int temperatureC;

  /// Signed, whole amps: positive = charge, negative = discharge, the `0x2E`
  /// convention (PROTOCOL.md §8.2). `0x2E` has 1 A resolution.
  final int currentA;

  /// Four cell voltages, V — battery only.
  final List<double>? cellsV;
}

/// The simulated unit for one demo link.
class DemoPeripheral {
  DemoPeripheral(this.kind, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DemoKind kind;
  final DateTime Function() _clock;

  /// The `0x2B` bytes `[ov, uv, ot, ut]`. Writable, and held only here: a demo
  /// session's settings vanish with it (design 0097 Q3).
  List<int> _thresholds = List<int>.unmodifiable(_defaultThresholds);

  /// OV 15.0 V, UV 10.8 V, OT 75 °C — the `0x2B` scaling in PROTOCOL.md §8.2.
  static const List<int> _defaultThresholds = [24, 16, 15, 0];

  /// Battery: the [ReportedStatus] byte. Starts normal.
  int _batteryStatus = ReportedStatus.normal;

  /// Capacitor: when a self-check was requested, or null.
  DateTime? _selfCheckAt;

  /// How long the self-check read-back holds each value. Real units hold
  /// `0x06` four to five seconds (see [CapacitorStatus]); unlike a real unit,
  /// the demo always returns to [CapacitorStatus.healthy] — it must not leave
  /// a reviewer staring at a check that never ends.
  static const Duration selfCheckStarting = Duration(seconds: 5);
  static const Duration selfCheckRunning = Duration(seconds: 10);

  /// VADJ 20.00, inside the measured 20.00–20.36 spread (PROTOCOL.md §8.2.1).
  static const int _vadjRaw = 2000;

  /// The cycle every demo trace repeats: rest, then a charge stretch, so the
  /// history and live charts have something to show.
  static const int cycleSeconds = 600;
  static const int chargeFromSecond = 480;

  /// The reading [kind] shows at [at]. Pure.
  static DemoReading readingAt(DemoKind kind, DateTime at) {
    final t = at.millisecondsSinceEpoch ~/ 1000;
    final phase = t % cycleSeconds;
    final charging = phase >= chargeFromSecond;
    // 0 → 1 across the charge stretch, so the voltage climbs instead of jumping.
    final ramp = charging
        ? (phase - chargeFromSecond) / (cycleSeconds - chargeFromSecond)
        : 0.0;
    final wave = math.sin(2 * math.pi * (t % 300) / 300);
    switch (kind) {
      case DemoKind.battery:
        final pvlt = charging
            ? 13.60 + 0.55 * ramp + 0.01 * _noise(t, 1)
            : 13.18 + 0.03 * wave + 0.01 * _noise(t, 1);
        const offsets = [0.004, -0.003, 0.001, -0.002];
        return DemoReading(
          pvlt: _round2(pvlt),
          temperatureC: 26 + (charging ? 1 : 0),
          currentA: charging ? (12 - (6 * ramp).round()) : 0,
          cellsV: [
            for (final o in offsets) _round3(pvlt / 4 + o + 0.001 * _noise(t, 2)),
          ],
        );
      case DemoKind.capacitor:
        final pvlt = charging
            ? 14.05 + 0.25 * ramp + 0.01 * _noise(t, 3)
            : 13.62 + 0.05 * wave + 0.01 * _noise(t, 3);
        return DemoReading(
          pvlt: _round2(pvlt),
          svlt: _round2(12.64 + 0.02 * wave + 0.01 * _noise(t, 4)),
          temperatureC: 31,
          // A capacitor streams 0x2E as a constant 0.0 A (product_class.dart).
          currentA: 0,
        );
    }
  }

  /// The frames this unit sends back after the app writes [written].
  List<Uint8List> answer(List<int> written) {
    if (written.isEmpty) return const [];
    if (written.first == kSyncByte) return _answerCommands(written);
    if (_isToken(written, kExtendedPollBytes)) {
      return [..._telemetryFrames(), ..._identityFrames()];
    }
    if (_isToken(written, const [kKeepAliveByte]) ||
        _isToken(written, const [kMetadataPollByte])) {
      return _telemetryFrames();
    }
    return const [];
  }

  List<Uint8List> _answerCommands(List<int> written) {
    final out = <Uint8List>[];
    for (final f in FrameReassembler().addBytes(written)) {
      if (!f.checksumOk) continue;
      final isReadBack = f.flag == 0x01 && f.len == 0;
      switch (f.selector) {
        case Commands.modeSet:
          if (!isReadBack && f.len >= 1) _applyMode(f.payload.first);
          out.add(_modeFrame());
        case Commands.thresholds:
          if (!isReadBack && f.len >= 4) {
            _thresholds = List<int>.unmodifiable(f.payload.sublist(0, 4));
          }
          out.add(_thresholdsFrame());
        case Commands.auth:
          // Accepted, never inspected (see the library doc).
          break;
        default:
          break;
      }
    }
    return out;
  }

  void _applyMode(int arg) {
    switch (kind) {
      case DemoKind.battery:
        if (arg == ModeArg.unlock) _batteryStatus = ReportedStatus.normal;
        if (arg == ModeArg.antiTheft) {
          _batteryStatus = ReportedStatus.antiTheftActive;
        }
        if (arg == ModeArg.cutOff) _batteryStatus = ReportedStatus.cutOffActive;
      case DemoKind.capacitor:
        // A capacitor has no cut-off or anti-theft (see [CapacitorStatus]).
        if (arg == ModeArg.capacitorSelfCheck) _selfCheckAt = _clock();
    }
  }

  /// The `0x23` byte right now.
  int get statusByte {
    switch (kind) {
      case DemoKind.battery:
        return _batteryStatus;
      case DemoKind.capacitor:
        final at = _selfCheckAt;
        if (at == null) return CapacitorStatus.healthy;
        final dt = _clock().difference(at);
        if (dt < selfCheckStarting) return CapacitorStatus.selfCheckStarting;
        if (dt < selfCheckStarting + selfCheckRunning) {
          return CapacitorStatus.selfCheckRunning;
        }
        _selfCheckAt = null;
        return CapacitorStatus.healthy;
    }
  }

  List<Uint8List> _telemetryFrames() {
    final r = readingAt(kind, _clock());
    return [
      buildFrame(Selectors.deviceType, [kind.deviceType]),
      buildFrame(Selectors.pvlt, _u16(r.pvlt * 100)),
      buildFrame(Selectors.temperature, [r.temperatureC & 0xFF]),
      _modeFrame(),
      buildFrame(Selectors.current, _u16(512 - r.currentA)),
      _thresholdsFrame(),
      if (r.svlt != null) buildFrame(Selectors.svlt, _u16(r.svlt! * 100)),
      if (r.cellsV != null) ...[
        buildFrame(Selectors.vadj, _u16(_vadjRaw)),
        buildFrame(Selectors.dvol, [
          for (final v in r.cellsV!) (v * 1000 / (_vadjRaw / 100)).round() & 0xFF,
        ]),
      ],
    ];
  }

  List<Uint8List> _identityFrames() {
    final r = readingAt(kind, _clock());
    return [
      // Serial 000001 and dealer 00000000: plainly not a real unit's.
      buildFrame(Selectors.serialB, const [0, 0, 0, 0, 0, 1]),
      buildFrame(Selectors.dealerCode, const [0, 0, 0, 0]),
      if (r.cellsV != null)
        buildFrame(Selectors.cellVoltagesMv, [
          for (final v in r.cellsV!) ..._u16(v * 1000),
        ]),
    ];
  }

  Uint8List _modeFrame() => buildFrame(Selectors.mode, [statusByte]);

  Uint8List _thresholdsFrame() => buildFrame(Selectors.thresholds, _thresholds);

  static bool _isToken(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<int> _u16(num v) {
    final n = v.round().clamp(0, 0xFFFF);
    return [(n >> 8) & 0xFF, n & 0xFF];
  }

  /// A deterministic value in [-1, 1] for second [t] on [channel].
  static double _noise(int t, int channel) {
    var h = (t * 374761393 + channel * 668265263) & 0x7FFFFFFF;
    h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF;
    return (h % 2001) / 1000.0 - 1.0;
  }

  static double _round2(double v) => (v * 100).round() / 100;
  static double _round3(double v) => (v * 1000).round() / 1000;
}
