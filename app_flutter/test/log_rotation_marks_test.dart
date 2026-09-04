// FB-110 — log rotation used to delete the user's capture marks, and the export
// never said the file had been truncated.
//
// ---------------------------------------------------------------------------
// What was wrong
// ---------------------------------------------------------------------------
//
//   1. `_deleteOldest` was `DELETE … ORDER BY id ASC LIMIT ?` with no
//      exception. A capture mark is an ORDINARY ROW whose `note` starts with
//      `mark: ` — nothing in the schema tells it apart — so the byte cap ate
//      them like any other packet. One reporter's five marks of 2026-08-19 were
//      gone by the time they exported: the file said `marks: none`.
//
//      🔑 That is not a lost packet. Every other row in this table is machine
//      output that the device will produce again; a mark is a HUMAN DECLARATION
//      about a moment that has passed, and it is the one thing in the file that
//      cannot be re-derived from anything.
//
//   2. Nothing in the exported preamble said the front of the log was missing.
//      A reader subtracted two frame counters across a rotation gap and got
//      **-495,912** — a number that only looks like data corruption.
//
// ---------------------------------------------------------------------------
// What the fix promises, and what it deliberately does NOT
// ---------------------------------------------------------------------------
//
//   * marks are stepped over by rotation — a PREFERENCE, not a guarantee;
//   * the byte cap always holds. If a log were to consist of almost nothing but
//     marks, protecting them would stop rotation working altogether (and
//     `insertLog` would then run two full-table scans on every single insert),
//     so protection degrades in that one direction. The test below has to build
//     that state deliberately; at the 100 MiB default it is ~97,000 rows away;
//   * every export states `rotated:`, `none` included.
//
// CLEAN-ROOM: expectations derive from this project's own source.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late LogRepo logs;

  setUp(() async {
    db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    logs = LogRepo(db.db);
  });
  tearDown(() async => db.close());

  /// One ordinary RX packet row.
  Future<void> packet(int i) => logs.insertLog(LogEntry(
        timestamp: DateTime.utc(2026, 8, 19, 10, 0, 0).add(Duration(seconds: i)),
        direction: LogDirection.rx,
        hex: 'b81901040000ccff',
        deviceId: 'AA',
      ));

  /// One capture mark, written exactly the way `capture_wizard.dart` writes it.
  Future<void> mark(CaptureMark m, String label) =>
      logs.insertLog(LogEntry.event(m.logLine(label), deviceId: 'AA'));

  /// The `marks:` summary line of an export, `# ` stripped.
  Future<String> markLine() async {
    final out = await logs.exportLog(header: const ['scope: all']);
    return out
        .split('\n')
        .firstWhere((l) => l.startsWith('# marks: '))
        .substring(2);
  }

  /// The `rotated:` line of an export, `# ` stripped.
  Future<String> rotatedLine() async {
    final out = await logs.exportLog(header: const ['scope: all']);
    return out
        .split('\n')
        .firstWhere((l) => l.startsWith('# rotated: '))
        .substring(2);
  }

  // =========================================================================
  group('🔴 rotation steps over capture marks', () {
    test('the five marks survive; the ordinary rows around them do not',
        () async {
      // The reporter's shape: marks made early in a long capture, then hours of
      // packets on top of them. Under the old rule the marks were the FIRST
      // thing dropped, precisely because they were the oldest.
      await mark(CaptureMark.powerBankOutA, 'A out');
      await mark(CaptureMark.powerBankOutC5v, 'C 5V');
      await mark(CaptureMark.powerBankOutCPd, 'C PD');
      await mark(CaptureMark.powerBankIn, 'charging');
      await mark(CaptureMark.powerBankIdle, 'idle');
      for (var i = 0; i < 300; i++) {
        await packet(i);
      }
      final before = await logs.approxBytes();
      expect(await markLine(), startsWith('marks: 5 ('),
          reason: 'the premise: five marks are in there to begin with');

      // Ask for well under half of it.
      await logs.trimToBytes(before ~/ 3);

      // 🔑 The assertion FB-110 exists for.
      expect(await markLine(), startsWith('marks: 5 ('),
          reason: 'rotation deleted the user ground truth again');
      // …and it really did rotate: the cap is enforced, and packets went.
      expect(await logs.approxBytes(), lessThanOrEqualTo(before ~/ 3));
      expect(await logs.count(), lessThan(305));
      final surviving = await logs.queryLog();
      expect(
        surviving.where((e) => e.note?.startsWith(LogRepo.markNotePrefix) ?? false),
        hasLength(5),
      );
    });

    test('the marks are kept even when they are the very oldest rows',
        () async {
      // Same rows, ids 1..5, i.e. exactly what `ORDER BY id ASC LIMIT n` takes
      // first. If the WHERE clause were dropped this is what breaks.
      await mark(CaptureMark.packIdle, 'parked');
      for (var i = 0; i < 200; i++) {
        await packet(i);
      }
      await logs.trimToBytes((await logs.approxBytes()) ~/ 4);
      final rows = await logs.queryLog();
      expect(rows.first.id, greaterThan(1),
          reason: 'newest-first: something must have been dropped at all');
      expect(rows.map((e) => e.note).where((n) => n != null && n.startsWith('mark: ')),
          hasLength(1));
    });
  });

  // =========================================================================
  group('🔑 the byte cap still holds — protection is a preference', () {
    test('a log made of nothing BUT marks still rotates', () async {
      // The degenerate state. Left protected, `trimToBytes` would delete
      // nothing, `insertLog` would call it on every insert (two full-table
      // scans each), and the log would grow past the cap for ever. The promise
      // the setting makes is the byte cap, so the cap wins here.
      for (var i = 0; i < 40; i++) {
        await mark(CaptureMark.packIdle, 'idle $i');
      }
      final before = await logs.approxBytes();
      final budget = before ~/ 4;

      await logs.trimToBytes(budget);

      expect(await logs.approxBytes(), lessThanOrEqualTo(budget),
          reason: 'rotation must never become a no-op — that is the failure '
              'mode protecting marks unconditionally would create');
      expect(await logs.count(), lessThan(40));
      // Still says something honest about what is left.
      expect(await markLine(), startsWith('marks: '));
    });

    test('trimToBytes terminates rather than looping when marks dominate',
        () async {
      // Both passes plus the fallback, on a table where the protected candidate
      // set is empty from the first query. The guarantee under test is that
      // this RETURNS.
      for (var i = 0; i < 12; i++) {
        await mark(CaptureMark.packCharging, 'charging $i');
      }
      await logs.trimToBytes(1).timeout(const Duration(seconds: 5));
      expect(await logs.approxBytes(), lessThanOrEqualTo(1));
    });
  });

  // =========================================================================
  group('🔴 the export says whether it was truncated', () {
    test('an untouched log says none — the line is never omitted', () async {
      await packet(0);
      expect(await rotatedLine(), 'rotated: none');
    });

    test('after rotation it says how many rows went', () async {
      for (var i = 0; i < 200; i++) {
        await packet(i);
      }
      final before = await logs.count();
      await logs.trimToBytes((await logs.approxBytes()) ~/ 4);
      final after = await logs.count();
      final dropped = before - after;
      expect(dropped, greaterThan(0), reason: 'the premise');
      expect(await rotatedLine(),
          'rotated: dropped=$dropped oldest rows (log size cap)');
    });

    test('🔵 a log the USER cleared is not reported as rotated', () async {
      // Otherwise every export after 「清除日誌」 would blame the app for rows
      // the owner deleted on purpose — a different lie in the same line.
      for (var i = 0; i < 20; i++) {
        await packet(i);
      }
      await logs.clearLog();
      await packet(999);
      expect(await rotatedLine(), 'rotated: none');
      expect((await logs.queryLog()).single.id, 1,
          reason: 'the AUTOINCREMENT high-water mark is reset with the rows');
    });

    test('🔑 it is a statement about the LOG, not about the scope', () async {
      // A per-device export whose unit connected late starts at a high id. That
      // is not truncation, and reading it as truncation would put a false
      // `rotated:` on most files ever exported.
      for (var i = 0; i < 10; i++) {
        await packet(i);
      }
      await logs.insertLog(LogEntry(
        timestamp: DateTime.utc(2026, 8, 19, 11),
        direction: LogDirection.rx,
        hex: 'b81901040000ccff',
        deviceId: 'BB',
      ));
      final out =
          await logs.exportLog(deviceId: 'BB', header: const ['scope: BB']);
      expect(out, contains('# rotated: none'));
    });
  });

  // =========================================================================
  group('🔑 one predicate, read by both halves', () {
    test('the reader and the deleter agree on case', () async {
      // `_markSummary` uses a case-SENSITIVE `String.startsWith`; SQLite's
      // `LIKE` is case-INSENSITIVE over ASCII. Had the delete used `LIKE`, a
      // row noted `MARK: …` would have been protected by rotation and counted
      // by nothing — a row the log keeps for ever and never mentions.
      await logs.insertLog(LogEntry.event('MARK: not a real mark'));
      for (var i = 0; i < 120; i++) {
        await packet(i);
      }
      expect(await markLine(), 'marks: none',
          reason: 'the reader does not count it');
      await logs.trimToBytes((await logs.approxBytes()) ~/ 4);
      final rows = await logs.queryLog();
      expect(rows.any((e) => e.note == 'MARK: not a real mark'), isFalse,
          reason: 'so the deleter must not protect it either');
    });

    test('the prefix constant is the one the wizard writes', () async {
      expect(CaptureMark.packIdle.logLine('x'),
          startsWith(LogRepo.markNotePrefix));
    });
  });
}
