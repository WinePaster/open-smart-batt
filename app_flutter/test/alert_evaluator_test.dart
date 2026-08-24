// Design 0080 P1 — the alert state machine (§3.3 / §3.4 / §3.6.3), against the
// test plan in §5.1.
//
// ---------------------------------------------------------------------------
// Why the whole file runs inside `fakeAsync`
// ---------------------------------------------------------------------------
//
// Every rule this machine implements is a rule about DURATION — five seconds of
// persistence, fifteen minutes between repeats, an hour of mute — and none of
// them can be checked by calling it quickly several times. `package:fake_async`
// substitutes `package:clock`'s clock, which is precisely why `lib/` reads
// `clock.now()` and not `DateTime.now()`; the same substitution is what made
// FB-66's frozen-isolate bug expressible at all
// (`autoconnect_watchdog_background_test.dart`).
//
// Note there is no `elapseBlocking` here and no need for one. That primitive
// models an isolate the OS has suspended, and it earns its keep against code
// that owns a `Timer`. `AlertEvaluator` owns none: time only advances at a
// `fold` call, so "the clock moved and nothing ran" is the DEFAULT here rather
// than a thing to be simulated. `async.elapse` followed by an explicit `fold`
// is the whole vocabulary.
//
// ---------------------------------------------------------------------------
// The fixture's timestamps are deliberately wrong
// ---------------------------------------------------------------------------
//
// `_sample()` stamps every [TelemetrySample] with the same frozen date, five
// months away from the fake clock. If any assertion below ever depended on
// `sample.timestamp`, the durations would come out as months and the file would
// fail loudly instead of drifting. §3.3.1 forbids that field as a time source
// (the corpus has a real `0x3B` RTC roll-back, and history backfill rides the
// same stream); this fixture is how that prohibition is enforced rather than
// merely written down. One test asserts it head-on.
//
// CLEAN-ROOM: every expectation derives from design 0080 and this project's own
// source.

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const String _dev = 'AA:BB:CC:DD:EE:FF';
const String _other = '11:22:33:44:55:66';

/// A frozen, deliberately unrelated stamp — see the file header.
final DateTime _wrongClock = DateTime.utc(2026, 3, 1);

TelemetrySample _sample({double? pvlt, int? tempC, DateTime? stamp}) =>
    TelemetrySample(
      timestamp: stamp ?? _wrongClock,
      pvlt: pvlt,
      temperatureC: tempC,
    );

/// Thresholds as a car battery reports them (`18401414`), with no user override.
///
/// 🔵 2026-08-22 — `deviceType` is now part of the fixture, not decoration.
/// Since §7.5.6 C-2 a unit whose class is unknown resolves to three empty
/// fields no matter what its `0x2B` said, so without the `0x02` byte this
/// fixture would silently become "nothing is watched" and every test built on
/// it would pass by evaluating nothing.
final AlertThresholds _carBattery = resolveThresholds(
  reported: _sample().copyWith(
    warnOv: 15.0,
    warnUv: 12.0,
    warnOt: 80,
    deviceType: kSmartBatteryDeviceType,
  ),
);

/// A gate that lets everything through: saved unit, both switches on, no mute.
const AlertGate _open = AlertGate(alertsEnabled: true, deviceSaved: true);

/// Drive one reading in and return whatever came out.
List<AlertEmission> _feed(
  AlertEvaluator e, {
  double? pvlt,
  int? tempC,
  String deviceId = _dev,
  AlertThresholds? thresholds,
  AlertGate gate = _open,
}) =>
    e.fold(
      deviceId: deviceId,
      sample: _sample(pvlt: pvlt, tempC: tempC),
      thresholds: thresholds ?? _carBattery,
      gate: gate,
    );

void main() {
  // -------------------------------------------------------------------------
  group('§3.3.1 — the debounce is measured in seconds', () {
    test('4.9 s of breach says nothing; 5.0 s says it once', () {
      fakeAsync((async) {
        final e = AlertEvaluator();

        // The very first over-limit reading opens the stopwatch and nothing
        // else. Firing here would make every reconnection to a unit that is
        // already warm an instant notification — the transient the debounce
        // exists to absorb.
        expect(_feed(e, pvlt: 11.5), isEmpty);
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.pending);
        expect(e.activeAlerts(_dev), isEmpty,
            reason: 'pending is a breach we have not decided to believe yet, '
                'so the banner must not show it — showing it would put the '
                'debounce on screen and undo it');

        async.elapse(const Duration(milliseconds: 4900));
        expect(_feed(e, pvlt: 11.5), isEmpty,
            reason: '4.9 s is not 5 s, and the boundary is the specification');

        async.elapse(const Duration(milliseconds: 100));
        final out = _feed(e, pvlt: 11.5);
        expect(out, hasLength(1));
        expect(out.single.kind, AlertKind.underVoltage);
        expect(out.single.index, 1);
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.firing);
        expect(e.activeAlerts(_dev), {AlertKind.underVoltage});
      });
    });

    test('the count of frames is irrelevant — only the elapsed time counts',
        () {
      // §3.3.1's actual argument: `_onTelemetry` runs once per DECODED FRAME
      // and a second carries several. Two runs, identical in wall-clock shape,
      // differing only in how many frames arrived, must reach the same verdict
      // — otherwise "5 samples" means 5 s on a battery and 1.5 s on a
      // capacitor and there is no sentence to show a user.
      int firesWith(int framesPerSecond) {
        var fired = 0;
        fakeAsync((async) {
          final e = AlertEvaluator();
          final step = Duration(milliseconds: 1000 ~/ framesPerSecond);
          for (var i = 0; i < framesPerSecond * 6; i++) {
            fired += _feed(e, pvlt: 11.5).length;
            async.elapse(step);
          }
        });
        return fired;
      }

      expect(firesWith(1), 1);
      expect(firesWith(8), 1,
          reason: 'eight times the frames over the same six seconds is still '
              'one event and one notification');
    });

    test('a sample that mentions nothing about a quantity leaves it alone', () {
      // A `0x21` frame carries no PVLT. Reading its absence as "voltage is fine
      // now" would let any interleaved selector reset a genuine breach — and
      // interleaved selectors are the normal traffic, not an edge case.
      fakeAsync((async) {
        final e = AlertEvaluator();
        _feed(e, pvlt: 11.5);
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.pending);

        async.elapse(const Duration(seconds: 3));
        expect(_feed(e, tempC: 30), isEmpty);
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.pending,
            reason: 'the temperature frame said nothing about PVLT');

        async.elapse(const Duration(seconds: 3));
        expect(_feed(e, pvlt: 11.5), hasLength(1),
            reason: 'and the stopwatch kept running across it — six seconds of '
                'breach, not three');
      });
    });

    test('sample.timestamp is never consulted, even when it runs backwards',
        () {
      // The corpus holds a real `0x3B` RTC roll-back. A machine that measured
      // persistence against the sample's own stamp would compute a negative
      // duration there and either fire instantly or never.
      fakeAsync((async) {
        final e = AlertEvaluator();
        e.fold(
          deviceId: _dev,
          sample: _sample(pvlt: 11.5, stamp: DateTime.utc(2026, 8, 22, 12)),
          thresholds: _carBattery,
          gate: _open,
        );

        async.elapse(const Duration(seconds: 6));
        // Same breach, but this frame claims to be an hour EARLIER.
        final out = e.fold(
          deviceId: _dev,
          sample: _sample(pvlt: 11.5, stamp: DateTime.utc(2026, 8, 22, 11)),
          thresholds: _carBattery,
          gate: _open,
        );

        expect(out, hasLength(1),
            reason: 'six seconds of wall clock elapsed, whatever the device '
                'thinks the time is');
      });
    });
  });

  // -------------------------------------------------------------------------
  group('§3.3 — hysteresis', () {
    test('a reading dithering across its own limit 100 times fires once', () {
      // §5.1's row, literally. Without the band, each dip below the threshold
      // would close the event and each rise would open a new one — with a fresh
      // budget of three notifications each time.
      fakeAsync((async) {
        final e = AlertEvaluator();
        var fired = 0;

        for (var i = 0; i < 100; i++) {
          // 11.95 / 12.05 — either side of UV 12.0, never as far as the
          // clear line at 12.3.
          fired += _feed(e, pvlt: i.isEven ? 11.95 : 12.05).length;
          async.elapse(const Duration(milliseconds: 200));
        }

        expect(fired, 1, reason: '20 s of chatter, one notification');
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.firing,
            reason: 'and the event is still open — the value never came back '
                'inside the band');
      });
    });

    test('coming back INSIDE the threshold is not enough; the band must be '
        'crossed', () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        _feed(e, pvlt: 11.5);
        async.elapse(const Duration(seconds: 5));
        expect(_feed(e, pvlt: 11.5), hasLength(1));

        // 12.1 is above the UV of 12.0 — no longer breaching — but short of
        // 12.3, so the event stays open.
        async.elapse(const Duration(seconds: 1));
        expect(_feed(e, pvlt: 12.1), isEmpty);
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.firing);

        async.elapse(const Duration(seconds: 1));
        expect(_feed(e, pvlt: 12.3), isEmpty);
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.normal,
            reason: 'UV 12.0 + 0.3 V band — exactly on the line clears it');
      });
    });

    test('over-voltage and over-temperature clear DOWNWARD through their bands',
        () {
      // The under-voltage direction is inverted and the other two are not; a
      // sign error in `_hasCleared` would be invisible from the UV tests alone.
      fakeAsync((async) {
        final e = AlertEvaluator();

        _feed(e, pvlt: 15.5, tempC: 90);
        async.elapse(const Duration(seconds: 5));
        final out = _feed(e, pvlt: 15.5, tempC: 90);
        expect(out.map((x) => x.kind),
            containsAll([AlertKind.overVoltage, AlertKind.overTemperature]));

        // Just under the limits, still inside the bands.
        async.elapse(const Duration(seconds: 1));
        _feed(e, pvlt: 14.9, tempC: 79);
        expect(e.phaseOf(_dev, AlertKind.overVoltage), AlertPhase.firing);
        expect(e.phaseOf(_dev, AlertKind.overTemperature), AlertPhase.firing);

        // OV 15.0 − 0.3 V and OT 80 − 3 °C.
        async.elapse(const Duration(seconds: 1));
        _feed(e, pvlt: 14.7, tempC: 77);
        expect(e.phaseOf(_dev, AlertKind.overVoltage), AlertPhase.normal);
        expect(e.phaseOf(_dev, AlertKind.overTemperature), AlertPhase.normal);
      });
    });

    test('a notification is never written about a reading that is not breaching',
        () {
      // The band keeps the EVENT open, but §3.5.3 prints the live reading in
      // the body, and "電壓過低 · 目前 12.10 V，門檻 12.00 V" is a message that
      // refutes itself. So an emission waits for the next genuine excursion.
      fakeAsync((async) {
        final e = AlertEvaluator();
        _feed(e, pvlt: 11.5);
        async.elapse(const Duration(seconds: 5));
        expect(_feed(e, pvlt: 11.5), hasLength(1));

        // Sit inside the band for well past the repeat interval.
        for (var i = 0; i < 20; i++) {
          async.elapse(const Duration(minutes: 1));
          expect(_feed(e, pvlt: 12.1), isEmpty);
        }
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.firing);

        // The moment it genuinely dips again, the overdue repeat is due.
        final out = _feed(e, pvlt: 11.9);
        expect(out, hasLength(1));
        expect(out.single.index, 2);
        expect(out.single.reading, 11.9,
            reason: 'and the number in the body is the one that is actually '
                'below the line');
      });
    });
  });

  // -------------------------------------------------------------------------
  group('§3.4 gate ① — the per-event budget', () {
    test('an hour of continuous breach yields exactly 3, spaced 15 minutes',
        () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        final fired = <AlertEmission>[];
        final start = clock.now();

        // 1 Hz for an hour, which is the real cadence.
        for (var i = 0; i < 3600; i++) {
          fired.addAll(_feed(e, pvlt: 11.5));
          async.elapse(const Duration(seconds: 1));
        }

        expect(fired, hasLength(3));
        expect(fired.map((x) => x.index), [1, 2, 3]);
        expect(fired[0].at.difference(start), const Duration(seconds: 5),
            reason: 'the first one lands at the end of the debounce');
        expect(fired[1].at.difference(fired[0].at), const Duration(minutes: 15));
        expect(fired[2].at.difference(fired[1].at), const Duration(minutes: 15));
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.silent,
            reason: 'budget spent, reading still bad — an unattended phone has '
                'to go quiet on its own');
        expect(e.activeAlerts(_dev), {AlertKind.underVoltage},
            reason: 'quiet is not the same as resolved: the banner stays up');
      });
    });

    test('clearing resets the budget, so a second event gets a full three', () {
      // §5.1: "解除後可再觸發 ⇒ 計數已重置". The alternative would let a unit
      // that faults, recovers and faults again be silenced by notifications
      // sent about the first fault.
      fakeAsync((async) {
        final e = AlertEvaluator();

        for (var i = 0; i < 3600; i++) {
          _feed(e, pvlt: 11.5);
          async.elapse(const Duration(seconds: 1));
        }
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.silent);

        // Back past the band ⇒ event over.
        _feed(e, pvlt: 12.4);
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.normal);

        async.elapse(const Duration(minutes: 5));
        _feed(e, pvlt: 11.5);
        async.elapse(const Duration(seconds: 5));
        final out = _feed(e, pvlt: 11.5);

        expect(out, hasLength(1));
        expect(out.single.index, 1, reason: 'a NEW event, numbered from one');
      });
    });

    test('a suppressed emission still spends its slot', () {
      // 🔑 A DECISION the design does not settle, recorded here so it is a
      // choice rather than an accident. The schedule is a property of the
      // reading and the clock alone, so a mute does not pause the counter. The
      // consequence is deliberate: a unit muted for an hour does NOT receive
      // three stored-up notifications the instant the mute expires, which is
      // the opposite of what the user pressed the button for. The cost is that
      // an event muted at minute 0 and unmuted at minute 40 has already spent
      // its budget and will say nothing more until it clears.
      fakeAsync((async) {
        final e = AlertEvaluator();
        final muted = AlertGate(
          alertsEnabled: true,
          deviceSaved: true,
          mutedUntil: clock.now().add(const Duration(hours: 1)),
        );
        final fired = <AlertEmission>[];

        for (var i = 0; i < 2400; i++) {
          fired.addAll(_feed(e, pvlt: 11.5, gate: muted));
          async.elapse(const Duration(seconds: 1));
        }

        expect(fired, hasLength(3), reason: 'all three were decided');
        expect(fired.every((x) => !x.shouldNotify), isTrue);
        expect(fired.map((x) => x.suppressedBy).toSet(),
            {AlertSuppression.muted});
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.silent);
      });
    });
  });

  // -------------------------------------------------------------------------
  group('§3.3.2 — disconnect clears, and says nothing', () {
    test('clearDevice emits nothing and leaves no trace', () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        _feed(e, pvlt: 11.5);
        async.elapse(const Duration(seconds: 5));
        expect(_feed(e, pvlt: 11.5), hasLength(1));
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.firing);

        // The link drops. 🔴 There is no "resolved" message, and the return
        // type is `void` on purpose: we did not observe it clear, we stopped
        // observing. Design 0038's rule — never emit something that implies
        // data we do not have.
        e.clearDevice(_dev);

        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.normal);
        expect(e.activeAlerts(_dev), isEmpty);

        // And nothing arrives later either, however long we wait — there is no
        // timer left holding a reference to the old event.
        async.elapse(const Duration(hours: 2));
        expect(e.activeAlerts(_dev), isEmpty);
      });
    });

    test('a unit that reconnects still breaching opens a NEW event', () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        for (var i = 0; i < 3600; i++) {
          _feed(e, pvlt: 11.5);
          async.elapse(const Duration(seconds: 1));
        }
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.silent);

        e.clearDevice(_dev);
        async.elapse(const Duration(minutes: 30));

        // Reconnected; the battery is still flat.
        _feed(e, pvlt: 11.5);
        async.elapse(const Duration(seconds: 5));
        final out = _feed(e, pvlt: 11.5);

        expect(out, hasLength(1));
        expect(out.single.index, 1,
            reason: 'carrying the old count across the gap would silence a '
                'genuinely persistent fault on the strength of notifications '
                'sent about a different connection');
      });
    });

    test('the debounce restarts from zero after a disconnect', () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        _feed(e, pvlt: 11.5);
        async.elapse(const Duration(seconds: 4));
        e.clearDevice(_dev);

        _feed(e, pvlt: 11.5);
        async.elapse(const Duration(seconds: 4));
        expect(_feed(e, pvlt: 11.5), isEmpty,
            reason: 'eight seconds of breach in total, but only four of them '
                'observed on this link');
      });
    });

    test('clearAll does the same for every unit at once', () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        _feed(e, pvlt: 11.5);
        _feed(e, pvlt: 11.5, deviceId: _other);
        async.elapse(const Duration(seconds: 5));
        _feed(e, pvlt: 11.5);
        _feed(e, pvlt: 11.5, deviceId: _other);

        e.clearAll();

        expect(e.activeAlerts(_dev), isEmpty);
        expect(e.activeAlerts(_other), isEmpty);
      });
    });
  });

  // -------------------------------------------------------------------------
  group('§3.6.3 / Q3 — the gate is on the OUTPUT, never on the input', () {
    test('an unsaved unit is fully evaluated and simply not notified about',
        () {
      // 🔴 §5.1's row, and the ruling's implementation discipline in one test:
      // "狀態機有升級、通知呼叫次數為 0". Moving the gate earlier — "unsaved ⇒
      // do not evaluate" — would take the advisory line away from a user who
      // has it today, which §3.6.3 calls a regression rather than the ruling.
      fakeAsync((async) {
        final e = AlertEvaluator();
        const unsaved = AlertGate(alertsEnabled: true, deviceSaved: false);

        _feed(e, pvlt: 11.5, gate: unsaved);
        async.elapse(const Duration(seconds: 5));
        final out = _feed(e, pvlt: 11.5, gate: unsaved);

        expect(out, hasLength(1), reason: 'the machine escalated');
        expect(out.single.shouldNotify, isFalse, reason: 'and nothing is posted');
        expect(out.single.suppressedBy, AlertSuppression.unsavedDevice);
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.firing);
        expect(e.activeAlerts(_dev), {AlertKind.underVoltage},
            reason: 'the banner and the advisory line are unaffected — that is '
                'the whole of ruling Q3');
      });
    });

    test('each gate names the reason, broadest cause first', () {
      // The order matters to the user, not to the machine: being told "this
      // device is muted" while the global switch is off sends them to fix the
      // wrong screen.
      fakeAsync((async) {
        final now = clock.now();
        AlertSuppression at(AlertGate g) => g.evaluate(now: now);

        expect(
            at(AlertGate(
                alertsEnabled: false,
                deviceSaved: false,
                deviceAlertsEnabled: false,
                silencedForSession: true,
                mutedUntil: now.add(const Duration(hours: 1)))),
            AlertSuppression.globallyDisabled);
        expect(
            at(AlertGate(
                alertsEnabled: true,
                deviceSaved: false,
                deviceAlertsEnabled: false,
                silencedForSession: true,
                mutedUntil: now.add(const Duration(hours: 1)))),
            AlertSuppression.unsavedDevice);
        expect(
            at(AlertGate(
                alertsEnabled: true,
                deviceSaved: true,
                deviceAlertsEnabled: false,
                silencedForSession: true,
                mutedUntil: now.add(const Duration(hours: 1)))),
            AlertSuppression.deviceAlertsDisabled);
        expect(
            at(AlertGate(
                alertsEnabled: true,
                deviceSaved: true,
                silencedForSession: true,
                mutedUntil: now.add(const Duration(hours: 1)))),
            AlertSuppression.silencedForSession);
        expect(
            at(AlertGate(
                alertsEnabled: true,
                deviceSaved: true,
                mutedUntil: now.add(const Duration(hours: 1)))),
            AlertSuppression.muted);
        expect(at(_open), AlertSuppression.none);
      });
    });

    test('a mute that has run out is simply not a mute', () {
      // "Mute for 1 hour" is a promise about TIME (§3.4 ②), so an expired stamp
      // needs no cleanup pass and no migration — it just stops being true.
      fakeAsync((async) {
        final e = AlertEvaluator();
        final gate = AlertGate(
          alertsEnabled: true,
          deviceSaved: true,
          mutedUntil: clock.now().add(const Duration(hours: 1)),
        );

        _feed(e, pvlt: 11.5, gate: gate);
        async.elapse(const Duration(seconds: 5));
        expect(_feed(e, pvlt: 11.5, gate: gate).single.suppressedBy,
            AlertSuppression.muted);

        // Well past the stamp, with the same gate object.
        async.elapse(const Duration(hours: 2));
        _feed(e, pvlt: 12.4, gate: gate); // clear, so a new event can open
        _feed(e, pvlt: 11.5, gate: gate);
        async.elapse(const Duration(seconds: 5));
        expect(_feed(e, pvlt: 11.5, gate: gate).single.shouldNotify, isTrue);
      });
    });

    test('an omitted gate delivers nothing, and says why', () {
      // `AlertGate.closed` is the default so that "not yet wired up" and
      // "switched off" look the same — ruling Q4 ships the global switch off.
      // The emission still comes back, so the omission is visible rather than
      // merely quiet.
      fakeAsync((async) {
        final e = AlertEvaluator();
        e.fold(
            deviceId: _dev,
            sample: _sample(pvlt: 11.5),
            thresholds: _carBattery);
        async.elapse(const Duration(seconds: 5));
        final out = e.fold(
            deviceId: _dev,
            sample: _sample(pvlt: 11.5),
            thresholds: _carBattery);

        expect(out, hasLength(1));
        expect(out.single.shouldNotify, isFalse);
        expect(out.single.suppressedBy, AlertSuppression.globallyDisabled);
      });
    });
  });

  // -------------------------------------------------------------------------
  group('§3.1 layer ④ — a field with no threshold is not evaluated', () {
    test('an unknown unit produces nothing however bad the reading', () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        // 🔵 A recognised battery that simply has no thresholds from any layer:
        // since §7.5.6 C-2 a bare `resolveThresholds()` would be stopped by the
        // DEVICE gate instead, which is a different rule and is tested in
        // `alert_thresholds_test.dart`. This one is still about layer ④.
        final none = resolveThresholds(wireClass: ProductClass.smartBattery);

        for (var i = 0; i < 60; i++) {
          expect(_feed(e, pvlt: 3.0, tempC: 120, thresholds: none), isEmpty);
          async.elapse(const Duration(seconds: 1));
        }
        expect(e.activeAlerts(_dev), isEmpty,
            reason: '3 V and 120 °C look alarming, but we have no idea what '
                'this unit is — a warning here is a coin toss whose losing '
                'side is permanent');
      });
    });

    test('a partially known unit evaluates only the fields it knows', () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        // Only a UV; nothing else from any layer. The wire class is required
        // since §7.5.6 C-2 — an unidentified unit gets no alarms at all, so
        // without it there would be no UV here to be partial about.
        // 🔵 2026-08-25 (FB-100) — ~~userUv: 12.0~~ came from the user before
        // the thresholds went read-only. A partial `0x2B` produces the same
        // shape and is a state the wire can actually be in.
        final partial = resolveThresholds(
          reported: _sample().copyWith(
            warnUv: 12.0,
            deviceType: kSmartBatteryDeviceType,
          ),
          wireClass: ProductClass.smartBattery,
        );

        _feed(e, pvlt: 11.5, tempC: 200, thresholds: partial);
        async.elapse(const Duration(seconds: 5));
        final out = _feed(e, pvlt: 11.5, tempC: 200, thresholds: partial);

        expect(out.map((x) => x.kind), [AlertKind.underVoltage]);
        expect(e.phaseOf(_dev, AlertKind.overTemperature), AlertPhase.normal,
            reason: '200 °C with no OT threshold anywhere is still not '
                'something we can call abnormal');
      });
    });
  });

  // -------------------------------------------------------------------------
  group('§3.2.2 — power banks: heat only', () {
    // 🔵 2026-08-22 — the premise moved from the DECLARATION to the WIRE
    // (design 0080 §7.5.1.1 A), and that changes what this group asserts.
    // It used to say "a user who taps 行動電源 gets no voltage alarms"; it now
    // says "a unit that REPORTS device-type 0x22 gets none", which is the claim
    // the ruling actually makes and the only one design 0066 permits. The three
    // resolved values are unchanged, so everything below still reads the same —
    // only the reason it holds is different. The declaration stays in the call
    // because layer ③ is still where the 50 °C comes from.
    final powerBank = resolveThresholds(
      category: DeclaredCategory.powerBank,
      wireClass: ProductClass.powerBank,
    );

    test('no voltage is ever evaluated, however far out it reads', () {
      fakeAsync((async) {
        final e = AlertEvaluator();

        // 3.6 V would be a catastrophic under-voltage on a 12 V pack. Here it
        // is a perfectly ordinary CELL voltage, which is the whole reason the
        // ruling exists — and 20 V is checked too, so the test cannot pass by
        // the reading merely happening to sit inside some band.
        for (var i = 0; i < 60; i++) {
          expect(_feed(e, pvlt: i.isEven ? 3.6 : 20.0, thresholds: powerBank),
              isEmpty);
          async.elapse(const Duration(seconds: 1));
        }

        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.normal);
        expect(e.phaseOf(_dev, AlertKind.overVoltage), AlertPhase.normal);
      });
    });

    test('over-temperature fires at the app-chosen 50 °C, labelled as ours', () {
      fakeAsync((async) {
        final e = AlertEvaluator();

        _feed(e, tempC: 49, thresholds: powerBank);
        async.elapse(const Duration(seconds: 10));
        expect(_feed(e, tempC: 50, thresholds: powerBank), isEmpty,
            reason: 'strictly greater, matching readingBreachesThreshold — the '
                'advisory line and the notification have to agree at exactly '
                'the value the user is looking at (§3.8)');

        _feed(e, tempC: 51, thresholds: powerBank);
        async.elapse(const Duration(seconds: 5));
        final out = _feed(e, tempC: 51, thresholds: powerBank);

        expect(out, hasLength(1));
        expect(out.single.threshold, 50);
        expect(out.single.source, ThresholdSource.appDefault,
            reason: 'the 50 is a reminder point we picked — the observed '
                'ceiling across 49 batches is 40 °C and nobody has measured '
                'what is actually unsafe. §3.2.2 requires the screen to say so, '
                'which it cannot do unless the emission carries it');
      });
    });
  });

  // -------------------------------------------------------------------------
  group('§3.9 — keyed by deviceId, never by "whoever is connected"', () {
    test('two units interleaved do not contaminate each other', () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        final first = <AlertEmission>[];
        final second = <AlertEmission>[];

        // Unit A is flat from t=0. Unit B is healthy until t=10 s.
        for (var i = 0; i < 40; i++) {
          first.addAll(_feed(e, pvlt: 11.5));
          second.addAll(
              _feed(e, pvlt: i < 10 ? 12.8 : 11.5, deviceId: _other));
          async.elapse(const Duration(seconds: 1));
        }

        expect(first, hasLength(1));
        expect(second, hasLength(1));
        expect(first.single.deviceId, _dev);
        expect(second.single.deviceId, _other);
        expect(second.single.at.difference(first.single.at),
            const Duration(seconds: 10),
            reason: 'B\'s five-second debounce started when B went out of '
                'range, not when A did');
      });
    });

    test('clearing one unit leaves the other alone', () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        _feed(e, pvlt: 11.5);
        _feed(e, pvlt: 11.5, deviceId: _other);
        async.elapse(const Duration(seconds: 5));
        _feed(e, pvlt: 11.5);
        _feed(e, pvlt: 11.5, deviceId: _other);

        e.clearDevice(_dev);

        expect(e.activeAlerts(_dev), isEmpty);
        expect(e.activeAlerts(_other), {AlertKind.underVoltage},
            reason: 'one link dropping is not the other one dropping — design '
                '0046 will make that a routine occurrence');
      });
    });

    test('the same unit can hold three independent events at once', () {
      fakeAsync((async) {
        final e = AlertEvaluator();

        // Over-voltage and over-temperature start together; under-voltage
        // cannot co-occur with over-voltage, so it is checked separately above.
        _feed(e, pvlt: 15.4, tempC: 95);
        async.elapse(const Duration(seconds: 5));
        final out = _feed(e, pvlt: 15.4, tempC: 95);

        expect(out, hasLength(2));
        expect(out.map((x) => x.kind).toSet(),
            {AlertKind.overVoltage, AlertKind.overTemperature});
        expect(out.every((x) => x.index == 1), isTrue);
        expect(out.map((x) => x.at).toSet(), hasLength(1),
            reason: 'one clock read per fold, so three machines cannot end up '
                'microseconds apart and disagree about a 5.000 s boundary');

        // Temperature recovers; the voltage event is untouched.
        async.elapse(const Duration(seconds: 1));
        _feed(e, pvlt: 15.4, tempC: 70);
        expect(e.phaseOf(_dev, AlertKind.overTemperature), AlertPhase.normal);
        expect(e.phaseOf(_dev, AlertKind.overVoltage), AlertPhase.firing);
      });
    });
  });

  // -------------------------------------------------------------------------
  group('what an emission carries (§3.5.3)', () {
    test('deviceId, kind, reading, threshold, provenance, index and time', () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        final start = clock.now();

        _feed(e, pvlt: 10.82);
        async.elapse(const Duration(seconds: 5));
        final x = _feed(e, pvlt: 10.82).single;

        // "<別名> · 電壓過低" / "目前 10.82 V，門檻 12.00 V · 14:32" — every
        // token in §3.5.3's copy has to come from somewhere, and this is it.
        expect(x.deviceId, _dev);
        expect(x.kind, AlertKind.underVoltage);
        expect(x.reading, 10.82);
        expect(x.threshold, 12.0);
        expect(x.source, ThresholdSource.device);
        expect(x.index, 1);
        expect(x.at, start.add(const Duration(seconds: 5)));
        expect(x.shouldNotify, isTrue);
      });
    });

    // 🔵 **2026-08-25 (FB-100) — ~~'a user-set threshold is reported as the
    // user\'s'~~ deleted with the layer it tested.** Worth keeping its point on
    // the record, because it is what the ruling gave up: the deleted case fed
    // 12.2 V against a user's 12.4 and asserted the event carried the user's
    // number, on the grounds that the device's own 12.0 「would say nothing at
    // all without the override — which is exactly the want §1.2 G1 describes:
    // knowing sooner」. Read-only thresholds mean an owner can no longer buy
    // that head start; the emission now always carries the factory point. The
    // replacement asserts the table's number survives the trip instead, so the
    // 'source travels with the event' contract keeps a test.
    test('an app-default threshold is reported as the app\'s', () {
      fakeAsync((async) {
        final e = AlertEvaluator();
        final table = resolveThresholds(
          reported: _sample().copyWith(deviceType: kSmartBatteryDeviceType),
          category: DeclaredCategory.carBattery,
        );

        _feed(e, pvlt: 11.8, thresholds: table);
        async.elapse(const Duration(seconds: 5));
        final x = _feed(e, pvlt: 11.8, thresholds: table).single;

        expect(x.threshold, 12.0, reason: 'the car-battery row, no 0x2B');
        expect(x.source, ThresholdSource.appDefault);
      });
    });

    test('a config the caller chose is the config that is used', () {
      // P2 exposes three of these in `settings`. A machine that quietly ignored
      // them would look correct in every test that used the defaults.
      fakeAsync((async) {
        final e = AlertEvaluator(
          config: const AlertEvaluatorConfig(
            sustain: Duration(seconds: 30),
            repeatInterval: Duration(minutes: 1),
            maxPerEvent: 2,
            voltageHysteresis: 1.0,
          ),
        );
        final fired = <AlertEmission>[];
        final start = clock.now();

        for (var i = 0; i < 600; i++) {
          fired.addAll(_feed(e, pvlt: 11.5));
          async.elapse(const Duration(seconds: 1));
        }

        expect(fired, hasLength(2),
            reason: 'maxPerEvent 2, not the default 3');
        expect(fired[0].at.difference(start), const Duration(seconds: 30),
            reason: 'the 30 s sustain was honoured, not the 5 s default');
        expect(fired[1].at.difference(fired[0].at), const Duration(minutes: 1),
            reason: 'and the 1 minute repeat, not the default 15');

        // The wider band too: with hysteresis at 1.0 V the clear line for a
        // 12.0 V UV sits at 13.0, so 12.5 — which WOULD have cleared it under
        // the 0.3 V default — leaves the event open.
        _feed(e, pvlt: 12.5);
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.silent);
        _feed(e, pvlt: 13.0);
        expect(e.phaseOf(_dev, AlertKind.underVoltage), AlertPhase.normal);
      });
    });
  });
}
