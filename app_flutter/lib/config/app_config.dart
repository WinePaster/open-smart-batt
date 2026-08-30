/// OpenSmartBatt — per-edition branding (design 0092 §3.3; design 0003 Phase 2).
///
/// WHAT BELONGS HERE, AND WHAT DOES NOT.
///
/// This holds the strings an edition calls ITSELF by — the name in the title
/// bar, the name on an exported file, the project link, which GitHub repo the
/// update check asks about. Nothing here may change what the app DOES: the same
/// build with a different [AppConfig] must decode the same bytes, write the same
/// database and post the same notifications.
///
/// 🔴 It is NOT the app's identity. Which app this IS — the bundle id, the
/// applicationId, the home-screen label — lives in each repo's own native
/// files (design 0003 §3.4), because that is what the OS installs against and
/// it must be settable without a Dart build. Putting it here as well would give
/// the same fact two homes, and this library has already paid for that mistake.
///
/// ⛔ The on-disk database file name is deliberately NOT here (design 0092 §4.3).
/// Two editions install as two apps with two sandboxes, so the same file name
/// cannot collide; making it configurable would only manufacture a difference
/// somebody has to explain later.
library;

import 'package:flutter/widgets.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';

/// Which edition this build is. Selects the word after the app name in
/// Settings → 版本 ("社群版" vs "專業版"), and nothing else.
enum AppEdition { community, pro }

/// Branding for one edition. Build-time constant — never mutated at runtime.
@immutable
class AppConfig {
  const AppConfig({
    required this.appName,
    required this.edition,
    required this.projectUrl,
    required this.updateRepo,
  });

  /// What the app calls itself: title bar, export subjects, notification
  /// titles. Keep it SHORT — it is also the home-screen label's sibling, and
  /// iOS truncates around 12 characters.
  final String appName;

  /// Community vs pro. See [AppEdition].
  final AppEdition edition;

  /// Public project page — the GitHub row in Settings → 關於.
  final String projectUrl;

  /// `owner/repo` the update check queries on GitHub.
  ///
  /// 🔴 null means DO NOT CHECK, and the "檢查更新" row is hidden. That is not a
  /// cosmetic choice: an edition with no release channel of its own that points
  /// at somebody else's releases is telling the user to download a DIFFERENT
  /// app over the top of this one (design 0092 §8.1).
  final String? updateRepo;

  /// The open build's branding. `bootstrap()`'s default, and the value
  /// [AppConfigScope.of] falls back to when no scope is in the tree — so every
  /// widget test that pumps a screen on its own keeps the open strings.
  static const AppConfig open = AppConfig(
    appName: 'OpenSmartBatt',
    edition: AppEdition.community,
    projectUrl: 'https://github.com/WinePaster/open-smart-batt',
    updateRepo: 'WinePaster/open-smart-batt',
  );
}

/// Makes the [AppConfig] readable from anywhere under the app shell.
///
/// An `InheritedWidget` rather than a provider ENTRY POINT on purpose: [of]
/// answers with [AppConfig.open] when no scope is above it, so the existing
/// widget tests — which pump individual screens with no composition root — keep
/// compiling and keep asserting the open strings. A `Provider` would have
/// thrown in every one of them.
class AppConfigScope extends InheritedWidget {
  const AppConfigScope({super.key, required this.config, required super.child});

  final AppConfig config;

  /// The branding in scope, or [AppConfig.open] when there is none.
  static AppConfig of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppConfigScope>()?.config ??
      AppConfig.open;

  @override
  bool updateShouldNotify(AppConfigScope oldWidget) =>
      oldWidget.config != config;
}

/// The localized word for an edition, used after the app name in Settings.
extension AppEditionLabel on AppEdition {
  String label(AppLocalizations l10n) => switch (this) {
    AppEdition.community => l10n.editionCommunity,
    AppEdition.pro => l10n.editionPro,
  };
}
