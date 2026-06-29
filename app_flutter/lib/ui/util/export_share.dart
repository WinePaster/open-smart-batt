/// Open-RCE-Batt — file export + share helper.
///
/// Writes a text blob (CSV / `.log`) to a temp file and hands it to the system
/// share sheet via `share_plus`. Used by the History (CSV) and Settings
/// (data CSV / diagnostics `.log`) screens.
library;

import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Timestamp fragment for export filenames, e.g. `20260629-130912`.
String exportStamp([DateTime? at]) =>
    DateFormat('yyyyMMdd-HHmmss').format(at ?? DateTime.now());

/// Write [content] to a temp file named [filename] and open the share sheet.
///
/// [mimeType] hints the receiving app (`text/csv`, `text/plain`). [subject] is
/// used by share targets that support one (e.g. email). Returns the
/// [ShareResultStatus] so callers can surface success/dismissal.
Future<ShareResultStatus> shareTextAsFile({
  required String content,
  required String filename,
  String? mimeType,
  String? subject,
}) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$filename');
  await file.writeAsString(content);
  final result = await Share.shareXFiles(
    [XFile(file.path, mimeType: mimeType, name: filename)],
    subject: subject,
  );
  return result.status;
}
