/// Open-RCE-Batt — telemetry history repository.
///
/// Persists [TelemetrySample] rows (mockup screen 4: History + CSV export).
/// Rows are written when `AppSettings.autoLog` is on (controller decides).
library;

import 'package:csv/csv.dart';
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import 'app_database.dart';

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
