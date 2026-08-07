// The §3.9 consent gate — the only thing standing between "the app has a speed
// feature" and "the app is recording where you have been, at what speed, into a
// file you will later mail to a stranger".
//
// 🔴 It shipped with ZERO tests (found by the 2026-08-07 Phase D+E review). The
// code was correct when read line by line, and that is exactly the problem: a
// later edit that moved `if (!agreed) return;` below the write, or that dropped
// the "speed goes into your export" bullet, would have kept all 995 tests
// green. Design 0042 G5 says the landing is "the result of consent, not the
// default" — these tests are what makes that sentence enforceable.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/ui/settings/speed_consent_dialog.dart';

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
  testWidgets('the dialog states all four consequences, none of them optional',
      (tester) async {
    await tester.pumpWidget(_host((c) => showSpeedDetectionConsentDialog(c)));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
    // Each of the four is a separate promise to the user. The second one —
    // "speed is written to the log and included in your export" — is the one
    // 0042 G5 calls out as un-fudgeable: a timestamped speed series is
    // behavioural data, and the wording may not soften to "uses location".
    for (final line in [
      l10n.speedConsentPointForeground,
      l10n.speedConsentPointRecorded,
      l10n.speedConsentPointNoLocationStored,
      l10n.speedConsentPointBattery,
    ]) {
      expect(find.text(line), findsOneWidget, reason: 'missing: $line');
    }
  });

  testWidgets('cancel resolves false — an accidental tap grants nothing',
      (tester) async {
    bool? result;
    await tester.pumpWidget(_host(
        (c) => showSpeedDetectionConsentDialog(c).then((v) => result = v)));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
    await tester.tap(find.text(l10n.commonCancel));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('a dismissal is a cancel, not a silent yes', (tester) async {
    bool? result;
    await tester.pumpWidget(_host(
        (c) => showSpeedDetectionConsentDialog(c).then((v) => result = v)));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    // Barrier tap. `showDialog` completes with null here, and null must not be
    // read as consent anywhere on the way back.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(result, isFalse,
        reason: 'null from showDialog must collapse to false, not to true');
  });

  testWidgets('only the explicit enable button resolves true', (tester) async {
    bool? result;
    await tester.pumpWidget(_host(
        (c) => showSpeedDetectionConsentDialog(c).then((v) => result = v)));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
    await tester.tap(find.text(l10n.speedConsentEnable));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
