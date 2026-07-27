// design 0008 — the foreground service that keeps the process alive.
//
// The stall these lock down is the one recorded in keepalive_stall_test.dart:
// with the screen off Android freezes the process, the 1 Hz keep-alive stops
// firing and RX/min goes 828 -> 248 -> 0 -> 1666 -> 832 with NO disconnect
// event. Detection shipped first (the stale banner); this is the part that
// stops it happening.
//
// What is NOT covered here: whether the OS actually keeps us unfrozen. That is
// only answerable on a real phone (see 0008 §5 V1-V6). These tests cover the
// decisions we can pin down in Dart — when the service starts and stops, that
// the notification is throttled, and that a denied permission cannot silently
// kill monitoring.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/platform/platform.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Records what the platform channel would have been asked to do.
class _FakeMonitor implements MonitorService {
  final List<String> calls = [];
  final List<MonitorNotification> posted = [];
  final _stop = StreamController<void>.broadcast();

  bool get running =>
      calls.isNotEmpty && calls.lastWhere((c) => c != 'update') == 'start';

  @override
  Future<void> start(MonitorNotification n) async {
    calls.add('start');
    posted.add(n);
  }

  @override
  Future<void> update(MonitorNotification n) async {
    calls.add('update');
    posted.add(n);
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Stream<void> get onStopRequested => _stop.stream;

  /// Simulate the user tapping "stop" on the notification.
  void requestStop() => _stop.add(null);

  @override
  void dispose() => _stop.close();
}

class _StubBle extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  int notificationPermissionCalls = 0;
  int disconnectCalls = 0;

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

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
  Future<void> ensureNotificationPermission() async {
    notificationPermissionCalls++;
  }

  @override
  Future<void> disconnect() async => disconnectCalls++;

  @override
  Future<void> writeCommand(List<int> bytes, {Duration? timeout}) async {}

  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);
  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

/// Let the controllers' async work (including the diagnostic-log writes) land.
///
/// A microtask hop is not enough: `_event` fires an unawaited DB insert, and if
/// the test tears the database down before it completes the whole case fails on
/// "database has already been closed" rather than on anything real.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

TelemetrySample sampleAt({double? pvlt, int? soc, int? tempC}) =>
    TelemetrySample.empty().copyWith(
      pvlt: pvlt,
      socPercent: soc,
      temperatureC: tempC,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  Future<AppServices> makeServices(_StubBle ble, _FakeMonitor monitor) async {
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    return AppServices.create(appDatabase: db, ble: ble, monitor: monitor);
  }

  group('service lifecycle follows the link', () {
    test('starts on ready and stops on disconnect', () async {
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      final s = await makeServices(ble, monitor);
      addTearDown(s.dispose);

      expect(monitor.calls, isEmpty, reason: 'nothing runs before a link');

      ble.emitLink(BleLinkState.ready);
      await settle();
      expect(s.connection.monitorRunning, isTrue);
      expect(monitor.calls, contains('start'));

      ble.emitLink(BleLinkState.disconnected);
      await settle();
      expect(s.connection.monitorRunning, isFalse);
      expect(monitor.calls.last, 'stop');
    });

    test('does not start when the user turned monitoring off', () async {
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      final s = await makeServices(ble, monitor);
      addTearDown(s.dispose);

      await s.settings.setBackgroundMonitoring(false);
      ble.emitLink(BleLinkState.ready);
      await settle();

      expect(s.connection.monitorRunning, isFalse);
      expect(monitor.calls, isNot(contains('start')));
    });

    test('toggling the setting off mid-connection stops the service', () async {
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      final s = await makeServices(ble, monitor);
      addTearDown(s.dispose);

      ble.emitLink(BleLinkState.ready);
      await settle();
      expect(s.connection.monitorRunning, isTrue);

      await s.settings.setBackgroundMonitoring(false);
      await settle();
      expect(s.connection.monitorRunning, isFalse);
      expect(monitor.calls.last, 'stop');
    });

    test('the stop action drops the BLE link', () async {
      // Otherwise the user dismisses the notification and the app keeps a
      // connection open with nothing on screen to reveal it.
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      final s = await makeServices(ble, monitor);
      addTearDown(s.dispose);

      ble.emitLink(BleLinkState.ready);
      await settle();

      monitor.requestStop();
      await settle();
      expect(ble.disconnectCalls, greaterThan(0));
      expect(s.connection.monitorRunning, isFalse);
    });
  });

  group('notification', () {
    test('is throttled well below the 1 Hz telemetry rate', () {
      // Posting once per sample is a measurable battery cost and the system
      // rate-limits it anyway, so the extra posts would be dropped regardless.
      expect(ConnectionController.notificationInterval,
          greaterThan(BleService.keepAliveInterval * 3));
    });

    test('does not post once per sample', () async {
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      final s = await makeServices(ble, monitor);
      addTearDown(s.dispose);

      ble.emitLink(BleLinkState.ready);
      await settle();

      for (var i = 0; i < 10; i++) {
        ble.emitTelemetry(sampleAt(pvlt: 13.0 + i / 10, soc: 80 + i));
        await settle();
      }

      final updates = monitor.calls.where((c) => c == 'update').length;
      expect(updates, lessThan(10),
          reason: '10 samples inside one throttle window must not be 10 posts');
    });

    test('carries the localized strings it was handed', () async {
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      final s = await makeServices(ble, monitor);
      addTearDown(s.dispose);

      s.connection.setNotificationStrings(
        title: 'T',
        stopLabel: 'S',
        channelName: 'C',
        channelDescription: 'D',
      );
      ble.emitLink(BleLinkState.ready);
      await settle();

      expect(monitor.posted, isNotEmpty);
      expect(monitor.posted.first.title, 'T');
      expect(monitor.posted.first.stopLabel, 'S');
      expect(monitor.posted.first.channelName, 'C');
    });
  });

  group('formatMonitorBody', () {
    test('renders voltage, charge and temperature', () {
      expect(formatMonitorBody(sampleAt(pvlt: 13.42, soc: 85, tempC: 26)),
          '13.4 V · 85% · 26°C');
    });

    test('drops fields the unit does not send', () {
      // A super-capacitor reports no SOC (design 0007). Showing "—%" for it
      // would read as a fault rather than as "not applicable".
      expect(formatMonitorBody(sampleAt(pvlt: 13.0)), '13.0 V');
      expect(formatMonitorBody(sampleAt()), '');
    });
  });

  group('permissions', () {
    test('a denied POST_NOTIFICATIONS cannot stop the service', () async {
      // ensureNotificationPermission returns void precisely so no caller can
      // gate on it; the watch must survive a user tapping "Don't allow".
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      final s = await makeServices(ble, monitor);
      addTearDown(s.dispose);

      ble.emitLink(BleLinkState.ready);
      await settle();

      expect(ble.notificationPermissionCalls, 1, reason: 'it is still asked');
      expect(monitor.calls, contains('start'), reason: 'and it starts anyway');
      expect(s.connection.monitorRunning, isTrue);
    });
  });

  group('settings split (design 0008 §3.5)', () {
    test('background monitoring defaults on, screen-awake stays off', () {
      // These are different things and used to share one key. Monitoring must
      // default on (the stall is the out-of-box experience without it); the
      // wakelock must stay off (it burns the screen for a whole ride).
      const d = AppSettings.defaults;
      expect(d.backgroundMonitoring, isTrue);
      expect(d.keepScreenAwake, isFalse);
    });

    test('a pre-v6 row keeps its wakelock choice and gains monitoring', () {
      // The old column is reused for keepScreenAwake, so an upgrading user's
      // existing choice survives rather than being silently reset.
      final migrated = AppSettings.fromMap(const {
        'background_keep_alive': 1,
        // no 'background_monitoring' key: that is what a pre-v6 row looks like
      });
      expect(migrated.keepScreenAwake, isTrue);
      expect(migrated.backgroundMonitoring, isTrue);
    });
  });
}
