/// Open-RCE-Batt — app-settings repository (mockup screen 5).
///
/// Persists [AppSettings] as a single row. Includes the diagnostics raw-packet
/// toggle (DEFAULT OFF), poll interval, theme and units.
library;

import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import 'app_database.dart';

/// Loads/saves the single settings row.
class SettingsRepo {
  SettingsRepo(this._db);

  final Database _db;

  /// Load persisted settings, or [AppSettings.defaults] if none stored yet.
  Future<AppSettings> loadSettings() async {
    final rows = await _db.query(
      Db.tableSettings,
      where: 'id = ?',
      whereArgs: [Db.settingsRowId],
      limit: 1,
    );
    if (rows.isEmpty) return AppSettings.defaults;
    return AppSettings.fromMap(rows.first);
  }

  /// Persist settings into the fixed single row (insert-or-replace).
  Future<void> saveSettings(AppSettings settings) {
    return _db.insert(
      Db.tableSettings,
      {'id': Db.settingsRowId, ...settings.toMap()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Reset to factory defaults.
  Future<void> resetToDefaults() => saveSettings(AppSettings.defaults);
}
