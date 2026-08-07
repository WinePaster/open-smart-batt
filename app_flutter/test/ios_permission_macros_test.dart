// 🔴 The iOS permission macros — a build-configuration fact that no Dart test
// could see, and that silently disabled a shipped feature.
//
// Reported from the field on v0.7.7 (2026-08-07): the app's page in iOS 設定
// had no 定位 row at all. Not "denied" — ABSENT. iOS only lists a permission a
// binary has actually asked for, and this binary never asked.
//
// Why: `ios/Podfile` sets `PERMISSION_LOCATION_WHENINUSE=0`. At 0 the plugin
// compiles `LocationPermissionStrategy` down to `UnknownPermissionStrategy`
// (permission_handler_apple 9.5.0, `LocationPermissionStrategy.h:19-23`), whose
// `requestPermission:` returns `PermissionStatusPermanentlyDenied` immediately
// (`UnknownPermissionStrategy.m:19-21`) without ever constructing a
// CLLocationManager. So `GpsSpeedController.requestPermission()` came back
// `permanentlyDenied`, the card offered "open Settings", and Settings had
// nothing to offer back. A dead end that looked like a user's own doing.
//
// The macro block was not wrong when it was written — every permission was
// genuinely unused, and disabling them is the documented way to avoid
// ITMS-90683. It became wrong when design 0042 started requesting location and
// nobody revisited a Ruby file. That is this project's recurring failure in its
// purest form: THE INPUT TO A DECISION HAD NO TEST LOOKING AT IT.
//
// So this file reads the Podfile as data. It is deliberately not a widget test
// and not a plugin test — it is the only place where "what the Dart code asks
// for" and "what the iOS build compiled in" are compared at all.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every `permission_handler` permission the app names, and the two facts about
/// each that this test needs.
///
/// 🔑 Adding a `Permission.x` to `lib/` without adding it here FAILS the last
/// test in this file. That is the point: the decision "does iOS need this
/// compiled in?" gets forced at the moment the permission is introduced,
/// instead of being discovered by a rider whose screen says nothing.
const permissions = <String, ({String macro, bool usedOnIos, String? plistKey})>{
  // The speed feature (design 0042). `GpsSpeedController` is the only caller
  // and it has no platform guard — this runs on iOS.
  'locationWhenInUse': (
    macro: 'PERMISSION_LOCATION_WHENINUSE',
    usedOnIos: true,
    plistKey: 'NSLocationWhenInUseUsageDescription',
  ),
  // Android 12+ BLE. `BleService.ensurePermissions` returns early on
  // `!Platform.isAndroid`; iOS prompts on first CoreBluetooth use, handled by
  // flutter_blue_plus and not by permission_handler at all.
  'bluetoothScan': (
    macro: 'PERMISSION_BLUETOOTH',
    usedOnIos: false,
    plistKey: null,
  ),
  'bluetoothConnect': (
    macro: 'PERMISSION_BLUETOOTH',
    usedOnIos: false,
    plistKey: null,
  ),
  // POST_NOTIFICATIONS for the Android foreground service.
  // `ensureNotificationPermission` also returns early on `!Platform.isAndroid`.
  'notification': (
    macro: 'PERMISSION_NOTIFICATIONS',
    usedOnIos: false,
    plistKey: null,
  ),
};

/// `PERMISSION_X=N` as the Podfile actually spells it.
Map<String, String> podfileMacros() {
  final src = File('ios/Podfile').readAsStringSync();
  final out = <String, String>{};
  for (final m
      in RegExp(r"'(PERMISSION_[A-Z_]+)=(\d)'").allMatches(src)) {
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

void main() {
  test('the Podfile really does carry a macro block', () {
    // Guards every assertion below from passing vacuously if the block is
    // deleted, renamed, or moved into an xcconfig.
    final macros = podfileMacros();
    expect(macros, isNotEmpty);
    expect(macros.length, greaterThan(10),
        reason: 'the block disables the unused permissions explicitly; a short '
            'list means it was rewritten and this test needs rewriting too');
  });

  test('🔴 every permission the app requests on iOS is compiled in', () {
    final macros = podfileMacros();
    for (final e in permissions.entries) {
      if (!e.value.usedOnIos) continue;
      expect(macros[e.value.macro], '1',
          reason: 'Permission.${e.key} is requested on iOS, so '
              '${e.value.macro} must be 1. At 0 the request returns '
              'permanentlyDenied without asking the OS, and the permission '
              'never appears in the app\'s page in Settings — which is exactly '
              'what shipped in v0.7.7.');
    }
  });

  test('…and every one that is compiled in has its usage description', () {
    // The other half of the same trade. ITMS-90683 rejects an upload whose
    // binary can request a permission it has no usage string for, and that
    // rejection is the reason the whole block exists. Turning a macro on
    // without the key would swap one shipped defect for another.
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    for (final e in permissions.entries) {
      if (!e.value.usedOnIos) continue;
      final key = e.value.plistKey;
      expect(key, isNotNull,
          reason: 'an iOS-used permission needs a usage description key');
      expect(plist, contains('<key>$key</key>'),
          reason: 'Permission.${e.key} is compiled in, so Info.plist must '
              'explain it or App Store Connect rejects the upload');
    }
  });

  test('the permissions NOT used on iOS stay compiled out', () {
    // Not symmetry for its own sake: each one left in is an ITMS-90683 target
    // and a handler in the binary that nothing calls.
    final macros = podfileMacros();
    for (final e in permissions.entries) {
      if (e.value.usedOnIos) continue;
      expect(macros[e.value.macro], '0',
          reason: 'Permission.${e.key} is Android-only (its caller returns '
              'early on !Platform.isAndroid), so ${e.value.macro} should stay '
              'off');
    }
  });

  test('🔴 no permission is used in lib/ without a decision recorded here', () {
    // The part that makes the rest maintainable. Derived from source, so the
    // NEXT feature that reaches for permission_handler cannot get to iOS
    // without someone answering "compiled in, or not?".
    final used = <String>{};
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      for (final m
          in RegExp(r'\bPermission\.([a-zA-Z]+)').allMatches(f.readAsStringSync())) {
        used.add(m.group(1)!);
      }
    }
    expect(used, isNotEmpty, reason: 'the scan itself must not be vacuous');
    expect(used.difference(permissions.keys.toSet()), isEmpty,
        reason: 'these permissions are requested by lib/ but have no entry in '
            'this file\'s table — decide whether iOS needs the macro, then add '
            'them. See the header for what happens when nobody does.');
  });
}
