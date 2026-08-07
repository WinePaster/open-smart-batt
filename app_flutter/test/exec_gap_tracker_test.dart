// Execution-gap instrument (design 0047 Phase 0).
//
// The tracker's claim is narrow and has to stay narrow: a line is emitted only
// when a BLE event lands ≥ threshold after a keep-alive tick that actually
// happened. Two mistakes would silently widen it into a different claim:
//  * measuring against nothing (no tick yet, or after reset) would turn
//    "the isolate was suspended" into "time since the last link existed";
//  * not re-ticking on the event itself would turn one suspension window into
//    a line per backlogged event flushed on thaw.
// Both are pinned here. Clock-free by construction — `now` is a parameter —
// so no test needs to wait out a real threshold.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/exec_gap_tracker.dart';

void main() {
  final t0 = DateTime(2026, 8, 7, 12, 0, 0);

  test('no line before any tick has happened', () {
    final tracker = ExecGapTracker();
    expect(tracker.onEvent('notify', t0), isNull,
        reason: 'with no tick there is no schedule to have gapped');
  });

  test('gap below threshold stays quiet', () {
    final tracker = ExecGapTracker();
    tracker.tick(t0);
    expect(
        tracker.onEvent('notify', t0.add(const Duration(milliseconds: 4999))),
        isNull);
  });

  test('gap at threshold emits the fixed-format line', () {
    final tracker = ExecGapTracker();
    tracker.tick(t0);
    expect(tracker.onEvent('notify', t0.add(const Duration(seconds: 5))),
        'exec gap 5000ms ended by notify');
  });

  test('a long suspension reports its true length and event type', () {
    final tracker = ExecGapTracker();
    tracker.tick(t0);
    expect(
        tracker.onEvent(
            'conn-state', t0.add(const Duration(minutes: 14, seconds: 3))),
        'exec gap 843000ms ended by conn-state');
  });

  test('the event itself counts as a tick: a backlog burst logs once', () {
    final tracker = ExecGapTracker();
    tracker.tick(t0);
    final thaw = t0.add(const Duration(seconds: 60));
    expect(tracker.onEvent('notify', thaw), isNotNull);
    // Backlogged chunks land within the same second on thaw.
    expect(
        tracker.onEvent('notify', thaw.add(const Duration(milliseconds: 3))),
        isNull);
    expect(
        tracker.onEvent('notify', thaw.add(const Duration(milliseconds: 9))),
        isNull);
  });

  test('reset severs the schedule: no gap can span a teardown', () {
    final tracker = ExecGapTracker();
    tracker.tick(t0);
    tracker.reset();
    // Ten idle minutes between two connections is not a suspension.
    expect(tracker.onEvent('conn-state', t0.add(const Duration(minutes: 10))),
        isNull);
  });

  test('a healthy 1 Hz schedule never emits', () {
    final tracker = ExecGapTracker();
    var now = t0;
    for (var i = 0; i < 30; i++) {
      tracker.tick(now);
      now = now.add(const Duration(seconds: 1));
    }
    expect(tracker.onEvent('notify', now), isNull);
  });

  test('threshold is injectable for policy tests', () {
    final tracker = ExecGapTracker(threshold: const Duration(seconds: 2));
    tracker.tick(t0);
    expect(tracker.onEvent('notify', t0.add(const Duration(seconds: 3))),
        'exec gap 3000ms ended by notify');
  });
}
