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
// 🔵 2026-08-22 (second ruling, §7.5.6) — nearly every call below grew a
// `wireClass:` argument. That is not boilerplate: an unclassified unit is now
// not watched AT ALL, so a fixture that omits the class no longer exercises the
// layers, it exercises the device-level gate. Where the omission was the point
// of the test, the test says so.
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
        reported: _reported(
          ov: 15.0,
          uv: 12.0,
          ot: 80,
          deviceType: kSmartBatteryDeviceType,
        ),
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
        reported: _reported(
          ov: 16.0,
          uv: 11.5,
          ot: 100,
          deviceType: kSuperCapacitorGen3DeviceType,
        ),
        category: DeclaredCategory.carCapacitor,
      );

      expect(r.ov, const ResolvedThreshold(16.0, ThresholdSource.device));
      expect(r.ov.value, isNot(kCategoryDefaults[DeclaredCategory.carCapacitor]!.ov),
          reason: 'the two layers genuinely disagree here — that is the point '
              'of the test, not a coincidence of the fixture');
    });

    test('③ the table answers when the unit reported nothing', () {
      // 🔵 The `wireClass` is new (§7.5.6 C-1): a battery is the ONE class whose
      // layer ③ needs both halves — `0x02` says "battery", the declaration says
      // which kind, and neither alone picks a row.
      final r = resolveThresholds(
        category: DeclaredCategory.motorcycleBattery,
        wireClass: ProductClass.smartBattery,
      );

      expect(r.ov, const ResolvedThreshold(15.0, ThresholdSource.appDefault));
      expect(r.uv, const ResolvedThreshold(11.0, ThresholdSource.appDefault));
      expect(r.ot, const ResolvedThreshold(80, ThresholdSource.appDefault));
    });

    test('④ nothing anywhere ⇒ not evaluated, and never guessed', () {
      // 🔵 Since §7.5.6 C-2 this call is stopped by the DEVICE gate rather than
      // by four empty layers; the assertions are unchanged because the outcome
      // is, and `disabledReason` is what now tells the two apart (asserted in
      // the §7.5.6 group).
      final r = resolveThresholds(wireClass: ProductClass.smartBattery);

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
      final r = resolveThresholds(wireClass: ProductClass.powerBank);
      expect(r.ov.source, ThresholdSource.none);
      expect(r.ot.isSet, isTrue);
    });
  });

  group('§3.1 — resolution is PER FIELD, not per unit', () {
    test('a user-set UV leaves OV and OT on the device\'s own values', () {
      final r = resolveThresholds(
        userUv: 12.4,
        reported: _reported(
          ov: 15.0,
          uv: 12.0,
          ot: 80,
          deviceType: kSmartBatteryDeviceType,
        ),
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
        reported: _reported(ov: 15.0, deviceType: kSmartBatteryDeviceType),
        category: DeclaredCategory.carBattery,
      );

      expect(r.uv.source, ThresholdSource.user);
      expect(r.ov.source, ThresholdSource.device);
      expect(r.ot.source, ThresholdSource.appDefault);
      expect(r.ot.value, 80);
    });

    test('operator [] agrees with the named fields', () {
      final r = resolveThresholds(
        reported: _reported(
          ov: 15.0,
          uv: 12.0,
          ot: 80,
          deviceType: kSmartBatteryDeviceType,
        ),
      );
      expect(r.hasAny, isTrue,
          reason: 'a fixture where all three are unset would make the three '
              'assertions below pass without comparing anything');
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
      // 🔵 The ROUTE changed on 2026-08-22 (§7.5.6 C-2): this used to fall
      // through four empty layers, and is now stopped at the device gate. The
      // assertion is deliberately left as-is, because "silence" is what this
      // test was ever about; the gate's own behaviour is pinned below.
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
      // 🔵 2026-08-22, §7.5.6 C-1 — this assertion changed MEANING, not just
      // value. It used to read `ResolvedThreshold.unavailable` with the reason
      // "the declaration is contradicted, so layer ③ says nothing at all
      // (§7.5.1.1 B)". That turned out to punish the wrong party: the ruling's
      // whole point is that a power bank gets a heat alarm, and the old rule
      // took it away from precisely the unit whose owner had mis-tapped. Layer
      // ③ is keyed on the wire now, so the wrong tap is simply ignored.
      expect(r.ot, const ResolvedThreshold(50, ThresholdSource.appDefault),
          reason: 'the wire says power bank, so the power-bank row applies and '
              'the contradicted declaration is not consulted at all');
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

    test('B — a contradicted declaration is ignored, and the WIRE\'s row is '
        'used', () {
      // 🔵 2026-08-22, §7.5.6 C-1 — this test previously asserted the opposite
      // outcome ("a contradicted declaration supplies no fallback at all":
      // three `ThresholdSource.none`, on the 不猜勝於猜錯 reading of §7.5.1.1 B).
      // It is inverted here because the ruling moved the coin toss: with the
      // declaration merely INDEXING the table, "car battery + 0x17" was two
      // claims of which one had to be discarded; with the wire indexing it, the
      // declaration is not a claim about which row to read at all, so there is
      // nothing left to be in conflict with. A capacitor gets the capacitor row
      // because it is a capacitor.
      final r = resolveThresholds(
        category: DeclaredCategory.carBattery,
        wireClass: ProductClass.supercapacitor,
      );

      expect(r.ov, const ResolvedThreshold(14.8, ThresholdSource.appDefault));
      expect(r.uv, const ResolvedThreshold(11.5, ThresholdSource.appDefault));
      expect(r.ot, const ResolvedThreshold(100, ThresholdSource.appDefault),
          reason: 'the capacitor row, not the 15.0/12.0/80 the owner\'s tap '
              'would have asked for');
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

    // 🔴 2026-08-22 — the two tests that stood here ("C — an unknown wire class
    // suppresses nothing and blocks nothing" and "C — a declared power bank
    // with no wire class is NOT voltage-muted") were DELETED, not adjusted.
    // Both asserted that an unclassified unit keeps resolving its layers
    // normally, which is §7.5.1.1 C — the one row of that ruling §7.5.6 C-2
    // overturned outright. Their subject matter now lives in the §7.5.6 group
    // below, with the opposite expectation; keeping them here as skipped or
    // renamed cases would leave two tests named "C" asserting contradictory
    // things about the same input, which is the failure this repo logs as
    // "同檔兩處互相矛盾".

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

  // ---------------------------------------------------------------------------
  group('§7.5.6 C-1 — layer ③ is keyed on the WIRE, the declaration only breaks '
      'the battery tie', () {
    // The second ruling of 2026-08-22, and the two field-reported holes that
    // caused it. Both were found by running the §7.5.1 fix, not by reading it —
    // which is why they get named regression tests rather than a note.
    test('hole ① — a power bank with NO declaration is still watched for heat',
        () {
      // 🔴 THE regression. A power bank never reports a `0x2B` (0 occurrences
      // in 49 batches), so layer ② is empty for the entire class; under the
      // declaration-keyed table, layer ③ needed a form the owner had probably
      // never filled in. Result: the Q1 ruling "行動電源只做溫度監控" applied to
      // nobody by default. The unit says what it is; that is enough.
      final r = resolveThresholds(
        reported: _reported(deviceType: kPowerBankDeviceType),
      );

      expect(r.ot, const ResolvedThreshold(50, ThresholdSource.appDefault));
      expect(r.ov, ResolvedThreshold.unavailable);
      expect(r.uv, ResolvedThreshold.unavailable,
          reason: 'the voltage suppression is untouched by this ruling — a '
              'cell voltage still has no 12 V-scale limit');
    });

    test('hole ② — a power bank declared as a car battery keeps that heat alarm',
        () {
      // The two holes stacked: the mis-tap used to be "contradicted" and cost
      // the unit its LAST remaining alarm. Same expectation as hole ①, because
      // the declaration is not consulted for this class at all.
      final r = resolveThresholds(
        category: DeclaredCategory.carBattery,
        wireClass: ProductClass.powerBank,
      );

      expect(r.ot, const ResolvedThreshold(50, ThresholdSource.appDefault));
      expect(r.ov, ResolvedThreshold.unavailable);
      expect(r.uv, ResolvedThreshold.unavailable);
    });

    test('a capacitor needs no declaration — one row serves both kinds', () {
      // §3.2.1: the bike and car capacitor rows are identical, so the wire's
      // inability to separate `0x17`/`0x18` into two kinds costs nothing here.
      // The declaration is simply not asked.
      final r = resolveThresholds(wireClass: ProductClass.supercapacitor);

      expect(r.ov, const ResolvedThreshold(14.8, ThresholdSource.appDefault));
      expect(r.uv, const ResolvedThreshold(11.5, ThresholdSource.appDefault));
      expect(r.ot, const ResolvedThreshold(100, ThresholdSource.appDefault));
    });

    test('a capacitor declared as the WRONG kind of capacitor is unaffected',
        () {
      // Follows from the row being shared, and worth pinning: it is the reason
      // the wire-keyed lookup can drop the contradiction check without losing
      // anything for this class.
      final bike = resolveThresholds(
        wireClass: ProductClass.supercapacitor,
        category: DeclaredCategory.motorcycleCapacitor,
      );
      final car = resolveThresholds(
        wireClass: ProductClass.supercapacitor,
        category: DeclaredCategory.carCapacitor,
      );
      expect(bike, car);
      expect(bike, resolveThresholds(wireClass: ProductClass.supercapacitor));
    });

    test('a battery with NO declaration gets no layer ③ — but keeps ① and ②',
        () {
      // The one gap the ruling knowingly leaves open, and the test is in two
      // halves so that "the battery is silent" cannot be mistaken for "the
      // battery is broken". `0x02` cannot say bike-or-car and the two rows
      // differ by a whole volt of UV, so there is no row to take.
      final noDeclaration =
          resolveThresholds(wireClass: ProductClass.smartBattery);

      for (final k in AlertKind.values) {
        expect(noDeclaration[k].source, ThresholdSource.none, reason: k.name);
      }
      expect(noDeclaration.isDeviceUnwatched, isFalse,
          reason: 'the DEVICE is recognised — it is only layer ③ that has '
              'nothing to say, which the UI renders differently (§7.5.6 C-3)');

      // Same unit, same absent declaration, one `0x2B` later. If this half ever
      // fails, the wire-keyed layer ③ has leaked upwards into layer ②.
      final withReported = resolveThresholds(
        wireClass: ProductClass.smartBattery,
        reported: _reported(ov: 15.0, uv: 12.0, ot: 80),
      );

      expect(withReported.ov, const ResolvedThreshold(15.0, ThresholdSource.device));
      expect(withReported.uv, const ResolvedThreshold(12.0, ThresholdSource.device));
      expect(withReported.ot, const ResolvedThreshold(80, ThresholdSource.device));
    });

    test('the declaration decides bike UV 11.0 vs car UV 12.0 — its last job',
        () {
      final bike = resolveThresholds(
        wireClass: ProductClass.smartBattery,
        category: DeclaredCategory.motorcycleBattery,
      );
      final car = resolveThresholds(
        wireClass: ProductClass.smartBattery,
        category: DeclaredCategory.carBattery,
      );

      expect(bike.uv, const ResolvedThreshold(11.0, ThresholdSource.appDefault));
      expect(car.uv, const ResolvedThreshold(12.0, ThresholdSource.appDefault));
      expect(bike.ov, car.ov, reason: 'both rows are 15.0 — only UV differs');
      expect(bike.ot, car.ot);
    });

    test('a battery declared as something that is not a battery gets no row',
        () {
      // "Absent" and "contradicting" collapse into the same case now, which is
      // the simplification the ruling bought: neither of them names one of the
      // two admissible rows.
      for (final c in <DeclaredCategory>[
        DeclaredCategory.carCapacitor,
        DeclaredCategory.motorcycleCapacitor,
        DeclaredCategory.powerBank,
      ]) {
        final r = resolveThresholds(
          wireClass: ProductClass.smartBattery,
          category: c,
        );
        expect(r.hasAny, isFalse, reason: c.storageKey);
      }
    });

    test('categoryDefaultsFor is the layer, and it is exhaustive over the wire',
        () {
      // Pinned directly because P2 reads it to render the "App 預設" badge
      // without re-running the whole resolution.
      expect(
          categoryDefaultsFor(wireClass: ProductClass.powerBank)!.ot,
          kPowerBankOtDefaultC);
      expect(categoryDefaultsFor(wireClass: ProductClass.powerBank)!.uv, isNull);
      expect(categoryDefaultsFor(wireClass: ProductClass.supercapacitor)!.ov,
          14.8);
      expect(categoryDefaultsFor(wireClass: ProductClass.smartBattery), isNull);
      expect(categoryDefaultsFor(wireClass: ProductClass.unknown), isNull,
          reason: 'unreachable through resolveThresholds, which returns at the '
              'device gate first — but a direct caller must still get the safe '
              'answer rather than an exception');
    });
  });

  // ---------------------------------------------------------------------------
  group('§7.5.6 C-2 — an unclassified unit is not watched at all', () {
    test('no exceptions: a reported 0x2B does not buy its way in', () {
      // 🔴 The first back door the ruling names, and the plausible one — layer
      // ② is per-unit evidence that needs no table of ours. It is refused
      // because a threshold is only meaningful next to a quantity, and an
      // unrecognised class does not tell us which quantity PVLT is. Compare
      // the power bank, where "voltage" is a ~3.7 V cell.
      final r = resolveThresholds(
        reported: _reported(ov: 15.0, uv: 12.0, ot: 80, deviceType: 0x33),
      );

      for (final k in AlertKind.values) {
        expect(r[k].source, ThresholdSource.none, reason: k.name);
        expect(r[k].value, isNull, reason: k.name);
      }
      expect(r.hasAny, isFalse);
    });

    test('no exceptions: a user-typed threshold does not buy its way in either',
        () {
      // 🔴 The second back door, and the uncomfortable one, because layer ①
      // outranks everything else in the entire design. It loses here anyway: a
      // user typing 12.0 into a unit neither of us has identified is making the
      // same guess we just declined to make, and we would be the ones ringing
      // the bell for it.
      final r = resolveThresholds(
        userOv: 15.0,
        userUv: 12.0,
        userOt: 60,
        reported: _reported(deviceType: 0x33),
      );

      for (final k in AlertKind.values) {
        expect(r[k].source, ThresholdSource.none, reason: k.name);
      }
      expect(r.hasAny, isFalse);
    });

    test('both back doors at once, and the persisted class is unknown too', () {
      final r = resolveThresholds(
        userUv: 12.0,
        reported: _reported(ov: 15.0, uv: 12.0, ot: 80, deviceType: 0x33),
        category: DeclaredCategory.carBattery,
        wireClass: ProductClass.unknown,
      );
      expect(r.hasAny, isFalse);
      expect(r.isDeviceUnwatched, isTrue);
    });

    test('"not arrived yet" and "arrived but unrecognised" are DIFFERENT', () {
      // 🔑 The distinction §7.5.6 C-2 requires the API to carry. Every single
      // connection spends its first frames in `deviceTypePending`, so a screen
      // that could not tell the two apart would flash "無法提供警告" at every
      // connect — a false alarm about the alarms.
      expect(resolveThresholds().disabledReason,
          AlertsDisabledReason.deviceTypePending,
          reason: 'offline saved device: no sample at all');
      expect(resolveThresholds(reported: _reported()).disabledReason,
          AlertsDisabledReason.deviceTypePending,
          reason: 'connected, telemetry flowing, 0x10 not seen yet');
      expect(resolveThresholds(reported: _reported(deviceType: 0x33)).disabledReason,
          AlertsDisabledReason.deviceTypeUnrecognised,
          reason: 'a byte exists and product_class.dart should be taught it — '
              'this is the one the UI may show');
    });

    test('a recognised unit carries no disabled reason', () {
      expect(resolveThresholds(wireClass: ProductClass.smartBattery).disabledReason,
          AlertsDisabledReason.none);
      expect(resolveThresholds(wireClass: ProductClass.smartBattery)
          .isDeviceUnwatched, isFalse);
    });

    test('AlertThresholds.none and .unwatched are not equal', () {
      // Both have three empty fields and both answer `hasAny == false`, so the
      // evaluator treats them alike — correctly. The screen must not: one says
      // "no numbers for this device", the other "we do not know what this
      // device is". A `==` that could not separate them would let P2's diff
      // miss the transition between them.
      expect(AlertThresholds.none,
          isNot(const AlertThresholds.unwatched(
              AlertsDisabledReason.deviceTypeUnrecognised)));
      expect(AlertThresholds.none.hasAny, isFalse);
      expect(
          const AlertThresholds.unwatched(AlertsDisabledReason.deviceTypePending)
              .hasAny,
          isFalse);
    });

    // 🔴 ~~test('a persisted class still rescues an unrecognised live byte')~~
    // REVERSED by §7.5.7 (third ruling of 2026-08-22), not deleted silently:
    // it used to assert `isDeviceUnwatched == false` for exactly the input the
    // group below now expects to be unwatched. Its old rationale ("the gate
    // asks the RESOLVED class, and an earlier session that recognised this unit
    // is evidence like any other") is what the owner ruled against — an
    // unrecognised byte is not the absence of evidence, it is evidence of
    // change, and it is newer than the record. Kept as a note rather than a
    // renamed test so the file never holds two cases asserting opposite things
    // about `deviceType: 0x33` + a good `wireClass` ("同檔兩處互相矛盾").
  });

  // ---------------------------------------------------------------------------
  group('§7.5.7 — an unrecognised live byte outranks the persisted class', () {
    // The third ruling of 2026-08-22, closing the gap the C-2 implementation
    // reported against itself: `live == unknown` used to fall back to the
    // persisted class, which merged "no byte" and "a byte we cannot read" into
    // one branch. They are opposites — no evidence versus fresh evidence of
    // change — so all three rows of the ruling's table get a test.

    test('row 1 — no byte yet: the persisted class carries the evaluation', () {
      // NOT `deviceTypePending`. Nothing has contradicted the record, and a
      // screen that went dark for the first frames of every connect would be
      // flashing a false alarm about the alarms.
      final r = resolveThresholds(
        wireClass: ProductClass.smartBattery,
        reported: _reported(ov: 15.2, ot: 62),
      );

      expect(r.isDeviceUnwatched, isFalse);
      expect(r.disabledReason, AlertsDisabledReason.none);
      expect(r.ov, const ResolvedThreshold(15.2, ThresholdSource.device),
          reason: 'evaluated normally on the strength of the stored class');
    });

    test('row 2 — an unrecognised byte disables the unit even though the '
        'persisted class is a good one', () {
      // 🔑 THE fix. 0x31 is not in `product_class.dart`; the unit is saying "I
      // am something" and this build cannot name it. That statement is newer
      // than `saved_devices.product_class`, so the record loses — which is also
      // what a firmware bump and a new hardware generation look like from here
      // (`0x18` read as unknown for a full day in 2026-08).
      final r = resolveThresholds(
        wireClass: ProductClass.smartBattery,
        reported: _reported(ov: 15.2, uv: 12.4, ot: 62, deviceType: 0x31),
      );

      for (final k in AlertKind.values) {
        expect(r[k], ResolvedThreshold.unavailable, reason: k.name);
      }
      expect(r.disabledReason, AlertsDisabledReason.deviceTypeUnrecognised,
          reason: 'the durable case, and the one the UI may show');
    });

    test('row 3 — no byte and no persisted class is the pending case', () {
      final r = resolveThresholds(
        wireClass: ProductClass.unknown,
        reported: _reported(ov: 15.2),
      );

      expect(r.disabledReason, AlertsDisabledReason.deviceTypePending,
          reason: 'transient: the 0x10 has not been seen on this link');
      expect(r.hasAny, isFalse);
    });

    test('row 2 beats layer ① too — a user threshold does not rescue it '
        'either', () {
      // The C-2 back doors do not reopen just because a persisted class exists:
      // the gate still returns before layer ① is read.
      final r = resolveThresholds(
        userUv: 12.0,
        wireClass: ProductClass.supercapacitor,
        reported: _reported(deviceType: 0x31),
      );

      expect(r.hasAny, isFalse);
      expect(r.disabledReason, AlertsDisabledReason.deviceTypeUnrecognised);
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
      AlertThresholds resolved() => resolveThresholds(
            reported: _reported(
              ov: 15.0,
              uv: 12.0,
              ot: 80,
              deviceType: kSmartBatteryDeviceType,
            ),
          );
      expect(resolved(), resolved());
      expect(resolved().hasAny, isTrue,
          reason: 'two identically EMPTY results would compare equal too, and '
              'would prove nothing about the fields');
    });

    test('AlertKind knows which unit it is measured in', () {
      expect(AlertKind.overVoltage.isVoltage, isTrue);
      expect(AlertKind.underVoltage.isVoltage, isTrue);
      expect(AlertKind.overTemperature.isVoltage, isFalse);
    });
  });
}
