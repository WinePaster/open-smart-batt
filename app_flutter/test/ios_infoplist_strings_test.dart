// Every iOS permission purpose string must be localized in BOTH lproj files.
//
// App Review reads these prompts in English; before 2026-10-18 they existed
// only in Chinese in Info.plist. A purpose key added to Info.plist but not to
// en.lproj would silently show Chinese to an English reviewer again (5.1.1),
// and nothing else in the build would notice.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Set<String> _keys(String text, RegExp pattern) =>
    pattern.allMatches(text).map((m) => m.group(1)!).toSet();

void main() {
  final plist = File('ios/Runner/Info.plist').readAsStringSync();
  final usageKeys =
      _keys(plist, RegExp(r'<key>(NS\w+UsageDescription)</key>'));

  test('Info.plist declares purpose strings at all', () {
    expect(usageKeys, contains('NSBluetoothAlwaysUsageDescription'));
  });

  for (final lproj in ['en', 'zh-Hant']) {
    test('$lproj.lproj covers every purpose key in Info.plist', () {
      final strings = File('ios/Runner/$lproj.lproj/InfoPlist.strings')
          .readAsStringSync();
      expect(_keys(strings, RegExp(r'^"(\w+)" = ', multiLine: true)),
          equals(usageKeys));
    });
  }

  test('iPhone only for the first App Store release', () {
    // Shipping once with iPad support makes it impossible to remove later.
    final pbx =
        File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(pbx, isNot(contains('TARGETED_DEVICE_FAMILY = "1,2"')));
    expect(pbx, contains('TARGETED_DEVICE_FAMILY = 1;'));
  });
}
