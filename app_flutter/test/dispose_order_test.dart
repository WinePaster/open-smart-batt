// AppServices teardown ordering.
//
// Found 2026-08-04 while building the watchface tests: `dispose()` used to
// dispose the controllers FIRST and drain [PendingWrites] after. But an
// in-flight write can end by calling back into a controller —
// `DeviceController.touch()` / `setProductClass()` both finish with
// `load()` → `notifyListeners()` — and on a disposed ChangeNotifier that is
// a "used after being disposed" error. The window only opens when a write is
// in flight at teardown, which is exactly the ordinary case: `touch()` fires
// on every telemetry sample for a saved, connected device.
//
// The fix reorders to BLE → drain → controllers → DB: the event sources stop
// first (nothing new is queued), the drain then completes with the
// controllers still alive, and the drain-before-close invariant that kills
// `database_closed` (see PendingWrites) is untouched.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/app_services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Minimal stub — the real [BleService] touches the plugin, which does not
/// exist on the test platform. Same shape as class_resolve_coverage_test.
class _StubBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<TelemetrySample> get telemetry =>
      const Stream<TelemetrySample>.empty();
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
  @override
  String? get connectedDeviceId => null;
  @override
  Future<bool> ensurePermissions() async => true;
  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

/// A write whose completion the test controls, so it is provably in flight
/// when `dispose()` runs.
class _GatedWrite {
  final gate = Completer<void>();

  /// Whatever the callback threw. Captured HERE, not left to propagate:
  /// [PendingWrites] deliberately swallows write errors (there is nowhere to
  /// report them at teardown), so an assertion that `dispose()` completes is
  /// green under BOTH orders — the disposed-controller error simply vanishes
  /// into the drain. The bug is only visible from inside the write.
  Object? callbackError;

  Future<void> run(AppServices s) async {
    await gate.future;
    try {
      // The callback-into-a-controller shape: repo write, then the controller
      // reloads and notifies. This is what `touch()` does after its await.
      await s.deviceRepo.touch('AA');
      await s.devices.load();
    } catch (e) {
      callbackError = e;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('a write in flight at teardown may call back into a live controller',
      () async {
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    final s = await AppServices.create(appDatabase: db, ble: _StubBle());
    await s.deviceRepo.upsertSavedDevice(const SavedDevice(id: 'AA', alias: 'unit'));
    await s.devices.load();

    // Queue the write and START dispose while it is still gated: the drain
    // must now wait for it, and its tail runs `devices.load()` +
    // `notifyListeners()`. With the old order (controllers disposed before
    // the drain) this threw "A DeviceController was used after being
    // disposed."; with the new order it must complete silently.
    final write = _GatedWrite();
    s.pending.add(write.run(s));

    final disposing = s.dispose();
    // Release the write only after dispose is underway, proving the overlap.
    write.gate.complete();
    await disposing;

    expect(write.callbackError, isNull,
        reason: 'the drain must finish while the controllers are still '
            'alive; a "used after being disposed" here means the old '
            'controllers-first order is back');
  });

  test('the drain still happens before the database closes', () async {
    // The invariant the OLD order existed to protect must survive the
    // reorder: a write released mid-dispose lands in an open database, not in
    // `DatabaseException(database_closed)`.
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    final s = await AppServices.create(appDatabase: db, ble: _StubBle());
    await s.deviceRepo.upsertSavedDevice(const SavedDevice(id: 'BB', alias: 'unit'));

    Object? writeError;
    final gate = Completer<void>();
    s.pending.add(() async {
      await gate.future;
      try {
        await s.deviceRepo.touch('BB');
      } catch (e) {
        writeError = e;
      }
    }());

    final disposing = s.dispose();
    gate.complete();
    await disposing;

    expect(writeError, isNull,
        reason: 'drain-before-close means the write finds the DB open');
  });
}
