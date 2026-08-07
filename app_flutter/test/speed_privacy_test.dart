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

    // 🔴 RE-POINTED 2026-08-07, by ruling, in the same change that landed
    // design 0045. The QUESTION is unchanged, word for word: with detection
    // off, no class and no stored face may lay out `DisplayModule.speed`. What
    // changed is which function is asked.
    //
    // Until design 0045 the filtering happened at the FACE layer, so asking
    // `watchfaceModules(cls, renderedWatchface(…))` was the whole story: switch
    // off ⇒ `riding` fell back to `standard` ⇒ no `speed` in the list. Design
    // 0045 Q3 lets the G meter keep `riding` alive on its own, so `riding` can
    // now be DRAWN with speed detection off — and a face-level check would have
    // gone on passing while the speed card was laid out anyway. The decision
    // moved down one layer, to `renderedModules`, and so does this test.
    //
    // This is a MORE precise question, not a weaker one: "which face is drawn"
    // was only ever a proxy for "what is on it", and the proxy has stopped
    // being exact.
    test('with it off, NO face on ANY class lays out the speed module', () {
      // Link 1, and the load-bearing one. The GNSS gate's first condition is
      // "a speed card is mounted", and only a laid-out module produces one.
      // No module ⇒ no card ⇒ no stream ⇒ no sample ⇒ no row. Everything
      // downstream is unreachable rather than merely unwritten.
      //
      // Both G states are swept, because "G available" is exactly the input
      // that makes `riding` reachable with speed off — testing only the
      // convenient one would leave the new hole untested.
      for (final gAvailable in [false, true]) {
        for (final cls in ProductClass.values) {
          for (final stored in Watchface.values) {
            final drawn = renderedModules(cls, stored, off,
                gForceAvailable: gAvailable);
            expect(drawn, isNot(contains(DisplayModule.speed)),
                reason: '$cls / ${stored.slug} (G available: $gAvailable) '
                    'would draw the speed card with detection off, which '
                    'would open the GNSS stream');
          }
        }
      }
    });

    test('and with it on, exactly one face does', () {
      // The mirror image: a guard that held because the module was unreachable
      // in BOTH states would be vacuous.
      for (final cls in ProductClass.values) {
        final withSpeed = [
          for (final f in Watchface.values)
            if (renderedModules(cls, f, on, gForceAvailable: false)
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
        //
        // 🔴 Columns are located BY NAME, not by counting from the end. This
        // used to assert that `accel` was the last column and then index
        // backwards from it; design 0045 appended `g_long`/`g_lat` under the
        // standing append-only rule and the arithmetic silently pointed at the
        // wrong cells. Positional indexing into a list that is documented as
        // growing was the bug, so the fix is to stop doing it — the assertions
        // themselves are unchanged.
        final csv = await repo.exportCsv();
        final body = csv.text.split(RegExp(r'\r?\n'));
        final header =
            body.first.split(',').map((c) => c.replaceAll('"', '')).toList();
        final cells = body[1].split(',');
        String cell(String column) {
          final i = header.indexOf(column);
          expect(i, greaterThanOrEqualTo(0), reason: 'no $column column');
          return cells[i];
        }

        expect(cell('speed'), 'null', reason: 'speed');
        expect(cell('accel'), 'null', reason: 'accel');
        expect(cell('accel'), isNot('0'));
        expect(cell('accel'), isNot('0.0'));
      }();
    });
  });
}
