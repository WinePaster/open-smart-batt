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
  ];

  /// Insert one telemetry sample. Returns the new row id.
  Future<int> insertSample(TelemetrySample sample) {
    return _db.insert(Db.tableHistory, sample.toMap());
  }

  /// Batch-insert many samples in a single transaction.
  Future<void> insertSamples(Iterable<TelemetrySample> samples) async {
    final batch = _db.batch();
    for (final s in samples) {
      batch.insert(Db.tableHistory, s.toMap());
    }
    await batch.commit(noResult: true);
  }

  /// Query history newest-first.
  ///
  /// - [since]: only rows with `timestamp >= since`.
  /// - [limit]: cap row count (most recent kept).
  Future<List<TelemetrySample>> querySamples({
    DateTime? since,
    int? limit,
  }) async {
    final rows = await _db.query(
      Db.tableHistory,
      where: since == null ? null : 'timestamp >= ?',
      whereArgs: since == null ? null : [since.millisecondsSinceEpoch],
      orderBy: 'timestamp DESC, id DESC',
      limit: limit,
    );
    return rows.map(TelemetrySample.fromMap).toList(growable: false);
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
  Future<String> exportCsv({DateTime? since, int? limit}) async {
    final samples = await querySamples(since: since, limit: limit);
    final rows = <List<Object?>>[csvColumns];
    for (final s in samples) {
      final m = s.toMap();
      rows.add(<Object?>[
        s.timestamp.toIso8601String(),
        for (final c in csvColumns.skip(1)) m[c],
      ]);
    }
    return const ListToCsvConverter().convert(rows);
  }
}
