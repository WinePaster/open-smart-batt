/// OpenSmartBatt — local SQLite database (OUR app DB, not the vendor's).
///
/// Owns connection lifecycle, schema DDL and migrations. Repositories
/// ([HistoryRepo], [DeviceRepo], [SettingsRepo], [LogRepo]) take the opened
/// [Database] and translate model `toMap()`/`fromMap()` rows.
///
/// CLEAN-ROOM: schema derived only from the model `toMap()` contracts and
/// docs/PROTOCOL.md §9 column correspondence. No vendor DB is read or copied.
library;

import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Table + column name constants (single source of truth for all repos).
class Db {
  Db._();

  /// Bump on any schema change and add a branch in [AppDatabase._onUpgrade].
  ///
  /// v2: settings gained `theme_mode TEXT` (tri-state light/dark/auto); the
  /// legacy `dark_theme` bool column is retained for migration.
  /// v3: saved_devices gained `name` (stable advertised name, the iOS NSUUID
  /// rebind key — D.3) and `stale` (failed-to-resolve flag).
  /// v4: saved_devices gained `product_class` (the resolved product class plus
  /// the cosmetic pack label); old rows default to 'unknown'.
  /// v5: history + diag_log gained `device_id` (which unit the row belongs to),
  /// history gained `soc` and diag_log gained `session_id`. All nullable with
  /// NO default: pre-v5 rows keep NULL, meaning "unknown device", because
  /// attributing them to the current unit would be a lie. This is the invariant
  /// the whole per-unit export story rests on — a recipient asking "is this all
  /// of that battery's data?" can only be answered if attribution is either
  /// right or absent, never guessed.
  /// v6: history gained `samples` (how many telemetry snapshots that minute's
  /// row averaged). Nullable with NO default, same reasoning as v5: pre-v6 rows
  /// genuinely do not know their sample count. Without it a full minute and a
  /// minute truncated by a silent disconnect look identical in an export.
  /// v7: history + diag_log gained `app_build` — which build WROTE the row, as
  /// opposed to which build exported it. Per row rather than per session
  /// because diag_log is trimmed oldest-first: a build recorded once at the
  /// start of a connection would be the first thing deleted, and the rows that
  /// survive are exactly the ones whose origin is hardest to reconstruct.
  /// v8: settings gained `background_monitoring` (Android foreground service),
  /// defaulting ON. The pre-existing `background_keep_alive` column keeps its
  /// name but now maps to `keepScreenAwake`, which is all it ever did;
  /// renaming it would need SQLite 3.25+ (API 30) and minSdk is 24.
  ///
  /// CLAIMING A NUMBER: rebase onto main FIRST and take the next free one. This
  /// list is the only registry, so two branches developed in parallel will
  /// happily claim the same version and merge without a textual conflict in the
  /// migration body — after which whoever already upgraded never runs the
  /// loser's branch. That is not hypothetical: the background-monitoring work
  /// was written as v6 while the export-provenance work took v6 and v7 on main,
  /// and it had to be renumbered to v8 at merge time.
  /// v9: settings gained `retention`, DEFAULT 'forever' — how long recorded
  /// history is KEPT, replacing the old "record at all?" switch. The `auto_log`
  /// column is DEAD from v9 on — nothing reads it. It stays because SQLite
  /// needs 3.35+ for DROP COLUMN and minSdk 24 ships older; rebuilding the
  /// whole settings table to reclaim four bytes is not a trade worth making.
  static const int schemaVersion = 9;

  /// On-disk database file name (lives under the platform databases dir).
  static const String fileName = 'open_smart_batt.db';

  // --- tables ---
  static const String tableHistory = 'history';
  static const String tableSavedDevices = 'saved_devices';
  static const String tableSettings = 'settings';
  static const String tableDiagLog = 'diag_log';

  /// Fixed single-row id for the settings table.
  static const int settingsRowId = 1;
}

/// Thrown when the stored schema is NEWER than this build understands — i.e.
/// the user downgraded the app after having run a later version.
///
/// We deliberately do NOT wipe the database in that case: the rows are intact
/// and the fix (install the newer build again) is in the user's hands, whereas
/// a silent delete would destroy months of history to work around a reversible
/// mistake. The startup screen surfaces this and tells them what to do.
class DatabaseDowngradeException implements Exception {
  const DatabaseDowngradeException({
    required this.storedVersion,
    required this.appVersion,
  });

  /// Schema version found on disk (written by the newer build).
  final int storedVersion;

  /// Schema version this build supports.
  final int appVersion;

  @override
  String toString() =>
      'DatabaseDowngradeException(stored=$storedVersion, app=$appVersion)';
}

/// Thin wrapper around an opened sqflite [Database].
///
/// Open once at app start (or inject a custom [databaseFactory] + [path] in
/// tests, e.g. sqflite_common_ffi) and hand the [db] to the repositories.
class AppDatabase {
  AppDatabase._(this.db);

  /// The live sqflite handle. Repositories operate on this directly.
  final Database db;

  /// Open (creating/migrating as needed).
  ///
  /// - [path]: explicit file path. Defaults to `<databasesPath>/[Db.fileName]`.
  /// - [factory]: inject an alternate [DatabaseFactory] (e.g. ffi for tests).
  static Future<AppDatabase> open({
    String? path,
    DatabaseFactory? factory,
  }) async {
    final fac = factory ?? databaseFactory;
    final dbPath = path ?? await defaultPath(factory: fac);
    final db = await fac.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: Db.schemaVersion,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onDowngrade: _onDowngrade,
      ),
    );
    return AppDatabase._(db);
  }

  /// Where the database lives when no explicit path is given.
  static Future<String> defaultPath({DatabaseFactory? factory}) async {
    final fac = factory ?? databaseFactory;
    return p.join(await fac.getDatabasesPath(), Db.fileName);
  }

  /// Delete the database file — the user-initiated last resort offered by the
  /// startup failure screen. DESTROYS history, saved devices and settings, so
  /// it must never be triggered automatically.
  ///
  /// Goes through the FACTORY's `deleteDatabase`, never `File.delete`, because
  /// under WAL the data is not all in the one file: a `-wal` left beside a
  /// deleted database is how a "reset" comes back haunted. Checked in all three
  /// implementations we ship on — sqflite_android hands off to
  /// `SQLiteDatabase.deleteDatabase(File)`, sqflite_darwin removes `-shm`/`-wal`
  /// explicitly (SqflitePlugin.m `deleteDatabaseFile:`), and sqflite_common's
  /// io filesystem removes `-wal`, `-shm` and `-journal`.
  static Future<void> reset({String? path, DatabaseFactory? factory}) async {
    final fac = factory ?? databaseFactory;
    await fac.deleteDatabase(path ?? await defaultPath(factory: fac));
  }

  /// Refuse to open a database written by a NEWER build (see
  /// [DatabaseDowngradeException]). sqflite's default here is to delete or to
  /// throw an opaque error; both are worse than saying exactly what happened.
  static Future<void> _onDowngrade(Database db, int from, int to) async {
    throw DatabaseDowngradeException(storedVersion: from, appVersion: to);
  }

  /// Close the underlying connection.
  Future<void> close() => db.close();

  static Future<void> _onConfigure(Database db) async {
    // Enforce foreign keys / sane defaults (no FKs yet, but cheap to enable).
    await db.execute('PRAGMA foreign_keys = ON');
    // Write-ahead logging. Measured on host: 390–412 µs per insert on the
    // rollback journal, 112 µs with WAL — ~3.5×, on the path that runs at the
    // measured 13 packets/s median (peak 22) with `rawPacketLog` on, plus a
    // history row a minute and every event line.
    //
    // `synchronous` is deliberately NOT touched. The usual WAL recipe pairs it
    // with `synchronous = NORMAL`, which is where WAL's reputation for losing
    // the last transactions on power loss comes from; the gain above was
    // measured with it left at FULL, so there is nothing to buy by weakening
    // it. This app records evidence — a truncated capture is the one failure
    // mode we cannot ask a user to reproduce.
    //
    // 🔴 **Android is deliberately left on the rollback journal.** It cannot be
    // reached from here anyway — sqflite's Android side decides WAL at open()
    // time via `SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING`, gated on the
    // manifest meta-data `com.tekartik.sqflite.wal_enabled`, read before
    // onConfigure runs — but the point is that we chose NOT to set that
    // meta-data, and the reason should outlive whoever next notices the
    // asymmetry:
    //
    //   Database.java:54  // To turn on when supported fully
    //   Database.java:55  // 2022-09-14 experiments show several corruption issue.
    //   Database.java:56  final static boolean WAL_ENABLED_BY_DEFAULT = false;
    //
    // Upstream's default-off is not an oversight, it is a corruption report.
    // And the mitigation we rely on below does not transfer: on Android the
    // WAL synchronous mode comes from the framework resource `db_wal_sync_mode`,
    // not from us, so "we keep synchronous = FULL" would be a claim we cannot
    // make on the one platform the reports came from.
    //
    // Weigh that against what it buys. After the O(1) rotation accounting
    // (`log_repo.dart`), this path uses ~0.54% of one background thread at the
    // measured packet rate, and only while `rawPacketLog` is on — which is off
    // by default. Trading any corruption risk on a database holding the user's
    // entire history (retention defaults to forever) for 0.4% of a background
    // thread on an opt-in diagnostic path is not a trade worth making.
    //
    // To revisit: read `PRAGMA synchronous` on a real Android device under WAL
    // and check whether upstream has flipped the default since.
    //
    // rawQuery, not execute: `PRAGMA journal_mode` RETURNS the resulting mode
    // as a row rather than being a pure statement.
    if (!Platform.isAndroid) {
      await db.rawQuery('PRAGMA journal_mode = WAL');
    }
  }

  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    for (final stmt in _createStatements) {
      batch.execute(stmt);
    }
    await batch.commit(noResult: true);
  }

  static Future<void> _onUpgrade(Database db, int from, int to) async {
    // v1 is the initial schema. Keep migrations additive and idempotent.
    if (from < 2) {
      // Add the tri-state theme column. No DEFAULT: existing rows get NULL so
      // AppSettings.fromMap migrates them from the legacy `dark_theme` bool.
      await db.execute(
        'ALTER TABLE ${Db.tableSettings} ADD COLUMN theme_mode TEXT',
      );
    }
    if (from < 3) {
      // D.3: stable advertised name (iOS NSUUID rebind key) + stale flag.
      // Additive with safe defaults so pre-v3 rows migrate cleanly.
      await db.execute(
        "ALTER TABLE ${Db.tableSavedDevices} ADD COLUMN name TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        'ALTER TABLE ${Db.tableSavedDevices} ADD COLUMN stale INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (from < 4) {
      // Persist the resolved product class / cosmetic pack label, so a unit
      // that has been identified once does not have to be re-identified (and
      // the dashboard does not have to guess) on every later connection.
      // Additive; pre-v4 rows default to 'unknown'.
      await db.execute(
        "ALTER TABLE ${Db.tableSavedDevices} ADD COLUMN product_class TEXT NOT NULL DEFAULT 'unknown'",
      );
    }
    if (from < 5) {
      // Attribute every recorded row to a device (and each log row to one
      // connection), so that data from several units stops accumulating into
      // one indistinguishable pile. Nullable with NO default — pre-v5 rows stay
      // NULL ("unknown device") rather than being mis-attributed to the current
      // unit, which would be a fabricated fact rather than a missing one.
      await db.execute(
        'ALTER TABLE ${Db.tableHistory} ADD COLUMN device_id TEXT',
      );
      await db.execute(
        'ALTER TABLE ${Db.tableHistory} ADD COLUMN soc INTEGER',
      );
      await db.execute(
        'ALTER TABLE ${Db.tableDiagLog} ADD COLUMN device_id TEXT',
      );
      await db.execute(
        'ALTER TABLE ${Db.tableDiagLog} ADD COLUMN session_id INTEGER',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_history_device ON ${Db.tableHistory} (device_id)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_diag_log_device ON ${Db.tableDiagLog} (device_id)',
      );
    }
    if (from < 6) {
      // How many telemetry snapshots each minute-row averaged, so a full minute
      // and a truncated one are distinguishable in an export — a connection cut
      // off silently leaves a short tail row that otherwise looks like any
      // other minute.
      // Nullable with NO default — pre-v6 rows do not know their count, and a
      // fabricated one would read as fact.
      await db.execute(
        'ALTER TABLE ${Db.tableHistory} ADD COLUMN samples INTEGER',
      );
    }
    if (from < 7) {
      // The build that RECORDED each row, which is not the build that exports
      // it: both tables accumulate for months, so one export routinely spans
      // several app versions. Without this, "was this gap a bug we already
      // fixed, or is the hardware simply like that?" is unanswerable.
      // Nullable with NO default — pre-v7 rows were written by a build we
      // cannot name, and guessing one would read as fact.
      await db.execute(
        'ALTER TABLE ${Db.tableHistory} ADD COLUMN app_build TEXT',
      );
      await db.execute(
        'ALTER TABLE ${Db.tableDiagLog} ADD COLUMN app_build TEXT',
      );
    }
    if (from < 8) {
      // Background monitoring via the Android foreground service.
      // DEFAULT 1 — existing users are exactly the ones hitting the stall, so
      // they get it on. Their `background_keep_alive` value is untouched and
      // now reads as `keepScreenAwake`, preserving that choice separately.
      await db.execute(
        'ALTER TABLE ${Db.tableSettings} ADD COLUMN background_monitoring INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (from < 9) {
      // History is now always recorded; this decides how long it is KEPT.
      // DEFAULT 'forever' so that upgrading — including from a build where the
      // user had auto-log switched off — never discards anything. Any shorter
      // default would delete real data, irreversibly, at the moment of an
      // upgrade the user never asked to be destructive.
      await db.execute(
        "ALTER TABLE ${Db.tableSettings} ADD COLUMN retention TEXT NOT NULL DEFAULT 'forever'",
      );
    }
  }

  /// All `CREATE TABLE`/index DDL for the current schema version.
  ///
  /// History columns mirror [TelemetrySample.toMap]; saved_devices mirror
  /// [SavedDevice.toMap]; settings mirror [AppSettings.toMap] (single row);
  /// diag_log mirrors [LogEntry.toMap].
  static const List<String> _createStatements = <String>[
    '''
    CREATE TABLE ${Db.tableHistory} (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp INTEGER NOT NULL,
      pvlt REAL,
      svlt REAL,
      ampere REAL,
      temperature INTEGER,
      dvol1 REAL,
      dvol2 REAL,
      dvol3 REAL,
      dvol4 REAL,
      soh INTEGER,
      mode INTEGER,
      twf INTEGER,
      serial TEXT,
      soc INTEGER,
      device_id TEXT,
      samples INTEGER,
      app_build TEXT
    )
    ''',
    'CREATE INDEX idx_history_ts ON ${Db.tableHistory} (timestamp)',
    'CREATE INDEX idx_history_device ON ${Db.tableHistory} (device_id)',
    '''
    CREATE TABLE ${Db.tableSavedDevices} (
      id TEXT PRIMARY KEY,
      alias TEXT NOT NULL DEFAULT '',
      name TEXT NOT NULL DEFAULT '',
      last_seen INTEGER,
      last_value REAL,
      stale INTEGER NOT NULL DEFAULT 0,
      product_class TEXT NOT NULL DEFAULT 'unknown'
    )
    ''',
    '''
    CREATE TABLE ${Db.tableSettings} (
      id INTEGER PRIMARY KEY CHECK (id = ${Db.settingsRowId}),
      auto_reconnect INTEGER NOT NULL DEFAULT 1,
      poll_interval_ms INTEGER NOT NULL DEFAULT 1000,
      background_keep_alive INTEGER NOT NULL DEFAULT 0,
      background_monitoring INTEGER NOT NULL DEFAULT 1,
      dark_theme INTEGER NOT NULL DEFAULT 1,
      theme_mode TEXT,
      lang TEXT NOT NULL DEFAULT 'zhHant',
      temp_unit TEXT NOT NULL DEFAULT 'celsius',
      auto_log INTEGER NOT NULL DEFAULT 1,
      raw_packet_log INTEGER NOT NULL DEFAULT 0,
      retention TEXT NOT NULL DEFAULT 'forever',
      log_max_bytes INTEGER NOT NULL DEFAULT ${20 * 1024 * 1024}
    )
    ''',
    '''
    CREATE TABLE ${Db.tableDiagLog} (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp INTEGER NOT NULL,
      direction TEXT NOT NULL,
      hex TEXT NOT NULL,
      note TEXT,
      device_id TEXT,
      session_id INTEGER,
      app_build TEXT
    )
    ''',
    'CREATE INDEX idx_diag_log_ts ON ${Db.tableDiagLog} (timestamp)',
    'CREATE INDEX idx_diag_log_device ON ${Db.tableDiagLog} (device_id)',
  ];
}
