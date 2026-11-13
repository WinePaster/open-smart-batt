// 2026-11-14 — ROG Phone 9 Pro (Android 16), 0.7.51+26111340 → +26111403
// trace build. Every scan, automatic or 重新掃描, died 1 ms after
// `calling FlutterBluePlus.startScan` with:
//
//   type 'List<dynamic>' is not a subtype of type 'List<DiscoveredDevice>'
//   of 'data'
//
// `BleService.startScan` cleared the list with `_emitTo(_scan, const [])`.
// `_emitTo<T>(StreamController<T> c, T v)` took T from BOTH arguments, so the
// untyped literal made T = List<dynamic>; Dart's covariant generics let that
// compile, and the controller's `add` rejected it at run time. Introduced by
// c4443e4 (2026-11-13, "no emits after dispose"); no test ran the real
// `startScan`, because every scan test stubs BleService above it.
//
// This one runs the REAL `BleService.startScan` against a stand-in radio one
// layer lower (`FlutterBluePlusPlatform.instance`, as double_gatt_setup_test
// does) and asserts both halves: the call completes, AND an advertisement that
// arrives afterwards reaches `scanResults`.
//
// CLEAN-ROOM: expectations derive from this project's own source and the
// published flutter_blue_plus sources.

// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' show FlutterBluePlus;
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/ble/ble.dart';

final class _ScanRadio extends FlutterBluePlusPlatform {
  final _scan = StreamController<BmScanResponse>.broadcast();
  final _adapter = StreamController<BmBluetoothAdapterState>.broadcast();
  int startScanCalls = 0;

  @override
  Stream<BmScanResponse> get onScanResponse => _scan.stream;

  @override
  Stream<BmBluetoothAdapterState> get onAdapterStateChanged => _adapter.stream;

  @override
  Future<bool> isSupported(BmIsSupportedRequest request) async => true;

  @override
  Future<BmBluetoothAdapterState> getAdapterState(
          BmBluetoothAdapterStateRequest request) async =>
      BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on);

  @override
  Future<bool> startScan(BmScanSettings request) async {
    startScanCalls++;
    return true;
  }

  @override
  Future<bool> stopScan(BmStopScanRequest request) async => true;

  void advertise(String id, String name) => _scan.add(BmScanResponse(
        advertisements: [
          BmScanAdvertisement(
            remoteId: DeviceIdentifier(id),
            platformName: name,
            advName: name,
            connectable: true,
            txPowerLevel: null,
            appearance: null,
            manufacturerData: const {},
            serviceData: const {},
            serviceUuids: const [],
            rssi: -60,
          ),
        ],
        success: true,
        errorCode: 0,
        errorString: '',
      ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final radio = _ScanRadio();

  setUpAll(() async {
    FlutterBluePlusPlatform.instance = radio;
    await FlutterBluePlus.isSupported;
    // Prime the plugin's adapter-state cache so `_awaitAdapterOn` returns at
    // once instead of waiting out its bound.
    await FlutterBluePlus.adapterState.first;
  });

  test('the real startScan completes and reaches the radio', () async {
    final ble = BleService();
    addTearDown(() async {
      await ble.stopScan();
      await ble.dispose();
    });

    await expectLater(ble.startScan(timeout: const Duration(seconds: 5)),
        completes);
    expect(radio.startScanCalls, 1);
  });

  test('and a device advertised afterwards shows up in scanResults', () async {
    final ble = BleService();
    addTearDown(() async {
      await ble.stopScan();
      await ble.dispose();
    });
    final seen = <List<DiscoveredDevice>>[];
    final sub = ble.scanResults.listen(seen.add);
    addTearDown(sub.cancel);

    await ble.startScan(timeout: const Duration(seconds: 5));
    radio.advertise('AA:BB:CC:DD:EE:FF', 'RCE-SCAP_II');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(seen.first, isEmpty, reason: 'the clear-out comes first');
    expect(seen.last.map((d) => d.id), contains('AA:BB:CC:DD:EE:FF'));
  });
}
