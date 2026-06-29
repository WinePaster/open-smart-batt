/// Open-RCE-Batt — protection status + mode controls (mockup 防護狀態 / 模式).
///
/// Three status badges (run-mode / capacitor-health / cut-off) over a row of
/// capability-gated action buttons:
///   * 檢測電容 — capacitor self-check (read-only readout; no command sent).
///   * 解除斷電 — documented-safe release (mode 0x06 + auth) via the auth dialog.
///   * 防盜 — anti-theft toggle, shown ONLY when the model is flagged as
///     supporting it (heuristic; off by default).
///
/// SAFETY: only release (0x06) is documented-safe and auto-buildable; anti-theft
/// is gated, warned and user-confirmed. The mockup's amber advisory note closes
/// the card.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../protocol/protocol.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'release_cutoff_dialog.dart';

/// Status badges + gated controls + advisory note (one card body).
class StatusControls extends StatelessWidget {
  const StatusControls({super.key});

  @override
  Widget build(BuildContext context) {
    final tele = context.watch<TelemetryController>();
    final caps = tele.capabilities;
    final online = context.select<ConnectionController, bool>((c) => c.isOnline);

    final runStatus = _runStatusOf(tele.mode);
    final capWarn = _capacitorWarning(tele);
    final cutOff = _isCutOff(tele.mode);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ---- status badges -------------------------------------------------
        Row(
          children: [
            Expanded(
              child: _Badge(
                icon: Icons.power_settings_new,
                label: '運行模式',
                value: runStatus.label,
                tone: runStatus.tone,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _Badge(
                icon: Icons.monitor_heart_outlined,
                label: '電容狀態',
                value: capWarn ? '警告' : '正常',
                tone: capWarn ? _Tone.warn : _Tone.good,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _Badge(
                icon: Icons.power_off,
                label: '斷電',
                value: cutOff ? '啟用' : '關閉',
                tone: cutOff ? _Tone.locked : _Tone.neutral,
              ),
            ),
          ],
        ),

        // ---- capability-gated controls ------------------------------------
        const SizedBox(height: 13),
        Row(
          children: [
            if (caps.isCapacitor) ...[
              Expanded(
                child: _CtrlButton(
                  variant: _BtnVariant.ghost,
                  icon: Icons.monitor_heart_outlined,
                  label: '檢測電容',
                  onPressed: online ? () => _detectCapacitor(context, tele) : null,
                ),
              ),
              const SizedBox(width: 9),
            ],
            if (caps.hasCutOff)
              Expanded(
                child: _CtrlButton(
                  variant: _BtnVariant.warn,
                  icon: Icons.power_settings_new,
                  label: '解除斷電',
                  onPressed: online ? () => _releaseCutOff(context, tele) : null,
                ),
              ),
            if (caps.hasAntiTheft) ...[
              const SizedBox(width: 9),
              Expanded(
                child: _CtrlButton(
                  variant: _BtnVariant.ghost,
                  icon: Icons.shield_outlined,
                  label: '防盜',
                  onPressed: online ? () => _antiTheft(context, tele) : null,
                ),
              ),
            ],
          ],
        ),

        // ---- advisory note -------------------------------------------------
        const SizedBox(height: 11),
        const _Note(
          text:
              '本機已偵測為「超級電容」，僅顯示支援的功能（防盜模式僅在支援的電池型號出現）。'
              '解除斷電後建議勿再上鎖；電容本身過壓／低壓／過溫保護仍有效。',
        ),
      ],
    );
  }

  // ---- actions ------------------------------------------------------------

  void _detectCapacitor(BuildContext context, TelemetryController tele) {
    // Read-only: surface the current SOH / capacity reading. No command is
    // sent — no capacitor self-check opcode is established by the protocol.
    final soh = tele.sohBucket;
    final svlt = tele.svlt;
    final msg = soh == null && svlt == null
        ? '尚未取得電容讀數，請稍候即時資料更新。'
        : 'SOH ${soh ?? '--'}%'
            '${svlt != null ? ' · 次電壓 ${svlt.toStringAsFixed(2)} V' : ''}'
            '${tele.pvlt != null ? ' · 主電壓 ${tele.pvlt!.toStringAsFixed(2)} V' : ''}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(milliseconds: 1600), content: Text('電容檢測：$msg')),
    );
  }

  Future<void> _releaseCutOff(
      BuildContext context, TelemetryController tele) async {
    final conn = context.read<ConnectionController>();
    final messenger = ScaffoldMessenger.of(context);
    final req = await showReleaseCutOffDialog(
      context,
      initialDealerCode: tele.dealerCode,
    );
    if (req == null) return;
    try {
      if (req.skipAuth) {
        await conn.releaseCutOffModeOnly();
        messenger.showSnackBar(
          const SnackBar(duration: Duration(milliseconds: 1600), content: Text('已送出解除指令（實驗：未帶驗證）')),
        );
      } else {
        await conn.releaseCutOff(cb: req.creds!.cb, pwSum: req.creds!.pwSum);
        messenger.showSnackBar(
          const SnackBar(duration: Duration(milliseconds: 1600), content: Text('已送出解除斷電指令')),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(duration: const Duration(milliseconds: 1600), content: Text('解除失敗：$e')),
      );
    }
  }

  Future<void> _antiTheft(
      BuildContext context, TelemetryController tele) async {
    final conn = context.read<ConnectionController>();
    final messenger = ScaffoldMessenger.of(context);
    // Anti-theft is not a documented-safe path: require explicit confirmation
    // and the same per-device auth before sending a gated mode code.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('啟用防盜模式'),
        content: Text(
          '防盜模式尚未經完整驗證，僅在支援的型號顯示。確定要送出防盜指令嗎？',
          style: TextStyle(color: context.colors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('繼續'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    final req = await showReleaseCutOffDialog(
      context,
      initialDealerCode: tele.dealerCode,
    );
    if (req == null) return;
    try {
      if (req.skipAuth) {
        await conn.switchModeOnly(ModeArg.antiTheft);
      } else {
        await conn.switchMode(ModeArg.antiTheft,
            cb: req.creds!.cb, pwSum: req.creds!.pwSum);
      }
      messenger.showSnackBar(
        const SnackBar(duration: Duration(milliseconds: 1600), content: Text('已送出防盜指令')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text('指令失敗：$e')));
    }
  }

  // ---- status interpretation ---------------------------------------------

  static _RunStatus _runStatusOf(int? mode) {
    if (mode == null) return const _RunStatus('--', _Tone.neutral);
    if ((mode & ReportedStatus.cutOffActive) != 0) {
      return const _RunStatus('斷電', _Tone.locked);
    }
    if ((mode & ReportedStatus.antiTheftActive) != 0) {
      return const _RunStatus('防盜', _Tone.good);
    }
    return const _RunStatus('正常', _Tone.good);
  }

  static bool _isCutOff(int? mode) =>
      mode != null && (mode & ReportedStatus.cutOffActive) != 0;

  /// True when a live reading breaches a known warning threshold.
  static bool _capacitorWarning(TelemetryController tele) {
    final pvlt = tele.pvlt;
    final ov = tele.warnOv;
    final uv = tele.warnUv;
    final temp = tele.temperatureC;
    final ot = tele.warnOt;
    if (pvlt != null && ov != null && pvlt > ov) return true;
    if (pvlt != null && uv != null && pvlt < uv) return true;
    if (temp != null && ot != null && temp > ot) return true;
    return false;
  }
}

class _RunStatus {
  const _RunStatus(this.label, this.tone);
  final String label;
  final _Tone tone;
}

enum _Tone { good, warn, locked, neutral }

/// Status badge (mockup `.badge` + `.active` / `.locked`).
class _Badge extends StatelessWidget {
  const _Badge({
    required this.icon,
    required this.label,
    required this.value,
    required this.tone,
  });

  final IconData icon;
  final String label;
  final String value;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final accent = switch (tone) {
      _Tone.good => AppColors.good,
      _Tone.warn => AppColors.amber,
      _Tone.locked => AppColors.danger,
      _Tone.neutral => colors.muted,
    };
    final borderColor = tone == _Tone.neutral ? colors.line : accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
      decoration: BoxDecoration(
        color: colors.panel2,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 1,
              color: colors.muted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: tone == _Tone.neutral ? colors.text : accent,
            ),
          ),
        ],
      ),
    );
  }
}

enum _BtnVariant { primary, ghost, warn }

/// Action button (mockup `.btn` `.primary` / `.ghost` / `.warn`).
class _CtrlButton extends StatelessWidget {
  const _CtrlButton({
    required this.variant,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final _BtnVariant variant;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    late final Color bg;
    late final Color fg;
    late final Color border;
    switch (variant) {
      case _BtnVariant.primary:
        bg = AppColors.amber;
        fg = AppColors.onAmber;
        border = Colors.transparent;
      case _BtnVariant.ghost:
        bg = context.colors.panel2;
        fg = context.colors.text;
        border = context.colors.line;
      case _BtnVariant.warn:
        bg = Colors.transparent;
        fg = AppColors.danger;
        border = AppColors.danger;
    }
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Amber advisory note (mockup `.note`).
class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.amber),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 10.5,
              height: 1.6,
              color: AppColors.amber,
            ),
          ),
        ),
      ],
    );
  }
}
