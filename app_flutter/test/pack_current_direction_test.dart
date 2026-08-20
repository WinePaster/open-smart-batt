// Pack current direction (design 0056 — owner's 2026-08-11 ruling).
//
// The battery family's `0x2E` was established as **negative = discharge,
// positive = charge** on 2026-08-11 (`docs/protocol/telemetry-decoding.md`
// §8.2), which removed the only reason the pack screens printed a bare signed
// number and named no direction. FB-47 is what a bare signed number costs: a
// dealer, and then the owner who had ruled on the sign convention himself, both
// read one as a DEFECT rather than as a direction.
//
// The whole hazard of fixing it is one line long: **the two families sign
// current the opposite way round** (a power bank's `0x4A − 0x49` is positive
// while DIScharging). So the tests below come in three parts:
//
//   D1–D5 — the pack derivation itself, including the quantisation dead-band.
//   D6    — the anti-unification guard: the same number, opposite verdicts. A
//           future "simplification" that routes both families through one
//           function fails here rather than in the field.
//   R1–R4 — what the pack card actually draws: magnitude, badge, no stray
//           minus, and the chart's direction key. Plus the power bank drawing
//           exactly what it drew before.
//
// CLEAN-ROOM: every expectation derives from this project's own protocol notes,
// its own captures and its own source. No vendor binary was consulted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/dashboard_cards.dart';
import 'package:open_smart_batt/ui/dashboard/power_flow.dart';

TelemetrySample _pack({double? current}) => TelemetrySample(
      timestamp: DateTime(2026, 8, 11, 9, 30),
      pvlt: 13.87,
      svlt: 13.9,
      temperatureC: 41,
      sohBucket: 88,
      current: current,
    );

CardTelemetry _tele(TelemetrySample s, {LiveTrendBuffer? trend}) =>
    StaticCardTelemetry(
      sample: s,
      trend: trend ?? LiveTrendBuffer(),
      tempUnit: TempUnit.celsius,
    );

Future<void> _pump(
  WidgetTester tester, {
  required DisplayModule module,
  required ProductClass cls,
  required CardTelemetry tele,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(900, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: locale,
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
          width: 360,
          child: Builder(
            builder: (c) =>
                dashboardCardFor(c, module,
                    shellClass: cls,
                    surface: CardSurface.deviceDetail,
                    tele: tele) ??
                const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  // ===========================================================================
  // D — the derivation
  // ===========================================================================
  group('packFlowOf — the sign means what §8.2 says it means', () {
    test('D1 negative is DISCHARGE — the cranking magnitudes', () {
      // The five engine starts that settled the convention read −211…−446 A
      // while PVLT collapsed to 0.90–1.87 V. A starter motor is the only
      // multi-hundred-amp thing on the bus and it cannot charge.
      expect(packFlowOf(-211), PowerFlow.discharging);
      expect(packFlowOf(-446), PowerFlow.discharging);
      expect(packFlowOf(-35), PowerFlow.discharging);
    });

    test('D2 positive is CHARGE — the alternator side of the same event', () {
      // Same capture, seconds later: current positive while PVLT climbs to
      // 14.5 V.
      expect(packFlowOf(59), PowerFlow.charging);
      expect(packFlowOf(8), PowerFlow.charging);
    });

    test('D3 zero is at rest, not a direction', () {
      expect(packFlowOf(0), PowerFlow.idle);
      expect(packFlowOf(-0.0), PowerFlow.idle);
    });

    test('D4 ±1 A — one quantisation count — names no direction', () {
      // `0x2E` is 1 A per count, so ±1 is inside the device's own rounding and
      // its sign is the least trustworthy bit it emits. A parked car whose
      // reading dithers 0 / −1 must not flash 「放電中」.
      expect(packFlowOf(1), PowerFlow.idle);
      expect(packFlowOf(-1), PowerFlow.idle);
      // ±2 is the first magnitude that survives a full count of error either
      // way, and it IS a direction.
      expect(packFlowOf(2), PowerFlow.charging);
      expect(packFlowOf(-2), PowerFlow.discharging);
      expect(kPackFlowDeadbandA, 1.5);
    });

    test('D5 no reading is unknown, which is not idle', () {
      expect(packFlowOf(null), PowerFlow.unknown);
    });
  });

  group('D6 the two families are NOT interchangeable', () {
    test('the same number gets opposite verdicts', () {
      // 🔴 The single most important assertion in this file. `0x2E` negative is
      // a pack discharging; `0x4A − 0x49` negative is a power bank CHARGING.
      // Anyone who unifies these two derivations breaks this line.
      expect(packFlowOf(-30), PowerFlow.discharging);
      expect(powerFlowOf(-30), PowerFlow.charging);
      expect(packFlowOf(30), PowerFlow.charging);
      expect(powerFlowOf(30), PowerFlow.discharging);
    });

    test('and they do not share a dead-band either', () {
      // A power bank at 0.5 A is discharging; a pack at 0.5 A is a rounding
      // artefact. Copying one band onto the other family is a defect in both
      // directions at once.
      expect(powerFlowOf(0.5), PowerFlow.discharging);
      expect(packFlowOf(0.5), PowerFlow.idle);
      expect(kPowerFlowDeadbandA, isNot(kPackFlowDeadbandA));
    });
  });

  // ===========================================================================
  // R — what the card draws
  // ===========================================================================
  group('R1 the pack current tile shows a magnitude and names the direction',
      () {
    testWidgets('discharging: 35.0 A + DISCHARGING, and no minus anywhere',
        (tester) async {
      await _pump(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: _tele(_pack(current: -35)));
      expect(find.text('35.0 A', findRichText: true), findsOneWidget);
      expect(find.text('DISCHARGING'), findsOneWidget);
      // The FB-47 regression, stated as a negative: the tile must not print the
      // bare signed number that two separate people read as a fault.
      expect(find.text('-35.0 A', findRichText: true), findsNothing);
    });

    testWidgets('charging: the positive side gets the other word',
        (tester) async {
      await _pump(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: _tele(_pack(current: 59)));
      expect(find.text('59.0 A', findRichText: true), findsOneWidget);
      expect(find.text('CHARGING'), findsOneWidget);
    });

    testWidgets('in-band: a magnitude with no direction claimed',
        (tester) async {
      await _pump(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: _tele(_pack(current: 0)));
      expect(find.text('0.0 A', findRichText: true), findsOneWidget);
      expect(find.text('AT REST'), findsOneWidget);
      expect(find.text('CHARGING'), findsNothing);
      expect(find.text('DISCHARGING'), findsNothing);
    });

    testWidgets('zh renders its own words, not the power bank ones',
        (tester) async {
      await _pump(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: _tele(_pack(current: -35)),
          locale: const Locale('zh'));
      expect(find.text('放電中'), findsOneWidget);
    });

    testWidgets('no current, no tile — the data gate is untouched',
        (tester) async {
      await _pump(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: _tele(_pack()));
      expect(find.text('MAIN CURRENT'), findsNothing);
      expect(find.text('AT REST'), findsNothing);
    });
  });

  group('R2 a capacitor still has no current tile at all', () {
    testWidgets('class gate first: no tile, so no badge either', (tester) async {
      // A capacitor streams `0x2E` as a constant 0.0 A, which is not a
      // measurement (`showsCurrentReadout: false`). Giving it a direction badge
      // would dress that constant up as a reading — the opposite of what the
      // chart footnote exists to say.
      await _pump(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.supercapacitor,
          tele: _tele(_pack(current: 0)));
      expect(find.text('MAIN CURRENT'), findsNothing);
      expect(find.text('AT REST'), findsNothing);
      expect(find.text('DISCHARGING'), findsNothing);
    });
  });

  group('R3 the chart keeps its signed track and gains a key', () {
    LiveTrendBuffer bufferWithSwing() {
      final b = LiveTrendBuffer();
      final t0 = DateTime(2026, 8, 11, 9, 30);
      // The 2026.08.03/001 shape: a swing THROUGH zero inside one minute. The
      // reason `abs()` is forbidden on this track. It ENDS on the discharge
      // side so the header's live value is a negative one — which is what makes
      // the assertion below able to see that the data stayed signed.
      for (final (i, a) in [8.0, 4.0, 0.0, -12.0, -29.0].indexed) {
        b.add(TelemetrySample(
            timestamp: t0.add(Duration(seconds: i)), current: a));
      }
      return b;
    }

    testWidgets('the pack current track prints "+ charge · − discharge"',
        (tester) async {
      await _pump(tester,
          module: DisplayModule.chart,
          cls: ProductClass.smartBattery,
          tele: _tele(_pack(current: -29), trend: bufferWithSwing()));
      expect(find.text('+ charge · − discharge'), findsOneWidget);
      // 🔒 The DATA is still signed and still crosses zero (2026-08-03 ruling,
      // design 0030 §3.2 / §7 Q5). The key explains the axis; it does not
      // rectify it. The track header's live value is the proof: still −29, not
      // 29 with a word beside it.
      expect(find.text('-29 A'), findsOneWidget);
    });

    testWidgets('zh key', (tester) async {
      await _pump(tester,
          module: DisplayModule.chart,
          cls: ProductClass.smartBattery,
          tele: _tele(_pack(current: -29), trend: bufferWithSwing()),
          locale: const Locale('zh'));
      expect(find.text('＋充電 · −放電'), findsOneWidget);
    });

    testWidgets('a power bank chart does NOT get the pack key', (tester) async {
      // Its current is signed the other way round, so this key would be a lie
      // there. The power bank says its direction in words on the SOC dial and
      // the energy-path row instead.
      await _pump(tester,
          module: DisplayModule.chart,
          cls: ProductClass.powerBank,
          tele: _tele(
              TelemetrySample(
                  timestamp: DateTime(2026, 8, 11, 9, 30),
                  deviceType: 0x18,
                  current: 2.72),
              trend: bufferWithSwing()));
      expect(find.text('+ charge · − discharge'), findsNothing);
      expect(find.text('＋充電 · −放電'), findsNothing);
    });
  });

  group('R4 the l10n keys exist in both languages and are distinct', () {
    test('pack direction words are their own strings', () async {
      for (final code in ['en', 'zh']) {
        final l = await AppLocalizations.delegate.load(Locale(code));
        for (final s in [
          l.packDirectionCharging,
          l.packDirectionDischarging,
          l.packDirectionIdle,
          l.dashboardTrackCurrentDirectionKey,
        ]) {
          expect(s, isNotEmpty, reason: '$code: an empty badge is not a word');
        }
        expect(l.packDirectionCharging, isNot(l.packDirectionDischarging));
        // Deliberately NOT asserted equal to the power bank's words: they are
        // separate keys so that a future wording change on one family cannot
        // silently move the other (design 0056 §5). Whether they happen to read
        // the same today is not the point.
        expect(l.packDirectionIdle, isNot(l.packDirectionCharging));
      }
    });
  });
}
