/// OpenSmartBatt — Settings screen (mockup screen 5).
///
/// Five cards: 連線 (connection), 顯示 (display), 資料 (data), 診斷/開發者
/// (diagnostics — raw BLE packet log DEFAULT OFF + export `.log`), and 關於
/// (about: version / GitHub / PROTOCOL.md / copyright). All settings bind to
/// [SettingsController]; data/log actions go through [TelemetryController].
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../util/export_share.dart';
import '../util/update_check.dart';
import '../widgets/industrial.dart';


/// Community project links (mockup startup disclaimer + About card).
const String kGithubUrl = 'https://github.com/WinePaster/open-smart-batt';
const String kProtocolUrl =
    'https://github.com/WinePaster/open-smart-batt/blob/main/docs/PROTOCOL.md';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
      children: const [
        _ConnectionCard(),
        _DisplayCard(),
        _DataCard(),
        _DiagnosticsCard(),
        _AboutCard(),
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
          SettingsRow(
            label: l10n.settingsKeepAwakeLabel,
            sub: l10n.settingsKeepAwakeSub,
            last: true,
            trailing: _Toggle(
              value: s.backgroundKeepAlive,
              onChanged: s.setBackgroundKeepAlive,
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
    setState(() => _busy = true);
    final tele = context.read<TelemetryController>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    // iPad popover anchor (D.7): capture before any await invalidates context.
    final origin = sharePositionFromContext(context);
    try {
      final csv = await tele.exportHistoryCsv();
      if (!csv.contains('\n')) {
        messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.commonNoRecordsToExport)));
        return;
      }
      await shareTextAsFile(
        content: csv,
        filename: 'opensmartbatt-history-${exportStamp()}.csv',
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
            label: l10n.settingsAutoLogLabel,
            sub: l10n.settingsAutoLogSub,
            trailing: _Toggle(value: s.autoLog, onChanged: s.setAutoLog),
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

  Future<void> _exportLog() async {
    if (_busy) return;
    setState(() => _busy = true);
    final tele = context.read<TelemetryController>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    // iPad popover anchor (D.7): capture before any await invalidates context.
    final origin = sharePositionFromContext(context);
    try {
      final log = await tele.exportLog();
      if (log.trim().isEmpty) {
        messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.settingsLogEmpty)));
        return;
      }
      await shareTextAsFile(
        content: log,
        filename: 'opensmartbatt-${exportStamp()}.log',
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
                (value: 5 * 1024 * 1024, label: '5 MB'),
                (value: 20 * 1024 * 1024, label: '20 MB'),
              ],
            ),
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
                borderRadius: BorderRadius.circular(9),
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
class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

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
