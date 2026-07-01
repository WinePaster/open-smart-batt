/// OpenSmartBatt — telemetry controller (mockup dashboard + history).
///
/// Subscribes to [BleService]'s decoded telemetry stream, exposes the latest
/// [TelemetrySample] plus derived gauge/readout values, drives history
/// auto-logging (gated by `AppSettings.autoLog`, throttled to the poll
/// interval) and the optional raw-packet diagnostics log (gated by
/// `AppSettings.rawPacketLog`, DEFAULT OFF, byte-budget-capped).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble.dart';
import '../data/data.dart';
import '../models/models.dart';
import 'settings_controller.dart';

/// Latest telemetry + derived values for the dashboard, plus history/log I/O.
class TelemetryController extends ChangeNotifier {
  TelemetryController(
    this._ble, {
    required SettingsController settings,
    required HistoryRepo history,
    required LogRepo logs,
  }) {
    _settings = settings;
    _history = history;
    _logs = logs;
    _sample = TelemetrySample.empty();
    _telemetrySub = _ble.telemetry.listen(_onTelemetry);
    _packetSub = _ble.packets.listen(_onPacket);
    _linkSub = _ble.linkState.listen(_onLinkState);
  }

  final BleService _ble;
  late final SettingsController _settings;
  late final HistoryRepo _history;
  late final LogRepo _logs;

  StreamSubscription<TelemetrySample>? _telemetrySub;
  StreamSubscription<BlePacketEvent>? _packetSub;
  StreamSubscription<BleLinkState>? _linkSub;

  late TelemetrySample _sample;

  // ---- raw sample + capability gating -----------------------------------

  /// Latest accumulated telemetry snapshot.
  TelemetrySample get sample => _sample;

  /// True once any meaningful register has been decoded.
  bool get hasData =>
      _sample.pvlt != null ||
      _sample.svlt != null ||
      _sample.temperatureC != null ||
      _sample.current != null;

  /// Capabilities derived from the device-type register (heuristic; gates the
  /// dashboard controls 檢測電容 / 解除斷電 / 防盜).
  DeviceCapabilities get capabilities =>
      DeviceCapabilities.fromDeviceType(_sample.deviceType);

  // ---- derived gauge / readout values -----------------------------------

  /// Primary voltage PVLT (V).
  double? get pvlt => _sample.pvlt;

  /// Gauge fill fraction 0..1 over the 8–16 V display range.
  double get gaugeFraction => _sample.pvltGaugeFraction;

  /// Gauge tick index 0..28 (selector 0x19).
  int? get gaugeIndex => _sample.pvltGaugeIndex;

  /// Secondary voltage SVLT (V).
  double? get svlt => _sample.svlt;

  /// Main current (A).
  double? get current => _sample.current;

  /// Per-cell DVOL voltages (V), or null until decoded.
  List<double>? get dvol => _sample.dvol;

  /// Capacity / SOH bucket (semantics heuristic).
  int? get sohBucket => _sample.sohBucket;

  /// Reported mode/status code (selector 0x23).
  int? get mode => _sample.mode;

  /// Raw TWF status bitfield (selector 0x20).
  int? get twfRaw => _sample.twfRaw;

  /// Battery serial / dealer code (selectors 0x25-0x27).
  String? get serial => _sample.serial;
  String? get dealerCode => _sample.dealerCode;

  /// Warning thresholds (selector 0x2B), in physical units.
  double? get warnOv => _sample.warnOv;
  double? get warnUv => _sample.warnUv;
  double? get warnOt => _sample.warnOt;

  /// Raw temperature (°C).
  int? get temperatureC => _sample.temperatureC;

  /// Temperature converted to the user's chosen display unit.
  double? get temperatureDisplay {
    final c = _sample.temperatureC;
    if (c == null) return null;
    return _settings.tempUnit == TempUnit.fahrenheit ? c * 9 / 5 + 32 : c.toDouble();
  }

  /// Display suffix for temperature (°C / °F).
  String get temperatureUnitLabel =>
      _settings.tempUnit == TempUnit.fahrenheit ? '°F' : '°C';

  // ---- history / log I/O (History + Settings screens) -------------------

  /// Telemetry history, newest-first.
  Future<List<TelemetrySample>> history({DateTime? since, int? limit}) =>
      _history.querySamples(since: since, limit: limit);

  /// Stored sample count.
  Future<int> historyCount() => _history.count();

  /// Bucketed trend for the chart (DB-side aggregation).
  Future<List<HistoryBucket>> historyBuckets(
          {DateTime? since, required int bucketMs}) =>
      _history.queryBuckets(since: since, bucketMs: bucketMs);

  /// Range-wide min/max/avg stats over raw rows.
  Future<HistoryStats> historyStats({DateTime? since}) =>
      _history.aggregate(since: since);

  /// CSV export of matching history rows (for share_plus / file write).
  Future<String> exportHistoryCsv({DateTime? since, int? limit}) =>
      _history.exportCsv(since: since, limit: limit);

  /// Clear all history.
  Future<void> clearHistory() => _history.clearHistory();

  /// Diagnostic log entries, newest-first.
  Future<List<LogEntry>> logEntries({int? limit}) => _logs.queryLog(limit: limit);

  /// Whole diagnostic log as a `.log` text blob.
  Future<String> exportLog() => _logs.exportLog();

  /// Approximate diagnostic-log size (bytes).
  Future<int> logApproxBytes() => _logs.approxBytes();

  /// Clear the diagnostic log.
  Future<void> clearLog() => _logs.clearLog();

  // ---- stream handlers --------------------------------------------------

  void _onTelemetry(TelemetrySample s) {
    _sample = s;
    notifyListeners();
    _maybeAutoLog(s);
  }

  // ---- per-minute aggregation -------------------------------------------
  // History stores ONE averaged row per minute (not every poll): accumulate
  // each minute's samples, then flush the average on minute-rollover/disconnect.
  DateTime? _bucketMinute;
  TelemetrySample? _bucketLast;
  double _sPvlt = 0, _sSvlt = 0, _sTemp = 0, _sCur = 0;
  int _nPvlt = 0, _nSvlt = 0, _nTemp = 0, _nCur = 0;

  void _maybeAutoLog(TelemetrySample s) {
    if (!_settings.autoLog) return;
    final t = s.timestamp;
    final minute = DateTime(t.year, t.month, t.day, t.hour, t.minute);
    if (_bucketMinute != null && minute.isAfter(_bucketMinute!)) {
      _flushBucket();
    }
    _bucketMinute = minute;
    _bucketLast = s;
    if (s.pvlt != null) {
      _sPvlt += s.pvlt!;
      _nPvlt++;
    }
    if (s.svlt != null) {
      _sSvlt += s.svlt!;
      _nSvlt++;
    }
    if (s.temperatureC != null) {
      _sTemp += s.temperatureC!;
      _nTemp++;
    }
    if (s.current != null) {
      _sCur += s.current!;
      _nCur++;
    }
  }

  /// Write the current minute's averaged sample to history, then reset.
  void _flushBucket() {
    final m = _bucketMinute;
    final last = _bucketLast;
    if (m != null && last != null) {
      final avg = last.copyWith(
        timestamp: m,
        pvlt: _nPvlt > 0 ? _sPvlt / _nPvlt : null,
        svlt: _nSvlt > 0 ? _sSvlt / _nSvlt : null,
        temperatureC: _nTemp > 0 ? (_sTemp / _nTemp).round() : null,
        current: _nCur > 0 ? _sCur / _nCur : null,
      );
      unawaited(_history.insertSample(avg));
    }
    _bucketMinute = null;
    _bucketLast = null;
    _sPvlt = _sSvlt = _sTemp = _sCur = 0;
    _nPvlt = _nSvlt = _nTemp = _nCur = 0;
  }

  void _onPacket(BlePacketEvent e) {
    if (!_settings.rawPacketLog) return;
    final entry = LogEntry.fromBytes(e.direction, e.bytes, at: e.at);
    unawaited(_logs.insertLog(entry, maxBytes: _settings.logMaxBytes));
  }

  void _onLinkState(BleLinkState s) {
    if (s == BleLinkState.disconnected) {
      // Persist the final partial minute before clearing live state.
      _flushBucket();
      // Clear the live readouts so the dashboard doesn't show stale values.
      if (hasData) {
        _sample = TelemetrySample.empty();
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _telemetrySub?.cancel();
    _packetSub?.cancel();
    _linkSub?.cancel();
    super.dispose();
  }
}
