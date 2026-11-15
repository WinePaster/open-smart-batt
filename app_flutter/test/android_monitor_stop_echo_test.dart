// 🔴 Android: the app's OWN stop of the foreground service must not come back
// to Dart as a user stop (2026.11.15/001).
//
// `MonitorService.onDestroy` used to broadcast `ACTION_STOP_REQUESTED` however
// it got there — the notification's stop action, the system, OR Dart's own
// `stop()` (`MainActivity` → `stopService`). Dart cannot tell those apart, so it
// treats every broadcast as the user pressing "stop": `_onMonitorStop` drops the
// link and `MultiLinkController.onMonitorStopped` releases every secondary.
//
// Since `2e7c999` (the service stays up through an auto-reconnect) a device
// switch stops the service and starts it again a few ms later; the echo of the
// stop then lands after the new link has started. In the field log every
// Android switch from `26111340` on shows `multilink: release … reason=
// monitor-stopped` with nobody touching the notification, the new link torn
// down 4 ms later, and a second connect — 1.6–2.5 s became 4.9–8.7 s.
//
// The fix lives in Kotlin, where no Dart test runs. So this file reads the two
// Kotlin sources as data and pins the three pieces of the fix together; losing
// any one of them silently restores the defect (or, for the reset, makes the
// user's real stop disappear).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _dir = 'android/app/src/main/kotlin/com/winepaster/openSmartBatt';

String _read(String name) => File('$_dir/$name').readAsStringSync();

/// The body of the first `{ … }` block that opens after [anchor].
String _block(String src, String anchor) {
  final at = src.indexOf(anchor);
  expect(at, isNot(-1), reason: 'anchor not found: $anchor');
  final open = src.indexOf('{', at);
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}' && --depth == 0) return src.substring(open, i + 1);
  }
  fail('unbalanced block after $anchor');
}

void main() {
  test("MainActivity marks Dart's stop as the app's own before stopService", () {
    final stop = _block(_read('MainActivity.kt'), '"stop" ->');
    final mark = stop.indexOf('MonitorService.stoppedByApp = true');
    final call = stop.indexOf('stopService(');
    expect(mark, isNot(-1));
    expect(call, isNot(-1));
    expect(mark, lessThan(call),
        reason: 'the flag must be set before onDestroy can run');
  });

  test('onDestroy broadcasts only when the stop was NOT the app\'s own, then '
      'clears the flag', () {
    final destroy = _block(_read('MonitorService.kt'), 'override fun onDestroy');
    final guard = destroy.indexOf('if (!stoppedByApp)');
    final send = destroy.indexOf('sendBroadcast(');
    final clear = destroy.indexOf('stoppedByApp = false');
    expect(guard, isNot(-1));
    expect(send, greaterThan(guard));
    expect(clear, greaterThan(send));
  });

  test('every start clears the flag (a stopService that found no service never '
      'reaches onDestroy)', () {
    final start = _block(_read('MonitorService.kt'), 'ACTION_START, ACTION_UPDATE ->');
    expect(start, contains('stoppedByApp = false'));
  });

  test("the notification's stop action still goes through the service (and "
      'so still reaches Dart)', () {
    final svc = _read('MonitorService.kt');
    expect(svc, contains('setAction(ACTION_STOP)'));
    final stop = _block(svc, 'ACTION_STOP ->');
    expect(stop, isNot(contains('stoppedByApp = true')));
  });
}
