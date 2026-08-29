// FB-101 / design 0085 S3 — who is allowed a current series, and in whose
// vocabulary.
//
// S2 shipped the mechanism with the chart unable to see a [ProductClass]: one
// hard-coded pack wording, and no way to refuse. S3 threads the class through,
// and the three things that changes are all failures that draw a perfectly
// ordinary-looking picture when they go wrong:
//
//  1. **Super-capacitor** — `0x2E` is pinned at `0.0 A` on a unit that cannot
//     measure current (§1.5). Drawn, it is a flat line on the zero rule, which
//     reads as "measured, and it is zero". Three other surfaces already refuse
//     it (the list row, the CSV column, the live track); this is the fourth.
//  2. **「全部裝置」** — `queryBuckets` groups by TIME, never by `device_id`,
//     and the two families sign current the OPPOSITE way round (§1.6). A
//     battery discharging at −3 A and a power bank discharging at +3 A average
//     to 0 A and are drawn as a unit at rest. ⛔ That is not an error bar; it
//     is two contradictory conventions added together, and Q4 ③ ruled it must
//     be refused **and explained**.
//  3. **A power bank labelled with the pack key** — `0x4A − 0x49` is positive
//     while DIScharging (`power_flow.dart`: "THE SIGN IS THE OPPOSITE"), so the
//     pack wording would call every charge a discharge, on a curve that is
//     otherwise correct.
//
// 🔴 And one thing S3 must not undo: **the min–max band in current mode**.
// With Q2 ① / Q3 ruling out the "these are averages" sentence, §3.3 leaves the
// band as the feature's only honesty mechanism and §9 item 10 makes it a
// shipping gate. It is re-pinned here THROUGH THE WIDGET, because S2 pinned it
// through the painter and S3 is the layer that could switch it off.
import 'dart:ui' as ui;

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
  final t0 = DateTime(2026, 8, 27, 10, 0);

  /// Six minutes of a unit crossing zero, with a real min–max spread so the
  /// band has something to draw.
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

  const stats = HistoryStats.empty;

  Widget host(ProductClass? cls, {List<HistoryBucket>? buckets}) => MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SingleChildScrollView(
            // 🔵 design 0089 — heading above, controlled card below, exactly
            // as production arranges them. The switch is the heading.
            child: SeriesHost(
              cls: cls,
              child: (series, onChanged) => HistoryTrendCard(
                buckets: buckets ?? run(),
                stats: stats,
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

  // 🔵 design 0089 — the ⇅ now sits in the heading's trailing slot, and the
  // whole heading row is the button. Present ⇒ switchable; absent ⇒ not.
  final toggle = seriesToggle();

  HistoryTrendPainter painterOf(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((c) => c.painter)
      .whereType<HistoryTrendPainter>()
      .single;

  // =========================================================================
  // The gate itself — one function, three answers, and null is not `unknown`.
  // =========================================================================

  group('historyChartCurrentGate', () {
    test('a null class is the ALL-DEVICES scope, not an unknown unit', () {
      // 🔴 The distinction the whole ruling rests on. `deviceClassFor` answers
      // `unknown` for a null id, which downstream means "one unit, family not
      // recorded" — a case where current IS drawn. Collapsing the two is how
      // the mixed-family average gets plotted.
      expect(historyChartCurrentGate(null),
          HistoryChartCurrentGate.mixedScope);
      expect(historyChartCurrentGate(ProductClass.unknown),
          HistoryChartCurrentGate.available);
    });

    test('a super-capacitor is refused', () {
      expect(historyChartCurrentGate(ProductClass.supercapacitor),
          HistoryChartCurrentGate.capacitor);
    });

    test('both measuring families are allowed', () {
      expect(historyChartCurrentGate(ProductClass.smartBattery),
          HistoryChartCurrentGate.available);
      expect(historyChartCurrentGate(ProductClass.powerBank),
          HistoryChartCurrentGate.available);
    });
  });

  group('the refusal says WHY, and the two reasons are different', () {
    test('the capacitor note is the EXISTING string, not a new one', () {
      // §0.3: the capacitor sentence is reused, not coined. If this ever stops
      // matching, the live chart and the history chart have started explaining
      // the same silence in two ways.
      expect(
        historyChartCurrentGateNote(en, HistoryChartCurrentGate.capacitor),
        en.capacitorChartNoCurrentNote,
      );
    });

    test('the all-devices note blames the SCOPE, not missing data', () {
      final note =
          historyChartCurrentGateNote(en, HistoryChartCurrentGate.mixedScope)!;
      expect(note, en.historyChartAllDevicesNoCurrentNote);
      // 🔴 "No current data" would be a second falsehood on top of the one
      // being avoided — it claims nothing was measured. The sentence has to
      // point at the scope and offer the way out.
      expect(note.toLowerCase(), contains('all devices'));
      expect(note.toLowerCase(), contains('opposite'));
      expect(note.toLowerCase(), contains('one device'));
    });

    test('the two refusals are not the same sentence', () {
      expect(
        historyChartCurrentGateNote(en, HistoryChartCurrentGate.capacitor),
        isNot(historyChartCurrentGateNote(
            en, HistoryChartCurrentGate.mixedScope)),
      );
    });

    test('nothing is said when there is nothing to explain', () {
      expect(historyChartCurrentGateNote(en, HistoryChartCurrentGate.available),
          isNull);
    });

    test('⛔ neither refusal mentions averaging (Q2① / Q3 ruled it out)', () {
      // §0.3's third row. The "history rows are averages" sentence was ruled
      // NOT to ship in this design; the min–max band carries it instead. A
      // helpful-looking addition here would quietly re-open a closed ruling.
      for (final g in HistoryChartCurrentGate.values) {
        final n = historyChartCurrentGateNote(en, g)?.toLowerCase() ?? '';
        expect(n, isNot(contains('average')));
        expect(n, isNot(contains('mean')));
      }
    });
  });

  // =========================================================================
  // Direction — two families, two opposite keys.
  // =========================================================================

  group('the direction key is per family and the families are opposite', () {
    test('a pack gets the pack key', () {
      for (final cls in [
        ProductClass.smartBattery,
        ProductClass.supercapacitor,
      ]) {
        expect(historyChartCurrentDirectionLabel(en, cls),
            en.dashboardTrackCurrentDirectionKey);
      }
    });

    test('a power bank gets its OWN key, and it is the mirror image', () {
      final pack = historyChartCurrentDirectionLabel(
          en, ProductClass.smartBattery)!;
      final bank =
          historyChartCurrentDirectionLabel(en, ProductClass.powerBank)!;
      expect(bank, en.powerBankTrackCurrentDirectionKey);
      expect(bank, isNot(pack));
      // 🔴 Not merely "different" — OPPOSITE. `0x2E` = 512 − u16 signs a charge
      // positive; `0x4A − 0x49` signs a DISCHARGE positive. Reusing the pack
      // key would label every power-bank charge as a discharge.
      expect(pack, startsWith('+ charge'));
      expect(bank, startsWith('+ discharge'));
    });

    test('an unclassified unit is left UNLABELLED, not defaulted to pack', () {
      // A default would be a guess, and on a misfiled power bank it is a
      // backwards guess (FB-43's shape). The list row does the same thing: a
      // signed number with no direction word.
      expect(historyChartCurrentDirectionLabel(en, ProductClass.unknown),
          isNull);
      expect(historyChartCurrentDirectionLabel(en, null), isNull);
    });
  });

  // =========================================================================
  // The card.
  // =========================================================================

  group('a battery can switch, and switching switches everything', () {
    testWidgets('the toggle is live and the legend follows it', (t) async {
      await t.pumpWidget(host(ProductClass.smartBattery));
      await t.pump();

      expect(toggle, findsOneWidget,
          reason: 'design 0089 — a switchable card shows the ⇅ beside its title');
      expect(painterOf(t).series, HistoryChartSeries.voltage);
      expect(find.text(en.historyLegendCurrent), findsNothing);
      // Two "Voltage"s to start with: the chart legend and the stats strip's
      // own row.
      //
      // ~~⚠️ **The strip is deliberately NOT switched** — it is a range-wide
      // aggregate of voltage and temperature that predates this design (design
      // 0085 §5 lists the chart and nothing else), and it names its own
      // quantity, so the two cannot be confused.~~
      //
      // 🔴 **OVERRULED — design 0085 S4** (owner, 2026-08-27, verbatim
      // 「應該要跟著切」). The sentence above was wrong about the consequence:
      // the strip naming its own quantity did NOT stop the two being confused,
      // it produced `Voltage 12.98 / 13.20 / 13.31` printed under a current
      // curve, which reads as the chart's own numbers. Both now switch
      // together, so this expectation is TIGHTENED rather than adjusted:
      // afterwards the word Voltage must be gone from the card ENTIRELY, and
      // Current must appear in both places.
      expect(find.text(en.historyLegendVoltage), findsNWidgets(2));

      await t.tap(toggle);
      await t.pump();

      // 🔴 The legend is the only thing on screen saying which quantity the
      // amber line is — current REUSES voltage's colour (案 B).
      expect(find.text(en.historyLegendCurrent), findsNWidgets(2),
          reason: 'chart legend + stats strip row (S4)');
      expect(find.text(en.historyLegendVoltage), findsNothing,
          reason: 'nothing on the card may still say Voltage once the left '
              'axis has left it');
      expect(painterOf(t).series, HistoryChartSeries.current);
      expect(painterOf(t).currentDirectionLabel,
          en.dashboardTrackCurrentDirectionKey);

      await t.tap(toggle);
      await t.pump();
      expect(painterOf(t).series, HistoryChartSeries.voltage);
      // ⛔ The key must not linger under a voltage axis it does not describe.
      expect(painterOf(t).currentDirectionLabel, isNull);
    });

    testWidgets('a power bank is labelled in its own vocabulary', (t) async {
      await t.pumpWidget(host(ProductClass.powerBank));
      await t.pump();
      await t.tap(toggle);
      await t.pump();

      expect(painterOf(t).currentDirectionLabel,
          en.powerBankTrackCurrentDirectionKey);
      expect(painterOf(t).currentDirectionLabel,
          isNot(en.dashboardTrackCurrentDirectionKey));
    });

    testWidgets('nothing is explained away when there is nothing wrong',
        (t) async {
      await t.pumpWidget(host(ProductClass.smartBattery));
      await t.pump();
      expect(find.text(en.capacitorChartNoCurrentNote), findsNothing);
      expect(
          find.text(en.historyChartAllDevicesNoCurrentNote), findsNothing);
    });
  });

  // =========================================================================
  // 🔴 §9 item 10 — SHIPPING GATE. Re-pinned at the widget layer.
  // =========================================================================

  group('🔴 SHIPPING GATE (§9 item 10): the band is there in current mode', () {
    testWidgets('the card draws a filled min–max band once switched',
        (t) async {
      await t.pumpWidget(host(ProductClass.smartBattery));
      await t.pump();
      await t.tap(toggle);
      await t.pump();

      final p = painterOf(t);
      expect(p.series, HistoryChartSeries.current);

      final rec = _Recording();
      p.paint(rec, const Size(320, 160));
      final fills = rec.paths
          .where((e) =>
              e.$2.style == PaintingStyle.fill && _sameHue(e.$2.color, p.vColor))
          .toList();
      expect(fills, isNotEmpty,
          reason: 'design 0085 §3.3 — Q2① / Q3 ruled out the "these are '
              'averages" sentence, so the band is the ONLY thing left saying '
              'the line is a mean. §9 item 10: no band, no ship.');
      expect(fills.first.$1.getBounds().height, greaterThan(0),
          reason: 'a zero-height band shows no spread at all');
    });

    testWidgets('and the band is not something the user can turn off',
        (t) async {
      // There is no setting for it and no branch that drops it: the count is
      // the same in both modes, which is the structural version of the claim.
      await t.pumpWidget(host(ProductClass.smartBattery));
      await t.pump();
      int fillsNow() {
        final p = painterOf(t);
        final rec = _Recording();
        p.paint(rec, const Size(320, 160));
        return rec.paths
            .where((e) =>
                e.$2.style == PaintingStyle.fill &&
                _sameHue(e.$2.color, p.vColor))
            .length;
      }

      final volts = fillsNow();
      await t.tap(toggle);
      await t.pump();
      expect(fillsNow(), volts);
      expect(volts, greaterThan(0));
    });
  });

  // =========================================================================
  // The two refusals, through the widget.
  // =========================================================================

  group('a super-capacitor is refused, out loud', () {
    testWidgets('the toggle is disabled and the reason is on screen',
        (t) async {
      await t.pumpWidget(host(ProductClass.supercapacitor));
      await t.pump();

      // 🔵 design 0089 §3.1 — the shape changed on 2026-08-29. It used to be
      // "disabled, not hidden"; the switch is the TITLE now, and a greyed-out
      // title reads as broken rather than as unavailable (FB-64). What 0085
      // §3.4 actually protects — the reason being on screen — is unchanged,
      // and asserted on the next line.
      expect(toggle, findsNothing,
          reason: 'design 0089 §3.1 — the ⇅ is absent, not greyed: the '
              'EXPLANATION does not go with it (the note below the plot is '
              'independent), so 0085 §3.4 is still satisfied, while a '
              'greyed-out TITLE would just read as broken (FB-64)');
      expect(find.text(en.capacitorChartNoCurrentNote), findsOneWidget);
    });

    testWidgets('the current series is ABSENT — not a flat line at zero',
        (t) async {
      await t.pumpWidget(host(ProductClass.supercapacitor));
      await t.pump();

      final p = painterOf(t);
      expect(p.series, HistoryChartSeries.voltage);
      expect(p.currentDirectionLabel, isNull);

      // The zero rule is drawn in current mode only, so its absence is the
      // observable form of "no current series was plotted". A flat line on it
      // would read as a measured zero — the exact claim `0x2E` cannot support
      // on this family.
      final rec = _Recording();
      p.paint(rec, const Size(320, 160));
      expect(_zeroLines(rec, p.vColor), isEmpty);
    });

    testWidgets('there is nothing to tap, and tapping the title does nothing',
        (t) async {
      await t.pumpWidget(host(ProductClass.supercapacitor));
      await t.pump();
      // 🔵 design 0089 — the old test tapped a dead IconButton. There is no
      // such button now; the equivalent is that the TITLE is inert.
      expect(toggle, findsNothing);
      await t.tap(chartHeading(), warnIfMissed: false);
      await t.pump();
      expect(painterOf(t).series, HistoryChartSeries.voltage,
          reason: 'the refusal has to survive a tap on the title, not merely '
              'be the opening state');
      expect(find.text(en.historyChartTodayCurrentTitle.toUpperCase()),
          findsNothing,
          reason: 'and the title must never name a series the card cannot draw');
    });
  });

  group('「全部裝置」 is refused, and the sentence blames the scope', () {
    testWidgets('the toggle is disabled and the note explains the scope',
        (t) async {
      await t.pumpWidget(host(null));
      await t.pump();

      expect(toggle, findsNothing,
          reason: 'design 0089 §3.1 — the ⇅ is absent, not greyed: the '
              'EXPLANATION does not go with it (the note below the plot is '
              'independent), so 0085 §3.4 is still satisfied, while a '
              'greyed-out TITLE would just read as broken (FB-64)');
      expect(find.text(en.historyChartAllDevicesNoCurrentNote), findsOneWidget);
      // ⛔ It must not borrow the capacitor's sentence: this scope's units may
      // measure current perfectly well.
      expect(find.text(en.capacitorChartNoCurrentNote), findsNothing);
    });

    testWidgets('⛔ no mixed-family average ever reaches the canvas', (t) async {
      // The failure being prevented, spelled out: a battery discharging at
      // −3 A and a power bank discharging at +3 A land in one time bucket
      // (`GROUP BY` has no `device_id`) and average to 0 A. Plotted, that is a
      // unit sitting at rest — a picture with no defect visible in it.
      await t.pumpWidget(host(null, buckets: [
        for (var i = 0; i < 6; i++)
          HistoryBucket(
            at: t0.add(Duration(minutes: i)),
            avgPvlt: 13.0,
            minPvlt: 12.9,
            maxPvlt: 13.1,
            avgAmpere: 0.0,
            minAmpere: -3.0,
            maxAmpere: 3.0,
            count: 120,
          ),
      ]));
      await t.pump();
      // Including when the user tries: the refusal has to survive the tap, not
      // merely be the opening state.
      expect(toggle, findsNothing,
          reason: 'design 0089 §3.1 — the ⇅ is absent, not greyed: the '
              'EXPLANATION does not go with it (the note below the plot is '
              'independent), so 0085 §3.4 is still satisfied, while a '
              'greyed-out TITLE would just read as broken (FB-64)');
      await t.tap(chartHeading(), warnIfMissed: false);
      await t.pump();

      final p = painterOf(t);
      expect(p.series, HistoryChartSeries.voltage);
      final rec = _Recording();
      p.paint(rec, const Size(320, 160));
      expect(_zeroLines(rec, p.vColor), isEmpty,
          reason: 'no current axis may be drawn for a multi-unit scope');
    });
  });

  // =========================================================================
  // A class that arrives late.
  // =========================================================================

  testWidgets('a class resolving mid-view drops a series it may no longer draw',
      (t) async {
    // `deviceClassFor` resolves through saved record → cached facts → live
    // link, so a unit really can go from `unknown` to `supercapacitor` while
    // this card is on screen.
    await t.pumpWidget(host(ProductClass.unknown));
    await t.pump();
    await t.tap(toggle);
    await t.pump();
    expect(painterOf(t).series, HistoryChartSeries.current);
    // An unclassified unit is drawn, but unlabelled — no family, no convention.
    expect(painterOf(t).currentDirectionLabel, isNull);

    await t.pumpWidget(host(ProductClass.supercapacitor));
    await t.pump();

    expect(painterOf(t).series, HistoryChartSeries.voltage);
    expect(toggle, findsNothing,
          reason: 'design 0089 §3.1 — the ⇅ is absent, not greyed: the '
              'EXPLANATION does not go with it (the note below the plot is '
              'independent), so 0085 §3.4 is still satisfied, while a '
              'greyed-out TITLE would just read as broken (FB-64)');
    expect(find.text(en.capacitorChartNoCurrentNote), findsOneWidget);
  });
}

Iterable<(Offset, Offset, Paint)> _zeroLines(_Recording r, Color v) =>
    r.lines.where((l) =>
        (l.$1.dy - l.$2.dy).abs() < 1e-9 &&
        _sameHue(l.$3.color, v) &&
        l.$3.color.a < 0.99);

/// Same hue, ignoring the alpha the band and the zero line apply.
bool _sameHue(Color a, Color b) =>
    (a.r - b.r).abs() < 1e-6 &&
    (a.g - b.g).abs() < 1e-6 &&
    (a.b - b.b).abs() < 1e-6;

/// A [Canvas] that keeps what it was asked to draw — same recorder as
/// `history_chart_current_series_test.dart`.
class _Recording implements Canvas {
  final List<(Path, Paint)> paths = <(Path, Paint)>[];
  final List<(Offset, Offset, Paint)> lines = <(Offset, Offset, Paint)>[];

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
