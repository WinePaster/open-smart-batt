// FB-101 / design 0085 S4 — the stats strip follows the chart's left axis.
//
// S3 shipped the switch and left the strip behind. Tapping the toggle redrew
// the curve as current, relabelled the legend, retitled the detail line — and
// left three voltage numbers sitting underneath, under a heading that still
// said Voltage. The owner's ruling was one sentence: 「應該要跟著切」.
//
// 🔴 The failure this file mostly exists for is NOT the label, though. It is
// one line of SQL. `HistoryRepo.aggregate` computes the strip's numbers, and
// every mean already in it is a bare `AVG(col)`. Copying that shape for
// `ampere` compiles, throws nothing, blanks nothing — and prints `+1.8A` under
// a chart line that `queryBuckets` (which uses `_wavg`) has correctly drawn
// BELOW ZERO, because current is the one quantity in the corpus whose SIGN
// flips between the weighted and the unweighted mean. Two numbers about one
// minute, on one screen, disagreeing about whether the battery is charging.
//
// So: group 1 pins the arithmetic, group 2 pins the pixels, and group 3 pins
// the refusals S3 already ruled (capacitor, 「全部裝置」) reaching this strip
// through the SAME gate rather than a second copy of the rule.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/l10n/app_localizations_en.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  // =========================================================================
  // 1. `aggregate()` — the numbers themselves
  // =========================================================================

  group('HistoryRepo.aggregate — the current stats', () {
    late AppDatabase db;
    late HistoryRepo history;

    setUp(() async {
      db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      history = HistoryRepo(db.db);
    });
    tearDown(() async => db.close());

    final minute = DateTime.utc(2026, 8, 7, 19, 26);

    Future<void> put({
      required DateTime at,
      double? pvlt,
      double? ampere,
      int samples = 5,
      String deviceId = 'AA',
    }) async {
      await db.db.insert(Db.tableHistory, <String, Object?>{
        'timestamp': at.millisecondsSinceEpoch,
        'pvlt': pvlt,
        'ampere': ampere,
        'device_id': deviceId,
        'samples': samples,
        'bucket_s': 60,
      });
    }

    test('THE test — the strip\'s mean is `samples`-weighted, sign and all',
        () async {
      // 🔴 The real 19:26 minute from `feedback_log/2026.08.07/007`, the same
      // fixture design 0085 S1 pinned for `queryBuckets`. One battery, one
      // minute, stored as FOUR rows because a disconnect flushed the bucket
      // three extra times, with sample counts 405 / 69 / 3 / 56:
      //
      //   weighted   (405·−1.699 + 69·2.839 + 3·4.000 + 56·2.071) / 533
      //              = −0.68 A  ⇒ DISCHARGING   ← the truth
      //   unweighted (−1.699 + 2.839 + 4.000 + 2.071) / 4
      //              = +1.80 A  ⇒ CHARGING      ← what a bare AVG() answers
      //
      // The strip has room for a sign and no room for a caveat. If this test
      // is ever "fixed" by changing the expected value, read `_wavg`'s doc
      // comment first — four separate log batches re-discovered this.
      const amps = <double>[-1.699, 2.839, 4.000, 2.071];
      const counts = <int>[405, 69, 3, 56];
      for (var i = 0; i < amps.length; i++) {
        await put(
          at: minute.add(Duration(seconds: i * 15)),
          pvlt: 13.2,
          ampere: amps[i],
          samples: counts[i],
        );
      }

      final s = await history.aggregate(deviceId: 'AA');

      expect(s.avgAmpere, isNotNull);
      expect(s.avgAmpere, lessThan(0),
          reason: 'this minute was DISCHARGING; a bare AVG(ampere) here puts '
              'a charging number under a discharging curve');
      expect(s.avgAmpere, closeTo(-0.6834, 1e-3));
      expect(s.avgAmpere, isNot(closeTo(1.8028, 1e-2)),
          reason: 'where AVG(ampere) lands — the wrong side of zero');
    });

    test('the chart and the strip agree about that same minute', () async {
      // design 0065 §6 R5. The strip is drawn directly under the curve; two
      // read paths over the same rows must not answer differently. (They are
      // different aggregations — one bucket vs the whole range — so this is
      // pinned on a range that holds exactly one bucket, where they coincide.)
      const amps = <double>[-1.699, 2.839, 4.000, 2.071];
      const counts = <int>[405, 69, 3, 56];
      for (var i = 0; i < amps.length; i++) {
        await put(
          at: minute.add(Duration(seconds: i * 15)),
          pvlt: 13.2,
          ampere: amps[i],
          samples: counts[i],
        );
      }

      final s = await history.aggregate(deviceId: 'AA');
      final bucket = (await history.queryBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;
      final row = (await history.queryListBuckets(
              bucketMs: 60000, deviceId: 'AA', tzOffsetMs: 0))
          .single;

      expect(s.avgAmpere, closeTo(bucket.avgAmpere!, 1e-9));
      expect(s.avgAmpere, closeTo(row.sample.current!, 1e-9));
      // And at the precision each surface actually PRINTS, which is the level
      // a user can compare them at: the list row shows a magnitude plus a
      // direction word, the strip shows the signed number.
      expect(s.avgAmpere!.abs().toStringAsFixed(1), '0.7');
      expect(
        historyCurrentBit(
            AppLocalizationsEn(), ProductClass.smartBattery, s.avgAmpere!),
        contains('0.7'),
      );
    });

    test('the extremes are raw readings, never weighted', () async {
      // A 1-sample row at +9.0 A is a reading that HAPPENED. It contributes
      // almost nothing to the mean and must still own the MAX — the same rule
      // pvlt and temperature already follow here.
      await put(at: minute, pvlt: 13.2, ampere: -0.5, samples: 500);
      await put(
          at: minute.add(const Duration(seconds: 10)),
          pvlt: 13.2,
          ampere: 9.0,
          samples: 1);
      await put(
          at: minute.add(const Duration(seconds: 20)),
          pvlt: 13.2,
          ampere: -7.0,
          samples: 1);

      final s = await history.aggregate(deviceId: 'AA');
      expect(s.maxAmpere, closeTo(9.0, 1e-9));
      expect(s.minAmpere, closeTo(-7.0, 1e-9));
      expect(s.avgAmpere, closeTo((-0.5 * 500 + 9.0 - 7.0) / 502, 1e-9));
    });

    test('a range with no current at all reports null, not 0.0', () async {
      // ⛔ 0.0 A is a claim ("measured, and it was zero"). A capacitor's `0x2E`
      // is exactly that lie, which is why it is gated out below; a range that
      // never read the register must say nothing instead.
      await put(at: minute, pvlt: 13.2, samples: 60);
      final s = await history.aggregate(deviceId: 'AA');
      expect(s.count, 1);
      expect(s.avgAmpere, isNull);
      expect(s.minAmpere, isNull);
      expect(s.maxAmpere, isNull);
    });

    test('rows that never read the register do not dilute the ones that did',
        () async {
      await put(at: minute, pvlt: 13.2, ampere: -3.0, samples: 60);
      await put(
          at: minute.add(const Duration(seconds: 30)),
          pvlt: 13.2,
          samples: 6000);
      final s = await history.aggregate(deviceId: 'AA');
      expect(s.avgAmpere, closeTo(-3.0, 1e-9),
          reason: 'a NULL ampere carries no weight');
    });

    test('⛔ the voltage and temperature means are UNCHANGED — still bare AVG',
        () async {
      // 🔑 A deliberate inconsistency, pinned so it cannot be "tidied" by
      // accident in either direction. design 0085 S4's scope is CURRENT ONLY;
      // switching `avgPvlt` to `_wavg` would move numbers already on users'
      // screens and is a separate decision nobody has taken. See
      // [HistoryStats.minAmpere]'s doc comment.
      await put(at: minute, pvlt: 12.5, ampere: -1.0, samples: 400);
      await put(
          at: minute.add(const Duration(seconds: 30)),
          pvlt: 14.5,
          ampere: 3.0,
          samples: 100);

      final s = await history.aggregate(deviceId: 'AA');
      expect(s.avgPvlt, closeTo(13.5, 1e-9),
          reason: 'the UNWEIGHTED (12.5 + 14.5) / 2 — today\'s behaviour');
      expect(s.avgPvlt, isNot(closeTo(12.9, 1e-6)),
          reason: 'the weighted value; if the strip ever moves here it must be '
              'a ruling, not a side effect of this design');
      // …while ampere, in the very same query, is weighted.
      expect(s.avgAmpere, closeTo((-1.0 * 400 + 3.0 * 100) / 500, 1e-9));
    });
  });

  // =========================================================================
  // 2. The strip on screen
  // =========================================================================

  group('_StatsStrip follows the series', () {
    final en = AppLocalizationsEn();
    final t0 = DateTime(2026, 8, 27, 10, 0);

    List<HistoryBucket> run() => [
          for (var i = 0; i < 6; i++)
            HistoryBucket(
              at: t0.add(Duration(minutes: i)),
              avgPvlt: 13.2 + i * 0.01,
              minPvlt: 13.1,
              maxPvlt: 13.3,
              avgTemp: 25.0,
              minTemp: 24.0,
              maxTemp: 26.0,
              avgAmpere: -3.0 + i,
              minAmpere: -4.0 + i,
              maxAmpere: -2.0 + i,
              count: 60,
            ),
        ];

    // Range-wide numbers chosen so every printed string is unique and so the
    // current MIN is negative (design 0030 §3.2 Q5 — no `abs()`).
    const stats = HistoryStats(
      minPvlt: 12.98,
      maxPvlt: 13.31,
      avgPvlt: 13.20,
      minTemp: 24.0,
      maxTemp: 26.0,
      avgTemp: 25.0,
      minAmpere: -4.2,
      maxAmpere: 3.6,
      avgAmpere: -0.6834,
      count: 360,
    );

    Widget host(ProductClass? cls) => MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: SingleChildScrollView(
              child: HistoryTrendCard(
                buckets: run(),
                stats: stats,
                tempUnit: TempUnit.celsius,
                multiDay: false,
                bucketMs: 60000,
                deviceClass: cls,
              ),
            ),
          ),
        );

    final toggle = find.widgetWithIcon(IconButton, Icons.swap_vert);

    testWidgets('voltage mode is exactly what it was before S4', (t) async {
      // Regression. Nothing about the default view moves.
      await t.pumpWidget(host(ProductClass.smartBattery));
      expect(find.text('12.98V'), findsOneWidget);
      expect(find.text('13.20V'), findsOneWidget);
      expect(find.text('13.31V'), findsOneWidget);
      // Legend entry + strip title, the same word in both.
      expect(find.text(en.historyLegendVoltage), findsNWidgets(2));
      expect(find.text(en.historyLegendCurrent), findsNothing);
      expect(find.text(en.historyStatMin), findsNWidgets(2));
      expect(find.text(en.historyStatAvg), findsNWidgets(2));
      expect(find.text(en.historyStatMax), findsNWidgets(2));
    });

    testWidgets('the toggle switches the numbers AND the label', (t) async {
      // 🔴 Both halves. Swapping only the numbers leaves `-0.7A` filed under
      // "Voltage", which is worse than not switching at all.
      await t.pumpWidget(host(ProductClass.smartBattery));
      await t.tap(toggle);
      await t.pump();

      expect(find.text(en.historyLegendCurrent), findsNWidgets(2),
          reason: 'legend + strip title');
      expect(find.text(en.historyLegendVoltage), findsNothing,
          reason: 'the word must LEAVE, not merely be joined');
      expect(find.text('-4.2A'), findsOneWidget);
      expect(find.text('-0.7A'), findsOneWidget);
      expect(find.text('3.6A'), findsOneWidget);
      expect(find.text('12.98V'), findsNothing);
      expect(find.text('13.20V'), findsNothing);
      expect(find.text('13.31V'), findsNothing);
    });

    testWidgets('a negative MIN keeps its sign — ⛔ no abs()', (t) async {
      // design 0030 §3.2 Q5. The list row spends a word (`放電中`) saying which
      // way the energy is going; in the strip the minus sign is the only
      // carrier there is, and stripping it would make −4.2 A of discharge and
      // +4.2 A of charge print identically.
      await t.pumpWidget(host(ProductClass.smartBattery));
      await t.tap(toggle);
      await t.pump();
      expect(find.text('-4.2A'), findsOneWidget);
      expect(find.text('4.2A'), findsNothing);
      expect(find.text('-0.7A'), findsOneWidget);
      expect(find.text('0.7A'), findsNothing);
    });

    testWidgets('one decimal, the same as the list row prints', (t) async {
      // design 0065 §6 R5. `historyCurrentBit` prints one decimal, and `0x2E`
      // is 1 A per count anyway (§1.8) — a second decimal would be inventing
      // resolution the wire never had.
      await t.pumpWidget(host(ProductClass.smartBattery));
      await t.tap(toggle);
      await t.pump();
      expect(find.text('-0.68A'), findsNothing);
      expect(find.text('-0.6834A'), findsNothing);
      expect(find.text('-0.7A'), findsOneWidget);
      expect(
        historyCurrentBit(en, ProductClass.smartBattery, stats.avgAmpere!),
        contains('0.7'),
      );
    });

    testWidgets('the temperature row is untouched by the switch', (t) async {
      // 案 B moves the LEFT axis only; temperature is on the right and stays
      // there. Its row must therefore read the same in both modes.
      await t.pumpWidget(host(ProductClass.smartBattery));
      expect(find.text('25°C'), findsOneWidget);
      expect(find.text('24°C'), findsOneWidget);
      expect(find.text('26°C'), findsOneWidget);
      await t.tap(toggle);
      await t.pump();
      expect(find.text('25°C'), findsOneWidget);
      expect(find.text('24°C'), findsOneWidget);
      expect(find.text('26°C'), findsOneWidget);
      expect(find.text(en.historyLegendTemperature), findsNWidgets(2));
    });

    testWidgets('switching back restores the voltage numbers', (t) async {
      await t.pumpWidget(host(ProductClass.smartBattery));
      await t.tap(toggle);
      await t.pump();
      await t.tap(toggle);
      await t.pump();
      expect(find.text('13.20V'), findsOneWidget);
      expect(find.text(en.historyLegendVoltage), findsNWidgets(2));
      expect(find.text('-0.7A'), findsNothing);
    });

    // ---- the refusals, through the SAME gate ----------------------------

    testWidgets('a super-capacitor never gets current stats', (t) async {
      // §1.5: its `0x2E` is pinned at 0.0 A on a unit that cannot measure
      // current. `HistoryStats` would still carry the placeholder zeros — the
      // strip must not print them, and it must not need its own copy of the
      // rule to avoid it (the caller resolves `historyChartCurrentGate` first).
      await t.pumpWidget(host(ProductClass.supercapacitor));
      expect(isDisabled(t, toggle), isTrue);
      await t.tap(toggle);
      await t.pump();
      expect(find.text(en.historyLegendCurrent), findsNothing);
      expect(find.text('-0.7A'), findsNothing);
      expect(find.text('13.20V'), findsOneWidget);
      expect(find.text(en.historyLegendVoltage), findsNWidgets(2));
    });

    testWidgets('「全部裝置」 never gets current stats', (t) async {
      // §1.6 / Q4 ③: `queryBuckets` groups by time, never by `device_id`, and
      // the two families sign current the opposite way round — so a range-wide
      // `aggregate()` over a mixed scope averages −3 A of battery discharge
      // with +3 A of power-bank discharge and reports 0 A. ⛔ The strip must
      // never put a number on that, and unlike the chart it has no band or
      // axis to hint with.
      await t.pumpWidget(host(null));
      expect(isDisabled(t, toggle), isTrue);
      await t.tap(toggle);
      await t.pump();
      expect(find.text(en.historyLegendCurrent), findsNothing);
      expect(find.text('-0.7A'), findsNothing);
      expect(find.text('13.20V'), findsOneWidget);
    });

    testWidgets('an unknown-family unit DOES get them', (t) async {
      // `unknown` is not null's synonym: one unit whose family nobody recorded
      // still stores one convention. The list row draws its current too.
      await t.pumpWidget(host(ProductClass.unknown));
      await t.tap(toggle);
      await t.pump();
      expect(find.text(en.historyLegendCurrent), findsNWidgets(2));
      expect(find.text('-0.7A'), findsOneWidget);
    });

    testWidgets('a null metric prints `--`, not a fabricated 0.0A', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: SingleChildScrollView(
              child: HistoryTrendCard(
                buckets: run(),
                // Temperature is filled in so the three `--` below can only
                // have come from the current row.
                stats: const HistoryStats(
                  minPvlt: 12.98,
                  maxPvlt: 13.31,
                  avgPvlt: 13.20,
                  minTemp: 24.0,
                  maxTemp: 26.0,
                  avgTemp: 25.0,
                  count: 360,
                ),
                tempUnit: TempUnit.celsius,
                multiDay: false,
                bucketMs: 60000,
                deviceClass: ProductClass.smartBattery,
              ),
            ),
          ),
        ),
      );
      await t.tap(toggle);
      await t.pump();
      expect(find.text(en.historyLegendCurrent), findsNWidgets(2));
      expect(find.text('--'), findsNWidgets(3));
      expect(find.text('0.0A'), findsNothing);
    });
  });
}

/// Is the [IconButton] at [f] disabled? (`onPressed == null`.)
bool isDisabled(WidgetTester t, Finder f) =>
    t.widget<IconButton>(f).onPressed == null;
