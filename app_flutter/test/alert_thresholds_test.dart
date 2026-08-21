// Design 0080 P1 — the four-layer threshold resolution (§3.1) and the
// per-category fallback table (§3.2).
//
// Two things are pinned here and they are not the same kind of claim.
//
// The ORDERING tests are about a rule: a unit's own `0x2B` outranks our table,
// per field, always. That rule is the design's central one and §3.2.1 gives the
// counter-example that makes it load-bearing — a third-generation capacitor
// leaves the factory with OV = 16.0 V while the table says 14.8, so a build
// that consulted the table first would warn about 7+ units in the corpus every
// time they behaved normally.
//
// The TABLE tests are about numbers, and they are here for a blunter reason:
// `docs/devices/motorcycle-battery.md:51` carried a wrong decode of `18181414`
// for three weeks (design 0080 §2.5) because nothing ever computed with it.
// These assertions are the thing that now computes with it. If somebody edits
// a constant, a test says so before a user's phone does.
//
// CLEAN-ROOM: every number below is decoded from this project's own shipping
// arithmetic (`telemetry_decoder.dart:103-109`) applied to payloads in our own
// captures, as tabulated in design 0080 §3.2.1.

import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/models/models.dart';

/// A sample carrying only a `0x2B` triple — layer ②'s entire contribution.
///
/// The timestamp is a fixed date nothing reads; see the evaluator's tests for
/// why `sample.timestamp` is never a time source in this feature.
TelemetrySample _reported({
  double? ov,
  double? uv,
  double? ot,
  int? deviceType,
}) =>
    TelemetrySample(
      timestamp: DateTime.utc(2026, 8, 22, 12),
      warnOv: ov,
      warnUv: uv,
      warnOt: ot,
      deviceType: deviceType,
    );

void main() {
  group('§3.1 — the four layers, in order', () {
    test('① a user value outranks both the device and the table', () {
      final r = resolveThresholds(
        userOv: 14.2,
        userUv: 12.4,
        userOt: 60,
        reported: _reported(ov: 15.0, uv: 12.0, ot: 80),
        category: DeclaredCategory.carBattery,
      );

      expect(r.ov, const ResolvedThreshold(14.2, ThresholdSource.user));
      expect(r.uv, const ResolvedThreshold(12.4, ThresholdSource.user));
      expect(r.ot, const ResolvedThreshold(60, ThresholdSource.user));
    });

    test('② the unit\'s own 0x2B outranks the category table', () {
      // THE case from §3.2.1: a gen-3 capacitor reports OV 16.0 while the table
      // would say 14.8. Rank them the other way round and every one of these
      // units is "over voltage" at rest.
      final r = resolveThresholds(
        reported: _reported(ov: 16.0, uv: 11.5, ot: 100),
        category: DeclaredCategory.carCapacitor,
      );

      expect(r.ov, const ResolvedThreshold(16.0, ThresholdSource.device));
      expect(r.ov.value, isNot(kCategoryDefaults[DeclaredCategory.carCapacitor]!.ov),
          reason: 'the two layers genuinely disagree here — that is the point '
              'of the test, not a coincidence of the fixture');
    });

    test('③ the table answers when the unit reported nothing', () {
      final r = resolveThresholds(category: DeclaredCategory.motorcycleBattery);

      expect(r.ov, const ResolvedThreshold(15.0, ThresholdSource.appDefault));
      expect(r.uv, const ResolvedThreshold(11.0, ThresholdSource.appDefault));
      expect(r.ot, const ResolvedThreshold(80, ThresholdSource.appDefault));
    });

    test('④ nothing anywhere ⇒ not evaluated, and never guessed', () {
      final r = resolveThresholds();

      expect(r.ov, ResolvedThreshold.unavailable);
      expect(r.uv, ResolvedThreshold.unavailable);
      expect(r.ot, ResolvedThreshold.unavailable);
      expect(r.hasAny, isFalse,
          reason: 'a unit with no threshold from any layer is invisible to the '
              'whole feature — §3.1 layer ④');
      for (final k in AlertKind.values) {
        expect(r[k].isSet, isFalse);
        expect(r[k].value, isNull);
        expect(r[k].source, ThresholdSource.none);
      }
    });

    test('④ a declared category we have no row for still yields nothing', () {
      // Every current category HAS a row, so this drives the null-map-lookup
      // path with a live-fire arrangement instead: category present, table row
      // present, but the field within it empty (the power bank's voltages).
      final r = resolveThresholds(category: DeclaredCategory.powerBank);
      expect(r.ov.source, ThresholdSource.none);
      expect(r.ot.isSet, isTrue);
    });
  });

  group('§3.1 — resolution is PER FIELD, not per unit', () {
    test('a user-set UV leaves OV and OT on the device\'s own values', () {
      final r = resolveThresholds(
        userUv: 12.4,
        reported: _reported(ov: 15.0, uv: 12.0, ot: 80),
        category: DeclaredCategory.carBattery,
      );

      expect(r.uv, const ResolvedThreshold(12.4, ThresholdSource.user),
          reason: 'the one field they answered');
      expect(r.ov, const ResolvedThreshold(15.0, ThresholdSource.device),
          reason: 'editing UV must not silently drop the device OV — the same '
              'rule setThresholds follows for the UT byte');
      expect(r.ot, const ResolvedThreshold(80, ThresholdSource.device));
    });

    test('three layers can supply three different fields of one unit', () {
      // A real enough shape: the user cares about under-voltage, the unit only
      // reported an OV (a partial 0x2B is not something we have seen, but a
      // per-field resolver must not assume the triple arrives whole), and the
      // temperature falls through to the table.
      final r = resolveThresholds(
        userUv: 12.6,
        reported: _reported(ov: 15.0),
        category: DeclaredCategory.carBattery,
      );

      expect(r.uv.source, ThresholdSource.user);
      expect(r.ov.source, ThresholdSource.device);
      expect(r.ot.source, ThresholdSource.appDefault);
      expect(r.ot.value, 80);
    });

    test('operator [] agrees with the named fields', () {
      final r = resolveThresholds(
        reported: _reported(ov: 15.0, uv: 12.0, ot: 80),
      );
      expect(r[AlertKind.overVoltage], r.ov);
      expect(r[AlertKind.underVoltage], r.uv);
      expect(r[AlertKind.overTemperature], r.ot);
    });
  });

  group('§3.2.1 — the fallback table, cell by cell', () {
    // 🔴 Spelled out rather than looped over the map, so that changing a
    // constant has to be defended here in the same edit. A loop would pass
    // against any table at all.
    test('carBattery — payload 18401414', () {
      final d = kCategoryDefaults[DeclaredCategory.carBattery]!;
      expect(d.ov, 15.0);
      expect(d.uv, 12.0);
      expect(d.ot, 80);
    });

    test('motorcycleBattery — payload 18181414, UV 11.0 not 12.0', () {
      // ⚠️ THIS is the cell design 0080 §2.5 had to correct in two documents
      // before it could be written down here. `18181414` decodes to
      // ov = 0x18*0.025+14.4 = 15.0, uv = 0x18*0.025+10.4 = 11.0,
      // ot = 0x14+60 = 80. The docs said "12.0 / 20 / 20".
      final d = kCategoryDefaults[DeclaredCategory.motorcycleBattery]!;
      expect(d.ov, 15.0);
      expect(d.uv, 11.0,
          reason: 'a bike battery is a smaller pack and its factory UV really '
              'is a volt below the car one — the "12.0" that stood in the docs '
              'for three weeks was an arithmetic slip, not a variant');
      expect(d.ot, 80);
    });

    test('both capacitor rows are identical, because the wire cannot tell them '
        'apart', () {
      final car = kCategoryDefaults[DeclaredCategory.carCapacitor]!;
      final bike = kCategoryDefaults[DeclaredCategory.motorcycleCapacitor]!;
      expect(car.ov, 14.8);
      expect(car.uv, 11.5);
      expect(car.ot, 100);
      expect(bike.ov, car.ov);
      expect(bike.uv, car.uv);
      expect(bike.ot, car.ot);
    });

    test('every category has a row — an unlisted one would resolve to nothing '
        'and warn about nobody', () {
      for (final c in DeclaredCategory.values) {
        expect(kCategoryDefaults[c], isNotNull, reason: c.storageKey);
      }
    });
  });

  group('§3.2.2 — the power bank watches heat and nothing else', () {
    // 🔵 2026-08-22 — every suppression test in this group used to establish
    // its premise with `category: DeclaredCategory.powerBank`, i.e. with the
    // owner's tap. They now establish it from the WIRE (design 0080 §7.5.1.1 A),
    // because the ruling is that the declaration must not decide this. The
    // expected outcomes are identical; what changed is which input produces
    // them, and that is the entire point of the fix.
    test('OT is 50 °C and is labelled as OURS, not the device\'s', () {
      final r = resolveThresholds(
        category: DeclaredCategory.powerBank,
        wireClass: ProductClass.powerBank,
      );

      expect(r.ot.value, 50);
      expect(r.ot.value, kPowerBankOtDefaultC);
      expect(r.ot.source, ThresholdSource.appDefault,
          reason: 'the badge on screen has to read "App 預設". No power bank in '
              'the corpus has ever reported a 0x2B, so calling this '
              'device-sourced would be a fabrication');
    });

    test('OV and UV are unset once the wire says 0x22', () {
      final r = resolveThresholds(
        category: DeclaredCategory.powerBank,
        wireClass: ProductClass.powerBank,
      );

      expect(r.ov, ResolvedThreshold.unavailable);
      expect(r.uv, ResolvedThreshold.unavailable);
      expect(r.hasAny, isTrue, reason: 'the unit is still watched — for heat');
    });

    test('a reported 0x2B could not turn the voltages back on', () {
      // No power bank has ever sent one (0 occurrences in 49 batches), so this
      // is a defence against a future decoder change rather than against
      // observed traffic. It matters because PVLT on this class is a ~3.7 V
      // CELL voltage: a 12 V-scale limit applied to it is not a wrong number,
      // it is a comparison between two different quantities.
      final r = resolveThresholds(
        reported: _reported(
          ov: 15.0,
          uv: 12.0,
          ot: 80,
          deviceType: kPowerBankDeviceType,
        ),
        category: DeclaredCategory.powerBank,
      );

      expect(r.ov, ResolvedThreshold.unavailable);
      expect(r.uv, ResolvedThreshold.unavailable);
      expect(r.ot, const ResolvedThreshold(80, ThresholdSource.device),
          reason: 'temperature is the one field this class does report, and a '
              'reported value still outranks our 50');
    });

    test('a user-typed voltage could not turn them on either', () {
      // The UI will not offer the rows at all (§3.2.2 — "不是顯示成灰色停用"),
      // so this should be unreachable through the app. It is asserted anyway
      // because the columns exist in v22 and an import, a migration or a
      // category changed AFTER the fact could each put a number there.
      final r = resolveThresholds(
        userOv: 4.3,
        userUv: 3.0,
        userOt: 45,
        category: DeclaredCategory.powerBank,
        wireClass: ProductClass.powerBank,
      );

      expect(r.ov, ResolvedThreshold.unavailable);
      expect(r.uv, ResolvedThreshold.unavailable);
      expect(r.ot, const ResolvedThreshold(45, ThresholdSource.user),
          reason: 'the ruling is about voltage; the user still owns the '
              'temperature limit');
    });

    test('an undeclared, unclassified unit is simply unknown', () {
      // Neither input present — the commonest real state, since most owners
      // never fill the form in and the class byte only arrives on connect.
      // Layer ④ catches it, so the outcome is silence, by a different route
      // than the suppression above.
      final r = resolveThresholds();
      expect(r.hasAny, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  group('§7.5.1 — the declaration supplies numbers, the wire supplies gates',
      () {
    // The 2026-08-22 ruling, and the four cases it turns on. Design 0066's rule
    // (`declared_device_model.dart`) is that a declared value gates nothing;
    // design 0080's first cut gated the two voltage alarms on it. What follows
    // is the regression suite for that, and the first test is the incident
    // itself.
    test('A — a power bank DECLARED as a car battery still gets no UV alarm',
        () {
      // 🔴 THE case. The owner taps the wrong entry in a five-item list; the
      // unit is a ~3.7 V cell reporting on PVLT; the car-battery row would put
      // UV at 12.0 V. That is a permanent, unclearable under-voltage warning
      // manufactured entirely out of a dropdown — and under the old code it is
      // exactly what happened.
      final r = resolveThresholds(
        category: DeclaredCategory.carBattery,
        reported: _reported(deviceType: kPowerBankDeviceType),
      );

      expect(r.ov, ResolvedThreshold.unavailable);
      expect(r.uv, ResolvedThreshold.unavailable,
          reason: 'the wire said 0x22; no tap in the UI can put a 12 V limit '
              'on a cell voltage');
      expect(r.ot, ResolvedThreshold.unavailable,
          reason: 'and 80 °C is not applied either — the declaration is '
              'contradicted, so layer ③ says nothing at all (§7.5.1.1 B)');
    });

    test('B — a car battery DECLARED as a power bank keeps its voltage alarms',
        () {
      // The mirror image, and the more dangerous direction of the two: here the
      // old code SILENCED a real 12 V pack's under-voltage alarm because of a
      // mis-tap. A missing warning is worse than a false one — the user never
      // finds out it was missing.
      final r = resolveThresholds(
        category: DeclaredCategory.powerBank,
        reported: _reported(
          ov: 15.0,
          uv: 12.0,
          ot: 80,
          deviceType: kSmartBatteryDeviceType,
        ),
      );

      expect(r.ov, const ResolvedThreshold(15.0, ThresholdSource.device));
      expect(r.uv, const ResolvedThreshold(12.0, ThresholdSource.device),
          reason: 'the unit itself said 12.0 on the wire; a declaration cannot '
              'switch that off');
      expect(r.ot, const ResolvedThreshold(80, ThresholdSource.device));
    });

    test('B — a contradicted declaration supplies no fallback at all', () {
      // Same shape as above but with no 0x2B to fall back on, which isolates
      // layer ③. A capacitor declared as a battery could take 15.0/12.0/80 from
      // the table, and it would be wrong by 0.2 V, 0.5 V and 20 °C. One of the
      // two inputs is a mistake and nothing here can tell which, so the honest
      // answer is layer ④ — 不猜勝於猜錯.
      final r = resolveThresholds(
        category: DeclaredCategory.carBattery,
        wireClass: ProductClass.supercapacitor,
      );

      for (final k in AlertKind.values) {
        expect(r[k].source, ThresholdSource.none, reason: k.name);
        expect(r[k].value, isNull, reason: k.name);
      }
      expect(r.hasAny, isFalse);
    });

    test('B — an AGREEING declaration is consulted as normal', () {
      // The control for the test above: same category, same layer, wire class
      // that matches. Without this pair, a bug that simply disabled layer ③
      // would pass the mismatch test.
      final r = resolveThresholds(
        category: DeclaredCategory.carBattery,
        wireClass: ProductClass.smartBattery,
      );

      expect(r.ov, const ResolvedThreshold(15.0, ThresholdSource.appDefault));
      expect(r.uv, const ResolvedThreshold(12.0, ThresholdSource.appDefault));
      expect(r.ot, const ResolvedThreshold(80, ThresholdSource.appDefault));
    });

    test('C — an unknown wire class suppresses nothing and blocks nothing', () {
      // A saved device with no link open, or a `0x10` that has not arrived yet,
      // or a hardware generation this build has never seen. Nothing has claimed
      // it is a power bank, so voltage is watched; nothing has contradicted the
      // declaration, so layer ③ still speaks. Both halves matter: silence here
      // would be a guess just as much as a warning would be.
      final r = resolveThresholds(category: DeclaredCategory.motorcycleBattery);

      expect(r.ov, const ResolvedThreshold(15.0, ThresholdSource.appDefault));
      expect(r.uv, const ResolvedThreshold(11.0, ThresholdSource.appDefault),
          reason: 'the bike row, and evaluated — §7.5.1.1 C');
      expect(r.ot, const ResolvedThreshold(80, ThresholdSource.appDefault));
    });

    test('C — a declared power bank with no wire class is NOT voltage-muted',
        () {
      // Subtle, and worth pinning precisely because the outcome looks identical
      // to the suppressed case: the two voltage fields are unset either way.
      // They are unset here because the power-bank ROW has no voltage cells,
      // not because anything was muted. If a future edit ever puts numbers in
      // that row, this test is what will notice that they now come through.
      final r = resolveThresholds(
        category: DeclaredCategory.powerBank,
        userUv: 3.0,
      );

      expect(r.uv, const ResolvedThreshold(3.0, ThresholdSource.user),
          reason: 'no wire evidence of 0x22 ⇒ nothing is suppressed, so the '
              'user value survives — the declaration alone must not gate');
      expect(r.ot.value, kPowerBankOtDefaultC);
    });

    test('the live device-type byte outranks the persisted class', () {
      // A restored backup or a re-used MAC can leave a stale product_class in
      // saved_devices. What is in front of us wins.
      final r = resolveThresholds(
        wireClass: ProductClass.smartBattery,
        reported: _reported(uv: 12.0, deviceType: kPowerBankDeviceType),
      );

      expect(r.uv, ResolvedThreshold.unavailable,
          reason: 'the byte on this link says 0x22, whatever the database '
              'remembers');
    });

    test('the persisted class stands in until the byte arrives', () {
      // The offline / pre-0x10 path: a sample exists but carries no device
      // type, so `fromDeviceType(null)` is unknown and the stored answer is the
      // only evidence there is.
      final r = resolveThresholds(
        wireClass: ProductClass.powerBank,
        reported: _reported(uv: 12.0),
      );

      expect(r.uv, ResolvedThreshold.unavailable);
    });
  });

  group('value semantics', () {
    test('ResolvedThreshold compares by value, so a rebuild is not a change',
        () {
      // P2 re-resolves on every settings edit and on every `ready`. Without
      // this, an identical re-resolution would look like new state to any
      // `==`-based diff and repaint the badge.
      expect(const ResolvedThreshold(15.0, ThresholdSource.device),
          const ResolvedThreshold(15.0, ThresholdSource.device));
      expect(const ResolvedThreshold(15.0, ThresholdSource.device),
          isNot(const ResolvedThreshold(15.0, ThresholdSource.user)),
          reason: 'same number, different provenance — a DIFFERENT badge, so '
              'not the same value');
      expect(
          resolveThresholds(reported: _reported(ov: 15.0, uv: 12.0, ot: 80)),
          resolveThresholds(reported: _reported(ov: 15.0, uv: 12.0, ot: 80)));
    });

    test('AlertKind knows which unit it is measured in', () {
      expect(AlertKind.overVoltage.isVoltage, isTrue);
      expect(AlertKind.underVoltage.isVoltage, isTrue);
      expect(AlertKind.overTemperature.isVoltage, isFalse);
    });
  });
}
