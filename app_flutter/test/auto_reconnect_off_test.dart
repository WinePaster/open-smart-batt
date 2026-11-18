// 2026-11-18 user report: 「自動重連」 turned off, yet the battery came back.
//
// This file pins the ConnectionController half: turning the setting OFF
// withdraws what is already pending — the iOS hand-off registered with
// CoreBluetooth (which no rung of ours re-reads before the OS delivers it) and
// a scheduled backoff rung. The multi-link half (the home tab adopting units on
// presence) is pinned in `multi_link_controller_test.dart`, group
// '2026-11-18: 自動重連 off'.
//
// Harness: the same shape as `autoconnect_watchdog_background_test.dart`
// (file-private there, so copied — trimmed to what these tests use).
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';

class _CapturingLogRepo implements LogRepo {
  final List<String> notes = <String>[];

  @override
  Future<int> insertLog(LogEntry entry, {int? maxBytes}) async {
    notes.add(entry.note ?? '');
    return notes.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubSettingsRepo implements SettingsRepo {
  _StubSettingsRepo({this.stored = AppSettings.defaults});

  /// What `settings.load()` reads back — the user's saved choice.
  final AppSettings stored;

  @override
  Future<AppSettings> loadSettings() async => stored;

  @override
  Future<void> saveSettings(AppSettings settings) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  int connectCalls = 0;
  int autoConnectCalls = 0;
  int disconnectCalls = 0;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<String> get diagnostics => const Stream<String>.empty();
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();
  @override
  bool get isScanning => false;
  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    connectCalls++;
    if (autoConnect) autoConnectCalls++;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

class _Harness {
  _Harness({AppSettings stored = AppSettings.defaults})
      : ble = _FakeBle(),
        logs = _CapturingLogRepo(),
        settings = SettingsController(_StubSettingsRepo(stored: stored)) {
    conn = ConnectionController(ble, settings: settings, logs: logs);
  }

  final _FakeBle ble;
  final _CapturingLogRepo logs;
  final SettingsController settings;
  late final ConnectionController conn;
  bool _disposed = false;

  Iterable<String> get standDownLines =>
      logs.notes.where((n) => n.startsWith('auto-reconnect: stood down'));

  /// A healthy link that dropped. On a test host the platform is not iOS, so
  /// this leaves a backoff rung scheduled ([ConnectionController.isRetrying]).
  void healthyDrop(FakeAsync async, {String id = 'AA'}) {
    unawaited(conn.connect(id));
    async.flushMicrotasks();
    for (final s in [
      BleLinkState.connecting,
      BleLinkState.connected,
      BleLinkState.ready,
      BleLinkState.disconnected,
    ]) {
      ble.emitLink(s);
      async.flushMicrotasks();
    }
  }

  /// [healthyDrop], then the iOS hand-off by hand (its platform gate is
  /// unreachable here — see `armAutoConnect`'s doc).
  void armAfterHealthyDrop(FakeAsync async) {
    healthyDrop(async);
    conn.armAutoConnect();
    async.flushMicrotasks();
  }

  /// A cold start after iOS reclaimed a process that had armed a hand-off:
  /// `AppServices.create` calls [ConnectionController.restoreArm] before
  /// `settings.load()`.
  void coldStartWithArm(FakeAsync async, {String id = 'AA'}) {
    conn.restoreArm(AutoConnectArm(
        deviceId: id,
        armedAt: DateTime.now().subtract(const Duration(minutes: 10))));
    async.flushMicrotasks();
  }

  void turnOff(FakeAsync async) {
    unawaited(settings.setAutoReconnect(false));
    async.flushMicrotasks();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    conn.dispose();
    unawaited(ble.dispose());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an armed iOS hand-off is cancelled when the setting goes off', () {
    fakeAsync((async) {
      final h = _Harness();
      h.armAfterHealthyDrop(async);
      expect(h.conn.isAutoConnectArmed, isTrue);
      final disconnectsBefore = h.ble.disconnectCalls;

      h.turnOff(async);

      expect(h.conn.isAutoConnectArmed, isFalse);
      expect(h.ble.disconnectCalls, disconnectsBefore + 1,
          reason: 'the pending OS connect is withdrawn');
      expect(h.standDownLines.single, contains('armed=true'));

      // The watchdog that would have run is gone with it: no timeout error,
      // no further attempt.
      final connectsBefore = h.ble.connectCalls;
      async.elapse(ConnectionController.autoConnectWatchdog * 2);
      expect(h.conn.lastErrorUnattributed, isNull,
          reason: 'the user asked for this; nothing failed');
      expect(h.ble.connectCalls, connectsBefore);
      h.dispose();
    });
  });

  test('a scheduled backoff rung is withdrawn when the setting goes off', () {
    fakeAsync((async) {
      final h = _Harness();
      h.healthyDrop(async);
      expect(h.conn.isRetrying, isTrue);
      expect(h.conn.reconnectAttempts, greaterThan(0));
      final connectsBefore = h.ble.connectCalls;

      h.turnOff(async);

      expect(h.conn.isRetrying, isFalse);
      expect(h.conn.reconnectAttempts, 0,
          reason: 'no "attempt N of 5" left on screen');
      expect(h.standDownLines.single, contains('retrying=true'));
      async.elapse(const Duration(minutes: 5));
      expect(h.ble.connectCalls, connectsBefore);
      h.dispose();
    });
  });

  test('nothing pending ⇒ turning it off writes nothing and cancels nothing',
      () {
    fakeAsync((async) {
      final h = _Harness();
      h.turnOff(async);
      expect(h.standDownLines, isEmpty);
      expect(h.ble.disconnectCalls, 0);
      h.dispose();
    });
  });

  test('turning it back on does not re-arm what was withdrawn', () {
    fakeAsync((async) {
      final h = _Harness();
      h.armAfterHealthyDrop(async);
      h.turnOff(async);
      final connectsBefore = h.ble.connectCalls;
      unawaited(h.settings.setAutoReconnect(true));
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 5));
      expect(h.conn.isAutoConnectArmed, isFalse);
      expect(h.ble.connectCalls, connectsBefore);
      h.dispose();
    });
  });

  group('a hand-off adopted at cold start (design 0060 restoration)', () {
    test('a launch whose saved setting is off withdraws it at settings load',
        () {
      fakeAsync((async) {
        final h = _Harness(
            stored: AppSettings.defaults.copyWith(autoReconnect: false));
        h.coldStartWithArm(async);
        expect(h.ble.autoConnectCalls, 1,
            reason: 'restoreArm runs before load, on the default (on)');
        unawaited(h.settings.load());
        async.flushMicrotasks();
        expect(h.ble.disconnectCalls, 1,
            reason: 'the load is the on → off edge');
        expect(h.standDownLines.single, contains('adopted=true'));
        h.dispose();
      });
    });

    test('turned off after the cold-start window: still withdrawn', () {
      fakeAsync((async) {
        final h = _Harness();
        h.coldStartWithArm(async);
        async.elapse(
            ConnectionController.coldReconcileGrace + const Duration(seconds: 1));
        h.turnOff(async);
        expect(h.ble.disconnectCalls, 1);
        expect(h.standDownLines.single, contains('adopted=true'));
        h.dispose();
      });
    });

    test('a restored link that already came up is left alone', () {
      fakeAsync((async) {
        final h = _Harness();
        h.coldStartWithArm(async);
        for (final s in [
          BleLinkState.connecting,
          BleLinkState.connected,
          BleLinkState.ready,
        ]) {
          h.ble.emitLink(s);
          async.flushMicrotasks();
        }
        h.turnOff(async);
        expect(h.ble.disconnectCalls, 0);
        expect(h.standDownLines, isEmpty);
        h.dispose();
      });
    });
  });
}
