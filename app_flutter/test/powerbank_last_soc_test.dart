// design 0103 Q7 / D8 (owner 2026-11-11 「Q7: OK」): an offline power-bank card
// shows the last SOC %, the same quantity as its live card — never `last_value`,
// which for a power bank is one cell's voltage (FB-43).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';

void main() {
  group('SavedDevice.cachedReading', () {
    test('a power bank is cached as SOC %, not as its cell voltage', () {
      const d = SavedDevice(
        id: 'pb',
        alias: 'M2',
        productClass: ProductClass.powerBank,
        lastValue: 3.79,
        lastSoc: 85,
      );
      expect(d.cachedReading, (value: '85', unit: '%'));
    });

    test('a power bank with no stored SOC shows nothing, not the cell', () {
      // Pre-v26 rows carry only last_value. Falling back to it would put the
      // FB-43 number straight back on the card.
      const d = SavedDevice(
        id: 'pb',
        alias: 'M2',
        productClass: ProductClass.powerBank,
        lastValue: 3.79,
      );
      expect(d.cachedReading, isNull);
    });

    test('a pack is still cached as PVLT, and ignores any SOC', () {
      const d = SavedDevice(
        id: 'bat',
        alias: 'car',
        productClass: ProductClass.smartBattery,
        lastValue: 13.214,
        lastSoc: 50,
      );
      expect(d.cachedReading, (value: '13.21', unit: 'V'));
    });

    test('nothing stored ⇒ null', () {
      const d = SavedDevice(id: 'x', alias: '');
      expect(d.cachedReading, isNull);
    });
  });

  test('last_soc round-trips through the row map; absent column reads null',
      () {
    const d = SavedDevice(
      id: 'pb',
      alias: 'M2',
      productClass: ProductClass.powerBank,
      lastSoc: 94,
    );
    final m = d.toMap();
    expect(m['last_soc'], 94);
    expect(SavedDevice.fromMap(m).lastSoc, 94);

    final legacy = Map<String, Object?>.of(m)..remove('last_soc');
    expect(SavedDevice.fromMap(legacy).lastSoc, isNull);
  });

  test('copyWith carries lastSoc', () {
    const d = SavedDevice(id: 'pb', alias: '', lastSoc: 10);
    expect(d.copyWith(alias: 'a').lastSoc, 10);
    expect(d.copyWith(lastSoc: 20).lastSoc, 20);
  });
}
