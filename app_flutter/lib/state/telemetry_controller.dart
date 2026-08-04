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
import 'live_trend_buffer.dart';
import 'session_context.dart';
import 'settings_controller.dart';
import 'telemetry_health.dart';

/// One minute of samples being accumulated for ONE unit.
///
/// Held per device rather than as a single set of fields, because the single
/// set degrades SILENTLY. The old code closed the bucket whenever the recording
/// unit changed mid-minute — correct with one link, and correct for the reason
/// stated there (a row must never mix two units' readings). But the moment
/// samples from two units interleave, "the unit changed" is true on nearly every
/// sample, so nearly every sample flushes its own row: one row per minute per
/// unit becomes one row per SAMPLE. The controller's own note on [_nSamples]
/// puts a full minute near 900, so that is roughly a 900× write amplification —
/// with no error, no exception and nothing on screen. The only thing that would
/// have said so is the `samples` column reading 1 on every row.
class _MinuteBucket {
  DateTime? minute;
  TelemetrySample? last;
  double sPvlt = 0, sSvlt = 0, sTemp = 0, sCur = 0;
  int nPvlt = 0, nSvlt = 0, nTemp = 0, nCur = 0;

  /// How many telemetry snapshots this minute has folded in.
  /// Counted per snapshot, not per field, so it answers one question honestly:
  /// how much data is behind this row. A full minute lands near 900; a row
  /// flushed seconds after the bucket opened lands in the tens, and the export
  /// makes that visible instead of passing both off as "one minute".
  int nSamples = 0;

  bool get isOpen => minute != null && last != null;
}

/// Telemetry freshness for ONE unit.
///
/// Per device because a stall is a statement about a specific link: with one
/// shared timestamp, any unit still sending would keep every other unit's
/// readouts looking live while they were frozen — which is precisely the
/// failure this detector was built to stop the dashboard doing.
class _StallWatch {
  DateTime? lastSampleAt;
  bool stalled = false;

  /// Frames actually decoded for this unit since its link came up.
  ///
  /// [lastSampleAt] cannot answer "has anything arrived?" — it is SEEDED at
  /// `ready` to give the first frame a grace period, so it is non-null from the
  /// moment a link opens whether or not the unit has said a word. That
  /// conflation is what let FB-20 be misread: a power bank whose writes take
  /// 4-5 s trips the write timeout while streaming 0x19/0x20/0x21/0x37 at
  /// 1.3-1.65 Hz, and nothing in the freshness state could tell that apart from
  /// a link that had gone silent.
  int samples = 0;
}

/// Latest telemetry + derived values for the dashboard, plus history/log I/O.
class TelemetryController extends ChangeNotifier implements TelemetryHealth {
  TelemetryController(
    this._ble, {
    required SettingsController settings,
    required HistoryRepo history,
    required LogRepo logs,
    SessionContext? session,
    Duration? stallThreshold,
    Duration? stallCheckInterval,
    String? appBuild,
    PendingWrites? pending,
  }) {
    _settings = settings;
    _history = history;
    _logs = logs;
    _pending = pending ?? PendingWrites();
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

  /// Build that is RECORDING, stamped on every row — not the build that later
  /// exports it. A log accumulates across app versions, so without this a
  /// missing register cannot be told apart from a bug in the build that
  /// recorded it. Null in tests and on hosts where the plugin channel is
  /// unavailable.
  String? _appBuild;

  late final SettingsController _settings;
  late final HistoryRepo _history;
  late final LogRepo _logs;

  /// In-flight history/log writes, so teardown can wait for them before the
  /// database closes. See [PendingWrites] for the race this closes.
  late final PendingWrites _pending;

  /// The tracker, so a composition root can drain it (see `AppServices`).
  PendingWrites get pendingWrites => _pending;

  /// Which unit/connection recorded rows belong to. Shared with
  /// [ConnectionController] rather than derived here, so the two writers of the
  /// same tables can never disagree about whose data a row is; see
  /// [SessionContext].
  late final SessionContext _session;

  StreamSubscription<TelemetrySample>? _telemetrySub;
  StreamSubscription<BlePacketEvent>? _packetSub;
  StreamSubscription<BleLinkState>? _linkSub;

  late TelemetrySample _sample;

  // ---- raw sample + capability gating -----------------------------------

  /// Latest accumulated telemetry snapshot.
  TelemetrySample get sample => _sample;

  /// Last few minutes of samples, for the dashboard's chart mode.
  ///
  /// Fed here rather than from its own stream subscription so it sees exactly
  /// what the readouts see — one source, one ordering. It is memory-only and is
  /// cleared whenever the link drops (see [_onLinkState]).
  LiveTrendBuffer get trend => _trend;
  final LiveTrendBuffer _trend = LiveTrendBuffer();

  /// True once any meaningful register has been decoded.
  bool get hasData =>
      _sample.pvlt != null ||
      _sample.svlt != null ||
      _sample.temperatureC != null ||
      _sample.current != null;

  // NOTE: product class + capabilities are intentionally NOT exposed here.
  // "Which class is this unit" has exactly one source of truth, and it lives on
  // [ConnectionController] (the pack-class resolver), which drives routing,
  // persistence AND capability gating together. Deriving the class a second
  // time from this controller's raw sample would let the two disagree — and the
  // visible result of that is a dashboard whose layout and whose controls
  // belong to different products.

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

  // ---- power-bank USB port / protocol (0x4B b7, design 0035) --------------
  // Decoded but not yet read by any view (Phase 0 changes no pixels). The
  // energy-path row (Phase 1+) consumes these; the §4.8 feedback hook records
  // [portFlagsRaw] alongside a user's port tag. bit0/bit4 never surface here.

  /// USB port from 0x4B b7 bit1 (Type-C cable/CC); never Type-A. Null until seen.
  UsbPort? get usbPort => _sample.usbPort;

  /// Boost rail off (b7 == 0x00). Null until b7 is seen.
  bool? get isRailOff => _sample.isRailOff;

  /// Boost rail actively outputting (b7 bit2). Null until b7 is seen.
  bool? get isOutputActive => _sample.isOutputActive;

  /// PD input negotiated (b7 bit3, one-way). Null until b7 is seen.
  bool? get isPdIn => _sample.isPdIn;

  /// PD output (b7 bit5). Null until b7 is seen.
  bool? get isPdOut => _sample.isPdOut;

  /// Raw 0x4B b7 flag byte — for the design 0035 §4.8 feedback hook only; never
  /// shown to a user. Null until b7 is seen.
  int? get portFlagsRaw => _sample.portFlagsRaw;

  /// Reported mode/status code (selector 0x23).
  int? get mode => _sample.mode;



  /// Battery serial (selector 0x26, tail only).
  String? get serial => _sample.serial;

  /// Full product serial = dealer code (0x27) + product serial (0x26); null
  /// until both arrive (connect burst). See [TelemetrySample.fullSerial].
  String? get fullSerial => _sample.fullSerial;
  String? get dealerCode => _sample.dealerCode;

  /// The device's own BLE address (selector 0x38), as an upper-case
  /// colon-separated MAC — the stable cross-platform identity (design 0027
  /// §3.2). NULL until a 0x38 frame arrives. Raw personal data: never exported
  /// as-is, only as its [shortDeviceHash].
  String? get mac => _sample.mac;

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

  /// History rows paired with the unit each was recorded against, so the UI can
  /// resolve a row's product class (see [HistoryRepo.querySamplesWithDevice]).
  Future<List<({TelemetrySample sample, String? deviceId})>> historyWithDevice({
    DateTime? since,
    int? limit,
    String? deviceId,
  }) =>
      _history.querySamplesWithDevice(
          since: since, limit: limit, deviceId: deviceId);

  /// Stored sample count.
  Future<int> historyCount() => _history.count();

  /// Bucketed trend for the chart (DB-side aggregation).
  ///
  /// FB-38: [deviceId] must match whatever the list is showing. A chart and a
  /// list disagreeing about which unit they cover is worse than neither being
  /// filtered.
  Future<List<HistoryBucket>> historyBuckets(
          {DateTime? since, required int bucketMs, String? deviceId}) =>
      _history.queryBuckets(
          since: since, bucketMs: bucketMs, deviceId: deviceId);

  /// Range-wide min/max/avg stats over raw rows.
  Future<HistoryStats> historyStats({DateTime? since, String? deviceId}) =>
      _history.aggregate(since: since, deviceId: deviceId);

  /// Rows in range that were recorded before the unit was identified.
  ///
  /// FB-38 / FB-21: a device-scoped view excludes these, so the screen has to
  /// be able to say how many it is not showing.
  Future<int> historyUnattributedCount({DateTime? since}) =>
      _history.countUnattributed(since: since);

  /// CSV export of matching history rows (for share_plus / file write).
  ///
  /// [labelFor] renders the human-readable `device` column; the caller supplies
  /// it because the alias/serial lookup lives in the device layer. [header]
  /// carries the `#`-prefixed provenance preamble — which build, which
  /// platform, which scope — so the file can be read years later without
  /// anyone having to remember where it came from; see [HistoryRepo.exportCsv]
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
  /// one connection, with an optional `#`-prefixed header. The header is
  /// comment syntax the per-line format already ignores, so it costs existing
  /// readers nothing while telling whoever receives the file which unit, which
  /// build and how many connections it covers.
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

  /// Distinct attributed device ids present in the diagnostic log — the units an
  /// all-devices export actually touches (design 0027 §3.1 `# devices:` block).
  Future<List<String>> logDistinctDeviceIds() => _logs.distinctDeviceIds();

  /// Approximate diagnostic-log size (bytes).
  Future<int> logApproxBytes() => _logs.approxBytes();

  /// Clear the diagnostic log.
  Future<void> clearLog() => _logs.clearLog();

  // ---- stream handlers --------------------------------------------------

  // ---- stall detection ---------------------------------------------------
  // A stall is NOT a disconnect: on Android the link stays ready while the OS
  // suspends the app, so RX and TX both stop for minutes and then flush a
  // backlog (evidenced twice in a 2026-07-27 field capture). During that window
  // the dashboard kept showing the last values with no hint they were frozen.

  /// Freshness per unit, keyed by the recording device id. The null key is the
  /// unattributed case (telemetry arriving before any session opened) — a real
  /// key, not an absence, so those samples keep the behaviour they had.
  final Map<String?, _StallWatch> _stalls = <String?, _StallWatch>{};
  Timer? _stallTimer;

  /// Injectable so tests can exercise the real transition in milliseconds
  /// instead of waiting out the field threshold.
  late final Duration _stallThreshold;
  late final Duration _stallCheckInterval;

  _StallWatch _watchFor(String? deviceId) =>
      _stalls.putIfAbsent(deviceId, _StallWatch.new);

  /// True when the link reports ready but no telemetry has arrived for
  /// [BleService.telemetryStallThreshold] — the readouts on screen are stale.
  ///
  /// Reports the unit currently being recorded, which is the one the dashboard
  /// is showing. With a single link that is the only watch there is.
  @override
  bool get telemetryStalled => _stalls[_session.deviceId]?.stalled ?? false;

  /// Whether the unit being recorded has produced at least one frame on this
  /// connection. False from `ready` until the first one actually lands.
  @override
  bool get hasTelemetry => (_stalls[_session.deviceId]?.samples ?? 0) > 0;

  /// Age of the newest telemetry, or null before the first frame.
  Duration? get telemetryAge => _ageOf(_session.deviceId);

  /// See [TelemetryHealth.lastTelemetryAt] for why this is only meaningful
  /// once [hasTelemetry] is true.
  @override
  DateTime? get lastTelemetryAt => _stalls[_session.deviceId]?.lastSampleAt;

  Duration? _ageOf(String? deviceId) {
    final at = _stalls[deviceId]?.lastSampleAt;
    return at == null ? null : DateTime.now().difference(at);
  }

  /// Re-evaluate every unit being watched, not just the visible one: a unit
  /// whose frames stopped has stalled whether or not it is the one on screen,
  /// and a watch that is only updated while visible would report the moment it
  /// came back into view rather than the moment it froze.
  void _evaluateStall() {
    var changed = false;
    for (final entry in _stalls.entries) {
      final age = _ageOf(entry.key);
      final next = age != null && age > _stallThreshold;
      if (next == entry.value.stalled) continue;
      entry.value.stalled = next;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _onTelemetry(TelemetrySample s) {
    _sample = s;
    // The telemetry stream carries no device id, so the recording session is
    // the attribution — same source the history row about to be written uses,
    // so a sample can never be counted against one unit and stored under
    // another.
    final watch = _watchFor(_session.deviceId);
    watch.lastSampleAt = DateTime.now();
    watch.samples++;
    _trend.add(s);
    if (watch.stalled) {
      watch.stalled = false; // recovered
    }
    notifyListeners();
    _maybeAutoLog(s);
  }

  // ---- per-minute aggregation -------------------------------------------
  // History stores ONE averaged row per minute PER UNIT (not every poll):
  // accumulate each minute's samples, then flush the average on
  // minute-rollover/disconnect.

  /// Open buckets keyed by the unit that owns them. The key is captured when
  /// the bucket opens, NOT when it flushes: a flush triggered by a disconnect
  /// (or after the next unit connects) would otherwise file the minute under
  /// the wrong device — or under none at all. The null key is the unattributed
  /// case and behaves exactly as it did.
  ///
  /// Keying is what replaces the old "a new unit mid-minute closes the bucket"
  /// rule. It gives the same guarantee — one row never mixes two units'
  /// readings — without the rule's failure mode, which was to close the bucket
  /// on EVERY sample as soon as two units interleaved (see [_MinuteBucket]).
  final Map<String?, _MinuteBucket> _buckets = <String?, _MinuteBucket>{};

  /// Fold a sample into the current minute's bucket.
  ///
  /// Recording is UNCONDITIONAL. An `autoLog` switch used to gate this, which
  /// meant a user could silently turn off the one thing we would later ask them
  /// to export, and nothing told them so. It was not even paying for itself:
  /// one row per minute is roughly 6 MB a year, against the 5 MB cap a single
  /// diagnostic log carries on its own. The setting the user actually needs is
  /// how long to KEEP history, and that is what replaced it.
  void _maybeAutoLog(TelemetrySample s) {
    final t = s.timestamp;
    final minute = DateTime(t.year, t.month, t.day, t.hour, t.minute);
    final deviceId = _session.deviceId;
    final b = _buckets.putIfAbsent(deviceId, _MinuteBucket.new);
    // Only a minute rollover closes a bucket now. The unit cannot change under
    // it: it IS the key.
    if (b.minute != null && minute.isAfter(b.minute!)) {
      _flushBucket(deviceId);
    }
    b.minute = minute;
    b.last = s;
    b.nSamples++;
    if (s.pvlt != null) {
      b.sPvlt += s.pvlt!;
      b.nPvlt++;
    }
    if (s.svlt != null) {
      b.sSvlt += s.svlt!;
      b.nSvlt++;
    }
    if (s.temperatureC != null) {
      b.sTemp += s.temperatureC!;
      b.nTemp++;
    }
    if (s.current != null) {
      b.sCur += s.current!;
      b.nCur++;
    }
  }

  /// Persist the minute currently being accumulated, if any.
  ///
  /// Called when the app may be about to lose control of its own execution —
  /// backgrounded, hidden, or being torn down. A minute
  /// rollover and a disconnect are the *orderly* ways a bucket closes; a
  /// silent suspension is not, and until this existed the partial minute was
  /// simply lost. A 2026-07-28 field capture ended that way: the diagnostic log
  /// held 37 more seconds of packets than the CSV did, with no disconnect event
  /// to explain the gap.
  ///
  /// Flushing resets the bucket, so pausing and resuming inside one minute
  /// yields TWO rows for that minute. That is deliberate: each row reports its
  /// own `samples` count, which is more honest than silently merging them or
  /// rewriting a row already on disk.
  ///
  /// Flushes EVERY open bucket: the app is about to lose control of its own
  /// execution, and a unit whose partial minute is left behind because another
  /// unit happened to be current is the loss this exists to prevent.
  void flushPendingHistory() => _flushAllBuckets();

  void _flushAllBuckets() {
    for (final deviceId in _buckets.keys.toList()) {
      _flushBucket(deviceId);
    }
  }

  /// Write one unit's current minute to history, then reset that bucket.
  ///
  /// The bucket object is reset in place rather than dropped, so a caller
  /// holding a reference to it (see [_maybeAutoLog]) keeps writing into the
  /// same one instead of silently filling a bucket nobody will flush.
  void _flushBucket(String? deviceId) {
    final b = _buckets[deviceId];
    if (b == null) return;
    if (b.isOpen) {
      final avg = b.last!.copyWith(
        timestamp: b.minute,
        pvlt: b.nPvlt > 0 ? b.sPvlt / b.nPvlt : null,
        svlt: b.nSvlt > 0 ? b.sSvlt / b.nSvlt : null,
        temperatureC: b.nTemp > 0 ? (b.sTemp / b.nTemp).round() : null,
        current: b.nCur > 0 ? b.sCur / b.nCur : null,
      );
      _pending.add(_history.insertSample(
        avg,
        deviceId: deviceId,
        samples: b.nSamples,
        appBuild: _appBuild,
      ));
    }
    b.minute = null;
    b.last = null;
    b.sPvlt = b.sSvlt = b.sTemp = b.sCur = 0;
    b.nPvlt = b.nSvlt = b.nTemp = b.nCur = 0;
    b.nSamples = 0;
  }

  void _onPacket(BlePacketEvent e) {
    if (!_settings.rawPacketLog) return;
    // The event names the link it crossed. Prefer that over "whichever unit is
    // current", which is what stamped one unit's frames with another's identity
    // whenever a superseded setup was still emitting (FB-41/FB-42), and which
    // would stop being a race and start being the norm with two links. The
    // session number then comes from THAT unit's session, never from the
    // ambient one — a session id may only travel with a row that belongs to it.
    final deviceId = e.deviceId ?? _session.deviceId;
    final entry = LogEntry.fromBytes(
      e.direction,
      e.bytes,
      at: e.at,
      note: e.note,
      deviceId: deviceId,
      sessionId: _session.sessionIdFor(deviceId),
      appBuild: _appBuild,
    );
    _pending.add(_logs.insertLog(entry, maxBytes: _settings.logMaxBytes));
  }

  void _onLinkState(BleLinkState s) {
    if (s == BleLinkState.ready) {
      // Grace period before the first frame, for the unit that just came up.
      // The frame count restarts with it: "has this CONNECTION heard anything"
      // is the question, and a previous connection's frames do not answer it.
      _watchFor(_session.deviceId)
        ..lastSampleAt = DateTime.now()
        ..samples = 0;
      _stallTimer?.cancel();
      _stallTimer = Timer.periodic(_stallCheckInterval, (_) => _evaluateStall());
    }
    if (s == BleLinkState.disconnected) {
      _stallTimer?.cancel();
      _stallTimer = null;
      // A disconnect has its own empty state; it is not a stall. Nothing is
      // being watched once the last link is gone, so drop the watches rather
      // than leaving them to report an age no link is producing.
      _stalls.clear();
      // Persist every open partial minute before clearing live state.
      _flushAllBuckets();
      // Same reason as the readouts below, but it has to be unconditional: a
      // trace kept across a disconnect would be redrawn against the NEXT unit's
      // axis, joining two units with a line neither of them produced.
      _trend.clear();
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
    _trend.dispose();
    super.dispose();
  }
}
