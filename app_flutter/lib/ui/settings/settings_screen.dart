/// Open-RCE-Batt — Settings screen (mockup screen 5).
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

import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../util/export_share.dart';
import '../util/update_check.dart';
import '../widgets/industrial.dart';


/// Community project links (mockup startup disclaimer + About card).
const String kGithubUrl = 'https://github.com/WinePaster/open-rce-batt';
const String kProtocolUrl =
    'https://github.com/WinePaster/open-rce-batt/blob/main/docs/PROTOCOL.md';

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
    return IndustrialCard(
      heading: '連線',
      headingIcon: Icons.bluetooth,
      child: Column(
        children: [
          SettingsRow(
            label: '自動重連',
            sub: '連線中斷時自動嘗試重連',
            trailing: _Toggle(
              value: s.autoReconnect,
              onChanged: s.setAutoReconnect,
            ),
          ),
          SettingsRow(
            label: '連線時保持螢幕喚醒',
            sub: '螢幕不自動關閉，方便邊騎邊看（連線時生效）',
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
    return IndustrialCard(
      heading: '顯示',
      headingIcon: Icons.speed,
      child: Column(
        children: [
          SettingsRow(
            label: '主題',
            sub: '介面配色（自動：跟隨系統）',
            trailing: SegmentedControl<AppThemeMode>(
              selected: s.themeMode,
              onChanged: s.setThemeMode,
              options: const [
                (value: AppThemeMode.light, label: '淺色'),
                (value: AppThemeMode.dark, label: '深色'),
                (value: AppThemeMode.auto, label: '自動'),
              ],
            ),
          ),
          SettingsRow(
            label: '溫度單位',
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
    try {
      final csv = await tele.exportHistoryCsv();
      if (!csv.contains('\n')) {
        messenger.showSnackBar(const SnackBar(duration: Duration(milliseconds: 1600), content: Text('沒有可匯出的紀錄')));
        return;
      }
      await shareTextAsFile(
        content: csv,
        filename: 'open-rce-batt-history-${exportStamp()}.csv',
        mimeType: 'text/csv',
        subject: 'Open-RCE-Batt 全部資料',
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text('匯出失敗：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final tele = context.read<TelemetryController>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _confirm(
      context,
      title: '清除歷史紀錄',
      body: '將刪除本機所有遙測歷史。此動作無法復原。',
      danger: true,
      confirmLabel: '清除',
    );
    if (!ok) return;
    await tele.clearHistory();
    messenger.showSnackBar(const SnackBar(duration: Duration(milliseconds: 1600), content: Text('已清除歷史紀錄')));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    return IndustrialCard(
      heading: '資料',
      headingIcon: Icons.description_outlined,
      child: Column(
        children: [
          SettingsRow(
            label: '自動紀錄',
            sub: '連線時自動寫入歷史',
            trailing: _Toggle(value: s.autoLog, onChanged: s.setAutoLog),
          ),
          SettingsLinkRow(
            icon: Icons.file_download_outlined,
            label: '匯出全部資料 (CSV)',
            onTap: _exportAll,
            trailing: _busy ? const _SmallSpinner() : null,
          ),
          SettingsLinkRow(
            icon: Icons.delete_outline,
            label: '清除歷史紀錄',
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
    try {
      final log = await tele.exportLog();
      if (log.trim().isEmpty) {
        messenger.showSnackBar(const SnackBar(duration: Duration(milliseconds: 1600), content: Text('診斷日誌為空')));
        return;
      }
      await shareTextAsFile(
        content: log,
        filename: 'open-rce-batt-${exportStamp()}.log',
        mimeType: 'text/plain',
        subject: 'Open-RCE-Batt 診斷日誌',
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text('匯出失敗：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearLog() async {
    final tele = context.read<TelemetryController>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _confirm(
      context,
      title: '清除診斷日誌',
      body: '將刪除本機所有原始 TX/RX 封包紀錄。',
      danger: true,
      confirmLabel: '清除',
    );
    if (!ok) return;
    await tele.clearLog();
    messenger.showSnackBar(const SnackBar(duration: Duration(milliseconds: 1600), content: Text('已清除診斷日誌')));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    return IndustrialCard(
      heading: '診斷 / 開發者',
      headingIcon: Icons.bug_report_outlined,
      child: Column(
        children: [
          SettingsRow(
            label: '記錄原始藍牙封包',
            sub: '記錄 TX/RX 原始 hex，供回報問題或協助破解未知指令。預設關閉',
            subHighlight: true,
            trailing: _Toggle(
              value: s.rawPacketLog,
              onChanged: s.setRawPacketLog,
            ),
          ),
          SettingsRow(
            label: '日誌容量上限',
            sub: '超過自動輪替覆蓋',
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
            label: '匯出診斷日誌 (.log)',
            onTap: _exportLog,
            trailing: _busy ? const _SmallSpinner() : null,
          ),
          SettingsLinkRow(
            icon: Icons.delete_outline,
            label: '清除診斷日誌',
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
          SnackBar(duration: const Duration(milliseconds: 1600), content: Text('無法開啟瀏覽器，已複製連結：$url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return IndustrialCard(
      heading: '關於',
      child: Column(
        children: [
          SettingsRow(
            label: '版本',
            sub: 'Open-RCE-Batt 社群版',
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
            label: '檢查更新',
            onTap: () => runUpdateCheck(context, manual: true),
          ),
          SettingsLinkRow(
            icon: Icons.code,
            label: 'GitHub 專案頁面',
            onTap: () => _copy(context, kGithubUrl),
          ),
          SettingsLinkRow(
            icon: Icons.description_outlined,
            label: '協定文件 PROTOCOL.md',
            onTap: () => _copy(context, kProtocolUrl),
          ),
          SettingsLinkRow(
            icon: Icons.link,
            label: '版權與免責聲明',
            onTap: () => _showAbout(context),
            last: true,
          ),
        ],
      ),
    );
  }
}

void _showAbout(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: context.colors.panel,
      title: const Text('版權與免責聲明', style: TextStyle(fontSize: 17)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本 App 為社群獨立開發的開源工具，基於公開逆向研究，'
              '透過藍牙與您已購買的 RCE 智慧電容／電池通訊。\n\n'
              '本專案非 RCE 官方產品、與原廠無任何關係，'
              '僅供已購買硬體之車主個人、非商業用途。',
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
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 15, color: AppColors.amber),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '解除斷電後請勿重新上鎖；電容本身過壓／低壓／過溫保護仍持續有效。',
                      style: TextStyle(
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
          child: const Text('關閉', style: TextStyle(color: AppColors.amber)),
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
  String confirmLabel = '確定',
}) async {
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
          child: Text('取消', style: TextStyle(color: context.colors.muted)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            confirmLabel,
            style: TextStyle(color: danger ? AppColors.danger : AppColors.amber),
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}
