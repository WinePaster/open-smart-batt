/// OpenSmartBatt — the two Settings exports' file writers, shared.
///
/// Extracted from `settings_screen.dart` (`_exportAll` / `_exportLog`) when
/// design 0100 gave them a third caller: the one-tap report bundle writes the
/// SAME all-data CSV and the SAME diagnostic log, from ONE [ExportTarget], into
/// one zip. Moving the bodies here — rather than copying them — is what keeps
/// a bundled file byte-for-byte the file the old button produces (timestamps
/// aside), so a recipient and `fbparse` never have to tell the two apart.
///
/// 🔑 Two halves, on purpose:
///
///   * [ExportCapture.of] reads every phone-side fact an export states, from a
///     live [BuildContext], BEFORE the first await (the screen may be gone by
///     the time a file is written — the rule every export handler already
///     followed, now in one place);
///   * the writers below take that capture and never touch a context.
///
/// 🔴 FB-68: the unit's identity, class slug and `layout:` come from the
/// [ExportTarget], resolved once by `chooseExportScope`. Nothing here
/// re-derives them; a bundle's two files therefore cannot name the same unit
/// two ways.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../dashboard/watchfaces.dart';
import 'export_header.dart';
import 'export_naming.dart';
import 'export_scope.dart';
import 'export_share.dart';

/// Everything an export states about the phone, captured in one breath.
class ExportCapture {
  ExportCapture._({
    required this.target,
    required this.appName,
    required this.edition,
    required this.services,
    required this.tele,
    required this.devices,
    required this.facts,
    required this.liveId,
    required this.liveClass,
    required this.home,
    required this.mode,
    required this.themeMode,
    required this.accent,
    required this.speedOn,
    required this.gMeterOn,
    required this.rawPacketLog,
  });

  /// Reads [context] NOW. Call it before any await in the handler.
  factory ExportCapture.of(BuildContext context, ExportTarget target) {
    // 🔴 EFFECTIVE, not stored (design 0063 §3.0.3). Advanced mode keeps the
    // user's switches and withholds the features, so the stored value would
    // describe an intention while the file describes a session.
    final settings = context.read<SettingsController>();
    final s = settings.settings;
    final tele = context.read<TelemetryController>();
    return ExportCapture._(
      target: target,
      appName: AppConfigScope.of(context).appName,
      edition: AppConfigScope.of(context).edition,
      services: context.read<AppServices>(),
      tele: tele,
      devices: context.read<DeviceController>(),
      // design 0057: nullable so a harness without the cache still builds.
      facts: context.read<DeviceFactsController?>(),
      // The live pair (design 0055 follow-up): an unnamed unit has no stored
      // class, and the CSV's current column is class-gated.
      liveId: tele.recordingDeviceId,
      liveClass: context.read<ConnectionController>().resolvedClass,
      // design 0046 Step 10: phone-wide, no link to lose, so NOT part of the
      // FB-68 snapshot — but still read before the first await.
      home: currentExportHomeValue(context),
      mode: s.mode,
      themeMode: s.themeMode,
      accent: AccentTheme.byId(s.accentThemeId) ?? AccentTheme.amber,
      speedOn: s.speedDetectionEffective,
      gMeterOn: s.gMeterEffective,
      rawPacketLog: settings.rawPacketLog,
    );
  }

  final ExportTarget target;
  final String appName;
  final AppEdition edition;
  final AppServices services;
  final TelemetryController tele;
  final DeviceController devices;
  final DeviceFactsController? facts;
  final String? liveId;
  final ProductClass liveClass;
  final String home;
  final AppMode mode;
  final AppThemeMode themeMode;
  final AccentTheme accent;
  /// The EFFECTIVE speed-detection / G-meter switches (named apart from the
  /// stored fields on purpose — `app_mode_test.dart` H9 counts stored reads).
  final bool speedOn;
  final bool gMeterOn;
  final bool rawPacketLog;

  String labelFor(String? id) => deviceLabelFor(devices, id, facts: facts);

  ProductClass classFor(String? id) => deviceClassFor(
        devices,
        id,
        facts: facts,
        liveDeviceId: liveId,
        liveClass: liveClass,
      );
}

/// The all-data CSV's filename for [target].
String allDataCsvFileName(ExportTarget target, {String? stamp}) =>
    exportFileName(
      base: 'opensmartbatt-history',
      classSlug: target.classSlug,
      ident: target.ident,
      stamp: stamp ?? exportStamp(),
      extension: 'csv',
    );

/// The diagnostic log's filename for [target].
String diagnosticLogFileName(ExportTarget target, {String? stamp}) =>
    exportFileName(
      base: 'opensmartbatt',
      classSlug: target.classSlug,
      ident: target.ident,
      stamp: stamp ?? exportStamp(),
      extension: 'log',
    );

/// Streams the "export all data" CSV for [c]'s target into [file] and returns
/// the number of data rows written (0 ⇒ the file holds only its preamble).
Future<int> writeAllDataCsv(ExportCapture c, File file) async {
  final target = c.target;
  // 🔴 FB-68: the snapshot, never a fresh read.
  final layout = target.layout;
  // A local, so the title reads `'$appName …'` — the shape `app_config_test`
  // T4 holds every exportHeaderLines call site to (FB-109).
  final appName = c.appName;
  // design 0061 T7b: the last ~10 seconds live in a write buffer until
  // something asks for them, and an export is exactly that.
  await c.tele.flushHistoryForExport();
  // design 0061 T4a — asked of the database over this export's own scope.
  final resolution = ExportResolution.forCsv(
    target.granularity,
    await c.tele.historyBucketWidths(deviceId: target.deviceId),
  );
  // design 0070: `exportHeaderLines` builds BOTH `devices:` and `declared:`
  // out of this list, so omitting it made a CSV claim zero declared units
  // while the log exported seconds later named three.
  final identities = await exportDeviceIdentities(c.devices, c.tele, target,
      facts: c.facts);
  // "Export all data" means all of it — no row cap — and it is streamed page
  // by page (design 0030 T4b) so the table never sits in memory.
  return c.tele.exportHistoryCsvToFile(
    file,
    deviceId: target.deviceId,
    granularity: target.granularity,
    labelFor: c.labelFor,
    classFor: c.classFor,
    header: exportHeaderLines(
      title: '$appName history export',
      exportedAt: DateTime.now(),
      appBuild: c.services.appBuild,
      platform: c.services.platform,
      edition: c.edition,
      scope: exportScopeLabel(target),
      // FB-60. Unconditional here and always `all`: this export has no range
      // picker, so the file has to say so rather than leave the recipient to
      // infer it from a missing line.
      window: 'all',
      resolution: resolution,
      // Same column, same rule as the History screen's export — the two paths
      // write the same CSV shape and must describe it identically.
      ampereColumn: true,
      layout: layout,
      home: c.home,
      mode: c.mode,
      themeMode: c.themeMode,
      accent: c.accent,
      speedDetection: c.speedOn,
      gMeter: c.gMeterOn,
      devices: identities,
    ),
  );
}

/// The diagnostic log for [c]'s target, preamble included. Blank (after trim)
/// when the log table holds nothing in scope.
///
/// The preamble tells whoever receives the file which unit it covers, which
/// app build produced it, how many connections it spans and whether raw
/// packets were being recorded at all. Without it a recipient cannot tell a
/// genuinely quiet capture from one the app never wrote, and has to guess at
/// the version — which is how an app-side bug once got read as a hardware
/// limitation.
Future<String> buildDiagnosticLog(ExportCapture c) async {
  final target = c.target;
  // 🔴 FB-68: batch 2026.08.13-001's log carried `layout: face=- modules=-`
  // beside a CSV from 17 s earlier that said `face=fixed`, because this line
  // used to be re-read, gated on `conn.isOnline`. It comes from the target.
  final layout = target.layout;
  final appName = c.appName; // see writeAllDataCsv
  // design 0027 §3.1: name every unit this export touches in the header, even
  // an all-devices export where the rows carry only nicknames.
  final identities = await exportDeviceIdentities(c.devices, c.tele, target,
      facts: c.facts);
  final sessions = target.scope == ExportScope.currentSession
      ? 1
      : await c.tele.logSessionCount(deviceId: target.deviceId);
  final header = exportHeaderLines(
    title: '$appName diagnostic log',
    exportedAt: DateTime.now(),
    appBuild: c.services.appBuild,
    platform: c.services.platform,
    edition: c.edition,
    scope: exportScopeLabel(target),
    layout: layout,
    home: c.home,
    mode: c.mode,
    themeMode: c.themeMode,
    accent: c.accent,
    speedDetection: c.speedOn,
    gMeter: c.gMeterOn,
    // design 0061 §3.4.3: this file has no history rows at all, so it says so
    // out loud rather than omitting the line (FB-32's rule).
    resolution: ExportResolution.none,
    connections: sessions,
    rawPacketLog: c.rawPacketLog,
    devices: identities,
  );
  return c.tele.exportLog(
    deviceId: target.deviceId,
    sessionId: target.sessionId,
    header: header,
    labelFor: c.labelFor,
  );
}
