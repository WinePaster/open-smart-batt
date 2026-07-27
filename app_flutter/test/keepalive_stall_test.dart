// Keep-alive robustness + telemetry stall detection.
//
// Field evidence (feedback_log/2026.07.27, twice; and again on 2026-07-06):
// Android suspends the app and BOTH directions stop together for minutes, then
// resume with a backlog burst — RX per minute went 828 → 248 → 0 → 1666 → 832,
// with the 15 s write timeout surfacing only at the moment of resume and NO
// disconnect event. The link was never down; the app was frozen.
//
// Two consequences that these tests lock down:
//   * the 1 Hz timer must not queue a write per stalled second, and
//   * the dashboard must say the readings are frozen instead of showing stale
//     numbers as if they were live.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// BleService stub whose streams a test can drive, and whose writes can be made
/// to hang the way a suspended app makes them hang.
class _StubBle extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  /// Completed by the test to release a "hung" write.
  Completer<void>? hold;
  int writeCalls = 0;

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  // Everything below keeps the constructor off the (unsupported) plugin.
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);
  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> writeCommand(List<int> bytes, {Duration? timeout}) async {
    writeCalls++;
    final h = hold;
    if (h != null) await h.future;
  }

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  Future<AppServices> makeServices(_StubBle ble) async {
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    return AppServices.create(appDatabase: db, ble: ble);
  }

  group('keep-alive write budget', () {
    test('the timeout is a few poll periods, not fifteen', () {
      // 15 s (the plugin default) is 15 ticks of a 1 Hz poll: the write sat
      // there long after the tick was useful and the error only surfaced on
      // resume, which is how a 2.5-minute freeze looked like a BLE fault.
      expect(BleService.keepAliveWriteTimeout,
          lessThan(BleService.keepAliveInterval * 15));
      expect(BleService.keepAliveWriteTimeout,
          greaterThan(BleService.keepAliveInterval * 2));
    });

    test('the stall threshold is several poll periods so it cannot flap', () {
      expect(BleService.telemetryStallThreshold,
          greaterThan(BleService.keepAliveInterval * 3));
    });
  });

  group('telemetry stall detection', () {
    // Millisecond thresholds so the REAL transition is exercised rather than
    // waiting out the 8 s field value.
    TelemetryController fastStallController(_StubBle ble, AppServices s) =>
        TelemetryController(
          ble,
          settings: s.settings,
          history: s.historyRepo,
          logs: s.logRepo,
          stallThreshold: const Duration(milliseconds: 60),
          stallCheckInterval: const Duration(milliseconds: 20),
        );

    test('a ready link whose frames stop goes stale, then recovers', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      final tele = fastStallController(ble, s);
      addTearDown(() async {
        tele.dispose();
        await s.dispose();
      });

      ble.emitLink(BleLinkState.ready);
      ble.emitTelemetry(TelemetrySample(timestamp: DateTime.now(), pvlt: 12.5));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(tele.telemetryStalled, isFalse);

      // Frames stop arriving — the link never drops, exactly as in the field.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(tele.telemetryStalled, isTrue,
          reason: 'frozen readings must be flagged, not shown as live');

      // The backlog lands on resume.
      ble.emitTelemetry(TelemetrySample(timestamp: DateTime.now(), pvlt: 12.6));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(tele.telemetryStalled, isFalse, reason: 'recovers on the next frame');
    });

    test('a stall is never reported before the link is ready', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      final tele = fastStallController(ble, s);
      addTearDown(() async {
        tele.dispose();
        await s.dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(tele.telemetryStalled, isFalse);
      expect(tele.telemetryAge, isNull);
    });

    test('disconnect clears the stall state', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      final tele = fastStallController(ble, s);
      addTearDown(() async {
        tele.dispose();
        await s.dispose();
      });

      ble.emitLink(BleLinkState.ready);
      ble.emitTelemetry(TelemetrySample(timestamp: DateTime.now(), pvlt: 12.5));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(tele.telemetryStalled, isTrue);

      ble.emitLink(BleLinkState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(tele.telemetryStalled, isFalse,
          reason: 'a disconnect has its own empty state; it is not a stall');
      expect(tele.telemetryAge, isNull,
          reason: 'no link means no age to report, not a zero age');
    });
  });
}
