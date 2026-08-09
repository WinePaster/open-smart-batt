// The clock card (design 0052).
//
// Four properties, and each of them is a thing that would be invisible in
// review and invisible on a developer's screen:
//
//  C1 — the tick lands ON the minute. `Timer.periodic(1 min)` counts from the
//       moment it was created, so a card built at 19:50:59 would next redraw at
//       19:51:59 and read the WRONG minute for 59 seconds out of every 60,
//       forever. Nobody notices that in a hot reload; everybody notices it when
//       they glance at the phone next to a wall clock.
//  C2 — the ticker stops on dispose. An uncancelled one holds a closure over a
//       dead element and calls it once a minute for the life of the process.
//  C3 — 12/24-hour follows the SYSTEM (`alwaysUse24HourFormat`), and the card
//       survives the widest thing that makes: a 1x1 tile on a small phone, in a
//       locale whose day period is two full-width glyphs.
//  C4 — the editor shows a FIXED time and arms no timer. That one is in
//       `home_editor_preview_test.dart`, beside the harness it needs.
//
// 🔑 Every timing assertion here rides `flutter_test`'s FakeAsync clock, and
// the TIME SOURCE is injected (`ClockCard.now` / `AlignedTicker.now`) — the
// seam `relativeTime` established. Nothing in this file waits for a real
// second to pass.
//
// CLEAN-ROOM: expectations derive from this project's own source and design
// docs.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/clock_card.dart';
import 'package:open_smart_batt/ui/util/aligned_ticker.dart';

/// The real outer width of a 1x1 home tile on a 390 pt phone.
///
/// Derived, not guessed:
///
///   screen 390 pt (iPhone 14/15 logical width)
///   HomePage ConstrainedBox maxWidth 560   — does not bind at 390
///   ListView padding LTRB(15, 10, 15, 14)  → 360
///   a row of two `Expanded`, NO gap between them (`home_page.dart`)
///   ÷ 2                                    → 180
const double kTileOuter = 180;

/// The card's INNER width at [kTileOuter]: minus a 1 px border each side and
/// `AppTheme.cardPadding` (15) each side.
///
/// Used as an OUTER width below, which makes the tile deliberately crueller
/// than any real phone — the card then has only 116 px to draw in. The
/// mockup's overflow section is measured against the 148 figure, so a card
/// that survives 148 as its outer width has margin over the picture that was
/// approved.
const double kTileInner = 148;

/// One line of 32 px type at `height: 1`, plus slack. Two lines would be ~64.
/// Same shape of threshold as `narrow_tile_layout_test.dart`'s `kOneLineMax`.
const double kOneLineMax = 48;

Widget _host(
  Widget child, {
  required bool use24,
  double width = 300,
  Locale locale = const Locale('en'),
}) =>
    MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: Builder(
        builder: (context) => MediaQuery(
          // The OS's answer, forced. This is the only input the card has for
          // 12 vs 24 hour — there is no app setting, on purpose (design 0052
          // §5).
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width, child: child),
            ),
          ),
        ),
      ),
    );

void main() {
  // =========================================================================
  // C1 — the tick is aligned to the wall clock, not to the mount time
  // =========================================================================
  group('C1: ticks land on the boundary', () {
    test('🔴 at 19:50:59 the next tick is 1 s away, not 60 s', () {
      // THE regression this whole helper exists for. A `Timer.periodic` armed
      // at this instant fires at 19:51:59 — the card would show `19:50` for 59
      // seconds after that minute ended, and would stay exactly that late for
      // as long as the app runs.
      expect(
        AlignedTicker.untilNext(
            DateTime(2026, 8, 9, 19, 50, 59), const Duration(minutes: 1)),
        const Duration(seconds: 1),
      );
    });

    test('and from any point inside a minute it lands on the next one', () {
      const minute = Duration(minutes: 1);
      for (final (s, ms, expected) in [
        (0, 0, const Duration(minutes: 1)),
        (1, 0, const Duration(seconds: 59)),
        (30, 0, const Duration(seconds: 30)),
        (59, 500, const Duration(milliseconds: 500)),
        (59, 999, const Duration(milliseconds: 1)),
      ]) {
        expect(
          AlignedTicker.untilNext(
              DateTime(2026, 8, 9, 19, 50, s, ms), minute),
          expected,
          reason: 'at :$s.$ms',
        );
      }
    });

    test('🔴 exactly on a boundary schedules the NEXT one, never zero', () {
      // A zero wait re-arms a zero wait: the fake clock in a widget test never
      // advances and the test hangs, and on a device it is a busy loop.
      expect(
        AlignedTicker.untilNext(
            DateTime(2026, 8, 9, 19, 50), const Duration(minutes: 1)),
        const Duration(minutes: 1),
      );
    });

    test('a zone offset that is not a whole hour still aligns to the minute',
        () {
      // Computed from the LOCAL time-of-day fields rather than from
      // `microsecondsSinceEpoch`, so UTC+05:45 (Nepal) aligns to the minute
      // the user's screen shows. This asserts the property that makes that
      // true: only the minute/second/sub-second fields are consulted, so the
      // hour is irrelevant to a one-minute period.
      const minute = Duration(minutes: 1);
      for (final h in [0, 5, 12, 23]) {
        expect(AlignedTicker.untilNext(DateTime(2026, 8, 9, h, 45, 20), minute),
            const Duration(seconds: 40));
      }
    });

    testWidgets('🔴 the CARD redraws at 19:51:00 after mounting at 19:50:59',
        (tester) async {
      // The end-to-end form of the first test: a periodic timer would leave
      // `19:50` on screen here.
      var fake = DateTime(2026, 8, 9, 19, 50, 59);
      await tester.pumpWidget(
        _host(ClockCard(now: () => fake), use24: true),
      );
      expect(find.text('19:50'), findsOneWidget);

      fake = DateTime(2026, 8, 9, 19, 51, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('19:51'), findsOneWidget,
          reason: 'a Timer.periodic(1 min) armed at :59 would still say 19:50');
      expect(find.text('19:50'), findsNothing);

      // …and it keeps going, on the minute, from the new alignment.
      fake = DateTime(2026, 8, 9, 19, 52, 0);
      await tester.pump(const Duration(minutes: 1));
      expect(find.text('19:52'), findsOneWidget);
    });

    test('the declared period comes from the VIEW', () {
      // Seam ③. V1 shows no seconds, so a per-second rebuild would repaint an
      // identical string 59 times out of 60.
      expect(ClockView.digital.tickPeriod, const Duration(minutes: 1));
    });
  });

  // =========================================================================
  // C2 — lifecycle
  // =========================================================================
  group('C2: the ticker is cancelled', () {
    testWidgets('stop() ends it, and a stopped ticker never fires again',
        (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      var fake = DateTime(2026, 8, 9, 19, 50, 0);
      var ticks = 0;
      final t = AlignedTicker(
        period: const Duration(minutes: 1),
        now: () => fake,
        onTick: () => ticks++,
      )..start();
      expect(t.isRunning, isTrue);

      fake = fake.add(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      expect(ticks, 1, reason: 'a running ticker must fire');

      t.stop();
      expect(t.isRunning, isFalse);
      await tester.pump(const Duration(minutes: 10));
      expect(ticks, 1, reason: 'a stopped ticker must never fire again');
    });

    testWidgets('🔴 unmounting the card leaves no pending timer',
        (tester) async {
      // The assertion is the test PASSING: `flutter_test` fails a test at
      // teardown with "A Timer is still pending even after the widget tree was
      // disposed" if anything is left armed. A `dispose` that forgot to cancel
      // re-arms once a minute forever, so it cannot get past this.
      final fake = DateTime(2026, 8, 9, 19, 50, 0);
      await tester.pumpWidget(_host(ClockCard(now: () => fake), use24: true));
      expect(find.text('19:50'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 10));
      expect(tester.takeException(), isNull,
          reason: 'a tick delivered to a dead element throws on setState');
    });
  });

  // =========================================================================
  // C3 — 12/24 hour, and the width it costs
  // =========================================================================
  group('C3: the hour format follows the system', () {
    test('the digits themselves', () {
      final evening = DateTime(2026, 8, 9, 19, 50);
      expect(clockDigits(evening, use24Hour: true), '19:50');
      expect(clockDigits(evening, use24Hour: false), '7:50');
      // Morning: 24-hour PADS, 12-hour does not — which is what both
      // conventions look like everywhere else on the phone.
      final morning = DateTime(2026, 8, 9, 7, 5);
      expect(clockDigits(morning, use24Hour: true), '07:05');
      expect(clockDigits(morning, use24Hour: false), '7:05');
      // 🔴 The two hours that read `0` under a naive `hour % 12`.
      expect(clockDigits(DateTime(2026, 8, 9, 0, 30), use24Hour: false),
          '12:30');
      expect(clockDigits(DateTime(2026, 8, 9, 0, 30), use24Hour: true),
          '00:30');
      expect(clockDigits(DateTime(2026, 8, 9, 12, 30), use24Hour: false),
          '12:30');
    });

    testWidgets('24-hour: `19:50` and no day period at all', (tester) async {
      await tester.pumpWidget(_host(
        ClockCardBody(time: DateTime(2026, 8, 9, 19, 50)),
        use24: true,
      ));
      expect(find.text('19:50'), findsOneWidget);
      expect(find.text('PM'), findsNothing);
      expect(find.text('AM'), findsNothing);
    });

    testWidgets('12-hour: `7:50` with the day period beside it', (tester) async {
      await tester.pumpWidget(_host(
        ClockCardBody(time: DateTime(2026, 8, 9, 19, 50)),
        use24: false,
      ));
      expect(find.text('7:50'), findsOneWidget);
      // From `MaterialLocalizations`, not from `app_en.arb` — "PM"/"下午" is a
      // locale fact Flutter already ships, and restating it in our own ARB
      // would be re-translating the framework.
      expect(find.text('PM'), findsOneWidget);
      expect(find.text('19:50'), findsNothing);
    });

    testWidgets('and the morning half of the same switch', (tester) async {
      await tester.pumpWidget(_host(
        ClockCardBody(time: DateTime(2026, 8, 9, 7, 5)),
        use24: false,
      ));
      expect(find.text('7:05'), findsOneWidget);
      expect(find.text('AM'), findsOneWidget);
    });

    testWidgets('🔴 in Chinese the day period is 下午, and it comes from Flutter',
        (tester) async {
      // The widest thing this card can be asked to draw, and the reason the
      // digits are typeset separately from the period: `下午` is two
      // full-width glyphs, and putting it inside the 32 px tabular run would
      // make the NUMBER change size between locales.
      await tester.pumpWidget(_host(
        ClockCardBody(time: DateTime(2026, 8, 9, 19, 50)),
        use24: false,
        locale: const Locale('zh'),
      ));
      expect(find.text('7:50'), findsOneWidget);
      expect(find.text('下午'), findsOneWidget);
    });
  });

  // =========================================================================
  // C3b — it fits the 1x1 slot it was designed for
  // =========================================================================
  group('C3b: a 1x1 tile does not overflow', () {
    for (final width in [kTileOuter, kTileInner]) {
      for (final (name, use24, locale) in [
        ('24-hour', true, const Locale('en')),
        ('12-hour en', false, const Locale('en')),
        ('12-hour zh', false, const Locale('zh')),
      ]) {
        testWidgets('$name at ${width.toInt()} px', (tester) async {
          await tester.pumpWidget(_host(
            ClockCardBody(time: DateTime(2026, 8, 9, 19, 50)),
            use24: use24,
            width: width,
            locale: locale,
          ));
          // A RenderFlex overflow is a thrown assertion in a widget test, so
          // this is the whole check — but it is written out rather than left
          // implicit, because a silent no-op test is worse than none.
          expect(tester.takeException(), isNull,
              reason: 'the clock overflowed a 1x1 tile at ${width}px');
          final digits = find.text(use24 ? '19:50' : '7:50');
          expect(digits, findsOneWidget);
          expect(tester.getSize(digits).height, lessThan(kOneLineMax),
              reason: 'the time wrapped onto two lines, which is the v0.7.8 '
                  'G-meter defect on a different card');
        });
      }
    }

    testWidgets('an enlarged system font shrinks it rather than breaking it',
        (tester) async {
      // `AppTheme.baseTextScale` is already 1.15 before the user touches
      // anything; 2.0 on top of that is a real accessibility setting.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                alwaysUse24HourFormat: false,
                textScaler: const TextScaler.linear(
                    2.0 * AppTheme.baseTextScale),
              ),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: kTileInner,
                    child: ClockCardBody(time: DateTime(2026, 8, 9, 19, 50)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('7:50'), findsOneWidget);
    });
  });

  // =========================================================================
  // The honesty floor — see `clock_card.dart`'s library comment
  // =========================================================================
  test('🔴 the clock has no availability condition, and it is WRITTEN', () {
    // Not `isTrue` on one settings object: the point is that NOTHING in
    // `AppSettings` and nothing about the G calibration can turn it off, so
    // there is no state in which a placed clock tile disappears. It is the
    // only module in the registry of which that is true.
    for (final s in const [
      AppSettings(),
      AppSettings(speedDetection: true, gMeterEnabled: true),
      AppSettings(speedDetection: false, gMeterEnabled: false),
    ]) {
      for (final g in [true, false]) {
        expect(
            phoneModuleAvailable(DisplayModule.clock, s, gForceAvailable: g),
            isTrue);
      }
    }
  });
}
