/// OpenSmartBatt — "is anyone actually watching this unit right now?"
/// (design 0091, FB-105 Q1).
///
/// ## Why this exists
///
/// The badge on the alerts entry row used to read exactly two columns of
/// `saved_devices` — `alert_enabled` and the mute instant — and print a green
/// 「已開啟」 whenever the first was 1. That sentence is true about a database
/// row and says nothing about the phone in the user's hand: it stayed green
/// with no link, with a stalled link, with the notification permission refused,
/// and — worst of the four — **with the global switch off**, which is the
/// state every user starts in (design 0080 ruling Q4 ships it OFF).
///
/// FB-105 arrived as a copy complaint. It was not one: the app had a paragraph
/// explaining that detection might stop, and no way to say that it HAD. The
/// paragraph is gone (`5ee52af`); this is the thing it was standing in for.
///
/// ## The order is `AlertSuppression`'s, deliberately
///
/// [AlertSuppression.evaluate] already ranks "why nothing will happen" from
/// broadest to narrowest, and its own doc comment says why: the reason shown
/// should be the one that explains the most and is furthest from where the user
/// is standing — being told "this device is muted" while the global switch is
/// off sends them to fix the wrong screen. 🔴 This ladder MUST stay in that
/// order; a second ranking of the same reasons is exactly the "two places to
/// look" failure this repo keeps logging.
///
/// One rung is added at the bottom that `AlertSuppression` cannot have: it is
/// only ever consulted when a frame arrives, so it has no opinion about a link
/// that is silent or absent. That rung is [AlertWatchState.notWatching].
library;

import '../../models/models.dart';

/// What the alerts badge says, worst-explaining-cause first.
enum AlertWatchState {
  /// The global switch is off — nothing is evaluated for notification on any
  /// unit. Fixed on the Settings screen, not here.
  globallyDisabled,

  /// This unit's own switch is off.
  deviceDisabled,

  /// "Mute for 1 hour" is still running.
  muted,

  /// Everything is enabled and we still cannot see anything: not connected to
  /// this unit, or connected with no frames arriving.
  ///
  /// 🔑 This is the state the old badge could not express, and the reason the
  /// feature needed a design doc rather than a string change.
  notWatching,

  /// Enabled, connected, frames arriving. The only state in which a breach
  /// would actually be noticed.
  watching,
}

/// Decide the badge state for one unit.
///
/// Pure, and takes every input explicitly, because the four sources live on
/// four different controllers and the alternative — reaching into them from the
/// widget — would make the ladder untestable without a full widget pump.
///
/// ⚠️ [hasTelemetry] is tested BEFORE [telemetryStalled], the same order
/// `ConnectionController._stateTitle` documents: `lastSampleAt` is seeded at
/// `ready`, so a link that never said a word also goes stalled after the
/// threshold. Here both answers happen to be [AlertWatchState.notWatching], but
/// the order is kept so this file cannot drift from the one that matters.
AlertWatchState alertWatchStateFor({
  required bool alertsEnabled,
  required SavedDevice saved,
  required String deviceId,
  required String? connectedDeviceId,
  required bool hasTelemetry,
  required bool telemetryStalled,
  required DateTime now,
}) {
  if (!alertsEnabled) return AlertWatchState.globallyDisabled;
  if (!saved.alertEnabled) return AlertWatchState.deviceDisabled;
  if (saved.isMutedAt(now)) return AlertWatchState.muted;
  if (connectedDeviceId != deviceId) return AlertWatchState.notWatching;
  if (!hasTelemetry) return AlertWatchState.notWatching;
  if (telemetryStalled) return AlertWatchState.notWatching;
  return AlertWatchState.watching;
}
