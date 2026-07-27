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
import 'package:open_smart_batt/models/models.dart'
    show DeviceCapabilities, ProductClass, SavedDevice;
import 'package:open_smart_batt/protocol/protocol.dart' show CommandBuilder;
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

  group('keep-alive schedule (BleService.keepAliveTokenFor, PROTOCOL.md §2)', () {
    const cb = CommandBuilder();
    List<int> token(int tick, {required bool pb}) =>
        BleService.keepAliveTokenFor(cb, tick: tick, isPowerBank: pb);

    test('tick 1 sends !# for every device', () {
      expect(token(1, pb: false), [0x21, 0x23]);
      expect(token(1, pb: true), [0x21, 0x23]);
    });

    test('a non-power-bank sends # each tick, @ every 25th', () {
      expect(token(2, pb: false), [0x23]);
      expect(token(5, pb: false), [0x23]); // the %5 !# is power-bank-only
      expect(token(24, pb: false), [0x23]);
      expect(token(25, pb: false), [0x40]);
      expect(token(50, pb: false), [0x40]);
    });

    test('a power bank additionally sends !# every 5th tick', () {
      expect(token(5, pb: true), [0x21, 0x23]);
      expect(token(10, pb: true), [0x21, 0x23]);
      expect(token(15, pb: true), [0x21, 0x23]);
      expect(token(20, pb: true), [0x21, 0x23]);
      // Non-multiples of 5 still get the plain #.
      expect(token(6, pb: true), [0x23]);
      // 25 is a multiple of BOTH 5 and 25; per PROTOCOL.md §2 the `@` metadata
      // poll is checked first, so a power bank still emits `@` at 25/50.
      expect(token(25, pb: true), [0x40]);
      expect(token(50, pb: true), [0x40]);
    });
  });

  group('ProductClass + DeviceCapabilities (design 0004 §3.1/§3.2)', () {
    test('device-type: 0x22 => powerBank, 0x02 => smartBattery, else unknown',
        () {
      expect(ProductClass.fromDeviceType(0x22), ProductClass.powerBank);
      expect(ProductClass.fromDeviceType(0x22).isPowerBank, isTrue);
      // 0x02 is the wire-verified smart battery (design 0004 §3.1).
      expect(ProductClass.fromDeviceType(0x02), ProductClass.smartBattery);
      expect(ProductClass.fromDeviceType(0x02).isPowerBank, isFalse);
      // 0x17 is the wire-verified super-capacitor since 2026-07-27 (design 0007,
      // which lands the mapping 0004 §3.1 deferred until a capture existed).
      expect(ProductClass.fromDeviceType(0x17), ProductClass.supercapacitor);
      // 0x44 (old Smi-tag bug) and an absent byte stay unknown.
      expect(ProductClass.fromDeviceType(0x44), ProductClass.unknown);
      expect(ProductClass.fromDeviceType(null), ProductClass.unknown);
    });

    test('capabilities are gated PER CLASS (design 0004 §3.2)', () {
      // 0x17 => supercapacitor (design 0007): 檢測電容 only. The owner confirmed
      // 2026-07-27 that a capacitor has no 解除斷電, so it must NOT be offered.
      final cap = DeviceCapabilities.fromDeviceType(0x17);
      expect(cap.productClass, ProductClass.supercapacitor);
      expect(cap.isCapacitor, isTrue);
      expect(cap.hasCutOff, isFalse);
      expect(cap.hasAntiTheft, isFalse);

      // An UNRECOGNISED byte still gets the bounded fallback: union EXCEPT
      // anti-theft (檢測電容 + 解除斷電, no 防盜).
      final unknownPack = DeviceCapabilities.fromDeviceType(0x99);
      expect(unknownPack.isPowerBank, isFalse);
      expect(unknownPack.isCapacitor, isTrue);
      expect(unknownPack.hasCutOff, isTrue);
      expect(unknownPack.hasAntiTheft, isFalse);
      // Anti-theft is NEVER exposed for the unknown fallback, even with an
      // override — it is smartBattery-only (§3.2).
      expect(
          unknownPack.copyWith(antiTheftOverride: true).hasAntiTheft, isFalse);

      // Power bank (0x22): no pack controls at all.
      final bank = DeviceCapabilities.fromDeviceType(0x22);
      expect(bank.isPowerBank, isTrue);
      expect(bank.isCapacitor, isFalse);
      expect(bank.hasCutOff, isFalse);
      expect(bank.hasAntiTheft, isFalse);

      // Smart battery (0x02): 解除斷電 yes, 檢測電容 no; anti-theft is
      // model-gated (off until an override enables it).
      final smart = DeviceCapabilities.fromDeviceType(0x02);
      expect(smart.isCapacitor, isFalse);
      expect(smart.hasCutOff, isTrue);
      expect(smart.hasAntiTheft, isFalse);
      expect(smart.copyWith(antiTheftOverride: true).hasAntiTheft, isTrue);

      // Same capacitor gating whether it comes from the class or the wire byte.
      final capByClass =
          DeviceCapabilities.fromClass(ProductClass.supercapacitor);
      expect(capByClass, cap);
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
