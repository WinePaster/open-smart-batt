// Unit tests for the per-class capability gating (design 0004 §3.2/§3.3).
//
// The corrected matrix (docs/devices.md): a super-capacitor exposes ONLY
// 檢測電容; a smart battery exposes 解除斷電 (+ model-gated 防盜); a power bank
// exposes none; an unclassified pack shows the bounded fallback — the union of
// pack controls EXCEPT anti-theft. DVOL is DATA-DRIVEN, not gated here (the old
// supportsDvol getter was removed — §3.5/Q1).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart'
    show DeviceCapabilities, ProductClass;

void main() {
  group('DeviceCapabilities per-class gating (design 0004 §3.2)', () {
    test('power bank: no pack controls', () {
      final c = DeviceCapabilities.fromClass(ProductClass.powerBank);
      expect(c.isPowerBank, isTrue);
      expect(c.isCapacitor, isFalse);
      expect(c.hasCutOff, isFalse);
      expect(c.hasAntiTheft, isFalse);
    });

    test('super-capacitor: 檢測電容 only', () {
      final c = DeviceCapabilities.fromClass(ProductClass.supercapacitor);
      expect(c.isPowerBank, isFalse);
      expect(c.isCapacitor, isTrue);
      expect(c.hasCutOff, isFalse);
      expect(c.hasAntiTheft, isFalse);
      // Anti-theft never applies to a capacitor, even with an override.
      expect(c.copyWith(antiTheftOverride: true).hasAntiTheft, isFalse);
    });

    test('smart battery: 解除斷電 yes, 檢測電容 no, 防盜 model-gated', () {
      final c = DeviceCapabilities.fromClass(ProductClass.smartBattery);
      expect(c.isPowerBank, isFalse);
      expect(c.isCapacitor, isFalse);
      expect(c.hasCutOff, isTrue);
      // Off until a per-model override enables it.
      expect(c.hasAntiTheft, isFalse);
      expect(c.copyWith(antiTheftOverride: true).hasAntiTheft, isTrue);
      expect(c.copyWith(antiTheftOverride: false).hasAntiTheft, isFalse);
    });

    test('unknown: bounded fallback = union EXCEPT anti-theft (§3.3)', () {
      final c = DeviceCapabilities.fromClass(ProductClass.unknown);
      expect(c, DeviceCapabilities.unknown);
      expect(c.isPowerBank, isFalse);
      expect(c.isCapacitor, isTrue); // 檢測電容 shown
      expect(c.hasCutOff, isTrue); //  解除斷電 shown
      expect(c.hasAntiTheft, isFalse); // 防盜 never in the fallback
      // The override cannot force anti-theft on an unclassified pack.
      expect(c.copyWith(antiTheftOverride: true).hasAntiTheft, isFalse);
    });
  });

  group('DeviceCapabilities value semantics', () {
    test('== / hashCode fold class + override', () {
      const a = DeviceCapabilities(productClass: ProductClass.smartBattery);
      const b = DeviceCapabilities(productClass: ProductClass.smartBattery);
      const c = DeviceCapabilities(
          productClass: ProductClass.smartBattery, antiTheftOverride: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('fromDeviceType maps the wire byte through ProductClass', () {
      expect(DeviceCapabilities.fromDeviceType(0x22).productClass,
          ProductClass.powerBank);
      expect(DeviceCapabilities.fromDeviceType(0x02).productClass,
          ProductClass.smartBattery);
      // 0x17 unverified → unknown (bounded fallback), NOT supercapacitor.
      expect(DeviceCapabilities.fromDeviceType(0x17).productClass,
          ProductClass.unknown);
      expect(DeviceCapabilities.fromDeviceType(null).productClass,
          ProductClass.unknown);
    });
  });
}
