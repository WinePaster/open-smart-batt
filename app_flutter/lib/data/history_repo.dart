/// OpenSmartBatt — telemetry history repository.
///
/// Persists [TelemetrySample] rows (mockup screen 4: History + CSV export).
/// Rows are written when `AppSettings.autoLog` is on (controller decides).
library;

import 'dart:io';

import 'package:csv/csv.dart';
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import 'app_database.dart';

/// One time-bucket of averaged/min/max telemetry for the trend chart.
/// Produced DB-side by [HistoryRepo.queryBuckets] so large ranges never load
/// every row into Dart.
class HistoryBucket {
  const HistoryBucket({
    required this.at,
    this.avgPvlt,
    this.minPvlt,
    this.maxPvlt,
    this.avgTemp,
    this.minTemp,
    this.maxTemp,
    required this.count,
  });

  final DateTime at; // bucket start
  final double? avgPvlt, minPvlt, maxPvlt;
  final double? avgTemp, minTemp, maxTemp; // temperature averaged across bucket
  final int count;
}

/// How much detail an export asks for — design 0061 T4 (FB-71).
///
/// Storage granularity and EXPORT granularity are deliberately decoupled: the
/// table holds one row per second, and this decides what a file made out of it
/// looks like. That decoupling is the whole architectural point — a 7-day
/// export stays around 12 MB and can still be sent over LINE, while the seconds
/// remain on the phone for whoever needs them.
enum HistoryGranularity {
  /// One row per (unit, minute), values averaged — **the default**, and byte
  /// for byte what every export produced before FB-71.
  minute,

  /// Stored rows exactly as they are. Second rows come out as seconds; rows
  /// recorded before FB-71 come out as the minute averages they are, unchanged
  /// and unexpanded (design 0061 §3.2.3 E1). Skipping them would be silent data
  /// loss and expanding one into 60 identical seconds would be inventing
  /// measurements; the `bucket_s` column says which is which, per row.
  second;

  /// The machine-stable slug for the export preamble. ASCII, not localized —
  /// the reader is whoever receives the file.
  String get slug => this == HistoryGranularity.minute ? '1min' : '1s';
}

/// One display bucket of the history LIST — design 0061 T3a/T3b.
///
/// The list stopped showing stored rows when storage went to one row per
/// second (design 0061 Phase 4): 60× the rows would have turned "the last
/// 1,000 records" from 16 hours into 16 minutes. It shows one entry per
/// display window instead, and this is that entry.
///
/// 🔴 **Why the extremes are carried and not just the mean.** A window is
/// classified normal / warning / event by the History screen, and the
/// thresholds are crossed by INSTANTS, not by averages: one second of
/// over-voltage inside a minute raises `maxPvlt` and leaves `avgPvlt` looking
/// perfectly ordinary. A list that classified on the mean would drop that
/// minute out of the "warnings only" filter — i.e. the 60× storage the user
/// paid for would buy a spike that the read path then averaged back out of
/// existence, with SQL that looks completely normal. So the screen judges on
/// [minPvlt] / [maxPvlt] / [maxTemp] and never on the means (design 0061
/// §3.3.2), and the means exist only to be DISPLAYED.
///
/// [sample] therefore carries the window's means for display; it is not a
/// reading anything ever reported, and its `timestamp` is the window's START.
class HistoryListRow {
  const HistoryListRow({
    required this.sample,
    required this.deviceId,
    required this.bucketMs,
    this.minPvlt,
    this.maxPvlt,
    this.minTemp,
    this.maxTemp,
    required this.rows,
    this.samples,
  });

  /// Window means for display, stamped with the window's start.
  final TelemetrySample sample;
  final String? deviceId;

  /// How wide the display window is. Not the stored `bucket_s` — one display
  /// window folds rows of any granularity.
  final int bucketMs;

  /// Extremes across the window. **The classification reads these.**
  final double? minPvlt, maxPvlt;
  final int? minTemp, maxTemp;

  /// Stored rows folded into this window (1 for a minute window over legacy
  /// data). Diagnostic; never shown as a sample count.
  final int rows;

  /// `SUM(samples)` — telemetry snapshots behind the window, null when no
  /// folded row counted any.
  final int? samples;
}

/// Range-wide min/max/avg over RAW rows (not bucket-averaged), for the stats
/// strip. Nulls when the range has no data for that metric.
class HistoryStats {
  const HistoryStats({
    this.minPvlt,
    this.maxPvlt,
    this.avgPvlt,
    this.minTemp,
    this.maxTemp,
    this.avgTemp,
    this.firstAt,
    required this.count,
  });

  final double? minPvlt, maxPvlt, avgPvlt;
  final double? minTemp, maxTemp, avgTemp;
  final DateTime? firstAt; // earliest row timestamp in range
  final int count;

  static const empty = HistoryStats(count: 0);
}

/// CRUD + CSV export over the `history` table.
class HistoryRepo {
  HistoryRepo(this._db);

  final Database _db;

  /// Ordered CSV/column header. Matches [TelemetrySample.toMap] keys, with
  /// `timestamp` rendered as ISO-8601 in CSV (epoch-ms in the DB).
  ///
  /// STANDING RULE: new columns are appended AT THE END, never inserted, and
  /// existing columns never move or change meaning. Recipients already have
  /// spreadsheets built on the original column order; every column past `serial`
  /// was added later under this rule, and it is the only reason those
  /// spreadsheets still open. `device` is the HUMAN-readable identity (serial /
  /// alias / short hash) — never the raw `device_id` (a MAC address on Android).
  static const List<String> csvColumns = <String>[
    'timestamp',
    'pvlt',
    'svlt',
    'ampere',
    'temperature',
    'dvol1',
    'dvol2',
    'dvol3',
    'dvol4',
    'soh',
    'mode',
    'twf',
    'serial',
    'soc',
    'device',
    'samples',
    'app_build',
    // design 0042 / 0044, appended under the standing rule above.
    //
    // 🔑 These two describe the PHONE, not the unit named in this row's
    // `device` column. One phone, N connected units: every row of the same
    // minute carries the SAME speed, deliberately, so a per-device query must
    // not sum them. Minutes with nothing connected have no row at all rather
    // than a row with a speed and no device (design 0042 §3.9 (b)+(d); a
    // device-less history row is what design 0043 §3.1 refuses to write).
    //
    // Blank means one of: the feature is off, the signal was never live that
    // minute, or the build predates this column. The first is settled by the
    // `speed detection: on/off` preamble line, which is emitted unconditionally
    // for exactly that reason; the third by `app_build`.
    //
    'speed',
    'accel',
    // design 0045, appended when it started writing them — the note that used
    // to stand here reserved the place and said the columns must not appear
    // before the feature did.
    //
    // Same terms as `speed`/`accel` above: they describe the PHONE, and every
    // row of the same minute carries the same pair. Metres per second squared,
    // signed, in VEHICLE coordinates — `g_long` positive is accelerating and
    // negative is braking; `g_lat` positive is a LEFT-hand corner.
    //
    // ⚠️ Minute AVERAGES of a signed quantity. A minute spent accelerating and
    // braking averages towards zero, and so does a minute of alternating
    // corners; the number is honest about what it is (the mean of what the
    // rider was shown) rather than a peak nobody saw. Design 0045 §3.7 accepted
    // that when C1 settled the table's granularity.
    //
    // 🔑 `g_lat` is the only column in this table that can see CORNERING.
    // `accel` is the derivative of a GPS speed, which is a scalar along the
    // direction of travel — it cannot. That is the increment design 0045 Q4
    // wanted: "what did the current do through that bend" has no other source.
    //
    // Blank means the G meter was off, uncalibrated, or not on screen that
    // minute — settled by the `g meter: on/off` preamble line together with
    // `app_build`, exactly as `speed detection:` settles the two above.
    'g_long',
    'g_lat',
    // design 0061 T4d (FB-71), appended under the standing rule above. HOW WIDE
    // THE WINDOW THIS ROW SUMMARISES IS, in seconds: 60 for every row recorded
    // before FB-71 and for any row a per-minute export aggregated, 1 for a
    // stored second exported as itself.
    //
    // 🔴 It is the row's GRANULARITY, never its duration and never its
    // confidence. A minute cut into segments by a disconnect can hold as few as
    // 3 samples and is still `bucket_s = 60`; `samples` is the only column that
    // says how much data is behind the row.
    //
    // Per row rather than per file because ONE FILE HOLDS BOTH. An export asked
    // for at second resolution over a range reaching back before FB-71 contains
    // stored seconds and legacy minute averages side by side, and the
    // preamble's `resolution: contains=` says so — but only this column says
    // WHICH ROWS.
    'bucket_s',
  ];

  /// Insert one telemetry sample, attributed to [deviceId] when known.
  ///
  /// [samples] is how many telemetry snapshots this row averaged. It is NOT
  /// part of [TelemetrySample]: the device never reports it, it is an artefact
  /// of our own per-minute aggregation, and mixing the two would blur where a
  /// number came from. Null means "unknown" — never 0, which would claim the
  /// row averaged nothing.
  ///
  /// [appBuild] is the build that RECORDED the row — not the one that exports
  /// it. This table accumulates across upgrades, so the two can differ by
  /// months, and an export that only names the exporting build cannot say which
  /// version produced any particular row.
  /// [speedMps] / [accelMps2] / [gLongMs2] / [gLatMs2] are the PHONE's, not
  /// this unit's — same "artefact
  /// of our own aggregation, not part of [TelemetrySample]" reasoning as
  /// [samples] and [appBuild], and for a sharper reason: the device never
  /// reports them and never could. Folding them onto the sample type would put
  /// a phone reading inside the object whose entire job is to say what a
  /// battery said. Null means the minute had no live GPS sample (or the feature
  /// is off) — never 0.0, which would claim the phone was measured standing
  /// still.
  ///
  /// **One row per (device, minute)** (design 0048). The controller flushes a
  /// partial minute whenever the app may lose control of its own execution, so
  /// one minute can arrive here in several segments; each extra segment used to
  /// become another row with the same timestamp, and the history screen —
  /// which renders `HH:mm:ss`, and every segment carries `:00` — showed them as
  /// identical duplicates. Segments are merged instead: the numbers combine by
  /// sample-count weight, which for a mean is exact (a weighted mean of the
  /// segments IS the mean of the whole minute), so the merge loses nothing.
  ///
  /// "This minute was cut into N segments" is diagnostic, not user data, and
  /// the diagnostic log already records it in full (`app paused` / `app hidden`
  /// / `link: disconnected`). It was never on this screen: `samples` appears
  /// only in the CSV.
  ///
  /// Rows written by earlier builds are NOT rewritten (design 0048 G2,
  /// 2026-08-07 ruling). Past minutes may still hold several rows; only one of
  /// them — the newest — is ever merged into, and the others are left alone.
  ///
  /// ⚠️ The read-modify-write runs in a TRANSACTION, and it has to. Design 0048
  /// §3 argued it was already safe because writes go through [PendingWrites] —
  /// but that class states plainly that it is "not a queue and not a
  /// scheduler", it only tracks futures that are *already running*. Two flushes
  /// of the same minute can therefore overlap, both see no existing row, and
  /// both insert.
  Future<int> insertSample(
    TelemetrySample sample, {
    String? deviceId,
    int? samples,
    String? appBuild,
    double? speedMps,
    double? accelMps2,
    double? gLongMs2,
    double? gLatMs2,
  }) {
    final incoming = _row(sample, deviceId, samples, appBuild,
        speedMps: speedMps,
        accelMps2: accelMps2,
        gLongMs2: gLongMs2,
        gLatMs2: gLatMs2);

    return _db.transaction<int>((txn) async {
      // `device_id IS NULL` rather than `= ?`: unattributed rows are their own
      // bucket, and SQL equality never matches NULL.
      final existing = await txn.query(
        Db.tableHistory,
        columns: null,
        where: deviceId == null
            ? 'timestamp = ? AND device_id IS NULL'
            : 'timestamp = ? AND device_id = ?',
        whereArgs: deviceId == null
            ? [incoming['timestamp']]
            : [incoming['timestamp'], deviceId],
        orderBy: 'id DESC',
        limit: 1,
      );
      if (existing.isEmpty) {
        return txn.insert(Db.tableHistory, incoming);
      }
      final old = existing.first;
      final id = (old['id'] as num).toInt();
      await txn.update(
        Db.tableHistory,
        _mergeRows(old, incoming),
        where: 'id = ?',
        whereArgs: [id],
      );
      return id;
    });
  }

  /// Columns holding a per-minute MEAN, so two segments of one minute combine
  /// by sample-count weight. Everything else is last-value-wins, which is what
  /// an uninterrupted minute would have produced anyway: the controller takes
  /// non-averaged fields from the minute's last sample.
  static const List<String> _meanColumns = <String>[
    'pvlt',
    'svlt',
    'ampere',
    'speed',
    'accel',
    'g_long',
    'g_lat',
  ];

  /// Same, but stored as INTEGER — so the weighted mean is rounded back.
  static const List<String> _meanIntColumns = <String>['temperature'];

  /// Combine an incoming segment into the row already stored for that minute.
  ///
  /// A null on either side is not a zero: it contributes no weight, and the
  /// other side's value survives unchanged. `samples` is null only when NEITHER
  /// side counted — never 0, which would claim the row averaged nothing.
  static Map<String, Object?> _mergeRows(
    Map<String, Object?> old,
    Map<String, Object?> incoming,
  ) {
    final oldN = (old['samples'] as num?)?.toInt();
    final incN = (incoming['samples'] as num?)?.toInt();
    // An unknown or non-positive count still has to weigh something, or a
    // segment that forgot to count would silently erase one that did.
    final wOld = (oldN != null && oldN > 0) ? oldN : 1;
    final wInc = (incN != null && incN > 0) ? incN : 1;

    final merged = <String, Object?>{};
    for (final entry in incoming.entries) {
      final col = entry.key;
      final inc = entry.value;
      final prev = old[col];

      if (col == 'samples') {
        merged[col] =
            (oldN == null && incN == null) ? null : (oldN ?? 0) + (incN ?? 0);
        continue;
      }

      final isMean = _meanColumns.contains(col);
      final isMeanInt = _meanIntColumns.contains(col);
      if (!isMean && !isMeanInt) {
        merged[col] = inc ?? prev;
        continue;
      }

      final a = (prev as num?)?.toDouble();
      final b = (inc as num?)?.toDouble();
      final double? value;
      if (a == null) {
        value = b;
      } else if (b == null) {
        value = a;
      } else {
        value = (a * wOld + b * wInc) / (wOld + wInc);
      }
      merged[col] = value == null ? null : (isMeanInt ? value.round() : value);
    }
    return merged;
  }

  /// Batch-insert many samples in a single transaction.
  Future<void> insertSamples(
    Iterable<TelemetrySample> samples, {
    String? deviceId,
  }) async {
    final batch = _db.batch();
    for (final s in samples) {
      batch.insert(Db.tableHistory, _row(s, deviceId, null, null));
    }
    await batch.commit(noResult: true);
  }

  static Map<String, Object?> _row(
    TelemetrySample s,
    String? deviceId,
    int? samples,
    String? appBuild, {
    double? speedMps,
    double? accelMps2,
    double? gLongMs2,
    double? gLatMs2,
  }) =>
      Map<String, Object?>.from(s.toMap())
        ..['device_id'] = deviceId
        ..['samples'] = samples
        ..['app_build'] = appBuild
        ..['speed'] = speedMps
        ..['accel'] = accelMps2
        ..['g_long'] = gLongMs2
        ..['g_lat'] = gLatMs2;

  /// Query history newest-first.
  ///
  /// - [since]: only rows with `timestamp >= since`.
  /// - [limit]: cap row count (most recent kept).
  Future<List<TelemetrySample>> querySamples({
    DateTime? since,
    int? limit,
    String? deviceId,
    bool attributedOnly = false,
  }) async {
    final (where, args) =
        _scope(since: since, deviceId: deviceId, attributedOnly: attributedOnly);
    final rows = await _db.query(
      Db.tableHistory,
      where: where,
      whereArgs: args,
      orderBy: 'timestamp DESC, id DESC',
      limit: limit,
    );
    return rows.map(TelemetrySample.fromMap).toList(growable: false);
  }

  /// Same as [querySamples], but each row keeps the device it was recorded
  /// against.
  ///
  /// [TelemetrySample] deliberately carries no device id (it models what the
  /// DEVICE reported, not our attribution of it), yet the History screen has to
  /// know a row's product class to decide whether a reading is meaningful — a
  /// super-capacitor streams a current register that is permanently pinned at
  /// 0.0 A, so that zero is a placeholder, not a measurement. The CSV
  /// exporter already solves this by reading the raw row; this gives the UI the
  /// same footing instead of tempting anyone to widen the model.
  Future<List<({TelemetrySample sample, String? deviceId})>>
      querySamplesWithDevice({
    DateTime? since,
    int? limit,
    String? deviceId,
    bool attributedOnly = false,
  }) async {
    final (where, args) =
        _scope(since: since, deviceId: deviceId, attributedOnly: attributedOnly);
    final rows = await _db.query(
      Db.tableHistory,
      where: where,
      whereArgs: args,
      orderBy: 'timestamp DESC, id DESC',
      limit: limit,
    );
    return rows
        .map((m) => (
              sample: TelemetrySample.fromMap(m),
              deviceId: m['device_id'] as String?,
            ))
        .toList(growable: false);
  }

  /// WHERE clause for a time/device scope. A null [deviceId] means "every
  /// device" — it never matches only the NULL (unattributed) rows.
  ///
  /// [attributedOnly] additionally drops the rows that carry NO device at all
  /// (design 0043 §3.2). It is OPT-IN rather than the default for one reason:
  /// the export must keep emitting those rows, and it is the only way anyone
  /// can still reach them once the History screen stops showing them. An
  /// opt-out default would put that guarantee one forgotten argument away,
  /// whereas an opt-in one cannot leak into a call site that never asks for it.
  (String?, List<Object?>?) _scope({
    DateTime? since,
    String? deviceId,
    bool attributedOnly = false,
  }) {
    final clauses = <String>[];
    final args = <Object?>[];
    // Redundant when [deviceId] is set (`NULL = 'AA'` is NULL, never true), but
    // spelled out anyway so the clause reads the same in every scope and a
    // reader never has to re-derive SQL's three-valued logic to be sure.
    if (attributedOnly) clauses.add('device_id IS NOT NULL');
    if (since != null) {
      clauses.add('timestamp >= ?');
      args.add(since.millisecondsSinceEpoch);
    }
    if (deviceId != null) {
      clauses.add('device_id = ?');
      args.add(deviceId);
    }
    if (clauses.isEmpty) return (null, null);
    return (clauses.join(' AND '), args);
  }

  /// The bucket-start expression, in SQL, for [bucketMs]-wide windows aligned
  /// to LOCAL midnight — design 0061 T13 (Q6, ruled 2026-08-14).
  ///
  /// `timestamp` is a UTC epoch, so the previous `(timestamp / b) * b` cut its
  /// buckets on UTC boundaries: at UTC+8 a 24-hour bucket ran 08:00 to 08:00
  /// and the chart labelled it `MM/dd` — so 08/01 08:00 .. 08/02 08:00 was
  /// drawn as "08/01". Shifting by the offset before dividing and back after
  /// puts the boundary on the viewer's own midnight.
  ///
  /// 🔴 **The offset is the VIEWER's, taken when the query runs**
  /// ([DateTime.now].timeZoneOffset), not the writer's, not a setting, not the
  /// unit's RTC. The chart answers "which day did I, here, now, see this on",
  /// and that is a question about the person looking.
  ///
  /// 🔴 **The same data viewed from two time zones therefore buckets
  /// DIFFERENTLY, and that is the intended behaviour, not a defect.** Written
  /// down because the obvious "fixes" — pinning a zone, or storing the
  /// recording zone — each invert the paragraph above. Whoever comes to
  /// "correct" this should have to argue with this comment first.
  ///
  /// ⚠️ Callers must use the SAME string in `SELECT` and in `GROUP BY`.
  /// Two expressions that merely agree mathematically are one edit away from
  /// grouping by one key and reporting another — and SQLite would not complain;
  /// the chart would simply draw its points in the wrong places.
  static String bucketExpr(int bucketMs, int tzOffsetMs) =>
      '(((timestamp + ($tzOffsetMs)) / $bucketMs) * $bucketMs - ($tzOffsetMs))';

  /// Local-zone offset at the moment of the query — see [bucketExpr].
  static int currentTzOffsetMs() =>
      DateTime.now().timeZoneOffset.inMilliseconds;

  /// SQL for the `samples`-WEIGHTED mean of [col].
  ///
  /// 🔴 A bare `AVG(col)` is wrong here and the corpus has measured how wrong.
  /// One stored minute can be several rows (design 0048 G2 leaves old segments
  /// alone), and those segments hold wildly different sample counts —
  /// `conventions.md` records a 19:26 minute stored as 405 / 69 / 3 / 56, where
  /// the unweighted mean of the four `ampere` values comes out with THE WRONG
  /// SIGN, and a 20:09 minute off by 69 %. The standing corpus rule is
  /// "per-minute statistics are always weighted by `samples`", and a new
  /// aggregation that ignored it would re-introduce, in the app, the exact
  /// defect four separate log batches have re-discovered.
  ///
  /// Rows with a NULL [col] contribute no weight, so a segment that never read
  /// the register cannot dilute one that did — the same rule [_mergeRows]
  /// follows. A NULL or non-positive `samples` still weighs 1, or a segment
  /// that forgot to count would erase one that did.
  static String _wavg(String col) =>
      'SUM(CASE WHEN $col IS NULL THEN 0.0 '
      'ELSE $col * 1.0 * (CASE WHEN COALESCE(samples, 0) > 0 THEN samples ELSE 1 END) END) / '
      'NULLIF(SUM(CASE WHEN $col IS NULL THEN 0 '
      'ELSE (CASE WHEN COALESCE(samples, 0) > 0 THEN samples ELSE 1 END) END), 0)';

  /// The History LIST, aggregated into [bucketMs]-wide display windows,
  /// newest-first — design 0061 T3a.
  ///
  /// Grouped by (device, window), never by window alone: the screen scopes
  /// itself to one unit today, but a query that would silently average a 3.7 V
  /// power bank into a 14 V capacitor if it ever stopped doing so is not one to
  /// leave lying around (FB-38's shape).
  ///
  /// [limit] caps WINDOWS, not stored rows — and it no longer saves any I/O
  /// (see [HistoryListRow] and the History screen's `_rowCap`): SQLite must
  /// scan and group every row matching the scope before it can know which
  /// windows are the newest. That is what makes `idx_history_device_ts`
  /// (schema v17) load-bearing rather than a nicety.
  ///
  /// [tzOffsetMs] defaults to the viewer's current offset; it is a parameter so
  /// a test can pin it. See [bucketExpr] for why it exists at all.
  Future<List<HistoryListRow>> queryListBuckets({
    DateTime? since,
    required int bucketMs,
    int? limit,
    String? deviceId,
    bool attributedOnly = false,
    int? tzOffsetMs,
  }) async {
    final b = bucketMs < 1000 ? 1000 : bucketMs;
    final off = tzOffsetMs ?? currentTzOffsetMs();
    final bucket = bucketExpr(b, off);
    final (clause, scopeArgs) =
        _scope(since: since, deviceId: deviceId, attributedOnly: attributedOnly);
    final where = clause == null ? '' : 'WHERE $clause';
    final rows = await _db.rawQuery(
      // ⚠️ `$bucket` appears in SELECT and in GROUP BY as the SAME string —
      // see [bucketExpr].
      'SELECT $bucket AS bucket, device_id AS device_id, '
      '${_wavg('pvlt')} AS avgPvlt, MIN(pvlt) AS minPvlt, MAX(pvlt) AS maxPvlt, '
      '${_wavg('svlt')} AS avgSvlt, '
      '${_wavg('ampere')} AS avgAmpere, '
      '${_wavg('temperature')} AS avgTemp, '
      'MIN(temperature) AS minTemp, MAX(temperature) AS maxTemp, '
      // Discrete, so "did it happen in this window", never an average. MAX over
      // the ReportedStatus space orders it the way the screen reads it:
      // cut-off (2) outranks anti-theft (1) outranks normal (0), which is the
      // same precedence `_classify` applies to a single row.
      'MAX(mode) AS mode, '
      // The WORST health bucket seen, for the same reason the thresholds use
      // extremes: a window that dipped is a window that dipped.
      'MIN(soh) AS soh, '
      'SUM(samples) AS samples, COUNT(*) AS n '
      'FROM ${Db.tableHistory} $where '
      'GROUP BY device_id, $bucket '
      'ORDER BY bucket DESC${limit == null ? '' : ' LIMIT $limit'}',
      <Object?>[...?scopeArgs],
    );
    double? d(Object? v) => (v as num?)?.toDouble();
    int? i(Object? v) => (v as num?)?.toInt();
    return rows
        .map((r) => HistoryListRow(
              sample: TelemetrySample(
                timestamp: DateTime.fromMillisecondsSinceEpoch(
                    (r['bucket'] as num).toInt()),
                pvlt: d(r['avgPvlt']),
                svlt: d(r['avgSvlt']),
                current: d(r['avgAmpere']),
                temperatureC: d(r['avgTemp'])?.round(),
                mode: i(r['mode']),
                sohBucket: i(r['soh']),
              ),
              deviceId: r['device_id'] as String?,
              bucketMs: b,
              minPvlt: d(r['minPvlt']),
              maxPvlt: d(r['maxPvlt']),
              minTemp: i(r['minTemp']),
              maxTemp: i(r['maxTemp']),
              rows: i(r['n']) ?? 0,
              samples: i(r['samples']),
            ))
        .toList(growable: false);
  }

  /// Bucketed trend for the chart: groups rows into [bucketMs]-wide buckets and
  /// returns avg/min/max of pvlt + temperature per bucket (ascending by time).
  /// [bucketMs] >= 60000 (one minute, the storage granularity).
  /// FB-38: [deviceId] scopes the chart the same way it scopes the list. These
  /// two used to build their own `WHERE` instead of going through [_scope],
  /// which is exactly how the device dimension came to exist on the list and
  /// not on the chart — so the History screen drew one unit's 3.7 V beside
  /// another's 14 V and called it a voltage anomaly.
  ///
  /// Buckets are aligned to the VIEWER's local midnight — see [bucketExpr] for
  /// the offset's provenance and for why the same data buckets differently in
  /// another time zone on purpose. [tzOffsetMs] is a parameter only so a test
  /// can pin it.
  Future<List<HistoryBucket>> queryBuckets({
    DateTime? since,
    required int bucketMs,
    String? deviceId,
    bool attributedOnly = false,
    int? tzOffsetMs,
  }) async {
    final b = bucketMs < 60000 ? 60000 : bucketMs;
    final off = tzOffsetMs ?? currentTzOffsetMs();
    final bucket = bucketExpr(b, off);
    final (clause, scopeArgs) =
        _scope(since: since, deviceId: deviceId, attributedOnly: attributedOnly);
    final where = clause == null ? '' : 'WHERE $clause';
    final args = <Object?>[...?scopeArgs];
    final rows = await _db.rawQuery(
      // ⚠️ `$bucket` is the same string in SELECT and GROUP BY, deliberately —
      // see [bucketExpr]. The two used to be spelled differently here
      // (`(timestamp / b) * b` against `timestamp / b`); they agreed, but only
      // by arithmetic, and a divergence would have grouped by one key while
      // reporting another with no error anywhere.
      'SELECT $bucket AS bucket, '
      'AVG(pvlt) AS avgPvlt, MIN(pvlt) AS minPvlt, MAX(pvlt) AS maxPvlt, '
      'AVG(temperature) AS avgTemp, MIN(temperature) AS minTemp, '
      'MAX(temperature) AS maxTemp, COUNT(*) AS n '
      'FROM ${Db.tableHistory} $where '
      'GROUP BY $bucket ORDER BY bucket ASC',
      args,
    );
    double? d(Object? v) => (v as num?)?.toDouble();
    return rows
        .map((r) => HistoryBucket(
              at: DateTime.fromMillisecondsSinceEpoch((r['bucket'] as num).toInt()),
              avgPvlt: d(r['avgPvlt']),
              minPvlt: d(r['minPvlt']),
              maxPvlt: d(r['maxPvlt']),
              avgTemp: d(r['avgTemp']),
              minTemp: d(r['minTemp']),
              maxTemp: d(r['maxTemp']),
              count: (r['n'] as num?)?.toInt() ?? 0,
            ))
        .toList(growable: false);
  }

  /// Range-wide min/max/avg over raw rows (accurate stats, not bucket-averaged).
  /// FB-38: see [queryBuckets] — same gap, same fix.
  Future<HistoryStats> aggregate({
    DateTime? since,
    String? deviceId,
    bool attributedOnly = false,
  }) async {
    final (clause, scopeArgs) =
        _scope(since: since, deviceId: deviceId, attributedOnly: attributedOnly);
    final where = clause == null ? '' : 'WHERE $clause';
    final args = <Object?>[...?scopeArgs];
    final r = await _db.rawQuery(
      'SELECT MIN(pvlt) AS minP, MAX(pvlt) AS maxP, AVG(pvlt) AS avgP, '
      'MIN(temperature) AS minT, MAX(temperature) AS maxT, AVG(temperature) AS avgT, '
      'MIN(timestamp) AS firstTs, COUNT(*) AS n FROM ${Db.tableHistory} $where',
      args,
    );
    final row = r.first;
    double? d(Object? v) => (v as num?)?.toDouble();
    final firstTs = (row['firstTs'] as num?)?.toInt();
    return HistoryStats(
      minPvlt: d(row['minP']),
      maxPvlt: d(row['maxP']),
      avgPvlt: d(row['avgP']),
      minTemp: d(row['minT']),
      maxTemp: d(row['maxT']),
      avgTemp: d(row['avgT']),
      firstAt:
          firstTs == null ? null : DateTime.fromMillisecondsSinceEpoch(firstTs),
      count: (row['n'] as num?)?.toInt() ?? 0,
    );
  }

  /// Total stored sample count, unattributed rows included.
  Future<int> count() async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM ${Db.tableHistory}',
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Rows that carry a device — i.e. everything the History screen can show.
  ///
  /// This is the number the screen's footer reports (design 0043 §3.2), and it
  /// is also one half of the invariant that licensed removing the screen's
  /// "all devices" option: it must equal the sum of [deviceGroups]' counts.
  /// If it ever exceeds that sum, some showable row belongs to no group and is
  /// therefore reachable from nowhere on the screen — the footer would then
  /// disagree with the lists above it, in public, which is the point of putting
  /// this number there rather than [count].
  Future<int> countAttributed() async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM ${Db.tableHistory} WHERE device_id IS NOT NULL',
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// One entry per device that history actually holds rows for.
  ///
  /// This — not `saved_devices` — is what the History screen's device picker
  /// offers (design 0043 §3.4). The two disagree in both directions: deleting a
  /// saved record leaves its rows behind, and saving a record is a MANUAL step
  /// the user can cancel, so a unit can accumulate a month of history without
  /// ever appearing in the saved list. Sourcing the picker from `saved_devices`
  /// therefore produced options that were guaranteed empty alongside data that
  /// was unreachable; grouping history against itself makes the picker and the
  /// data agree by construction.
  ///
  /// Deliberately NOT time-scoped. The picker answers "which units does this
  /// database know about", which is a different question from "which stretch of
  /// time am I looking at" — a list that shrank with the range would make units
  /// blink out when the user switched to "today" and read as data loss.
  ///
  /// [lastAt] is the newest row for that device, used to order the units that
  /// have no saved record left to sort by, and to tell two ids for the same
  /// physical unit apart after an iOS reinstall rotates its NSUUID.
  Future<List<({String deviceId, int count, DateTime lastAt})>>
      deviceGroups() async {
    final rows = await _db.rawQuery(
      'SELECT device_id AS id, COUNT(*) AS n, MAX(timestamp) AS lastAt '
      'FROM ${Db.tableHistory} WHERE device_id IS NOT NULL '
      'GROUP BY device_id',
    );
    return rows
        .map((r) => (
              deviceId: r['id'] as String,
              count: (r['n'] as num?)?.toInt() ?? 0,
              lastAt: DateTime.fromMillisecondsSinceEpoch(
                  (r['lastAt'] as num?)?.toInt() ?? 0),
            ))
        .toList(growable: false);
  }

  /// Delete all history rows.
  Future<int> clearHistory() => _db.delete(Db.tableHistory);

  /// Delete rows older than [before]; returns rows removed.
  Future<int> deleteOlderThan(DateTime before) {
    return _db.delete(
      Db.tableHistory,
      where: 'timestamp < ?',
      whereArgs: [before.millisecondsSinceEpoch],
    );
  }

  /// Write matching rows (newest-first) into [file] as CSV with header.
  ///
  /// `timestamp` is emitted as ISO-8601; remaining columns are the raw values
  /// (empty cell for nulls). The finished file is what goes to `share_plus`.
  ///
  /// [labelFor] turns a stored `device_id` into the human-readable identity for
  /// the `device` column — never the raw id, which is a MAC address on Android
  /// and would leak into every shared file. Rows recorded before the schema had
  /// a device column have no device id, so they get an empty cell rather than a
  /// guess.
  /// [classFor] resolves a stored `device_id` to its product class. It exists
  /// for one reason: a super-capacitor streams the 0x2E current register pinned
  /// at exactly 0.0 A even though it cannot measure current. The dashboard hides
  /// that readout for the same reason, so exporting `0.0` would tell the
  /// recipient the unit is drawing no current — a claim the device never made.
  /// Those cells get this exporter's empty value instead (the same `null` the
  /// dvol columns already use). Rows with no device id keep whatever was
  /// recorded: we do not know their class, so we do not edit their data.
  ///
  /// [header] lines are emitted first, each prefixed with `# `, followed by a
  /// repo-computed `rows / range / devices` summary line and then the column
  /// header. Together they let a recipient answer "where did this come from and
  /// is any of it missing?" from the file alone. The split of duties is
  /// deliberate: the caller knows the PROVENANCE (app build, platform, which
  /// scope the user picked) and only it can reach `PackageInfo`; this repo knows
  /// the CONTENT and can count it DB-side, without a result set to walk.
  ///
  /// Returns the number of DATA rows written. Callers must test `rows == 0` for
  /// "nothing to export" — with a preamble present the file is never empty, so
  /// the old `!csv.contains('\n')` check would always pass.
  ///
  /// 🔑 **No `limit` parameter, deliberately** (design 0030 T4c, FB-59). The
  /// History screen used to pass its own `_rowCap = 1000` — the list's UI paging
  /// bound — straight into the export, so an export of a longer range was
  /// SILENTLY truncated to its newest 1,000 rows and nothing in the file or on
  /// the screen said so. The cap is a property of a scrolling list, never of a
  /// file; the export's bound is the time range the user picked and nothing
  /// else. It is absent rather than defaulted to null so that no call site can
  /// reintroduce one by passing a variable that happens to be in scope.
  ///
  /// 📄 **Paged and streamed** (design 0030 T4b). Rows are fetched
  /// [_exportPageSize] at a time and appended to [file] as they are converted,
  /// so the peak memory cost is one page — not the whole export, which used to
  /// exist THREE times over at once (`List<Map>` → `List<List>` → one `String`).
  /// The event loop is yielded between pages, so BLE notifications keep being
  /// delivered and the keep-alive write cannot time out mid-export (FB-40's
  /// neighbourhood).
  /// [granularity] decides what a ROW of this file is (design 0061 T4d):
  /// [HistoryGranularity.minute] aggregates stored rows into one row per
  /// (unit, minute) — which is byte for byte what every export produced before
  /// FB-71 — while [HistoryGranularity.second] emits stored rows untouched.
  /// Either way every row states its own `bucket_s`.
  Future<int> exportCsvToFile(
    File file, {
    DateTime? since,
    String? deviceId,
    String Function(String? deviceId)? labelFor,
    ProductClass Function(String? deviceId)? classFor,
    List<String> header = const [],
    HistoryGranularity granularity = HistoryGranularity.minute,
    void Function(int written, int total)? onProgress,
  }) async {
    final sink = file.openWrite();
    try {
      return await _exportCsvStream(
        granularity: granularity,
        // Flushing per page is what keeps the streaming honest: an unawaited
        // `IOSink.write` only queues, so without this the whole export would
        // pile up in the sink's buffer and we would have moved the peak rather
        // than removed it.
        emit: (chunk) async {
          sink.write(chunk);
          await sink.flush();
        },
        since: since,
        deviceId: deviceId,
        labelFor: labelFor,
        classFor: classFor,
        header: header,
        onProgress: onProgress,
      );
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  /// In-memory variant of [exportCsvToFile], for tests and callers that already
  /// hold the whole thing (there are none in the app — every export path writes
  /// a file). Same bytes, same row count; it just accumulates them in a
  /// [StringBuffer] instead of a sink, so it carries the memory cost the file
  /// path exists to avoid. Do not reach for it from the UI.
  Future<({String text, int rows})> exportCsv({
    DateTime? since,
    String? deviceId,
    String Function(String? deviceId)? labelFor,
    ProductClass Function(String? deviceId)? classFor,
    List<String> header = const [],
    HistoryGranularity granularity = HistoryGranularity.minute,
  }) async {
    final buf = StringBuffer();
    final rows = await _exportCsvStream(
      granularity: granularity,
      emit: (chunk) async => buf.write(chunk),
      since: since,
      deviceId: deviceId,
      labelFor: labelFor,
      classFor: classFor,
      header: header,
    );
    return (text: buf.toString(), rows: rows);
  }

  /// Rows fetched (and converted, and written) per page — design 0030 T4b.
  static const int _exportPageSize = 5000;

  /// The row separator the CSV body uses. Spelled out and handed to the
  /// converter rather than left to its default, because the streamed writer has
  /// to emit it itself between pages: if the two ever disagreed, every 5,000th
  /// row would join the one before it.
  static const String _csvEol = '\r\n';
  static const ListToCsvConverter _csv = ListToCsvConverter(eol: _csvEol);

  /// The paged core behind [exportCsvToFile] / [exportCsv].
  ///
  /// The preamble has to be written BEFORE any row, yet its `rows: / range: /
  /// devices: / builds:` summary describes all of them. It is therefore
  /// computed with aggregate SQL (see [_contentSummarySql]) over the same scope
  /// the pages walk — no result set is held to derive it.
  ///
  /// 🔑 That summary is only trustworthy if the scope cannot move underneath
  /// the paging, and it can: this app writes a history row every minute while
  /// the export runs. `LIMIT/OFFSET` over a newest-first order shifts by one
  /// for every row inserted mid-export, which duplicates a row at each page
  /// boundary, and a count taken up front would then disagree with what was
  /// written. So the whole export is pinned to the rows that existed when it
  /// started, by id — every later row sorts above the pin and is simply not
  /// part of this file. `rows:` then equals the number of rows written, by
  /// construction rather than by luck.
  ///
  /// 📐 **Two shapes of page** (design 0061 T4d). At
  /// [HistoryGranularity.second] a page is stored rows, exactly as before. At
  /// [HistoryGranularity.minute] a page is `GROUP BY (device, minute)`, and the
  /// paging, the pin and the count all apply to GROUPS — `rows:` still equals
  /// the rows written, but they are windows now.
  Future<int> _exportCsvStream({
    required Future<void> Function(String chunk) emit,
    DateTime? since,
    String? deviceId,
    String Function(String? deviceId)? labelFor,
    ProductClass Function(String? deviceId)? classFor,
    List<String> header = const [],
    HistoryGranularity granularity = HistoryGranularity.minute,
    int? tzOffsetMs,
    void Function(int written, int total)? onProgress,
  }) async {
    // No `attributedOnly` here, and there must never be one: since design 0043
    // the History screen hides rows with no device, so this export is the only
    // remaining way to get them off the phone. Those rows were never deleted
    // precisely because this path keeps them reachable — a CSV names the device
    // on every row, so one file holding several units cannot mislead the way a
    // single averaged chart line does.
    final (scopeClause, scopeArgs) = _scope(since: since, deviceId: deviceId);
    final pin = await _maxRowId();
    final where =
        scopeClause == null ? 'id <= ?' : '$scopeClause AND id <= ?';
    final args = <Object?>[...?scopeArgs, pin];
    final byMinute = granularity == HistoryGranularity.minute;
    // Aligned to the viewer's local minute, the same expression the list and
    // the chart group by — see [bucketExpr]. A whole-hour offset cannot move a
    // minute boundary, but there are zones offset by 30 and 45 minutes, and
    // having the export cut its minutes somewhere the screen does not is
    // exactly the "the file and the screen say different things" failure this
    // whole change is trying not to commit.
    final bucket = bucketExpr(60000, tzOffsetMs ?? currentTzOffsetMs());
    final groupBy = 'device_id, $bucket';

    final total =
        byMinute ? await _countGroups(where, args, groupBy) : await _countWhere(where, args);
    // A per-device export cannot state its own completeness from the result set
    // — the rows it excluded are, by definition, not in it. So count them
    // separately. `_contentSummary` can say "(+unattributed)" only for an
    // all-devices export, which is exactly the asymmetry that let per-device
    // CSVs look complete while dropping 11.3 % of their samples.
    final excluded =
        deviceId == null ? 0 : await countUnattributed(since: since);
    // The other half of the same silent loss: rows attributed to a DIFFERENT
    // unit are dropped by [_scope] and were reported nowhere. See
    // [countOtherDevices].
    final fromOthers = deviceId == null
        ? 0
        : await countOtherDevices(deviceId, since: since);

    final preamble = <String>[
      for (final h in header) '# $h',
      if (header.isNotEmpty)
        '# ${await _contentSummarySql(where, args, rows: total, bucket: byMinute ? bucket : null)}',
      // Omitted entirely at zero: an empty field reads as a missing feature
      // (export_header.dart's rule).
      if (header.isNotEmpty && excluded > 0)
        '# excluded: $excluded unattributed rows',
      if (header.isNotEmpty && fromOthers > 0)
        '# excluded: $fromOthers rows from other devices',
    ];
    // The column header closes the preamble block. There is no `# truncated:`
    // line to go with it and there cannot be one any more: with the row cap
    // gone (T4c) this path has no way to stop early, so a line reporting
    // truncation would be unreachable code claiming to guard against something
    // that can no longer happen.
    await emit([...preamble, ''].join('\n'));
    await emit(_csv.convert(<List<Object?>>[csvColumns]));

    var written = 0;
    while (written < total) {
      final page = byMinute
          ? await _db.rawQuery(
              'SELECT $bucket AS timestamp, device_id AS device_id, '
              '${_minuteExportColumns()} '
              'FROM ${Db.tableHistory} WHERE $where '
              'GROUP BY $groupBy '
              'ORDER BY timestamp DESC, device_id DESC '
              'LIMIT $_exportPageSize OFFSET $written',
              args,
            )
          : await _db.query(
              Db.tableHistory,
              where: where,
              whereArgs: args,
              orderBy: 'timestamp DESC, id DESC',
              limit: _exportPageSize,
              offset: written,
            );
      if (page.isEmpty) break; // rows deleted under us; stop rather than spin
      final rows = <List<Object?>>[];
      for (final m in page) {
        final id = m['device_id'] as String?;
        final isCapacitor =
            id != null && classFor?.call(id) == ProductClass.supercapacitor;
        rows.add(<Object?>[
          // Read straight off the row rather than through
          // `TelemetrySample.fromMap`: only the timestamp is taken from the
          // model, and building a whole sample object per row to reach one
          // field costs an allocation the streaming exists to avoid. Same
          // conversion, epoch-ms to local ISO-8601.
          DateTime.fromMillisecondsSinceEpoch((m['timestamp'] as num?)?.toInt() ?? 0)
              .toIso8601String(),
          for (final c in csvColumns.skip(1))
            if (c == 'device')
              (id == null ? null : labelFor?.call(id))
            else if (c == 'ampere' && isCapacitor)
              null // see [classFor]: the device cannot measure current
            else
              m[c],
        ]);
      }
      await emit(_csvEol + _csv.convert(rows));
      written += page.length;
      onProgress?.call(written, total);
      // Design 0030 T4b: hand the event loop back between pages. `convert()` is
      // synchronous and does not, so without this a large export is one
      // uninterrupted block of work with BLE notifications queued behind it.
      await Future<void>.delayed(Duration.zero);
    }
    return written;
  }

  /// The aggregate `SELECT` list for a per-minute export page — design 0061
  /// T4d. Every CSV column except `timestamp` and `device_id`, which the caller
  /// supplies as the group keys.
  ///
  /// 🔑 **The means are weighted by `samples`, exactly as the History list is**
  /// (see [_wavg] for the measured reason, and for why a bare `AVG` over
  /// segmented minute rows can come out with the wrong SIGN). Screen and file
  /// agreeing about the same minute is not a nicety here: the reporter reads
  /// one and we read the other.
  ///
  /// ⚠️ **The non-mean columns report the LARGEST value in the window, not the
  /// last one.** [_mergeRows] — the app's one rule for combining rows of the
  /// same minute — calls them last-value-wins, and a `GROUP BY` on the SQLite
  /// this app is allowed to assume cannot express "last" (window functions need
  /// 3.25+, and on Android sqflite runs against the system library on a minSdk
  /// 24 device). The choice is therefore between the largest and an arbitrary
  /// one; the largest at least reproduces, and for the two that matter it fails
  /// in the safe direction — `mode` keeps a cut-off rather than a normal, and
  /// `twf` keeps a fault word rather than a zero. `soh` is the exception and
  /// takes MIN, matching the list: a window that dipped is a window that
  /// dipped.
  static String _minuteExportColumns() {
    const means = <String>[
      'pvlt',
      'svlt',
      'ampere',
      'dvol1',
      'dvol2',
      'dvol3',
      'dvol4',
      'speed',
      'accel',
      'g_long',
      'g_lat',
    ];
    // Stored INTEGER, so the weighted mean is rounded back — same treatment
    // `_mergeRows` gives them.
    const meanInts = <String>['temperature', 'soc'];
    return <String>[
      for (final c in means) '${_wavg(c)} AS $c',
      for (final c in meanInts) 'CAST(ROUND(${_wavg(c)}) AS INTEGER) AS $c',
      'MIN(soh) AS soh',
      'MAX(mode) AS mode',
      'MAX(twf) AS twf',
      'MAX(serial) AS serial',
      'MAX(app_build) AS app_build',
      'SUM(samples) AS samples',
      // 🔴 A literal, and correct by construction: this row IS a minute window,
      // whatever the rows underneath it were. A minute window built out of
      // stored seconds is `60` for the same reason one built out of a legacy
      // minute average is — `bucket_s` describes the row in the file, not its
      // ancestry.
      '60 AS bucket_s',
    ].join(', ');
  }

  /// Rows a per-minute export of this scope would write — i.e. how many
  /// (unit, minute) windows it holds.
  Future<int> _countGroups(
      String where, List<Object?> args, String groupBy) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM '
      '(SELECT 1 FROM ${Db.tableHistory} WHERE $where GROUP BY $groupBy)',
      args,
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// How many rows an export of this scope at [granularity] would write.
  ///
  /// Used by the export sheet's size estimate (design 0061 T4c / Q4), where it
  /// must run OFF the UI thread's critical path — at second resolution this
  /// counts a table 60× the size of the one that used to be here.
  Future<int> countExportRows({
    DateTime? since,
    String? deviceId,
    required HistoryGranularity granularity,
    int? tzOffsetMs,
  }) async {
    final (clause, scopeArgs) = _scope(since: since, deviceId: deviceId);
    final where = clause ?? '1';
    final args = <Object?>[...?scopeArgs];
    if (granularity == HistoryGranularity.second) {
      return _countWhere(where, args);
    }
    final bucket = bucketExpr(60000, tzOffsetMs ?? currentTzOffsetMs());
    return _countGroups(where, args, 'device_id, $bucket');
  }

  /// The distinct stored granularities in this scope, ascending — the raw
  /// material for the preamble's `resolution: contains=` line (design 0061
  /// §3.2.3). Empty when the scope holds no rows at all, which is a DIFFERENT
  /// statement from "one granularity" and is why the caller must not default
  /// it.
  Future<List<int>> distinctBucketWidths({
    DateTime? since,
    String? deviceId,
  }) async {
    final (clause, scopeArgs) = _scope(since: since, deviceId: deviceId);
    final where = clause == null ? '' : 'WHERE $clause';
    final rows = await _db.rawQuery(
      'SELECT DISTINCT bucket_s AS b FROM ${Db.tableHistory} $where '
      'ORDER BY b ASC',
      <Object?>[...?scopeArgs],
    );
    return rows
        .map((r) => (r['b'] as num?)?.toInt())
        .whereType<int>()
        .toList(growable: false);
  }

  /// Highest `id` currently in the table, used to pin an export's scope. Zero on
  /// an empty table — `id <= 0` then matches nothing, which is correct.
  Future<int> _maxRowId() async {
    final r = await _db.rawQuery('SELECT MAX(id) AS m FROM ${Db.tableHistory}');
    return (r.first['m'] as num?)?.toInt() ?? 0;
  }

  Future<int> _countWhere(String where, List<Object?> args) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM ${Db.tableHistory} WHERE $where',
      args,
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Rows in range that carry no device attribution, and are therefore absent
  /// from every per-device export. Counted directly rather than inferred from
  /// the result set, which cannot see them.
  /// Rows recorded before the unit was identified, in [since]'s range.
  ///
  /// Used by the EXPORT header only. The History screen used to call this too,
  /// to footnote how many rows its device scope was hiding; design 0043 §3.6.1
  /// withdrew that note. A row with no device is not a category the user has to
  /// understand — it is a record that should never have been written (§3.1 now
  /// prevents it), so the screen simply does not deal in it. The export still
  /// declares the count because a file that cannot state what it omits is the
  /// original problem this whole line of work exists to fix.
  Future<int> countUnattributed({DateTime? since}) async {
    final where = <String>['device_id IS NULL'];
    final args = <Object?>[];
    if (since != null) {
      where.add('timestamp >= ?');
      args.add(since.millisecondsSinceEpoch);
    }
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM ${Db.tableHistory} WHERE ${where.join(' AND ')}',
      args,
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Rows in range belonging to some OTHER unit than [deviceId] — the other
  /// half of the same silent loss [countUnattributed] covers.
  ///
  /// The first pass at export completeness counted the rows with NO device and
  /// stopped there, but [_scope] filters `device_id = ?`, which drops rows
  /// belonging to a DIFFERENT unit just as completely — and unlike the
  /// unattributed ones, those said nothing at all. A phone that has watched two
  /// packs exports one of them and the CSV reads as though the other had never
  /// been connected.
  ///
  /// Reported separately from [countUnattributed], never summed: "recorded
  /// before we knew the unit" and "belongs to a different unit" are different
  /// facts, and only the first is a shortcoming of ours.
  ///
  /// Scoped by [since] — unlike the log's equivalent, which has no time window.
  /// A count that reached outside the exported range would describe rows the
  /// file was never going to contain, which is not the question the header
  /// line answers.
  ///
  /// `IS NOT NULL` is redundant under SQL three-valued logic (`NULL != 'AA'`
  /// evaluates to NULL, not true, so unattributed rows never match), but it is
  /// spelled out so the partition against [countUnattributed] is exact and
  /// visibly so: every excluded row lands in exactly one of the two.
  Future<int> countOtherDevices(String deviceId, {DateTime? since}) async {
    final where = <String>['device_id IS NOT NULL', 'device_id != ?'];
    final args = <Object?>[deviceId];
    if (since != null) {
      where.add('timestamp >= ?');
      args.add(since.millisecondsSinceEpoch);
    }
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM ${Db.tableHistory} WHERE ${where.join(' AND ')}',
      args,
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// `rows: N  range: A .. B  devices: N` — what the file actually contains, so
  /// a recipient can see the size and span of the data instead of guessing.
  ///
  /// Computed DB-side over the export's pinned scope, because the preamble is
  /// written before the first page is fetched and no result set exists yet to
  /// summarise (design 0030 T4b). The wording, spacing and omission rules are
  /// unchanged from the version that walked the rows — recipients have
  /// spreadsheets and scripts reading these lines.
  ///
  /// [rows] is passed in rather than counted here, because at per-minute
  /// granularity the file's rows are WINDOWS and `COUNT(*)` over the table
  /// would describe something the reader is not holding. [bucket] is the same
  /// aggregation's bucket expression, non-null in that case only, so `range:`
  /// names the first and last row IN THE FILE instead of landing up to 59
  /// seconds away from them.
  Future<String> _contentSummarySql(
    String where,
    List<Object?> args, {
    required int rows,
    String? bucket,
  }) async {
    final ts = bucket ?? 'timestamp';
    final r = await _db.rawQuery(
      'SELECT MIN($ts) AS minTs, MAX($ts) AS maxTs, '
      'COUNT(DISTINCT device_id) AS devices, '
      'SUM(CASE WHEN device_id IS NULL THEN 1 ELSE 0 END) AS unattributed '
      'FROM ${Db.tableHistory} WHERE $where',
      args,
    );
    final row = r.first;
    final n = rows;
    if (n == 0) return 'rows: 0';
    String at(Object? ms) =>
        DateTime.fromMillisecondsSinceEpoch((ms as num).toInt())
            .toIso8601String();
    // `COUNT(DISTINCT …)` skips NULLs, which is exactly the old
    // `whereType<String>().toSet().length`; the NULL rows are reported by the
    // `(+unattributed)` marker instead, never folded into the device count.
    final devices = (row['devices'] as num?)?.toInt() ?? 0;
    final unattributed = ((row['unattributed'] as num?)?.toInt() ?? 0) > 0;
    // Which build(s) RECORDED these rows. Listed because it is routinely
    // different from the exporting build named in the preamble, and
    // a reader who conflates the two draws wrong conclusions from missing data.
    final buildRows = await _db.rawQuery(
      'SELECT DISTINCT app_build AS b FROM ${Db.tableHistory} '
      'WHERE $where AND app_build IS NOT NULL',
      args,
    );
    final builds = buildRows.map((m) => m['b'] as String).toList()..sort();
    return 'rows: $n  '
        'range: ${at(row['minTs'])} .. ${at(row['maxTs'])}  '
        'devices: $devices${unattributed ? ' (+unattributed)' : ''}'
        '${builds.isEmpty ? '' : '  builds: ${builds.join(', ')}'}';
  }

  /// Distinct device ids present in history (NULL rows excluded).
  Future<List<String>> distinctDeviceIds() async {
    final rows = await _db.rawQuery(
      'SELECT DISTINCT device_id FROM ${Db.tableHistory} '
      'WHERE device_id IS NOT NULL ORDER BY device_id',
    );
    return rows.map((r) => r['device_id'] as String).toList(growable: false);
  }
}
