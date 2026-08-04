/// OpenSmartBatt — shared primitives for the split protection controls.
///
/// The protection card has one body per product class ([CapacitorControls] /
/// [BatteryControls]) plus the unknown-class fallback [PackControls], because a
/// capacitor and a battery do not have the same controls. The badges, buttons,
/// advisory note, status interpretation and the action handlers all live here,
/// so the bodies differ ONLY in which of them they compose — no chrome is
/// duplicated and no body can quietly grow its own variant of a status rule.
///
/// SAFETY, and it is not symmetric:
///   * 復電 ([releaseCutOff]) writes "normal" (mode 0x00) and moves a pack
///     TOWARD running. One confirmation; the auth frame rides automatically
///     (cb from the device's own dealer code, pwSum from the built-in default),
///     so the owner needs no password — see its doc (design 0036).
///   * 斷電 ([cutOff]) and 防盜 ([antiTheft]) move a pack AWAY from running and
///     can leave a vehicle unable to start. Both require an explicit risk
///     confirmation and then the per-device auth dialog. In this build 斷電 has
///     no button anywhere; see [cutOff].
/// The gating helpers below encode the same lean: never refuse the way back,
/// never offer the way out on a device we cannot read.
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

/// May we offer 斷電 (mode 0x02)?
///
/// ONLY when the device positively reports normal. Every other case — cut-off,
/// anti-theft, and a byte we cannot place in the pack space at all — is refused:
/// we do not send a lock command to a device whose state we cannot read.
bool cutOffActionEnabled(int? mode) =>
    packRunModeOf(mode) == PackRunMode.normal;

/// May we offer 復電 (write "normal")?
///
/// The MIRROR of [cutOffActionEnabled], and deliberately NOT its negation-plus-
/// unknown: an unreadable state leaves release ENABLED. The asymmetry is the
/// whole point — refusing the release on a device we cannot read risks locking
/// an owner out of their vehicle, while the cost of the opposite mistake is one
/// wasted write. These are two separate functions rather than one bool and its
/// negation precisely so that asymmetry is visible in the types and testable.
///
/// This used to be unconditional, so a battery reporting `normal` still offered
/// a large red button that could not possibly do anything, and reported "sent"
/// when pressed. That is exactly what a field report described: the function
/// was tried, and nothing happened.
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

/// Watch `0x23` after a mode write and report what actually happened.
///
/// Every mode write used to report "sent" and stop there, because the wire
/// carries no acknowledgement — but `0x23` streams at roughly 1 Hz, so the
/// device's own answer arrives within seconds if we simply look. Six seconds at
/// 500 ms gives about six samples of a ~1 Hz register.
///
/// This turns each attempt into evidence, which matters while the release code
/// itself is unproven: eight writes of the previous code, across two packs,
/// changed nothing, and nobody could tell that from the app.
///
/// Reports "unchanged", never "failed". A device that ignored the write and one
/// that was never in that state look identical from here, and we do not know
/// which we are seeing.
Future<String> _modeWriteOutcome(
  AppLocalizations l10n,
  TelemetryController tele, {
  required String action,
  required int? before,
  required bool skipAuth,
}) async {
  const window = Duration(seconds: 6);
  const step = Duration(milliseconds: 500);
  final deadline = DateTime.now().add(window);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(step);
    if (tele.mode != before) {
      return l10n.modeChangedSnack(action, runStatusOf(l10n, tele.mode).label);
    }
  }
  final status = runStatusOf(l10n, tele.mode).label;
  return skipAuth
      ? l10n.modeUnchangedNoAuthSnack(action, status)
      : l10n.modeUnchangedSnack(action, status);
}

/// Resolve release auth WITHOUT asking the user (design 0036 §4.2):
///   * `cb`    — from the device's own dealer code (selector 0x27), via
///     [CommandBuilder.cbFromFieldCb] (the wire-confirmed 4-char rule:
///     `01680102` → `0168` → 168 = 0x00A8).
///   * `pwSum` — the built-in [kDefaultCutoffPwSum]; the cut-off password is
///     assumed a dealer-wide constant (design 0036 §2, working assumption).
/// Returns null when the dealer code has not arrived on the wire yet, so the
/// caller can fall back to the manual auth dialog.
///
/// Pure and [visibleForTesting]: the whole point is the cb rule, so it must be
/// unit-testable without a live connection.
@visibleForTesting
AuthCredentials? releaseAuthFromDealerCode(String? dealerCode) {
  if (dealerCode == null) return null;
  try {
    return AuthCredentials(
      cb: CommandBuilder.cbFromFieldCb(dealerCode),
      pwSum: kDefaultCutoffPwSum,
    );
  } on ArgumentError {
    return null; // too short — dealer code not on the wire yet
  } on FormatException {
    return null; // leading chars not decimal
  }
}

/// 復電 — write "normal" (mode 0x00) bundled with the auth frame.
///
/// Owner's decision 2026-08-04 (design 0036): the release always carries auth
/// (the only path proven to work on the wire — iOS eng-app HCI capture, mode-0
/// with auth moved `0x23` 02→00), but the owner never types a password: `cb`
/// comes from the device's own dealer code and `pwSum` from [kDefaultCutoffPwSum].
/// The no-auth mode-0 path is deliberately dropped (unproven; ruling Q3).
///
/// When the dealer code has not streamed yet, falls back to the manual auth
/// dialog so an owner who knows their code can still proceed.
///
/// [_modeWriteOutcome] reads `0x23` back and reports what actually happened, so
/// a wrong assumption (e.g. a different dealer's password) surfaces as "state
/// unchanged" rather than a false success.
///
/// Writing "normal" clears anti-theft as well as cut-off — hence the copy, and
/// hence the control is no longer named after cut-off alone.
Future<void> releaseCutOff(
    BuildContext context, TelemetryController tele) async {
  final conn = context.read<ConnectionController>();
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final action = l10n.commonReleaseCutOff;
  final before = tele.mode;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.releaseConfirmTitle),
      content: SingleChildScrollView(
        child: Text(
          l10n.releaseConfirmBody,
          style: TextStyle(color: ctx.colors.muted, height: 1.5),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l10n.releaseConfirmContinue),
        ),
      ],
    ),
  );
  if (ok != true) return;
  var creds = releaseAuthFromDealerCode(tele.dealerCode);
  if (creds == null) {
    // Dealer code not on the wire yet — let the owner supply auth manually.
    if (!context.mounted) return;
    final req = await showReleaseCutOffDialog(
      context,
      initialDealerCode: tele.dealerCode,
    );
    if (req == null || req.creds == null) return; // release requires auth (Q3)
    creds = req.creds!;
  }
  try {
    await conn.releaseCutOff(cb: creds.cb, pwSum: creds.pwSum);
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 3600),
      content: Text(await _modeWriteOutcome(l10n, tele,
          action: action, before: before, skipAuth: false)),
    ));
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 1600),
        content: Text(l10n.releaseFailedSnack('$e')),
      ),
    );
  }
}

/// 斷電 — manual cut-off (mode 0x02 + auth).
///
/// ⚠️ NO BUTTON IN THIS BUILD invokes this. It is kept, tested and gated so the
/// distributor build can wire it up without anyone re-deriving a destructive
/// path from scratch — that is how such a path comes back less careful. The
/// public app deliberately only ever moves a pack toward normal.
///
/// SAFETY: this is the app's only outbound command that can immobilise a
/// vehicle, and the release path that would undo it is **not proven to work** —
/// no capture in hand shows any pack responding to a mode write. Two gates
/// stand in front of it: an explicit risk confirmation naming that specific
/// consequence, then the same per-device auth dialog anti-theft uses. A caller
/// that adds a button must additionally gate it on [cutOffActionEnabled].
Future<void> cutOff(BuildContext context, TelemetryController tele) async {
  final conn = context.read<ConnectionController>();
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final action = l10n.commonCutOffAction;
  final before = tele.mode;
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
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 3600),
      content: Text(await _modeWriteOutcome(l10n, tele,
          action: action, before: before, skipAuth: req.skipAuth)),
    ));
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
  final before = tele.mode;
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
    // All three mode writes (復電 / 斷電 / 防盜) share one verification path, so
    // none of them can regress to reporting "sent" without looking.
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 3600),
      content: Text(await _modeWriteOutcome(l10n, tele,
          action: l10n.commonAntiTheft,
          before: before,
          skipAuth: req.skipAuth)),
    ));
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

/// The advisory notes that close a control body, with their spacing.
///
/// Spacing lives here because the notes are CONDITIONAL: 11 px above the first
/// one that renders, 7 px between, and nothing trailing. Each call site used to
/// hard-code `SizedBox(height: 11)` before the block and `SizedBox(height: 7)`
/// after every note, which was correct only because a permanent note always
/// closed the column. Design 0034 §5.4 removed those permanent notes, so an
/// unconditional gap would now hang off the bottom of a card whenever no note
/// fires — which is the common case.
///
/// Pass the notes in display order; empty entries are omitted by the caller's
/// own collection-`if`, and an empty list renders nothing at all.
List<Widget> advisoryNotes(List<String> texts) => [
      for (var i = 0; i < texts.length; i++) ...[
        SizedBox(height: i == 0 ? 11 : 7),
        AdvisoryNote(text: texts[i]),
      ],
    ];

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
