/// OpenSmartBatt — telemetry history repository.
///
/// Persists [TelemetrySample] rows (mockup screen 4: History + CSV export).
/// Rows are written when `AppSettings.autoLog` is on (controller decides).
library;

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
  /// design 0006 appended `soc` and `device` AT THE END on purpose: recipients
  /// already have spreadsheets built on the original column order, so existing
  /// columns must never move. `device` is the HUMAN-readable identity (serial /
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
  ];

  /// Insert one telemetry sample, attributed to [deviceId] when known.
  ///
  /// [samples] is how many telemetry snapshots this row averaged (design 0009).
  /// It is NOT part of [TelemetrySample]: the device never reports it, it is an
  /// artefact of our own per-minute aggregation, and mixing the two would blur
  /// where a number came from. Null means "unknown" — never 0, which would
  /// claim the row averaged nothing.
  ///
  /// [appBuild] is the build that RECORDED the row (design 0010) — not the one
  /// that exports it. This table accumulates across upgrades, so the two can
  /// differ by months.
  Future<int> insertSample(
    TelemetrySample sample, {
    String? deviceId,
    int? samples,
    String? appBuild,
  }) {
    return _db.insert(
        Db.tableHistory, _row(sample, deviceId, samples, appBuild));
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
    String? appBuild,
  ) =>
      Map<String, Object?>.from(s.toMap())
        ..['device_id'] = deviceId
        ..['samples'] = samples
        ..['app_build'] = appBuild;

  /// Query history newest-first.
  ///
  /// - [since]: only rows with `timestamp >= since`.
  /// - [limit]: cap row count (most recent kept).
  Future<List<TelemetrySample>> querySamples({
    DateTime? since,
    int? limit,
    String? deviceId,
  }) async {
    final (where, args) = _scope(since: since, deviceId: deviceId);
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
  /// super-capacitor's 0.0 A is not a measurement (design 0007). The CSV
  /// exporter already solves this by reading the raw row; this gives the UI the
  /// same footing instead of tempting anyone to widen the model.
  Future<List<({TelemetrySample sample, String? deviceId})>>
      querySamplesWithDevice({
    DateTime? since,
    int? limit,
    String? deviceId,
  }) async {
    final (where, args) = _scope(since: since, deviceId: deviceId);
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
  (String?, List<Object?>?) _scope({DateTime? since, String? deviceId}) {
    final clauses = <String>[];
    final args = <Object?>[];
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

  /// Bucketed trend for the chart: groups rows into [bucketMs]-wide buckets and
  /// returns avg/min/max of pvlt + temperature per bucket (ascending by time).
  /// [bucketMs] >= 60000 (one minute, the storage granularity).
  Future<List<HistoryBucket>> queryBuckets({
    DateTime? since,
    required int bucketMs,
  }) async {
    final b = bucketMs < 60000 ? 60000 : bucketMs;
    final where = since == null ? '' : 'WHERE timestamp >= ?';
    final args = <Object?>[
      if (since != null) since.millisecondsSinceEpoch,
    ];
    final rows = await _db.rawQuery(
      'SELECT (timestamp / $b) * $b AS bucket, '
      'AVG(pvlt) AS avgPvlt, MIN(pvlt) AS minPvlt, MAX(pvlt) AS maxPvlt, '
      'AVG(temperature) AS avgTemp, MIN(temperature) AS minTemp, '
      'MAX(temperature) AS maxTemp, COUNT(*) AS n '
      'FROM ${Db.tableHistory} $where '
      'GROUP BY timestamp / $b ORDER BY bucket ASC',
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
  Future<HistoryStats> aggregate({DateTime? since}) async {
    final where = since == null ? '' : 'WHERE timestamp >= ?';
    final args = <Object?>[
      if (since != null) since.millisecondsSinceEpoch,
    ];
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

  /// Total stored sample count.
  Future<int> count() async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM ${Db.tableHistory}',
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
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

  /// Render matching rows (newest-first) as a CSV string with header.
  ///
  /// `timestamp` is emitted as ISO-8601; remaining columns are the raw values
  /// (empty cell for nulls). Safe for `share_plus` / file export.
  ///
  /// [labelFor] turns a stored `device_id` into the human-readable identity for
  /// the `device` column (design 0006 §3.5). Rows recorded before v5 have no
  /// device id, so they get an empty cell rather than a guess.
  /// [classFor] resolves a stored `device_id` to its product class. It exists
  /// for one reason: a super-capacitor streams the 0x2E current register pinned
  /// at exactly 0.0 A even though it cannot measure current. The dashboard hides
  /// that readout (design 0007), so exporting `0.0` would tell the recipient the
  /// unit is drawing no current — a claim the device never made. Those cells get
  /// this exporter's empty value instead (the same `null` the dvol columns
  /// already use). Rows with no device id (pre-0006) keep whatever was recorded:
  /// we do not know their class, so we do not edit their data.
  ///
  /// [header] lines (design 0009) are emitted first, each prefixed with `# `,
  /// followed by a repo-computed `rows / range / devices` summary line and then
  /// the column header. The split of duties is deliberate: the caller knows the
  /// PROVENANCE (app build, platform, which scope the user picked) and only it
  /// can reach `PackageInfo`; this repo knows the CONTENT and already holds the
  /// query result, so it counts without a second trip to the database.
  ///
  /// Returns the text together with the number of DATA rows. Callers must test
  /// `rows == 0` for "nothing to export" — with a preamble present the file is
  /// never empty, so the old `!csv.contains('\n')` check would always pass.
  Future<({String text, int rows})> exportCsv({
    DateTime? since,
    int? limit,
    String? deviceId,
    String Function(String? deviceId)? labelFor,
    ProductClass Function(String? deviceId)? classFor,
    List<String> header = const [],
  }) async {
    final (where, args) = _scope(since: since, deviceId: deviceId);
    final raw = await _db.query(
      Db.tableHistory,
      where: where,
      whereArgs: args,
      orderBy: 'timestamp DESC, id DESC',
      limit: limit,
    );
    final rows = <List<Object?>>[csvColumns];
    for (final m in raw) {
      final s = TelemetrySample.fromMap(m);
      final id = m['device_id'] as String?;
      final isCapacitor =
          id != null && classFor?.call(id) == ProductClass.supercapacitor;
      rows.add(<Object?>[
        s.timestamp.toIso8601String(),
        for (final c in csvColumns.skip(1))
          if (c == 'device')
            (id == null ? null : labelFor?.call(id))
          else if (c == 'ampere' && isCapacitor)
            null // see [classFor]: the device cannot measure current
          else
            m[c],
      ]);
    }
    // design 0019: a per-device export cannot state its own completeness from
    // the result set — the rows it excluded are, by definition, not in it. So
    // count them separately. `_contentSummary` can say "(+unattributed)" only
    // for an all-devices export, which is exactly the asymmetry that let the
    // per-device CSVs look complete while dropping 11.3 % of their samples.
    final excluded =
        deviceId == null ? 0 : await _countUnattributed(since: since);
    final body = const ListToCsvConverter().convert(rows);
    final lines = <String>[
      for (final h in header) '# $h',
      if (header.isNotEmpty) '# ${_contentSummary(raw)}',
      // Omitted entirely at zero: an empty field reads as a missing feature
      // (export_header.dart's rule).
      if (header.isNotEmpty && excluded > 0)
        '# excluded: $excluded unattributed rows',
      body,
    ];
    return (text: lines.join('\n'), rows: raw.length);
  }

  /// Rows in range that carry no device attribution, and are therefore absent
  /// from every per-device export. Counted directly rather than inferred from
  /// the result set, which cannot see them.
  Future<int> _countUnattributed({DateTime? since}) async {
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

  /// `rows: N  range: A .. B  devices: N` — what the file actually contains, so
  /// a recipient can see the size and span of the data instead of guessing.
  /// Rows are ordered newest-first, hence `last`/`first` for the range ends.
  static String _contentSummary(List<Map<String, Object?>> raw) {
    if (raw.isEmpty) return 'rows: 0';
    String at(Map<String, Object?> m) =>
        DateTime.fromMillisecondsSinceEpoch((m['timestamp'] as num).toInt())
            .toIso8601String();
    final devices =
        raw.map((m) => m['device_id'] as String?).whereType<String>().toSet();
    final unattributed = raw.any((m) => m['device_id'] == null);
    // Which build(s) RECORDED these rows (design 0010). Listed because it is
    // routinely different from the exporting build named in the preamble, and
    // a reader who conflates the two draws wrong conclusions from missing data.
    final builds = raw
        .map((m) => m['app_build'] as String?)
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
    return 'rows: ${raw.length}  '
        'range: ${at(raw.last)} .. ${at(raw.first)}  '
        'devices: ${devices.length}${unattributed ? ' (+unattributed)' : ''}'
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
