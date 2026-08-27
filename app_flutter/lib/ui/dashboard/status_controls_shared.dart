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

import 'package:clock/clock.dart';
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

  /// A self-check is in progress ([CapacitorStatus.isSelfCheck]).
  ///
  /// 🔵 **FB-102.** This member is the fix: `0x06` / `0x07` used to fall into
  /// [unknown], so a unit that had merely been put into self-check was badged
  /// 「無法辨識」 in amber and its owner was told to export a diagnostic log.
  /// It is NOT a health verdict — it says the unit is busy, and nothing about
  /// whether it is well.
  selfCheck,

  /// Some other byte. We have no captured fault sample to name a code from, so
  /// this is reported as unknown WITH the raw byte, never guessed at.
  unknown,
}

/// Decode the `0x23` byte in the CAPACITOR status space.
/// Null [mode] means nothing has arrived yet — callers render `--`.
CapacitorHealth? capacitorHealthOf(int? mode) => switch (mode) {
      null => null,
      CapacitorStatus.healthy => CapacitorHealth.healthy,
      _ => CapacitorStatus.isSelfCheck(mode)
          ? CapacitorHealth.selfCheck
          : CapacitorHealth.unknown,
    };

/// True when a live reading breaches one of this unit's RESOLVED thresholds
/// (OV / UV / OT).
///
/// This is OUR computation from telemetry, NOT a device-reported state — see
/// [CapacitorHealth]. It drives an advisory line, never the status badge.
///
/// Named for the class it was written for; it is not capacitor-specific and all
/// three control bodies use it (FB-30 — the battery body was the one that never
/// did, and a battery over its own limits therefore said nothing).
///
/// 🔵 **Design 0080 §3.8 / §7.1 (P2): [thresholds] replaced three direct reads
/// of `tele.warnOv` / `warnUv` / `warnOt`.** That is the whole point of the
/// change and it is not a refactor:
///
///   * those three fields are layer ② ALONE, so this line used to ignore a
///     threshold the user had typed for this very unit and report「正常」while
///     the notification the same reading is about to raise says otherwise —
///     the "one fact, two sources" failure this repo has three logged incidents
///     of, aimed at an alarm;
///   * and it used to fire on a unit whose class nothing had identified, where
///     §7.5.6 C-2 says we do not know what 12.0 V even means. [AlertThresholds]
///     comes back empty in that case, so this returns false without needing to
///     know why — the SCREEN is the thing that must tell the two "empty"s apart
///     (`AlertsDisabledReason`), not this comparison.
///
/// The comparison itself is unchanged, strictly greater / strictly less, and is
/// deliberately the same shape as `AlertEvaluator`'s: two comparators disagreeing
/// on the boundary would put the advisory line and the notification one hundredth
/// of a volt apart.
bool readingBreachesThreshold(
  TelemetryController tele,
  AlertThresholds thresholds,
) {
  final pvlt = tele.pvlt;
  final temp = tele.temperatureC;
  final ov = thresholds.ov.value;
  final uv = thresholds.uv.value;
  final ot = thresholds.ot.value;
  if (pvlt != null && ov != null && pvlt > ov) return true;
  if (pvlt != null && uv != null && pvlt < uv) return true;
  if (temp != null && ot != null && temp > ot) return true;
  return false;
}

// ---------------------------------------------------------------------------
// Actions (auth-gated exactly as before the split).
// ---------------------------------------------------------------------------

/// How long the SELF-CHECK button stays locked waiting for the unit to report
/// [CapacitorStatus.healthy] again.
///
/// 🔴 **Read what this is and what it is not.** It is a cap on how long THIS
/// APP holds its own button, and nothing else. It is NOT a claim about how long
/// a self-check takes, and it is deliberately not a countdown on screen: the
/// one figure anybody ever wrote down for that ("about ten seconds") came from
/// a single observation of a single unit and does not survive the wire —
/// checks have been seen returning to normal in about six seconds and have been
/// seen staying in self-check across three reconnections and 23 minutes. A
/// hard-coded timer would be showing the user a number we know to be wrong,
/// which is worse than showing none. Same reasoning as design 0081's "no live
/// counter".
const Duration _selfCheckWatchLimit = Duration(seconds: 30);

/// How long we wait for the unit to acknowledge the write by moving `0x23` off
/// [CapacitorStatus.healthy] at all. Short, because the read-back is the first
/// thing that changes; the long wait is [_selfCheckWatchLimit], after it.
const Duration _selfCheckAckWindow = Duration(seconds: 8);

/// What one press of 檢測電容 ended in — the four outcomes, so the caller's copy
/// and the tests name the same set.
enum CapacitorSelfCheckOutcome {
  /// The user backed out of the confirmation, or auth could not be derived.
  notSent,

  /// Sent, and `0x23` never moved. Nothing observable changed.
  noResponse,

  /// The unit entered self-check and then reported [CapacitorStatus.healthy]
  /// again on its own.
  finished,

  /// The unit entered self-check and was still in it when we stopped watching.
  ///
  /// 🔴 NOT a failure and NOT a cancellation — see [capacitorSelfCheck].
  stillRunning,
}

/// 檢測電容 — start a real self-check on a super-capacitor (design 0082 Q1).
///
/// 🔴 **This button used to send NOTHING.** It reprinted the SOH / voltage
/// numbers already on the screen into a snackbar and called that a check, which
/// is the reason design 0082 exists: a control named after an action that did
/// not happen. Confirmed on the wire as late as 2026-08-27 — a whole session
/// with the button pressed carried no outbound write except the routine polls.
///
/// What it does now: `0x23` <- [ModeArg.capacitorSelfCheck], bundled with the
/// auth sub-frame in one 15-byte write, i.e. exactly the shape every other mode
/// write in this app already had ([CommandBuilder.switchMode]). Auth is derived
/// the same way the release derives it ([releaseAuthFromDealerCode]) — the
/// owner types nothing.
///
/// ## The three rules this flow is built around
///
/// 1. **Confirm first, with the consequence, not with "are you sure".** The
///    capacitor's voltage drops while the check runs, so the dialog says that.
///    An `AlertDialog`, the same shape as the cut-off confirmation: two writes
///    that both change how a device behaves must not be presented differently.
/// 2. **Unlock on what the DEVICE says, never on a stopwatch.** We wait for
///    `0x23` to come back to [CapacitorStatus.healthy]. [_selfCheckWatchLimit]
///    exists so the button cannot be locked forever, and its expiry is a fact
///    about this app, not about the device.
/// 3. 🔴 **We never write the unit back out of self-check. Not on give-up, not
///    on any path.** (Owner's ruling, 2026-08-28, over an explicitly considered
///    alternative.) The known cost is accepted and is stated to the user rather
///    than hidden: when the watch expires we say the unit may still be in
///    self-check and that we have not taken it out. What we must not say is
///    "finished" or "cancelled" — both would be claims about a device we have
///    stopped being able to back up.
///
/// The ONE outbound write in this function is [ConnectionController
/// .capacitorSelfCheck]. Anything that adds a second one is undoing rule 3.
Future<CapacitorSelfCheckOutcome> capacitorSelfCheck(
    BuildContext context, TelemetryController tele) async {
  final conn = context.read<ConnectionController>();
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.capacitorSelfCheckDialogTitle),
      content: SingleChildScrollView(
        child: Text(
          l10n.capacitorSelfCheckDialogBody,
          style: TextStyle(color: ctx.colors.muted, height: 1.5),
        ),
      ),
      actions: [
        // Cancel first — the safe choice is the one a hurried tap lands on,
        // same ordering as the cut-off dialog.
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l10n.capacitorSelfCheckDialogConfirm),
        ),
      ],
    ),
  );
  if (confirmed != true) return CapacitorSelfCheckOutcome.notSent;

  // Auth rides along automatically, exactly as the release does. No manual
  // dialog fallback here: that dialog is written for the cut-off flow, and
  // borrowing it would put cut-off copy in front of a capacitor owner. The
  // dealer code arrives within seconds of a link going ready, so "not yet" is
  // a wait, not a dead end.
  final creds = releaseAuthFromDealerCode(tele.dealerCode);
  if (creds == null) {
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 3600),
      content: Text(l10n.capacitorSelfCheckNotReady),
    ));
    return CapacitorSelfCheckOutcome.notSent;
  }

  try {
    await conn.capacitorSelfCheck(cb: creds.cb, pwSum: creds.pwSum);
    // The same write ++ read-back pairing the release uses. A lone mode write
    // was measured to be intermittent, and this is a read, so it cannot take
    // the device anywhere.
    await conn.pollMode();
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 3600),
      content: Text(l10n.capacitorSelfCheckFailedSnack('$e')),
    ));
    return CapacitorSelfCheckOutcome.notSent;
  }

  final entered = await _waitFor(
      tele, (m) => CapacitorStatus.isSelfCheck(m), _selfCheckAckWindow);
  if (!entered) {
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 4200),
      content: Text(l10n.capacitorSelfCheckNoResponseSnack),
    ));
    return CapacitorSelfCheckOutcome.noResponse;
  }

  final returned = await _waitFor(
      tele, (m) => m == CapacitorStatus.healthy, _selfCheckWatchLimit);
  messenger.showSnackBar(SnackBar(
    duration: const Duration(milliseconds: 4200),
    content: Text(returned
        ? l10n.capacitorSelfCheckDoneSnack
        : l10n.capacitorSelfCheckStillRunningSnack),
  ));
  // 🔴 Nothing is written here on either branch. See rule 3 above.
  return returned
      ? CapacitorSelfCheckOutcome.finished
      : CapacitorSelfCheckOutcome.stillRunning;
}

/// Poll `0x23` until [test] accepts it or [window] runs out.
///
/// The read-only sibling of [_modeChangedWithin]: that one asks "did it move
/// off the value it had", which cannot express "did it come back to 0x05" —
/// and the self-check needs the second question, because the value it started
/// from is the value it has to return to.
///
/// 🔑 `clock.now()`, not `DateTime.now()`. The two agree in production (the
/// default clock IS `DateTime.now`), and they differ in exactly one place that
/// matters: a test can substitute the first, so "the app gave up and STILL
/// wrote nothing" is checkable without spending the give-up window in real
/// seconds. Same reason `AlertEvaluator` and `connection_controller`'s
/// autoConnect deadline read it.
Future<bool> _waitFor(
    TelemetryController tele, bool Function(int?) test, Duration window) async {
  const step = Duration(milliseconds: 500);
  final deadline = clock.now().add(window);
  while (clock.now().isBefore(deadline)) {
    if (test(tele.mode)) return true;
    await Future<void>.delayed(step);
  }
  return test(tele.mode);
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

/// Polls `0x23` for up to [window] and returns whether it moved off [before].
/// The bool form the release retry loop needs — [_modeWriteOutcome] is the
/// message form used by the single-shot cut-off / anti-theft actions.
Future<bool> _modeChangedWithin(
    TelemetryController tele, int? before, Duration window) async {
  const step = Duration(milliseconds: 500);
  final deadline = DateTime.now().add(window);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(step);
    if (tele.mode != before) return true;
  }
  return false;
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

/// Release retries the mode+auth ++ read-back pair this many times, watching
/// `0x23` for [_releaseWindow] after each, before it reports (design 0036 §10).
const int _releaseAttempts = 3;
const Duration _releaseWindow = Duration(seconds: 3);

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
/// Each attempt writes the mode+auth frame, then the `0x23` read-back poll
/// ([ConnectionController.pollMode]) — the pairing the engineering app uses —
/// and watches `0x23`. A single write was observed to be intermittent (an
/// identical frame failed at 15:58 and succeeded at 16:17 on the same pack,
/// FB 2026.08.04/003), so we retry the pair up to [_releaseAttempts] times
/// before reporting. `0x23` back-reads make a wrong assumption (e.g. a different
/// dealer's password) surface as "unchanged" rather than a false success.
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
    var changed = false;
    for (var i = 0; i < _releaseAttempts && !changed; i++) {
      await conn.releaseCutOff(cb: creds.cb, pwSum: creds.pwSum); // mode+auth
      await conn.pollMode(); // 0x23 read-back — match the eng-app pairing
      changed = await _modeChangedWithin(tele, before, _releaseWindow);
    }
    final status = runStatusOf(l10n, tele.mode).label;
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 4200),
      content: Text(changed
          ? l10n.modeChangedSnack(action, status)
          : l10n.modeUnchangedRetriedSnack(action, _releaseAttempts, status)),
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
/// vehicle. Two gates stand in front of it: an explicit risk confirmation
/// naming that specific consequence, then the same per-device auth dialog
/// anti-theft uses. A caller that adds a button must additionally gate it on
/// [cutOffActionEnabled].
///
/// The release path that would undo it used to be described here as "not proven
/// to work — no capture in hand shows any pack responding to a mode write".
/// That is **no longer true** (corrected 2026-08-14): three independent packs
/// released 5 times out of 5 attempts, `0x23` following the write within
/// 2–89 ms. See `releaseCutOff` in ConnectionController.
///
/// ⚠️ The gates stay exactly as they are, and this correction is **not** a
/// reason to relax them. Release works but is not reliable on the first try —
/// one of six writes drew no response and needed the automatic retry — so a
/// build that wires up a cut-off button is still committing a user to a path
/// whose undo can take several seconds and, in principle, may not land at all.
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
            style: const TextStyle(color: AppSemantics.danger),
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
    // 🔴 One switch, three status colours: they are only ever readable as a
    // set. If `warn` followed the user's accent (design 0064) and the accent
    // were red, "warning" and "locked" would render identically — and in the
    // default amber theme that mistake is invisible.
    final accent = switch (tone) {
      ControlTone.good => AppSemantics.good,
      ControlTone.warn => AppSemantics.warn,
      ControlTone.locked => AppSemantics.danger,
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
      // BRAND, not status: this enum picks a BUTTON TREATMENT, and its own
      // `warn` member below uses `danger`, so `primary` is not "the amber
      // tone" — it is the app's filled primary action, the same thing
      // `ElevatedButtonTheme` paints. It follows the accent (design 0064).
      case ControlButtonVariant.primary:
        bg = context.accent.accent;
        fg = context.accent.onAccent;
        border = Colors.transparent;
      case ControlButtonVariant.ghost:
        bg = context.colors.panel2;
        fg = context.colors.text;
        border = context.colors.line;
      case ControlButtonVariant.warn:
        bg = Colors.transparent;
        fg = AppSemantics.danger;
        border = AppSemantics.danger;
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
        const Icon(Icons.warning_amber_rounded, size: 14, color: AppSemantics.warn),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 10.5,
              height: 1.6,
              color: AppSemantics.warn,
            ),
          ),
        ),
      ],
    );
  }
}
