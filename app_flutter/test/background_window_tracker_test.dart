// Foreground/background window pairing (design 0047 Phase 0).
//
// The `bg-window:` lines are what lets a feedback batch measure suspension
// windows against link survival without reconstructing them from per-minute
// frame-count holes. What the pairing must guarantee:
//  * one window = one enter + one exit, however many non-foreground states
//    the OS delivers back to back (iOS sends inactive→hidden→paused);
//  * `inactive` opens nothing — a notification banner is not the user leaving
//    (same judgement as SpeedLifecycleGate, and for the same reason);
//  * a `resumed` with no open window says nothing, so a banner round-trip
//    cannot mint a zero-length window into the statistics.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble_models.dart';
import 'package:open_smart_batt/state/background_window_tracker.dart';

void main() {
  final t0 = DateTime(2026, 8, 7, 11, 0, 50);

  test('paused opens a window and snapshots the link', () {
    final tracker = BackgroundWindowTracker();
    expect(tracker.onLifecycle('paused', link: 'ready', now: t0),
        'bg-window: enter link=ready');
    expect(tracker.inBackground, isTrue);
  });

  test('hidden then paused (iOS ordering) opens ONE window', () {
    final tracker = BackgroundWindowTracker();
    expect(tracker.onLifecycle('hidden', link: 'ready', now: t0), isNotNull);
    expect(
        tracker.onLifecycle('paused',
            link: 'ready', now: t0.add(const Duration(milliseconds: 12))),
        isNull,
        reason: 'the second non-foreground state is the same departure');
    expect(tracker.inBackground, isTrue);
  });

  test('resume closes the window with its duration and link state', () {
    final tracker = BackgroundWindowTracker();
    tracker.onLifecycle('paused', link: 'ready', now: t0);
    expect(
        tracker.onLifecycle('resumed',
            link: 'none', now: t0.add(const Duration(minutes: 14, seconds: 3))),
        'bg-window: exit away=843000ms link=none');
    expect(tracker.inBackground, isFalse);
  });

  test('window duration is measured from the FIRST non-foreground state', () {
    final tracker = BackgroundWindowTracker();
    tracker.onLifecycle('hidden', link: 'ready', now: t0);
    tracker.onLifecycle('paused',
        link: 'ready', now: t0.add(const Duration(seconds: 2)));
    expect(
        tracker.onLifecycle('resumed',
            link: 'ready', now: t0.add(const Duration(seconds: 10))),
        'bg-window: exit away=10000ms link=ready');
  });

  test('resumed with no open window says nothing', () {
    final tracker = BackgroundWindowTracker();
    expect(tracker.onLifecycle('resumed', link: 'ready', now: t0), isNull);
  });

  test('inactive is not an edge in either direction', () {
    final tracker = BackgroundWindowTracker();
    expect(tracker.onLifecycle('inactive', link: 'ready', now: t0), isNull);
    expect(tracker.inBackground, isFalse,
        reason: 'a banner or permission dialog is not the user leaving');
    tracker.onLifecycle('paused', link: 'ready', now: t0);
    expect(
        tracker.onLifecycle('inactive',
            link: 'ready', now: t0.add(const Duration(seconds: 1))),
        isNull,
        reason: 'and inside a window it must not close or reopen it');
    expect(tracker.inBackground, isTrue);
  });

  test('detached also opens a window (control may never come back)', () {
    final tracker = BackgroundWindowTracker();
    expect(tracker.onLifecycle('detached', link: 'connected', now: t0),
        'bg-window: enter link=connected');
  });

  test('consecutive windows pair independently', () {
    final tracker = BackgroundWindowTracker();
    tracker.onLifecycle('paused', link: 'ready', now: t0);
    tracker.onLifecycle('resumed',
        link: 'ready', now: t0.add(const Duration(seconds: 30)));
    expect(
        tracker.onLifecycle('paused',
            link: 'none', now: t0.add(const Duration(minutes: 5))),
        'bg-window: enter link=none');
    expect(
        tracker.onLifecycle('resumed',
            link: 'none', now: t0.add(const Duration(minutes: 5, seconds: 8))),
        'bg-window: exit away=8000ms link=none');
  });

  group('linkToken', () {
    test('maps the five link states onto the three-token vocabulary', () {
      expect(BackgroundWindowTracker.linkToken(BleLinkState.ready), 'ready');
      expect(BackgroundWindowTracker.linkToken(BleLinkState.connected),
          'connected');
      // Transitional states carry no live data path, so they read as none —
      // the adjacent `link:` lines keep the full state when it matters.
      expect(
          BackgroundWindowTracker.linkToken(BleLinkState.disconnected), 'none');
      expect(
          BackgroundWindowTracker.linkToken(BleLinkState.connecting), 'none');
      expect(BackgroundWindowTracker.linkToken(BleLinkState.disconnecting),
          'none');
    });
  });
}
