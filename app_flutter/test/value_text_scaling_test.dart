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

  // The gauge's centre readout is inside a FittedBox that is ALREADY saturated
  // at every scale (measured: 135.96 × 24.72 from 1.0 to 2.0), so switching it
  // to Text.rich cannot make it bigger on its own — the dial diameter is the
  // binding constraint. This test pins the honest current behaviour so that
  // whoever widens the dial sees this expectation fail and updates it, rather
  // than believing the number already scales.
  testWidgets('gauge readout is capped by the dial, not by the text scale',
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
    // Doubling the text scale moves it by under a pixel (layout rounding),
    // i.e. it is pinned by the ring, not by the scale. If this ever fails
    // because `large` grew, the dial has been widened — good, but update the
    // comment in pvlt_gauge.dart and this test together.
    expect(large.width, closeTo(small.width, 1.0));
    expect(large.height, closeTo(small.height, 1.0));
  });
}
