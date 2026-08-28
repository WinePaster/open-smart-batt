/// OpenSmartBatt — the alert state machine (design 0080 §3.3 / §3.4 / §3.6.3).
///
/// PURE Dart apart from `package:clock`. No `ChangeNotifier`, no repository, no
/// notification plugin, no `Timer` — this file is the reason design 0080 §5
/// puts P1 first and alone: **the state machine is the only part of the feature
/// that has logic in it, and everything after P1 is wiring.** Keeping it free
/// of platform lets the whole of §5.1's test plan run in milliseconds, and lets
/// a fix to a transition be verified without a phone, a battery, or a database.
///
/// ## Not a `Timer`, on purpose
///
/// Nothing in here schedules anything. Time only moves when [AlertEvaluator.fold]
/// is called, i.e. when a telemetry frame arrives. That is a deliberate
/// property, not a shortcut: a repeat notification fired by a timer while the
/// link is silent would be a claim about a unit we are no longer hearing from,
/// which is the exact dishonesty §3.3.2 forbids on the disconnect path. If the
/// frames stop, the alerts stop, and that is the truthful outcome.
///
/// ## 🔴 The clock is `clock.now()`, and neither of the two obvious alternatives
///
/// **Not `DateTime.now()`**: `fake_async` substitutes `package:clock`'s clock
/// and cannot substitute `DateTime.now()`, so a hard-coded `DateTime.now()`
/// would make "4.9 seconds does not fire, 5.0 does" untestable except by
/// actually sleeping. This is the same reason `connection_controller` moved its
/// autoConnect deadline onto `clock.now()` for FB-66.
///
/// **Not `sample.timestamp`**: it is the app clock at assembly time, so it
/// normally agrees — but it comes off a stream that also carries backfilled
/// history, and the corpus contains a real `0x3B` RTC roll-back. A clock that
/// can jump backwards turns "has this been breaching for five seconds" into a
/// negative duration. What this machine measures is **wall-clock persistence**,
/// so it reads the wall clock.
///
/// ## 🔑 Why the debounce is a DURATION and not a frame count
///
/// Ruling C1 asked for "N consecutive readings". That cannot be implemented
/// literally. `TelemetryController._onTelemetry` runs once per DECODED FRAME,
/// and a second on the link carries several frames from several selectors —
/// `0x19` (PVLT), `0x21` (temperature), `0x23` (mode) each arrive as their own
/// frame and each `copyWith`s a fresh [TelemetrySample]. So "5 consecutive
/// samples" is about 5 s on one product family and about 1.5 s on another, and
/// there is no sentence about it that could be shown to a user. Counting
/// seconds decouples the rule from frame rate, from product class and from the
/// keep-alive cadence at once (§3.3.1).
///
/// A corollary worth stating because it looks like a bug from the outside: a
/// field that is absent from a given frame (a `0x21` frame carries no PVLT)
/// leaves its state machine **untouched**, neither advancing nor clearing it.
/// Treating "this frame did not mention PVLT" as "PVLT is fine now" would let
/// any interleaved selector reset a real breach.
///
/// ## Where the gate is — and is not
///
/// [fold] evaluates **every** unit that has a usable threshold, saved or not,
/// and always returns what happened. The saved/enabled/muted question is
/// answered afterwards, per emission, by [AlertGate], and it decides one thing
/// only: whether a notification should be posted. Ruling Q3 (§0.2.1) is
/// explicit that the on-screen advisory and the event banner keep working for
/// an unsaved unit; §3.6.3's implementation note is equally explicit that
/// moving the gate earlier — "unsaved ⇒ do not even evaluate" — is a regression
/// and not the ruling. That is why the gate lives on the OUTPUT of this file
/// and not on its input.
library;

import 'package:clock/clock.dart';

import '../models/alert_thresholds.dart';
import '../models/product_class.dart';
import '../models/telemetry_sample.dart';
import '../protocol/selectors.dart';

export '../models/alert_thresholds.dart';

/// Where one (unit, kind) pair currently sits (design 0080 §3.3).
enum AlertPhase {
  /// Reading is inside limits, or has come back inside them past the hysteresis
  /// band. No event is open and the emission counter is zero.
  normal,

  /// Over the line, but not yet for long enough. Nothing has been emitted.
  pending,

  /// The event is open and has emitted at least one, but fewer than
  /// [AlertEvaluatorConfig.maxPerEvent], notifications.
  firing,

  /// Still over the line, but the per-event budget is spent. Emits nothing more
  /// until the reading clears — which is the point: an unattended phone must go
  /// quiet on its own (§3.4 gate ①).
  silent,
}

/// Why an emission must not become a notification (design 0080 §3.6.3).
///
/// An enum rather than a bool because these four are acted on differently
/// later: two of them are the user's own choice and should be reflected back to
/// them on screen, one is a settings state with a one-tap fix, and one is an
/// invitation to save the device. Collapsing them into `false` would throw all
/// of that away at the only point where it is still known.
enum AlertSuppression {
  /// Nothing blocks it — post the notification.
  none,

  /// The global switch is off. Ships off (ruling Q4, §3.7.3).
  globallyDisabled,

  /// This unit is not in `saved_devices` (ruling Q3). It has no alias to put in
  /// the title and nowhere to keep a mute, so it cannot be notified about — but
  /// it was still evaluated, and the screen still shows it.
  unsavedDevice,

  /// This unit's own alert switch is off (`saved_devices.alert_enabled`).
  deviceAlertsDisabled,

  /// "Mute for 1 hour" is still running (§3.4 gate ②). Persisted, so it
  /// survives an app restart — an hour is a promise about TIME.
  muted,

  /// "Don't remind me for this connection" (§3.4 gate ③). Memory only, so it
  /// dies with the link — that is what the words mean.
  silencedForSession,
}

/// The four tunables of §3.3, injectable so tests can state them explicitly.
///
/// The defaults are the design's, and P2 will let the user override the three
/// that are in `settings` (`alert_sustain_sec` / `alert_repeat_min` /
/// `alert_max_per_event`). Hysteresis is deliberately NOT among those columns:
/// it is a property of how noisy the reading is, not a preference, and exposing
/// it would let a user set it to zero and rediscover the chatter it exists to
/// prevent.
class AlertEvaluatorConfig {
  const AlertEvaluatorConfig({
    this.sustain = const Duration(seconds: 5),
    this.voltageHysteresis = 0.3,
    this.temperatureHysteresis = 3,
    this.repeatInterval = const Duration(minutes: 15),
    this.maxPerEvent = 3,
  });

  /// How long a reading must stay over the line before the event opens.
  final Duration sustain;

  /// Volts the reading must come back INSIDE the threshold before the event is
  /// considered cleared. A reading between the threshold and this band is
  /// neither breaching nor cleared — it holds the current phase — which is what
  /// makes a value dithering across its own limit produce one notification
  /// instead of a hundred.
  final double voltageHysteresis;

  /// Degrees Celsius; same rule as [voltageHysteresis].
  final double temperatureHysteresis;

  /// Gap between repeats within one event. The user may not have seen the first.
  final Duration repeatInterval;

  /// Emissions per event, after which the machine goes [AlertPhase.silent]
  /// until the reading clears.
  final int maxPerEvent;

  /// Band for [kind], in that kind's own unit.
  double hysteresisFor(AlertKind kind) =>
      kind.isVoltage ? voltageHysteresis : temperatureHysteresis;
}

/// Everything outside this file that can stop a notification (design 0080 §3.4,
/// §3.6.3). A snapshot, passed in per [AlertEvaluator.fold] call.
///
/// 🔑 The evaluator owns NONE of this. `alert_muted_until` lives in
/// `saved_devices` and the session flag lives wherever the UI keeps it; putting
/// either behind this class's back would give the state machine a persistence
/// dependency and cost P1 its independence — and would put one piece of state
/// in two places, which is the failure mode `discipline.md` records three
/// separate incidents of.
class AlertGate {
  const AlertGate({
    required this.alertsEnabled,
    required this.deviceSaved,
    this.deviceAlertsEnabled = true,
    this.mutedUntil,
    this.silencedForSession = false,
  });

  /// The default [AlertEvaluator.fold] uses when no gate is supplied: evaluate,
  /// deliver nothing.
  ///
  /// 🔑 Chosen to fail SILENT rather than fail LOUD. A caller that forgets to
  /// pass a gate is a caller that has not yet been taught about the global
  /// switch, and ruling Q4 ships that switch off — so "not yet wired" and
  /// "switched off" ought to look the same. The emissions still come back, with
  /// [AlertSuppression.globallyDisabled] on them, so the omission is visible
  /// rather than merely quiet.
  static const AlertGate closed =
      AlertGate(alertsEnabled: false, deviceSaved: false);

  /// The global switch (`settings.alerts_enabled`, default 0 — ruling Q4).
  final bool alertsEnabled;

  /// Whether this unit has a `saved_devices` row (ruling Q3).
  final bool deviceSaved;

  /// This unit's own switch (`saved_devices.alert_enabled`, default 1).
  final bool deviceAlertsEnabled;

  /// End of a "mute for 1 hour", or null. Compared against `clock.now()`; a
  /// stamp in the past is simply expired and needs no cleanup.
  final DateTime? mutedUntil;

  /// "Don't remind me for this connection". Memory-only by contract (§3.4).
  final bool silencedForSession;

  /// First reason this emission is blocked, or [AlertSuppression.none].
  ///
  /// Order is not arbitrary: it runs from the broadest cause to the narrowest,
  /// so the reason surfaced to the user is the one that explains the most and
  /// is furthest from where they are standing. Being told "this device is
  /// muted" while the global switch is off would send them to fix the wrong
  /// screen.
  AlertSuppression evaluate({DateTime? now}) {
    if (!alertsEnabled) return AlertSuppression.globallyDisabled;
    if (!deviceSaved) return AlertSuppression.unsavedDevice;
    if (!deviceAlertsEnabled) return AlertSuppression.deviceAlertsDisabled;
    if (silencedForSession) return AlertSuppression.silencedForSession;
    final until = mutedUntil;
    if (until != null && (now ?? clock.now()).isBefore(until)) {
      return AlertSuppression.muted;
    }
    return AlertSuppression.none;
  }
}

/// One thing the state machine decided should be said.
///
/// Produced whether or not it may be delivered — see [suppressedBy]. §0.2.1
/// splits "evaluate" from "notify" into two layers and this class is the seam:
/// the screen may render every emission it likes, and only [shouldNotify] ones
/// reach `AlertNotifier.post` in P3.
class AlertEmission {
  const AlertEmission({
    required this.deviceId,
    required this.kind,
    required this.reading,
    required this.threshold,
    required this.source,
    required this.index,
    required this.at,
    required this.suppressedBy,
  });

  /// Which unit. The key of everything here (§3.9) — never "whichever unit is
  /// connected", so that design 0046's second link needs no change in this file.
  final String deviceId;

  final AlertKind kind;

  /// The reading that triggered it, in the kind's own unit. Carried as a double
  /// even for temperature, whose wire value is a signed int8, so that §3.5.3's
  /// notification body has one formatting path rather than two.
  final double reading;

  /// The threshold it crossed, and [source] is where that number came from —
  /// both travel with the emission because §3.5.3 puts the threshold in the
  /// notification body ("目前 10.82 V，門檻 11.00 V") and §6.2 wants the badge
  /// to say who chose it.
  final double threshold;
  final ThresholdSource source;

  /// 1-based position within the CURRENT event, so `index == 1` is the opening
  /// notification and `index == config.maxPerEvent` is the last one before the
  /// machine goes quiet. Resets when the event clears, never on app restart —
  /// P1 holds no persistence at all.
  final int index;

  /// `clock.now()` at the moment it was decided (§3.5.3 prints a time).
  final DateTime at;

  /// [AlertSuppression.none] when this should become a notification.
  final AlertSuppression suppressedBy;

  /// True when nothing blocks it.
  bool get shouldNotify => suppressedBy == AlertSuppression.none;

  @override
  String toString() => 'AlertEmission(${kind.name} #$index on $deviceId: '
      '$reading vs $threshold [${source.name}], ${suppressedBy.name})';
}

/// Per (deviceId, kind) machine state. Private: nothing outside needs to see
/// the timestamps, and exposing them would invite a caller to do the arithmetic
/// a second time.
class _KindState {
  AlertPhase phase = AlertPhase.normal;

  /// When the current uninterrupted breach began — the [AlertPhase.pending]
  /// stopwatch. Cleared on return to [AlertPhase.normal].
  DateTime? breachedAt;

  /// When the last emission was produced, for the repeat interval.
  DateTime? lastEmittedAt;

  /// Emissions so far in this event.
  int emitted = 0;

  void reset() {
    phase = AlertPhase.normal;
    breachedAt = null;
    lastEmittedAt = null;
    emitted = 0;
  }
}

/// The alert state machine for every unit at once (design 0080 §3.3).
///
/// Keyed by `deviceId` from the first line, per §3.9 — not by "the unit on the
/// link". Today there is only ever one link so the two agree, and that
/// agreement is exactly what would let a "current device" shortcut pass every
/// test and then break the day design 0046 brings a second link. Design 0079
/// §0.3 already recorded that trap once, with thresholds read off whichever
/// unit happened to be connected.
class AlertEvaluator {
  AlertEvaluator({this.config = const AlertEvaluatorConfig()});

  /// The four tunables. **Mutable, and replaced rather than rebuilt** — P3
  /// wires three of them to `settings` (§3.6), where the user can move them
  /// while an event is open.
  ///
  /// 🔑 Assigning here keeps every open event's counter and stopwatch, which is
  /// the same answer §7.5.5 gave for a THRESHOLD edited mid-event: the new
  /// value applies from the next fold. Rebuilding the evaluator instead would
  /// silently clear every machine, so nudging "repeat every 15 min" to 16 would
  /// forgive a battery that had already spent its budget.
  AlertEvaluatorConfig config;

  final Map<String, Map<AlertKind, _KindState>> _states =
      <String, Map<AlertKind, _KindState>>{};

  /// Current phase of one (unit, kind), for the detail page's event banner.
  ///
  /// A unit never seen, or one that was cleared by [clearDevice], reads back as
  /// [AlertPhase.normal] rather than null: "we are not warning about this" is
  /// the honest rendering of both, and a nullable return would push a
  /// `?? normal` into every call site anyway.
  AlertPhase phaseOf(String deviceId, AlertKind kind) =>
      _states[deviceId]?[kind]?.phase ?? AlertPhase.normal;

  /// Kinds currently past [AlertPhase.pending] on this unit — what the banner
  /// renders. [AlertPhase.pending] is excluded deliberately: it is a breach we
  /// have not yet decided to believe, and showing it would put the debounce on
  /// screen and undo it.
  Set<AlertKind> activeAlerts(String deviceId) => <AlertKind>{
        for (final kind in AlertKind.values)
          if (phaseOf(deviceId, kind) != AlertPhase.normal &&
              phaseOf(deviceId, kind) != AlertPhase.pending)
            kind,
      };

  /// Feed one telemetry sample for one unit and get back what should be said.
  ///
  /// Returns an empty list on almost every call — a breach produces at most one
  /// emission per kind per call, and a steady healthy reading produces none.
  /// The result is never null and never a "nothing changed" sentinel, so the
  /// caller can do `for (final e in fold(...))` unconditionally on the 1 Hz
  /// path.
  ///
  /// [thresholds] is resolved by the caller (via `resolveThresholds`) rather
  /// than here, because §3.6.2 requires the hot path to touch no storage: the
  /// resolution happens once when the link goes ready and once more whenever
  /// the user edits a setting, and what arrives here is already the answer.
  List<AlertEmission> fold({
    required String deviceId,
    required TelemetrySample sample,
    required AlertThresholds thresholds,
    AlertGate gate = AlertGate.closed,
  }) {
    // One `now` for the whole call. Reading the clock per kind could put the
    // three machines microseconds apart and make "5.0 s exactly" fire for two
    // of them and not the third.
    final now = clock.now();
    final suppression = gate.evaluate(now: now);
    final out = <AlertEmission>[];
    final selfChecking = _inCapacitorSelfCheck(sample);

    for (final kind in AlertKind.values) {
      // 🔵 **FB-102 (2), and it is a SUPPRESSION, so read why before widening
      // it.** A super-capacitor running its self-check reports voltages far
      // below its resting value — one field capture sat at 5.83 V on a unit
      // whose under-voltage limit is 11.47 — and a user was duly notified
      // 「欠壓・目前 5.73 V，門檻 11.47 V，已持續 3 分」 about a unit that was
      // working. The reading is real; what is false is calling it a fault,
      // because every threshold it is compared against was set for a unit that
      // is not being checked.
      //
      // Scoped as narrowly as the defect: VOLTAGE only (temperature is not
      // disturbed by the check, and an over-temperature during one is still an
      // over-temperature), and only on a unit whose class we positively read as
      // a super-capacitor. A unit we could not classify keeps its alerts —
      // erring LOUD is the right direction for an alarm, and the byte pair this
      // turns on is outside the pack code space anyway, so no battery can reach
      // this branch.
      //
      // Reset rather than merely skip: an event already open when the check
      // starts must close, or the banner would keep showing a warning that
      // nothing is feeding any more.
      if (selfChecking && kind.isVoltage) {
        _states[deviceId]?[kind]?.reset();
        continue;
      }
      final threshold = thresholds[kind];
      // Layer ④, or a frame that says nothing about this quantity. Both leave
      // the machine exactly as it was — see the library comment.
      if (!threshold.isSet) continue;
      // 🔵 P3: `AlertKind.readingIn` rather than a private copy here. The
      // banner and the notification body quote the same number this line
      // steps the machine on, and three extractors would be three chances for
      // the screen and the alarm to be talking about different fields.
      final reading = kind.readingIn(sample);
      if (reading == null) continue;

      final emission = _step(
        deviceId: deviceId,
        kind: kind,
        reading: reading,
        threshold: threshold,
        now: now,
        suppression: suppression,
      );
      if (emission != null) out.add(emission);
    }
    return out;
  }

  /// Forget everything about one unit — call this on disconnect (§3.3.2).
  ///
  /// 🔴 Returns nothing, and that is the specification, not an oversight. There
  /// is no "alert cleared" message because **we did not observe it clear; we
  /// stopped observing.** Design 0038's honesty rule in one line: never emit
  /// something that implies data we do not have. A user told "voltage back to
  /// normal" by an app that has been off the link for ten minutes has been
  /// lied to about the one thing they were watching.
  ///
  /// It also zeroes the per-event counter, so a unit that reconnects still
  /// breaching opens a NEW event and gets its full budget. The alternative —
  /// carrying the count across the gap — would silence a genuinely persistent
  /// fault on the strength of notifications sent about a different connection.
  void clearDevice(String deviceId) => _states.remove(deviceId);

  /// Forget every unit. For a full teardown; same no-emission contract as
  /// [clearDevice].
  void clearAll() => _states.clear();

  /// Is this frame from a super-capacitor that is in its self-check phase?
  ///
  /// Both halves are required. [CapacitorStatus.isSelfCheck] is the single
  /// source of the byte pair — shared with the status badge and with the
  /// button's own gate, so the screen and the alarm cannot drift apart about
  /// whether a unit is busy — and the class check keeps the suppression away
  /// from every unit whose device-type byte we have not positively read.
  static bool _inCapacitorSelfCheck(TelemetrySample sample) =>
      ProductClass.fromDeviceType(sample.deviceType) ==
          ProductClass.supercapacitor &&
      CapacitorStatus.isSelfCheck(sample.mode);

  /// Is [reading] past [limit] in the direction [kind] cares about?
  ///
  /// Strict comparison, matching `readingBreachesThreshold` in
  /// `status_controls_shared.dart` exactly (`pvlt > ov`, `pvlt < uv`,
  /// `temp > ot`). §3.8 makes that agreement mandatory: once P2 has the
  /// advisory line reading these same thresholds, a `>` here against a `>=`
  /// there would make the screen and the notification disagree at precisely the
  /// value the user set — the one reading they are most likely to be staring at.
  bool _isBreaching(AlertKind kind, double reading, double limit) =>
      kind == AlertKind.underVoltage ? reading < limit : reading > limit;

  /// Has [reading] come back far enough INSIDE [limit] to end the event?
  ///
  /// Note this is not `!_isBreaching`. The band between the threshold and the
  /// hysteresis line is a third state — "still bad enough to keep the event
  /// open, not bad enough to be new news" — and that third state is the whole
  /// mechanism. Without it, a reading oscillating by a millivolt around its own
  /// limit opens and closes an event on every frame, and each open eventually
  /// buys a fresh budget of three notifications.
  bool _hasCleared(AlertKind kind, double reading, double limit) {
    final band = config.hysteresisFor(kind);
    return kind == AlertKind.underVoltage
        ? reading >= limit + band
        : reading <= limit - band;
  }

  AlertEmission? _step({
    required String deviceId,
    required AlertKind kind,
    required double reading,
    required ResolvedThreshold threshold,
    required DateTime now,
    required AlertSuppression suppression,
  }) {
    final limit = threshold.value!;
    final state = _states
        .putIfAbsent(deviceId, () => <AlertKind, _KindState>{})
        .putIfAbsent(kind, () => _KindState());

    if (state.phase == AlertPhase.normal) {
      if (_isBreaching(kind, reading, limit)) {
        state.phase = AlertPhase.pending;
        state.breachedAt = now;
      }
      // A first sample that is ALREADY over the line still waits out `sustain`.
      // The alternative — firing immediately because we have no earlier reading
      // to compare with — would make every reconnection to a hot battery an
      // instant notification, which is the transient this debounce exists to
      // absorb.
      return null;
    }

    // Any non-normal phase ends the same way: back inside the hysteresis band
    // and the event is over, counter and all.
    if (_hasCleared(kind, reading, limit)) {
      state.reset();
      return null;
    }

    // 🔑 Everything below this line may EMIT, so the reading has to be over the
    // line RIGHT NOW and not merely inside an open event. The three phases
    // above tolerate a reading sitting in the hysteresis band — that is what
    // stops the chatter — but §3.5.3 puts the live reading in the notification
    // body, and "電壓過高 · 目前 14.95 V，門檻 15.00 V" is a message that
    // refutes itself. A dithering value therefore waits for its next genuine
    // excursion, which costs at most one frame and keeps every notification
    // true at the instant it is written.
    if (!_isBreaching(kind, reading, limit)) return null;

    switch (state.phase) {
      case AlertPhase.pending:
        // `>=`, so a `sustain` of exactly 5 s fires at 5.000 s and not at the
        // next frame after it. §5.1 pins both sides of that boundary.
        final held = now.difference(state.breachedAt!);
        if (held < config.sustain) return null;
        return _emit(
          deviceId: deviceId,
          kind: kind,
          reading: reading,
          threshold: threshold,
          state: state,
          now: now,
          suppression: suppression,
        );

      case AlertPhase.firing:
        final since = now.difference(state.lastEmittedAt!);
        if (since < config.repeatInterval) return null;
        return _emit(
          deviceId: deviceId,
          kind: kind,
          reading: reading,
          threshold: threshold,
          state: state,
          now: now,
          suppression: suppression,
        );

      case AlertPhase.silent:
        // Budget spent, reading still bad. Nothing until it clears.
        return null;

      case AlertPhase.normal:
        // Unreachable — handled above. Listed so a future phase added to the
        // enum makes this switch fail to compile rather than fall through.
        return null;
    }
  }

  AlertEmission _emit({
    required String deviceId,
    required AlertKind kind,
    required double reading,
    required ResolvedThreshold threshold,
    required _KindState state,
    required DateTime now,
    required AlertSuppression suppression,
  }) {
    state.emitted += 1;
    state.lastEmittedAt = now;
    // 🔑 The budget is spent by the emission, not by the delivery. A suppressed
    // emission still counts, because the schedule this machine keeps is a
    // property of the READING and the clock, and nothing else. Letting a mute
    // pause the counter would make `index` mean different things on two units
    // seeing identical data, and would hand a muted unit a full three
    // notifications the instant the mute expired — the opposite of what the
    // user pressed the button for.
    state.phase = state.emitted >= config.maxPerEvent
        ? AlertPhase.silent
        : AlertPhase.firing;
    return AlertEmission(
      deviceId: deviceId,
      kind: kind,
      reading: reading,
      threshold: threshold.value!,
      source: threshold.source,
      index: state.emitted,
      at: now,
      suppressedBy: suppression,
    );
  }
}
