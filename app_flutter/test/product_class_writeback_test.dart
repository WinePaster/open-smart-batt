// The product class reaches the SAVED RECORD, not just the screen.
//
// The defect this file locks down. A device is saved from the naming dialog,
// and that dialog opens at `connected` — about two and a half seconds before
// `ready`, and therefore before the `0x10` device-type byte has arrived. So the
// class the dialog captures is always `unknown`, and the record is created
// `unknown`. That much is by design and is not the bug.
//
// The bug was the retry that never happened. The one write this controller
// attempted lived inside `_recomputePackLabel`, behind an early return whose
// job was to throttle `notifyListeners()`. The class resolved while the dialog
// was still up, `DeviceController.setProductClass` silently no-opped because
// the record did not exist yet, and the gate then made sure no later sample of
// that connection ever tried again. The unit stayed `unknown` in storage until
// the user disconnected and connected a SECOND time.
//
// What that cost the user: `HomeLayout.renderedFor` drops every tile bound to a
// device with no class — the module tiles AND the device card (design 0050 D4)
// — and the home editor offers it no module cards at all. A unit they had just
// named was, from the home page's point of view, not there.
//
// The fix is `_persistProductClass`, called on every telemetry sample beside
// `_persistIdentity` and `_persistFacts`, which had already solved exactly this
// problem in exactly this way for the MAC and the serial.
//
// CLEAN-ROOM: expectations derive from this project's own source and captures.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// No radio: the test drives link transitions and telemetry directly, and says
/// which id the "connected" unit has.
class _StubBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  String? held;
  String advertised = '';

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  String? get connectedDeviceId => held;

  @override
  String get connectedDeviceName => advertised;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {}

  @override
  Future<void> disconnect() async {}

  void emitLink(BleLinkState s) => _linkOut.add(s);
  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _telemetryOut.close();
    await super.dispose();
  }
}

/// Let the fire-and-forget writes land. Each one is a DB statement plus a
/// controller reload, so a microtask hop is not enough.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

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

  TelemetrySample sampleWith({int? deviceType, String? mac, String? serial}) =>
      TelemetrySample(
        timestamp: DateTime.utc(2026, 8, 14, 6, 5),
        pvlt: 13.2,
        deviceType: deviceType,
        mac: mac,
        serial: serial,
      );

  /// Bring the link up on [id] without sending any telemetry yet — the state
  /// the naming dialog is opened from is one step EARLIER than this, at
  /// `connected`.
  Future<void> connectTo(AppServices s, _StubBle ble, String id,
      {ProductClass? seedClass}) async {
    ble.held = id;
    await s.connection.connect(id, seedClass: seedClass);
    ble.emitLink(BleLinkState.connected);
    await settle();
  }

  Future<void> becomeReady(_StubBle ble) async {
    ble.emitLink(BleLinkState.ready);
    await settle();
  }

  Future<void> drop(AppServices s, _StubBle ble) async {
    ble.emitLink(BleLinkState.disconnected);
    ble.held = null;
    await settle();
  }

  // =========================================================================
  // 1. The cause, stated as a test so nobody "fixes" it in the wrong place
  // =========================================================================
  group('the naming dialog captures no class, and that is expected', () {
    test('at `connected` — where the dialog opens — the class is unknown',
        () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      await connectTo(s, ble, 'BATT');

      // These two getters ARE what `save_device_flow.dart` reads, before its
      // `await showAliasDialog(...)`, to fill `saveNew(productClass: ...)`.
      expect(s.connection.packLabel, ProductClass.unknown);
      expect(s.connection.resolvedClass, ProductClass.unknown);
      expect(s.connection.isPowerBank, isFalse);

      // So the record is born unknown. The bug was never this line.
      await s.devices.saveNew('BATT', '前車電瓶',
          productClass: s.connection.packLabel);
      expect(s.devices.deviceFor('BATT')!.productClass, ProductClass.unknown,
          reason: 'the dialog answered before `ready`; there was nothing to '
              'record yet');
    });
  });

  // =========================================================================
  // 2. The fix: the class lands on the record after the record exists
  // =========================================================================
  group('a saved record picks the class up from any later sample', () {
    test('🔴 the class resolves BEFORE the record exists, and still lands',
        () async {
      // The field ordering, to the second: `connect` 06:05:18, dialog 06:05:19,
      // `ready` 06:05:21, `class-resolve` 06:05:21, dialog answered 06:05:24.
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      await connectTo(s, ble, 'BATT');
      await becomeReady(ble);

      // 06:05:21 — the byte arrives while the dialog is still up. This write
      // is LOST, and must be: there is no record to write onto.
      ble.emitTelemetry(sampleWith(deviceType: kSmartBatteryDeviceType));
      await settle();
      expect(s.devices.deviceFor('BATT'), isNull,
          reason: 'sanity: the user has not answered the dialog yet');
      expect(s.connection.packLabel, ProductClass.smartBattery,
          reason: 'sanity: the link itself knows the class by now');

      // 06:05:24 — the user answers. `initialClass` was captured before the
      // await, so it is still `unknown`.
      await s.devices.saveNew('BATT', '前車電瓶');
      expect(s.devices.deviceFor('BATT')!.productClass, ProductClass.unknown);

      // 06:05:25 — the next second's frame. THIS is the whole fix: before it,
      // `_recomputePackLabel`'s early return had already decided the class had
      // not changed, so no further attempt was ever made.
      ble.emitTelemetry(sampleWith(deviceType: kSmartBatteryDeviceType));
      await settle();

      expect(s.devices.deviceFor('BATT')!.productClass,
          ProductClass.smartBattery,
          reason: 'a unit the user just named must not stay invisible on the '
              'home page until the SECOND connect');
    });

    test('a frame carrying no device-type byte still triggers the retry',
        () async {
      // 0x10 is not on every frame. The retry must not depend on the byte
      // being re-sent — the resolver remembers it for the connection.
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      await connectTo(s, ble, 'CAP');
      await becomeReady(ble);
      ble.emitTelemetry(sampleWith(deviceType: kSuperCapacitorDeviceType));
      await settle();
      await s.devices.saveNew('CAP', '前車電容');

      ble.emitTelemetry(sampleWith(mac: 'AA:BB:CC:DD:EE:FF'));
      await settle();

      expect(s.devices.deviceFor('CAP')!.productClass,
          ProductClass.supercapacitor);
    });

    test('a record already stored as unknown self-heals on the next connect',
        () async {
      // Every user who has already hit this bug has one of these on their
      // phone. There is no migration script — connecting once is the fix.
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);
      await s.devices.saveNew('BATT', '前車電瓶');
      expect(s.devices.deviceFor('BATT')!.productClass, ProductClass.unknown);

      await connectTo(s, ble, 'BATT');
      await becomeReady(ble);
      ble.emitTelemetry(sampleWith(deviceType: kSmartBatteryDeviceType));
      await settle();

      expect(s.devices.deviceFor('BATT')!.productClass,
          ProductClass.smartBattery);
    });

    test('a record stored WRONG is corrected, not merely filled in', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);
      await s.devices.saveNew('UNIT', 'unit',
          productClass: ProductClass.supercapacitor);

      await connectTo(s, ble, 'UNIT');
      await becomeReady(ble);
      ble.emitTelemetry(sampleWith(deviceType: kSmartBatteryDeviceType));
      await settle();

      expect(s.devices.deviceFor('UNIT')!.productClass,
          ProductClass.smartBattery,
          reason: 'the wire byte overrides a stored class every time — the '
              'self-heal the old comment promised, now on every sample');
    });
  });

  // =========================================================================
  // 3. FB-25: what must NOT be written
  // =========================================================================
  group('🔴 FB-25: only the resolver may write, never the seed', () {
    test('a seed for a rebound id is never stamped onto its record', () async {
      // `connect(seedClass:)` is the rebound-iOS-id path: the class comes from
      // a record filed under the OLD id. It may route the screen; it must not
      // be written back onto THIS id's row, because the two ids are only
      // believed to be the same unit.
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);
      await s.devices.saveNew('REBOUND', 'unit');

      await connectTo(s, ble, 'REBOUND',
          seedClass: ProductClass.smartBattery);
      await becomeReady(ble);
      // Frames, but never a device-type byte.
      for (var i = 0; i < 3; i++) {
        ble.emitTelemetry(sampleWith());
        await settle();
      }

      expect(s.connection.packLabel, ProductClass.smartBattery,
          reason: 'sanity: the seed still drives what the screen shows');
      expect(s.devices.deviceFor('REBOUND')!.productClass, ProductClass.unknown,
          reason: 'the seed is a belief, not an observation — writing it would '
              'stamp one device class onto another device row');
    });

    test('an unrecognised device-type byte is not a class', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);
      await s.devices.saveNew('MYSTERY', 'unit');

      await connectTo(s, ble, 'MYSTERY');
      await becomeReady(ble);
      ble.emitTelemetry(sampleWith(deviceType: 0x99));
      await settle();

      expect(s.devices.deviceFor('MYSTERY')!.productClass, ProductClass.unknown,
          reason: 'the byte arrived and this build does not map it; the record '
              'must say so rather than guess');
    });

    test('an UNSAVED unit is left unsaved', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      await connectTo(s, ble, 'CAP');
      await becomeReady(ble);
      for (var i = 0; i < 3; i++) {
        ble.emitTelemetry(sampleWith(deviceType: kSuperCapacitorDeviceType));
        await settle();
      }

      expect(s.devices.deviceFor('CAP'), isNull,
          reason: 'calling this on every sample must not create rows the user '
              'declined to keep (design 0055 §5)');
    });
  });

  // =========================================================================
  // 4. Called every second — so it has to cost nothing when nothing changed
  // =========================================================================
  group('the per-sample call is a no-op once the value is in place', () {
    test('repeat samples write nothing further', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);
      await s.devices.saveNew('BATT', '前車電瓶');

      await connectTo(s, ble, 'BATT');
      await becomeReady(ble);
      const mac = 'AA:BB:CC:DD:EE:FF';
      ble.emitTelemetry(
          sampleWith(deviceType: kSmartBatteryDeviceType, mac: mac));
      await settle();
      expect(s.devices.deviceFor('BATT')!.productClass,
          ProductClass.smartBattery);

      // Every write on this controller ends in `load()` + `notifyListeners()`,
      // so a reload that did not need to happen is observable from here.
      // last-seen is throttled to a minute and the MAC is unchanged, so the
      // class is the only thing that could still fire.
      var reloads = 0;
      void count() => reloads++;
      s.devices.addListener(count);
      addTearDown(() => s.devices.removeListener(count));

      for (var i = 0; i < 5; i++) {
        ble.emitTelemetry(
            sampleWith(deviceType: kSmartBatteryDeviceType, mac: mac));
        await settle();
      }

      expect(reloads, 0,
          reason: 'DeviceController.setProductClass dedupes before any I/O — '
              'that is what makes calling it per sample affordable');
      expect(s.devices.deviceFor('BATT')!.productClass,
          ProductClass.smartBattery);
    });
  });

  // =========================================================================
  // 5. The one non-telemetry writer, kept alive across the move
  // =========================================================================
  group('the manual override still persists', () {
    test('setPackLabelOverride writes onto the saved record', () async {
      // This used to persist as a side effect of `_recomputePackLabel`. Moving
      // the write out of that method must not silently drop it.
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);
      await s.devices.saveNew('MYSTERY', 'unit');

      await connectTo(s, ble, 'MYSTERY');
      await becomeReady(ble);
      ble.emitTelemetry(sampleWith(deviceType: 0x99));
      await settle();

      s.connection.setPackLabelOverride(ProductClass.supercapacitor);
      await settle();

      expect(s.devices.deviceFor('MYSTERY')!.productClass,
          ProductClass.supercapacitor);
    });
  });

  // =========================================================================
  // 6. End to end: the home page can finally draw the unit
  // =========================================================================
  group('the home surface stops hiding a freshly named unit', () {
    test('renderedFor keeps its tiles after one post-save sample', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      await connectTo(s, ble, 'BATT');
      await becomeReady(ble);
      ble.emitTelemetry(sampleWith(deviceType: kSmartBatteryDeviceType));
      await settle();
      await s.devices.saveNew('BATT', '1328');

      const layout = HomeLayout([
        HomeTile.device('BATT'),
        HomeTile.module(DisplayModule.cells, deviceId: 'BATT'),
      ]);

      // Before the retry lands, design 0050 D4 hides the whole unit.
      expect(
          layout
              .renderedFor(s.devices.devices, AppSettings.defaults,
                  gForceAvailable: false)
              .tiles
              .where((t) => t.deviceId == 'BATT'),
          isEmpty,
          reason: 'sanity: this is the screen the user reported');

      ble.emitTelemetry(sampleWith(deviceType: kSmartBatteryDeviceType));
      await settle();

      expect(
          layout
              .renderedFor(s.devices.devices, AppSettings.defaults,
                  gForceAvailable: false)
              .tiles
              .length,
          2,
          reason: 'both the device card and the module tile come back — D4 is '
              'untouched, the record simply stopped lying about the class');
      await drop(s, ble);
    });
  });
}
