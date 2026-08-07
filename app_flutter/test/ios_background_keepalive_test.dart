// design 0047 Phase 1 — notify-driven keep-alive for iOS background windows.
//
// Three claims, matching the three hard conditions the Phase-1 merge ruling
// attached:
//
//   1. ANDROID IS UNREACHABLE. The pacing gate runs through
//      `MonitorService.pacesKeepAliveInBackground`, which only
//      `IosMonitorService` answers true — so with an Android-shaped monitor
//      the transport never leaves timer-driven mode, whatever the lifecycle
//      does. Zero behaviour change is structural, not situational.
//   2. THE DEBOUNCE HOLDS. A notify may carry a keep-alive only when the last
//      SUCCESSFUL write is a full interval old, so the paced cadence can never
//      exceed the 1 Hz the foreground timer already produces.
//   3. FB-53 DOES NOT COME BACK (R2). A backlog flushed on thaw lands as many
//      notifies inside one instant; the caller's in-flight check plus the
//      debounce make that ONE write, not one per queued event. The pure
//      policy half of that is pinned here; the in-flight half is the same
//      re-entrancy guard `keepalive_stall_test.dart` already locks down.
//
// Clock-free throughout: the pacer takes `now`, so no test waits out a real
// interval — the same reason ExecGapTracker and BackgroundWindowTracker are
// built the way they are.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/platform/platform.dart';
import 'package:open_smart_batt/state/state.dart';

class _StubSettingsRepo implements SettingsRepo {
  @override
  Future<AppSettings> loadSettings() async => AppSettings.defaults;

  @override
  Future<void> saveSettings(AppSettings settings) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Minimal link-state source; keeps the constructor off the plugin. The
/// pacing methods themselves are deliberately NOT overridden — the controller
/// tests below assert against the real `setNotifyDrivenKeepAlive` /
/// `notifyDrivenKeepAlive` implementation.
class _StubBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  String? get connectedDeviceId => 'STUB-DEV';

  @override
  Future<void> ensureNotificationPermission() async {}

  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

/// The Android/desktop shape: a monitor whose strategy does NOT pace.
class _NonPacingMonitor implements MonitorService {
  final _stop = StreamController<void>.broadcast();

  @override
  Future<void> start(MonitorNotification n) async {}

  @override
  Future<void> update(MonitorNotification n) async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get onStopRequested => _stop.stream;

  @override
  bool get pacesKeepAliveInBackground => false;

  @override
  void dispose() => _stop.close();
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime(2026, 8, 7, 12, 0, 0);

  group('NotifyKeepAlivePacer — debounce policy', () {
    test('inactive: never sends, counts nothing', () {
      final p = NotifyKeepAlivePacer();
      expect(p.shouldSend(lastWriteOk: null, now: t0), isFalse);
      expect(p.sends, 0);
    });

    test('active with no successful write yet: sends immediately', () {
      // The window may open right after a thaw whose last write predates the
      // link; starving the device while waiting for a baseline would be the
      // exact failure the pacer exists to prevent.
      final p = NotifyKeepAlivePacer()..setActive(true, t0);
      expect(p.shouldSend(lastWriteOk: null, now: t0), isTrue);
    });

    test('a write younger than the interval suppresses the send', () {
      final p = NotifyKeepAlivePacer()..setActive(true, t0);
      expect(
        p.shouldSend(
          lastWriteOk: t0,
          now: t0.add(const Duration(milliseconds: 400)),
        ),
        isFalse,
        reason: 'the paced cadence must never exceed the timer cadence',
      );
    });

    test('a write one full interval old releases the next send', () {
      final p = NotifyKeepAlivePacer()..setActive(true, t0);
      expect(
        p.shouldSend(
          lastWriteOk: t0,
          now: t0.add(NotifyKeepAlivePacer.defaultMinInterval),
        ),
        isTrue,
      );
    });

    test('a thawed backlog with a stale write releases exactly one send once '
        'the in-flight rule is applied', () {
      // FB-53 / R2. Backlogged notifies all land at the same wall-clock "now"
      // with the same stale lastWriteOk. The pacer alone would say yes to each
      // — which is why the CALLER asks only when no write is in flight, and
      // `_sendKeepAlive` raises its in-flight flag synchronously before its
      // first await. This test pins the division of labour: the pacer's yes is
      // repeatable (a), so the in-flight guard is load-bearing (b), exactly as
      // `_onNotify` composes them.
      final stale = t0.subtract(const Duration(minutes: 3));
      final p = NotifyKeepAlivePacer()..setActive(true, t0);
      // (a) Without the guard the pacer would fire per event...
      expect(p.shouldSend(lastWriteOk: stale, now: t0), isTrue);
      expect(p.shouldSend(lastWriteOk: stale, now: t0), isTrue);
      // (b) ...and with it the second ask never happens; once the ONE write
      // succeeds, the refreshed timestamp suppresses the rest of the burst.
      expect(p.shouldSend(lastWriteOk: t0, now: t0), isFalse);
    });

    test('setActive is idempotent and only a closing window reports', () {
      final p = NotifyKeepAlivePacer();
      expect(p.setActive(false, t0), isNull, reason: 'off → off: no window');
      expect(p.setActive(true, t0), isNull, reason: 'opening reports nothing');
      expect(p.setActive(true, t0), isNull, reason: 'on → on: no double-open');
      p.shouldSend(lastWriteOk: null, now: t0);
      final line = p.setActive(false, t0.add(const Duration(seconds: 90)));
      expect(line, 'bg-keepalive: window=90000ms paced=1');
      expect(p.setActive(false, t0), isNull, reason: 'off → off again');
    });

    test('a new window starts its count from zero', () {
      final p = NotifyKeepAlivePacer()..setActive(true, t0);
      p.shouldSend(lastWriteOk: null, now: t0);
      p.setActive(false, t0);
      p.setActive(true, t0);
      expect(p.setActive(false, t0), 'bg-keepalive: window=0ms paced=0');
    });

    test('the paced interval IS the timer interval', () {
      // Reproduce the existing cadence from a different trigger — not invent a
      // new one. The two constants live in different files only because the
      // pacer must not import the service.
      expect(NotifyKeepAlivePacer.defaultMinInterval,
          BleService.keepAliveInterval);
    });
  });

  group('platform dispatch — who may switch the trigger', () {
    test('only IosMonitorService opts in', () {
      final ios = IosMonitorService();
      final noop = NoopMonitorService();
      addTearDown(ios.dispose);
      addTearDown(noop.dispose);
      expect(ios.pacesKeepAliveInBackground, isTrue);
      expect(noop.pacesKeepAliveInBackground, isFalse);
      // AndroidMonitorService's own false is asserted in
      // foreground_service_test.dart's channel harness; the abstract getter's
      // doc comment marks it 🔴 load-bearing.
    });

    test('IosMonitorService tracks engagement without any platform channel',
        () async {
      final ios = IosMonitorService();
      addTearDown(ios.dispose);
      const n = MonitorNotification(
          title: '', body: '', stopLabel: '', channelName: '',
          channelDescription: '');
      expect(ios.engaged, isFalse);
      await ios.start(n);
      expect(ios.engaged, isTrue);
      await ios.start(n);
      expect(ios.engagements, 1, reason: 'a refresh is not a re-engagement');
      await ios.stop();
      expect(ios.engaged, isFalse);
      await ios.start(n);
      expect(ios.engagements, 2);
      await ios.stop();
    });
  });

  group('controller wiring — when the transport actually switches', () {
    late _StubBle ble;
    late SettingsController settings;
    late ConnectionController conn;

    Future<void> build(MonitorService monitor) async {
      ble = _StubBle();
      settings = SettingsController(_StubSettingsRepo());
      await settings.load();
      conn = ConnectionController(ble, settings: settings, monitor: monitor);
      addTearDown(() async {
        conn.dispose();
        await ble.dispose();
      });
    }

    test('iOS: backgrounding while monitored hands the keep-alive to the '
        'notify path, resuming hands it back', () async {
      await build(IosMonitorService());
      ble.emitLink(BleLinkState.ready);
      await settle();
      expect(ble.notifyDrivenKeepAlive, isFalse,
          reason: 'foreground stays timer-driven — FB-53-era behaviour');

      conn.logAppLifecycle('paused');
      expect(ble.notifyDrivenKeepAlive, isTrue);

      conn.logAppLifecycle('resumed');
      expect(ble.notifyDrivenKeepAlive, isFalse,
          reason: 'the resume probe and the timer own the foreground');
    });

    test('iOS: backgrounding with no link does not arm pacing', () async {
      await build(IosMonitorService());
      conn.logAppLifecycle('paused');
      expect(ble.notifyDrivenKeepAlive, isFalse,
          reason: 'no monitor engagement without a ready link');
      conn.logAppLifecycle('resumed');
    });

    test('iOS: turning the setting off stands pacing down mid-window',
        () async {
      await build(IosMonitorService());
      ble.emitLink(BleLinkState.ready);
      await settle();
      conn.logAppLifecycle('paused');
      expect(ble.notifyDrivenKeepAlive, isTrue);

      await settings.setBackgroundMonitoring(false);
      await settle();
      expect(ble.notifyDrivenKeepAlive, isFalse);
    });

    test('iOS: a drop mid-window disarms; the reconnect re-arms', () async {
      await build(IosMonitorService());
      ble.emitLink(BleLinkState.ready);
      await settle();
      conn.logAppLifecycle('paused');
      expect(ble.notifyDrivenKeepAlive, isTrue);

      ble.emitLink(BleLinkState.disconnected);
      await settle();
      expect(ble.notifyDrivenKeepAlive, isFalse,
          reason: 'a dead link has no notify path to pace');

      ble.emitLink(BleLinkState.ready);
      await settle();
      expect(ble.notifyDrivenKeepAlive, isTrue,
          reason: 'an auto-reconnect during the window resumes recording');
    });

    test('Android-shaped monitor: the notify path is unreachable', () async {
      // Hard condition 1. Same lifecycle, same link states, same settings —
      // the only difference is the monitor's declared strategy, and that alone
      // must keep the transport timer-driven throughout.
      await build(_NonPacingMonitor());
      ble.emitLink(BleLinkState.ready);
      await settle();
      conn.logAppLifecycle('paused');
      expect(ble.notifyDrivenKeepAlive, isFalse);
      conn.logAppLifecycle('resumed');
      ble.emitLink(BleLinkState.disconnected);
      await settle();
      expect(ble.notifyDrivenKeepAlive, isFalse);
    });
  });

  group('transport surface', () {
    test('setNotifyDrivenKeepAlive reports the closed window on diagnostics',
        () async {
      final ble = _StubBle();
      addTearDown(ble.dispose);
      final lines = <String>[];
      final sub = ble.diagnostics.listen(lines.add);
      addTearDown(sub.cancel);

      ble.setNotifyDrivenKeepAlive(true);
      expect(ble.notifyDrivenKeepAlive, isTrue);
      ble.setNotifyDrivenKeepAlive(true); // idempotent — no spurious line
      ble.setNotifyDrivenKeepAlive(false);
      ble.setNotifyDrivenKeepAlive(false);
      await settle();

      expect(lines, hasLength(1));
      expect(lines.single, startsWith('bg-keepalive: window='));
      expect(lines.single, endsWith('paced=0'));
    });
  });
}
