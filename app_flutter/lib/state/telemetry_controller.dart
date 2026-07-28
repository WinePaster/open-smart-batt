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
import 'session_context.dart';
import 'settings_controller.dart';

/// Latest telemetry + derived values for the dashboard, plus history/log I/O.
class TelemetryController extends ChangeNotifier {
  TelemetryController(
    this._ble, {
    required SettingsController settings,
    required HistoryRepo history,
    required LogRepo logs,
    SessionContext? session,
    Duration? stallThreshold,
    Duration? stallCheckInterval,
    String? appBuild,
  }) {
    _settings = settings;
    _history = history;
    _logs = logs;
    _session = session ?? SessionContext();
    _appBuild = appBuild;
    _stallThreshold = stallThreshold ?? BleService.telemetryStallThreshold;
    _stallCheckInterval = stallCheckInterval ?? const Duration(seconds: 2);
    _sample = TelemetrySample.empty();
    _telemetrySub = _ble.telemetry.listen(_onTelemetry);
    _packetSub = _ble.packets.listen(_onPacket);
    _linkSub = _ble.linkState.listen(_onLinkState);
  }

  final BleService _ble;

  /// Build that is recording, stamped on every row (design 0010). Null in
  /// tests and on hosts where the plugin channel is unavailable.
  String? _appBuild;

  late final SettingsController _settings;
  late final HistoryRepo _history;
  late final LogRepo _logs;

  /// Which unit/connection recorded rows belong to (design 0006). Shared with
  /// [ConnectionController]; see [SessionContext].
  late final SessionContext _session;

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

  // NOTE: product class + capabilities are intentionally NOT exposed here.
  // Design 0001 §3.1 mandates a single source of truth for "which class is
  // this unit"; that lives on [ConnectionController] (the pack-class resolver),
  // which drives routing, persistence AND capability gating. Deriving the class
  // a second time from this controller's raw sample would let the two disagree.

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

  /// True when DVOL frames are arriving but VADJ (scaling) is not yet known, so
  /// per-cell voltages are shown as pending rather than a bogus value.
  bool get dvolPending => _sample.dvolPending;

  /// Capacity / SOH bucket (icon level; semantics heuristic).
  int? get sohBucket => _sample.sohBucket;

  /// Device-reported state-of-charge percent (0..100), selector 0x96 b6.
  int? get socPercent => _sample.socPercent;

  /// Reported mode/status code (selector 0x23).
  int? get mode => _sample.mode;

  /// Raw TWF status bitfield (selector 0x20).
  int? get twfRaw => _sample.twfRaw;

  /// Battery serial (selector 0x26, tail only).
  String? get serial => _sample.serial;

  /// Full product serial = dealer code (0x27) + product serial (0x26); null
  /// until both arrive (connect burst). See [TelemetrySample.fullSerial].
  String? get fullSerial => _sample.fullSerial;
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

  /// Unit currently being recorded (null when disconnected) — the default
  /// scope for a "this device only" export.
  String? get recordingDeviceId => _session.deviceId;

  /// Current connection counter (null when disconnected).
  int? get recordingSessionId => _session.sessionId;

  /// Telemetry history, newest-first. [deviceId] scopes to one unit; null means
  /// every unit (including rows recorded before device attribution existed).
  Future<List<TelemetrySample>> history({
    DateTime? since,
    int? limit,
    String? deviceId,
  }) =>
      _history.querySamples(since: since, limit: limit, deviceId: deviceId);

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
  ///
  /// [labelFor] renders the human-readable `device` column; the caller supplies
  /// it because the alias/serial lookup lives in the device layer. [header]
  /// carries the provenance preamble (design 0009); see [HistoryRepo.exportCsv]
  /// for why the returned row count — not the text — decides "nothing to
  /// export".
  Future<({String text, int rows})> exportHistoryCsv({
    DateTime? since,
    int? limit,
    String? deviceId,
    String Function(String? deviceId)? labelFor,
    ProductClass Function(String? deviceId)? classFor,
    List<String> header = const [],
  }) =>
      _history.exportCsv(
        since: since,
        limit: limit,
        deviceId: deviceId,
        labelFor: labelFor,
        classFor: classFor,
        header: header,
      );

  /// Clear all history.
  Future<void> clearHistory() => _history.clearHistory();

  /// Diagnostic log entries, newest-first.
  Future<List<LogEntry>> logEntries({int? limit, String? deviceId}) =>
      _logs.queryLog(limit: limit, deviceId: deviceId);

  /// Diagnostic log as a `.log` text blob, optionally scoped to one unit and/or
  /// one connection, with an optional `#`-prefixed header (design 0006 §3.6).
  Future<String> exportLog({
    String? deviceId,
    int? sessionId,
    List<String> header = const [],
    String Function(String? deviceId)? labelFor,
  }) =>
      _logs.exportLog(
        deviceId: deviceId,
        sessionId: sessionId,
        header: header,
        labelFor: labelFor,
      );

  /// How many distinct connections the log holds for a scope (header line).
  Future<int> logSessionCount({String? deviceId}) =>
      _logs.sessionCount(deviceId: deviceId);

  /// Approximate diagnostic-log size (bytes).
  Future<int> logApproxBytes() => _logs.approxBytes();

  /// Clear the diagnostic log.
  Future<void> clearLog() => _logs.clearLog();

  // ---- stream handlers --------------------------------------------------

  // ---- stall detection ---------------------------------------------------
  // A stall is NOT a disconnect: on Android the link stays ready while the OS
  // suspends the app, so RX and TX both stop for minutes and then flush a
  // backlog (evidenced twice in feedback_log/2026.07.27). During that window
  // the dashboard kept showing the last values with no hint they were frozen.

  DateTime? _lastSampleAt;
  Timer? _stallTimer;
  bool _stalled = false;

  /// Injectable so tests can exercise the real transition in milliseconds
  /// instead of waiting out the field threshold.
  late final Duration _stallThreshold;
  late final Duration _stallCheckInterval;

  /// True when the link reports ready but no telemetry has arrived for
  /// [BleService.telemetryStallThreshold] — the readouts on screen are stale.
  bool get telemetryStalled => _stalled;

  /// Age of the newest telemetry, or null before the first frame.
  Duration? get telemetryAge {
    final at = _lastSampleAt;
    return at == null ? null : DateTime.now().difference(at);
  }

  void _evaluateStall() {
    final age = telemetryAge;
    final next = age != null && age > _stallThreshold;
    if (next == _stalled) return;
    _stalled = next;
    notifyListeners();
  }

  void _onTelemetry(TelemetrySample s) {
    _sample = s;
    _lastSampleAt = DateTime.now();
    if (_stalled) {
      _stalled = false; // recovered
    }
    notifyListeners();
    _maybeAutoLog(s);
  }

  // ---- per-minute aggregation -------------------------------------------
  // History stores ONE averaged row per minute (not every poll): accumulate
  // each minute's samples, then flush the average on minute-rollover/disconnect.
  DateTime? _bucketMinute;
  TelemetrySample? _bucketLast;

  /// Unit that owns the minute currently being accumulated. Captured when the
  /// bucket opens, NOT when it flushes: a flush triggered by a disconnect (or
  /// after the next unit connects) would otherwise file the minute under the
  /// wrong device — or under none at all.
  String? _bucketDeviceId;
  double _sPvlt = 0, _sSvlt = 0, _sTemp = 0, _sCur = 0;
  int _nPvlt = 0, _nSvlt = 0, _nTemp = 0, _nCur = 0;

  /// How many telemetry snapshots this minute has folded in (design 0009).
  /// Counted per snapshot, not per field, so it answers one question honestly:
  /// how much data is behind this row. A full minute lands near 900; a row
  /// flushed seconds after the bucket opened lands in the tens, and the export
  /// makes that visible instead of passing both off as "one minute".
  int _nSamples = 0;

  void _maybeAutoLog(TelemetrySample s) {
    if (!_settings.autoLog) return;
    final t = s.timestamp;
    final minute = DateTime(t.year, t.month, t.day, t.hour, t.minute);
    // A new unit mid-minute also closes the bucket, so one row never mixes two
    // devices' readings.
    final deviceId = _session.deviceId;
    if (_bucketMinute != null &&
        (minute.isAfter(_bucketMinute!) || deviceId != _bucketDeviceId)) {
      _flushBucket();
    }
    _bucketMinute = minute;
    _bucketDeviceId = deviceId;
    _bucketLast = s;
    _nSamples++;
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

  /// Persist the minute currently being accumulated, if any.
  ///
  /// Called when the app may be about to lose control of its own execution —
  /// backgrounded, hidden, or being torn down (design 0009 §3.2). A minute
  /// rollover and a disconnect are the *orderly* ways a bucket closes; a
  /// silent suspension is not, and until this existed the partial minute was
  /// simply lost. A 2026-07-28 field capture ended that way: the diagnostic log
  /// held 37 more seconds of packets than the CSV did, with no disconnect event
  /// to explain the gap.
  ///
  /// Flushing resets the bucket, so pausing and resuming inside one minute
  /// yields TWO rows for that minute. That is deliberate: each row reports its
  /// own [_nSamples], which is more honest than silently merging them or
  /// rewriting a row already on disk.
  void flushPendingHistory() => _flushBucket();

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
      unawaited(_history.insertSample(
        avg,
        deviceId: _bucketDeviceId,
        samples: _nSamples,
        appBuild: _appBuild,
      ));
    }
    _bucketMinute = null;
    _bucketDeviceId = null;
    _bucketLast = null;
    _sPvlt = _sSvlt = _sTemp = _sCur = 0;
    _nPvlt = _nSvlt = _nTemp = _nCur = 0;
    _nSamples = 0;
  }

  void _onPacket(BlePacketEvent e) {
    if (!_settings.rawPacketLog) return;
    final entry = LogEntry.fromBytes(
      e.direction,
      e.bytes,
      at: e.at,
      note: e.note,
      deviceId: _session.deviceId,
      sessionId: _session.sessionId,
      appBuild: _appBuild,
    );
    unawaited(_logs.insertLog(entry, maxBytes: _settings.logMaxBytes));
  }

  void _onLinkState(BleLinkState s) {
    if (s == BleLinkState.ready) {
      _lastSampleAt = DateTime.now(); // grace period before the first frame
      _stallTimer?.cancel();
      _stallTimer = Timer.periodic(_stallCheckInterval, (_) => _evaluateStall());
    }
    if (s == BleLinkState.disconnected) {
      _stallTimer?.cancel();
      _stallTimer = null;
      _lastSampleAt = null;
      _stalled = false;
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
    _stallTimer?.cancel();
    _telemetrySub?.cancel();
    _packetSub?.cancel();
    _linkSub?.cancel();
    super.dispose();
  }
}
