// FB-107 (2026-08-30, owner) — the switch has to be FINDABLE, not merely
// present.
//
// design 0089 (FB-103) made the chart card's heading the voltage/current
// switch and advertised it with a bare 14 px `swap_vert` in the heading's
// trailing slot. It shipped in `v0.7.36`, and the owner reported the same
// complaint again on `v0.7.38`, verbatim:
//
//   「歷史資料的切換電壓跟電流趨勢的 icon 很不明顯 可以在按鈕旁邊放切換兩個字嗎？」
//
// 🔴 That is **FB-70's shape a third time** — an entry point too small or too
// unlabelled to find is indistinguishable from a feature that is not there.
// The fix is one word beside the glyph.
//
// ⚠️ **What these tests can and cannot prove.** They pin that the word is in
// the widget tree, inside the tap target, and gone when the gate is shut.
// They CANNOT prove it reads as a control on a real phone — the defect being
// fixed is a visibility defect, and no widget test has ever been able to see.
// Real-device acceptance is still owed (design 0089 §6 said so about the
// previous attempt at the same problem, and that attempt shipped without it).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/l10n/app_localizations_en.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';

import 'support/series_host.dart';

void main() {
  final en = AppLocalizationsEn();
  final t0 = DateTime(2026, 8, 30, 10, 0);

  List<HistoryBucket> run() => [
        for (var i = 0; i < 6; i++)
          HistoryBucket(
            at: t0.add(Duration(minutes: i)),
            avgPvlt: 13.2 + i * 0.01,
            minPvlt: 13.1,
            maxPvlt: 13.3,
            avgAmpere: -3.0 + i,
            minAmpere: -4.0 + i,
            maxAmpere: -2.0 + i,
            count: 60,
          ),
      ];

  Widget host(ProductClass? cls) => MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SeriesHost(
              cls: cls,
              child: (series, onChanged) => HistoryTrendCard(
                buckets: run(),
                stats: HistoryStats.empty,
                tempUnit: TempUnit.celsius,
                multiDay: false,
                bucketMs: 60000,
                deviceClass: cls,
                series: series,
                onSeriesChanged: onChanged,
              ),
            ),
          ),
        ),
      );

  HistoryTrendPainter painterOf(WidgetTester t) => t
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((c) => c.painter)
      .whereType<HistoryTrendPainter>()
      .single;

  final label = find.text(en.historyChartSeriesSwitchLabel);


  group('FB-107 — the glyph travels with a word', () {
    testWidgets('a switchable card labels its switch', (t) async {
      await t.pumpWidget(host(ProductClass.smartBattery));
      await t.pump();

      expect(label, findsOneWidget,
          reason: 'the bare glyph is what the owner reported twice');
      expect(seriesToggle(), findsOneWidget,
          reason: 'the word JOINS the glyph — it does not replace it');
    });

    testWidgets('the word is INSIDE the tap target', (t) async {
      // 🔑 The point of the change. A label that is not part of the button is
      // a caption, and a caption does not make anything pressable.
      await t.pumpWidget(host(ProductClass.smartBattery));
      await t.pump();
      expect(painterOf(t).series, HistoryChartSeries.voltage);

      await t.tap(label);
      await t.pump();
      expect(painterOf(t).series, HistoryChartSeries.current);

      await t.tap(label);
      await t.pump();
      expect(painterOf(t).series, HistoryChartSeries.voltage,
          reason: 'it is a toggle, so the word has to work both ways');
    });

    testWidgets('the full sentence stays available to a screen reader',
        (t) async {
      // The visible word is one syllable of the story; the tooltip / semantics
      // label is the whole of it, and design 0089 put it on the heading button.
      await t.pumpWidget(host(ProductClass.smartBattery));
      await t.pump();
      expect(en.historyChartSeriesSwitchLabel,
          isNot(en.historyChartSeriesToggle),
          reason: 'the short label must not quietly become the long one');
    });

    testWidgets('a 320 dp phone still lays the heading row out', (t) async {
      // 🔴 The word is not free: it eats the `Flexible` title's budget, and
      // that row has already overflowed once in this project's history (see
      // `CardHeading._row`). Measured on the narrowest phone this app targets,
      // with the LONGEST heading of the four.
      //
      // ⚠️ **Known cost, accepted 2026-08-30.** In the fixed-advance TEST font
      // the label loses 67.5 px of budget: English "Today's Voltage Trend" was
      // already ellipsised before this change (182.0 → 114.5) and "Current
      // Trend" newly is (162.5 → 114.5). Chinese is untouched — 「今日電壓趨勢」
      // lays out at 75.0 and 「電流趨勢」 at 50.0, both drawn whole. The test
      // font is wider per character than the font a phone resolves, so those
      // numbers bound the damage rather than describe it.
      //
      // What this test pins is the part that must NEVER regress: the row
      // ellipsises instead of overflowing.
      t.view.physicalSize = const Size(320, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(host(ProductClass.smartBattery));
      await t.pump();

      expect(t.takeException(), isNull,
          reason: 'a striped overflow bar is not an acceptable failure here');
      expect(label, findsOneWidget);
      expect(seriesToggle(), findsOneWidget);
    });

    // =======================================================================
    // The gate. design 0089 §3.1 ruled the affordance HIDES rather than greys
    // out — a greyed-out title is unreadable, and the refusal sentence stays
    // on the plot either way. The word must obey the same rule as the glyph:
    // a lone 「切換」 next to an inert title is FB-64 with better typography.
    // =======================================================================
    for (final cls in <ProductClass?>[ProductClass.supercapacitor, null]) {
      testWidgets('no word and no glyph when the gate is shut: $cls',
          (t) async {
        await t.pumpWidget(host(cls));
        await t.pump();
        expect(label, findsNothing);
        expect(seriesToggle(), findsNothing);
      });
    }
  });
}
