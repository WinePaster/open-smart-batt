/// OpenSmartBatt — diagnostic raw-BLE log repository (mockup settings).
///
/// Optional TX/RX hex packet log, only written when `AppSettings.rawPacketLog`
/// is ON (DEFAULT OFF). Capped/rotated by an approximate byte budget
/// (`AppSettings.logMaxBytes`) — oldest rows are dropped first, EXCEPT the
/// user's capture marks, which rotation steps over (FB-110). Every export says
/// whether it was rotated, so a recipient never has to infer it.
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
import 'device_id_aliases.dart';

/// Append-only-ish log with size-based rotation over the `diag_log` table.
class LogRepo {
  LogRepo(this._db);

  final Database _db;

  /// design 0077 path A (FB-93) — see `device_id_aliases.dart`. Wired by the
  /// composition root, null until then.
  DeviceIdAliases? idAliases;

  /// Fixed per-row overhead (bytes) approximating timestamp + direction +
  /// separators when rendered via [LogEntry.toLogLine], used for rotation math.
  static const int _rowOverheadBytes = 40;

  /// What a capture mark's `note` starts with — see [CaptureMark.logLine].
  ///
  /// 🔑 **ONE definition, read by both sides (FB-110).** [_markSummary] counts
  /// marks with it and [_deleteOldest] protects them with it. They were written
  /// three months apart and only one of them existed until FB-110, which is
  /// exactly how the two halves of a rule drift: rotation deleted rows the
  /// summary was still counting, and the export then said `marks: none` about a
  /// capture whose owner had made five of them by hand.
  static const String markNotePrefix = 'mark: ';

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
      // design 0077 path A (FB-93) — the same widening as
      // `history_repo._scope`, and it has to be the same or a rebound unit's
      // diagnostic log and its history would disagree about which rows are
      // hers. `scopeIdsFor` is shared for exactly that reason.
      final ids = scopeIdsFor(deviceId, idAliases);
      if (ids.length == 1) {
        clauses.add('device_id = ?');
      } else {
        clauses.add('device_id IN (${List.filled(ids.length, '?').join(',')})');
      }
      args.addAll(ids);
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
    // 🔴 FB-110. Whether this file starts at the beginning of the log, or at
    // whatever survived the byte cap.
    //
    // A recipient who does not know the front is missing does arithmetic across
    // the gap — a reader of one of these files subtracted two frame counters
    // over a rotation and got **-495,912**. Emitted UNCONDITIONALLY, `none`
    // included: a line that appears only when there is something to report
    // makes its absence mean both "nothing was dropped" and "an older build
    // wrote this", which is the same rule `marks:` already follows.
    final dropped = await droppedByRotation();
    final out = <String>[
      ...header.map((h) => '# $h'),
      if (header.isNotEmpty) '# rows: ${rows.length}',
      if (header.isNotEmpty)
        // ⚠️ WHOLE-LOG, even in a device-scoped export — `# rows:` above it is
        // scoped and this is not, and a reader who took them as the same scope
        // would conclude THIS unit's capture lost its front. Said in the line
        // itself rather than left to the reader: one phone can rotate away half
        // a million rows of unit A while unit B's few thousand are all intact.
        '# rotated: ${dropped == 0 ? 'none (whole log)' : 'dropped=$dropped '
            'oldest rows from the whole log, not just this scope '
            '(log size cap)'}',
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
      if (note == null || !note.startsWith(markNotePrefix)) continue;
      total++;
      final code =
          note.substring(markNotePrefix.length).split(' |').first.trim();
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
  ///
  /// 🔵 FB-110: also resets the rotation tally, so a user who emptied their own
  /// log does not find every later export headed `rotated: dropped=…` blaming
  /// the app for rows they deleted on purpose.
  ///
  /// ⚠️ The `sqlite_sequence` delete is kept, but it no longer carries that
  /// argument — nothing reads the sequence since v25. It stays because ids
  /// restarting at 1 on a deliberately emptied log is the behaviour shipped in
  /// v0.7.42, and changing it would move what an export's `id` column means for
  /// no gain.
  Future<int> clearLog() async {
    final n = await _db.delete(Db.tableDiagLog);
    await _db.delete('sqlite_sequence',
        where: 'name = ?', whereArgs: [Db.tableDiagLog]);
    await _db.rawUpdate(
      'UPDATE ${Db.tableLogStats} SET rotated_count = 0 WHERE id = ?',
      [Db.logStatsRowId],
    );
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
      // 🔴 FB-110. Marks first-class: the ordinary path steps over them.
      final dropped = await _deleteOldest(toRemove, protectMarks: true);
      // 🔑 THE BOUNDARY, and it is the whole judgement of FB-110.
      //
      // A shortfall here can mean only one thing. `toRemove` is clamped to the
      // TOTAL row count, and the protected delete takes the oldest `n`
      // non-mark rows — so it comes up short if and only if fewer than
      // `toRemove` non-mark rows exist at all, i.e. the table is by now mostly
      // capture marks. In that state protecting them would mean the cap simply
      // stops being enforced: [insertLog] would call this on EVERY insert (two
      // full-table scans each), the log would grow past `logMaxBytes` without
      // limit, and the user would have neither their marks nor a working log.
      //
      // So protection is a PREFERENCE, not a guarantee, and it degrades in the
      // one direction that keeps the promise the setting makes: the byte cap
      // always holds. In practice the fallback is unreachable — marks are a
      // handful of rows against ~97,000 at the 100 MiB default — and the test
      // that pins it has to build the state deliberately.
      if (dropped < toRemove) {
        await _deleteOldest(toRemove - dropped, protectMarks: false);
      }
    }
    // Both passes deleted, so the last figure is stale. One more query keeps
    // the estimate exact on exit rather than leaving it reading high.
    _estimatedBytes = await approxBytes();
  }

  /// Delete the [n] oldest rows and return how many actually went.
  ///
  /// With [protectMarks] the candidate set excludes capture-mark rows — the
  /// user's own ground truth, which they cannot re-record after the fact
  /// (FB-110). `substr(note, 1, 6) = 'mark: '` rather than `LIKE 'mark:%'`
  /// deliberately: SQLite's `LIKE` is case-insensitive over ASCII, and the
  /// reading side ([_markSummary]) uses a case-SENSITIVE `String.startsWith`.
  /// Two predicates that disagree on `MARK: ` would protect a row nothing
  /// counts, or count one nothing protects.
  Future<int> _deleteOldest(int n, {required bool protectMarks}) async {
    final keep = protectMarks
        ? 'WHERE note IS NULL OR substr(note, 1, ${markNotePrefix.length}) != ? '
        : '';
    final gone = await _db.rawDelete(
      'DELETE FROM ${Db.tableDiagLog} WHERE id IN '
      '(SELECT id FROM ${Db.tableDiagLog} $keep'
      'ORDER BY id ASC LIMIT ?)',
      [if (protectMarks) markNotePrefix, n],
    );
    // FB-110 (v25). THE counting point, and the only one: every caller of this
    // method is rotation. `clearLog` deletes by a different path precisely so
    // that a deliberate emptying is not counted as loss.
    if (gone > 0) await _bumpRotatedCount(gone);
    return gone;
  }

  /// Add [n] to the persisted rotation tally.
  ///
  /// A single `UPDATE … SET x = x + ?` rather than read-modify-write: the trim
  /// loop calls [_deleteOldest] twice in a pass and [insertLog] can re-enter
  /// it, and a Dart-side increment would lose one of two overlapping bumps.
  Future<void> _bumpRotatedCount(int n) => _db.rawUpdate(
        'UPDATE ${Db.tableLogStats} '
        'SET rotated_count = rotated_count + ? WHERE id = ?',
        [n, Db.logStatsRowId],
      );

  /// How many rows were dropped off the FRONT of the log, or 0 for a log that
  /// has never rotated.
  ///
  /// 🔑 Derived from the `id` sequence, not from a counter: `diag_log.id` is
  /// `INTEGER PRIMARY KEY AUTOINCREMENT`, so SQLite keeps its own high-water
  /// mark for the table in `sqlite_sequence.seq` — the highest id it has ever
  /// ISSUED, which never goes down on a delete and is therefore how many rows
  /// have EVER existed since the last [clearLog]. Subtract how many are left and
  /// what remains is what rotation took. That needs no new column — and it
  /// survives the app being restarted, which an in-memory flag would not.
  ///
  /// 🔴 **It used to read `MIN(id) - 1`, and that was wrong the moment marks
  /// became protected.** ~~the lowest surviving id is therefore exactly one
  /// more than the number of rows that have gone~~ — [_deleteOldest] with
  /// `protectMarks: true` steps OVER capture marks, so the oldest surviving row
  /// is the user's first mark and `MIN(id)` freezes there for ever. Measured on
  /// the two shapes FB-110 is about:
  ///
  ///   * 5 marks, then 300 packets, trimmed → **220 rows deleted**, `MIN(id)`
  ///     still 1, reported **0**, and the header said `rotated: none` on a file
  ///     that had lost two thirds of its front;
  ///   * 1,000 packets, one mark, 9,000 packets, trimmed → **8,000 deleted**,
  ///     reported **1,000**.
  ///
  /// The two halves of FB-110 broke each other: protecting the marks is what
  /// made the `rotated:` line lie.
  ///
  /// ✅ **It reads `sqlite_sequence.seq`, NOT `MAX(id)`, and that is the whole
  /// difference between right and nearly right.**
  /// ~~⚠️ One case this still under-reports … if the table is by now almost
  /// entirely marks, the protected pass can take every non-mark row INCLUDING
  /// the newest, and `MAX(id)` then drops with it — 5 marks + 3 packets trimmed
  /// by 6 reports 3, not 6 … it is simply not fixed~~ — **fixed, by changing
  /// the formula rather than by accepting the gap** (owner's ruling). `MAX(id)`
  /// is a property of the SURVIVING rows, so deleting the newest row moves it;
  /// `sqlite_sequence.seq` is a property of the TABLE'S HISTORY, so nothing but
  /// [clearLog] moves it down. In that degenerate shape the sequence still
  /// reads 8 while 2 rows survive ⇒ **6, which is what actually went.**
  ///
  /// ~~The migration this needed already existed: `Db.schemaVersion` v24~~
  /// 🔴 **v24 is vestigial since v25** — nothing reads `sqlite_sequence`.
  ///
  /// ⚠️ Deliberately WHOLE-TABLE, never scoped. A per-device export's oldest
  /// row has a high id simply because that unit connected late; reading that as
  /// truncation would put a false `rotated:` on most files.
  ///
  /// [clearLog] resets the tally, so a log the user cleared themselves reads as
  /// "not rotated" rather than reporting the cleared rows as losses.
  Future<int> droppedByRotation() async {
    // FB-110 (v25). A COUNTER, not arithmetic over ids.
    //
    // 🔴 The previous two shapes (`MAX(id) - COUNT(*)`, then
    // `sqlite_sequence.seq - COUNT(*)`) both inferred loss from the id space,
    // and neither could tell rotation from the user's own `clearLog`. The v24
    // migration only reached databases whose log happened to be EMPTY at
    // upgrade time — and it is not, because `bootstrap()` writes two rows on
    // every launch regardless of `raw_packet_log`. So "cleared it, opened the
    // app, upgraded" kept reading as loss. See [Db.schemaVersion] v25.
    final r = await _db.rawQuery(
      'SELECT rotated_count AS n FROM ${Db.tableLogStats} WHERE id = ?',
      [Db.logStatsRowId],
    );
    if (r.isEmpty) return 0;
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

}
