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
//   3. 🔴 And then the fix for (1) broke the fix for (2). `droppedByRotation`
//      was `MIN(id) - 1`, which is the count of dropped rows only while the
//      oldest surviving row is the oldest row ever written. Protecting marks is
//      exactly what stops that being true: the first mark the user made now
//      survives for ever, `MIN(id)` freezes on it, and the header reported
//      **0** on a log that had just lost 220 of 305 rows. Now
//      ~~`MAX(id) - COUNT(*)`~~ **`sqlite_sequence.seq - COUNT(*)`** — ids ever
//      ISSUED minus rows still here — which does not care where the protected
//      rows sit, and unlike `MAX(id)` does not fall when the newest row is one
//      of the ones deleted. That last difference is a whole case: see
//      「the degenerate shape」 below.
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
      // The mark is row id 1, i.e. exactly what `ORDER BY id ASC LIMIT n` takes
      // first. If the WHERE clause were dropped this is what breaks.
      await mark(CaptureMark.packIdle, 'parked');
      for (var i = 0; i < 200; i++) {
        await packet(i);
      }
      final before = await logs.count();
      await logs.trimToBytes((await logs.approxBytes()) ~/ 4);
      final rows = await logs.queryLog();

      // 🔴 The premise, and it has to be able to FAIL. This used to read
      // `rows.first.id, greaterThan(1)` — but `queryLog()` is newest-first, so
      // `rows.first.id` is `MAX(id)`, which is above 1 the moment a second row
      // exists whether rotation deleted anything or not. Made the trim a no-op
      // and the case stayed green.
      expect(rows, hasLength(lessThan(before)),
          reason: 'rotation deleted nothing at all — the mark sitting at id 1 '
              'must not stop the ordinary rows above it from going');
      // …and the protected mark really is the oldest surviving row.
      expect(rows.last.id, 1,
          reason: 'the mark was row id 1 and must still be there');
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

    test('🔴 …and it still says so when the log HAS marks in it', () async {
      // 🔑 THE CASE THE OTHER TEN MISSED, and the reason it was missed is
      // structural: every case with marks in it asserted on `marks:` and never
      // looked at `rotated:`, and every case that read `rotated:` inserted no
      // marks. Nothing here was untested — the two halves were tested apart,
      // and the defect lived exactly in the seam.
      //
      // The two halves of FB-110 broke each other. Protecting the marks is what
      // made the count lie: `MIN(id) - 1` reads the oldest SURVIVING id, the
      // user's first mark is now never deleted, so `MIN(id)` freezes at 1 and
      // the header reported `none` on a file that had lost 220 of its 305 rows.
      await mark(CaptureMark.powerBankOutA, 'A out');
      await mark(CaptureMark.powerBankOutC5v, 'C 5V');
      await mark(CaptureMark.powerBankOutCPd, 'C PD');
      await mark(CaptureMark.powerBankIn, 'charging');
      await mark(CaptureMark.powerBankIdle, 'idle');
      for (var i = 0; i < 300; i++) {
        await packet(i);
      }
      final before = await logs.count();
      await logs.trimToBytes((await logs.approxBytes()) ~/ 3);
      final after = await logs.count();
      final dropped = before - after;

      expect(dropped, greaterThan(0), reason: 'the premise: it did rotate');
      // Half one: the marks are still there…
      expect(await markLine(), startsWith('marks: 5 ('));
      // 🔴 …which is precisely what used to make half two lie. This assertion
      // is the fault line: the oldest surviving row is mark id 1, so anything
      // derived from `MIN(id)` reports 0 here no matter how much went.
      expect((await logs.queryLog()).last.id, 1,
          reason: 'the premise of the defect: MIN(id) is pinned at 1 by the '
              'protected mark, so a MIN(id)-derived count cannot see the loss');
      // Half two, now measured against the same rows the first half counted.
      expect(await rotatedLine(),
          'rotated: dropped=$dropped oldest rows (log size cap)');
    });

    test('🔴 a mark in the MIDDLE does not truncate the count either',
        () async {
      // The second measured shape: the mark is not the oldest row, so `MIN(id)`
      // is not frozen at 1 — it is frozen at the mark, and the count comes out
      // as "everything before the mark" instead of everything that went. The
      // reported figure is plausible, which is worse than obviously zero.
      for (var i = 0; i < 100; i++) {
        await packet(i);
      }
      await mark(CaptureMark.packIdle, 'parked');
      for (var i = 100; i < 900; i++) {
        await packet(i);
      }
      final before = await logs.count();
      await logs.trimToBytes((await logs.approxBytes()) ~/ 4);
      final after = await logs.count();
      final dropped = before - after;

      expect(dropped, greaterThan(101),
          reason: 'the premise: rotation reached past the mark at id 101');
      expect((await logs.queryLog()).last.id, 101,
          reason: 'the protected mark is the oldest survivor, so MIN(id)-1 '
              'would report exactly 100 whatever the real figure is');
      expect(await rotatedLine(),
          'rotated: dropped=$dropped oldest rows (log size cap)');
    });

    test(
        '🔴 the degenerate shape: mostly marks, and the NEWEST rows go too',
        () async {
      // 🔑 THE CASE THAT KILLED `MAX(id) - COUNT(*)`. When the table is almost
      // entirely marks, `trimToBytes`'s protected pass runs out of non-mark
      // rows and falls back to an unprotected delete — so the rows that go
      // include the newest one, and `MAX(id)` DROPS WITH IT. A count derived
      // from the surviving rows therefore under-reports by exactly the number
      // of rows deleted off the top.
      //
      // `sqlite_sequence.seq` is a property of the table's history rather than
      // of its surviving rows, so nothing but `clearLog` moves it down — which
      // is why this test can assert the real figure instead of documenting a
      // gap. Under `MAX(id) - COUNT(*)` this reports 3; the truth is 6.
      await mark(CaptureMark.powerBankOutA, 'A out');
      await mark(CaptureMark.powerBankOutC5v, 'C 5V');
      await mark(CaptureMark.powerBankOutCPd, 'C PD');
      await mark(CaptureMark.powerBankIn, 'charging');
      await mark(CaptureMark.powerBankIdle, 'idle');
      for (var i = 0; i < 3; i++) {
        await packet(i);
      }
      expect(await logs.count(), 8);

      // Aim the byte budget at "remove 6 of the 8", derived from the rows this
      // test actually wrote rather than from a hard-coded size — `trimToBytes`
      // computes its batch from the measured average row.
      final total = await logs.approxBytes();
      final avg = (total / 8).ceil();
      final maxBytes = ((total - (avg * 4.5).round()) / 0.9).ceil();
      await logs.trimToBytes(maxBytes);

      final after = await logs.count();
      expect(after, 2, reason: 'the premise: 6 of the 8 rows went');
      // The fallback took marks off the FRONT and the protected pass had
      // already taken every packet, including the newest row in the table.
      expect((await logs.queryLog()).first.id, 5,
          reason: 'the newest surviving row is a mark, so MAX(id) has fallen '
              'from 8 to 5 — that fall is the whole defect');
      expect(await rotatedLine(),
          'rotated: dropped=6 oldest rows (log size cap)',
          reason: 'six rows went; MAX(id) - COUNT(*) would say three');
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
