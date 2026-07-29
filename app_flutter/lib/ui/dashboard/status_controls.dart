/// OpenSmartBatt — per-class protection controls (mockup 防護狀態 / 模式).
///
/// Design 0004 §3.4 splits the old single `StatusControls` into class-specific
/// bodies so a capacitor and a battery show the controls they actually have
/// (docs/devices.md capability matrix):
///   * [CapacitorControls] — capacitor-health badge + 檢測電容 (read-only).
///   * [BatteryControls]  — cut-off badge + 解除斷電 (auth-gated) + 防盜
///     (model-gated, warned + confirmed).
///   * [PackControls]     — the bounded [DeviceCapabilities.unknown] fallback
///     used while a pack is still being classified: the union of the two above
///     EXCEPT anti-theft (design 0004 §3.3).
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

/// Protection card body for a super-capacitor (design 0004 §3.4).
class CapacitorControls extends StatelessWidget {
  const CapacitorControls({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    final online = context.select<ConnectionController, bool>((c) => c.isOnline);

    // A capacitor has NO run mode: no cut-off, no anti-theft (docs/devices.md
    // capability matrix). The badge that used to sit here read the 0x23 byte
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

/// Protection card body for a smart battery (design 0004 §3.4).
class BatteryControls extends StatelessWidget {
  const BatteryControls({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    final online = context.select<ConnectionController, bool>((c) => c.isOnline);
    // Anti-theft is genuinely model-gated (design 0004 §3.2) — the only caps.*
    // bit this body still consults.
    final hasAntiTheft = context
        .select<ConnectionController, bool>((c) => c.capabilities.hasAntiTheft);

    final runStatus = runStatusOf(l10n, tele.mode);
    final known = packRunModeOf(tele.mode) != null;
    final cutOff = isCutOffMode(tele.mode);
    // FB-30. This body was the ONLY one of the three that never consulted
    // `readingBreachesThreshold()` — a battery crossing the over/under-voltage or
    // over-temperature limits IT REPORTED (0x2B) said nothing at all, while a
    // capacitor and an unclassified pack both did. The gap mattered more after
    // design 0018 removed the device-reported fault banner: between the two,
    // a battery had no abnormality signal of any kind left.
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
            Expanded(
              child: ControlButton(
                variant: ControlButtonVariant.warn,
                icon: Icons.power_settings_new,
                label: l10n.commonReleaseCutOff,
                onPressed: online ? () => releaseCutOff(context, tele) : null,
              ),
            ),
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
// Fallback body: bounded union for an unclassified pack (design 0004 §3.3).
// ---------------------------------------------------------------------------

/// Protection card body for a pack that has not been classified yet: shows the
/// UNION of pack controls EXCEPT anti-theft, gated by [DeviceCapabilities.unknown]
/// (design 0004 §3.3). Converges to [CapacitorControls] / [BatteryControls] the
/// moment the cosmetic label resolves.
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
                  onPressed: online ? () => releaseCutOff(context, tele) : null,
                ),
              ),
          ],
        ),
        const SizedBox(height: 11),
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
