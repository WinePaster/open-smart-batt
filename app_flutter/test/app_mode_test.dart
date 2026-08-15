// Personal / advanced mode (design 0063).
//
// WHAT THIS FEATURE IS. One two-valued setting. `personal` is the app exactly
// as it shipped yesterday — four tabs, opens on the home grid, speed card and G
// meter available. `advanced` removes the home tab from the bottom bar and, with
// it, withdraws the three things that only ever lived there: the speed card, the
// G meter and full-screen mode.
//
// 🔑 WHAT MAKES IT WORTH ITS OWN TEST FILE is that both halves fail silently.
//
//   * Get the DEFAULT wrong and every existing user loses their main screen on
//     the next launch, with nothing they did to explain it and no error to
//     read. There is no message for "a tab you were used to is missing".
//   * Get the effective-value fold wrong and nothing visible breaks at all —
//     the exports simply start saying `g meter: on` beside an empty column, and
//     we find out months later from a capture we can no longer interpret. That
//     is the same defect FB-32 cost three wrong replies to a reporter.
//
// The tests are numbered H1–H10 after `0063-implementation-plan.md` §6, and each
// one names the regression it catches rather than the code it touches.
//
// H1  fresh install and upgrade both land on personal   (also `schema_v18_test`)
// H4  advanced withdraws the features WITHOUT rewriting the user's switches
// H9  the effective-value rule has no seventh consumer  (grep guard)
// H10 the export preamble states the mode, and states the effective switches
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';

/// A settings row with both features switched ON, so that every assertion about
/// advanced mode is about the MODE withdrawing them rather than about them
/// having been off in the first place.
const AppSettings _bothOn = AppSettings(
  speedDetection: true,
  gMeterEnabled: true,
);

List<String> _header(AppSettings s) => exportHeaderLines(
      title: 'OpenSmartBatt history export',
      exportedAt: DateTime.utc(2026, 8, 15, 12, 0),
      appBuild: '0.7.20+26081500',
      platform: 'android 15',
      scope: 'device=battery/1206',
      layout: 'face=standard modules=gaugeVoltage,readouts,cells',
      home: 'tiles=auto',
      mode: s.mode,
      // Exactly what the three call sites in `lib/` pass — the EFFECTIVE
      // values. Passing the stored ones here would make this file agree with a
      // bug rather than catch it.
      speedDetection: s.speedDetectionEffective,
      gMeter: s.gMeterEffective,
      resolution: ExportResolution.none,
    );

void main() {
  group('H1: nobody is moved into advanced mode by an upgrade', () {
    test('a fresh install is personal', () {
      // The constructor default. `schema_v18_test` covers the other half — an
      // upgraded row, whose `app_mode` is NULL — because that one needs a real
      // database to be worth anything.
      expect(AppSettings.defaults.mode, AppMode.personal);
    });

    test('a row with no app_mode at all decodes to personal', () {
      // The pre-v18 shape: the KEY IS ABSENT, which is different from present
      // and null and is what `fromMap` actually meets when a v17 row is read by
      // a build that has not upgraded the file yet.
      expect(AppSettings.fromMap(const <String, Object?>{}).mode,
          AppMode.personal);
      expect(AppSettings.fromMap(const {'app_mode': null}).mode,
          AppMode.personal);
    });

    test('a value this build does not know decodes to personal, not a throw',
        () {
      // A downgrade after some future release adds a third mode. Settings
      // decoding never throws in this file (the standing `_themeModeFromMap`
      // rule): one unreadable cosmetic field must not stop the app starting.
      expect(AppSettings.fromMap(const {'app_mode': 'expert'}).mode,
          AppMode.personal);
      expect(AppSettings.fromMap(const {'app_mode': 7}).mode, AppMode.personal);
    });

    test('personal mode changes NOTHING about the effective values', () {
      // The design's central promise, stated as an assertion: in personal mode
      // the fold is the identity, so "personal == today's app" is mechanical
      // rather than a claim in a doc.
      for (final speed in [false, true]) {
        for (final g in [false, true]) {
          final s = AppSettings(speedDetection: speed, gMeterEnabled: g);
          expect(s.speedDetectionEffective, speed);
          expect(s.gMeterEffective, g);
        }
      }
    });
  });

  group('H4: advanced withdraws the features and keeps the answers', () {
    final advanced = _bothOn.copyWith(mode: AppMode.advanced);

    test('the effective values go false', () {
      expect(advanced.speedDetectionEffective, isFalse);
      expect(advanced.gMeterEffective, isFalse);
    });

    test('🔑 the STORED switches are untouched', () {
      // Design 0063 Q9, and the reason it was ruled that way: somebody who
      // tries advanced mode for ten minutes and comes back must find their own
      // choices where they left them. If a future `setMode` ever "tidies up" by
      // writing the switches false, this is what says no — and the user-visible
      // symptom it prevents (settings that quietly emptied themselves) is one
      // nobody would report as a bug about mode switching.
      expect(advanced.speedDetection, isTrue);
      expect(advanced.gMeterEnabled, isTrue);
      // …and switching back restores the feature with no second write.
      expect(advanced.copyWith(mode: AppMode.personal).speedDetectionEffective,
          isTrue);
      expect(
          advanced.copyWith(mode: AppMode.personal).gMeterEffective, isTrue);
    });

    test('the home grid stops offering the speed card', () {
      // `phoneModuleAvailable` is the single decision point both drawing
      // surfaces share (`display_module.dart`), so this is what keeps the speed
      // card out of a layout the home grid would otherwise still generate —
      // advanced mode hides the tab but leaves the page mounted.
      expect(
        phoneModuleAvailable(DisplayModule.speed, advanced,
            gForceAvailable: false),
        isFalse,
      );
      expect(
        phoneModuleAvailable(DisplayModule.speed, _bothOn,
            gForceAvailable: false),
        isTrue,
      );
    });
  });

  group('H9: the effective-value rule has no seventh consumer', () {
    test('only the model, the controller and the settings screen read the '
        'stored switches', () {
      // 🔑 A GREP, not a unit test, and deliberately so — the defect it catches
      // is the ADDITION of a reader somewhere else, which by definition no
      // existing test covers. The shape is borrowed from
      // `direction_followups_test.dart` X5, which does the same thing to
      // `exportHeaderLines(`'s call sites.
      //
      // What goes wrong without it: a new export path, a new card, a new
      // notification reads `.speedDetection` because that is the obvious name,
      // and it is right in personal mode — which is every developer's phone and
      // every test — and wrong in advanced mode, where it prints a confident
      // header over an empty column. We would find out from a field capture,
      // months later, and it would look like a data-loss bug rather than a
      // one-line mistake.
      //
      // Three files are allowed, and each has a reason it cannot be folded:
      //   * `app_settings.dart` DEFINES both fields and both folds;
      //   * `settings_controller.dart` passes them through for the screen below;
      //   * `settings_screen.dart` DRAWS the user's own answer, which stays
      //     visible while advanced mode withholds the feature (Q9). The screen
      //     answers "what did I say"; everything else answers "what happened",
      //     and only the second one is the fold.
      final grep = Process.runSync(
        'grep',
        // `\b` so that `speedDetectionEffective` — which legitimately contains
        // `speedDetection` — is not counted as a stored-value read. That
        // subtlety is the whole reason this is a word-boundary regex rather
        // than a plain substring search.
        ['-rnE', r'\.(speedDetection|gMeterEnabled)\b', 'lib/'],
        runInShell: false,
      );
      final readers = (grep.stdout as String)
          .trim()
          .split('\n')
          .where((l) => l.isNotEmpty)
          .map((l) => l.split(':'))
          // `path:line:source`. Doc comments name these fields constantly —
          // several of them precisely to warn the reader off — and a sentence
          // about a field is not a read of it.
          .where((p) => !p.sublist(2).join(':').trimLeft().startsWith('//'))
          .map((p) => p.first)
          .toSet();
      expect(readers, {
        'lib/models/app_settings.dart',
        'lib/state/settings_controller.dart',
        'lib/ui/settings/settings_screen.dart',
      });
    });
  });

  group('H10: the preamble says which app wrote the file', () {
    test('`mode:` is emitted for personal too', () {
      // FB-32's standing rule. A line that appeared only in advanced mode would
      // make its absence mean both "they were in personal mode" and "a build
      // older than this one wrote the file" — and these files are read years
      // later, so the second reading never goes away.
      expect(_header(_bothOn), contains('mode: personal'));
      expect(_header(_bothOn.copyWith(mode: AppMode.advanced)),
          contains('mode: advanced'));
    });

    test('it sits directly above the two switch lines', () {
      // Adjacency is asserted rather than left loose because it is what makes
      // `speed detection: off` readable: since 0063 that `off` has two causes,
      // and `mode:` is the line that separates them. Whoever inserts the next
      // header line has to come here and say where it goes.
      final lines = _header(_bothOn);
      final at = lines.indexOf('mode: personal');
      expect(at, greaterThan(0));
      expect(lines[at + 1], startsWith('speed detection: '));
      expect(lines[at + 2], startsWith('g meter: '));
    });

    test('`layout:` is still the last line', () {
      // T10 constraint 1 (`export_layout_header_test.dart:51`): the ingest
      // scripts anchor on it. A new line in the optional middle must not have
      // moved it, and this is cheap insurance against the next one either.
      expect(_header(_bothOn).last, startsWith('layout: '));
      expect(_header(_bothOn.copyWith(mode: AppMode.advanced)).last,
          startsWith('layout: '));
    });

    test('🔑 in advanced mode both switch lines print off, even though the '
        'user left them on', () {
      // §0.6's failure path, written out: turn the G meter on in personal mode,
      // switch to advanced, export. The stored switch still says `on`; the
      // column cannot contain anything; a header that reported the switch would
      // state the same lie FB-32 was raised to end, arriving by a new route.
      final lines = _header(_bothOn.copyWith(mode: AppMode.advanced));
      expect(lines, contains('speed detection: off'));
      expect(lines, contains('g meter: off'));
      // The control: same settings, personal mode, both on.
      final personal = _header(_bothOn);
      expect(personal, contains('speed detection: on'));
      expect(personal, contains('g meter: on'));
    });

    test('the mode line is machine-stable ASCII, not localized', () {
      // A preamble is read by whoever RECEIVES the file — us, months later, or
      // a script — not by the phone that produced it. Same rule as
      // `exportScopeLabel`.
      for (final m in AppMode.values) {
        final line = _header(AppSettings(mode: m))
            .firstWhere((l) => l.startsWith('mode: '));
        expect(line, 'mode: ${m.name}');
        expect(line.codeUnits, everyElement(lessThan(128)));
      }
    });
  });
}
