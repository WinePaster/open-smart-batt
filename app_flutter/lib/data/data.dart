/// OpenSmartBatt local data layer — OUR app SQLite (not the vendor's).
///
/// Barrel for the database opener + repositories. Depends on `models/` and
/// `package:sqflite`; consumed by the state/controller layer.
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

export 'app_database.dart';
export 'history_repo.dart';
export 'device_repo.dart';
export 'settings_repo.dart';
export 'log_repo.dart';
export 'update_service.dart';
