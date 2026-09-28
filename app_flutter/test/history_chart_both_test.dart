// design 0096 — voltage and current on one history chart (案 D).
//
// Owner, 2026-09-29: 「照建議，把電壓電流改為預設第一個」 ⇒ voltage on the LEFT,
// current on the RIGHT (borrowing temperature's axis and colour), temperature
// not drawn; this view is the default and first in the switch's cycle.
//
// What is pinned here is what would fail silently — a chart that still draws
// and looks ordinary, and is wrong:
//  T1  the gate still wins: capacitor / all-devices never get `both`;
//  T2+T3  the right axis carries CURRENT, not temperature, and the temperature
//      line is gone (a temperature curve drawn in current's colour against an
//      ampere axis would look perfectly plausible);
//  T4  the right gutter opens for current even on a unit with no temperature;
//  T6  the cycle order;
//  T7  the zero line sits at the RIGHT axis's zero, in current's colour.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/l10n/app_localizations_en.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';

void main() {
  const size = Size(320, 160);
  const plotTop = 8.0, plotH = 160.0 - 8 - 18;
  final t0 = DateTime(2026, 9, 29, 9, 0);
  final vColor = AccentTheme.amber.accent;
  final tColor = AccentTheme.amber.accentSecondary;
  final en = AppLocalizationsEn();

  /// 11 minutes: current FALLS 5 → −5 A while temperature RISES 28 → 38 °C,
  /// so a stroke in [tColor] tells by its direction which quantity it is.
  List<HistoryBucket> run({bool withTemp = true}) => [
        for (var i = 0; i < 11; i++)
          HistoryBucket(
            at: t0.add(Duration(minutes: i)),
            avgPvlt: 13.2,
            minPvlt: 13.1,
            maxPvlt: 13.3,
            avgTemp: withTemp ? 28 + i.toDouble() : null,
            minTemp: withTemp ? 27 + i.toDouble() : null,
            maxTemp: withTemp ? 29 + i.toDouble() : null,
            avgAmpere: 5 - i.toDouble(),
            minAmpere: 4.5 - i.toDouble(),
            maxAmpere: 5.5 - i.toDouble(),
            count: 60,
          ),
      ];

  _Recording paint(List<HistoryBucket> b,
      {HistoryChartSeries series = HistoryChartSeries.both,
      bool hasTemp = true,
      String? direction}) {
    final c = _Recording();
    historyTrendPainterForTest(
      buckets: b,
      hasTemp: hasTemp,
      series: series,
      currentDirectionLabel: direction,
    ).paint(c, size);
    return c;
  }

  bool same(Color a, Color b) => a.toARGB32() == b.toARGB32();
  Iterable<Path> strokes(_Recording r, Color c) => r.paths
      .where((p) => p.$2.style == PaintingStyle.stroke && same(p.$2.color, c))
      .map((p) => p.$1);

  /// y at the start and end of [p].
  (double, double) ends(Path p) {
    final m = p.computeMetrics().first;
    return (
      m.getTangentForOffset(0)!.position.dy,
      m.getTangentForOffset(m.length)!.position.dy,
    );
  }

  group('T2/T3 the right axis is current, and temperature is not drawn', () {
    test('the one secondary-colour stroke FALLS (current), not rises (temp)',
        () {
      final s = strokes(paint(run()), tColor).toList();
      expect(s, hasLength(1), reason: 'current only — no temperature line');
      final (y0, y1) = ends(s.single);
      expect(y1, greaterThan(y0),
          reason: 'screen y grows downward: a falling current moves DOWN');
    });

    test('control: in voltage mode that stroke is temperature and rises', () {
      final s = strokes(
              paint(run(), series: HistoryChartSeries.voltage), tColor)
          .toList();
      expect(s, hasLength(1));
      final (y0, y1) = ends(s.single);
      expect(y1, lessThan(y0));
    });

    test('voltage stays on the left in both', () {
      expect(strokes(paint(run()), vColor), hasLength(1));
    });

    test('current keeps its min–max band (Q4 a)', () {
      final fills = paint(run()).paths.where((p) =>
          p.$2.style == PaintingStyle.fill &&
          (p.$2.color.a - 0.22).abs() < 0.01 &&
          same(p.$2.color.withValues(alpha: 1), tColor));
      expect(fills, isNotEmpty);
    });
  });

  group('T7 the zero line', () {
    Iterable<(Offset, Offset, Paint)> zeroLines(_Recording r, Color c) =>
        r.lines.where((l) =>
            (l.$1.dy - l.$2.dy).abs() < 1e-9 &&
            (l.$3.color.a - 0.55).abs() < 0.01 &&
            same(l.$3.color.withValues(alpha: 1), c));

    test('sits at the RIGHT axis zero, in current\'s colour', () {
      final z = zeroLines(paint(run()), tColor).toList();
      expect(z, hasLength(1));
      // Window −5.5…5.5 ⇒ zero is the middle of the plot.
      expect(z.single.$1.dy, closeTo(plotTop + plotH / 2, 0.01));
      expect(zeroLines(paint(run()), vColor), isEmpty,
          reason: 'not the left axis\'s 0 V, which is off the plot');
    });

    test('absent in voltage mode', () {
      final r = paint(run(), series: HistoryChartSeries.voltage);
      expect(zeroLines(r, tColor), isEmpty);
      expect(zeroLines(r, vColor), isEmpty);
    });
  });

  group('T4 the right gutter', () {
    double rightEdge(_Recording r) => r.horizontals
        .map((l) => l.$2.dx)
        .reduce((a, b) => a > b ? a : b);

    test('opens for current even when the unit has no temperature', () {
      final b = run(withTemp: false);
      expect(rightEdge(paint(b, hasTemp: false)),
          closeTo(size.width - 40, 1e-9));
      expect(
          rightEdge(paint(b,
              hasTemp: false, series: HistoryChartSeries.voltage)),
          closeTo(size.width - 8, 1e-9));
    });

    test('the tap geometry uses the same formula', () {
      expect(
          HistoryChartGeometry.hasRightAxis(
              hasTemp: false, series: HistoryChartSeries.both),
          isTrue);
      expect(
          HistoryChartGeometry.hasRightAxis(
              hasTemp: false, series: HistoryChartSeries.current),
          isFalse);
    });
  });

  test('T6 the cycle: both → voltage → current → both', () {
    var s = HistoryChartSeries.both;
    final seen = <HistoryChartSeries>[];
    for (var i = 0; i < 3; i++) {
      s = nextHistoryChartSeries(s);
      seen.add(s);
    }
    expect(seen, [
      HistoryChartSeries.voltage,
      HistoryChartSeries.current,
      HistoryChartSeries.both,
    ]);
  });

  group('T1 framing: the gate wins, and the title names both (Q2)', () {
    final week = HistoryRangeSel.preset(HistoryRange.week);
    final today = HistoryRangeSel.preset(HistoryRange.today);

    test('battery: both is kept and titled as both', () {
      final r = historyChartFraming(en, week,
          deviceClass: ProductClass.smartBattery,
          series: HistoryChartSeries.both);
      expect(r.series, HistoryChartSeries.both);
      expect(r.heading, en.historyChartBothTitle);
      expect(
          historyChartFraming(en, today,
                  deviceClass: ProductClass.smartBattery,
                  series: HistoryChartSeries.both)
              .heading,
          en.historyChartTodayBothTitle);
    });

    for (final cls in [ProductClass.supercapacitor, null]) {
      test('$cls: both is refused → voltage', () {
        final r = historyChartFraming(en, week,
            deviceClass: cls, series: HistoryChartSeries.both);
        expect(r.canSwitch, isFalse);
        expect(r.series, HistoryChartSeries.voltage);
        expect(r.heading, en.historyChartTitle);
      });
    }
  });

  group('T3/T5 the card in the combined view', () {
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

    Widget host(HistoryChartSeries series) => MaterialApp(
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
                deviceClass: ProductClass.smartBattery,
                series: series,
                onSeriesChanged: (_) {},
              ),
            ),
          ),
        );

    testWidgets('legend names current, not temperature; stats keep all three',
        (t) async {
      await t.pumpWidget(host(HistoryChartSeries.both));
      // Legend + stats row each.
      expect(find.text(en.historyLegendVoltage), findsNWidgets(2));
      expect(find.text(en.historyLegendCurrent), findsNWidgets(2));
      // 🔴 Stats row ONLY — a legend entry would label the cyan line
      // "Temperature" while it plots amperes.
      expect(find.text(en.historyLegendTemperature), findsOneWidget);
      expect(find.text('-4.2A'), findsOneWidget);
      expect(find.text('12.98V'), findsOneWidget);
      expect(find.text('24°C'), findsOneWidget);
    });

    testWidgets('control: voltage mode keeps the temperature legend',
        (t) async {
      await t.pumpWidget(host(HistoryChartSeries.voltage));
      expect(find.text(en.historyLegendTemperature), findsNWidgets(2));
      expect(find.text(en.historyLegendCurrent), findsNothing);
    });

    testWidgets('T5 a tapped point reads voltage, current AND temperature',
        (t) async {
      await t.pumpWidget(host(HistoryChartSeries.both));
      await t.tapAt(t.getCenter(find.byType(CustomPaint).last));
      await t.pump();
      final detail = find.byWidgetPredicate((w) =>
          w is Text &&
          (w.data ?? '').contains('${en.historyLegendVoltage} ') &&
          (w.data ?? '').contains('${en.historyLegendCurrent} ') &&
          (w.data ?? '').contains(en.historyLegendTemperature));
      expect(detail, findsOneWidget);
    });
  });
}

class _Recording implements Canvas {
  final List<(Path, Paint)> paths = <(Path, Paint)>[];
  final List<(Offset, Offset, Paint)> lines = <(Offset, Offset, Paint)>[];

  Iterable<(Offset, Offset, Paint)> get horizontals =>
      lines.where((l) => (l.$1.dy - l.$2.dy).abs() < 1e-9);

  @override
  void drawPath(Path path, Paint paint) => paths.add((path, paint));

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      lines.add((p1, p2, paint));

  @override
  void drawCircle(Offset c, double radius, Paint paint) {}

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
