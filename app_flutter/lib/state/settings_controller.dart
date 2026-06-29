/// Open-RCE-Batt — settings controller (mockup screen 5).
///
/// Owns the live [AppSettings] and persists every mutation through
/// [SettingsRepo]. Other controllers ([TelemetryController],
/// [ConnectionController]) listen to this to react to the auto-log /
/// raw-packet-log / auto-reconnect / poll-interval toggles.
library;

import 'package:flutter/foundation.dart';

import '../data/data.dart';
import '../models/models.dart';

/// ChangeNotifier wrapper around the single persisted [AppSettings] row.
class SettingsController extends ChangeNotifier {
  SettingsController(this._repo);

  final SettingsRepo _repo;

  AppSettings _settings = AppSettings.defaults;
  bool _loaded = false;

  /// Current settings (defaults until [load] completes).
  AppSettings get settings => _settings;

  /// True once the persisted row has been read at least once.
  bool get loaded => _loaded;

  // Convenience pass-throughs the other controllers / UI read frequently.
  bool get autoReconnect => _settings.autoReconnect;
  int get pollIntervalMs => _settings.pollIntervalMs;
  bool get backgroundKeepAlive => _settings.backgroundKeepAlive;
  bool get darkTheme => _settings.darkTheme;
  AppLang get lang => _settings.lang;
  TempUnit get tempUnit => _settings.tempUnit;
  bool get autoLog => _settings.autoLog;
  bool get rawPacketLog => _settings.rawPacketLog;
  int get logMaxBytes => _settings.logMaxBytes;

  /// Load the persisted row (or defaults if none stored yet).
  Future<void> load() async {
    _settings = await _repo.loadSettings();
    _loaded = true;
    notifyListeners();
  }

  /// Replace the whole settings object (optimistic: notifies, then persists).
  Future<void> update(AppSettings next) async {
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    await _repo.saveSettings(next);
  }

  // --- per-field setters (UI binds switches/dropdowns to these) ---
  Future<void> setAutoReconnect(bool v) =>
      update(_settings.copyWith(autoReconnect: v));
  Future<void> setPollIntervalMs(int v) =>
      update(_settings.copyWith(pollIntervalMs: v));
  Future<void> setBackgroundKeepAlive(bool v) =>
      update(_settings.copyWith(backgroundKeepAlive: v));
  Future<void> setDarkTheme(bool v) =>
      update(_settings.copyWith(darkTheme: v));
  Future<void> setLang(AppLang v) => update(_settings.copyWith(lang: v));
  Future<void> setTempUnit(TempUnit v) =>
      update(_settings.copyWith(tempUnit: v));
  Future<void> setAutoLog(bool v) => update(_settings.copyWith(autoLog: v));
  Future<void> setRawPacketLog(bool v) =>
      update(_settings.copyWith(rawPacketLog: v));
  Future<void> setLogMaxBytes(int v) =>
      update(_settings.copyWith(logMaxBytes: v));

  /// Reset every field to factory defaults.
  Future<void> resetToDefaults() async {
    _settings = AppSettings.defaults;
    notifyListeners();
    await _repo.resetToDefaults();
  }
}
