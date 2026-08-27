/// OpenSmartBatt — per-class protection controls (mockup 防護狀態 / 模式).
///
/// One `StatusControls` used to serve every pack, which meant a capacitor and a
/// battery were handed the same buttons. They are different hardware: a
/// capacitor has no run mode, so cut-off and anti-theft do not exist for it,
/// while a battery has no capacitor to self-check. The control set is therefore
/// split per class — see [DeviceCapabilities] for the authoritative matrix:
///   * [CapacitorControls] — capacitor-health badge + 檢測電容 (a real write
///     since 2026-08-28; see `capacitorSelfCheck`).
///   * [BatteryControls]  — cut-off badge + 復電 (confirmed, no auth) + 防盜
///     (model-gated, warned + auth-gated).
///   * [PackControls]     — the bounded [DeviceCapabilities.unknown] fallback
///     used while a pack is still being classified: 復電 only.
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
import '../util/alert_thresholds_lookup.dart';
import 'status_controls_shared.dart';

// ---------------------------------------------------------------------------
// Capacitor body: health badge + 檢測電容 (read-only).
// ---------------------------------------------------------------------------

/// Protection card body for a super-capacitor.
///
/// Stateful for exactly one reason: 檢測電容 is an in-flight operation now
/// (design 0082 Q5 — lock the controls while the check runs), and "is this
/// unit's check ours and still running" is a property of this screen's press,
/// not of the device. The device-side half of the same question — whether the
/// unit is IN self-check — is read from `0x23` and not tracked here, so the
/// badge stays right even for a check somebody else started.
class CapacitorControls extends StatefulWidget {
  const CapacitorControls({super.key, this.deviceId});

  /// The unit whose page this body sits on, or null when the caller names none.
  ///
  /// 🔴 **Design 0080 §3.9: a threshold follows the DEVICE, never "whoever is
  /// connected".** Design 0079 §0.3 logged what happens otherwise — unit A's
  /// rows judged against unit B's limits — so the id is threaded in from
  /// [PackView] rather than looked up from `ConnectionController` here, even
  /// though on this surface the two agree today (the detail page only builds a
  /// dashboard when the page's unit IS the live one).
  ///
  /// Null is a supported value and means "no saved record to consult": layer ①
  /// and the declaration both live in `saved_devices`, so an unnamed unit
  /// resolves from its own `0x2B` alone — which is exactly what design 0055 made
  /// an ordinary way to use the app, and what every widget test in this repo
  /// constructs.
  final String? deviceId;

  @override
  State<CapacitorControls> createState() => _CapacitorControlsState();
}

class _CapacitorControlsState extends State<CapacitorControls> {
  /// True from the moment 檢測電容 is pressed until `capacitorSelfCheck`
  /// returns — the design 0082 Q5 lock.
  bool _selfCheckBusy = false;

  Future<void> _runSelfCheck(TelemetryController tele) async {
    setState(() => _selfCheckBusy = true);
    try {
      await capacitorSelfCheck(context, tele);
    } finally {
      // `finally`, so a throw on the way out cannot strand the card disabled
      // with nothing to press. `mounted` because the wait outlives a page pop.
      if (mounted) setState(() => _selfCheckBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    final online = context.select<ConnectionController, bool>((c) => c.isOnline);

    // A capacitor has no cut-off and no anti-theft (see the device capability
    // matrix in [DeviceCapabilities]). The badge that used to sit
    // here read the 0x23 byte
    // through the pack code space and rendered a healthy unit's `5` as a red
    // "cut-off" — see [packRunModeOf]. Removed, not fixed in place: the control
    // was never applicable to this class.
    final health = capacitorHealthOf(tele.mode);
    final selfChecking = health == CapacitorHealth.selfCheck;
    // 🔵 FB-102 ②. The unit's voltage falls far below its resting value while a
    // self-check runs, and every threshold this line compares against was
    // written for a unit that is NOT being checked — so the advisory would fire
    // on the check, name it 過壓/低壓/過溫, and be describing the measurement
    // rather than the pack. The notification path suppresses the same phase for
    // the same reason; see `AlertEvaluator.fold`. The two must agree, per the
    // standing rule that this comparator and the alarm's never diverge.
    final thresholdBreach = !selfChecking &&
        readingBreachesThreshold(
            tele, watchAlertThresholds(context, widget.deviceId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusBadge(
          icon: Icons.monitor_heart_outlined,
          label: l10n.statusBadgeCapacitorLabel,
          value: switch (health) {
            CapacitorHealth.healthy => l10n.commonNormal,
            // Busy, not broken. This member is the FB-102 fix: the byte used to
            // land in `unknown` and badge a working unit as 「無法辨識」.
            CapacitorHealth.selfCheck => l10n.statusBadgeCapacitorSelfCheck,
            // Plain language, never the raw byte: this app's readers are
            // vehicle owners. The byte still reaches us — ConnectionController
            // writes it to the diagnostic log via the always-on event path.
            CapacitorHealth.unknown => l10n.statusBadgeCapacitorUnknown,
            null => '--',
          },
          tone: switch (health) {
            CapacitorHealth.healthy => ControlTone.good,
            // Neutral, deliberately: amber here would put a working unit back
            // in the warning colour FB-102 is about, and green would claim a
            // verdict the byte does not carry.
            CapacitorHealth.selfCheck => ControlTone.neutral,
            CapacitorHealth.unknown => ControlTone.warn,
            null => ControlTone.neutral,
          },
        ),
        const SizedBox(height: 13),
        ControlButton(
          variant: ControlButtonVariant.ghost,
          icon: Icons.monitor_heart_outlined,
          label: l10n.controlDetectCapacitor,
          // Disabled while OUR check is in flight (Q5) and while the unit says
          // it is already in one — a second `0x06` on top of a running check is
          // a write we have no reason to believe is harmless.
          onPressed: online && !_selfCheckBusy && !selfChecking
              ? () => _runSelfCheck(tele)
              : null,
        ),
        // The permanent "this unit is a super-capacitor…" note was removed on
        // 2026-08-04 (design 0034 §5.4): it fired on every render and told the
        // owner nothing they could act on. What is left is conditional and
        // actionable. ⚠️ The accepted consequence is that a capacitor owner
        // now sees fewer buttons than a battery owner with NO explanation —
        // if that turns into a question, the answer is an expandable ⓘ, not
        // the permanent paragraph coming back.
        ...advisoryNotes([
          // What is happening and what to do about it, while the unit is busy.
          if (selfChecking) l10n.statusAdvisoryCapacitorSelfCheck,
          // Tell the owner what to DO about an unrecognised status, instead of
          // showing them a hex byte they cannot act on.
          if (health == CapacitorHealth.unknown)
            l10n.statusAdvisoryCapacitorUnknown,
          // Threshold breach is OUR computation, so it is an advisory line —
          // it must not masquerade as the device-reported status badge above.
          if (thresholdBreach) l10n.statusAdvisoryThresholdBreach,
        ]),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Battery body: cut-off badge + 解除斷電 + 防盜 (model-gated).
// ---------------------------------------------------------------------------

/// Protection card body for a smart battery.
class BatteryControls extends StatelessWidget {
  const BatteryControls({super.key, this.deviceId});

  /// The unit whose page this body sits on, or null when the caller names none.
  ///
  /// 🔴 **Design 0080 §3.9: a threshold follows the DEVICE, never "whoever is
  /// connected".** Design 0079 §0.3 logged what happens otherwise — unit A's
  /// rows judged against unit B's limits — so the id is threaded in from
  /// [PackView] rather than looked up from `ConnectionController` here, even
  /// though on this surface the two agree today (the detail page only builds a
  /// dashboard when the page's unit IS the live one).
  ///
  /// Null is a supported value and means "no saved record to consult": layer ①
  /// and the declaration both live in `saved_devices`, so an unnamed unit
  /// resolves from its own `0x2B` alone — which is exactly what design 0055 made
  /// an ordinary way to use the app, and what every widget test in this repo
  /// constructs.
  final String? deviceId;


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
    final thresholdBreach =
        readingBreachesThreshold(tele, watchAlertThresholds(context, deviceId));

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
        // The permanent "this unit is a smart battery…" note was removed on
        // 2026-08-04 (design 0034 §5.4). Both survivors are conditional and
        // both tell the reader what to do next.
        ...advisoryNotes([
          // A disabled button must say why. The gate exists because the button
          // used to be permanently live and report "command sent" against packs
          // that were already running normally — nothing could change, and the
          // user was told nothing had gone wrong either. Greying it out without
          // a reason would just move that confusion one step earlier. Only
          // shown while online: offline, everything is disabled for one obvious
          // reason and repeating it per-button is noise.
          if (online && !canRelease) l10n.releaseDisabledNote,
          // Same treatment as the other two bodies: OUR computation from the
          // device's own thresholds, so it is an advisory line and never a
          // device-reported status badge.
          if (thresholdBreach) l10n.statusAdvisoryThresholdBreach,
        ]),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Fallback body: bounded union for an unclassified pack.
// ---------------------------------------------------------------------------

/// Protection card body for a pack that has not been classified yet: 復電 only,
/// gated by [DeviceCapabilities.unknown]. Lenient rather than empty, because
/// that control is auth-gated, so the worst case is an offered button that does
/// nothing — whereas hiding everything would leave a battery that needs 復電
/// with no way to ask for it. Converges to [CapacitorControls] /
/// [BatteryControls] the moment the cosmetic label resolves.
///
/// 🔵 **檢測電容 was removed from this body on 2026-08-28** (design 0082 Q8).
/// It was here as the other half of the "bounded union", and that union's whole
/// justification is the sentence above: nothing in it can change a device's
/// state. Q1 turned 檢測電容 into a real `0x23` write, so keeping it here would
/// have made that sentence false — and the class most likely to receive the
/// write through this route is a power-bank-labelled shell, which has no
/// capacitor at all.
class PackControls extends StatelessWidget {
  const PackControls({super.key, this.deviceId});

  /// The unit whose page this body sits on, or null when the caller names none.
  ///
  /// 🔴 **Design 0080 §3.9: a threshold follows the DEVICE, never "whoever is
  /// connected".** Design 0079 §0.3 logged what happens otherwise — unit A's
  /// rows judged against unit B's limits — so the id is threaded in from
  /// [PackView] rather than looked up from `ConnectionController` here, even
  /// though on this surface the two agree today (the detail page only builds a
  /// dashboard when the page's unit IS the live one).
  ///
  /// Null is a supported value and means "no saved record to consult": layer ①
  /// and the declaration both live in `saved_devices`, so an unnamed unit
  /// resolves from its own `0x2B` alone — which is exactly what design 0055 made
  /// an ordinary way to use the app, and what every widget test in this repo
  /// constructs.
  final String? deviceId;


  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    final online = context.select<ConnectionController, bool>((c) => c.isOnline);
    final hasCutOff = context
        .select<ConnectionController, bool>((c) => c.capabilities.hasCutOff);

    final runStatus = runStatusOf(l10n, tele.mode);
    final known = packRunModeOf(tele.mode) != null;
    final thresholdBreach =
        readingBreachesThreshold(tele, watchAlertThresholds(context, deviceId));
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
            if (hasCutOff)
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
        // The permanent "the device type is not recognised yet…" note was
        // removed on 2026-08-04 (design 0034 §5.4). ⚠️ Note what it also
        // carried: "you can set the type above" — the only pointer to the
        // label picker in the chip. The picker itself is unchanged and still
        // the only place a class can be chosen.
        ...advisoryNotes([
          if (hasCutOff && online && !canRelease) l10n.releaseDisabledNote,
          // Threshold breach is class-agnostic (it only needs 0x2B + a
          // reading), so it survives the badge removal above as an advisory
          // line.
          if (thresholdBreach) l10n.statusAdvisoryThresholdBreach,
        ]),
      ],
    );
  }
}
