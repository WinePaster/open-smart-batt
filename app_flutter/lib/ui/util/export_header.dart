/// OpenSmartBatt — export provenance preamble (design 0009 §3.1).
///
/// Every exported file should be able to answer "which build produced this,
/// on what platform, covering what?" without the reader having to guess. The
/// 2026-07-28 field report could only be dated by noticing its CSV was missing
/// two columns — a coincidence, and one that nearly led to reading an app bug
/// (no keep-alive write ⇒ no metadata burst) as a hardware limitation.
///
/// [exportHeaderLines] is PURE (no Flutter, no plugins) so the formatting is
/// unit-testable; the plugin/platform lookup lives in [exportEnvironment].
/// Same split as `export_naming.dart`.
library;

import 'dart:io' show Platform;

import 'package:package_info_plus/package_info_plus.dart';

import 'export_scope.dart';

/// Value used wherever the environment cannot be determined. Never an empty
/// string: a blank field reads as "nobody filled this in", `unknown` reads as
/// "we asked and could not find out".
const String kUnknownEnv = 'unknown';

/// The `#`-preamble lines for an export, WITHOUT the `# ` prefix (the writer
/// adds it, since the log and the CSV emit them at different points).
///
/// Optional fields are omitted entirely rather than rendered empty — a line
/// that says `connections=` tells the reader nothing and looks like a bug.
List<String> exportHeaderLines({
  required String title,
  required DateTime exportedAt,
  required String appBuild,
  required String platform,
  required String scope,
  int? connections,
}) {
  final scopeLine = StringBuffer('scope: $scope');
  if (connections != null) scopeLine.write('  connections=$connections');
  return <String>[
    title,
    'exported: ${exportedAt.toIso8601String()}',
    scopeLine.toString(),
    'app: $appBuild  platform: $platform',
  ];
}

/// Machine-stable description of what an export covers, e.g.
/// `device=battery/1206 session=3`. Deliberately NOT localized: a preamble is
/// read by whoever receives the file (and by us, months later), so it must not
/// change with the exporting phone's UI language.
String exportScopeLabel(ExportTarget target) => switch (target.scope) {
      ExportScope.allDevices => 'all devices',
      ExportScope.currentDevice =>
        'device=${target.classSlug}/${target.ident ?? '-'}',
      ExportScope.currentSession =>
        'device=${target.classSlug}/${target.ident ?? '-'} '
            'session=${target.sessionId}',
    };

/// App build (`version+buildNumber`) and OS description for the preamble.
///
/// Never throws: on a host without the plugin channel (unit tests, unsupported
/// platforms) it degrades to [kUnknownEnv]. A missing preamble field must never
/// be a reason an export fails — the data matters more than its label.
Future<({String build, String platform})> exportEnvironment() async {
  var build = kUnknownEnv;
  try {
    final info = await PackageInfo.fromPlatform();
    build = '${info.version}+${info.buildNumber}';
  } catch (_) {
    // Plugin channel unavailable — keep kUnknownEnv.
  }
  var platform = kUnknownEnv;
  try {
    platform =
        '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  } catch (_) {
    // Unsupported host — keep kUnknownEnv.
  }
  return (build: build, platform: platform);
}
