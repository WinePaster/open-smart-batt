/// OpenSmartBatt — settings controller (mockup screen 5).
///
/// Owns the live [AppSettings] and persists every mutation through
/// [SettingsRepo]. Other controllers ([TelemetryController],
/// [ConnectionController]) listen to this to react to the auto-log /
/// raw-packet-log / auto-reconnect / poll-interval toggles.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../data/data.dart';
import '../models/models.dart';

/// ChangeNotifier wrapper around the single persisted [AppSettings] row.
class SettingsController extends ChangeNotifier {
  /// The lint below suggests `{this._history}`, which does not compile: Dart
  /// forbids private named parameters.
  ///
  /// [isIOS] picks which background-monitoring field the [backgroundMonitoring]
  /// getter/setter reach (design 0047 Phase 1); injectable so tests can
  /// exercise both platforms' dispatch on one host. Defaults to the real
  /// platform.
  SettingsController(this._repo, {HistoryRepo? history, bool? isIOS})
      // ignore: prefer_initializing_formals
      : _history = history,
        _isIOS = isIOS ?? Platform.isIOS;

  /// Optional: pruning needs it, everything else does not. Null in tests that
  /// only exercise settings.
  final HistoryRepo? _history;

  final SettingsRepo _repo;

  /// Which platform's background-monitoring field this controller serves.
  final bool _isIOS;

  AppSettings _settings = AppSettings.defaults;
  bool _loaded = false;

  /// Current settings (defaults until [load] completes).
  AppSettings get settings => _settings;

  /// True once the persisted row has been read at least once.
  bool get loaded => _loaded;

  // Convenience pass-throughs the other controllers / UI read frequently.
  bool get autoReconnect => _settings.autoReconnect;
  int get pollIntervalMs => _settings.pollIntervalMs;

  /// The running platform's background-monitoring switch — Android's field or
  /// iOS's, never both (design 0047 Phase 1). ONE getter on purpose: the
  /// settings row and `ConnectionController._updateMonitor` both ask "is
  /// background monitoring on HERE", and giving them two fields to choose from
  /// is how a platform reads the other one's default. The fields stay separate
  /// underneath because their defaults differ (Android ON per FB-26, iOS OFF
  /// per 0047 Q4) and because iOS's stored Android column was never a choice —
  /// see [AppSettings.backgroundMonitoringIos].
  bool get backgroundMonitoring => _isIOS
      ? _settings.backgroundMonitoringIos
      : _settings.backgroundMonitoring;
  bool get keepScreenAwake => _settings.keepScreenAwake;

  /// Personal or advanced (design 0063). The navigation shell reads this on
  /// `initState` and again from its listener — it decides how many tabs exist.
  AppMode get mode => _settings.mode;
  AppThemeMode get themeMode => _settings.themeMode;
  AppLang get lang => _settings.lang;
  TempUnit get tempUnit => _settings.tempUnit;
  /// 🔴 **The STORED switch — what the user said, not whether the feature is
  /// running.** Since design 0063 the answer to "is speed on?" is
  /// [AppSettings.speedDetectionEffective], which folds [mode] in. These two
  /// pass-throughs exist for the Settings screen, which has to draw the user's
  /// own answer even while advanced mode is withholding the feature (Q9), and
  /// they are the wrong thing for anybody else to read. `app_mode_test.dart` H9
  /// greps `lib/` to keep that list closed.
  bool get speedDetection => _settings.speedDetection;
  SpeedUnit get speedUnit => _settings.speedUnit;

  /// The STORED switch — see [speedDetection], same rule, same reason.
  bool get gMeterEnabled => _settings.gMeterEnabled;
  String? get gCalibration => _settings.gCalibration;
  String? get homeLayout => _settings.homeLayout;
  RetentionPolicy get retention => _settings.retention;
  bool get rawPacketLog => _settings.rawPacketLog;
  int get logMaxBytes => _settings.logMaxBytes;
  int? get logTrimBudget => _settings.logTrimBudget;

  /// The app-wide warning switch and its three tuning parameters (design 0080
  /// §3.6). See [AppSettings.alertsEnabled] for why the switch defaults OFF and
  /// for the one thing it must never be read to gate.
  bool get alertsEnabled => _settings.alertsEnabled;
  int get alertSustainSec => _settings.alertSustainSec;
  int get alertRepeatMin => _settings.alertRepeatMin;
  int get alertMaxPerEvent => _settings.alertMaxPerEvent;

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
  /// Writes the running platform's field only, mirroring the getter: an iOS
  /// toggle must not overwrite the Android column (the user may move
  /// platforms; each column keeps its own history).
  Future<void> setBackgroundMonitoring(bool v) => update(_isIOS
      ? _settings.copyWith(backgroundMonitoringIos: v)
      : _settings.copyWith(backgroundMonitoring: v));
  Future<void> setKeepScreenAwake(bool v) =>
      update(_settings.copyWith(keepScreenAwake: v));
  /// Switch between personal and advanced (design 0063).
  ///
  /// 🔴 It writes ONE field. Do not "tidy up" by also clearing
  /// [AppSettings.speedDetection] / [AppSettings.gMeterEnabled] here: Q9 rules
  /// that the stored switches survive the round trip, so a user who tries
  /// advanced mode and comes back finds their own choices intact. The
  /// withdrawal of those features is expressed by the effective getters, which
  /// change answer the instant this returns — nothing has to be written for it.
  Future<void> setMode(AppMode v) => update(_settings.copyWith(mode: v));

  Future<void> setThemeMode(AppThemeMode v) =>
      update(_settings.copyWith(themeMode: v));

  /// Choose an accent set (design 0064), or null to go back to "never chose".
  ///
  /// Takes an ID rather than colours, matching what is stored — see
  /// [AppSettings.accentThemeId]. Null goes through `clearAccentTheme` for the
  /// same reason [setGCalibration] does: `copyWith` cannot otherwise express a
  /// nullable field being set back to null, and the difference between "never
  /// chose" and "chose the default" is one we want to keep.
  Future<void> setAccentTheme(String? id) => update(
      _settings.copyWith(accentThemeId: id, clearAccentTheme: id == null));
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

  /// The G meter master switch (design 0045 §3.5 / Q2).
  ///
  /// Same division of labour as [setSpeedDetection]: the confirmation dialog
  /// belongs to the screen, this only records the answer.
  ///
  /// ⚠️ Turning it OFF leaves [setGCalibration] alone on purpose. The mount has
  /// not moved because the user switched a feature off, and making them redo
  /// the wizard to get the feature back would be a punishment for trying it.
  /// "Zero the calibration" is its own row.
  Future<void> setGMeterEnabled(bool v) =>
      update(_settings.copyWith(gMeterEnabled: v));

  /// Store a completed calibration (`GForceCalibration.encode()`), or NULL to
  /// zero it (design 0045 §3.5 — the settings page's "校準歸零" row).
  ///
  /// 🔴 This is the ONLY writer of `settings.g_calibration`, and it goes
  /// through `AppSettings` rather than touching the column. A second path that
  /// wrote the column directly would be erased by the next `saveSettings` —
  /// see the `toMap` warning in `app_settings.dart`.
  Future<void> setGCalibration(String? v) => update(
      _settings.copyWith(gCalibration: v, clearGCalibration: v == null));

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
  /// The app-wide warning switch (design 0080 §3.7.3, Q4).
  ///
  /// Same division of labour as [setSpeedDetection] and [setGMeterEnabled]: the
  /// first-run explanation and the OS permission prompt belong to the SCREEN,
  /// this only records the answer. A setter that asked for permission itself
  /// would make "write the setting" and "obtain consent" one call, so any later
  /// caller — a restore-defaults, a test, a deep link from a notification —
  /// would either block on a dialog it cannot answer or bypass the consent.
  ///
  /// 📌 P2 stores it and shows it. Nothing reads it to decide anything yet; the
  /// permission flow and the evaluator arrive together in P3, because they share
  /// one gate and splitting them would give that gate two versions.
  Future<void> setAlertsEnabled(bool v) =>
      update(_settings.copyWith(alertsEnabled: v));

  /// Seconds a reading must stay past a threshold before it counts (§3.3.1 —
  /// seconds, never sample counts). Clamped to the offered range here as well as
  /// in [AppSettings.fromMap]: the stepper is one caller, and the clamp belongs
  /// where the value is written rather than only where it is read back.
  Future<void> setAlertSustainSec(int v) => update(_settings.copyWith(
      alertSustainSec: _clamp(v, AppSettings.alertSustainMinSec,
          AppSettings.alertSustainMaxSec)));

  Future<void> setAlertRepeatMin(int v) => update(_settings.copyWith(
      alertRepeatMin: _clamp(v, AppSettings.alertRepeatMinMinutes,
          AppSettings.alertRepeatMaxMinutes)));

  Future<void> setAlertMaxPerEvent(int v) => update(_settings.copyWith(
      alertMaxPerEvent: _clamp(v, AppSettings.alertMaxPerEventMin,
          AppSettings.alertMaxPerEventMax)));

  static int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

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
