/// OpenSmartBatt — shared primitives for the split protection controls.
///
/// Design 0004 §3.4 splits `StatusControls` into per-class control bodies
/// ([CapacitorControls] / [BatteryControls]) plus the [unknown]-fallback
/// [PackControls]. The badges, buttons, advisory note, status interpretation and
/// the (auth-gated) action handlers are shared here so the bodies differ ONLY in
/// which badges/buttons they compose — no chrome is duplicated.
///
/// SAFETY: the destructive paths are unchanged from the pre-split widget — only
/// documented release (mode 0x06 + auth) is auto-buildable; anti-theft is warned
/// + user-confirmed; both go through the per-device auth dialog.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../protocol/protocol.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'release_cutoff_dialog.dart';

// ---------------------------------------------------------------------------
// Status interpretation (pure helpers, shared by every control body).
// ---------------------------------------------------------------------------

/// Run mode of a pack (smart battery), decoded from selector `0x23`.
enum PackRunMode { normal, antiTheft, cutOff }

/// Decode the `0x23` byte in the PACK status space ([ReportedStatus]).
///
/// Returns null when the byte is not one of the three pack codes — which is the
/// normal outcome on a super-capacitor, whose `0x23` answers in an entirely
/// different space ([CapacitorStatus]). Callers render null as `--`.
///
/// EQUALITY, not a bitmask. The previous mask (`mode & cutOffActive != 0`)
/// reported every healthy super-capacitor as "cut-off active" in red, because
/// its byte is `5` and `5 & 4 != 0`. The same bug fires for 6, 7, 12, 13…
PackRunMode? packRunModeOf(int? mode) => switch (mode) {
      ReportedStatus.normal => PackRunMode.normal,
      ReportedStatus.antiTheftActive => PackRunMode.antiTheft,
      ReportedStatus.cutOffActive => PackRunMode.cutOff,
      _ => null,
    };

/// Run-mode badge value + tone. Null [mode] (or a byte outside the pack space)
/// renders as a neutral `--` — we say nothing rather than guess.
RunStatus runStatusOf(AppLocalizations l10n, int? mode) =>
    switch (packRunModeOf(mode)) {
      PackRunMode.cutOff => RunStatus(l10n.commonCutOff, ControlTone.locked),
      PackRunMode.antiTheft =>
        RunStatus(l10n.commonAntiTheft, ControlTone.good),
      PackRunMode.normal => RunStatus(l10n.commonNormal, ControlTone.good),
      null => const RunStatus('--', ControlTone.neutral),
    };

/// Run-mode badge value + tone.
class RunStatus {
  const RunStatus(this.label, this.tone);
  final String label;
  final ControlTone tone;
}

/// True only when the pack reports cut-off ACTIVE. Exact match — see
/// [packRunModeOf] for why a bitmask is wrong here.
bool isCutOffMode(int? mode) => packRunModeOf(mode) == PackRunMode.cutOff;

/// May we offer 斷電 (mode 0x02)? — design 0020 §3.1 (FB-35).
///
/// ONLY when the device positively reports normal. Every other case — cut-off,
/// anti-theft, and a byte we cannot place in the pack space at all — is refused:
/// we do not send a lock command to a device whose state we cannot read.
bool cutOffActionEnabled(int? mode) =>
    packRunModeOf(mode) == PackRunMode.normal;

/// May we offer 解除斷電 (mode 0x06)? — design 0020 §3.1 (FB-34).
///
/// The MIRROR of [cutOffActionEnabled], and deliberately NOT its negation-plus-
/// unknown: an unreadable state leaves release ENABLED. The asymmetry is the
/// whole point — refusing the release on a device we cannot read risks locking
/// an owner out of their vehicle, while the cost of the opposite mistake is one
/// wasted write.
///
/// FB-34: this used to be unconditional, so a battery reporting `normal` still
/// offered a large red 解除斷電 button that could not possibly do anything, and
/// reported "sent" when pressed. That is exactly what a field report described
/// as 「測試斷電功能，無作動」.
bool releaseActionEnabled(int? mode) =>
    packRunModeOf(mode) != PackRunMode.normal;

/// Health of a super-capacitor as the DEVICE reports it (selector `0x23`).
///
/// Distinct from [readingBreachesThreshold], which is a threshold comparison WE compute
/// from live readings. Both are useful; conflating them is what made the old
/// capacitor card self-contradictory (device state shown in the threshold badge
/// and vice versa).
enum CapacitorHealth {
  /// The byte matches the value healthy units report ([CapacitorStatus.healthy]).
  healthy,

  /// Some other byte. We have no captured fault sample to name a code from, so
  /// this is reported as unknown WITH the raw byte, never guessed at.
  unknown,
}

/// Decode the `0x23` byte in the CAPACITOR status space.
/// Null [mode] means nothing has arrived yet — callers render `--`.
CapacitorHealth? capacitorHealthOf(int? mode) => mode == null
    ? null
    : mode == CapacitorStatus.healthy
        ? CapacitorHealth.healthy
        : CapacitorHealth.unknown;

/// True when a live reading breaches one of the thresholds the DEVICE reported
/// (OV / UV / OT, selector 0x2B).
///
/// This is OUR computation from telemetry, NOT a device-reported state — see
/// [CapacitorHealth]. It drives an advisory line, never the status badge.
///
/// Named for the class it was written for; it is not capacitor-specific and all
/// three control bodies use it (FB-30 — the battery body was the one that never
/// did, and a battery over its own limits therefore said nothing).
bool readingBreachesThreshold(TelemetryController tele) {
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

// ---------------------------------------------------------------------------
// Actions (auth-gated exactly as before the split).
// ---------------------------------------------------------------------------

/// 檢測電容 — read-only: surface the current SOH / capacity reading. No command
/// is sent (no capacitor self-check opcode is established by the protocol).
void detectCapacitor(BuildContext context, TelemetryController tele) {
  final l10n = AppLocalizations.of(context);
  final soh = tele.sohBucket;
  final svlt = tele.svlt;
  final msg = soh == null && svlt == null
      ? l10n.capacitorCheckNoData
      : l10n.capacitorCheckReadout(
          soh?.toString() ?? '--',
          svlt != null ? svlt.toStringAsFixed(2) : '--',
          tele.pvlt != null ? tele.pvlt!.toStringAsFixed(2) : '--',
        );
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(milliseconds: 1600),
      content: Text(l10n.capacitorCheckSnack(msg)),
    ),
  );
}

/// Snack text for a mode write that returned without throwing — design 0020 §3.3.
///
/// It says "sent", never "done". A mode write has **no observable
/// acknowledgement** on the wire: a 23-hour capture wrote mode 0x06 five times
/// and `0x23` stayed `0x00` on 2131/2131 frames, with no error frame and no
/// change in reply cadence (PROTOCOL.md §6.2). So the app cannot distinguish
/// accepted / rejected / already-in-that-state, and must not imply it can — it
/// reports what was sent plus what the device is reporting right now.
String _modeSentText(
  AppLocalizations l10n,
  TelemetryController tele, {
  required String action,
  required bool skipAuth,
}) {
  final status = runStatusOf(l10n, tele.mode).label;
  return skipAuth
      ? l10n.modeSentNoAuthSnack(action, status)
      : l10n.modeSentSnack(action, status);
}

/// 解除斷電 — documented-safe release (mode 0x06 + auth) via the auth dialog.
Future<void> releaseCutOff(
    BuildContext context, TelemetryController tele) async {
  final conn = context.read<ConnectionController>();
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final action = l10n.commonReleaseCutOff;
  final req = await showReleaseCutOffDialog(
    context,
    initialDealerCode: tele.dealerCode,
  );
  if (req == null) return;
  try {
    if (req.skipAuth) {
      await conn.releaseCutOffModeOnly();
    } else {
      await conn.releaseCutOff(cb: req.creds!.cb, pwSum: req.creds!.pwSum);
    }
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 2600),
        content: Text(_modeSentText(l10n, tele,
            action: action, skipAuth: req.skipAuth)),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 1600),
        content: Text(l10n.releaseFailedSnack('$e')),
      ),
    );
  }
}

/// 斷電 — manual cut-off (mode 0x02 + auth). Design 0020 Phase 2 (FB-35).
///
/// SAFETY: this is the app's first outbound command that can immobilise a
/// vehicle, and the release path that would undo it is **not proven to work**
/// (design 0020 §7 Q1 + FB-36). Two gates stand in front of it: an explicit
/// risk confirmation that names that specific consequence, then the same
/// per-device auth dialog anti-theft uses. The caller additionally gates the
/// button on [cutOffActionEnabled].
Future<void> cutOff(BuildContext context, TelemetryController tele) async {
  final conn = context.read<ConnectionController>();
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final action = l10n.commonCutOffAction;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(l10n.cutOffDialogTitle),
      content: SingleChildScrollView(
        child: Text(
          l10n.cutOffDialogBody,
          style: TextStyle(color: context.colors.muted, height: 1.5),
        ),
      ),
      actions: [
        // Cancel first and unstyled-destructive-last: the safe choice is the
        // one a hurried tap lands on.
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            l10n.cutOffDialogConfirm,
            style: const TextStyle(color: AppColors.danger),
          ),
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
      await conn.switchModeOnly(ModeArg.cutOff);
    } else {
      await conn.switchMode(ModeArg.cutOff,
          cb: req.creds!.cb, pwSum: req.creds!.pwSum);
    }
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 2600),
        content: Text(_modeSentText(l10n, tele,
            action: action, skipAuth: req.skipAuth)),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 1600),
        content: Text(l10n.cutOffFailedSnack('$e')),
      ),
    );
  }
}

/// 防盜 — NOT a documented-safe path: require explicit confirmation and the same
/// per-device auth before sending a gated mode code.
Future<void> antiTheft(BuildContext context, TelemetryController tele) async {
  final conn = context.read<ConnectionController>();
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(l10n.antiTheftDialogTitle),
      content: Text(
        l10n.antiTheftDialogBody,
        style: TextStyle(color: context.colors.muted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.commonContinue),
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
    // Same honesty as the other two mode writes (design 0020 §3.3): anti-theft
    // is no more acknowledged than release or cut-off is.
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 2600),
        content: Text(_modeSentText(l10n, tele,
            action: l10n.commonAntiTheft, skipAuth: req.skipAuth)),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 1600),
        content: Text(l10n.antiTheftFailedSnack('$e')),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared widgets (badge / button / note).
// ---------------------------------------------------------------------------

/// Badge tone (mockup `.badge` accents).
enum ControlTone { good, warn, locked, neutral }

/// Status badge (mockup `.badge` + `.active` / `.locked`).
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.tone,
  });

  final IconData icon;
  final String label;
  final String value;
  final ControlTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final accent = switch (tone) {
      ControlTone.good => AppColors.good,
      ControlTone.warn => AppColors.amber,
      ControlTone.locked => AppColors.danger,
      ControlTone.neutral => colors.muted,
    };
    final borderColor = tone == ControlTone.neutral ? colors.line : accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
      decoration: BoxDecoration(
        color: colors.panel2,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
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
              color: tone == ControlTone.neutral ? colors.text : accent,
            ),
          ),
        ],
      ),
    );
  }
}

/// Action-button variant (mockup `.btn` `.primary` / `.ghost` / `.warn`).
enum ControlButtonVariant { primary, ghost, warn }

/// Action button (mockup `.btn`). A null [onPressed] renders disabled (dimmed).
class ControlButton extends StatelessWidget {
  const ControlButton({
    super.key,
    required this.variant,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final ControlButtonVariant variant;
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
      case ControlButtonVariant.primary:
        bg = AppColors.amber;
        fg = AppColors.onAmber;
        border = Colors.transparent;
      case ControlButtonVariant.ghost:
        bg = context.colors.panel2;
        fg = context.colors.text;
        border = context.colors.line;
      case ControlButtonVariant.warn:
        bg = Colors.transparent;
        fg = AppColors.danger;
        border = AppColors.danger;
    }
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 7),
              // Flexible + ellipsis so multiple buttons never overflow on narrow
              // screens / high text scale.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: fg,
                  ),
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
class AdvisoryNote extends StatelessWidget {
  const AdvisoryNote({super.key, required this.text});

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
