/// OpenSmartBatt — GitHub release update check.
///
/// Queries the public GitHub Releases API for the latest tag and compares it to
/// the running version. No device data is sent; only GitHub is contacted. The
/// app never auto-installs — it points the user to the release page to download
/// manually (Android side-load).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// A newer release found on GitHub.
class UpdateInfo {
  const UpdateInfo({
    required this.latestTag,
    required this.htmlUrl,
    this.apkUrl,
  });

  /// e.g. "v0.4.0".
  final String latestTag;

  /// The release page (fallback download location).
  final String htmlUrl;

  /// Direct .apk asset URL, if present.
  final String? apkUrl;
}

/// Pick the URL the "download" action should open for a given platform (D.6).
/// Pure + unit-testable (no `dart:io` Platform read here — the caller passes
/// [isIOS]).
///
/// iOS has no APK side-load path, so it must ALWAYS open the release page
/// ([UpdateInfo.htmlUrl]) and never an `.apk` asset. Android prefers the direct
/// [UpdateInfo.apkUrl] when present, falling back to the release page.
String updateUrlFor(UpdateInfo update, {required bool isIOS}) =>
    isIOS ? update.htmlUrl : (update.apkUrl ?? update.htmlUrl);

class UpdateService {
  const UpdateService({required this.repo});

  /// `owner/repo` on GitHub. Injected (design 0092 §8.1) rather than hard-coded:
  /// an edition with no releases of its own must not send its users to somebody
  /// else's, and the caller is the only place that knows which edition this is.
  final String repo;

  String get _api => 'https://api.github.com/repos/$repo/releases/latest';

  /// Release listing page (used as the manual-download fallback).
  String get releasesPage => 'https://github.com/$repo/releases';

  /// Returns the latest release iff it is strictly newer than [currentVersion]
  /// (e.g. "0.3.2"); returns null when up-to-date or on any error (silent).
  Future<UpdateInfo?> checkForUpdate(String currentVersion) async {
    try {
      final res = await http.get(
        Uri.parse(_api),
        headers: const {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String?) ?? '';
      if (tag.isEmpty || !_isNewer(tag, currentVersion)) return null;

      String? apk;
      final assets = json['assets'];
      if (assets is List) {
        for (final a in assets) {
          final name = (a is Map ? a['name'] as String? : null) ?? '';
          if (name.toLowerCase().endsWith('.apk')) {
            apk = a['browser_download_url'] as String?;
            break;
          }
        }
      }
      return UpdateInfo(
        latestTag: tag,
        htmlUrl: (json['html_url'] as String?) ?? releasesPage,
        apkUrl: apk,
      );
    } catch (_) {
      return null; // unreachable / rate-limited / malformed → treat as no update
    }
  }

  /// True if [tag] (vMAJOR.MINOR.PATCH[-pre]) core version > [current].
  /// Pre-release suffixes are ignored for the comparison.
  static bool _isNewer(String tag, String current) {
    final a = _parse(tag);
    final b = _parse(current);
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  static List<int> _parse(String v) {
    final core = v.replaceFirst(RegExp('^v'), '').split('-').first;
    final parts = core.split('.');
    return List<int>.generate(
      3,
      (i) => i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0,
    );
  }
}
