// design 0102: BLE scanning asks for location only where Android requires it.
//
// On API 31+ BLUETOOTH_SCAN carries neverForLocation, so a location prompt on
// the scan tab was never needed — it contradicted the privacy policy ("location
// is requested only when you turn on speed detection") and is the kind of
// unexplained sensitive permission Play review asks about.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  test('Android 12+ (API 31+) asks for Bluetooth only', () {
    for (final sdk in [31, 33, 35, 36]) {
      expect(BleService.blePermissionsFor(sdk),
          [Permission.bluetoothScan, Permission.bluetoothConnect],
          reason: 'API $sdk');
    }
  });

  test('Android 11 and below still ask for location (BLE scan needs it)', () {
    for (final sdk in [24, 29, 30]) {
      expect(BleService.blePermissionsFor(sdk),
          contains(Permission.locationWhenInUse),
          reason: 'API $sdk');
    }
  });

  test('unknown API level keeps the old, location-inclusive request', () {
    // A missing grant on API <= 30 is a scan that silently finds nothing;
    // an extra prompt on 31+ is only a prompt.
    expect(BleService.blePermissionsFor(null),
        contains(Permission.locationWhenInUse));
  });
}
