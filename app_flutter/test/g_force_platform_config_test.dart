// Platform declarations for the G meter (design 0045 Phase 1 / §2.2 / R6).
//
// Same reasoning as `speed_platform_config_test.dart`: these files cannot be
// reviewed from the Dart code, and being wrong is expensive in a way a test run
// will not show. Design 0045 R6 rates a MISSING required iOS usage key as
// crash-level — the OS terminates the app the first time the API is touched —
// so the key is declared defensively and pinned here.
//
// 🔲 The underlying fact is UNVERIFIED (design 0045 §2.2 #4): the common
// account is that raw accelerometer access does not prompt at all and only the
// activity/pedometer APIs need `NSMotionUsageDescription`. Nobody here has run
// it on a device. Declaring the key costs an unused string; omitting it costs a
// crash on hardware we have not tested. Phase 1's real-device check turns the
// 🔲 into a fact and this comment into a statement.
//
// The other half of this file is the negative space, and it matters more than
// the positive: the G meter must not have quietly acquired a permission it does
// not need. It reads one sensor, in the foreground, while a card is on screen.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _packageRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate package root from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir;
}

String _withoutComments(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

void main() {
  final root = _packageRoot().path;
  final manifest = _withoutComments(
      File('$root/android/app/src/main/AndroidManifest.xml').readAsStringSync());
  final plist =
      _withoutComments(File('$root/ios/Runner/Info.plist').readAsStringSync());

  group('iOS', () {
    test('the motion usage key is declared', () {
      expect(plist, contains('<key>NSMotionUsageDescription</key>'));
    });

    test('and it says what it actually does', () {
      // A usage string is a promise. This one is narrow on purpose: the sensor
      // is read while the dashboard shows the card and at no other time, which
      // is exactly what the three-condition gate enforces.
      expect(plist, contains('加速度計'));
      expect(plist, contains('儀表板'));
    });
  });

  group('Android', () {
    test('the G meter added NO permission at all', () {
      // Reading the accelerometer needs none below 200 Hz, and this samples at
      // about 50 (design 0045 §2.2 #3, §3.4). A permission appearing here would
      // mean the sampling rate had been raised without anyone noticing what it
      // cost.
      expect(manifest.contains('HIGH_SAMPLING_RATE_SENSORS'), isFalse,
          reason: 'the game-rate sampling this feature uses is far below the '
              '200 Hz threshold that needs it');
      expect(manifest.contains('BODY_SENSORS'), isFalse);
      expect(manifest.contains('ACTIVITY_RECOGNITION'), isFalse,
          reason: 'this is not an activity/fitness feature and must not look '
              'like one to a store reviewer');
    });
  });

  test('the dependency is declared and pinned', () {
    // Design 0045 §2.3 named `sensors_plus` as the single new dependency and
    // left its compatibility with this toolchain to be resolved at `pub get`.
    // It resolved; pinning the constraint here means a future bump is a
    // decision rather than a side effect.
    final pubspec = File('$root/pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('sensors_plus:'));
    final lock = File('$root/pubspec.lock').readAsStringSync();
    expect(lock, contains('sensors_plus'));
  });
}
