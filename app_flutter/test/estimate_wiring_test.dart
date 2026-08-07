// Every `bind*Estimates` on TelemetryController has a caller in AppServices.
//
// 🔴 The wiring lines in `AppServices.create` are the one place where "the
// feature exists" and "the feature is connected" can differ, and they had no
// test (flagged honestly by the design 0044 implementer, 2026-08-07). Deleting
// `telemetry.bindAccelEstimates(speed.accelEstimates)` compiles, runs, passes
// 1101 tests, and silently stops acceleration from ever being recorded — the
// column just stays NULL. Same shape as the defects this project keeps finding:
// the failure is in the CALLER, and every test looks at the callee.
//
// ## Why source-level, and why that is enough here
//
// Mis-wiring is already impossible: `bindSpeedEstimates` takes
// `Stream<SpeedEstimate>` and `bindAccelEstimates` takes `Stream<AccelEstimate>`,
// so swapping them does not compile. The residual risk is OMISSION — a line
// deleted, or a third estimate stream added later and never bound. Deriving the
// list of methods from the source and demanding a caller for each covers
// exactly that, including the case that does not exist yet.
//
// The alternative was a `speedSource:` injection point on AppServices so a fake
// could be fed end to end. That is a production seam added for a test, and it
// would prove no more than this does about omission. `give_up_visibility_test`
// set the precedent for deriving the checklist from the source rather than
// maintaining a second copy of it by hand.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every estimate stream TelemetryController accepts is actually bound',
      () {
    final telemetry =
        File('lib/state/telemetry_controller.dart').readAsStringSync();
    final services = File('lib/state/app_services.dart').readAsStringSync();

    final binders = RegExp(r'void (bind\w*Estimates)\(')
        .allMatches(telemetry)
        .map((m) => m.group(1)!)
        .toSet();

    expect(binders, isNotEmpty,
        reason: 'the regex stopped matching — fix it rather than deleting the '
            'test, or this file silently guards nothing');

    for (final b in binders) {
      expect(services, contains('$b('),
          reason: '$b exists on TelemetryController but AppServices never '
              'calls it. The stream is produced and thrown away: nothing '
              'throws, nothing logs, and the column it feeds just stays NULL.');
    }
  });
}
