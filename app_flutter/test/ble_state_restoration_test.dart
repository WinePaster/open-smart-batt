// design 0060 Phase 2 (FB-67) — opting into CoreBluetooth state restoration.
//
// WHAT "B" IS. iOS reclaims a suspended app under memory pressure and the
// pending connect dies with it, so nothing is left to bring the app back when
// the battery reappears. `CBCentralManagerOptionRestoreIdentifierKey` is the OS
// mechanism that changes that: the system relaunches the app for the connection
// and replays what it was doing. flutter_blue_plus exposes it as
// `setOptions(restoreState: true)`.
//
// WHAT IS TESTABLE HERE, AND WHAT IS NOT. The restoration EVENT
// (`willRestoreState:`) cannot be raised on a host, "iOS killed the process"
// cannot be simulated, and whether the option had any effect is a property of a
// real CBCentralManager. So this file tests the two things that are ours:
//
//   1. the call is made in a form that cannot stop the app from starting —
//      design 0060 §6's requirement, and the reason it is wrapped at all;
//   2. it says which way it went, because those log lines are the ONLY input
//      design 0060 Q3 has for "does restoration actually happen in the field".
//
// The rest is Phase 3's device list (R1–R7), and no green run in this file may
// be read as evidence that FB-67's "B" half works.
//
// ⚠️ THE CALL SITE IS THE OTHER HALF OF THE FIX, and it is not assertable from
// here: the option is read only when the plugin CONSTRUCTS its CBCentralManager,
// behind a one-shot nil guard, and the manager is built lazily by the first
// platform call — ours being `ConnectionController`'s `adapterState.listen`,
// inside `AppServices.create`. `bootstrap()` therefore calls this BEFORE
// `AppServices.create`, and a future edit that moves either one past the other
// makes the whole feature a silent no-op. There is no test that can catch that;
// see `BleService.enableStateRestoration`'s doc comment, which is where the
// argument is written down.
//
// CLEAN-ROOM: derived from this project's own source and the plugin's published
// API.
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a successful call reports `ok`', () async {
    var called = 0;
    final line = await configureBleStateRestoration(setOptions: () async {
      called++;
    });
    expect(called, 1);
    expect(line, 'restore: setOptions(restoreState: true) ok');
  });

  test('a THROWN failure does not propagate — bootstrap must still finish',
      () async {
    // 🔴 The requirement, stated as design 0060 §3.8 states it: only the
    // DATABASE failing to open earns `StartupFailureApp`, because that is the
    // failure that takes the diagnostic log down with it. An iOS-only BLE
    // optimisation that could not be enabled must never be the reason an app
    // will not open — which on Android and on every desktop host is the
    // ordinary case, not an exotic one.
    final line = await configureBleStateRestoration(
        setOptions: () async => throw StateError('no platform'));
    expect(line, startsWith('restore: setOptions(restoreState: true) failed='));
    expect(line, contains('no platform'),
        reason: 'and the reason travels with it — a `failed` with no cause is '
            'the kind of line a triage cannot act on');
  });

  test('the REAL call is safe on a host with no plugin behind it', () async {
    // Not a mock: this is `BleService.enableStateRestoration` reaching for a
    // method channel nothing answers. It must come back as a `failed=` line
    // rather than as an exception, because that is precisely what every
    // non-iOS run of this app does.
    final line = await configureBleStateRestoration();
    expect(line, startsWith('restore: setOptions(restoreState: true) '));
  });
}
