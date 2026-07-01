/// OpenSmartBatt — file export + share helper.
///
/// Writes a text blob (CSV / `.log`) to a temp file and hands it to the system
/// share sheet via `share_plus`. Used by the History (CSV) and Settings
/// (data CSV / diagnostics `.log`) screens.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Timestamp fragment for export filenames, e.g. `20260629-130912`.
String exportStamp([DateTime? at]) =>
    DateFormat('yyyyMMdd-HHmmss').format(at ?? DateTime.now());

/// Pure geometry helper (no [BuildContext], so it is unit-testable): the global
/// bounds of a laid-out [box], used as the iPad share-sheet popover anchor.
Rect sharePositionFromBox(RenderBox box) =>
    box.localToGlobal(Offset.zero) & box.size;

/// Computes the iPad share-sheet popover anchor [Rect] for the widget behind
/// [context]. Returns `null` if the render object isn't a laid-out [RenderBox]
/// yet (callers then fall back to the system default). iPhone ignores the
/// anchor, so passing `null` there is harmless.
Rect? sharePositionFromContext(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return sharePositionFromBox(box);
}

/// Write [content] to a temp file named [filename] and open the share sheet.
///
/// [mimeType] hints the receiving app (`text/csv`, `text/plain`). [subject] is
/// used by share targets that support one (e.g. email). Returns the
/// [ShareResultStatus] so callers can surface success/dismissal.
/// [sharePositionOrigin] anchors the share sheet on iPad (where it is a
/// popover); compute it at the call site from the triggering widget via
/// [sharePositionFromContext]. iPhone/Android ignore it.
Future<ShareResultStatus> shareTextAsFile({
  required String content,
  required String filename,
  String? mimeType,
  String? subject,
  Rect? sharePositionOrigin,
}) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$filename');
  await file.writeAsString(content);
  final result = await Share.shareXFiles(
    [XFile(file.path, mimeType: mimeType, name: filename)],
    subject: subject,
    sharePositionOrigin: sharePositionOrigin,
  );
  return result.status;
}
