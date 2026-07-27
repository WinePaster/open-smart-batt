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

    final runStatus = runStatusOf(l10n, tele.mode);
    final capWarn = capacitorWarning(tele);

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
                icon: Icons.monitor_heart_outlined,
                label: l10n.statusBadgeCapacitorLabel,
                value: capWarn ? l10n.commonWarning : l10n.commonNormal,
                tone: capWarn ? ControlTone.warn : ControlTone.good,
              ),
            ),
          ],
        ),
        const SizedBox(height: 13),
        ControlButton(
          variant: ControlButtonVariant.ghost,
          icon: Icons.monitor_heart_outlined,
          label: l10n.controlDetectCapacitor,
          onPressed: online ? () => detectCapacitor(context, tele) : null,
        ),
        const SizedBox(height: 11),
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
    final cutOff = isCutOffMode(tele.mode);

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
                value: cutOff
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
    final capWarn = capacitorWarning(tele);
    final cutOff = isCutOffMode(tele.mode);

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
                icon: Icons.monitor_heart_outlined,
                label: l10n.statusBadgeCapacitorLabel,
                value: capWarn ? l10n.commonWarning : l10n.commonNormal,
                tone: capWarn ? ControlTone.warn : ControlTone.good,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: StatusBadge(
                icon: Icons.power_off,
                label: l10n.commonCutOff,
                value: cutOff
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
        AdvisoryNote(text: l10n.statusAdvisoryNoteUnclassified),
      ],
    );
  }
}
