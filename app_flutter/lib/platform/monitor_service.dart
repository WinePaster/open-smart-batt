/// OpenSmartBatt — background-monitor service handle.
///
/// Thin Dart side of the app's only platform channel. On Android it drives a
/// `connectedDevice` foreground service whose sole job is to keep this process
/// at foreground importance while a pack is connected, so the screen going off
/// does not let Doze / App Standby freeze the BLE loop.
///
/// It carries no BLE state and issues no BLE calls: flutter_blue_plus binds its
/// channels to the main engine, so the existing Dart keep-alive keeps running
/// unchanged the moment the process stops being frozen. Everything here is
/// notification plumbing.
///
/// iOS is [IosMonitorService] (design 0047 Phase 1): no foreground service
/// exists there, and none is needed — `Info.plist` declares the
/// `bluetooth-central` background mode, under which each inbound GATT event
/// wakes the app for a short execution window. What iOS needs instead is a
/// different keep-alive strategy while backgrounded (notify-driven rather than
/// timer-driven), and this handle is where that strategy is DECLARED
/// ([MonitorService.pacesKeepAliveInBackground]) so the controller wiring
/// stays platform-free. Desktop and tests keep [NoopMonitorService].
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Text shown on the ongoing notification. Supplied by the caller so the
/// strings come from the app's own l10n rather than Android resources — the
/// in-app language override is independent of the device locale.
class MonitorNotification {
  const MonitorNotification({
    required this.title,
    required this.body,
    required this.stopLabel,
    required this.channelName,
    required this.channelDescription,
  });

  final String title;
  final String body;
  final String stopLabel;
  final String channelName;
  final String channelDescription;

  Map<String, String> toArgs() => {
        'title': title,
        'body': body,
        'stopLabel': stopLabel,
        'channelName': channelName,
        'channelDescription': channelDescription,
      };
}

/// Starts/stops the platform's background-monitor affordance.
abstract class MonitorService {
  /// Begin (or refresh) the foreground service with [notification].
  Future<void> start(MonitorNotification notification);

  /// Update the ongoing notification's text. Callers should throttle this;
  /// see [ConnectionController] for the 5 s cadence and why 1 Hz is wrong.
  Future<void> update(MonitorNotification notification);

  /// Stop the service and dismiss the notification.
  Future<void> stop();

  /// Fires when the user taps the notification's stop action (or the system
  /// reclaims the service), so the caller can drop the BLE link rather than
  /// leaving it orphaned behind a dismissed notification.
  Stream<void> get onStopRequested;

  /// Release the channel handler.
  void dispose();

  /// True when this platform's background strategy drives the BLE keep-alive
  /// off inbound notify events while the app is backgrounded (iOS under
  /// `bluetooth-central`, design 0047 Phase 1).
  ///
  /// 🔴 Android answers FALSE and must keep answering false: its foreground
  /// service holds the process at foreground importance, the 1 Hz timer never
  /// freezes, and the timer-driven path is the one every Android field capture
  /// was diagnosed against. `ConnectionController` consults this before ever
  /// touching `BleService.setNotifyDrivenKeepAlive`, so the Android code path
  /// is unreachable by construction, not merely unexercised.
  bool get pacesKeepAliveInBackground;

  /// The right implementation for the running platform.
  factory MonitorService.forPlatform() {
    if (Platform.isAndroid) return AndroidMonitorService();
    if (Platform.isIOS) return IosMonitorService();
    return NoopMonitorService();
  }
}

/// Does nothing. Used on desktop and in tests.
class NoopMonitorService implements MonitorService {
  final _stop = StreamController<void>.broadcast();

  @override
  Future<void> start(MonitorNotification notification) async {}

  @override
  Future<void> update(MonitorNotification notification) async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get onStopRequested => _stop.stream;

  @override
  bool get pacesKeepAliveInBackground => false;

  @override
  void dispose() => _stop.close();
}

/// iOS background-monitoring handle (design 0047 Phase 1).
///
/// Deliberately channel-free: iOS has no foreground service to start and no
/// ongoing notification to post, so [start]/[update]/[stop] only track whether
/// monitoring is ENGAGED (link online + setting on — the same condition that
/// runs the Android service). What iOS contributes instead is declared, not
/// executed, here:
///
///   * [pacesKeepAliveInBackground] — opts the controller into switching the
///     keep-alive to notify-driven pacing for the duration of a background
///     window (`BleService.setNotifyDrivenKeepAlive`).
///   * [engagements] — how many times monitoring engaged this process, the
///     one diagnostic count this object can own outright. Per-wakeup counts
///     live where the wakeups land: the transport's `bg-keepalive:` /
///     `exec gap` / `bg-window:` lines already ride the always-on diagnostics
///     path in the field-capture format Phase 0 established.
///
/// [onStopRequested] never fires: there is no notification for the user to
/// dismiss. The OS reclaiming the app is observed the way it always was — by
/// the resume probe finding a dead link (design 0039).
class IosMonitorService implements MonitorService {
  final _stop = StreamController<void>.broadcast();

  bool _engaged = false;
  int _engagements = 0;

  /// True between [start] and [stop] — background monitoring is on and a link
  /// is up. The keep-alive pacing additionally requires the app to actually BE
  /// in the background; that edge belongs to the lifecycle observer, so the
  /// controller combines the two rather than this object guessing at one.
  bool get engaged => _engaged;

  /// How many times monitoring engaged since this process started.
  int get engagements => _engagements;

  @override
  Future<void> start(MonitorNotification notification) async {
    if (!_engaged) _engagements++;
    _engaged = true;
  }

  @override
  Future<void> update(MonitorNotification notification) async {}

  @override
  Future<void> stop() async {
    _engaged = false;
  }

  @override
  Stream<void> get onStopRequested => _stop.stream;

  @override
  bool get pacesKeepAliveInBackground => true;

  @override
  void dispose() => _stop.close();
}

/// Talks to `MonitorService.kt` over `com.winepaster.openSmartBatt/monitor`.
class AndroidMonitorService implements MonitorService {
  AndroidMonitorService({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('com.winepaster.openSmartBatt/monitor') {
    _channel.setMethodCallHandler(_onCall);
    // Boot reconciliation. A previous process may have left a service running:
    // its task was swiped away, or its engine died while the foreground service
    // held the process up. Nothing else would ever stop it — `_updateMonitor`
    // opens with `if (shouldRun == _monitorRunning) return`, and in a fresh
    // engine both are false, so it never reaches the `stop()` branch.
    //
    // Unconditional, because at construction this process is definitionally not
    // connected: the app never auto-connects at launch (every `connect()` /
    // `connectToSaved()` caller is a user tap). With no orphan this is a no-op.
    //
    // Here rather than in ConnectionController on purpose: "the platform may
    // hold a service from a previous process" is a platform fact, and
    // NoopMonitorService has no such problem. Design 0038 §5.2.
    unawaited(_invoke('stop'));
  }

  final MethodChannel _channel;
  final _stop = StreamController<void>.broadcast();

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'onStopRequested' && !_stop.isClosed) _stop.add(null);
    return null;
  }

  /// Fire-and-forget, swallowing platform errors.
  ///
  /// A failed channel call must never take the app down or block the BLE path:
  /// losing the foreground service degrades us to the old behaviour (the stall
  /// banner still catches it), which is a far better outcome than an unhandled
  /// exception. Mirrors how `_updateWakelock` treats wakelock_plus.
  Future<void> _invoke(String method, [Map<String, String>? args]) async {
    try {
      await _channel.invokeMethod<bool>(method, args);
    } on PlatformException {
      // Service refused to start (e.g. POST_NOTIFICATIONS edge cases).
    } on MissingPluginException {
      // No channel on this build/host (unit tests, older embedding).
    }
  }

  @override
  Future<void> start(MonitorNotification notification) =>
      _invoke('start', notification.toArgs());

  @override
  Future<void> update(MonitorNotification notification) =>
      _invoke('update', notification.toArgs());

  @override
  Future<void> stop() => _invoke('stop');

  @override
  Stream<void> get onStopRequested => _stop.stream;

  /// 🔴 False, permanently: the foreground service keeps the process — and the
  /// 1 Hz keep-alive timer — running, so the notify-driven path has nothing to
  /// contribute and switching to it would CHANGE Android behaviour (design
  /// 0047's hard condition 1 forbids exactly that).
  @override
  bool get pacesKeepAliveInBackground => false;

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _stop.close();
  }
}
