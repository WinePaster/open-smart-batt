// Schema v24 — FB-110's migration: realign `sqlite_sequence` for `diag_log`.
//
// WHY THIS FILE EXISTS, and it is a fifth reason on top of v18/19/20/21/22.
// Those guard a setting, invisible columns, a one-shot rewrite, and the
// NULL-vs-number distinction. This one guards a number that is PRINTED IN A
// FILE THE USER SENDS TO SOMEBODY ELSE, and whose whole purpose is to be
// believed.
//
// ---------------------------------------------------------------------------
// The defect the migration exists for
// ---------------------------------------------------------------------------
//
// `LogRepo.clearLog` now resets the table's AUTOINCREMENT high-water mark, so a
// log the user emptied on purpose no longer reads as rotated. That is a code
// change, and code changes are retro-active; the DATA is not. Every database
// cleared under v0.7.42 or earlier still carries the old mark, so the first
// export after upgrading would be headed
//
//     # rotated: dropped=N oldest rows (log size cap)
//
// where N is exactly the number of rows the owner deleted themselves — a lie
// about the app's own behaviour, addressed to whoever receives the file, and it
// would repeat on every export until they cleared the log again.
//
// ---------------------------------------------------------------------------
// What is asserted, and each is a way this goes wrong
// ---------------------------------------------------------------------------
//
//   * 🔴 **The stale mark is gone.** The fixture is built the way the old
//     `clearLog` left a database — rows inserted, then all deleted, sequence
//     untouched — and the premise is asserted BEFORE the upgrade so the case
//     cannot pass by accident on a fixture that never had the problem.
//   * 🔴 **A genuinely rotated log keeps its count.** The opposite error: a
//     migration that simply zeroed the mark would erase real truncation from
//     every database that had rotated honestly, and `rotated:` would then
//     under-report instead of over-reporting. The 500 rows in that fixture
//     really did go.
//   * 🔴 **A database that has never written a `diag_log` row survives it.**
//     There is no `sqlite_sequence` row to update; the statement must be a
//     no-op rather than an error on first launch after upgrading.
//   * 🔴 **A fresh install is unaffected** — `_createStatements` and
//     `_onUpgrade` must not disagree about the starting state.
//
// The v23 schema below is written out BY HAND, same discipline as
// `schema_v11/v17/v20/v21/v22`: a fixture that borrows `_createStatements` from
// the code under test passes whatever that code does, including the bug.
//
// CLEAN-ROOM: expectations derive from this project's own source.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The v23 shape — what a phone running v0.7.42 has on disk.
const List<String> _v23Schema = <String>[
  '''
  CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    pvlt REAL, svlt REAL, ampere REAL, temperature INTEGER,
    dvol1 REAL, dvol2 REAL, dvol3 REAL, dvol4 REAL,
    soh INTEGER, mode INTEGER, twf INTEGER, serial TEXT, soc INTEGER,
    device_id TEXT, samples INTEGER, app_build TEXT,
    speed REAL, accel REAL, g_long REAL, g_lat REAL,
    bucket_s INTEGER NOT NULL DEFAULT 60
  )''',
  'CREATE INDEX idx_history_ts ON history (timestamp)',
  'CREATE INDEX idx_history_device ON history (device_id)',
  'CREATE INDEX idx_history_device_ts ON history (device_id, timestamp)',
  '''
  CREATE TABLE saved_devices (
    id TEXT PRIMARY KEY,
    alias TEXT NOT NULL DEFAULT '',
    name TEXT NOT NULL DEFAULT '',
    last_seen INTEGER,
    last_value REAL,
    stale INTEGER NOT NULL DEFAULT 0,
    product_class TEXT NOT NULL DEFAULT 'unknown',
    display_layout TEXT,
    mac TEXT,
    serial TEXT,
    declared_category TEXT,
    declared_model TEXT,
    declared_region TEXT,
    declared_label TEXT,
    declared_capacity TEXT,
    declared_note TEXT,
    declared_at INTEGER,
    declared_retrofit INTEGER,
    alert_enabled INTEGER NOT NULL DEFAULT 1,
    alert_ov REAL,
    alert_uv REAL,
    alert_ot REAL,
    alert_muted_until INTEGER,
    former_ids TEXT
  )''',
  '''
  CREATE TABLE settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    auto_reconnect INTEGER NOT NULL DEFAULT 1,
    poll_interval_ms INTEGER NOT NULL DEFAULT 1000,
    background_keep_alive INTEGER NOT NULL DEFAULT 0,
    background_monitoring INTEGER NOT NULL DEFAULT 1,
    background_monitoring_ios INTEGER NOT NULL DEFAULT 0,
    dark_theme INTEGER NOT NULL DEFAULT 1,
    theme_mode TEXT,
    lang TEXT NOT NULL DEFAULT 'zhHant',
    temp_unit TEXT NOT NULL DEFAULT 'celsius',
    auto_log INTEGER NOT NULL DEFAULT 1,
    raw_packet_log INTEGER NOT NULL DEFAULT 0,
    retention TEXT NOT NULL DEFAULT 'forever',
    log_max_bytes INTEGER NOT NULL DEFAULT ${20 * 1024 * 1024},
    speed_detection INTEGER NOT NULL DEFAULT 0,
    speed_unit TEXT NOT NULL DEFAULT 'kmh',
    home_layout TEXT,
    g_meter_enabled INTEGER NOT NULL DEFAULT 0,
    g_calibration TEXT,
    app_mode TEXT,
    accent_theme TEXT,
    alerts_enabled INTEGER NOT NULL DEFAULT 0,
    alert_sustain_sec INTEGER NOT NULL DEFAULT 5,
    alert_repeat_min INTEGER NOT NULL DEFAULT 15,
    alert_max_per_event INTEGER NOT NULL DEFAULT 3
  )''',
  '''
  CREATE TABLE diag_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    direction TEXT NOT NULL,
    hex TEXT NOT NULL,
    note TEXT,
    device_id TEXT,
    session_id INTEGER,
    app_build TEXT
  )''',
  'CREATE INDEX idx_diag_log_ts ON diag_log (timestamp)',
  'CREATE INDEX idx_diag_log_device ON diag_log (device_id)',
  '''
  CREATE TABLE device_facts (
    id TEXT PRIMARY KEY,
    name TEXT,
    product_class TEXT,
    mac TEXT,
    serial TEXT,
    first_seen INTEGER NOT NULL,
    last_seen INTEGER NOT NULL
  )''',
  'CREATE INDEX idx_device_facts_mac ON device_facts (mac)',
  '''
  CREATE TABLE autoconnect_arm (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    device_id TEXT NOT NULL,
    armed_at INTEGER NOT NULL,
    app_build TEXT,
    session_id INTEGER
  )''',
];

void main() {
  setUpAll(sqfliteFfiInit);

  /// The AUTOINCREMENT high-water mark SQLite is holding for `diag_log`, or
  /// null when it has no row for the table at all.
  Future<int?> sequenceOf(dynamic db) async {
    final rows = await db.rawQuery(
      "SELECT seq FROM sqlite_sequence WHERE name = 'diag_log'",
    );
    if (rows.isEmpty) return null;
    return (rows.first['seq'] as num?)?.toInt();
  }

  /// The `rotated:` line of an export, `# ` stripped.
  Future<String> rotatedLine(LogRepo logs) async {
    final out = await logs.exportLog(header: const ['scope: all']);
    return out
        .split('\n')
        .firstWhere((l) => l.startsWith('# rotated: '))
        .substring(2);
  }

  /// One ordinary RX packet row.
  Future<void> packet(LogRepo logs, int i) => logs.insertLog(LogEntry(
        timestamp: DateTime.utc(2026, 9, 5, 10).add(Duration(seconds: i)),
        direction: LogDirection.rx,
        hex: 'b81901040000ccff',
        deviceId: 'AA',
      ));

  /// Build a real v23 file on disk, hand it to [seed], then open it with the
  /// current app so the 23 → 24 branch actually runs. [seed] gets the raw
  /// legacy handle, i.e. it can write ids and `sqlite_sequence` directly, which
  /// is the whole point — the state under test is one no current code path can
  /// produce any more.
  Future<AppDatabase> upgradeFromV23(
    String tag,
    Future<void> Function(dynamic db) seed,
  ) async {
    final dir = await Directory.systemTemp.createTemp('osb_$tag');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'v23.db');
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 23,
        onCreate: (db, _) async {
          for (final stmt in _v23Schema) {
            await db.execute(stmt);
          }
        },
      ),
    );
    await legacy.insert('settings', {
      'id': 1,
      'lang': 'zhHant',
      'retention': 'forever',
    });
    await seed(legacy);
    await legacy.close();
    final upgraded =
        await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    addTearDown(upgraded.close);
    return upgraded;
  }

  /// Exactly what the OLD `clearLog` left behind: [n] rows written, all of them
  /// deleted, the high-water mark untouched.
  Future<void> clearedTheOldWay(dynamic db, int n) async {
    for (var i = 0; i < n; i++) {
      await db.insert('diag_log', {
        'timestamp': 1757000000000 + i,
        'direction': 'rx',
        'hex': 'b81901040000ccff',
        'device_id': 'AA',
      });
    }
    await db.delete('diag_log');
  }

  // =========================================================================
  group('🔴 v23 → v24: the stale high-water mark goes', () {
    test('a log the user cleared under the OLD build reports none', () async {
      var before = -1;
      final db = await upgradeFromV23('v24_cleared', (legacy) async {
        await clearedTheOldWay(legacy, 1000);
        // 🔑 The premise, asserted on the fixture itself. Without this the case
        // would pass just as happily on a database that never had the problem.
        before = (await sequenceOf(legacy))!;
      });
      expect(before, 1000,
          reason: 'the fixture must actually carry the stale mark, otherwise '
              'this test proves nothing about the migration');

      expect(await sequenceOf(db.db), 0,
          reason: 'the migration must bring it down to what the surviving rows '
              '(none) justify');

      // And the user-visible consequence, which is the only reason any of this
      // matters: the next export does not accuse the app of losing 1,000 rows.
      final logs = LogRepo(db.db);
      for (var i = 0; i < 5; i++) {
        await packet(logs, i);
      }
      expect((await logs.queryLog()).last.id, 1,
          reason: 'ids restart at 1, so MAX(id) counts rows that really existed');
      expect(await rotatedLine(logs), 'rotated: none');
    });

    test('🔴 a log that REALLY rotated keeps its count — the opposite error',
        () async {
      // A migration that simply zeroed the mark would be just as wrong, in the
      // direction nobody notices: every honestly truncated log would start
      // saying `none`, and the reader who subtracted two frame counters across
      // the gap would be back where FB-110 found them.
      final db = await upgradeFromV23('v24_rotated', (legacy) async {
        for (var i = 0; i < 600; i++) {
          await legacy.insert('diag_log', {
            'timestamp': 1757000000000 + i,
            'direction': 'rx',
            'hex': 'b81901040000ccff',
            'device_id': 'AA',
          });
        }
        // What rotation does: the oldest 500 go, the sequence stays at 600.
        await legacy.rawDelete(
          'DELETE FROM diag_log WHERE id IN '
          '(SELECT id FROM diag_log ORDER BY id ASC LIMIT 500)',
        );
      });

      expect(await sequenceOf(db.db), 600,
          reason: 'MAX(id) is 600, so there is nothing stale to take down');
      final logs = LogRepo(db.db);
      expect(await logs.droppedByRotation(), 500);
      expect(await rotatedLine(logs),
          'rotated: dropped=500 oldest rows (log size cap)');
    });

    test('a database that has never written a diag_log row survives it',
        () async {
      // No `sqlite_sequence` row for the table at all — the UPDATE matches
      // nothing and must simply do nothing, on the very first launch after the
      // upgrade rather than at some later point where it would be noticed.
      final db = await upgradeFromV23('v24_virgin', (legacy) async {
        expect(await sequenceOf(legacy), isNull, reason: 'the premise');
      });
      expect(await sequenceOf(db.db), isNull);
      final logs = LogRepo(db.db);
      expect(await logs.droppedByRotation(), 0);
      expect(await rotatedLine(logs), 'rotated: none');
      await packet(logs, 0);
      expect((await logs.queryLog()).single.id, 1);
      expect(await rotatedLine(logs), 'rotated: none');
    });

    test('an upgraded log that was never cleared is left exactly as it was',
        () async {
      final db = await upgradeFromV23('v24_untouched', (legacy) async {
        for (var i = 0; i < 7; i++) {
          await legacy.insert('diag_log', {
            'timestamp': 1757000000000 + i,
            'direction': 'rx',
            'hex': 'b81901040000ccff',
            'device_id': 'AA',
          });
        }
      });
      expect(await sequenceOf(db.db), 7);
      final logs = LogRepo(db.db);
      expect(await logs.count(), 7);
      expect(await rotatedLine(logs), 'rotated: none');
    });
  });

  // =========================================================================
  group('🔑 the two ways a database can arrive at v24 agree', () {
    test('a fresh install reports none and starts at id 1', () async {
      final dir = await Directory.systemTemp.createTemp('osb_v24_fresh');
      addTearDown(() => dir.delete(recursive: true));
      final db = await AppDatabase.open(
        path: p.join(dir.path, 'fresh.db'),
        factory: databaseFactoryFfi,
      );
      addTearDown(db.close);
      final logs = LogRepo(db.db);
      expect(await rotatedLine(logs), 'rotated: none');
      await packet(logs, 0);
      expect((await logs.queryLog()).single.id, 1);
      expect(await rotatedLine(logs), 'rotated: none');
    });

    test('🔵 clearLog on the new build reaches the same state the migration '
        'produces', () async {
      // The migration and `clearLog` are the two halves of one rule; if they
      // ever disagreed, whether a user reads a true header would depend on
      // which build they happened to clear on.
      final db = await upgradeFromV23('v24_parity', (legacy) async {
        await clearedTheOldWay(legacy, 42);
      });
      final logs = LogRepo(db.db);
      final afterMigration = await sequenceOf(db.db);

      for (var i = 0; i < 42; i++) {
        await packet(logs, i);
      }
      await logs.clearLog();
      final afterClear = await sequenceOf(db.db);

      // 🔑 The migration UPDATEs the row to 0; `clearLog` DELETEs it. SQLite
      // reads both as "the next id is 1", which is the property that actually
      // has to hold — so this compares the CONSEQUENCE, not the storage.
      expect(afterMigration, anyOf(0, isNull));
      expect(afterClear, anyOf(0, isNull));
      await packet(logs, 0);
      expect((await logs.queryLog()).single.id, 1);
      expect(await rotatedLine(logs), 'rotated: none');
    });
  });
}
