// design 0089 / FB-103 — 圖表標題要說實話。
//
// THE FIELD REPORT. The owner, on `v0.7.35`: 「我的既有歷史紀錄 資料完全沒看到
// 電流顯示在電池產品上啊」. The data was there (battery `ampere` is ~100% filled
// corpus-wide) and the gate allowed it. What stopped them was the card itself:
// it was titled "Voltage Trend", unconditionally, so it had already answered
// the question they came with. Nobody hunts for a control on a card that says
// the thing they want is not here.
//
// 🔴 AND IT GOT WORSE AFTER SWITCHING. The old 16 px toolbar toggle did change
// the axis — while the heading went on saying "Voltage Trend". Not merely hard
// to find: actively false.
//
// So these tests pin one property, from several sides: **the title names the
// series that is drawn, always** — and, where it cannot switch, it never
// pretends it can.
//
// CLEAN-ROOM: expectations derive from this project's own source and rulings.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/l10n/app_localizations_en.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/history/history_chart_core.dart';
import 'package:open_smart_batt/ui/history/history_query.dart';

void main() {
  final en = AppLocalizationsEn();

  group('the framing names the series — all four combinations', () {
    ({String heading, bool canSwitch}) f(
      HistoryRange range,
      HistoryChartSeries s,
    ) {
      final r = historyChartFraming(
        en,
        HistoryRangeSel.preset(range),
        deviceClass: ProductClass.smartBattery,
        series: s,
      );
      return (heading: r.heading, canSwitch: r.canSwitch);
    }

    test('today × voltage', () {
      expect(f(HistoryRange.today, HistoryChartSeries.voltage).heading,
          en.historyChartTodayTitle);
    });
    test('today × current', () {
      expect(f(HistoryRange.today, HistoryChartSeries.current).heading,
          en.historyChartTodayCurrentTitle);
    });
    test('multi-day × voltage', () {
      expect(f(HistoryRange.week, HistoryChartSeries.voltage).heading,
          en.historyChartTitle);
    });
    test('multi-day × current', () {
      expect(f(HistoryRange.week, HistoryChartSeries.current).heading,
          en.historyChartCurrentTitle);
    });

    test('🔴 the four strings are four DIFFERENT strings', () {
      // A composed title ("今日" + "電流趨勢") would pass every test above and
      // still be wrong in Chinese; four distinct constants is the ruling (Q2).
      final all = <String>{
        en.historyChartTitle,
        en.historyChartCurrentTitle,
        en.historyChartTodayTitle,
        en.historyChartTodayCurrentTitle,
      };
      expect(all.length, 4);
    });
  });

  group('a title can never name a series the card may not draw', () {
    for (final (label, cls) in <(String, ProductClass?)>[
      ('all devices', null),
      ('a super-capacitor', ProductClass.supercapacitor),
    ]) {
      test('$label: current is refused, and the title says voltage', () {
        final r = historyChartFraming(
          en,
          HistoryRangeSel.preset(HistoryRange.week),
          deviceClass: cls,
          // Ask for current anyway — a stale selection, or a class that
          // resolved late, can both do exactly this.
          series: HistoryChartSeries.current,
        );
        expect(r.canSwitch, isFalse);
        expect(r.series, HistoryChartSeries.voltage,
            reason: 'the effective series is forced back');
        expect(r.heading, en.historyChartTitle,
            reason: 'THE DEFECT, INVERTED — the heading follows the effective '
                'series, so it cannot advertise a current axis that is not '
                'being drawn');
      });
    }

    test('an unclassified single unit KEEPS current', () {
      // `unknown` is one unit whose family nobody recorded — not the
      // all-devices scope. FB-73 leaves real batteries sitting on `unknown`,
      // and refusing them would be the reported defect all over again.
      final r = historyChartFraming(
        en,
        HistoryRangeSel.preset(HistoryRange.week),
        deviceClass: ProductClass.unknown,
        series: HistoryChartSeries.current,
      );
      expect(r.canSwitch, isTrue);
      expect(r.heading, en.historyChartCurrentTitle);
    });
  });

  test('⛔ a caller that passes no class gets a title that cannot lie', () {
    // Defaults matter here: `deviceClass` defaults to null, which reads as the
    // all-devices scope. A surface added later that forgets to pass it gets
    // "voltage, no switch" — wrong, but not FALSE.
    final r = historyChartFraming(en, HistoryRangeSel.preset(HistoryRange.all));
    expect(r.canSwitch, isFalse);
    expect(r.series, HistoryChartSeries.voltage);
    expect(r.heading, en.historyChartTitle);
  });

  testWidgets('the heading is the switch, and it is not a 16 px icon',
      (t) async {
    // The whole of FB-103 in one assertion: what the user has to hit is the
    // biggest text on the card, not a grey glyph whose only explanation was a
    // tooltip (FB-70's failure mode, which this file's subject repeated).
    var series = HistoryChartSeries.voltage;
    await t.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: StatefulBuilder(builder: (context, setState) {
        final f = historyChartFraming(
          AppLocalizations.of(context),
          HistoryRangeSel.preset(HistoryRange.week),
          deviceClass: ProductClass.smartBattery,
          series: series,
        );
        return Scaffold(
          body: InkWell(
            onTap: f.canSwitch
                ? () => setState(() => series =
                    f.series == HistoryChartSeries.current
                        ? HistoryChartSeries.voltage
                        : HistoryChartSeries.current)
                : null,
            child: Text(f.heading),
          ),
        );
      }),
    ));

    expect(find.text(en.historyChartTitle), findsOneWidget);
    await t.tap(find.text(en.historyChartTitle));
    await t.pump();
    expect(find.text(en.historyChartCurrentTitle), findsOneWidget,
        reason: 'tapping the title switches the series AND renames the card');
    expect(find.text(en.historyChartTitle), findsNothing,
        reason: 'the old name must LEAVE — that is the half that was false');
  });
}
