/// OpenSmartBatt — the ONE place a screen asks "what are this unit's warning
/// thresholds?" (design 0080 §3.8 / §7, P2).
///
/// ## Why this file exists at all
///
/// `resolveThresholds()` is pure and takes six loose arguments. Four of them —
/// the owner's three numbers, the live `0x2B`, the declaration, and the class —
/// live in four different controllers, and gathering them is the part that goes
/// wrong. Design 0079 §0.3 already logged the exact mistake once: the history
/// list took its thresholds from **whoever is connected** rather than from
/// **whoever this page is about**, so unit A's stored rows were judged against
/// unit B's limits. Design 0080 §3.9 makes "keyed on `deviceId`, never on the
/// link" a rule; this function is what makes obeying it the default, because
/// there is nothing to pass except the id.
///
/// 🔴 **`resolveThresholds()` is the app's only threshold source (§3.8).** The
/// advisory line, the history row colouring and (in P3) the evaluator all come
/// through here. Nothing anywhere else may compare a reading against
/// `TelemetrySample.warnOv` directly.
/// 🔵 **2026-08-25 (FB-100): the reason changed, the rule did not.** ~~that is
/// layer ② alone, so a screen doing it would ignore the user's own value~~ —
/// there is no user value to ignore any more. What a direct read still skips is
/// the power bank's voltage suppression, the unrecognised-class gate and the
/// category fallback, any one of which is enough to make the screen and the
/// notification disagree about the same unit. Same logged failure, fewer ways
/// in.
///
/// ## Why the `0x2B` is re-read every time and never cached
///
/// It is not persisted anywhere — neither `saved_devices` nor `device_facts`
/// has a column for it (design 0080 §7.5.2, verified 2026-08-22). So layer ②
/// exists only while a link is up, and the honest consequence is that an OFFLINE
/// saved unit cannot show a 「裝置回報」 badge. That gap is stated on screen
/// rather than papered over: caching the last-seen triple against the device id
/// would make a stale number look like a live fact, and `0x2B` is exactly the
/// kind of value a firmware change moves.
///
/// Re-resolving costs nothing worth measuring — it is a handful of null checks
/// over values already in memory, with no IO — which is why §7.5.2 replaced the
/// design's original "resolve once at `ready`" with "resolve at the point of
/// use". At `ready` there is no sample yet, so that version would have answered
/// from the category table and then silently changed its mind seconds later.
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/state.dart';
import 'export_scope.dart' show deviceClassFor;

/// Resolve [deviceId]'s three thresholds from plain controller values.
///
/// Takes controllers rather than a [BuildContext] for [deviceClassFor]'s reason
/// — it must be callable after an await, when the screen may be gone — and so
/// that a test can state each layer directly instead of assembling a widget
/// tree.
///
/// [liveSample] / [liveDeviceId] are a pair and must travel together. The sample
/// is dropped when the two ids POSITIVELY DISAGREE — page on unit A, session on
/// unit B — which is design 0079 §0.3's defect and the only case that can be
/// detected. Both "cannot tell" cases let it through, deliberately and by
/// precedent: `TelemetryController._sampleIsFromCurrentSession` documents the
/// same two escapes (G2 "the sample carries no id", G3 "no session is open") for
/// the same reason, that refusing on an absence files nothing more correctly and
/// costs a real screen its readings.
///
///   * [liveDeviceId] null ⇒ no session is being recorded, so there is nobody
///     the sample could belong to instead. On a real disconnect the controller
///     has already emptied it, so this is a test-double shape more than a live
///     one.
///   * [deviceId] null ⇒ the caller named no unit, so no unit is being
///     misattributed to. Passing an id is how a caller opts into the check, and
///     every screen does.
///
/// A null [deviceId] — or one with no saved record — is not an error: it is the
/// UNSAVED unit design 0055 made ordinary. Layer ① and the declaration both live
/// in `saved_devices`, so both are simply absent, and the unit resolves from its
/// own `0x2B` exactly as it does today (§3.6.3).
AlertThresholds alertThresholdsFor(
  DeviceController devices,
  String? deviceId, {
  DeviceFactsController? facts,
  TelemetrySample? liveSample,
  String? liveDeviceId,
  ProductClass liveClass = ProductClass.unknown,
}) {
  final saved = deviceId == null ? null : devices.deviceFor(deviceId);
  // 🔴 The gate. See the doc above — this is the whole of design 0079 §0.3, and
  // it refuses only when the two ids positively disagree.
  final mine =
      deviceId == null || liveDeviceId == null || deviceId == liveDeviceId;
  return resolveThresholds(
    // 🔵 2026-08-25 (FB-100) — ~~userOv: saved?.alertOv,~~ and its two
    // neighbours went with layer ①. `saved` is still read below for the
    // declaration, so the record is not suddenly unused here.
    reported: mine ? liveSample : null,
    // Tie-breaker only, and only for a `0x02` battery — see
    // `categoryDefaultsFor`. Reading it for anything else would put a
    // dropdown in charge of whether an alarm exists, which design 0066 forbids.
    category: saved?.declared.category,
    // What the WIRE said, with the persisted class standing in only where no
    // live byte has arrived (§7.5.7). `deviceClassFor` already ranks stored >
    // cached facts > live-for-this-unit, and `resolveThresholds` overrules it
    // outright when the live byte is present and unrecognised.
    wireClass: deviceClassFor(
      devices,
      deviceId,
      facts: facts,
      liveDeviceId: liveDeviceId,
      liveClass: liveClass,
    ),
  );
}

/// The class `resolveThresholds` WOULD HAVE USED for [deviceId] — the answer to
/// "which rows does this unit's alert screen have at all".
///
/// 🔴 **This mirrors the two lines at the top of [resolveThresholds] and must
/// keep mirroring them.** `alert_thresholds_lookup_test.dart` asserts the two
/// agree on every combination, in the same spirit as the schema-parity test:
/// two independent statements of one rule that no compiler relates to each
/// other need a test that does.
///
/// Why the screen cannot get this out of [AlertThresholds] instead: three empty
/// fields is not evidence of a class. A power bank's OV/UV are empty because
/// they are SUPPRESSED (§3.2.2 — the rows must not be drawn at all, "不是顯示成
/// 灰色停用"), while a battery with no `0x2B` and no declaration has empty
/// fields it would very much like the user to fill in. Deriving the class from
/// the emptiness would put those two on the same screen.
///
/// 📌 [ProductClass.unknown] out of here means one of the two things
/// [AlertsDisabledReason] separates, and the caller must read the reason off
/// the [AlertThresholds] to tell which — this function deliberately does not
/// try, because collapsing "pending" and "unrecognised" into one enum value is
/// what §7.5.6 C-3 forbids showing on screen.
ProductClass alertWireClassFor(
  DeviceController devices,
  String? deviceId, {
  DeviceFactsController? facts,
  TelemetrySample? liveSample,
  String? liveDeviceId,
  ProductClass liveClass = ProductClass.unknown,
}) {
  final mine =
      deviceId == null || liveDeviceId == null || deviceId == liveDeviceId;
  final liveByte = mine ? liveSample?.deviceType : null;
  // §7.5.7: an unrecognised byte is EVIDENCE and overrules the record; an absent
  // byte is no evidence and lets the record stand in.
  if (liveByte != null) return ProductClass.fromDeviceType(liveByte);
  return deviceClassFor(
    devices,
    deviceId,
    facts: facts,
    liveDeviceId: liveDeviceId,
    liveClass: liveClass,
  );
}

/// [alertWireClassFor] wired to the providers. Same watches, same reasons, as
/// [watchAlertThresholds] — a screen calls both and gets one consistent answer
/// because both read the same frame's values.
ProductClass watchAlertWireClass(BuildContext context, String? deviceId) {
  final tele = context.watch<TelemetryController>();
  final conn = context.watch<ConnectionController>();
  return alertWireClassFor(
    context.watch<DeviceController>(),
    deviceId,
    facts: context.watch<DeviceFactsController?>(),
    liveSample: tele.sample,
    liveDeviceId: tele.recordingDeviceId,
    liveClass: conn.resolvedClass,
  );
}

/// Does this class get the two VOLTAGE rows at all (design 0080 §3.2.2, Q1)?
///
/// Reads the published constant rather than restating the rule, so the
/// suppression has one home: `kPowerBankWatchesTemperatureOnly`'s doc is where
/// the three reasons live, and it is also the flag a future ruling would flip.
bool alertVoltageWatched(ProductClass wireClass) =>
    !(kPowerBankWatchesTemperatureOnly && wireClass == ProductClass.powerBank);

/// [alertThresholdsFor] wired to the providers, for widgets.
///
/// Watches, rather than reads, the two controllers whose changes must redraw a
/// threshold: the telemetry sample (a `0x2B` arriving flips a row from 「App
/// 預設」 to 「裝置回報」) and the saved record (the user typing a value).
///
/// 🔑 The live id is [TelemetryController.recordingDeviceId] — the SESSION's
/// unit — not `ConnectionController.connectedDeviceId`. The two differ in the
/// window that matters: `connectedDeviceId` falls back to the DESIRED id, so it
/// names a unit while a connect is still in flight and the sample on hand is
/// still the previous unit's. The session id is null the moment the link drops
/// and is set only once a unit is genuinely being recorded, which is the same
/// pairing `history_csv_export.dart` and `device_history_tab.dart` already use.
///
/// ⚠️ Callers already inside a `watch<TelemetryController>()` — the three
/// protection bodies — pay nothing extra for this; provider deduplicates the
/// dependency.
AlertThresholds watchAlertThresholds(BuildContext context, String? deviceId) {
  final tele = context.watch<TelemetryController>();
  final conn = context.watch<ConnectionController>();
  return alertThresholdsFor(
    context.watch<DeviceController>(),
    deviceId,
    facts: context.watch<DeviceFactsController?>(),
    liveSample: tele.sample,
    liveDeviceId: tele.recordingDeviceId,
    liveClass: conn.resolvedClass,
  );
}
