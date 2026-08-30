/// OpenSmartBatt — writing and sharing one history CSV.
///
/// Extracted from `history_screen.dart` unchanged when design 0065 gave the
/// device detail page a second export button. Everything a history CSV states
/// about itself is decided here, so the two surfaces cannot start describing
/// the same database differently.
///
/// 🔑 It takes a resolved [ExportTarget] and never resolves one itself. That is
/// FB-68's rule: identity, class slug and `layout:` are snapshotted ONCE, at the
/// instant the user asked (inside `chooseExportScope`), and travel here
/// immutable. Re-deriving any of them after the scope sheet closed is exactly
/// the defect — two files from one sitting, 14 s apart, naming the same unit
/// two different ways.
///
/// ⚠️ WHAT DOES DIFFER between the two callers is the [ExportTarget] itself,
/// and only that: the History tab's covers whichever unit its picker is on,
/// while the detail page's is pinned to the unit whose page it is, connected or
/// not (design 0065 §0.6). Both then produce byte-identical file structure.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../config/app_config.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../dashboard/watchfaces.dart';
import 'export_header.dart';
import 'export_naming.dart';
import 'export_scope.dart';
import 'export_share.dart';

/// Stream [target]'s history rows into a temporary CSV and offer it to the
/// share sheet.
///
/// [since] and [until] are the range the caller's own view is showing;
/// [window] is its `window:` preamble value (see `historyWindowLabel`) — the
/// three are passed together because they are statements about the same
/// choice, and a file whose rows and whose stated window disagreed would be
/// worse than either.
///
/// 🔵 [until] added by design 0083 S4, and it reaches EVERY question this
/// function asks the database — the rows, the row count, the two omission
/// counts in the header, and the `resolution: contains=` line. One of them
/// left unbounded would put a sentence in the preamble that the file below it
/// contradicts.
///
/// Reports its own failures through the caller's [ScaffoldMessenger]; the
/// caller owns only the busy flag around it.
Future<void> exportHistoryCsv(
  BuildContext context, {
  required ExportTarget target,
  required DateTime? since,
  required DateTime? until,
  required String window,
}) async {
  final l10n = AppLocalizations.of(context);
  // design 0092: read with the other pre-await captures below.
  final appName = AppConfigScope.of(context).appName;
  final messenger = ScaffoldMessenger.of(context);
  // Captured now: every lookup below runs after an await, when the screen that
  // started this may already be gone.
  final devices = context.read<DeviceController>();
  // design 0057: the identity cache, nullable so a harness without one behaves
  // exactly as the code did before 0057 existed.
  final facts = context.read<DeviceFactsController?>();
  final services = context.read<AppServices>();
  final tele = context.read<TelemetryController>();
  // The live pair (design 0055 follow-up): a unit that was never named has no
  // stored class, and without this its capacitor `0.0 A` would be exported as a
  // measurement. Only the unit on the link is eligible — see [deviceClassFor].
  final liveId = tele.recordingDeviceId;
  final liveClass = context.read<ConnectionController>().resolvedClass;
  String labelFor(String? id) => deviceLabelFor(devices, id, facts: facts);
  ProductClass classFor(String? id) => deviceClassFor(
        devices,
        id,
        facts: facts,
        liveDeviceId: liveId,
        liveClass: liveClass,
      );
  // iPad popover anchor (D.7): capture before any await invalidates context.
  final origin = sharePositionFromContext(context);
  // 🔴 FB-68: "the moment of export" is ONE instant, fixed inside the target by
  // `chooseExportScope`. Re-reading the layout here would let this file and the
  // diagnostic log the same reporter sends seconds later disagree about the
  // same phone.
  final layout = target.layout;
  // Phone-wide, no link to lose, so it is not part of the snapshot.
  final home = currentExportHomeValue(context);
  // 🔴 EFFECTIVE, not stored (design 0063 §3.0.3). Advanced mode keeps the
  // user's switches and withholds the features, so the stored value would
  // describe an intention while the file describes a session.
  final appSettings = context.read<SettingsController>().settings;
  final mode = appSettings.mode;
  // design 0064: captured with the rest of the snapshot, before the awaits.
  final themeMode = appSettings.themeMode;
  final accent =
      AccentTheme.byId(appSettings.accentThemeId) ?? AccentTheme.amber;
  final speedDetection = appSettings.speedDetectionEffective;
  final gMeter = appSettings.gMeterEffective;
  try {
    final filename = exportFileName(
      base: 'opensmartbatt-history',
      classSlug: target.classSlug,
      ident: target.ident,
      stamp: exportStamp(),
      extension: 'csv',
    );
    // design 0061 T7b — before a single row is read.
    await tele.flushHistoryForExport();
    final file = await exportTempFile(filename);
    // design 0061 T4a. What the scope ACTUALLY holds, asked of the database
    // over the same window the export walks — never assumed.
    final resolution = ExportResolution.forCsv(
      target.granularity,
      await tele.historyBucketWidths(
          since: since, until: until, deviceId: target.deviceId),
    );
    // design 0070. The same identity list the diagnostic log has always
    // carried, so `devices:` and `declared:` say the same thing in both files a
    // reporter sends. Computed HERE rather than taken as a parameter, for the
    // reason stated at the top of this file: everything a history CSV states
    // about itself is decided here, so its two call sites cannot start
    // describing the same database differently. A parameter would hand them
    // exactly that freedom.
    final identities =
        await exportDeviceIdentities(devices, tele, target, facts: facts);
    // Streamed straight into the file (design 0030 T4b) and NOT capped at the
    // list's row cap (T4c / FB-59).
    final rows = await tele.exportHistoryCsvToFile(
      file,
      since: since,
      until: until,
      deviceId: target.deviceId,
      granularity: target.granularity,
      labelFor: labelFor,
      classFor: classFor,
      header: exportHeaderLines(
        title: 'OpenSmartBatt history export',
        exportedAt: DateTime.now(),
        appBuild: services.appBuild,
        platform: services.platform,
        scope: exportScopeLabel(target),
        window: window,
        resolution: resolution,
        // design 0056 follow-up: this file HAS an `ampere` column, so it states
        // what that column's sign means.
        ampereColumn: true,
        layout: layout,
        home: home,
        mode: mode,
        themeMode: themeMode,
        accent: accent,
        speedDetection: speedDetection,
        gMeter: gMeter,
        // design 0070. Without this the block was silently `count=0` in every
        // CSV ever exported, while the log written seconds later said `count=3`
        // — and `conventions/export-header.md` reads a zero as "nobody filled
        // one in".
        devices: identities,
      ),
    );
    // Row count, not text emptiness: every export carries a provenance
    // preamble, so the file is never literally empty.
    if (rows == 0) {
      // The header-only file is already on disk; delete it rather than leave a
      // plausible-looking export in the temp directory.
      await file.delete().catchError((_) => file);
      messenger.showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1600),
        content: Text(l10n.commonNoRecordsToExport),
      ));
      return;
    }
    await shareExportFile(
      file: file,
      filename: filename,
      mimeType: 'text/csv',
      subject: l10n.historyExportSubject(appName),
      sharePositionOrigin: origin,
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1600),
        content: Text(l10n.commonExportFailed('$e'))));
  }
}
