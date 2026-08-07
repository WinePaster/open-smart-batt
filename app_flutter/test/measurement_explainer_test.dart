// The two "how this is measured" sheets (design 0042 §3.9b / 0045 §3.6b).
//
// What is worth pinning here is NOT the wording — it is the two ways these can
// rot without anybody noticing:
//
//  1. The row disappears. Both sheets answer a question people ask AFTER using
//     the feature, so reachability is the whole value; a sheet nobody can open
//     is the same as no sheet.
//  2. 🔴 The numbers drift away from the constants they describe. Both texts
//     quote thresholds the Phase F / Phase 4 road test will tune. A knob moved
//     without the sentence moving leaves the app stating something that is no
//     longer true — to the one user who cared enough to open the sheet.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/state/speed_estimator.dart';
import 'package:open_smart_batt/ui/settings/measurement_explainer.dart';

Widget _host(void Function(BuildContext) onReady) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => onReady(context),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('the speed sheet states the three things a user cannot infer',
      (tester) async {
    await tester.pumpWidget(_host(showSpeedMeasurementExplainer));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
    // Each of these is a real thing a rider hits and cannot explain: a frozen
    // number in a tunnel, a 0 while wheeling the bike, and where the data goes.
    expect(find.text(l10n.explainerSpeedWhat), findsOneWidget);
    expect(find.text(l10n.explainerSpeedHolding), findsOneWidget);
    expect(find.text(l10n.explainerSpeedStill), findsOneWidget);
    expect(find.text(l10n.explainerSpeedNotDone), findsOneWidget);
  });

  testWidgets('the G sheet leads with the limit, not with the feature',
      (tester) async {
    await tester.pumpWidget(_host(showGForceMeasurementExplainer));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
    expect(find.text(l10n.explainerGForceWhat), findsOneWidget);
    expect(find.text(l10n.explainerGForceLean), findsOneWidget);
    expect(find.text(l10n.explainerGForceNotDone), findsOneWidget);
  });

  test('🔴 the still-clamp sentence matches the constant it describes', () {
    // The text says "under 3 km/h reads 0". `vStillMps` is what actually
    // decides that, and design 0042 Phase F will retune it — this is the only
    // thing that will notice if the number moves and the sentence does not.
    const cfg = SpeedEstimatorConfig();
    final kmh = cfg.vStillMps * 3.6;
    expect(kmh, closeTo(3.0, 1e-9),
        reason: 'vStillMps changed. Update explainerSpeedStillLead in BOTH '
            'app_zh.arb and app_en.arb, and design 0042 §3.9b, before '
            'changing this expectation — the sheet is a promise to the user, '
            'not a comment');

    for (final f in ['lib/l10n/app_zh.arb', 'lib/l10n/app_en.arb']) {
      expect(File(f).readAsStringSync(), contains('3 km/h'),
          reason: '$f no longer quotes the threshold the code enforces');
    }
  });

  test('🔴 both rows are reachable from the settings screen', () {
    // A sheet nobody can open is the same as no sheet, and these two are the
    // only place the lean-angle shortfall and the still-clamp are ever
    // explained to a user.
    final src =
        File('lib/ui/settings/settings_screen.dart').readAsStringSync();
    for (final fn in [
      'showSpeedMeasurementExplainer(',
      'showGForceMeasurementExplainer(',
    ]) {
      expect(src, contains(fn), reason: 'no way in: $fn');
    }
  });
}
