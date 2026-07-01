// Unit tests for the pure iOS-port helpers extracted in the Implement phase.
//
// Covers the platform-divergent logic that has no host-VM Bluetooth/Platform
// dependency, so it runs headless under `flutter test`:
//   - D.6  update download URL selection (iOS -> htmlUrl, Android -> apkUrl)
//   - D.4  reconnect backoff/cap calculator + per-platform connect tuning
//   - D.3  saved-device key rebind (iOS UUID) + stale marking
//
// The real BLE scan/connect/keep-alive paths are NOT exercised here (they need
// a physical iPhone + RCE battery — see integration_test/app_test.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart' show BleService;
import 'package:open_smart_batt/data/data.dart' show UpdateInfo, updateUrlFor;
import 'package:open_smart_batt/models/models.dart' show SavedDevice;
import 'package:open_smart_batt/models/saved_device.dart' show rebindSavedDeviceId;
import 'package:open_smart_batt/state/state.dart' show reconnectBackoff;

void main() {
  group('D.6 update URL selection (updateUrlFor)', () {
    const withApk = UpdateInfo(
      latestTag: 'v0.7.0',
      htmlUrl: 'https://github.com/WinePaster/open-smart-batt/releases/tag/v0.7.0',
      apkUrl: 'https://github.com/WinePaster/open-smart-batt/releases/'
          'download/v0.7.0/open-smart-batt.apk',
    );
    const noApk = UpdateInfo(
      latestTag: 'v0.7.0',
      htmlUrl: 'https://github.com/WinePaster/open-smart-batt/releases/tag/v0.7.0',
    );

    test('iOS always opens the release page, never the .apk asset', () {
      expect(updateUrlFor(withApk, isIOS: true), withApk.htmlUrl);
      expect(updateUrlFor(withApk, isIOS: true), isNot(endsWith('.apk')));
      // Even with no apk asset, iOS stays on the html release page.
      expect(updateUrlFor(noApk, isIOS: true), noApk.htmlUrl);
    });

    test('Android prefers the direct apk asset when present', () {
      expect(updateUrlFor(withApk, isIOS: false), withApk.apkUrl);
    });

    test('Android falls back to the release page when no apk asset', () {
      expect(updateUrlFor(noApk, isIOS: false), noApk.htmlUrl);
    });
  });

  group('D.4 reconnect backoff (reconnectBackoff)', () {
    test('attempt 0 returns the base delay', () {
      expect(reconnectBackoff(0), const Duration(seconds: 2));
    });

    test('doubles per attempt (base * 2^n) until the cap', () {
      expect(reconnectBackoff(1), const Duration(seconds: 4));
      expect(reconnectBackoff(2), const Duration(seconds: 8));
      expect(reconnectBackoff(3), const Duration(seconds: 16));
    });

    test('is clamped to the cap (bounded)', () {
      // 2 * 2^4 = 32s would exceed the 30s cap.
      expect(reconnectBackoff(4), const Duration(seconds: 30));
      expect(reconnectBackoff(10), const Duration(seconds: 30));
      // Huge attempt counts never overflow the shift / exceed the cap.
      expect(reconnectBackoff(1000), const Duration(seconds: 30));
    });

    test('is monotonic non-decreasing across attempts', () {
      Duration prev = Duration.zero;
      for (var n = 0; n <= 20; n++) {
        final d = reconnectBackoff(n);
        expect(d >= prev, isTrue, reason: 'attempt $n decreased ($d < $prev)');
        prev = d;
      }
    });

    test('negative attempts are treated as attempt 0', () {
      expect(reconnectBackoff(-1), reconnectBackoff(0));
      expect(reconnectBackoff(-99), const Duration(seconds: 2));
    });

    test('honours custom base/cap', () {
      const base = Duration(milliseconds: 500);
      const cap = Duration(seconds: 3);
      expect(reconnectBackoff(0, base: base, cap: cap),
          const Duration(milliseconds: 500));
      expect(reconnectBackoff(1, base: base, cap: cap),
          const Duration(seconds: 1));
      // 0.5s * 2^3 = 4s -> clamped to 3s.
      expect(reconnectBackoff(3, base: base, cap: cap), cap);
    });
  });

  group('D.4 per-platform connect tuning (BleService)', () {
    test('iOS makes a single short-timeout attempt; Android retries', () {
      // iOS: one attempt (no native timeout, retry only multiplies the freeze).
      expect(BleService.connectAttemptsFor(isIOS: true), 1);
      // Android: connect-bounce recovery.
      expect(BleService.connectAttemptsFor(isIOS: false), 3);
    });

    test('iOS connect timeout is shorter than Android (faster stale error)', () {
      final ios = BleService.connectTimeoutFor(isIOS: true);
      final android = BleService.connectTimeoutFor(isIOS: false);
      expect(ios, BleService.iosConnectTimeout);
      expect(android, BleService.androidConnectTimeout);
      expect(ios < android, isTrue);
      // iOS worst-case freeze is one short timeout, well under Android's
      // 3 x 20s = 60s.
      final iosWorst = ios * BleService.connectAttemptsFor(isIOS: true);
      final androidWorst =
          android * BleService.connectAttemptsFor(isIOS: false);
      expect(iosWorst < androidWorst, isTrue);
      expect(iosWorst.inSeconds, lessThan(15));
    });
  });

  group('D.3 saved-device id rebind (rebindSavedDeviceId)', () {
    test('Android (useNameKey=false) is identity — always the stable MAC', () {
      final id = rebindSavedDeviceId(
        savedId: 'AA:BB:CC:DD:EE:FF',
        savedName: 'RCE-SCAP_II',
        candidates: const {'11:22:33:44:55:66': 'RCE-SCAP_II'},
        useNameKey: false,
      );
      expect(id, 'AA:BB:CC:DD:EE:FF');
    });

    test('iOS keeps the saved UUID when the OS is still reusing it', () {
      final id = rebindSavedDeviceId(
        savedId: 'UUID-OLD',
        savedName: 'RCE-SCAP_II',
        candidates: const {
          'UUID-OLD': 'RCE-SCAP_II',
          'UUID-OTHER': 'RCE-SCAP_I',
        },
        useNameKey: true,
      );
      expect(id, 'UUID-OLD');
    });

    test('iOS rebinds a stale UUID to the fresh one with a matching name', () {
      final id = rebindSavedDeviceId(
        savedId: 'UUID-STALE-FROM-LAST-INSTALL',
        savedName: 'RCE-SCAP_II',
        candidates: const {
          'UUID-FRESH': 'RCE-SCAP_II',
          'UUID-OTHER': 'RCE-SCAP_I',
        },
        useNameKey: true,
      );
      expect(id, 'UUID-FRESH');
    });

    test('iOS falls back to the saved id when no name matches', () {
      // Caller then surfaces a stale error if the connect fails.
      final id = rebindSavedDeviceId(
        savedId: 'UUID-STALE',
        savedName: 'RCE-SCAP_II',
        candidates: const {'UUID-OTHER': 'RCE-SCAP_I'},
        useNameKey: true,
      );
      expect(id, 'UUID-STALE');
    });

    test('iOS with an empty saved name cannot rebind (uses saved id)', () {
      // Pre-migration rows have no stable name → rebinding is inert.
      final id = rebindSavedDeviceId(
        savedId: 'UUID-STALE',
        savedName: '',
        candidates: const {'UUID-FRESH': 'RCE-SCAP_II'},
        useNameKey: true,
      );
      expect(id, 'UUID-STALE');
    });

    test('empty-named candidates never match (no accidental rebind)', () {
      final id = rebindSavedDeviceId(
        savedId: 'UUID-STALE',
        savedName: '',
        candidates: const {'UUID-FRESH': ''},
        useNameKey: true,
      );
      expect(id, 'UUID-STALE');
    });
  });

  group('D.3 stale marking (SavedDevice.fromMap)', () {
    test('stale=1 column round-trips to true', () {
      final d = SavedDevice.fromMap(const {
        'id': 'UUID-X',
        'alias': '電容 #1',
        'name': 'RCE-SCAP_II',
        'stale': 1,
      });
      expect(d.stale, isTrue);
      expect(d.name, 'RCE-SCAP_II');
    });

    test('absent stale column defaults to not-stale (pre-migration rows)', () {
      final d = SavedDevice.fromMap(const {'id': 'UUID-X', 'alias': 'a'});
      expect(d.stale, isFalse);
      expect(d.name, ''); // forward-compatible default
    });

    test('stale=0 round-trips to false', () {
      final d = SavedDevice.fromMap(const {
        'id': 'UUID-X',
        'alias': 'a',
        'stale': 0,
      });
      expect(d.stale, isFalse);
    });
  });
}
