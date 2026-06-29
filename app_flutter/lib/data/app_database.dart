/// Open-RCE-Batt — local SQLite database (OUR app DB, not the vendor's).
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
  static const int schemaVersion = 1;

  /// On-disk database file name (lives under the platform databases dir).
  static const String fileName = 'open_rce_batt.db';

  // --- tables ---
  static const String tableHistory = 'history';
  static const String tableSavedDevices = 'saved_devices';
  static const String tableSettings = 'settings';
  static const String tableDiagLog = 'diag_log';

  /// Fixed single-row id for the settings table.
  static const int settingsRowId = 1;
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
    final dbPath = path ?? p.join(await fac.getDatabasesPath(), Db.fileName);
    final db = await fac.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: Db.schemaVersion,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return AppDatabase._(db);
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
    // v1 is the initial schema. Future migrations: `if (from < 2) { ... }`.
    // Keep migrations additive and idempotent.
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
      serial TEXT
    )
    ''',
    'CREATE INDEX idx_history_ts ON ${Db.tableHistory} (timestamp)',
    '''
    CREATE TABLE ${Db.tableSavedDevices} (
      id TEXT PRIMARY KEY,
      alias TEXT NOT NULL DEFAULT '',
      last_seen INTEGER,
      last_value REAL
    )
    ''',
    '''
    CREATE TABLE ${Db.tableSettings} (
      id INTEGER PRIMARY KEY CHECK (id = ${Db.settingsRowId}),
      auto_reconnect INTEGER NOT NULL DEFAULT 1,
      poll_interval_ms INTEGER NOT NULL DEFAULT 1000,
      background_keep_alive INTEGER NOT NULL DEFAULT 0,
      dark_theme INTEGER NOT NULL DEFAULT 1,
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
      note TEXT
    )
    ''',
    'CREATE INDEX idx_diag_log_ts ON ${Db.tableDiagLog} (timestamp)',
  ];
}
