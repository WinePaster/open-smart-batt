/// OpenSmartBatt — where design 0080's state machine is finally CALLED
/// (P3: §3.3, §3.4, §3.6.3, §5).
///
/// P1 built [AlertEvaluator] with no caller. P2 built the thresholds, the
/// screens and the columns, still with no caller. This file is the caller, and
/// it exists as its own object rather than as a handful of fields on
/// [TelemetryController] for one reason worth stating: **the layer boundary in
/// §0.2.1 is the whole feature.** Evaluating and notifying are two steps with a
/// gate between them, and the gate has to be visible in one place or it grows a
/// second version.
///
/// ```
///   frame ──▶ resolve thresholds ──▶ evaluator.fold ──┬──▶ events  (screen: ALWAYS)
///                                                     └──▶ notifier.post (gated)
/// ```
///
/// ## 🔴 The gate is on the OUTPUT and must stay there
///
/// Ruling Q3 (§0.2.1, §3.6.3): an unsaved unit is evaluated, its advisory line
/// still shows, its event banner still shows — only the notification is
/// withheld, because an unsaved unit has no alias to title one with and nowhere
/// to keep a mute. Moving the gate one step earlier ("unsaved ⇒ do not even
/// evaluate") is cheaper, passes most tests, and is a REGRESSION: it would take
/// away a warning the app has shown since long before design 0080. The design
/// calls that out explicitly, twice, which is usually a sign somebody nearly
/// did it.
///
/// ## What this class owns, and what it deliberately does not
///
/// * **Owns** the evaluator, the per-unit open events (for the banner), the
///   session mutes, the permission status, and the formatting of a notification.
/// * **Does not own** thresholds — they arrive through [AlertThresholdResolver],
///   a closure supplied by the composition root, so `resolveThresholds()` stays
///   the app's single threshold source (§3.8) without this file importing the
///   UI layer where the gathering lives.
/// * **Does not own** the mute instant or the per-device switch: those are
///   `saved_devices` columns and are read through [DeviceController] on each
///   fold. One piece of state, one home — the failure this repo has three
///   logged incidents of.
///
/// ## Why nothing here has a Timer
///
/// Same contract as [AlertEvaluator]: time advances only when a frame arrives.
/// A repeat notification fired by a timer while the link was silent would be a
/// statement about a unit we can no longer hear, which is the dishonesty
/// §3.3.2 forbids on the disconnect path. When the frames stop, the alerts
/// stop.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../platform/alert_notifier.dart';
import 'alert_evaluator.dart';
import 'device_controller.dart';
import 'settings_controller.dart';
import 'telemetry_controller.dart' show TelemetryAlertSink;

export '../platform/alert_notifier.dart'
    show AlertNotifier, AlertNotification, AlertPermission, NoopAlertNotifier;

/// Resolve one unit's three thresholds, given the frame just decoded for it.
///
/// A closure rather than a dependency because the gathering — the owner's
/// numbers, the live `0x2B`, the declaration, the wire class — is spread over
/// four controllers and is already assembled in exactly one place
/// (`alertThresholdsFor`, `ui/util/alert_thresholds_lookup.dart`). Passing that
/// function in keeps §3.8's "one threshold source" intact while leaving
/// `lib/state` free of an import pointing at `lib/ui`.
typedef AlertThresholdResolver = AlertThresholds Function(
  String deviceId,
  TelemetrySample sample,
);

/// Everything a notification needs to say, in the user's chosen language.
///
/// 🔴 **Handed in from a widget, never read here** (§5.2). Notifications are
/// posted from the telemetry path, which has no `BuildContext`; and the app's
/// in-app language override is independent of the device locale, so pulling
/// text from platform resources would show the wrong language to precisely the
/// user who changed it. `MonitorNotification` / `setNotificationStrings` already
/// established this shape for the foreground service, and this is the same move.
///
/// The two body fields are FUNCTIONS because the numbers are not known when the
/// locale resolves — the generated `AppLocalizations` method is captured in a
/// closure and called later with the reading of the moment.
class AlertNotificationStrings {
  const AlertNotificationStrings({
    required this.channelName,
    required this.channelDescription,
    required this.overVoltage,
    required this.underVoltage,
    required this.overTemperature,
    required this.title,
    required this.bodyVolts,
    required this.bodyCelsius,
  });

  /// Neutral placeholders, used until the first frame resolves l10n.
  ///
  /// 🔑 Not English copy, and not empty: `ConnectionController` seeds its own
  /// notification title with the bare brand name for the same reason. A
  /// notification that slipped out in this window would be terse rather than
  /// in a language the user did not pick — and in practice the window is closed
  /// before any link exists, since `didChangeDependencies` runs on the first
  /// frame and a breach needs a connection plus `sustain` seconds.
  static AlertNotificationStrings get placeholder => AlertNotificationStrings(
        channelName: 'OpenSmartBatt',
        channelDescription: 'OpenSmartBatt',
        overVoltage: 'OV',
        underVoltage: 'UV',
        overTemperature: 'OT',
        title: (alias, kind) => '$alias · $kind',
        bodyVolts: (reading, threshold, time) =>
            '$reading V / $threshold V · $time',
        bodyCelsius: (reading, threshold, time) =>
            '$reading °C / $threshold °C · $time',
      );

  /// Android channel name + description, shown in the OS's own settings.
  final String channelName;
  final String channelDescription;

  /// The three kind names, as they appear after the alias in a title.
  final String overVoltage;
  final String underVoltage;
  final String overTemperature;

  /// `(alias, kindLabel) => '阿福的機車 · 電壓過低'`.
  final String Function(String alias, String kind) title;

  /// `(reading, threshold, time) => '目前 10.82 V，門檻 11.00 V · 14:32'`.
  final String Function(String reading, String threshold, String time)
      bodyVolts;

  /// The same, in degrees.
  final String Function(String reading, String threshold, String time)
      bodyCelsius;

  String labelFor(AlertKind kind) => switch (kind) {
        AlertKind.overVoltage => overVoltage,
        AlertKind.underVoltage => underVoltage,
        AlertKind.overTemperature => overTemperature,
      };
}

/// One warning that is currently RAISED on one unit — what the detail page's
/// event banner draws (§5, P3: "詳情頁事件橫幅").
///
/// 🔑 It carries [since] and the threshold, and NOT the live reading. The
/// reading is on [TelemetryController], which the banner is watching anyway;
/// duplicating it here would make this object change five times a second and
/// notify every listener at that rate for a number they already have.
@immutable
class AlertEvent {
  const AlertEvent({
    required this.kind,
    required this.since,
    required this.threshold,
    required this.source,
  });

  final AlertKind kind;

  /// When this event was RAISED — the instant the first notification was
  /// decided, not the instant the reading first crossed the line.
  ///
  /// The difference is `sustain`, and it is the honest one to show: the banner
  /// says "this has been true long enough for us to believe it", and dating it
  /// from the first stray sample would put the debounce on screen and undo it
  /// (same argument as `activeAlerts` excluding `pending`).
  final DateTime since;

  /// The limit that was crossed, and where the number came from.
  final double threshold;
  final ThresholdSource source;

  /// How long this has been raised, against the wall clock.
  Duration ageAt(DateTime now) => now.difference(since);

  @override
  bool operator ==(Object other) =>
      other is AlertEvent &&
      other.kind == kind &&
      other.since == since &&
      other.threshold == threshold &&
      other.source == source;

  @override
  int get hashCode => Object.hash(kind, since, threshold, source);
}

/// Drives [AlertEvaluator] off the telemetry stream and turns what it says into
/// notifications (design 0080 P3).
class AlertController extends ChangeNotifier implements TelemetryAlertSink {
  AlertController({
    required AlertThresholdResolver resolve,
    required DeviceController devices,
    required SettingsController settings,
    AlertNotifier? notifier,
    AlertEvaluator? evaluator,
  }) {
    // Assigned in the body rather than in an initializer list, matching
    // [TelemetryController]: the fields are private, Dart has no private named
    // formal, and the two optional dependencies have to be defaulted here
    // anyway.
    _resolve = resolve;
    _devices = devices;
    _settings = settings;
    _notifier = notifier ?? NoopAlertNotifier();
    _evaluator = evaluator ?? AlertEvaluator();
    _applySettings();
    _settings.addListener(_applySettings);
    _tapSub = _notifier.onTapped.listen(_tapped.add);
  }

  late final AlertThresholdResolver _resolve;
  late final DeviceController _devices;
  late final SettingsController _settings;
  late final AlertNotifier _notifier;
  late final AlertEvaluator _evaluator;

  StreamSubscription<String>? _tapSub;
  final _tapped = StreamController<String>.broadcast();

  /// Raised warnings by unit, then by kind. Empty for a unit with nothing wrong.
  final Map<String, Map<AlertKind, AlertEvent>> _events =
      <String, Map<AlertKind, AlertEvent>>{};

  /// Gate ③ — 「本次連線不再提醒」 (§3.4).
  ///
  /// 🔴 **In memory, and HERE rather than on a widget.** P2 had to park it on
  /// `_AlertSettingsPageState` because nothing else observed the connection, and
  /// recorded the consequence in §7.6.4: it died when the user left the page,
  /// which is not what the words say. It dies with the LINK now — [onLinkLost]
  /// is the only thing that clears it.
  ///
  /// ⚠️ The asymmetry with the 1-hour mute (which IS persisted) is deliberate
  /// and is spelled out in §3.4: "for an hour" is a promise about wall-clock
  /// time and must survive a restart; "not again this connection" is a promise
  /// about a link and ends when the link does. Writing this one to the database
  /// is the single change that would make it wrong rather than merely
  /// short-lived.
  final Set<String> _sessionSilenced = <String>{};

  /// Which alert kinds were on screen when the user collapsed the detail-page
  /// banner, per device — design 0086 Q2/Q3.
  ///
  /// 🔴 **Memory only, and cleared with the link, for the same reason as
  /// [_sessionSilenced] above.** The owner's ruling was 「只有這次連線有效」;
  /// writing this to the database is the single change that would make it
  /// wrong, exactly as for the session silence.
  ///
  /// 🔑 **A set of kinds, not a bool, and that is the whole of Q3.** Collapsing
  /// says "I have read THIS one" — it is not a mute. So the banner reopens the
  /// moment a kind appears that was not in the set at collapse time, and does
  /// NOT reopen when one merely clears (that is the warning going away, not new
  /// information). [isBannerCollapsed] is where those two rules live.
  ///
  /// ⚠️ Not to be confused with [_sessionSilenced], which is the user asking
  /// for no more *notifications*. This one is only about how much room the
  /// banner takes on screen; the warning itself never stops being displayed.
  final Map<String, Set<AlertKind>> _bannerCollapsed = <String, Set<AlertKind>>{};

  AlertNotificationStrings _strings = AlertNotificationStrings.placeholder;

  AlertPermission _permission = AlertPermission.unknown;

  /// System notification permission as last observed.
  ///
  /// Starts [AlertPermission.unknown] and stays there until the feature is
  /// switched on — see that enum for why reading it early would show every new
  /// iOS user a red "denied" for a prompt they have never seen (§7.6.2 c).
  AlertPermission get permission => _permission;

  /// True when the feature is on but the OS will not deliver.
  ///
  /// 🔴 The condition §6.2 forbids failing silently at. Design 0008 §3.4 is the
  /// precedent it names: there, a denied `POST_NOTIFICATIONS` left the
  /// foreground service running and merely hid its notification, and what the
  /// user experienced was "I turned it on and nothing arrives".
  bool get permissionBlocked =>
      _settings.settings.alertsEnabled &&
      (_permission == AlertPermission.denied ||
          _permission == AlertPermission.permanentlyDenied);

  /// Device ids of notifications the user tapped. The composition root listens
  /// and opens that unit's alert settings page (§3.4.1).
  Stream<String> get onNotificationTapped => _tapped.stream;

  /// The evaluator, for tests and for anything that needs a phase directly.
  @visibleForTesting
  AlertEvaluator get evaluator => _evaluator;

  // ---- reading state ------------------------------------------------------

  /// Warnings currently raised on [deviceId], ordered as [AlertKind] is.
  ///
  /// Empty for a healthy unit, for an unknown one, and for one that is merely
  /// `pending` — a breach we have not yet decided to believe.
  List<AlertEvent> eventsFor(String? deviceId) {
    final map = deviceId == null ? null : _events[deviceId];
    if (map == null || map.isEmpty) return const <AlertEvent>[];
    return <AlertEvent>[
      for (final kind in AlertKind.values)
        if (map[kind] case final AlertEvent e) e,
    ];
  }

  /// Whether 「本次連線不再提醒」 is on for [deviceId].
  bool isSessionSilenced(String deviceId) =>
      _sessionSilenced.contains(deviceId);

  /// Set 「本次連線不再提醒」. Memory only, by contract — see [_sessionSilenced].
  void setSessionSilenced(String deviceId, bool value) {
    final changed =
        value ? _sessionSilenced.add(deviceId) : _sessionSilenced.remove(deviceId);
    if (changed) notifyListeners();
  }

  /// Whether the detail-page banner for [deviceId] is collapsed right now
  /// (design 0086).
  ///
  /// False as soon as anything is raised that was not raised when the user
  /// collapsed — see [_bannerCollapsed] for why that is the rule and not a
  /// plain flag.
  bool isBannerCollapsed(String deviceId) {
    final at = _bannerCollapsed[deviceId];
    if (at == null) return false;
    // Superset check, deliberately one-directional: something NEW reopens the
    // banner; something clearing does not.
    return eventsFor(deviceId).every((e) => at.contains(e.kind));
  }

  /// Collapse or expand the detail-page banner for [deviceId] (design 0086).
  ///
  /// Collapsing snapshots what is raised at that moment, which is what makes
  /// [isBannerCollapsed] able to tell "the same warning" from "a new one".
  void setBannerCollapsed(String deviceId, bool value) {
    if (value) {
      _bannerCollapsed[deviceId] =
          eventsFor(deviceId).map((e) => e.kind).toSet();
    } else if (_bannerCollapsed.remove(deviceId) == null) {
      return;
    }
    notifyListeners();
  }

  // ---- the telemetry path -------------------------------------------------

  /// Fold one decoded frame for [deviceId] (design 0080 §3.3).
  ///
  /// Called from `TelemetryController._onTelemetry`, AFTER design 0078's
  /// session-attribution guard has already run — this method deliberately does
  /// not repeat that check. Two gates against the same defect is how one of
  /// them ends up being the wrong one.
  ///
  /// A null [deviceId] is dropped: with no unit to key on there is nothing to
  /// resolve thresholds for and nothing to title a notification with. That is
  /// the same position `_maybeAutoLog` takes for a history row (design 0043
  /// §3.1) and, like that one, it is a guard against the future — today the
  /// session always has a unit by the time telemetry flows.
  @override
  void onSample(String? deviceId, TelemetrySample sample) {
    if (deviceId == null) return;
    // Resolved on EVERY frame, not cached (§7.5.2). It is a handful of null
    // checks over values already in memory with no IO, and the alternative —
    // resolving once at `ready` — answers before the `0x2B` has arrived and
    // then silently changes its mind.
    final thresholds = _resolve(deviceId, sample);
    final emissions = _evaluator.fold(
      deviceId: deviceId,
      sample: sample,
      thresholds: thresholds,
      gate: _gateFor(deviceId),
    );
    for (final e in emissions) {
      // 🔴 THE gate, and the only one. `shouldNotify` is P1's own answer to
      // "may this be delivered"; re-deriving it here would be a second copy of
      // §3.6.3's rule with nothing keeping the two in step.
      if (e.shouldNotify) unawaited(_post(deviceId, e));
    }
    _syncEvents(deviceId, thresholds);
  }

  /// The link dropped — forget everything about every unit (§3.3.2).
  ///
  /// 🔴 **No "all clear" notification is sent, and that is the specification.**
  /// We did not watch the reading come back; we stopped watching. Telling a
  /// user "voltage back to normal" about a unit we have been off the link with
  /// for ten minutes is a lie about the one thing they were watching, and it is
  /// design 0038's honesty rule in a single sentence: never emit something that
  /// implies data we do not have.
  ///
  /// ⚠️ Notifications ALREADY posted are left alone. They are a record of
  /// something that was true when it was written, not a live readout — unlike
  /// the foreground service's ongoing row, which design 0038 §1.2 dismisses on
  /// disconnect precisely because it claims to be live. Withdrawing them would
  /// erase the evidence of the alert from a phone whose owner has not looked at
  /// it yet, which is the one outcome that makes the whole feature pointless.
  @override
  void onLinkLost() {
    _evaluator.clearAll();
    // The per-event budget goes with it: a unit that reconnects still breaching
    // opens a NEW event with its full three notifications, rather than being
    // silenced on the strength of ones sent about a different connection.
    final had = _events.isNotEmpty ||
        _sessionSilenced.isNotEmpty ||
        _bannerCollapsed.isNotEmpty;
    _events.clear();
    _sessionSilenced.clear();
    // design 0086 Q2: collapsing the banner is a promise about THIS link, so it
    // ends where the link does — same contract, same clearing point.
    _bannerCollapsed.clear();
    if (had) notifyListeners();
  }

  // ---- permission ---------------------------------------------------------

  /// Ask for the permission (the first-enable flow, §3.7.3) and record the
  /// answer. Returns true when notifications will actually be delivered.
  Future<bool> requestPermission() async {
    _setPermission(await _notifier.ensurePermission());
    return _permission == AlertPermission.granted;
  }

  /// Re-read the permission without prompting.
  ///
  /// Safe to call from a screen only once the feature has been enabled —
  /// [AlertPermission.unknown]'s doc says why, and this method deliberately
  /// does not enforce it: the rule belongs to the screen that decides WHEN to
  /// ask, and a silent refusal here would be indistinguishable from a grant.
  Future<void> refreshPermission() async =>
      _setPermission(await _notifier.permissionStatus());

  /// Open the OS's app settings, so a refused permission has a way back
  /// (§6.2, 「一鍵跳系統設定」).
  Future<bool> openSystemSettings() => _notifier.openSystemSettings();

  /// The unit a notification-launched cold start is about, or null.
  Future<String?> takeLaunchPayload() => _notifier.takeLaunchPayload();

  /// Hand over the localized notification text; see [AlertNotificationStrings].
  void setNotificationStrings(AlertNotificationStrings strings) =>
      _strings = strings;

  // ---- internals ----------------------------------------------------------

  /// The four suppression questions of §3.6.3, answered from the two places
  /// that own them: `settings` for the global switch, `saved_devices` for the
  /// rest, and this object for the session mute.
  AlertGate _gateFor(String deviceId) {
    final saved = _devices.deviceFor(deviceId);
    return AlertGate(
      alertsEnabled: _settings.settings.alertsEnabled,
      deviceSaved: saved != null,
      deviceAlertsEnabled: saved?.alertEnabled ?? true,
      mutedUntil: saved?.alertMutedUntil,
      silencedForSession: _sessionSilenced.contains(deviceId),
    );
  }

  Future<void> _post(String deviceId, AlertEmission e) async {
    final saved = _devices.deviceFor(deviceId);
    // `deviceSaved` is part of the gate, so a suppressed emission never reaches
    // here without one — but the record can be deleted between the fold and
    // this await, and a title reading "null · 電壓過低" is not a thing to ship.
    final alias = saved?.alias;
    if (alias == null || alias.isEmpty) return;
    final volts = e.kind.isVoltage;
    final reading = volts ? formatVolts(e.reading) : formatCelsius(e.reading);
    final threshold =
        volts ? formatVolts(e.threshold) : formatCelsius(e.threshold);
    final time = _clockTime(e.at);
    await _notifier.post(AlertNotification(
      // 🔑 Per (unit, kind), so the repeat at 15 minutes UPDATES the row on the
      // shade instead of stacking a second one (§3.5.3).
      id: alertNotificationId(deviceId, e.kind),
      title: _strings.title(alias, _strings.labelFor(e.kind)),
      body: volts
          ? _strings.bodyVolts(reading, threshold, time)
          : _strings.bodyCelsius(reading, threshold, time),
      payload: deviceId,
      channelName: _strings.channelName,
      channelDescription: _strings.channelDescription,
    ));
  }

  /// Bring [_events] into line with what the evaluator now says is raised.
  ///
  /// Notifies only when the SET or the thresholds behind it move. This runs on
  /// every frame — several times a second — and a `notifyListeners()` per frame
  /// would rebuild every watcher of this controller at telemetry rate for a
  /// value that changes once an hour.
  void _syncEvents(String deviceId, AlertThresholds thresholds) {
    final active = _evaluator.activeAlerts(deviceId);
    final previous = _events[deviceId];
    if (active.isEmpty) {
      if (previous == null) return;
      _events.remove(deviceId);
      notifyListeners();
      return;
    }
    final now = clock.now();
    final next = <AlertKind, AlertEvent>{};
    for (final kind in active) {
      final was = previous?[kind];
      // The limit is re-read each time so an event opened against the device's
      // own `0x2B` follows the user editing that field mid-event — §7.5.5's
      // "the new value applies from the next fold", carried through to what the
      // banner prints. A field whose threshold vanished under an open event
      // keeps the one it was raised against rather than losing its row.
      final resolved = thresholds[kind];
      final limit = resolved.value ?? was?.threshold;
      if (limit == null) continue;
      next[kind] = AlertEvent(
        kind: kind,
        // 🔑 `was?.since` first: the clock is read once when the event opens
        // and never again, so the banner's "for 12 minutes" counts from the
        // alert, not from the last frame.
        since: was?.since ?? now,
        threshold: limit,
        source: resolved.isSet ? resolved.source : (was?.source ?? resolved.source),
      );
    }
    if (_mapEquals(previous, next)) return;
    _events[deviceId] = next;
    notifyListeners();
  }

  static bool _mapEquals(
    Map<AlertKind, AlertEvent>? a,
    Map<AlertKind, AlertEvent> b,
  ) {
    if (a == null) return b.isEmpty;
    if (a.length != b.length) return false;
    for (final entry in b.entries) {
      if (a[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _setPermission(AlertPermission next) {
    if (next == _permission) return;
    _permission = next;
    notifyListeners();
  }

  /// The three tunables the user can move (§3.6). Hysteresis is not among them
  /// — see [AlertEvaluatorConfig.voltageHysteresis] for why it is config-only.
  void _applySettings() {
    final s = _settings.settings;
    final next = AlertEvaluatorConfig(
      sustain: Duration(seconds: s.alertSustainSec),
      repeatInterval: Duration(minutes: s.alertRepeatMin),
      maxPerEvent: s.alertMaxPerEvent,
    );
    _evaluator.config = next;
  }

  /// `14:32` — 24-hour, zero-padded, no locale.
  ///
  /// 🔑 Deliberately NOT `intl`'s `DateFormat.Hm()`. That would need a locale,
  /// and this string is built where there is no `BuildContext` to get one from;
  /// picking the DEVICE locale here would contradict the whole reason the rest
  /// of the text is passed in (§5.2). A zero-padded 24-hour clock is the one
  /// rendering that is unambiguous in every locale this app ships.
  static String _clockTime(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _settings.removeListener(_applySettings);
    unawaited(_tapSub?.cancel());
    _tapped.close();
    _notifier.dispose();
    super.dispose();
  }
}
