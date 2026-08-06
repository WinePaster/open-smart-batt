// Platform declarations for GPS speed (design 0042 Phase C / §3.5 / N1).
//
// These two files are the part of this feature nobody can review from the Dart
// code, and the part with the highest cost of being wrong: a stray background
// location key is a store-review conversation, and the usage string is a
// promise made to every user who reads the permission dialog. Both are pinned
// here rather than trusted to a diff.
//
// The usage string in particular has already been wrong once. An earlier draft
// promised "速度資訊不會被儲存或上傳" while the same design has speed going into
// history and into exports — the ruling of 2026-08-06 narrowed the promise to
// the coordinate. The assertion below is on the corrected wording, verbatim.
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

/// Drop XML comments, so the prose explaining why a key is absent cannot be
/// mistaken for the key being present.
String _withoutComments(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

void main() {
  final root = _packageRoot().path;
  final manifest = _withoutComments(
      File('$root/android/app/src/main/AndroidManifest.xml').readAsStringSync());
  final plist =
      _withoutComments(File('$root/ios/Runner/Info.plist').readAsStringSync());

  group('Android', () {
    test('ACCESS_FINE_LOCATION is no longer capped at API 30', () {
      final element = RegExp(r'<uses-permission[^>]*ACCESS_FINE_LOCATION[^>]*>')
          .firstMatch(manifest);
      expect(element, isNotNull);
      // The cap was BLE-scan legacy. Leaving it on would mean the speed feature
      // silently has no permission on every phone sold since Android 12 — and
      // the failure would look like "GPS never gets a fix", not like a manifest
      // problem.
      expect(element!.group(0), isNot(contains('maxSdkVersion')));
    });

    test('no background location, and the service type is unchanged', () {
      for (final forbidden in [
        'ACCESS_BACKGROUND_LOCATION',
        'FOREGROUND_SERVICE_LOCATION',
      ]) {
        expect(manifest.contains(forbidden), isFalse,
            reason: '$forbidden is design 0042 N1 — this feature is '
                'foreground-only and does not ride on design 0039');
      }
      // design 0008's foreground service keeps its connectedDevice type.
      expect(manifest, contains('FOREGROUND_SERVICE_CONNECTED_DEVICE'));
    });

    test('the BLE scan declaration is untouched', () {
      // Regression guard for §3.5: the two features share one location
      // permission, and neverForLocation is what keeps the BLE scan from being
      // treated as location gathering.
      expect(manifest, contains('neverForLocation'));
      expect(manifest, contains('android.permission.BLUETOOTH_SCAN'));
    });
  });

  group('iOS', () {
    test('the WhenInUse usage string is the ruled wording, verbatim', () {
      expect(plist, contains('<key>NSLocationWhenInUseUsageDescription</key>'));
      expect(
        plist,
        contains('<string>顯示騎乘速度時需要取得定位（位置座標不會被儲存或上傳）。</string>'),
      );
    });

    test('no always-on location and no background modes', () {
      for (final forbidden in [
        'NSLocationAlwaysAndWhenInUseUsageDescription',
        'NSLocationAlwaysUsageDescription',
        'UIBackgroundModes',
      ]) {
        expect(plist.contains(forbidden), isFalse,
            reason: '$forbidden would turn a foreground speed readout into a '
                'background-location app (0042 N1 / R1)');
      }
    });
  });
}
