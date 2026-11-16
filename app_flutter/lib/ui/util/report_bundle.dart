/// OpenSmartBatt — the report bundle's zip (design 0100 §3.3).
///
/// No Flutter imports: a bundle is files in, one file out, so it is tested
/// against a temp directory with no widget harness.
///
/// ```
/// opensmartbatt-report-<class>-<ident>-<stamp>.zip
/// ├── opensmartbatt-history-<class>-<ident>-<stamp>.csv
/// ├── opensmartbatt-<class>-<ident>-<stamp>.log
/// └── note.txt          ← only when the user wrote something
/// ```
///
/// The members keep the names the stand-alone exports use, so a bundle
/// unzipped into `feedback_log/` needs no renaming and `fbparse` sees the same
/// files it always has.
///
/// 🔑 The note is its OWN file, never a line in the CSV or log preamble: those
/// headers are machine-read, and free text inside them would be one more input
/// `fbparse` has to defend against.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';

import '../../config/app_config.dart' show AppEdition;
import 'export_naming.dart';
import 'export_scope.dart';

/// The member name of the user's note inside a bundle.
const String kReportNoteFileName = 'note.txt';

/// The bundle's own filename for [target].
String reportBundleFileName(ExportTarget target, {required String stamp}) =>
    exportFileName(
      base: 'opensmartbatt-report',
      classSlug: target.classSlug,
      ident: target.ident,
      stamp: stamp,
      extension: 'zip',
    );

/// The text of `note.txt`, or null when [note] is blank — an empty note is
/// left out rather than shipped as a file that says nothing.
///
/// A short `#` preamble names the build and the instant, so a note that
/// travels apart from its zip can still be placed.
String? reportNoteText({
  required String note,
  required String appName,
  required String appBuild,
  required String platform,
  required AppEdition edition,
  required String scope,
  required DateTime at,
  // design 0106 Phase 5: the export header's `vehicle:` value, or null (no
  // line). Never a name.
  String? vehicle,
}) {
  final body = note.trim();
  if (body.isEmpty) return null;
  return [
    '# $appName problem report',
    '# app: $appBuild  platform: $platform',
    '# edition: ${edition.name}',
    '# exported: ${at.toIso8601String()}',
    '# scope: $scope',
    if (vehicle != null) '# vehicle: $vehicle',
    '',
    body,
    '',
  ].join('\n');
}

/// Writes [zip] holding [members] (each under its given name) and, when
/// non-null, [noteText] as [kReportNoteFileName]. Returns [zip].
///
/// Members are added from disk one at a time, so a large CSV never has to sit
/// in memory whole (the same reason it is streamed into its file — design
/// 0030 T4b).
///
/// 🔴 On a background isolate (realme 9 Pro+, 2026-11-16). `archive`'s
/// encoder deflates each member synchronously — `addFile` is `async` only for
/// its two `stat` calls — so a log near the 100 MiB cap froze the UI isolate
/// for the whole compression, long enough for Android's not-responding
/// dialog. Files, paths and strings are all sendable.
Future<File> writeReportBundle({
  required File zip,
  required List<({File file, String name})> members,
  String? noteText,
}) {
  final zipPath = zip.path;
  final parts = [for (final m in members) (path: m.file.path, name: m.name)];
  return Isolate.run(() {
    _writeReportBundleSync(zipPath, parts, noteText);
    return File(zipPath);
  });
}

void _writeReportBundleSync(
  String zipPath,
  List<({String path, String name})> parts,
  String? noteText,
) {
  final zip = File(zipPath);
  if (zip.existsSync()) zip.deleteSync();
  final enc = ZipFileEncoder()..create(zipPath);
  try {
    for (final m in parts) {
      enc.addFileSync(File(m.path), m.name);
    }
    if (noteText != null) {
      enc.addArchiveFile(ArchiveFile.string(kReportNoteFileName, noteText));
    }
  } finally {
    enc.closeSync();
  }
}
