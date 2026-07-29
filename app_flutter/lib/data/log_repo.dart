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

  /// Query log entries newest-first, optionally scoped to one unit and/or one
  /// connection (design 0006).
  Future<List<LogEntry>> queryLog({
    int? limit,
    String? deviceId,
    int? sessionId,
  }) async {
    final (where, args) = _scope(deviceId: deviceId, sessionId: sessionId);
    final rows = await _db.query(
      Db.tableDiagLog,
      where: where,
      whereArgs: args,
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(LogEntry.fromMap).toList(growable: false);
  }

  /// Highest `session_id` seen so far, or null when the log holds no session-
  /// tagged rows. Used at startup to keep the counter monotonic across restarts.
  Future<int?> lastSessionId() async {
    final r = await _db.rawQuery(
      'SELECT MAX(session_id) AS n FROM ${Db.tableDiagLog}',
    );
    return (r.first['n'] as num?)?.toInt();
  }

  /// Distinct device ids present in the log (NULL rows excluded).
  Future<List<String>> distinctDeviceIds() async {
    final rows = await _db.rawQuery(
      'SELECT DISTINCT device_id FROM ${Db.tableDiagLog} '
      'WHERE device_id IS NOT NULL ORDER BY device_id',
    );
    return rows.map((r) => r['device_id'] as String).toList(growable: false);
  }

  /// Builds the WHERE clause for a device/session scope. A null [deviceId]
  /// means "every device" — it never matches only the NULL rows.
  (String?, List<Object?>?) _scope({String? deviceId, int? sessionId}) {
    final clauses = <String>[];
    final args = <Object?>[];
    if (deviceId != null) {
      clauses.add('device_id = ?');
      args.add(deviceId);
    }
    if (sessionId != null) {
      clauses.add('session_id = ?');
      args.add(sessionId);
    }
    if (clauses.isEmpty) return (null, null);
    return (clauses.join(' AND '), args);
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

  /// Render the log oldest-first as a `.log` text blob (one line each),
  /// optionally scoped to one unit and/or one connection (design 0006).
  ///
  /// [header] lines are emitted first, each prefixed with `# ` — they tell
  /// whoever receives the file which unit, which app version and how many
  /// connections it covers. The per-line format below is unchanged.
  /// [labelFor] renders a device id as the human identity used in the section
  /// separators. Without separators an all-devices export is ambiguous line by
  /// line: the rows carry the device internally, but the text format does not
  /// (and tagging all ~10k of them would bloat the file for no extra meaning).
  /// A separator every time the device or the connection changes says the same
  /// thing once, and keeps the per-line format byte-identical for any tooling
  /// that already parses it.
  Future<String> exportLog({
    String? deviceId,
    int? sessionId,
    List<String> header = const [],
    String Function(String? deviceId)? labelFor,
  }) async {
    final (where, args) = _scope(deviceId: deviceId, sessionId: sessionId);
    final rows = await _db.query(
      Db.tableDiagLog,
      where: where,
      whereArgs: args,
      orderBy: 'id ASC',
    );
    // design 0019: the log export had no content summary at all — the CSV has
    // had one since design 0009. Without it a recipient cannot tell a short
    // capture from a truncated one, and cannot see that a per-device scope
    // dropped the connect-time block (GATT dump, property flags) that lives on
    // unattributed rows until `link: connecting`.
    final excluded = deviceId == null ? 0 : await _countUnattributed();
    final out = <String>[
      ...header.map((h) => '# $h'),
      if (header.isNotEmpty) '# rows: ${rows.length}',
      // design 0013: say up front whether this file carries ground truth, and
      // which states it covers. Whoever receives it should not have to scan ten
      // thousand lines to find out that it has none.
      if (header.isNotEmpty) '# marks: ${_markSummary(rows)}',
      if (header.isNotEmpty && excluded > 0)
        '# excluded: $excluded unattributed rows',
    ];
    String? lastKey;
    var first = true;
    for (final row in rows) {
      final e = LogEntry.fromMap(row);
      // The build is part of the key: an app update between two connections
      // that happen to share a device must start a new section, or the label
      // would claim rows for a build that did not write them (design 0010).
      final key = '${e.deviceId}/${e.sessionId}/${e.appBuild}';
      if (key != lastKey) {
        lastKey = key;
        // No separator before the very first block when there is no header —
        // it would just be a stray line at the top of the file.
        if (!first || header.isNotEmpty) out.add('');
        out.add('# ---- ${_sectionLabel(e, labelFor)} ----');
      }
      out.add(e.toLogLine());
      first = false;
    }
    return out.join('\n');
  }

  static String _sectionLabel(
    LogEntry e,
    String Function(String? deviceId)? labelFor,
  ) {
    final id = e.deviceId;
    if (id == null) {
      // Recorded outside a connection (scan events) or before design 0006.
      return 'device=unattributed';
    }
    final label = labelFor?.call(id) ?? '';
    // NEVER the raw id: on Android that is the MAC address, and this text ends
    // up in a file the user shares. Fall back to the non-reversible digest.
    final device = 'device=${label.isEmpty ? shortDeviceHash(id) : label}';
    final session = e.sessionId == null ? '' : ' session=${e.sessionId}';
    // Omitted entirely when unknown (pre-0010 rows), which keeps their section
    // labels byte-identical to what they were before this field existed.
    final build = e.appBuild == null ? '' : ' app=${e.appBuild}';
    return '$device$session$build';
  }

  /// `6 (pb_out_a, pb_out_c_5v, …)` or `none`.
  ///
  /// Explicitly `none` rather than an omitted line: "this capture has no marks"
  /// is information, and a blank would read as a missing feature.
  static String _markSummary(List<Map<String, Object?>> rows) {
    final codes = <String>[];
    var total = 0;
    for (final r in rows) {
      final note = r['note'] as String?;
      if (note == null || !note.startsWith('mark: ')) continue;
      total++;
      final code = note.substring(6).split(' |').first.trim();
      if (code.isNotEmpty && !codes.contains(code)) codes.add(code);
    }
    if (total == 0) return 'none';
    return '$total (${codes.join(', ')})';
  }

  /// Rows with no device attribution — invisible to any per-device export.
  /// Counted directly; the filtered result set cannot see them.
  Future<int> _countUnattributed() async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM ${Db.tableDiagLog} WHERE device_id IS NULL',
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Number of distinct connections covered by a scope (for the export header).
  Future<int> sessionCount({String? deviceId}) async {
    final (where, args) = _scope(deviceId: deviceId);
    final r = await _db.rawQuery(
      'SELECT COUNT(DISTINCT session_id) AS n FROM ${Db.tableDiagLog}'
      '${where == null ? '' : ' WHERE $where'}',
      args,
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
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
