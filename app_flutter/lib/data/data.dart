/// OpenSmartBatt local data layer — OUR app SQLite (not the vendor's).
///
/// Barrel for the database opener + repositories. Depends on `models/` and
/// `package:sqflite`; consumed by the state/controller layer.
///
/// [AckMarker] is the one member that is NOT SQLite: a "seen once" flag kept as
/// a file, deliberately outside the settings row. `ack_marker.dart` states why,
/// and UI that only needs a marker should import that file directly rather than
/// this barrel — it costs nothing and pulls in no database.
///
/// Usage:
/// ```dart
/// final appDb = await AppDatabase.open();
/// final history = HistoryRepo(appDb.db);
/// final devices = DeviceRepo(appDb.db);
/// final settings = SettingsRepo(appDb.db);
/// final logs = LogRepo(appDb.db);
/// ```
library;

export 'ack_marker.dart';
export 'app_database.dart';
export 'pending_writes.dart';
export 'history_repo.dart';
export 'device_repo.dart';
export 'device_facts_repo.dart';
export 'settings_repo.dart';
export 'log_repo.dart';
export 'update_service.dart';
