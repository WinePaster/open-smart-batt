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

  /// Bucketed trend for the chart: groups rows into [bucketMs]-wide buckets and
  /// returns avg/min/max of pvlt + temperature per bucket (ascending by time).
  /// [bucketMs] >= 60000 (one minute, the storage granularity).
  /// FB-38: [deviceId] scopes the chart the same way it scopes the list. These
  /// two used to build their own `WHERE` instead of going through [_scope],
  /// which is exactly how the device dimension came to exist on the list and
  /// not on the chart — so the History screen drew one unit's 3.7 V beside
  /// another's 14 V and called it a voltage anomaly.
  Future<List<HistoryBucket>> queryBuckets({
    DateTime? since,
    required int bucketMs,
    String? deviceId,
    bool attributedOnly = false,
  }) async {
    final b = bucketMs < 60000 ? 60000 : bucketMs;
    final (clause, scopeArgs) =
        _scope(since: since, deviceId: deviceId, attributedOnly: attributedOnly);
    final where = clause == null ? '' : 'WHERE $clause';
    final args = <Object?>[...?scopeArgs];
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

  /// Render matching rows (newest-first) as a CSV string with header.
  ///
  /// `timestamp` is emitted as ISO-8601; remaining columns are the raw values
  /// (empty cell for nulls). Safe for `share_plus` / file export.
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
  /// the CONTENT and already holds the query result, so it counts without a
  /// second trip to the database.
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
    // No `attributedOnly` here, and there must never be one: since design 0043
    // the History screen hides rows with no device, so this export is the only
    // remaining way to get them off the phone. Those rows were never deleted
    // precisely because this path keeps them reachable — a CSV names the device
    // on every row, so one file holding several units cannot mislead the way a
    // single averaged chart line does.
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
    final body = const ListToCsvConverter().convert(rows);
    final lines = <String>[
      for (final h in header) '# $h',
      if (header.isNotEmpty) '# ${_contentSummary(raw)}',
      // Omitted entirely at zero: an empty field reads as a missing feature
      // (export_header.dart's rule).
      if (header.isNotEmpty && excluded > 0)
        '# excluded: $excluded unattributed rows',
      if (header.isNotEmpty && fromOthers > 0)
        '# excluded: $fromOthers rows from other devices',
      body,
    ];
    return (text: lines.join('\n'), rows: raw.length);
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
  /// Rows are ordered newest-first, hence `last`/`first` for the range ends.
  static String _contentSummary(List<Map<String, Object?>> raw) {
    if (raw.isEmpty) return 'rows: 0';
    String at(Map<String, Object?> m) =>
        DateTime.fromMillisecondsSinceEpoch((m['timestamp'] as num).toInt())
            .toIso8601String();
    final devices =
        raw.map((m) => m['device_id'] as String?).whereType<String>().toSet();
    final unattributed = raw.any((m) => m['device_id'] == null);
    // Which build(s) RECORDED these rows. Listed because it is routinely
    // different from the exporting build named in the preamble, and
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
