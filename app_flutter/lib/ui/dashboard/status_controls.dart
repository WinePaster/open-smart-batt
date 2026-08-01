/// OpenSmartBatt — per-class protection controls (mockup 防護狀態 / 模式).
///
/// One `StatusControls` used to serve every pack, which meant a capacitor and a
/// battery were handed the same buttons. They are different hardware: a
/// capacitor has no run mode, so cut-off and anti-theft do not exist for it,
/// while a battery has no capacitor to self-check. The control set is therefore
/// split per class — see [DeviceCapabilities] for the authoritative matrix:
///   * [CapacitorControls] — capacitor-health badge + 檢測電容 (read-only).
///   * [BatteryControls]  — cut-off badge + 復電 (confirmed, no auth) + 防盜
///     (model-gated, warned + auth-gated).
///   * [PackControls]     — the bounded [DeviceCapabilities.unknown] fallback
///     used while a pack is still being classified: the union of the two above
///     EXCEPT anti-theft.
///
/// The bodies are driven by an EXPLICIT widget choice (which body the pack shell
/// builds), not by reading `caps.*` booleans — except the two genuinely
/// model-gated bits (anti-theft, and the union membership of the fallback). All
/// badges/buttons/note come from `status_controls_shared.dart`, so no chrome is
/// duplicated. SAFETY: destructive paths stay auth-gated exactly as before.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import 'status_controls_shared.dart';

// ---------------------------------------------------------------------------
// Capacitor body: health badge + 檢測電容 (read-only).
// ---------------------------------------------------------------------------

/// Protection card body for a super-capacitor.
class CapacitorControls extends StatelessWidget {
  const CapacitorControls({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    final online = context.select<ConnectionController, bool>((c) => c.isOnline);

    // A capacitor has NO run mode: no cut-off, no anti-theft (see the device
    // capability matrix in [DeviceCapabilities]). The badge that used to sit
    // here read the 0x23 byte
    // through the pack code space and rendered a healthy unit's `5` as a red
    // "cut-off" — see [packRunModeOf]. Removed, not fixed in place: the control
    // was never applicable to this class.
    final health = capacitorHealthOf(tele.mode);
    final thresholdBreach = readingBreachesThreshold(tele);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusBadge(
          icon: Icons.monitor_heart_outlined,
          label: l10n.statusBadgeCapacitorLabel,
          value: switch (health) {
            CapacitorHealth.healthy => l10n.commonNormal,
            // Plain language, never the raw byte: this app's readers are
            // vehicle owners. The byte still reaches us — ConnectionController
            // writes it to the diagnostic log via the always-on event path.
            CapacitorHealth.unknown => l10n.statusBadgeCapacitorUnknown,
            null => '--',
          },
          tone: switch (health) {
            CapacitorHealth.healthy => ControlTone.good,
            CapacitorHealth.unknown => ControlTone.warn,
            null => ControlTone.neutral,
          },
        ),
        const SizedBox(height: 13),
        ControlButton(
          variant: ControlButtonVariant.ghost,
          icon: Icons.monitor_heart_outlined,
          label: l10n.controlDetectCapacitor,
          onPressed: online ? () => detectCapacitor(context, tele) : null,
        ),
        const SizedBox(height: 11),
        // Tell the owner what to DO about an unrecognised status, instead of
        // showing them a hex byte they cannot act on.
        if (health == CapacitorHealth.unknown) ...[
          AdvisoryNote(text: l10n.statusAdvisoryCapacitorUnknown),
          const SizedBox(height: 7),
        ],
        // Threshold breach is OUR computation, so it is an advisory line — it
        // must not masquerade as the device-reported status badge above.
        if (thresholdBreach) ...[
          AdvisoryNote(text: l10n.statusAdvisoryThresholdBreach),
          const SizedBox(height: 7),
        ],
        AdvisoryNote(text: l10n.statusAdvisoryNoteCapacitor),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Battery body: cut-off badge + 解除斷電 + 防盜 (model-gated).
// ---------------------------------------------------------------------------

/// Protection card body for a smart battery.
class BatteryControls extends StatelessWidget {
  const BatteryControls({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    final online = context.select<ConnectionController, bool>((c) => c.isOnline);
    // Anti-theft is genuinely model-gated — some battery models have the
    // hardware and some do not, and nothing on the wire says which. It is the
    // only caps.* bit this body still consults; everything else about which
    // controls belong here is already decided by WHICH body the pack shell
    // built.
    final hasAntiTheft = context
        .select<ConnectionController, bool>((c) => c.capabilities.hasAntiTheft);

    final runStatus = runStatusOf(l10n, tele.mode);
    final known = packRunModeOf(tele.mode) != null;
    // Named `isCutOff`, not `cutOff`: the latter now shadows the cut-off action
    // this body invokes.
    final isCutOff = isCutOffMode(tele.mode);
    // See `releaseActionEnabled` for the gate's asymmetry and why it leans the
    // way it does. `cutOffActionEnabled` is deliberately NOT consulted here —
    // this build ships no cut-off button at all (see the note below).
    final canRelease = releaseActionEnabled(tele.mode);
    // FB-30. This body was the ONLY one of the three that never consulted
    // `readingBreachesThreshold()` — a battery crossing the over/under-voltage or
    // over-temperature limits IT REPORTED (0x2B) said nothing at all, while a
    // capacitor and an unclassified pack both did. The gap widened when the
    // device-reported fault banner was removed — the bit it fired on turned out
    // to mean "charging" on a power bank, and had never had any supporting
    // evidence on a pack — leaving a battery with no abnormality signal of any
    // kind. This line is the one that remains.
    //
    // The name is historical — the helper is a threshold comparison over
    // PVLT/temperature against the device's own thresholds, and is not
    // capacitor-specific.
    final thresholdBreach = readingBreachesThreshold(tele);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: StatusBadge(
                icon: Icons.power_settings_new,
                label: l10n.statusBadgeRunModeLabel,
                value: runStatus.label,
                tone: runStatus.tone,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: StatusBadge(
                icon: Icons.power_off,
                label: l10n.commonCutOff,
                // `--` while the byte is outside the pack space: "off" would be
                // an assertion we cannot back (cf. [packRunModeOf]).
                value: !known
                    ? '--'
                    : isCutOff
                        ? l10n.statusBadgeCutOffOn
                        : l10n.statusBadgeCutOffOff,
                tone: isCutOff ? ControlTone.locked : ControlTone.neutral,
              ),
            ),
          ],
        ),
        const SizedBox(height: 13),
        // 🔴 The community build offers RELEASE ONLY (owner's decision,
        // 2026-07-30). Cut-off and anti-theft both leave a
        // vehicle unable to start, and the path back is still unproven, so the
        // build that reaches the general public only ever moves a pack toward
        // normal. The `cutOff()` action and its gate stay in
        // status_controls_shared.dart with their tests: the distributor build
        // will need them, and deleting a tested destructive path only to
        // rewrite it later is how it comes back less careful.
        Row(
          children: [
            Expanded(
              child: ControlButton(
                variant: ControlButtonVariant.warn,
                icon: Icons.power_settings_new,
                label: l10n.commonReleaseCutOff,
                onPressed: online && canRelease
                    ? () => releaseCutOff(context, tele)
                    : null,
              ),
            ),
            // Anti-theft is unchanged: still model-gated, so still off unless a
            // unit is explicitly marked as supporting it.
            if (hasAntiTheft) ...[
              const SizedBox(width: 9),
              Expanded(
                child: ControlButton(
                  variant: ControlButtonVariant.ghost,
                  icon: Icons.shield_outlined,
                  label: l10n.commonAntiTheft,
                  onPressed: online ? () => antiTheft(context, tele) : null,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 11),
        // A disabled button must say why. The gate exists because the button
        // used to be permanently live and report "command sent" against packs
        // that were already running normally — nothing could change, and the
        // user was told nothing had gone wrong either. Greying it out without a
        // reason would just move that confusion one step earlier. Only
        // shown while online: offline, everything is disabled for one obvious
        // reason and repeating it per-button is noise.
        if (online && !canRelease) ...[
          AdvisoryNote(text: l10n.releaseDisabledNote),
          const SizedBox(height: 7),
        ],
        // Same treatment as the other two bodies: OUR computation from the
        // device's own thresholds, so it is an advisory line and never a
        // device-reported status badge.
        if (thresholdBreach) ...[
          AdvisoryNote(text: l10n.statusAdvisoryThresholdBreach),
          const SizedBox(height: 7),
        ],
        AdvisoryNote(text: l10n.statusAdvisoryNoteBattery),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Fallback body: bounded union for an unclassified pack.
// ---------------------------------------------------------------------------

/// Protection card body for a pack that has not been classified yet: shows the
/// UNION of pack controls EXCEPT anti-theft, gated by
/// [DeviceCapabilities.unknown]. Lenient rather than empty, because every
/// control in that union is read-only or auth-gated, so the worst case is an
/// offered button that does nothing — whereas hiding everything would leave a
/// battery that needs 復電 with no way to ask for it. Converges to
/// [CapacitorControls] / [BatteryControls] the moment the cosmetic label
/// resolves.
class PackControls extends StatelessWidget {
  const PackControls({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    final online = context.select<ConnectionController, bool>((c) => c.isOnline);
    final caps = context
        .select<ConnectionController, DeviceCapabilities>((c) => c.capabilities);

    final runStatus = runStatusOf(l10n, tele.mode);
    final known = packRunModeOf(tele.mode) != null;
    final thresholdBreach = readingBreachesThreshold(tele);
    final cutOff = isCutOffMode(tele.mode);
    // The same asymmetric gate as the battery body. There is deliberately NO
    // 斷電 button in this body (owner's ruling, 2026-07-30): an unclassified
    // pack is one whose device type we could not even read, and sending it a
    // command that can immobilise a vehicle has no justification. Release
    // stays — it is the escape hatch, and this body already offered it.
    final canRelease = releaseActionEnabled(tele.mode);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Only the two PACK badges here. The capacitor-status badge is gone:
        // while the class is unresolved we do not know which code space the
        // 0x23 byte belongs to, so asserting capacitor health would be a guess.
        // Both badges self-disambiguate — a capacitor's byte is outside the
        // pack space, so they render `--` rather than a wrong state.
        Row(
          children: [
            Expanded(
              child: StatusBadge(
                icon: Icons.power_settings_new,
                label: l10n.statusBadgeRunModeLabel,
                value: runStatus.label,
                tone: runStatus.tone,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: StatusBadge(
                icon: Icons.power_off,
                label: l10n.commonCutOff,
                value: !known
                    ? '--'
                    : cutOff
                        ? l10n.statusBadgeCutOffOn
                        : l10n.statusBadgeCutOffOff,
                tone: cutOff ? ControlTone.locked : ControlTone.neutral,
              ),
            ),
          ],
        ),
        const SizedBox(height: 13),
        Row(
          children: [
            if (caps.isCapacitor) ...[
              Expanded(
                child: ControlButton(
                  variant: ControlButtonVariant.ghost,
                  icon: Icons.monitor_heart_outlined,
                  label: l10n.controlDetectCapacitor,
                  onPressed: online ? () => detectCapacitor(context, tele) : null,
                ),
              ),
              if (caps.hasCutOff) const SizedBox(width: 9),
            ],
            if (caps.hasCutOff)
              Expanded(
                child: ControlButton(
                  variant: ControlButtonVariant.warn,
                  icon: Icons.power_settings_new,
                  label: l10n.commonReleaseCutOff,
                  onPressed: online && canRelease
                      ? () => releaseCutOff(context, tele)
                      : null,
                ),
              ),
          ],
        ),
        const SizedBox(height: 11),
        if (caps.hasCutOff && online && !canRelease) ...[
          AdvisoryNote(text: l10n.releaseDisabledNote),
          const SizedBox(height: 7),
        ],
        // Threshold breach is class-agnostic (it only needs 0x2B + a reading),
        // so it survives the badge removal above as an advisory line.
        if (thresholdBreach) ...[
          AdvisoryNote(text: l10n.statusAdvisoryThresholdBreach),
          const SizedBox(height: 7),
        ],
        AdvisoryNote(text: l10n.statusAdvisoryNoteUnclassified),
      ],
    );
  }
}
