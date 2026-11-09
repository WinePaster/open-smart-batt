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

  /// The `0x2B` bytes `[ov, uv, ot, ut]` this unit streams — the most common
  /// real payload of each class (`18401414` battery, `102c2814` capacitor).
  /// 🔵 2026-11-09 (design 0098): read-only, as on real hardware from this app's
  /// side — the app no longer writes `0x2B` and nothing on screen reads it. It
  /// is still streamed so a demo log looks like a real one.
  List<int> get _thresholds => kind == DemoKind.capacitor
      ? const [0x10, 0x2C, 0x28, 0x14]
      : const [0x18, 0x40, 0x14, 0x14];

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

  /// The two drives of a demo day, as local minute-of-day `[start, end)`: the
  /// unit charges while the engine runs and rests in between, which is the
  /// shape a real car's day has (one charge stretch every few minutes, the
  /// first version, drew 24 hours of history as solid spikes).
  static const List<(int, int)> drives = [
    (7 * 60 + 30, 8 * 60 + 15),
    (17 * 60 + 40, 18 * 60 + 35),
  ];

  /// Minutes since the end of the last drive, or null while driving; and the
  /// 0 → 1 progress through the current drive.
  static ({bool driving, double progress, int restMin}) _phase(DateTime at) {
    final local = at.toLocal();
    final m = local.hour * 60 + local.minute;
    for (final (s, e) in drives) {
      if (m >= s && m < e) {
        final sec = (m - s) * 60 + local.second;
        return (driving: true, progress: sec / ((e - s) * 60), restMin: 0);
      }
    }
    var rest = 24 * 60;
    for (final (_, e) in drives) {
      final since = (m - e) % (24 * 60);
      if (since < rest) rest = since;
    }
    return (driving: false, progress: 0, restMin: rest);
  }

  /// The reading [kind] shows at [at]. Pure.
  static DemoReading readingAt(DemoKind kind, DateTime at) {
    final t = at.millisecondsSinceEpoch ~/ 1000;
    final p = _phase(at);
    // A slow ripple, so a live chart watched for a minute is not a ruler.
    final wave = math.sin(2 * math.pi * (t % 300) / 300);
    // Resting voltage settles over the hours after a drive.
    final settle = math.min(p.restMin, 600) / 600;
    switch (kind) {
      case DemoKind.battery:
        final pvlt = p.driving
            ? 13.95 + 0.25 * p.progress + 0.01 * _noise(t, 1)
            : 13.32 - 0.14 * settle + 0.015 * wave + 0.01 * _noise(t, 1);
        const offsets = [0.004, -0.003, 0.001, -0.002];
        return DemoReading(
          pvlt: _round2(pvlt),
          temperatureC: p.driving ? 29 : 25 + (settle < 0.3 ? 2 : 0),
          // Charge current tapers as the battery fills.
          currentA: p.driving ? (14 - (10 * p.progress).round()) : 0,
          cellsV: [
            for (final o in offsets) _round3(pvlt / 4 + o + 0.001 * _noise(t, 2)),
          ],
        );
      case DemoKind.capacitor:
        final pvlt = p.driving
            ? 14.20 + 0.10 * p.progress + 0.01 * _noise(t, 3)
            : 13.70 - 0.12 * settle + 0.02 * wave + 0.01 * _noise(t, 3);
        return DemoReading(
          pvlt: _round2(pvlt),
          svlt: _round2((p.driving ? 14.05 : 12.70 - 0.06 * settle) +
              0.01 * wave + 0.01 * _noise(t, 4)),
          temperatureC: p.driving ? 34 : 30,
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
