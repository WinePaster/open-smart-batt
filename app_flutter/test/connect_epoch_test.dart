// Connection-setup timeout (FB-23) and epoch guard (FB-39): own the timeout
// rather than inheriting the BLE plugin's, and make a late callback from a
// superseded connection attempt unable to touch the current one.
//
// THE CAPTURE THIS PINS DOWN. A 2026-07-30 field capture, 18:15–18:17:
//
//   18:15:46  connect → <device A>          (a capacitor)
//   18:16:11  Uncaught: discoverServices | Timed out after 15s
//   18:16:27  Uncaught: discoverServices | Timed out after 15s
//   18:16:44  Uncaught: discoverServices | Timed out after 15s
//   18:16:48  link: connected  →  18:16:49  GATT dump succeeds
//   18:17:17  connect → <device B>          (the owner gives up, taps a power bank)
//   18:17:22  link: ready       ← attributed to the CAPACITOR, five seconds late
//
// So the app came online as a device the user had already moved away from, and
// the dashboard showed a capacitor to someone who had just asked for a power
// bank. One file held 101 `Uncaught:` lines, none of which could be caught by
// anyone: the only caller of _setupConnection is a stream listener.
//
// The two faults are one chain — the timeouts stretched the connect long enough
// for the late `ready` to land — so fixing either alone leaves the symptom.
//
// CLEAN-ROOM: expectations derive from our own capture and our own source.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';

void main() {
  group('ConnectEpoch — the guard itself', () {
    test('work captured before any change is still current', () {
      final e = ConnectEpoch();
      final mine = e.current;
      expect(e.isCurrent(mine), isTrue);
    });

    test('one begin() invalidates everything captured before it', () {
      final e = ConnectEpoch();
      final mine = e.current;
      e.begin();
      expect(e.isCurrent(mine), isFalse,
          reason: 'a newer connect owns the shared state now');
    });

    test('the epoch opened by begin() is the one now in force', () {
      final e = ConnectEpoch();
      final opened = e.begin();
      expect(opened, e.current);
      expect(e.isCurrent(opened), isTrue);
    });

    test('a double bump still just invalidates — it never resurrects', () {
      // connect() bumps, then its own disconnect() bumps again. Both must
      // invalidate the same older work, and neither may resurrect it.
      final e = ConnectEpoch();
      final mine = e.current;
      e.begin();
      e.begin();
      expect(e.isCurrent(mine), isFalse);
    });

    test('an epoch never becomes current again', () {
      // The counter only moves forward, so a setup that lost the race can never
      // win it back on a later connect.
      final e = ConnectEpoch();
      final mine = e.current;
      for (var i = 0; i < 50; i++) {
        e.begin();
        expect(e.isCurrent(mine), isFalse, reason: 'after ${i + 1} bumps');
      }
    });

    test('two overlapping setups: only the newer one may proceed', () {
      // The captured sequence above, in miniature.
      final e = ConnectEpoch();
      final capacitor = e.begin(); // connect → device A
      final powerBank = e.begin(); // connect → device B, while the first awaits
      expect(e.isCurrent(capacitor), isFalse,
          reason: 'the late `ready` must NOT be published');
      expect(e.isCurrent(powerBank), isTrue);
    });
  });

  group('gattSetupFailureReason — readable, and still specific', () {
    test('a discovery timeout is named as such', () {
      final r = gattSetupFailureReason(TimeoutException('x'));
      expect(r, contains('timed out'));
      expect(r.toLowerCase(), isNot(contains('uncaught')));
    });

    test('missing characteristics are distinguished from a timeout', () {
      final r = gattSetupFailureReason(
          StateError('GATT characteristics not found (write=false, '
              'notify=false)'));
      expect(r, contains('characteristics'));
      expect(r, isNot(contains('timed out')));
      // The original text survives — it carries which side was missing.
      expect(r, contains('write=false'));
    });

    test('anything else keeps the exception text verbatim', () {
      final r = gattSetupFailureReason(
          Exception('FlutterBluePlusException | fbp-code: 1'));
      expect(r, contains('fbp-code: 1'));
    });

    test('every branch produces a non-empty, single-line reason', () {
      // It goes into a log line, so a newline would corrupt the format that
      // eleven collected batches are parsed with.
      for (final e in <Object>[
        TimeoutException('x'),
        StateError('GATT characteristics not found'),
        Exception('boom'),
        'a bare string',
      ]) {
        final r = gattSetupFailureReason(e);
        expect(r, isNotEmpty);
        expect(r, isNot(contains('\n')));
      }
    });
  });

  group('discovery timing — the point is to notice before the plugin does', () {
    test('our timeout is shorter than the 15 s flutter_blue_plus applies', () {
      // If it were not, the plugin would always win the race and we would be
      // back to an uncatchable exception. This is the whole mechanism.
      expect(BleService.discoverTimeout,
          lessThan(const Duration(seconds: 15)));
    });

    test('discovery is retried, on both platforms', () {
      // The capture showed discovery failing three times and then succeeding,
      // so a single attempt discards a link that was about to work.
      expect(BleService.discoverAttemptsFor(isIOS: true), greaterThan(1));
      expect(BleService.discoverAttemptsFor(isIOS: false), greaterThan(1));
    });

    test('the total discovery budget still beats the single 15 s it replaces',
        () {
      final total = BleService.discoverTimeout *
          BleService.discoverAttemptsFor(isIOS: true);
      expect(total, lessThanOrEqualTo(const Duration(seconds: 16)));
    });
  });
}
