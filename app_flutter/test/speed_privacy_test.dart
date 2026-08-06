// 🔴 design 0042 G5 — the coordinate red line, half one: the type layer.
//
// G5 says latitude/longitude may never reach any persistent layer or any
// export. There are two ways to hold that line and only one of them survives
// contact with a future maintainer: you can review every diff forever, or you
// can arrange for there to be no field to put a coordinate in. This file pins
// the second.
//
// FB-33 is why the first way is not good enough. `log_entry.dart` and
// `log_repo.dart` BOTH stated the invariant in prose ("NEVER the raw id: on
// Android that is the MAC address, and this text ends up in a file the user
// shares"), and two MAC addresses were still recovered from a log a reporter
// shared with us. A GPS track is worth considerably more than a MAC.
//
// Half two — "detection off ⇒ speed never lands" — is a Phase E test: it needs
// the settings key and the history column, neither of which exists yet.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Package root regardless of the runner's cwd, so the source scans below can
/// read `lib/`. Same shape as the guard in `power_path_test.dart`.
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

/// Strip comments and doc comments so the scan reads CODE.
///
/// This matters here more than it usually would: the files under test talk
/// about latitude and longitude at length precisely in order to forbid them.
/// A scan that could not tell prose from a declaration would either fail on the
/// warning that keeps the rule alive, or force the warning to be deleted.
String _codeOnly(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

/// Anything that names a position. Substrings for the spelled-out forms (so
/// `myLatitude` is caught too) and word-bounded matches for the abbreviations
/// (so `translate`, `latest` and `locationWhenInUse` are not).
final List<RegExp> _coordinatePatterns = [
  RegExp(r'latitude', caseSensitive: false),
  RegExp(r'longitude', caseSensitive: false),
  RegExp(r'coordinate', caseSensitive: false),
  RegExp(r'\b(lat|lng|lon)\b', caseSensitive: false),
];

List<File> _dartFilesUnder(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));

void main() {
  final root = _packageRoot().path;

  test('the speed feature carries no coordinate, by construction', () {
    final files = _dartFilesUnder('$root/lib').where((f) {
      final name = f.uri.pathSegments.last;
      return name.contains('speed') || name.contains('gps');
    }).toList();

    expect(files, isNotEmpty,
        reason: 'the scan found nothing to scan — renamed files would make '
            'this guard silently vacuous');

    for (final f in files) {
      final code = _codeOnly(f.readAsStringSync());
      for (final p in _coordinatePatterns) {
        expect(p.hasMatch(code), isFalse,
            reason: '${f.path} matches $p — design 0042 G5 forbids a '
                'coordinate anywhere in the speed path. If a platform sample '
                'has one, drop it on the line that maps it, not later.');
      }
    }
  });

  test('nothing in lib/ reads a coordinate off anything', () {
    // The broader half of the same rule. The plugin hands us a position object
    // that DOES carry latitude/longitude; the guarantee is that no line of this
    // app ever touches those members. Scanning the whole tree rather than the
    // speed files alone is deliberate — the leak FB-33 actually produced came
    // from a call site far away from the type that stated the invariant.
    final offenders = <String>[];
    for (final f in _dartFilesUnder('$root/lib')) {
      final code = _codeOnly(f.readAsStringSync());
      if (RegExp(r'\.\s*(latitude|longitude)\b').hasMatch(code)) {
        offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty);
  });

  test('the speed types have no serialiser, so nothing can persist them whole',
      () {
    final code =
        _codeOnly(File('$root/lib/state/speed_estimator.dart').readAsStringSync());
    // `toMap`/`toJson` is how every persisted model in this app reaches the
    // database (see `TelemetrySample.toMap`). Withholding one from SpeedFix and
    // SpeedEstimate means the landing path added in Phase E has to name the
    // individual scalar it writes — it cannot hand the whole object to a repo
    // and hope the shape stays safe.
    for (final serialiser in ['toMap', 'toJson', 'toDb']) {
      expect(code.contains(serialiser), isFalse,
          reason: '$serialiser on a speed type would make bulk persistence a '
              'one-liner, and the red line depends on it not being one');
    }
  });
}
