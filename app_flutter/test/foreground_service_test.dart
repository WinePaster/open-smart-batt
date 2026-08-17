// The foreground service that keeps the process alive.
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
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

  // Android-shaped: these tests exercise the foreground-service strategy, and
  // the notify-driven keep-alive path must stay unreachable through it.
  @override
  bool get pacesKeepAliveInBackground => false;

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
  int pokeCalls = 0;

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
  Future<void> pokeKeepAlive() async => pokeCalls++;

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

/// Telemetry freshness, flippable in a microsecond.
///
/// The real implementation is [TelemetryController], whose stall threshold is
/// 8 s and whose check runs on a 2 s timer — exercising the notification's
/// three states through it would mean a test suite that waits out the field
/// thresholds. That is what the [TelemetryHealth] seam is for.
class _FakeHealth extends ChangeNotifier implements TelemetryHealth {
  bool _has = false;
  bool _stalled = false;
  DateTime? _at;

  @override
  bool get hasTelemetry => _has;

  @override
  bool get telemetryStalled => _stalled;

  @override
  DateTime? get lastTelemetryAt => _at;

  void set({bool? has, bool? stalled, DateTime? at}) {
    _has = has ?? _has;
    _stalled = stalled ?? _stalled;
    _at = at ?? _at;
    notifyListeners();
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
        titleConnecting: 'TC',
        titleStalled: 'TS',
        stopLabel: 'S',
        channelName: 'C',
        channelDescription: 'D',
      );
      ble.emitLink(BleLinkState.ready);
      await settle();

      expect(monitor.posted, isNotEmpty);
      // The FIRST post is "connecting": ready has arrived, telemetry has not.
      expect(monitor.posted.first.title, 'TC');
      expect(monitor.posted.first.stopLabel, 'S');
      expect(monitor.posted.first.channelName, 'C');

      ble.emitTelemetry(sampleAt(pvlt: 13.0));
      await settle();
      expect(monitor.posted.last.title, 'T');
    });
  });

  group('boot reconciliation', () {
    // A previous process can leave a foreground service running (task swiped
    // away, or engine dead while the service held the process up). Nothing else
    // ever stops it: `_updateMonitor` opens with
    // `if (shouldRun == _monitorRunning) return`, and in a fresh engine both
    // are false. Design 0038 §1.2(d).
    test('AndroidMonitorService asks the platform to stop on construction',
        () async {
      const channel = MethodChannel('test/monitor-reconcile');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return true;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));

      final svc = AndroidMonitorService(channel: channel);
      addTearDown(svc.dispose);
      await settle();

      expect(calls, ['stop'],
          reason: 'an orphan from the last process must not outlive launch');
    });

    test('a missing platform channel cannot take the launch down', () async {
      // No mock handler at all: the call raises MissingPluginException, which
      // `_invoke` swallows. Constructing must still succeed.
      const channel = MethodChannel('test/monitor-absent');
      final svc = AndroidMonitorService(channel: channel);
      addTearDown(svc.dispose);
      await settle();
    });
  });

  group('the notification tells the truth about the link', () {
    /// Wire a flippable health source in place of the real TelemetryController.
    Future<(AppServices, _StubBle, _FakeMonitor, _FakeHealth)> withHealth()
        async {
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      final s = await makeServices(ble, monitor);
      final health = _FakeHealth();
      s.connection.bindTelemetryHealth(health);
      s.connection.setNotificationStrings(
        title: 'LIVE',
        titleConnecting: 'CONNECTING',
        titleStalled: 'STALE',
        stopLabel: 'S',
        channelName: 'C',
        channelDescription: 'D',
      );
      return (s, ble, monitor, health);
    }

    test('ready with nothing received yet says "connecting", not "monitoring"',
        () async {
      // The state that made an orphaned service indistinguishable from a
      // healthy one: title "monitoring", body empty.
      final (s, ble, monitor, _) = await withHealth();
      addTearDown(s.dispose);

      ble.emitLink(BleLinkState.ready);
      await settle();

      expect(monitor.posted.last.title, 'CONNECTING');
      expect(monitor.posted.last.body, isEmpty);
    });

    test('a stall retitles and stamps the frozen reading with its clock time',
        () async {
      final (s, ble, monitor, health) = await withHealth();
      addTearDown(s.dispose);

      ble.emitLink(BleLinkState.ready);
      health.set(has: true);
      ble.emitTelemetry(sampleAt(pvlt: 13.4, soc: 85, tempC: 26));
      await settle();
      expect(monitor.posted.last.title, 'LIVE');
      expect(monitor.posted.last.body, '13.40 V · 85% · 26°C');

      final before = monitor.calls.length;
      health.set(stalled: true, at: DateTime(2026, 8, 5, 14, 32));
      await settle();

      expect(monitor.calls.length, greaterThan(before),
          reason: 'a state change must not wait out the 5 s throttle');
      expect(monitor.posted.last.title, 'STALE');
      expect(monitor.posted.last.body, '13.40 V · 85% · 26°C (14:32)');
    });

    test('recovery goes back to "monitoring" immediately', () async {
      final (s, ble, monitor, health) = await withHealth();
      addTearDown(s.dispose);

      ble.emitLink(BleLinkState.ready);
      health.set(has: true);
      ble.emitTelemetry(sampleAt(pvlt: 13.4));
      health.set(stalled: true, at: DateTime(2026, 8, 5, 14, 32));
      await settle();
      expect(monitor.posted.last.title, 'STALE');

      health.set(stalled: false);
      await settle();
      expect(monitor.posted.last.title, 'LIVE');
      expect(monitor.posted.last.body, isNot(contains('(')));
    });

    test('notifications that change nothing do not post', () async {
      // TelemetryController notifies on EVERY sample (1 Hz). Without the
      // edge-trigger this listener would post at that rate.
      final (s, ble, monitor, health) = await withHealth();
      addTearDown(s.dispose);

      ble.emitLink(BleLinkState.ready);
      await settle();
      // The first transition of a connection always posts (the previous link's
      // health is deliberately forgotten when the service starts), so let that
      // one land before counting.
      health.set(has: true);
      await settle();
      final before = monitor.calls.length;

      for (var i = 0; i < 20; i++) {
        health.set(has: true, stalled: false);
      }
      await settle();

      expect(monitor.calls.length, before,
          reason: '20 no-op notifications must produce 0 posts');
    });

    test('a link that never speaks is "connecting", never "no data"', () async {
      // lastSampleAt is SEEDED at ready, so a silent link also goes `stalled`
      // once the threshold passes. Reading stalled before hasTelemetry would
      // label it "no data" and hang a clock time on a reading that never was.
      final (s, ble, monitor, health) = await withHealth();
      addTearDown(s.dispose);

      ble.emitLink(BleLinkState.ready);
      health.set(has: false, stalled: true, at: DateTime(2026, 8, 5, 14, 32));
      await settle();

      expect(monitor.posted.last.title, 'CONNECTING');
      expect(monitor.posted.last.body, isEmpty);
    });
  });

  group('resume liveness probe', () {
    test('asks the device whether the link is still real', () async {
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      final s = await makeServices(ble, monitor);
      addTearDown(s.dispose);

      ble.emitLink(BleLinkState.ready);
      await settle();
      expect(ble.pokeCalls, 0);

      s.connection.onAppResumed(window: const Duration(milliseconds: 40));
      await settle();
      expect(ble.pokeCalls, 1);
    });

    test('does not probe when there is no link to probe', () async {
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      final s = await makeServices(ble, monitor);
      addTearDown(s.dispose);

      s.connection.onAppResumed(window: const Duration(milliseconds: 40));
      await settle();
      expect(ble.pokeCalls, 0);
      expect(ble.disconnectCalls, 0);
    });

    test('silence past the deadline drops the link', () async {
      // A suspension that ends in the OS reclaiming the link produces NO
      // disconnect event, so `ready` on resume is a claim. Design 0039 §3.1.
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      final s = await makeServices(ble, monitor);
      addTearDown(s.dispose);

      ble.emitLink(BleLinkState.ready);
      await settle();

      s.connection.onAppResumed(window: const Duration(milliseconds: 40));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(ble.disconnectCalls, 1,
          reason: 'the transport is dropped so the reconnect ladder can run');
    });

    test('one frame inside the window is enough to keep the link', () async {
      // 🔑 ANY telemetry, not "the rate is back to normal". Thawing flushes a
      // backlog all at once, so a rate test would misread recovery as failure.
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      final s = await makeServices(ble, monitor);
      addTearDown(s.dispose);

      ble.emitLink(BleLinkState.ready);
      await settle();

      s.connection.onAppResumed(window: const Duration(milliseconds: 40));
      ble.emitTelemetry(sampleAt(pvlt: 13.0));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(ble.disconnectCalls, 0);
    });

    test('the probe window is far wider than a healthy resume needs', () {
      // Measured p50 from `app resumed` to the next inbound frame: 0.29 s
      // (Android) / 0.34 s (iOS) across the corpus. Firing early costs a link
      // that was about to answer; waiting costs a few stale seconds.
      expect(ConnectionController.resumeProbeWindow,
          greaterThan(const Duration(seconds: 2)));
    });
  });

  group('formatStaleMonitorBody', () {
    test('stamps the clock time the reading was taken', () {
      expect(
          formatStaleMonitorBody(
              '13.4 V · 85%', DateTime(2026, 8, 5, 9, 7)),
          '13.4 V · 85% (09:07)');
    });

    test('an unknown time leaves the reading alone', () {
      // Inventing a "last updated" for a reading that never arrived is the
      // confusion TelemetryHealth.lastTelemetryAt exists to warn about.
      expect(formatStaleMonitorBody('13.4 V', null), '13.4 V');
    });

    test('stands alone when there is no reading to stamp', () {
      expect(formatStaleMonitorBody('', DateTime(2026, 8, 5, 14, 32)),
          '(14:32)');
    });
  });

  group('formatMonitorBody', () {
    test('renders voltage, charge and temperature', () {
      // Two decimals (FB-81): `0x19` decodes as `u16/100`, so 13.42 is a value
      // the register can hold, and the old one-decimal form printed it as 13.4
      // while the dashboard beside it said 13.42.
      expect(formatMonitorBody(sampleAt(pvlt: 13.42, soc: 85, tempC: 26)),
          '13.42 V · 85% · 26°C');
    });

    test('drops fields the unit does not send', () {
      // A super-capacitor reports no SOC at all. Showing "—%" for it would read
      // as a fault rather than as "not applicable".
      expect(formatMonitorBody(sampleAt(pvlt: 13.0)), '13.00 V');
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

  group('settings split: background monitoring vs screen-awake', () {
    test('background monitoring defaults on, screen-awake stays off', () {
      // These are different things and used to share one key. Monitoring must
      // default on (the stall is the out-of-box experience without it); the
      // wakelock must stay off (it burns the screen for a whole ride).
      const d = AppSettings.defaults;
      expect(d.backgroundMonitoring, isTrue);
      expect(d.keepScreenAwake, isFalse);
    });

    test('a pre-v8 row keeps its wakelock choice and gains monitoring', () {
      // The old column is reused for keepScreenAwake, so an upgrading user's
      // existing choice survives rather than being silently reset.
      final migrated = AppSettings.fromMap(const {
        'background_keep_alive': 1,
        // no 'background_monitoring' key: that is what a pre-v8 row looks like
      });
      expect(migrated.keepScreenAwake, isTrue);
      expect(migrated.backgroundMonitoring, isTrue);
    });
  });

  group('schema v8 migration (v7 → v8)', () {
    // This design was written against schema v6, but designs 0009/0010 took v6
    // and v7 on main first, so it was renumbered to v8 on merge. That makes
    // THIS the migration most worth testing: v0.6.9 shipped v7 to real users,
    // so `from < 8` is the branch that has to fire for them. The sibling test
    // above only exercises AppSettings.fromMap — it never touches ALTER TABLE.
    test('a v7 database gains background_monitoring, defaulting on', () async {
      // A real file: an in-memory DB is discarded on close, so the upgrade path
      // would never see the v7 data.
      final dir = await Directory.systemTemp.createTemp('osb_v8');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'v7.db');
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 7,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                auto_reconnect INTEGER NOT NULL DEFAULT 1,
                poll_interval_ms INTEGER NOT NULL DEFAULT 1000,
                background_keep_alive INTEGER NOT NULL DEFAULT 0,
                dark_theme INTEGER NOT NULL DEFAULT 1, theme_mode TEXT,
                lang TEXT NOT NULL DEFAULT 'zhHant',
                temp_unit TEXT NOT NULL DEFAULT 'celsius',
                auto_log INTEGER NOT NULL DEFAULT 1,
                raw_packet_log INTEGER NOT NULL DEFAULT 0,
                log_max_bytes INTEGER NOT NULL DEFAULT ${5 * 1024 * 1024}
              )''');
            await db.execute('''
              CREATE TABLE history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL, pvlt REAL, svlt REAL, ampere REAL,
                temperature INTEGER, dvol1 REAL, dvol2 REAL, dvol3 REAL,
                dvol4 REAL, soh INTEGER, mode INTEGER, twf INTEGER,
                serial TEXT, soc INTEGER, device_id TEXT, samples INTEGER,
                app_build TEXT
              )''');
            await db.execute('''
              CREATE TABLE diag_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL, direction TEXT NOT NULL,
                hex TEXT NOT NULL, note TEXT, device_id TEXT,
                session_id INTEGER, app_build TEXT
              )''');
            await db.execute('''
              CREATE TABLE saved_devices (
                id TEXT PRIMARY KEY, alias TEXT, name TEXT NOT NULL DEFAULT '',
                stale INTEGER NOT NULL DEFAULT 0,
                product_class TEXT NOT NULL DEFAULT 'unknown'
              )''');
          },
        ),
      );
      // A user who had deliberately turned the wakelock OFF.
      await legacy.insert('settings', {'id': 1, 'background_keep_alive': 0});
      await legacy.close();

      final upgraded =
          await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      addTearDown(upgraded.close);
      final row = (await upgraded.db.query('settings')).single;

      expect(row['background_monitoring'], 1,
          reason: 'upgrading users are exactly the ones hitting the stall');
      expect(row['background_keep_alive'], 0,
          reason: 'their separate wakelock choice must survive untouched');
    });
  });
}
