// The dashboard's NUMBERS must honour the OS text-size setting.
//
// Found 2026-08-03: the two places that render a value + unit in one line used
// the raw `RichText`, whose textScaler defaults to `TextScaler.noScaling`
// (Flutter `basic.dart`), while every label beside them is a plain `Text` and
// therefore does scale. So a user who enlarged their system font got bigger
// labels and identically-sized readings — the opposite of what they asked for.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/pvlt_gauge.dart';
import 'package:open_smart_batt/ui/dashboard/readout_grid.dart';

void main() {
  Widget host({required double scale, required Widget child}) => MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(body: Center(child: child)),
        ),
      );

  testWidgets('readout values grow with the text scale', (tester) async {
    Future<Size> measure(double scale) async {
      await tester.pumpWidget(host(
        scale: scale,
        child: const SizedBox(
          width: 340,
          child: ReadoutGrid(items: [
            Readout(
                icon: Icons.thermostat,
                label: 'TEMP',
                value: '31',
                unit: '°C'),
          ]),
        ),
      ));
      return tester.getSize(find.textContaining('31'));
    }

    final small = await measure(1.0);
    final large = await measure(1.5);
    expect(large.height, greaterThan(small.height),
        reason: 'the value ignored the text scale (raw RichText)');
  });

  // The gauge's centre readout sits in a FittedBox that is already saturated,
  // so at a FIXED dial size the number cannot grow no matter what the text
  // scale is. That is the widget behaving correctly — the dial is the binding
  // constraint, and it is chosen by the caller.
  testWidgets('at a fixed dial size the readout is capped by the ring',
      (tester) async {
    Future<Size> measure(double scale) async {
      await tester.pumpWidget(host(
        scale: scale,
        child: PvltGauge.voltage(
          volts: 14.02,
          caption: 'PVLT',
          subText: null,
          size: 206,
        ),
      ));
      return tester.getSize(find.byType(FittedBox).first);
    }

    final small = await measure(1.0);
    final large = await measure(2.0);
    // Under a pixel apart (layout rounding): pinned by the ring, not the scale.
    expect(large.width, closeTo(small.width, 1.0));
    expect(large.height, closeTo(small.height, 1.0));
  });

  // ...which is why the CALLER grows the dial. AppTheme.gaugeDiameter is the
  // single place that decides, shared by the pack view and the power-bank view.
  group('AppTheme.gaugeDiameter', () {
    Future<double> diameter(
      WidgetTester tester, {
      required double available,
      required double osScale,
    }) async {
      late double result;
      await tester.pumpWidget(host(
        // What main.dart hands down: the OS setting times the app's own bump.
        scale: osScale * AppTheme.baseTextScale,
        child: Builder(builder: (context) {
          result = AppTheme.gaugeDiameter(context, available);
          return const SizedBox();
        }),
      ));
      return result;
    }

    // Card inner width = screen − 15 list padding − 15 card padding, twice.
    double cardWidth(double screen) => screen - 60;

    testWidgets('the default screen does not move', (tester) async {
      // THE regression that matters: a user who never touched their system
      // font must see exactly the layout they see today.
      for (final screen in [320.0, 375.0, 390.0, 440.0]) {
        final w = cardWidth(screen);
        expect(
          await diameter(tester, available: w, osScale: 1.0),
          (w * 0.74).clamp(180.0, 240.0),
          reason: '$screen pt moved at the default text size',
        );
      }
    });

    testWidgets('a user who enlarged text gets a bigger dial', (tester) async {
      final w = cardWidth(390);
      final normal = await diameter(tester, available: w, osScale: 1.0);
      final large = await diameter(tester, available: w, osScale: 1.3);
      expect(large, greaterThan(normal));
      expect(large, closeTo(240 * 1.3, 0.01));
    });

    testWidgets('never wider than the card', (tester) async {
      // 320 pt with a big system font: the cap would be 312 but only 260 is
      // there. Overflowing the card would be a worse bug than a small dial.
      final w = cardWidth(320);
      expect(await diameter(tester, available: w, osScale: 1.3),
          lessThanOrEqualTo(w));
    });

    testWidgets('a SMALLER system font does not shrink the dial',
        (tester) async {
      // Android's smallest step is 0.85. That user asked for more content per
      // screen, not for a smaller instrument.
      final w = cardWidth(390);
      expect(await diameter(tester, available: w, osScale: 0.85),
          await diameter(tester, available: w, osScale: 1.0));
    });

    testWidgets('the readout really does grow once the dial does',
        (tester) async {
      Future<Size> readout(double osScale) async {
        final size = await diameter(tester, available: cardWidth(390), osScale: osScale);
        await tester.pumpWidget(host(
          scale: osScale * AppTheme.baseTextScale,
          child: PvltGauge.voltage(
            volts: 14.02,
            caption: 'PVLT',
            subText: null,
            size: size,
          ),
        ));
        return tester.getSize(find.byType(FittedBox).first);
      }

      final normal = await readout(1.0);
      final large = await readout(1.3);
      expect(large.height, greaterThan(normal.height),
          reason: 'the whole point of growing the dial');
    });
  });
}
