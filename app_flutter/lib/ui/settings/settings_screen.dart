/// OpenSmartBatt — Settings screen (mockup screen 5).
///
/// Five cards: 連線 (connection), 顯示 (display), 資料 (data), 診斷/開發者
/// (diagnostics — raw BLE packet log DEFAULT OFF + export `.log`), and 關於
/// (about: version / GitHub / PROTOCOL.md / copyright). All settings bind to
/// [SettingsController]; data/log actions go through [TelemetryController].
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../dashboard/capture_mark_labels.dart';
import '../diagnostics/capture_wizard.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../util/export_header.dart';
import '../util/export_naming.dart';
import '../util/export_scope.dart';
import '../util/export_share.dart';
import '../util/update_check.dart';
import '../widgets/industrial.dart';


/// Community project links (mockup startup disclaimer + About card).
const String kGithubUrl = 'https://github.com/WinePaster/open-smart-batt';
const String kProtocolUrl =
    'https://github.com/WinePaster/open-smart-batt/blob/main/docs/PROTOCOL.md';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, this.deviceInfoPanelBuilder});

  /// Optional closed-side device-info panel (design 0003 seam). NULL on the
  /// open build, where nothing is rendered and the screen is byte-identical to
  /// before the slot existed.
  ///
  /// The open side knows only WHERE the panel goes, never what it contains: a
  /// closed composition root passes `bootstrap(deviceInfoPanelBuilder: …)` and
  /// reads its own [DeviceMetadata] inside the builder. No closed selector,
  /// label or field name is referenced here.
  final WidgetBuilder? deviceInfoPanelBuilder;

  @override
  Widget build(BuildContext context) {
    final panel = deviceInfoPanelBuilder;
    return ListView(
      padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
      children: [
        const _ConnectionCard(),
        if (panel != null) panel(context),
        const _DisplayCard(),
        const _DataCard(),
        const _DiagnosticsCard(),
        const _AboutCard(),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 連線 / Connection
// ---------------------------------------------------------------------------

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.settingsConnectionHeading,
      headingIcon: Icons.bluetooth,
      child: Column(
        children: [
          SettingsRow(
            label: l10n.settingsAutoReconnectLabel,
            sub: l10n.settingsAutoReconnectSub,
            trailing: _Toggle(
              value: s.autoReconnect,
              onChanged: s.setAutoReconnect,
            ),
          ),
          // design 0008: background execution and keeping the screen on are
          // two different things. They shared one setting while the wakelock
          // was the only mitigation available; now they are separate.
          // Platform-split, and disabled on iOS. The switch does nothing there
          // (NoopMonitorService), yet it still flipped `monitorRunning` — which
          // is how the dashboard ended up giving iOS users Android-only advice
          // (FB-26). The row is kept rather than hidden: a user who has heard
          // of the feature needs to see WHY it is unavailable, and the stored
          // preference must survive for a future iOS implementation or a move
          // to Android.
          SettingsRow(
            label: l10n.settingsBackgroundMonitorLabel,
            sub: Platform.isIOS
                ? l10n.settingsBackgroundMonitorSubIos
                : l10n.settingsBackgroundMonitorSubAndroid,
            trailing: _Toggle(
              value: s.backgroundMonitoring,
              onChanged: Platform.isIOS ? null : s.setBackgroundMonitoring,
            ),
          ),
          SettingsRow(
            label: l10n.settingsKeepAwakeLabel,
            sub: l10n.settingsKeepAwakeSub,
            last: true,
            trailing: _Toggle(
              value: s.keepScreenAwake,
              onChanged: s.setKeepScreenAwake,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 顯示 / Display
// ---------------------------------------------------------------------------

class _DisplayCard extends StatelessWidget {
  const _DisplayCard();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.settingsDisplayHeading,
      headingIcon: Icons.speed,
      child: Column(
        children: [
          SettingsRow(
            label: l10n.settingsThemeLabel,
            sub: l10n.settingsThemeSub,
            trailing: SegmentedControl<AppThemeMode>(
              selected: s.themeMode,
              onChanged: s.setThemeMode,
              options: [
                (value: AppThemeMode.light, label: l10n.settingsThemeLight),
                (value: AppThemeMode.dark, label: l10n.settingsThemeDark),
                (value: AppThemeMode.auto, label: l10n.settingsThemeAuto),
              ],
            ),
          ),
          SettingsRow(
            label: l10n.settingsLanguageLabel,
            sub: l10n.settingsLanguageSub,
            trailing: SegmentedControl<AppLang>(
              selected: s.lang,
              onChanged: (v) => context.read<SettingsController>().setLang(v),
              options: [
                (value: AppLang.zhHant, label: l10n.settingsLanguageZhHant),
                (value: AppLang.en, label: l10n.settingsLanguageEnglish),
                (value: AppLang.system, label: l10n.settingsLanguageSystem),
              ],
            ),
          ),
          SettingsRow(
            label: l10n.settingsTempUnitLabel,
            last: true,
            trailing: SegmentedControl<TempUnit>(
              selected: s.tempUnit,
              onChanged: s.setTempUnit,
              options: const [
                (value: TempUnit.celsius, label: '°C'),
                (value: TempUnit.fahrenheit, label: '°F'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 資料 / Data
// ---------------------------------------------------------------------------

class _DataCard extends StatefulWidget {
  const _DataCard();

  @override
  State<_DataCard> createState() => _DataCardState();
}

class _DataCardState extends State<_DataCard> {
  bool _busy = false;

  Future<void> _exportAll() async {
    if (_busy) return;
    // design 0006: pick the unit BEFORE showing the spinner — the sheet is the
    // user's decision point, not work.
    final target = await chooseExportScope(context, offerSession: false);
    if (target == null || !mounted) return;
    setState(() => _busy = true);
    final tele = context.read<TelemetryController>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    // Captured now: the label lookup runs after an await, when this screen may
    // already be gone.
    final devices = context.read<DeviceController>();
    final services = context.read<AppServices>();
    String labelFor(String? id) => deviceLabelFor(devices, id);
    ProductClass classFor(String? id) => deviceClassFor(devices, id);
    // iPad popover anchor (D.7): capture before any await invalidates context.
    final origin = sharePositionFromContext(context);
    try {
      final csv = await tele.exportHistoryCsv(
        deviceId: target.deviceId,
        labelFor: labelFor,
        classFor: classFor,
        header: exportHeaderLines(
          title: 'OpenSmartBatt history export',
          exportedAt: DateTime.now(),
          appBuild: services.appBuild,
          platform: services.platform,
          scope: exportScopeLabel(target),
        ),
      );
      // Row count, not text emptiness: the preamble means the file is never
      // empty (design 0009).
      if (csv.rows == 0) {
        messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.commonNoRecordsToExport)));
        return;
      }
      await shareTextAsFile(
        content: csv.text,
        filename: exportFileName(
          base: 'opensmartbatt-history',
          classSlug: target.classSlug,
          ident: target.ident,
          stamp: exportStamp(),
          extension: 'csv',
        ),
        mimeType: 'text/csv',
        subject: l10n.settingsExportSubjectAllData,
        sharePositionOrigin: origin,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.commonExportFailed('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final tele = context.read<TelemetryController>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final ok = await _confirm(
      context,
      title: l10n.settingsClearHistoryTitle,
      body: l10n.settingsClearHistoryBody,
      danger: true,
      confirmLabel: l10n.settingsClearConfirm,
    );
    if (!ok) return;
    await tele.clearHistory();
    messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.settingsHistoryCleared)));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.settingsDataHeading,
      headingIcon: Icons.description_outlined,
      child: Column(
        children: [
          SettingsRow(
            label: l10n.settingsRetentionLabel,
            sub: l10n.settingsRetentionSub,
            trailing: SegmentedControl<RetentionPolicy>(
              selected: s.retention,
              onChanged: s.setRetention,
              options: [
                (value: RetentionPolicy.days30, label: l10n.retention30Days),
                (value: RetentionPolicy.days90, label: l10n.retention90Days),
                (value: RetentionPolicy.days365, label: l10n.retention365Days),
                (value: RetentionPolicy.forever, label: l10n.retentionForever),
              ],
            ),
          ),
          SettingsLinkRow(
            icon: Icons.file_download_outlined,
            label: l10n.settingsExportAllLabel,
            onTap: _exportAll,
            trailing: _busy ? const _SmallSpinner() : null,
          ),
          SettingsLinkRow(
            icon: Icons.delete_outline,
            label: l10n.settingsClearHistoryLabel,
            onTap: _clear,
            last: true,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 診斷 / Diagnostics
// ---------------------------------------------------------------------------

class _DiagnosticsCard extends StatefulWidget {
  const _DiagnosticsCard();

  @override
  State<_DiagnosticsCard> createState() => _DiagnosticsCardState();
}

class _DiagnosticsCardState extends State<_DiagnosticsCard> {
  bool _busy = false;

  /// Run the guided capture script for the connected unit.
  ///
  /// Requires a live connection: the marks describe states of a device we are
  /// recording, and running it disconnected would write ground truth for
  /// nothing.
  Future<void> _runCaptureWizard() async {
    final l10n = AppLocalizations.of(context);
    final conn = context.read<ConnectionController>();
    final messenger = ScaffoldMessenger.of(context);
    if (!conn.isOnline) {
      messenger.showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1800),
        content: Text(l10n.disconnectedTitle),
      ));
      return;
    }
    final marks = CaptureMark.forClass(conn.packLabel)
        .where((m) => m != CaptureMark.note)
        .toList();
    if (marks.isEmpty) {
      // An unclassified unit has no script — offering one would invite the
      // mislabelled ground truth this feature exists to prevent.
      messenger.showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1800),
        content: Text(l10n.packLabelUnclassified),
      ));
      return;
    }
    final done = await showCaptureWizard(
      context,
      marks: marks,
      labelFor: (m) => captureMarkLabel(l10n, m),
    );
    if (!done) return;
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 2600),
      content: Text(l10n.captureWizardFinished),
    ));
  }

  Future<void> _exportLog() async {
    if (_busy) return;
    // The diagnostic log is the one export where "this connection only" is
    // useful — that is the slice we ask a reporter for (design 0006 §3.4).
    final target = await chooseExportScope(context, offerSession: true);
    if (target == null || !mounted) return;
    setState(() => _busy = true);
    final tele = context.read<TelemetryController>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    // Captured now: the lookup runs after an await, when this screen may be gone.
    final devices = context.read<DeviceController>();
    final services = context.read<AppServices>();
    String labelFor(String? id) => deviceLabelFor(devices, id);
    // iPad popover anchor (D.7): capture before any await invalidates context.
    final origin = sharePositionFromContext(context);
    try {
      final header = await _logHeader(tele, services, target);
      final log = await tele.exportLog(
        deviceId: target.deviceId,
        sessionId: target.sessionId,
        header: header,
        labelFor: labelFor,
      );
      if (log.trim().isEmpty) {
        messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.settingsLogEmpty)));
        return;
      }
      await shareTextAsFile(
        content: log,
        filename: exportFileName(
          base: 'opensmartbatt',
          classSlug: target.classSlug,
          ident: target.ident,
          stamp: exportStamp(),
          extension: 'log',
        ),
        mimeType: 'text/plain',
        subject: l10n.settingsExportSubjectDiagLog,
        sharePositionOrigin: origin,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.commonExportFailed('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// `#`-prefixed preamble telling whoever receives the file which unit, which
  /// app build and how many connections it covers (design 0006 §3.6).
  Future<List<String>> _logHeader(
    TelemetryController tele,
    AppServices services,
    ExportTarget target,
  ) async {
    final sessions = target.scope == ExportScope.currentSession
        ? 1
        : await tele.logSessionCount(deviceId: target.deviceId);
    return exportHeaderLines(
      title: 'OpenSmartBatt diagnostic log',
      exportedAt: DateTime.now(),
      appBuild: services.appBuild,
      platform: services.platform,
      scope: exportScopeLabel(target),
      connections: sessions,
    );
  }

  Future<void> _clearLog() async {
    final tele = context.read<TelemetryController>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final ok = await _confirm(
      context,
      title: l10n.settingsClearLogTitle,
      body: l10n.settingsClearLogBody,
      danger: true,
      confirmLabel: l10n.settingsClearConfirm,
    );
    if (!ok) return;
    await tele.clearLog();
    messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.settingsLogCleared)));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.settingsDiagnosticsHeading,
      headingIcon: Icons.bug_report_outlined,
      child: Column(
        children: [
          SettingsRow(
            label: l10n.settingsRawPacketLogLabel,
            sub: l10n.settingsRawPacketLogSub,
            subHighlight: true,
            trailing: _Toggle(
              value: s.rawPacketLog,
              onChanged: s.setRawPacketLog,
            ),
          ),
          SettingsRow(
            label: l10n.settingsLogMaxSizeLabel,
            sub: l10n.settingsLogMaxSizeSub,
            trailing: SegmentedControl<int>(
              selected: s.logMaxBytes,
              onChanged: s.setLogMaxBytes,
              options: const [
                (value: 20 * 1024 * 1024, label: '20 MB'),
                (value: 100 * 1024 * 1024, label: '100 MB'),
              ],
            ),
          ),
          // design 0013 Phase 2. Lives in Diagnostics rather than on the
          // dashboard because it is a deliberate procedure, not a quick action —
          // the dashboard bar covers spontaneous marking.
          SettingsLinkRow(
            icon: Icons.assignment_turned_in_outlined,
            label: l10n.captureWizardTitle,
            onTap: _runCaptureWizard,
          ),
          SettingsLinkRow(
            icon: Icons.file_download_outlined,
            label: l10n.settingsExportLogLabel,
            onTap: _exportLog,
            trailing: _busy ? const _SmallSpinner() : null,
          ),
          SettingsLinkRow(
            icon: Icons.delete_outline,
            label: l10n.settingsClearLogLabel,
            onTap: _clearLog,
            last: true,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 關於 / About
// ---------------------------------------------------------------------------

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  Future<void> _copy(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    var opened = false;
    try {
      opened = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: url));
      messenger.showSnackBar(
          SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.commonOpenBrowserFailed(url))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.settingsAboutHeading,
      child: Column(
        children: [
          SettingsRow(
            label: l10n.settingsVersionLabel,
            sub: l10n.settingsVersionSub,
            trailing: FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snap) {
                final v = snap.hasData
                    ? 'v${snap.data!.version} (+${snap.data!.buildNumber})'
                    : '…';
                return Text(
                  v,
                  style: AppTextStyles.mono(context).copyWith(
                    color: context.colors.muted,
                  ),
                );
              },
            ),
          ),
          // Android-only: iOS updates come via TestFlight / the App Store, and
          // GitHub releases carry only the Android APK, so hide this on iOS.
          if (!Platform.isIOS)
            SettingsLinkRow(
              icon: Icons.system_update_alt,
              label: l10n.settingsCheckUpdateLabel,
              onTap: () => runUpdateCheck(context, manual: true),
            ),
          SettingsLinkRow(
            icon: Icons.code,
            label: l10n.settingsGithubLabel,
            onTap: () => _copy(context, kGithubUrl),
          ),
          SettingsLinkRow(
            icon: Icons.description_outlined,
            label: l10n.settingsProtocolDocLabel,
            onTap: () => _copy(context, kProtocolUrl),
          ),
          SettingsLinkRow(
            icon: Icons.link,
            label: l10n.settingsCopyrightLabel,
            onTap: () => _showAbout(context),
            last: true,
          ),
        ],
      ),
    );
  }
}

void _showAbout(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: context.colors.panel,
      title: Text(l10n.settingsAboutDialogTitle, style: const TextStyle(fontSize: 17)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsAboutDialogBody,
              style: TextStyle(
                  fontSize: 12.5, height: 1.7, color: context.colors.muted),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.amber.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(color: AppColors.amber.withValues(alpha: 0.28)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 15, color: AppColors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.settingsAboutDialogWarning,
                      style: const TextStyle(
                          fontSize: 11, height: 1.5, color: AppColors.amber),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.commonClose, style: const TextStyle(color: AppColors.amber)),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// shared small bits
// ---------------------------------------------------------------------------

/// Compact themed switch used by the settings rows.
///
/// A null [onChanged] renders the switch disabled but still shows its value —
/// used where a setting exists and is stored, but the platform cannot honour it
/// (design 0014 §3.4).
class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      onChanged: onChanged,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _SmallSpinner extends StatelessWidget {
  const _SmallSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.amber),
    );
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  bool danger = false,
  String? confirmLabel,
}) async {
  final l10n = AppLocalizations.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: context.colors.panel,
      title: Text(title, style: const TextStyle(fontSize: 17)),
      content: Text(
        body,
        style: TextStyle(
            fontSize: 12.5, height: 1.6, color: context.colors.muted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.commonCancel, style: TextStyle(color: context.colors.muted)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            confirmLabel ?? l10n.commonConfirm,
            style: TextStyle(color: danger ? AppColors.danger : AppColors.amber),
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}
