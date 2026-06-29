/// Open-RCE-Batt — app settings model (mockup screen 5).
///
/// PURE Dart. Persisted as a single key/value row set in our SQLite.
library;

/// Display language.
enum AppLang { zhHant, en }

/// Temperature display unit.
enum TempUnit { celsius, fahrenheit }

/// App theme preference. [auto] follows the OS (system) brightness. DEFAULT is
/// [light].
enum AppThemeMode { light, dark, auto }

/// All user-configurable settings. Defaults match the mockup's shown state
/// (raw-packet diagnostics OFF by default).
class AppSettings {
  // --- connection ---
  /// Auto-reconnect when the link drops.
  final bool autoReconnect;

  /// Telemetry poll / keep-alive interval (ms). Mockup options: 500/1000/2000.
  final int pollIntervalMs;

  /// Keep the connection alive (and logging) while the screen is off.
  final bool backgroundKeepAlive;

  // --- display ---
  /// Theme preference (light / dark / auto). DEFAULT [AppThemeMode.light].
  final AppThemeMode themeMode;
  final AppLang lang;
  final TempUnit tempUnit;

  // --- data ---
  /// Auto-write telemetry to history while connected.
  final bool autoLog;

  // --- diagnostics ---
  /// Log raw TX/RX BLE packets as hex. DEFAULT OFF.
  final bool rawPacketLog;

  /// Diagnostic log size cap (bytes) before rotation. Mockup: 5 MB / 20 MB.
  final int logMaxBytes;

  const AppSettings({
    this.autoReconnect = true,
    this.pollIntervalMs = 1000,
    this.backgroundKeepAlive = false,
    this.themeMode = AppThemeMode.light,
    this.lang = AppLang.zhHant,
    this.tempUnit = TempUnit.celsius,
    this.autoLog = true,
    this.rawPacketLog = false,
    this.logMaxBytes = 5 * 1024 * 1024,
  });

  /// Defaults (matches the mockup's initial UI state).
  static const AppSettings defaults = AppSettings();

  AppSettings copyWith({
    bool? autoReconnect,
    int? pollIntervalMs,
    bool? backgroundKeepAlive,
    AppThemeMode? themeMode,
    AppLang? lang,
    TempUnit? tempUnit,
    bool? autoLog,
    bool? rawPacketLog,
    int? logMaxBytes,
  }) =>
      AppSettings(
        autoReconnect: autoReconnect ?? this.autoReconnect,
        pollIntervalMs: pollIntervalMs ?? this.pollIntervalMs,
        backgroundKeepAlive: backgroundKeepAlive ?? this.backgroundKeepAlive,
        themeMode: themeMode ?? this.themeMode,
        lang: lang ?? this.lang,
        tempUnit: tempUnit ?? this.tempUnit,
        autoLog: autoLog ?? this.autoLog,
        rawPacketLog: rawPacketLog ?? this.rawPacketLog,
        logMaxBytes: logMaxBytes ?? this.logMaxBytes,
      );

  Map<String, Object?> toMap() => {
        'auto_reconnect': autoReconnect ? 1 : 0,
        'poll_interval_ms': pollIntervalMs,
        'background_keep_alive': backgroundKeepAlive ? 1 : 0,
        'theme_mode': themeMode.name,
        'lang': lang.name,
        'temp_unit': tempUnit.name,
        'auto_log': autoLog ? 1 : 0,
        'raw_packet_log': rawPacketLog ? 1 : 0,
        'log_max_bytes': logMaxBytes,
      };

  static AppSettings fromMap(Map<String, Object?> m) => AppSettings(
        autoReconnect: (m['auto_reconnect'] as num?)?.toInt() != 0,
        pollIntervalMs: (m['poll_interval_ms'] as num?)?.toInt() ?? 1000,
        backgroundKeepAlive: (m['background_keep_alive'] as num?)?.toInt() == 1,
        themeMode: _themeModeFromMap(m),
        lang: AppLang.values.firstWhere(
          (e) => e.name == m['lang'],
          orElse: () => AppLang.zhHant,
        ),
        tempUnit: TempUnit.values.firstWhere(
          (e) => e.name == m['temp_unit'],
          orElse: () => TempUnit.celsius,
        ),
        autoLog: (m['auto_log'] as num?)?.toInt() != 0,
        rawPacketLog: (m['raw_packet_log'] as num?)?.toInt() == 1,
        logMaxBytes:
            (m['log_max_bytes'] as num?)?.toInt() ?? (5 * 1024 * 1024),
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
}
