/// OpenSmartBatt — multi-link experiment: build flag and the ruled constants
/// (design 0103, owner rulings D1–D7, 2026-11-11).
///
/// ## The flag is COMPILE-TIME, on purpose (0103 §7 Q1 / D4)
///
/// TestFlight's internal and external groups install the SAME binary, and an
/// Android prerelease APK is downloadable by anyone, so a runtime toggle that
/// is merely hidden would still ship the unvalidated multi-link code to every
/// user. With `--dart-define=OSB_MULTILINK=true` absent the experiment does
/// not exist in the build: no switch in Settings, no controller, and every
/// hook in `ConnectionController` stays null — the single-link path is the
/// only path (0103 §3.1.2, pinned by `test/multi_link_off_test.dart`).
///
/// Build the internal test binary with:
///
///     flutter build ios --dart-define=OSB_MULTILINK=true …
library;

/// True only in a build made with `--dart-define=OSB_MULTILINK=true`.
const bool kMultiLinkBuild = bool.fromEnvironment('OSB_MULTILINK');

/// What happens to the other live links while a power bank is the primary
/// link (D1: 「我們先假設暫停 真的不行再斷開」).
enum PowerBankOthersMode {
  /// Stop polling, keep the link and its notify subscription (0046a §5.6).
  pause,

  /// Fallback if design 0103 phase 0 shows a paused link drops: disconnect,
  /// reconnect when the power bank is released.
  disconnect,
}

/// Ruled constants. One place, so the D1 fallback and any re-tuning from the
/// field logs (0103 §4) are one-line changes.
abstract final class MultiLinkConfig {
  /// D6 — 「3台如何」. Total links, primary included.
  static const int maxConcurrentLinks = 3;

  /// D1. Switch to [PowerBankOthersMode.disconnect] if phase 0 fails.
  static const PowerBankOthersMode powerBankOthers = PowerBankOthersMode.pause;

  /// D5 ①: the window is the last N keep-alive writes (~1 min at 1 Hz).
  static const int demoteWindowWrites = 60;

  /// D5 ②: mean write time at or above this demotes the link.
  static const int demoteAvgMs = 500;

  /// D5 ⑤: how long a demoted link stays paused before it is retried.
  static const Duration demoteRetryAfter = Duration(minutes: 5);

  /// D5 ⑤: demotions per session after which the link is left out until the
  /// user connects it by hand.
  static const int demoteMaxPerSession = 3;

  /// How often the demotion rule is evaluated.
  static const Duration demoteCheckEvery = Duration(seconds: 10);

  /// Backoff for a secondary link that failed to connect or dropped.
  static const Duration secondaryRetryBase = Duration(seconds: 30);
  static const Duration secondaryRetryCap = Duration(minutes: 5);

  /// Marker files (`AckMarker`), not settings columns: the experiment must
  /// not change the database schema, or installing a normal build over this
  /// one would be a schema DOWNGRADE.
  static const String enabledMarker = 'multilink_experiment_on';
  static const String skipPowerBankPromptMarker =
      'multilink_powerbank_prompt_skip';
}
