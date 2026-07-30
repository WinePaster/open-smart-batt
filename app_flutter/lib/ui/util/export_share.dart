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

/// Clips [rect] to [bounds] — the coordinate space the platform validates the
/// anchor against, i.e. the Flutter view. Returns `null` when nothing survives,
/// so the caller passes no anchor and gets the system default position.
///
/// 🔴 **Required, not cosmetic (FB-40, 2026-07-30 `016`).** iOS rejects an
/// anchor that is zero-sized or reaches outside the source view, and it does so
/// on **iPhone as well as iPad** — even though only iPad renders the sheet as a
/// popover. The rejection is a `PlatformException` out of `shareXFiles`, which
/// the export call sites catch and show as 「匯出失敗」, so the export is lost:
///
/// ```
/// sharePositionOrigin: argument must be set,
/// {{15, -76.928543864442759}, {345, 369}} must be non-zero and within
/// coordinate space of source view: {{0, 0}, {375, 667}}
/// ```
///
/// That anchor is the Settings 「資料」 card (`ListView` padding 15 ⇒ x = 15,
/// width = 375 − 30 = 345) scrolled 77 pt above the viewport top. Anchors come
/// from the *card*, not the screen, so any card the user scrolls past the top
/// or bottom edge produces an out-of-bounds Rect on every phone-sized screen.
Rect? clampShareAnchor(Rect rect, Rect bounds) {
  final clipped = rect.intersect(bounds);
  return clipped.isEmpty ? null : clipped;
}

/// Computes the share-sheet anchor [Rect] for the widget behind [context],
/// clipped to the view so the platform cannot reject it (see [clampShareAnchor]).
///
/// Returns `null` if the render object isn't a laid-out [RenderBox] yet, or if
/// the widget is scrolled entirely out of view. Callers then fall back to the
/// system default position, which is harmless everywhere — only iPad uses the
/// anchor to place the popover.
Rect? sharePositionFromContext(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  final view = View.of(context);
  final bounds = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  if (bounds.isEmpty) return null;
  return clampShareAnchor(sharePositionFromBox(box), bounds);
}

/// Write [content] to a temp file named [filename] and open the share sheet.
///
/// [mimeType] hints the receiving app (`text/csv`, `text/plain`). [subject] is
/// used by share targets that support one (e.g. email). Returns the
/// [ShareResultStatus] so callers can surface success/dismissal.
/// [sharePositionOrigin] anchors the share sheet on iPad (where it is a
/// popover); compute it at the call site from the triggering widget via
/// [sharePositionFromContext], which clips it to the view. Only iPad *uses* the
/// anchor, but iOS *validates* it on every device, so it must be in bounds or
/// `null` — never a raw un-clipped widget Rect (FB-40).
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
