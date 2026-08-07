/// OpenSmartBatt — settings controller (mockup screen 5).
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
  /// The lint below suggests `{this._history}`, which does not compile: Dart
  /// forbids private named parameters.
  // ignore: prefer_initializing_formals
  SettingsController(this._repo, {HistoryRepo? history}) : _history = history;

  /// Optional: pruning needs it, everything else does not. Null in tests that
  /// only exercise settings.
  final HistoryRepo? _history;

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
  bool get backgroundMonitoring => _settings.backgroundMonitoring;
  bool get keepScreenAwake => _settings.keepScreenAwake;
  AppThemeMode get themeMode => _settings.themeMode;
  AppLang get lang => _settings.lang;
  TempUnit get tempUnit => _settings.tempUnit;
  bool get speedDetection => _settings.speedDetection;
  SpeedUnit get speedUnit => _settings.speedUnit;
  String? get homeLayout => _settings.homeLayout;
  RetentionPolicy get retention => _settings.retention;
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
  Future<void> setBackgroundMonitoring(bool v) =>
      update(_settings.copyWith(backgroundMonitoring: v));
  Future<void> setKeepScreenAwake(bool v) =>
      update(_settings.copyWith(keepScreenAwake: v));
  Future<void> setThemeMode(AppThemeMode v) =>
      update(_settings.copyWith(themeMode: v));
  Future<void> setLang(AppLang v) => update(_settings.copyWith(lang: v));
  Future<void> setTempUnit(TempUnit v) =>
      update(_settings.copyWith(tempUnit: v));

  /// The GPS speed master switch (design 0042 §3.9).
  ///
  /// Deliberately NOT the place the consent dialog lives. Turning this on has
  /// four consequences the user has to have been shown first, and a setter that
  /// asked for consent itself would make "write the setting" and "obtain
  /// consent" the same call — so any later caller (a restore-defaults, a test,
  /// a deep link) would either be blocked by a dialog it cannot answer or
  /// silently bypass the consent. The dialog belongs to the screen; this only
  /// records the answer.
  Future<void> setSpeedDetection(bool v) =>
      update(_settings.copyWith(speedDetection: v));

  Future<void> setSpeedUnit(SpeedUnit v) =>
      update(_settings.copyWith(speedUnit: v));

  /// Persist the home page's grid, or NULL to go back to the generated one.
  ///
  /// 🔴 NULL is the "restore defaults" write (design 0046 §4.9), and it is not
  /// the same as storing today's generated layout: the generator reflects the
  /// devices the user has AT RENDER TIME, so a unit saved next week appears by
  /// itself. A snapshot would freeze the list at the moment of the reset.
  Future<void> setHomeLayout(String? v) => update(
      _settings.copyWith(homeLayout: v, clearHomeLayout: v == null));
  /// Change how long history is kept, then apply it immediately.
  ///
  /// Applying on change is the honest behaviour: the user picked "30 days"
  /// expecting older rows to be gone, not to linger until the next launch.
  /// Shortening the window DELETES data and cannot be undone — the UI copy
  /// says so.
  Future<void> setRetention(RetentionPolicy v) async {
    await update(_settings.copyWith(retention: v));
    await pruneHistory();
  }

  /// Drop history older than the retention window. No-op for
  /// [RetentionPolicy.forever], and when no history repo was injected.
  Future<void> pruneHistory() async {
    final age = _settings.retention.maxAge;
    final history = _history;
    if (age == null || history == null) return;
    await history.deleteOlderThan(DateTime.now().subtract(age));
  }
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
