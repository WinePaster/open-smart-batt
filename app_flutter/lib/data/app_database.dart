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
  /// v10: saved_devices gained `display_layout TEXT` — the dashboard layout
  /// this unit is shown with (design 0034 Q3: bound to the DEVICE, because
  /// binding it to the CLASS would let the user's type guess pick a layout, and
  /// "a layout may be chosen by wire-derived facts and by nothing else" is a
  /// standing invariant). Nullable with NO default: a NULL reads back as
  /// [DisplayLayout.defaults], which draws exactly the pre-v10 screen, so an
  /// upgrade changes nothing for anyone who never opens the setting (G4).
  /// v11: saved_devices gained `mac TEXT` (the device's own BLE address from
  /// selector 0x38 — design 0027 §3.2, the stable cross-platform identity) and
  /// `serial TEXT` (the full 15-digit product serial, per-device rather than
  /// only living on the connected sample). Both nullable with NO default and NO
  /// backfill: a pre-v11 row keeps NULL, meaning "not yet observed", rather than
  /// being stamped with whatever unit connected next. Same reasoning as v5–v7.
  /// v12: the GPS speed feature (design 0042) — and, deliberately, four columns
  /// it does not use. NINE columns in one migration, because this list is a
  /// one-way ratchet: `_onUpgrade` is a cumulative `if (from < N)` chain, so a
  /// column left out of v12 can only ever be added by a v13, and design 0044 Q2
  /// ruled there is not going to be one ("speed + accel + g_long + g_lat in one
  /// go, no v13"). A forgotten column here does not cost a follow-up migration;
  /// it overturns a ruling.
  ///
  ///   history.speed / accel     REAL, nullable — the PHONE's speed (m/s) and
  ///     its first derivative (m/s²), averaged over the same minute the rest of
  ///     the row averages. 🔑 They describe the PHONE, not the unit named by
  ///     this row's `device_id`: one phone, N connected devices, so every open
  ///     bucket in a minute receives the SAME value (design 0042 §3.9, ruling
  ///     (b)+(d) of 2026-08-07). Per-device queries must therefore not SUM
  ///     them. With nothing connected there is no bucket and no row, so those
  ///     minutes are absent rather than NULL — deliberately, since opening a
  ///     device-less bucket is exactly what design 0043 §3.1 forbids.
  ///     `accel` is written by design 0044; v12 only makes the room.
  ///   history.g_long / g_lat    REAL, nullable — reserved for design 0045's
  ///     G meter (its Q4/Q7). Nothing writes them yet.
  ///   settings.speed_detection  INTEGER NOT NULL DEFAULT 0 — the master switch
  ///     (design 0042 §3.9). DEFAULT 0 so an upgrade never turns on a feature
  ///     whose consent dialog the user has not seen.
  ///   settings.speed_unit       TEXT NOT NULL DEFAULT 'kmh'.
  ///   settings.home_layout      TEXT, nullable, NO default — reserved for
  ///     design 0046. It was claimed as ITS v12; the collision was resolved on
  ///     2026-08-06 by folding the column in here, which left that delivery
  ///     with no schema change at all. NULL for the same reason
  ///     `saved_devices.display_layout` is (v10): "this app has no custom home"
  ///     is already what NULL says, and a written-in empty layout would claim
  ///     every existing user had chosen one.
  ///   settings.g_meter_enabled  INTEGER NOT NULL DEFAULT 0 — reserved for
  ///     design 0045 §3.8. NOT NULL because it is a boolean: nullable would
  ///     invent a third state (NULL/0/1) with two of them meaning "off".
  ///   settings.g_calibration    TEXT, nullable, NO default — reserved for
  ///     design 0045 §3.8 (a JSON rotation matrix plus a timestamp). Nullable
  ///     because "never calibrated" is not some matrix; encoding it as an empty
  ///     string would invent a sentinel worse than NULL.
  ///
  /// ⚠️ The four reserved columns have NO writer, and must not gain one before
  /// their own design lands. `SettingsRepo.saveSettings` is INSERT OR REPLACE,
  /// so a settings column absent from `AppSettings.toMap()` is reset on the next
  /// change to ANY setting — harmless while nothing writes them, silent data
  /// loss the moment something does. See the note on [AppSettings.toMap].
  ///
  /// 🔴 SQLite cannot ALTER an existing column's constraints, so the NOT NULL /
  /// DEFAULT decisions above are welded in from the moment v12 ships.
  /// v13: settings gained `background_monitoring_ios` (design 0047 Phase 1 —
  /// iOS background BLE via `bluetooth-central`), DEFAULT 0. A SEPARATE column
  /// from v8's `background_monitoring`, not a reuse of it, because reuse would
  /// misread history: every iOS row already stores 1 in the Android column —
  /// `toMap` persisted the Android default on every settings change while the
  /// iOS switch was disabled (FB-26) — so on iOS that 1 was never a user's
  /// choice, and reading it as "on" would upgrade every iOS user into
  /// background execution nobody opted into. DEFAULT 0 / NULL-reads-off is the
  /// Q4 "default off" ruling in schema form (same shape as v12's
  /// `speed_detection`). Note this v13 does NOT touch the 0044 Q2 ruling —
  /// that ruled out a v13 for the SPEED column family, not the version number.
  /// v14: data-only — force-migrates `settings.log_max_bytes` 20 MB → 100 MB
  /// (2026-08-11 ruling; the Dart default moved the same day). No column
  /// change, so fresh and upgraded schemas stay identical.
  /// v15: the new table `device_facts` (design 0057) — what each unit said
  /// about ITSELF, kept whether or not the user ever named it. Until now the
  /// only way into storage was the naming dialog, so "the user declined to give
  /// it a name" also threw away the advertised name, the `0x10` class, the
  /// `0x38` MAC and the serial it had just reported; an unnamed capacitor's
  /// export then had no class to gate on and wrote its permanent, unmeasurable
  /// `0.0 A` out as a measurement (0057 §2 G2).
  ///
  /// A SEPARATE table rather than more columns on `saved_devices`, because the
  /// two answer different questions and only one of them may reach routing:
  /// `saved_devices` decides what the NEXT connection draws, `device_facts`
  /// decides how PAST records read back (0057 §3). Nothing in routing reads
  /// this table, which is what keeps "delete a device ⇒ it is a stranger again"
  /// literally true.
  ///
  ///   device_facts.id           TEXT PRIMARY KEY — the BLE remote id, i.e. the
  ///     same key `history.device_id` is written with. NOT the MAC, even though
  ///     the MAC is the stable identity of the physical unit: an iOS reinstall
  ///     mints a fresh NSUUID, and re-keying the old row onto the new id would
  ///     orphan every history row already written under the old one. Duplicate
  ///     machines are handled by reconciling ACROSS rows instead — see
  ///     [DeviceFactsRepo.observe] (§4.1.1).
  ///   device_facts.name / product_class / mac / serial   nullable, NO default:
  ///     NULL is "never observed", and each is written only when a value is
  ///     actually in hand, so a frame without `0x38` cannot blank a known MAC.
  ///   device_facts.first_seen / last_seen   INTEGER NOT NULL — a row exists
  ///     because a connection happened, so both instants always exist.
  ///
  /// NO BACKFILL from `saved_devices` (0048 G2's discipline): a unit that
  /// connected before v15 simply has no row and reads back exactly as it does
  /// today. Copying the saved columns across would look free and would not be —
  /// it would assert that facts were observed under ids we never observed them
  /// under, and on iOS those ids may since have been rebound.
  /// v16: the new table `autoconnect_arm` (design 0060 / FB-67) — the ONE
  /// armed iOS autoConnect hand-off, written so it outlives the process that
  /// armed it. Everything the watchdog knows about an armed hand-off lives in
  /// `ConnectionController`'s memory (`_autoConnectArmedAt` /
  /// `_autoConnectArmedId`), and iOS reclaims a suspended app without warning:
  /// the deadline is not deferred, it is gone, and the next launch has no input
  /// from which it could learn that a hand-off was ever in flight. FB-67
  /// measured 29 such cold returns on one phone in eight days.
  ///
  /// A SEPARATE table rather than columns on `settings`, and the reasoning is
  /// design 0060 §4: `settings` holds what the USER chose, this holds what the
  /// LAST RUN was doing, and `SettingsRepo.resetToDefaults()` would wipe the
  /// second along with the first. Not on `saved_devices` either — armed is a
  /// whole-app singular state (there is one `_desiredDeviceId`), so a per-device
  /// row would make "two units armed at once" representable, and an armed unit
  /// need not be saved at all.
  ///
  ///   autoconnect_arm.id          INTEGER PRIMARY KEY CHECK (id = 1) — the
  ///     same fixed-single-row shape as `settings`, so the invalid state above
  ///     cannot be written even by mistake.
  ///   autoconnect_arm.device_id   TEXT NOT NULL — which unit was being waited
  ///     for. A row cannot exist without one; that is the whole content.
  ///   autoconnect_arm.armed_at    INTEGER NOT NULL — `clock.now()` at arm
  ///     time, the SAME clock the FB-66 watchdog judges its deadline against.
  ///   autoconnect_arm.app_build   TEXT, nullable — which build armed it, so an
  ///     upgrade performed while armed is legible rather than silently dropped.
  ///   autoconnect_arm.session_id  INTEGER, nullable — ties the reconciliation
  ///     line back to the log section of the connection it belonged to.
  ///
  /// The table holds 0 or 1 rows and is deleted from on every ordinary
  /// convergence, so it never grows.
  static const int schemaVersion = 16;

  /// On-disk database file name (lives under the platform databases dir).
  static const String fileName = 'open_smart_batt.db';

  // --- tables ---
  static const String tableHistory = 'history';
  static const String tableSavedDevices = 'saved_devices';
  static const String tableSettings = 'settings';
  static const String tableDiagLog = 'diag_log';

  /// design 0057. Read the warning on [DeviceFacts] before wiring anything new
  /// to it: this table serves the READ-BACK of past records only.
  static const String tableDeviceFacts = 'device_facts';

  /// design 0060 (FB-67). The armed iOS autoConnect hand-off, persisted so it
  /// survives the process being reclaimed. Written by
  /// `ConnectionController._armAutoConnect` and deleted by
  /// `_cancelAutoConnectWatchdog` — those two and nothing else.
  static const String tableAutoConnectArm = 'autoconnect_arm';

  /// Fixed single-row id for the settings table.
  static const int settingsRowId = 1;

  /// Fixed single-row id for [tableAutoConnectArm] — "armed" is one state for
  /// the whole app, not one per device. See [schemaVersion] v16.
  static const int autoConnectArmRowId = 1;
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
    if (from < 10) {
      // Per-device dashboard layout (design 0034). Nullable with NO default,
      // for once NOT because a default would be a fabricated fact but because
      // NULL already means the right thing: "this unit has no layout of its
      // own" reads back as the default watchface, which is today's screen. A
      // literal '{"face":"standard"}' written into every row would say the
      // opposite — that every existing user has made a choice — and would have
      // to be told apart from a real one the day the editor lands.
      await db.execute(
        'ALTER TABLE ${Db.tableSavedDevices} ADD COLUMN display_layout TEXT',
      );
    }
    if (from < 11) {
      // The device's own BLE address (0x38 MAC) and full product serial, made
      // per-device instead of only living on the live sample (design 0027 §3.2).
      // Additive and nullable with NO default: pre-v11 rows stay NULL ("not yet
      // observed"). Backfilling them with the currently-connected unit's values
      // would attribute one battery's identity to every older row, exactly the
      // fabricated-fact failure the v5 attribution rules exist to prevent.
      await db.execute(
        'ALTER TABLE ${Db.tableSavedDevices} ADD COLUMN mac TEXT',
      );
      await db.execute(
        'ALTER TABLE ${Db.tableSavedDevices} ADD COLUMN serial TEXT',
      );
    }
    if (from < 12) {
      // design 0042 (GPS speed) plus four columns reserved for designs 0044 /
      // 0045 / 0046. The full rationale — including why all nine land at once
      // and why each constraint is what it is — is on [Db.schemaVersion]; this
      // is the one place it can still be changed, and after it ships it is not.
      //
      // `speed`/`accel` are nullable with NO default: a minute with no live GPS
      // sample genuinely has no speed, and a written-in 0.0 would claim the
      // phone was stationary.
      await db.execute(
        'ALTER TABLE ${Db.tableHistory} ADD COLUMN speed REAL',
      );
      await db.execute(
        'ALTER TABLE ${Db.tableHistory} ADD COLUMN accel REAL',
      );
      await db.execute(
        'ALTER TABLE ${Db.tableHistory} ADD COLUMN g_long REAL',
      );
      await db.execute(
        'ALTER TABLE ${Db.tableHistory} ADD COLUMN g_lat REAL',
      );
      await db.execute(
        'ALTER TABLE ${Db.tableSettings} ADD COLUMN speed_detection INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        "ALTER TABLE ${Db.tableSettings} ADD COLUMN speed_unit TEXT NOT NULL DEFAULT 'kmh'",
      );
      await db.execute(
        'ALTER TABLE ${Db.tableSettings} ADD COLUMN home_layout TEXT',
      );
      await db.execute(
        'ALTER TABLE ${Db.tableSettings} ADD COLUMN g_meter_enabled INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE ${Db.tableSettings} ADD COLUMN g_calibration TEXT',
      );
    }
    if (from < 13) {
      // iOS background monitoring (design 0047 Phase 1). DEFAULT 0: the Q4
      // ruling is that iOS defaults OFF, and — unlike v8, where upgrading
      // Android users were exactly the ones hitting the stall — upgrading iOS
      // users have never been asked, so the upgrade must not answer for them.
      // See [Db.schemaVersion] v13 for why this cannot reuse v8's column.
      await db.execute(
        'ALTER TABLE ${Db.tableSettings} ADD COLUMN background_monitoring_ios '
        'INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (from < 14) {
      // Diagnostic-log budget 20 MB → 100 MB, forced (2026-08-11 ruling): a
      // 20 MB cap rotated away a field device's ten oldest sessions before
      // anyone exported, and stored 20s are overwhelmingly the persisted old
      // default rather than a choice. This does sweep along anyone who
      // deliberately picked 20 over 100 after 2026-07-29 — accepted, because
      // the option remains and re-choosing 20 afterwards sticks (fromMap
      // keeps any value in logMaxBytesOptions). Rows at other values (e.g.
      // an explicit 100 MB) are untouched.
      // Guarded: a database old enough to predate the column reads the Dart
      // default (now 100 MB) via fromMap anyway, so there is nothing to move.
      final cols = await db.rawQuery('PRAGMA table_info(${Db.tableSettings})');
      if (cols.any((r) => r['name'] == 'log_max_bytes')) {
        await db.execute(
          'UPDATE ${Db.tableSettings} SET log_max_bytes = ${100 * 1024 * 1024} '
          'WHERE log_max_bytes = ${20 * 1024 * 1024}',
        );
      }
    }
    if (from < 15) {
      // design 0057: keep what a unit said about itself even when the user
      // never named it. A NEW table, so the upgrade is a pure addition — no
      // existing column, row or query changes, and every screen that does not
      // know about it behaves exactly as it did (T57-8).
      //
      // Deliberately EMPTY afterwards. Backfilling it from `saved_devices`
      // would be one line and would state something we never observed: that
      // those facts were seen under those ids at some knowable time. Same
      // discipline as 0048 G2 — an upgrade may add capability, never evidence.
      for (final stmt in _deviceFactsStatements) {
        await db.execute(stmt);
      }
    }
    if (from < 16) {
      // design 0060 (FB-67): somewhere for an armed autoConnect to survive the
      // process being reclaimed. A NEW table, so the upgrade adds capability
      // and touches no existing column, row or query.
      //
      // Deliberately EMPTY afterwards, and here that is not even a discipline
      // question: an arm is a statement about a hand-off in flight RIGHT NOW,
      // and the process that could have been holding one is the one being
      // upgraded away. There is nothing to backfill it from and nothing it
      // could truthfully say.
      for (final stmt in _autoConnectArmStatements) {
        await db.execute(stmt);
      }
    }
  }

  /// design 0060's table, written ONCE and used by both [_createStatements] and
  /// the v16 branch of [_onUpgrade] — see the note on [_deviceFactsStatements]
  /// for why a second copy of a `CREATE TABLE` is how two installs end up with
  /// schemas that quietly differ.
  static const List<String> _autoConnectArmStatements = <String>[
    '''
    CREATE TABLE ${Db.tableAutoConnectArm} (
      id INTEGER PRIMARY KEY CHECK (id = ${Db.autoConnectArmRowId}),
      device_id TEXT NOT NULL,
      armed_at INTEGER NOT NULL,
      app_build TEXT,
      session_id INTEGER
    )
    ''',
  ];

  /// design 0057's table, written ONCE and used by both [_createStatements] and
  /// the v15 branch of [_onUpgrade]. Two copies of a `CREATE TABLE` is how a
  /// fresh install and an upgraded one end up with schemas that differ in some
  /// column nobody remembers adding to the second copy.
  static const List<String> _deviceFactsStatements = <String>[
    '''
    CREATE TABLE ${Db.tableDeviceFacts} (
      id TEXT PRIMARY KEY,
      name TEXT,
      product_class TEXT,
      mac TEXT,
      serial TEXT,
      first_seen INTEGER NOT NULL,
      last_seen INTEGER NOT NULL
    )
    ''',
    // 🔴 Deliberately NOT UNIQUE (design 0057 §4.1.1). One physical unit
    // legitimately owns several rows here — an iOS reinstall gives it a new
    // NSUUID and the old row must survive, because history recorded under the
    // old id is keyed by it. A UNIQUE index would turn the intended shape into
    // a constraint violation on the second connection after a reinstall.
    'CREATE INDEX idx_device_facts_mac ON ${Db.tableDeviceFacts} (mac)',
  ];

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
      app_build TEXT,
      speed REAL,
      accel REAL,
      g_long REAL,
      g_lat REAL
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
      product_class TEXT NOT NULL DEFAULT 'unknown',
      display_layout TEXT,
      mac TEXT,
      serial TEXT
    )
    ''',
    '''
    CREATE TABLE ${Db.tableSettings} (
      id INTEGER PRIMARY KEY CHECK (id = ${Db.settingsRowId}),
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
      g_calibration TEXT
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
    ..._deviceFactsStatements,
    ..._autoConnectArmStatements,
  ];
}
