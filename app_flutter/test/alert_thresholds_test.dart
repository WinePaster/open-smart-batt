// Threshold resolution — design 0098 (2026-11-09), on top of design 0080's
// class gates.
//
// 🔵 **Rewritten for design 0098.** The design-0080 version of this file
// (in git history before this change) pinned a layer order: the unit's own
// `0x2B` outranked our table. The owner ruled that `0x2B` is the unit's
// internal PROTECTION setting and must not reach the app at all; the app warns
// on its own fixed numbers instead. So the ordering tests are gone, replaced by
// their opposite — a reported `0x2B` changes NOTHING — and the table tests now
// pin the ruling's numbers rather than decoded payloads:
//
//   battery, capacitor   OV ≥ 15.0 V   UV ≤ 11.5 V   OT ≥ 80 °C
//   power bank           —             —             OT ≥ 50 °C
//
// What carried over unchanged, because design 0098 did not touch it: the
// device-level gate (§7.5.6 C-2 — an unclassified unit is not watched), the
// §7.5.7 rule that an unrecognised live byte outranks the persisted class, and
// the power bank's voltage suppression (§3.2.2).
//
// The comparison direction (≥ / ≤, inclusive) is the evaluator's and the
// advisory line's; it is pinned in `alert_evaluator_test.dart`.

import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/models/models.dart';

/// A sample carrying a `0x2B` triple and/or a device-type byte.
///
/// The triple is here to prove it is IGNORED. The timestamp is a fixed date
/// nothing reads.
TelemetrySample _reported({
  double? ov,
  double? uv,
  double? ot,
  int? deviceType,
}) =>
    TelemetrySample(
      timestamp: DateTime.utc(2026, 11, 9, 12),
      warnOv: ov,
      warnUv: uv,
      warnOt: ot,
      deviceType: deviceType,
    );

const _app15 = ResolvedThreshold(15.0, ThresholdSource.appDefault);
const _app115 = ResolvedThreshold(11.5, ThresholdSource.appDefault);
const _app80 = ResolvedThreshold(80, ThresholdSource.appDefault);

void main() {
  group('design 0098 — the app\'s numbers, by ruling', () {
    test('a battery gets ≥15.0 / ≤11.5 / ≥80', () {
      final r = resolveThresholds(wireClass: ProductClass.smartBattery);
      expect(r.ov, _app15);
      expect(r.uv, _app115);
      expect(r.ot, _app80);
    });

    test('a capacitor gets the same three numbers', () {
      final r = resolveThresholds(wireClass: ProductClass.supercapacitor);
      expect(r.ov, _app15);
      expect(r.uv, _app115);
      expect(r.ot, _app80);
    });

    test('the table holds exactly the ruling', () {
      for (final c in [ProductClass.smartBattery, ProductClass.supercapacitor]) {
        final row = kAppAlertThresholds[c]!;
        expect(row.ov, 15.0, reason: c.name);
        expect(row.uv, 11.5, reason: c.name);
        expect(row.ot, 80, reason: c.name);
      }
      final bank = kAppAlertThresholds[ProductClass.powerBank]!;
      expect(bank.ov, isNull);
      expect(bank.uv, isNull);
      expect(bank.ot, kPowerBankOtDefaultC);
      expect(kAppAlertThresholds.containsKey(ProductClass.unknown), isFalse,
          reason: 'an unknown class has no row by design (§7.5.6 C-2)');
    });

    test('appThresholdsFor is the table, keyed on the wire', () {
      for (final c in ProductClass.values) {
        expect(appThresholdsFor(c), kAppAlertThresholds[c], reason: c.name);
      }
    });
  });

  group('design 0098 — 0x2B is a protection parameter and is NOT read', () {
    test('a gen-3 capacitor reporting 402c2814 (OV 16.0) still resolves 15.0',
        () {
      // The case design 0080 used to argue the OPPOSITE ranking. Under 0098 the
      // unit's own value is its protection point, not our warning.
      final r = resolveThresholds(
        reported: _reported(
          ov: 16.0,
          uv: 11.5,
          ot: 80,
          deviceType: kSuperCapacitorGen3DeviceType,
        ),
      );
      expect(r.ov, _app15);
      expect(r.uv, _app115);
      expect(r.ot, _app80);
    });

    test('a battery reporting 18401414 resolves to the app row, not 12.0', () {
      final r = resolveThresholds(
        reported: _reported(
          ov: 15.0,
          uv: 12.0,
          ot: 80,
          deviceType: kSmartBatteryDeviceType,
        ),
      );
      expect(r.uv, _app115, reason: 'the old car-battery UV 12.0 is gone');
    });

    test('a unit with no 0x2B at all resolves identically to one with', () {
      final without = resolveThresholds(
          reported: _reported(deviceType: kSuperCapacitorDeviceType));
      final with2B = resolveThresholds(
        reported: _reported(
            ov: 14.8, uv: 11.5, ot: 100, deviceType: kSuperCapacitorDeviceType),
      );
      expect(with2B, without);
    });

    test('every value has the app as its source — there is no other', () {
      final r = resolveThresholds(wireClass: ProductClass.smartBattery);
      for (final k in AlertKind.values) {
        expect(r[k].source, ThresholdSource.appDefault, reason: k.name);
      }
      expect(ThresholdSource.values,
          [ThresholdSource.appDefault, ThresholdSource.none],
          reason: 'ThresholdSource.device was removed with layer ②');
    });

    test('an OFFLINE saved unit has thresholds — no link needed any more', () {
      // Design 0080 §7.5.2's gap (「連線後才知道」) closes by construction:
      // the persisted class is enough.
      final r = resolveThresholds(wireClass: ProductClass.supercapacitor);
      expect(r.hasAny, isTrue);
      expect(r.ov, _app15);
    });
  });

  group('operator [] agrees with the named fields', () {
    test('per kind', () {
      final r = resolveThresholds(wireClass: ProductClass.smartBattery);
      expect(r[AlertKind.overVoltage], r.ov);
      expect(r[AlertKind.underVoltage], r.uv);
      expect(r[AlertKind.overTemperature], r.ot);
    });
  });

  // ---------------------------------------------------------------------------
  group('§3.2.2 — the power bank watches heat and nothing else', () {
    test('OT is 50 °C; OV and UV are unset', () {
      final r = resolveThresholds(wireClass: ProductClass.powerBank);
      expect(r.ot, const ResolvedThreshold(50, ThresholdSource.appDefault));
      expect(r.ov, ResolvedThreshold.unavailable);
      expect(r.uv, ResolvedThreshold.unavailable);
    });

    test('a live 0x22 byte mutes voltage even over a battery record', () {
      final r = resolveThresholds(
        wireClass: ProductClass.smartBattery,
        reported: _reported(ov: 15.0, uv: 12.0, deviceType: kPowerBankDeviceType),
      );
      expect(r.ov, ResolvedThreshold.unavailable);
      expect(r.uv, ResolvedThreshold.unavailable);
      expect(r.ot.value, kPowerBankOtDefaultC);
    });
  });

  // ---------------------------------------------------------------------------
  group('§7.5.6 C-2 — an unclassified unit is not watched at all', () {
    test('no exceptions: a reported 0x2B does not buy its way in', () {
      final r = resolveThresholds(
        reported: _reported(ov: 15.0, uv: 12.0, ot: 80, deviceType: 0x33),
      );
      for (final k in AlertKind.values) {
        expect(r[k].source, ThresholdSource.none, reason: k.name);
        expect(r[k].value, isNull, reason: k.name);
      }
      expect(r.hasAny, isFalse);
    });

    test('"not arrived yet" and "arrived but unrecognised" are DIFFERENT', () {
      // Every connection spends its first frames in `deviceTypePending`; a
      // screen that could not tell the two apart would flash "無法提供警告" at
      // every connect.
      expect(resolveThresholds().disabledReason,
          AlertsDisabledReason.deviceTypePending,
          reason: 'offline saved device with no persisted class');
      expect(resolveThresholds(reported: _reported()).disabledReason,
          AlertsDisabledReason.deviceTypePending,
          reason: 'connected, telemetry flowing, 0x10 not seen yet');
      expect(
          resolveThresholds(reported: _reported(deviceType: 0x33))
              .disabledReason,
          AlertsDisabledReason.deviceTypeUnrecognised,
          reason: 'a byte exists and product_class.dart should be taught it');
    });

    test('a recognised unit carries no disabled reason', () {
      final r = resolveThresholds(wireClass: ProductClass.smartBattery);
      expect(r.disabledReason, AlertsDisabledReason.none);
      expect(r.isDeviceUnwatched, isFalse);
    });

    test('AlertThresholds.none and .unwatched are not equal', () {
      expect(
          AlertThresholds.none,
          isNot(const AlertThresholds.unwatched(
              AlertsDisabledReason.deviceTypeUnrecognised)));
      expect(AlertThresholds.none.hasAny, isFalse);
      expect(
          const AlertThresholds.unwatched(AlertsDisabledReason.deviceTypePending)
              .hasAny,
          isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  group('§7.5.7 — an unrecognised live byte outranks the persisted class', () {
    test('row 1 — no byte yet: the persisted class carries the evaluation', () {
      final r = resolveThresholds(
        wireClass: ProductClass.smartBattery,
        reported: _reported(ov: 15.2, ot: 62),
      );
      expect(r.disabledReason, AlertsDisabledReason.none);
      expect(r.ov, _app15,
          reason: 'the app row for the stored class — not the reported 15.2');
    });

    test('row 2 — an unrecognised byte disables the unit even though the '
        'persisted class is a good one', () {
      final r = resolveThresholds(
        wireClass: ProductClass.smartBattery,
        reported: _reported(ov: 15.2, uv: 12.4, ot: 62, deviceType: 0x31),
      );
      for (final k in AlertKind.values) {
        expect(r[k], ResolvedThreshold.unavailable, reason: k.name);
      }
      expect(r.disabledReason, AlertsDisabledReason.deviceTypeUnrecognised);
    });

    test('row 3 — no byte and no persisted class is the pending case', () {
      final r = resolveThresholds(
        wireClass: ProductClass.unknown,
        reported: _reported(ov: 15.2),
      );
      expect(r.disabledReason, AlertsDisabledReason.deviceTypePending);
      expect(r.hasAny, isFalse);
    });
  });

  group('value semantics', () {
    test('ResolvedThreshold compares by value, so a rebuild is not a change',
        () {
      expect(const ResolvedThreshold(15.0, ThresholdSource.appDefault),
          const ResolvedThreshold(15.0, ThresholdSource.appDefault));
      expect(ResolvedThreshold.unavailable,
          isNot(const ResolvedThreshold(15.0, ThresholdSource.appDefault)));
      AlertThresholds resolved() => resolveThresholds(
          reported: _reported(deviceType: kSmartBatteryDeviceType));
      expect(resolved(), resolved());
      expect(resolved().hasAny, isTrue,
          reason: 'two identically EMPTY results would compare equal too');
    });

    test('AlertKind.breaches is INCLUSIVE (design 0098)', () {
      expect(AlertKind.overVoltage.breaches(15.0, 15.0), isTrue);
      expect(AlertKind.overVoltage.breaches(14.99, 15.0), isFalse);
      expect(AlertKind.underVoltage.breaches(11.5, 11.5), isTrue);
      expect(AlertKind.underVoltage.breaches(11.51, 11.5), isFalse);
      expect(AlertKind.overTemperature.breaches(80, 80), isTrue);
      expect(AlertKind.overTemperature.breaches(79, 80), isFalse);
    });

    test('AlertKind knows which unit it is measured in', () {
      expect(AlertKind.overVoltage.isVoltage, isTrue);
      expect(AlertKind.underVoltage.isVoltage, isTrue);
      expect(AlertKind.overTemperature.isVoltage, isFalse);
    });
  });
}
