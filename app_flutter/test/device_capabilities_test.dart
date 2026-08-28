// Unit tests for the per-class capability gating.
//
// The matrix these pin down (see [DeviceCapabilities]): a super-capacitor
// exposes ONLY 檢測電容; a smart battery exposes 解除斷電 (+ model-gated 防盜);
// a power bank exposes none; an unclassified pack shows the bounded fallback —
// the union of pack controls EXCEPT anti-theft.
//
// The rows matter individually. Before the split, one `!isPowerBank` flag gated
// all three, so a capacitor was offered controls for a run mode it does not
// have. DVOL is DATA-DRIVEN and deliberately NOT gated here — the card renders
// only when values arrive, so a `supportsDvol` getter would have been a second,
// untested gate in front of a gate.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart'
    show DeviceCapabilities, ProductClass;

void main() {
  group('DeviceCapabilities per-class gating', () {
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

    test('unknown: bounded fallback = 解除斷電 only (§3.3, design 0082 Q8)', () {
      final c = DeviceCapabilities.fromClass(ProductClass.unknown);
      expect(c, DeviceCapabilities.unknown);
      expect(c.isPowerBank, isFalse);
      // 🔵 CHANGED 2026-08-28, and the change is the point of the test.
      // 檢測電容 used to be in this fallback because it sent nothing at all;
      // design 0082 Q1 made it a real `0x23` <- `0x06` write, and the whole
      // justification for erring lenient here is that NOTHING in the fallback
      // can change a device's state. So the control left the fallback rather
      // than the argument being softened to keep it.
      expect(c.isCapacitor, isFalse); // 檢測電容 NOT shown
      expect(c.hasCutOff, isTrue); //  解除斷電 shown
      expect(c.hasAntiTheft, isFalse); // 防盜 never in the fallback
      // The override cannot force anti-theft on an unclassified pack.
      expect(c.copyWith(antiTheftOverride: true).hasAntiTheft, isFalse);
    });

    test('no unclassified unit can be handed a state-changing write', () {
      // The invariant behind the fallback, stated as an invariant rather than
      // as three separate expectations that could each be relaxed alone:
      // the only control the unknown class gets is the release, and the
      // release is auth-gated and moves a pack TOWARD running.
      final c = DeviceCapabilities.fromClass(ProductClass.unknown);
      expect(c.isCapacitor, isFalse);
      expect(c.hasAntiTheft, isFalse);
      expect(c.copyWith(antiTheftOverride: true).isCapacitor, isFalse);
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
      // 0x17 → supercapacitor since the 2026-07-27 wire capture.
      expect(DeviceCapabilities.fromDeviceType(0x17).productClass,
          ProductClass.supercapacitor);
      // Only an absent / unrecognised byte falls back to unknown.
      expect(DeviceCapabilities.fromDeviceType(null).productClass,
          ProductClass.unknown);
      expect(DeviceCapabilities.fromDeviceType(0x99).productClass,
          ProductClass.unknown);
    });
  });
}
