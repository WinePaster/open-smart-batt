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
// Half two — "detection off ⇒ speed never lands" — arrived with Phase E and is
// the last group in this file. It is pinned SEPARATELY from the coordinate rule
// on purpose: they are different promises with different consequences. A
// coordinate leak is permanent and unbounded; a speed leak is bounded by what
// the user agreed to in the consent dialog. Merging them into one test would
// let a change that weakens either one be argued past on the strength of the
// other.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/dashboard/watchfaces.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

  // =========================================================================
  // 🔴 G5 half two — with the switch off, speed never lands (design 0042 §3.9)
  // =========================================================================
  //
  // Off is the DEFAULT, so this is the promise made to everyone who never opens
  // the setting: no GNSS stream, no rows, nothing in an export. It is enforced
  // structurally rather than by a check at the write, and the structure is a
  // chain — each link is asserted below, because a chain argued in prose is how
  // FB-33 happened.
  group('detection off ⇒ nothing to land in the first place', () {
    const off = AppSettings();
    const on = AppSettings(speedDetection: true);

    test('the switch is off unless someone turned it on', () {
      expect(AppSettings.defaults.speedDetection, isFalse);
      expect(off.speedDetection, isFalse);
    });

    test('with it off, NO face on ANY class lays out the speed module', () {
      // Link 1, and the load-bearing one. The GNSS gate's first condition is
      // "the effective face renders speed", and the speed card is what reports
      // it. No module ⇒ no card ⇒ no stream ⇒ no sample ⇒ no row. Everything
      // downstream is unreachable rather than merely unwritten.
      for (final cls in ProductClass.values) {
        for (final stored in Watchface.values) {
          final drawn = watchfaceModules(cls, renderedWatchface(cls, stored, off));
          expect(drawn, isNot(contains(DisplayModule.speed)),
              reason: '$cls / ${stored.slug} would draw the speed card with '
                  'detection off, which would open the GNSS stream');
        }
      }
    });

    test('and with it on, exactly one face does', () {
      // The mirror image: a guard that held because the module was unreachable
      // in BOTH states would be vacuous.
      for (final cls in ProductClass.values) {
        final withSpeed = [
          for (final f in Watchface.values)
            if (watchfaceModules(cls, renderedWatchface(cls, f, on))
                .contains(DisplayModule.speed))
              f,
        ];
        // `unknown` is forced to `standard` by design 0034 Q4, so it gets none.
        expect(withSpeed, cls == ProductClass.unknown ? isEmpty : [Watchface.riding],
            reason: '$cls');
      }
    });

    test('a row written with no speed keeps the column NULL, not 0.0', () {
      // Link 2, at the storage end. Null is the only value that can mean "no
      // measurement"; 0.0 would claim the phone was measured standing still,
      // which is the same lie in the database that G2 forbids on screen.
      sqfliteFfiInit();
      return () async {
        final db = await AppDatabase.open(
            path: inMemoryDatabasePath, factory: databaseFactoryFfi);
        addTearDown(db.close);
        final repo = HistoryRepo(db.db);
        await repo.insertSample(
          TelemetrySample(
              timestamp: DateTime.fromMillisecondsSinceEpoch(60000), pvlt: 12.5),
          deviceId: 'AA',
        );
        final row = (await db.db.query(Db.tableHistory)).single;
        expect(row['speed'], isNull);
        expect(row['accel'], isNull);
        // And it exports as an absent cell, not as a number. ⚠️ "Absent"
        // renders as the literal `null` here — that is this app's existing CSV
        // convention for every nullable column (`soc`, `device`, `app_build`
        // …), not something these two columns do differently, and changing it
        // would move every recipient's spreadsheet. What matters for G2 is only
        // that it is not `0`.
        final csv = await repo.exportCsv();
        final body = csv.text.split(RegExp(r'\r?\n'));
        expect(body.first.split(',').last.replaceAll('"', ''), 'accel');
        final cells = body[1].split(',');
        expect(cells[cells.length - 2], 'null', reason: 'speed');
        expect(cells.last, 'null', reason: 'accel');
        expect(cells.last, isNot('0'));
        expect(cells.last, isNot('0.0'));
      }();
    });
  });
}
