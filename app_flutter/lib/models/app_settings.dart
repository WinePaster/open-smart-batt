/// OpenSmartBatt — app settings model (mockup screen 5).
///
/// PURE Dart. Persisted as a single key/value row set in our SQLite.
library;

/// Display language. [system] follows the device locale.
enum AppLang { system, zhHant, en }

/// Temperature display unit.
enum TempUnit { celsius, fahrenheit }

/// App theme preference. [auto] follows the OS (system) brightness. DEFAULT is
/// [light].
enum AppThemeMode { light, dark, auto }

/// How long recorded telemetry history is kept (design 0011). DEFAULT
/// [forever].
///
/// This REPLACED an "auto-log" on/off switch. That switch's only effect was
/// whether history rows were written at all, which made it the history
/// feature's master off button — and the people who turned it off were exactly
/// the people who later could not produce data when asked for it. A year of
/// history costs about 6 MB, so the storage argument it existed for never held.
/// The useful control is how long to keep, not whether to record.
enum RetentionPolicy {
  days30,
  days90,
  days365,

  /// Never prune. The default: a diagnostic app should not silently discard
  /// the dealer's history, and nobody should lose data merely by upgrading.
  forever;

  /// Age beyond which rows are pruned, or null for [forever].
  Duration? get maxAge => switch (this) {
        RetentionPolicy.days30 => const Duration(days: 30),
        RetentionPolicy.days90 => const Duration(days: 90),
        RetentionPolicy.days365 => const Duration(days: 365),
        RetentionPolicy.forever => null,
      };
}

/// All user-configurable settings. Defaults match the mockup's shown state
/// (raw-packet diagnostics OFF by default).
class AppSettings {
  // --- connection ---
  /// Auto-reconnect when the link drops.
  final bool autoReconnect;

  /// Telemetry poll / keep-alive interval (ms). Mockup options: 500/1000/2000.
  final int pollIntervalMs;

  /// Keep monitoring while the app is backgrounded / the screen is off, via the
  /// Android foreground service (design 0008). Defaults ON — without it the OS
  /// freezes the process and telemetry stops, which is the whole problem.
  ///
  /// No-op on iOS, which needs a different mechanism (design 0009).
  final bool backgroundMonitoring;

  /// Keep the *screen* from turning off while connected. Handy when the phone
  /// is mounted and you want to watch the numbers while riding.
  ///
  /// This is NOT a background-execution setting; it used to be called
  /// `backgroundKeepAlive`, which is what it was named while it was the only
  /// mitigation available, but it only ever drove a wakelock. Persisted under
  /// the original `background_keep_alive` column so existing choices survive
  /// (SQLite RENAME COLUMN needs 3.25+, i.e. API 30, and minSdk here is 24).
  final bool keepScreenAwake;

  // --- display ---
  /// Theme preference (light / dark / auto). DEFAULT [AppThemeMode.light].
  final AppThemeMode themeMode;
  final AppLang lang;
  final TempUnit tempUnit;

  // --- data ---
  /// How long history is kept. Telemetry is ALWAYS recorded while connected
  /// (design 0011); this only decides when old rows are pruned.
  final RetentionPolicy retention;

  // --- diagnostics ---
  /// Log raw TX/RX BLE packets as hex. DEFAULT OFF.
  final bool rawPacketLog;

  /// Diagnostic log size cap (bytes) before rotation. Mockup: 5 MB / 20 MB.
  final int logMaxBytes;

  /// The budgets the UI offers, smallest first. `fromMap` normalises anything
  /// else to [defaultLogMaxBytes] — a stored value outside this set would leave
  /// the segmented control with NOTHING selected (it matches on `==`), which
  /// reads as a broken screen rather than a stale preference.
  static const List<int> logMaxBytesOptions = [
    20 * 1024 * 1024,
    100 * 1024 * 1024,
  ];

  /// Default diagnostic-log budget. Raised from 5 MB on 2026-07-29: field logs
  /// run about 13 KB/min while connected, so 5 MB started rotating after ~6.5 h
  /// of dense capture — and rotation drops the OLDEST rows, which is exactly
  /// where the connect-time GATT dump and metadata burst live.
  static const int defaultLogMaxBytes = 20 * 1024 * 1024;

  const AppSettings({
    this.autoReconnect = true,
    this.pollIntervalMs = 1000,
    this.backgroundMonitoring = true,
    this.keepScreenAwake = false,
    this.themeMode = AppThemeMode.light,
    this.lang = AppLang.zhHant,
    this.tempUnit = TempUnit.celsius,
    this.retention = RetentionPolicy.forever,
    this.rawPacketLog = false,
    this.logMaxBytes = defaultLogMaxBytes,
  });

  /// Defaults (matches the mockup's initial UI state).
  static const AppSettings defaults = AppSettings();

  AppSettings copyWith({
    bool? autoReconnect,
    int? pollIntervalMs,
    bool? backgroundMonitoring,
    bool? keepScreenAwake,
    AppThemeMode? themeMode,
    AppLang? lang,
    TempUnit? tempUnit,
    RetentionPolicy? retention,
    bool? rawPacketLog,
    int? logMaxBytes,
  }) =>
      AppSettings(
        autoReconnect: autoReconnect ?? this.autoReconnect,
        pollIntervalMs: pollIntervalMs ?? this.pollIntervalMs,
        backgroundMonitoring: backgroundMonitoring ?? this.backgroundMonitoring,
        keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
        themeMode: themeMode ?? this.themeMode,
        lang: lang ?? this.lang,
        tempUnit: tempUnit ?? this.tempUnit,
        retention: retention ?? this.retention,
        rawPacketLog: rawPacketLog ?? this.rawPacketLog,
        logMaxBytes: logMaxBytes ?? this.logMaxBytes,
      );

  Map<String, Object?> toMap() => {
        'auto_reconnect': autoReconnect ? 1 : 0,
        'poll_interval_ms': pollIntervalMs,
        // Column keeps its original name: it always *was* the screen wakelock,
        // only the Dart field was misnamed. See [keepScreenAwake].
        'background_keep_alive': keepScreenAwake ? 1 : 0,
        'background_monitoring': backgroundMonitoring ? 1 : 0,
        'theme_mode': themeMode.name,
        'lang': lang.name,
        'temp_unit': tempUnit.name,
        'retention': retention.name,
        'raw_packet_log': rawPacketLog ? 1 : 0,
        'log_max_bytes': logMaxBytes,
      };

  static AppSettings fromMap(Map<String, Object?> m) => AppSettings(
        autoReconnect: (m['auto_reconnect'] as num?)?.toInt() != 0,
        pollIntervalMs: (m['poll_interval_ms'] as num?)?.toInt() ?? 1000,
        keepScreenAwake: (m['background_keep_alive'] as num?)?.toInt() == 1,
        // Pre-v6 rows have no such column (NULL) — those users predate the
        // foreground service, so they get the new default ON rather than OFF.
        backgroundMonitoring:
            (m['background_monitoring'] as num?)?.toInt() != 0,
        themeMode: _themeModeFromMap(m),
        lang: AppLang.values.firstWhere(
          (e) => e.name == m['lang'],
          orElse: () => AppLang.zhHant,
        ),
        tempUnit: TempUnit.values.firstWhere(
          (e) => e.name == m['temp_unit'],
          orElse: () => TempUnit.celsius,
        ),
        retention: RetentionPolicy.values.firstWhere(
          (r) => r.name == m['retention'],
          orElse: () => RetentionPolicy.forever,
        ),
        rawPacketLog: (m['raw_packet_log'] as num?)?.toInt() == 1,
        logMaxBytes: _normaliseLogMaxBytes((m['log_max_bytes'] as num?)?.toInt()),
      );

  /// Resolve the theme mode from a persisted row.
  ///
  /// Prefers the new `theme_mode` string column. Falls back to migrating the
  /// legacy `dark_theme` bool/int (true → dark, false → light). Defaults to
  /// [AppThemeMode.light] when neither is present.
  static AppThemeMode _themeModeFromMap(Map<String, Object?> m) {
    final raw = m['theme_mode'];
    if (raw is String && raw.isNotEmpty) {
      for (final e in AppThemeMode.values) {
        if (e.name == raw) return e;
      }
    }
    final legacy = m['dark_theme'];
    if (legacy != null) {
      final on = (legacy as num).toInt() != 0;
      return on ? AppThemeMode.dark : AppThemeMode.light;
    }
    return AppThemeMode.light;
  }

  /// Map a stored budget onto one the UI can display. Legacy 5 MB rows (the
  /// pre-2026-07-29 default) land on the new default rather than leaving the
  /// segmented control blank.
  static int _normaliseLogMaxBytes(int? stored) =>
      logMaxBytesOptions.contains(stored) ? stored! : defaultLogMaxBytes;
}
