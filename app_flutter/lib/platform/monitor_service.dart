/// OpenSmartBatt — background-monitor service handle (design 0008).
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
/// Every platform is served by [NoopMonitorService] except Android; iOS needs a
/// different mechanism entirely (UIBackgroundModes — design 0009).
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

  /// The right implementation for the running platform.
  factory MonitorService.forPlatform() {
    if (Platform.isAndroid) return AndroidMonitorService();
    return NoopMonitorService();
  }
}

/// Does nothing. Used on iOS/desktop and in tests.
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
  void dispose() => _stop.close();
}

/// Talks to `MonitorService.kt` over `com.winepaster.openSmartBatt/monitor`.
class AndroidMonitorService implements MonitorService {
  AndroidMonitorService({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('com.winepaster.openSmartBatt/monitor') {
    _channel.setMethodCallHandler(_onCall);
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

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _stop.close();
  }
}
