/// OpenSmartBatt — "Report a problem": one tap, one file (design 0100).
///
/// One dialog, one scope choice, one [ExportTarget] ⇒ the all-data CSV, the
/// diagnostic log and the user's note, zipped and handed to the share sheet.
///
/// 🔑 Why ONE target matters more than the zip: a reporter used to export the
/// CSV and the log separately, two scope sheets apart, and twice in the field
/// (batches 2026.08.03-002 and 2026.08.13-001) the two files of one sitting
/// named the same unit two different ways (FB-68). Both files here are written
/// from the same target, so that cannot happen.
///
/// Nothing leaves the phone except through the share sheet — the app still
/// makes no network request (design 0100 §1.3).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../demo/demo.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../util/export_header.dart';
import '../util/export_scope.dart';
import '../util/export_share.dart';
import '../util/export_writers.dart';
import '../util/report_bundle.dart';

/// Run the report flow from [context].
///
/// [deviceId] pins the export to one unit (the capture wizard passes the unit
/// it just scripted); null lets the user choose in the scope sheet.
/// [afterCapture] tells the dialog that a guided capture has just recorded raw
/// frames, even if the wizard has since put the logging switch back off.
/// [onBusy] brackets the work after the user's last decision, for a spinner.
Future<void> reportProblem(
  BuildContext context, {
  String? deviceId,
  bool afterCapture = false,
  void Function(bool busy)? onBusy,
}) async {
  final settings = context.read<SettingsController>();
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context);
  final decision = await showDialog<_ReportDecision>(
    context: context,
    builder: (_) => _ReportDialog(
      // The wizard borrows the switch and gives it back (capture_wizard.dart
      // `_finish`), so after a capture the frames are in the table whatever
      // the switch now says — the FB-37 disclosure applies, FB-32's does not.
      rawFrames: settings.rawPacketLog || afterCapture,
    ),
  );
  if (decision == null || !context.mounted) return;
  if (decision.enableLogging) {
    // FB-32 §3.2: enabling CANCELS. The rows do not exist yet, so carrying on
    // would hand over an equally empty log while implying the gap was fixed.
    await settings.setRawPacketLog(true);
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 3200),
      content: Text(l10n.rawLogEnabledSnack),
    ));
    return;
  }
  // design 0100 Q4: no "this connection only" — the CSV has no such slice, and
  // two files scoped differently is the FB-68 problem again.
  final target =
      await chooseExportScope(context, offerSession: false, deviceId: deviceId);
  if (target == null || !context.mounted) return;
  // design 0097: demo data never leaves the app.
  if (isDemoDeviceId(target.deviceId)) {
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 1600),
      content: Text(l10n.reportDemoRefused),
    ));
    return;
  }
  final capture = ExportCapture.of(context, target);
  // iPad popover anchor (D.7), and validated on every iPhone (FB-40).
  final origin = sharePositionFromContext(context);
  onBusy?.call(true);
  try {
    // One stamp for all three names, so the members visibly belong together.
    final stamp = exportStamp();
    final csvName = allDataCsvFileName(target, stamp: stamp);
    final csvFile = await exportTempFile(csvName);
    final rows = await writeAllDataCsv(capture, csvFile);
    final log = await buildDiagnosticLog(capture);
    final logName = diagnosticLogFileName(target, stamp: stamp);
    final logFile = await exportTempFile(logName);
    final hasLog = log.trim().isNotEmpty;
    if (hasLog) await logFile.writeAsString(log);
    final noteText = reportNoteText(
      note: decision.note,
      appName: capture.appName,
      appBuild: capture.services.appBuild,
      platform: capture.services.platform,
      edition: capture.edition,
      scope: exportScopeLabel(target),
      at: DateTime.now(),
    );
    // A note alone is still a report ("it will not connect" may come with no
    // rows at all); only a bundle with nothing in it is refused.
    if (rows == 0 && !hasLog && noteText == null) {
      await csvFile.delete().catchError((_) => csvFile);
      messenger.showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1600),
        content: Text(l10n.commonNoRecordsToExport),
      ));
      return;
    }
    final zipName = reportBundleFileName(target, stamp: stamp);
    final zip = await writeReportBundle(
      zip: await exportTempFile(zipName),
      members: [
        if (rows > 0) (file: csvFile, name: csvName),
        if (hasLog) (file: logFile, name: logName),
      ],
      noteText: noteText,
    );
    await shareExportFile(
      file: zip,
      filename: zipName,
      mimeType: 'application/zip',
      subject: l10n.reportSubject(capture.appName),
      sharePositionOrigin: origin,
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 1600),
      content: Text(l10n.commonExportFailed('$e')),
    ));
  } finally {
    onBusy?.call(false);
  }
}

class _ReportDecision {
  const _ReportDecision.send(this.note) : enableLogging = false;
  const _ReportDecision.enableLogging()
      : note = '',
        enableLogging = true;

  final String note;
  final bool enableLogging;
}

/// The one "here is what this file is" dialog (design 0100 §3.2), with the
/// note field. It REUSES the FB-32 / FB-37 sentences rather than rewording
/// them: the stand-alone log export says the same thing about the same file.
class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.rawFrames});

  /// Raw frames are (or will be) in the log ⇒ FB-37's address disclosure;
  /// otherwise FB-32's "this log holds only events" warning.
  final bool rawFrames;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = TextStyle(color: context.colors.muted, height: 1.5);
    return AlertDialog(
      title: Text(l10n.reportDialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.reportDialogBody, style: muted),
            const SizedBox(height: 12),
            Text(
              widget.rawFrames
                  ? l10n.rawLogContentsDialogTitle
                  : l10n.rawLogOffDialogTitle,
              key: const ValueKey('report-raw-title'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              widget.rawFrames
                  ? l10n.rawLogContentsDialogBody
                  : l10n.rawLogOffDialogBody,
              style: muted,
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('report-note'),
              controller: _note,
              minLines: 3,
              maxLines: 6,
              maxLength: 2000,
              decoration: InputDecoration(
                hintText: l10n.reportNoteHint,
                helperText: l10n.reportNotePrivacy,
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        if (!widget.rawFrames)
          TextButton(
            key: const ValueKey('report-enable-logging'),
            onPressed: () => Navigator.of(context)
                .pop(const _ReportDecision.enableLogging()),
            child: Text(l10n.rawLogOffEnable),
          ),
        TextButton(
          key: const ValueKey('report-send'),
          onPressed: () =>
              Navigator.of(context).pop(_ReportDecision.send(_note.text)),
          child: Text(l10n.reportSend),
        ),
      ],
    );
  }
}
