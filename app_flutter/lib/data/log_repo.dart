/// OpenSmartBatt — diagnostic raw-BLE log repository (mockup settings).
///
/// Optional TX/RX hex packet log, only written when `AppSettings.rawPacketLog`
/// is ON (DEFAULT OFF). Capped/rotated by an approximate byte budget
/// (`AppSettings.logMaxBytes`, default 5 MB) — oldest rows are dropped first.
library;

import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import 'app_database.dart';

/// Append-only-ish log with size-based rotation over the `diag_log` table.
class LogRepo {
  LogRepo(this._db);

  final Database _db;

  /// Fixed per-row overhead (bytes) approximating timestamp + direction +
  /// separators when rendered via [LogEntry.toLogLine], used for rotation math.
  static const int _rowOverheadBytes = 40;

  /// Insert a log entry. If [maxBytes] is given, trim oldest rows afterwards
  /// to keep the estimated log size within budget. Returns the new row id.
  Future<int> insertLog(LogEntry entry, {int? maxBytes}) async {
    final map = Map<String, Object?>.from(entry.toMap())..remove('id');
    final id = await _db.insert(Db.tableDiagLog, map);
    if (maxBytes != null) {
      await trimToBytes(maxBytes);
    }
    return id;
  }

  /// Query log entries newest-first.
  Future<List<LogEntry>> queryLog({int? limit}) async {
    final rows = await _db.query(
      Db.tableDiagLog,
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(LogEntry.fromMap).toList(growable: false);
  }

  /// Stored row count.
  Future<int> count() async {
    final r = await _db.rawQuery('SELECT COUNT(*) AS n FROM ${Db.tableDiagLog}');
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Estimated on-disk/text size of the log in bytes (for rotation + UI).
  Future<int> approxBytes() async {
    final r = await _db.rawQuery(
      'SELECT '
      'COALESCE(SUM(LENGTH(hex) + LENGTH(COALESCE(note, \'\')) + ?), 0) AS bytes '
      'FROM ${Db.tableDiagLog}',
      [_rowOverheadBytes],
    );
    return (r.first['bytes'] as num?)?.toInt() ?? 0;
  }

  /// Render the whole log oldest-first as a `.log` text blob (one line each).
  Future<String> exportLog() async {
    final rows = await _db.query(Db.tableDiagLog, orderBy: 'id ASC');
    final entries = rows.map(LogEntry.fromMap);
    return entries.map((e) => e.toLogLine()).join('\n');
  }

  /// Delete every log row.
  Future<int> clearLog() => _db.delete(Db.tableDiagLog);

  /// Drop oldest rows until the estimated size is within [maxBytes].
  ///
  /// Removes rows in one batched delete (estimated from the average row size)
  /// then re-checks once, so worst case is two passes.
  Future<void> trimToBytes(int maxBytes) async {
    if (maxBytes <= 0) {
      await clearLog();
      return;
    }
    for (var pass = 0; pass < 2; pass++) {
      final total = await approxBytes();
      if (total <= maxBytes) return;
      final rows = await count();
      if (rows <= 0) return;
      final avg = (total / rows).ceil().clamp(1, total);
      // +1 row of slack so we drop strictly below the cap.
      final toRemove = (((total - maxBytes) / avg).ceil() + 1).clamp(1, rows);
      await _deleteOldest(toRemove);
    }
  }

  Future<void> _deleteOldest(int n) async {
    await _db.rawDelete(
      'DELETE FROM ${Db.tableDiagLog} WHERE id IN '
      '(SELECT id FROM ${Db.tableDiagLog} ORDER BY id ASC LIMIT ?)',
      [n],
    );
  }
}
