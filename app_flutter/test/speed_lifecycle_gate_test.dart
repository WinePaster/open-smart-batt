// `inactive` is not "the user left" (design 0042 §3.4, Q5).
//
// The mapping under test used to be `setAppResumed(state == resumed)`, which is
// correct for `paused` and wrong for `inactive`. `inactive` fires for a
// notification banner, a control-centre drag, the app switcher, an incoming
// call — and for a system permission dialog, which is exactly what design
// 0042's own consent flow raises. Each of those ran the full teardown:
// cancel the platform stream, `SpeedEstimator.reset()` (which empties the card
// AND emits a `→ lost` edge design 0044 uses to drop its window), then a
// permission read, a fresh stream and a GNSS warm start on the way back.
//
// What is NOT debounced is as load-bearing as what is: `paused` / `hidden` /
// `detached` still close in the same turn, because they are the states that
// actually cost battery, and G4's "any condition failing cancels it" has to
// stay literal for those.
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/state/speed_lifecycle_gate.dart';

void main() {
  late List<bool> calls;
  late SpeedLifecycleGate gate;

  setUp(() {
    calls = <bool>[];
    gate = SpeedLifecycleGate(
      setAppResumed: calls.add,
      grace: const Duration(milliseconds: 40),
    );
    addTearDown(gate.dispose);
  });

  test('resumed opens immediately', () {
    gate.onLifecycle(AppLifecycleState.resumed);
    expect(calls, [true]);
    expect(gate.gracePending, isFalse);
  });

  for (final state in [
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.detached,
  ]) {
    test('${state.name} closes in the SAME turn, with no grace', () {
      // Synchronously, deliberately: these are the states where a location
      // stream is genuinely costing a user battery for nothing.
      gate.onLifecycle(state);
      expect(calls, [false]);
      expect(gate.gracePending, isFalse);
    });
  }

  test('inactive does not close anything yet', () {
    gate.onLifecycle(AppLifecycleState.resumed);
    calls.clear();
    gate.onLifecycle(AppLifecycleState.inactive);
    expect(calls, isEmpty,
        reason: 'a banner must not blank the speed reading');
    expect(gate.gracePending, isTrue);
  });

  test('inactive followed by resumed is as if nothing happened', () async {
    // The permission-dialog case, and the banner case: the app was never away.
    gate.onLifecycle(AppLifecycleState.resumed);
    calls.clear();
    gate.onLifecycle(AppLifecycleState.inactive);
    gate.onLifecycle(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(calls, [true],
        reason: 'one redundant open, and crucially NO close — a close would '
            'have reset the estimator and emitted the `lost` edge design 0044 '
            'treats as the end of a series');
    expect(gate.gracePending, isFalse);
  });

  test('an inactive nobody came back from does close, late', () async {
    gate.onLifecycle(AppLifecycleState.resumed);
    calls.clear();
    gate.onLifecycle(AppLifecycleState.inactive);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(calls, [false], reason: 'the grace is a delay, not a veto');
    expect(gate.gracePending, isFalse);
  });

  test('paused arriving during the grace closes at once, not on the timer',
      () async {
    // The real iOS order for a genuine departure: inactive, then background.
    // The close must not wait out the remainder of a grace that has been
    // overtaken by a definite answer.
    gate.onLifecycle(AppLifecycleState.resumed);
    calls.clear();
    gate.onLifecycle(AppLifecycleState.inactive);
    gate.onLifecycle(AppLifecycleState.paused);
    expect(calls, [false]);
    expect(gate.gracePending, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(calls, [false], reason: 'and the cancelled timer does not fire too');
  });

  test('dispose cancels a pending grace', () async {
    // Otherwise a timer outliving the widget calls into a disposed controller.
    gate.onLifecycle(AppLifecycleState.inactive);
    gate.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(calls, isEmpty);
  });

  test('the shipped grace is a few seconds, not a few minutes', () {
    // A sanity bound rather than a tuned value (Phase F meets a real phone).
    // Too long and a real departure keeps GNSS running; too short and it stops
    // covering the banner it exists for.
    expect(SpeedLifecycleGate.defaultGrace.inSeconds, inInclusiveRange(2, 10));
  });
}
