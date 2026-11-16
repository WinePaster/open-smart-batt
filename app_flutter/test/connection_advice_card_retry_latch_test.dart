// Feedback `2026.11.16/003` (ruled 2026-11-16): one press of the advice card's
// retry produced two `connect →` 15–19 ms apart on a Redmi Pad 2, and the
// second cancelled the first. The card now latches: the first tap fires, any
// tap inside `ConnectionAdviceCard.retryLockout` is dropped, and the button
// works again afterwards (a retry refused on the spot must stay retryable).
//
// CLEAN-ROOM: expectations derive from this project's own source and field
// captures.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/devices/connection_failure.dart';

Future<void> _pump(WidgetTester tester, VoidCallback onRetry) {
  return tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: ConnectionAdviceCard(
            hint: 'hint',
            retryLabel: 'Retry',
            onRetry: onRetry,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a double tap inside one frame starts exactly one retry',
      (tester) async {
    var calls = 0;
    await _pump(tester, () => calls++);

    // Two taps with no frame in between — the field case (15–19 ms apart).
    await tester.tap(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(calls, 1);
  });

  testWidgets('taps inside the lockout are dropped, after it they work',
      (tester) async {
    var calls = 0;
    await _pump(tester, () => calls++);

    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(calls, 1, reason: 'an impatient second press is not a new attempt');

    // A retry refused on the spot leaves the card mounted — the button must
    // not stay dead, or the only way out of this screen is gone.
    await tester.pump(ConnectionAdviceCard.retryLockout);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(calls, 2);
  });

  testWidgets('disposing the card mid-lockout leaves no timer behind',
      (tester) async {
    await _pump(tester, () {});
    await tester.tap(find.text('Retry'));
    await tester.pumpWidget(const SizedBox());
    // flutter_test fails the test on a pending Timer at teardown.
  });
}
