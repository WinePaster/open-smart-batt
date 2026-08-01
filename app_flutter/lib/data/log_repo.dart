/// OpenSmartBatt — diagnostic raw-BLE log repository (mockup settings).
///
/// Optional TX/RX hex packet log, only written when `AppSettings.rawPacketLog`
/// is ON (DEFAULT OFF). Capped/rotated by an approximate byte budget
/// (`AppSettings.logMaxBytes`, default 5 MB) — oldest rows are dropped first.
///
/// Rotation accounting is O(1) per insert: a running byte total is kept in
/// memory and only crossing the cap queries the database. It used to run
/// `SUM(LENGTH(...))` over the whole table on *every* insert, which at the
/// measured packet rate meant tens of full-table scans per second once the log
/// reached its cap. See `_lowWaterFraction` and `_estimatedBytes`.
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

  /// When a trim runs, it drops down to this fraction of the cap rather than to
  /// just under it, leaving headroom before the next one is due.
  ///
  /// Without headroom, a log sitting at its cap trims on *every* insert — the
  /// steady state, not an edge case, since the cap is reached after roughly two
  /// hours of capture. At 5 MB / ~54 B per row that is ~97,000 rows, and each
  /// trim is two `SUM(LENGTH(...))` scans plus a `COUNT(*)`. Measured packet
  /// rate is a median of 13/s (peak 22/s), so the old code ran on the order of
  /// 39 full-table scans per second, forever.
  ///
  /// At 0.9 each trim frees ~10% of the cap ≈ 9,700 rows ≈ 12 minutes of
  /// capture. Combined with [_estimatedBytes] that is one trim per ~9,700
  /// inserts instead of one per insert.
  static const double _lowWaterFraction = 0.9;

  /// Running estimate of [approxBytes], maintained by [insertLog] so the hot
  /// path costs no query at all. `null` means "unknown, re-ground on next use".
  ///
  /// Kept exact rather than merely close: [trimToBytes] and [clearLog] both
  /// re-ground it from the real query, so error cannot accumulate across trims.
  /// The one drift source between trims is `String.length` (UTF-16 code units)
  /// against SQLite `LENGTH()` (characters), which differ only for astral-plane
  /// text in `note` — and a late trim, not a broken cap, is the worst it can do.
  ///
  /// ⚠️ Assumes this repo is the only writer to `diag_log`. That holds in the
  /// app (one [LogRepo] per database); a second instance would keep its own
  /// estimate and could trim late.
  int? _estimatedBytes;

  /// Size this row contributes, matching [approxBytes]'s SQL exactly.
  static int _rowBytes(Map<String, Object?> map) =>
      ((map['hex'] as String?)?.length ?? 0) +
      ((map['note'] as String?)?.length ?? 0) +
      _rowOverheadBytes;

  /// Insert a log entry. If [maxBytes] is given, trim oldest rows afterwards
  /// to keep the estimated log size within budget. Returns the new row id.
  ///
  /// The budget check is O(1): the running total in [_estimatedBytes] is
  /// incremented locally and only crossing [maxBytes] touches the database.
  Future<int> insertLog(LogEntry entry, {int? maxBytes}) async {
    final map = Map<String, Object?>.from(entry.toMap())..remove('id');
    final id = await _db.insert(Db.tableDiagLog, map);
    if (maxBytes == null) {
      // Not tracking a budget on this call, so the running total no longer
      // accounts for every row. Drop it rather than let it read low.
      _estimatedBytes = null;
      return id;
    }
    final known = _estimatedBytes;
    // Seeding reads the real total, which already includes the row just
    // inserted; otherwise add it ourselves.
    final estimate =
        _estimatedBytes = known == null ? await approxBytes() : known + _rowBytes(map);
    if (estimate > maxBytes) {
      await trimToBytes(maxBytes);
    }
    return id;
  }

  /// Query log entries newest-first, optionally scoped to one unit and/or one
  /// connection. The table is a single global accumulator shared by every
  /// device, so a scope is the only way to get "just this unit" out of it.
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
  /// optionally scoped to one unit and/or one connection.
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
    // The log export long had no content summary at all, while the CSV did.
    // Without one a recipient cannot tell a short capture from a truncated one,
    // and cannot see that a per-device scope dropped the connect-time block
    // (GATT dump, property flags) that lives on unattributed rows until
    // `link: connecting`.
    final excluded = deviceId == null ? 0 : await _countUnattributed();
    // The other half of the same silent loss. The first pass counted the rows
    // with NO device, but [_scope] filters `device_id = ?`, which drops rows
    // belonging to OTHER units just as completely — and those said nothing at
    // all. A phone that has watched two packs exports one of them and the file
    // reads as if the other never existed.
    // Both numbers are reported, never summed: "recorded
    // before we knew the unit" and "belongs to a different unit" are different
    // facts, and only the first one is a defect of ours.
    //
    // Deliberately scope-wide, i.e. NOT narrowed by [sessionId] — same as
    // [excluded]. A session-scoped export's other rows are mostly this device's
    // own other connections, which the `connections=N` header line already
    // covers; counting them here would read as data loss when it is not.
    final fromOthers = deviceId == null ? 0 : await _countOtherDevices(deviceId);
    final out = <String>[
      ...header.map((h) => '# $h'),
      if (header.isNotEmpty) '# rows: ${rows.length}',
      // Say up front whether this file carries user-declared ground truth (the
      // capture marks), and which states it covers. Whoever receives it should
      // not have to scan ten thousand lines to find out that it has none.
      if (header.isNotEmpty) '# marks: ${_markSummary(rows)}',
      if (header.isNotEmpty && excluded > 0)
        '# excluded: $excluded unattributed rows',
      // Omitted at zero, like every other optional preamble field: an empty
      // field reads as a missing feature (export_header.dart's rule).
      if (header.isNotEmpty && fromOthers > 0)
        '# excluded: $fromOthers rows from other devices',
    ];
    String? lastKey;
    var first = true;
    for (final row in rows) {
      final e = LogEntry.fromMap(row);
      // The build is part of the key: an app update between two connections
      // that happen to share a device must start a new section, or the label
      // would claim rows for a build that did not write them.
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
      // Recorded outside a connection (scan events), or by a build that
      // predates per-device attribution.
      return 'device=unattributed';
    }
    final label = labelFor?.call(id) ?? '';
    // NEVER the raw id: on Android that is the MAC address, and this text ends
    // up in a file the user shares. Fall back to the non-reversible digest.
    final device = 'device=${label.isEmpty ? shortDeviceHash(id) : label}';
    final session = e.sessionId == null ? '' : ' session=${e.sessionId}';
    // Omitted entirely when unknown, which keeps the section labels of rows
    // recorded before this field existed byte-identical to what they were —
    // tooling that already parses the old separators does not break.
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

  /// Rows attributed to some OTHER unit than [deviceId] — invisible to this
  /// device's export for the opposite reason to [_countUnattributed]: they have
  /// an attribution, just not this one.
  ///
  /// `IS NOT NULL` is redundant — SQL three-valued logic already makes
  /// `NULL != 'AA'` evaluate to NULL rather than true, so unattributed rows
  /// never match — but it is spelled out because the partition between this
  /// count and [_countUnattributed] has to be exact and obviously so: every
  /// excluded row must land in exactly one of the two, and a reader should not
  /// have to recall the three-valued rule to be sure of it.
  Future<int> _countOtherDevices(String deviceId) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM ${Db.tableDiagLog} '
      'WHERE device_id IS NOT NULL AND device_id != ?',
      [deviceId],
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
  Future<int> clearLog() async {
    final n = await _db.delete(Db.tableDiagLog);
    _estimatedBytes = 0;
    return n;
  }

  /// Drop oldest rows until the estimated size is within [maxBytes].
  ///
  /// Trims down to [_lowWaterFraction] of the cap, not merely under it, so the
  /// next trim is thousands of inserts away instead of the next one. Removes
  /// rows in one batched delete (estimated from the average row size) then
  /// re-checks once, so worst case is two passes.
  ///
  /// On return [_estimatedBytes] always holds a freshly queried total — this is
  /// where the running estimate is re-grounded.
  Future<void> trimToBytes(int maxBytes) async {
    if (maxBytes <= 0) {
      await clearLog();
      return;
    }
    // Callers get what they asked for — under maxBytes — with the low-water
    // mark only deciding how far under.
    final target = (maxBytes * _lowWaterFraction).floor().clamp(1, maxBytes);
    for (var pass = 0; pass < 2; pass++) {
      final total = _estimatedBytes = await approxBytes();
      if (total <= target) return;
      final rows = await count();
      if (rows <= 0) {
        _estimatedBytes = 0;
        return;
      }
      final avg = (total / rows).ceil().clamp(1, total);
      // +1 row of slack so we drop strictly below the target.
      final toRemove = (((total - target) / avg).ceil() + 1).clamp(1, rows);
      await _deleteOldest(toRemove);
    }
    // Both passes deleted, so the last figure is stale. One more query keeps
    // the estimate exact on exit rather than leaving it reading high.
    _estimatedBytes = await approxBytes();
  }

  Future<void> _deleteOldest(int n) async {
    await _db.rawDelete(
      'DELETE FROM ${Db.tableDiagLog} WHERE id IN '
      '(SELECT id FROM ${Db.tableDiagLog} ORDER BY id ASC LIMIT ?)',
      [n],
    );
  }
}
