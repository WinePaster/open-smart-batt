/// OpenSmartBatt — which app build is running (design 0010).
///
/// Lives in `state/`, not `models/`: it depends on a Flutter plugin, and the
/// models layer is documented as pure Dart with no Flutter imports.
///
/// Resolved ONCE at startup by [AppServices] and injected downstream, so no
/// hot path ever waits on a plugin channel.
library;

import 'dart:io' show Platform;

import 'package:package_info_plus/package_info_plus.dart';

/// Used wherever the environment cannot be determined. Never an empty string:
/// blank reads as "nobody filled this in", `unknown` reads as "we asked and
/// could not find out".
const String kUnknownEnv = 'unknown';

/// App build (`version+buildNumber`) and OS description.
///
/// Never throws. On a host without the plugin channel (unit tests, unsupported
/// platforms) it degrades to [kUnknownEnv] — a missing version label must never
/// take down an export, let alone recording.
Future<({String build, String platform})> resolveBuildInfo() async {
  var build = kUnknownEnv;
  try {
    final info = await PackageInfo.fromPlatform();
    build = '${info.version}+${info.buildNumber}';
  } catch (_) {
    // Plugin channel unavailable — keep kUnknownEnv.
  }
  var platform = kUnknownEnv;
  try {
    platform = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  } catch (_) {
    // Unsupported host — keep kUnknownEnv.
  }
  return (build: build, platform: platform);
}
