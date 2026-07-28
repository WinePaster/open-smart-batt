/// OpenSmartBatt — local SQLite database (OUR app DB, not the vendor's).
///
/// Owns connection lifecycle, schema DDL and migrations. Repositories
/// ([HistoryRepo], [DeviceRepo], [SettingsRepo], [LogRepo]) take the opened
/// [Database] and translate model `toMap()`/`fromMap()` rows.
///
/// CLEAN-ROOM: schema derived only from the model `toMap()` contracts and
/// docs/PROTOCOL.md §9 column correspondence. No vendor DB is read or copied.
library;

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
  /// v4: saved_devices gained `product_class` (resolved class + cosmetic pack
  /// label — design 0001 §5 Phase 5); old rows default to 'unknown'.
  /// v5: history + diag_log gained `device_id` (which unit the row belongs to),
  /// history gained `soc` and diag_log gained `session_id` — design 0006. All
  /// nullable with NO default: pre-v5 rows keep NULL, meaning "unknown device",
  /// because attributing them to the current unit would be a lie.
  /// v6: history gained `samples` (how many telemetry snapshots that minute's
  /// row averaged) — design 0009. Nullable with NO default, same reasoning as
  /// v5: pre-v6 rows genuinely do not know their sample count.
  /// v7: history + diag_log gained `app_build` — which build WROTE the row,
  /// as opposed to which build exported it (design 0010). Per row rather than
  /// per session because diag_log is trimmed oldest-first: a build recorded
  /// once at the start of a connection would be the first thing deleted.
  static const int schemaVersion = 7;

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
      // design 0001 §5 Phase 5: persist the resolved product class / cosmetic
      // pack label. Additive; pre-v4 rows default to 'unknown'.
      await db.execute(
        "ALTER TABLE ${Db.tableSavedDevices} ADD COLUMN product_class TEXT NOT NULL DEFAULT 'unknown'",
      );
    }
    if (from < 5) {
      // design 0006: attribute every recorded row to a device (and each log row
      // to one connection). Nullable with NO default — pre-v5 rows stay NULL
      // ("unknown device") rather than being mis-attributed to the current unit.
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
      // design 0009: how many telemetry snapshots each minute-row averaged, so
      // a full minute and a truncated one are distinguishable in an export.
      // Nullable with NO default — pre-v6 rows do not know their count, and a
      // fabricated one would read as fact.
      await db.execute(
        'ALTER TABLE ${Db.tableHistory} ADD COLUMN samples INTEGER',
      );
    }
    if (from < 7) {
      // design 0010: the build that RECORDED each row. Nullable with NO
      // default — pre-v7 rows were written by a build we cannot name, and
      // guessing one would read as fact.
      await db.execute(
        'ALTER TABLE ${Db.tableHistory} ADD COLUMN app_build TEXT',
      );
      await db.execute(
        'ALTER TABLE ${Db.tableDiagLog} ADD COLUMN app_build TEXT',
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
      dark_theme INTEGER NOT NULL DEFAULT 1,
      theme_mode TEXT,
      lang TEXT NOT NULL DEFAULT 'zhHant',
      temp_unit TEXT NOT NULL DEFAULT 'celsius',
      auto_log INTEGER NOT NULL DEFAULT 1,
      raw_packet_log INTEGER NOT NULL DEFAULT 0,
      log_max_bytes INTEGER NOT NULL DEFAULT ${5 * 1024 * 1024}
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
