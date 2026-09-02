// design 0093 — the live chart's full-screen shell.
//
// 🔴 The point of the file is that there is only ONE picture. The card and the
// landscape page draw through `live_trend_chart_core.dart`, and they must also
// AGREE ABOUT WHAT THE LINES ARE CALLED — a copy of the track list taken at push
// time would freeze a power bank's 輸入／輸出 legend against a flow that keeps
// moving. FB-74 / design 0065 §6 R5 is the standing rule: one unit drawn two
// ways is one unit nobody can check.
//
// What is pinned here, and why each one would otherwise be invisible:
//
//  * T1  both shells paint the same bytes from the same source;
//  * T2  the card STOPS ticking while the page covers it (a `Timer.periodic`
//        survives `TickerMode` and `Offstage`, so nothing else stops it);
//  * T3  a disconnect leaves a picture on screen — the buffer is cleared
//        unconditionally, so the page must already hold a copy;
//  * T4  and says when it stopped;
//  * T5  a reconnect DISCARDS that copy rather than extending it;
//  * T6  the entry is on the device page and not on the home grid, which is the
//        same widget at ~120 px;
//  * T7  the entry is 40x40, labelled, and drawn with the shared glyph;
//  * T8  landscape is locked on entry and released on exit;
//  * T9  the legends follow the flow, and freeze with the picture;
//  * T10 nothing says anything about a time window while the link is up.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/l10n/app_localizations_en.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/card_telemetry.dart';
import 'package:open_smart_batt/state/live_trend_buffer.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/dashboard_cards.dart';
import 'package:open_smart_batt/ui/dashboard/live_trend_chart.dart';
import 'package:open_smart_batt/ui/dashboard/live_trend_chart_page.dart';
import 'package:open_smart_batt/ui/dashboard/readouts_card.dart';

final _en = AppLocalizationsEn();

TelemetrySample _s(DateTime at,
        {double? pvlt, double? current, int? temp, double? svlt, int? soc}) =>
    TelemetrySample.empty().copyWith(
      timestamp: at,
      pvlt: pvlt,
      svlt: svlt,
      current: current,
      temperatureC: temp,
      socPercent: soc,
    );

/// Two minutes of a pack that crosses zero — the shape the buffer exists for.
LiveTrendBuffer _seeded({int n = 20, double sign = -1}) {
  final t0 = DateTime(2026, 9, 2, 14, 22, 5);
  final b = LiveTrendBuffer(capacity: 900);
  for (var i = 0; i < n; i++) {
    b.add(_s(t0.add(Duration(seconds: i)),
        pvlt: 13.2 + i * 0.01, current: sign * (4.0 + i * 0.3), temp: 30 + i));
  }
  return b;
}

StaticCardTelemetry _tele(LiveTrendBuffer b, {double? current, int? soc}) =>
    StaticCardTelemetry(
      sample: TelemetrySample.empty()
          .copyWith(current: current, socPercent: soc, svlt: 5.1),
      trend: b,
      tempUnit: TempUnit.celsius,
    );

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.dark(),
      home: home,
    );

/// The card as the device page builds it.
Widget _card(CardTelemetry tele, {CardSurface surface = CardSurface.deviceDetail}) =>
    Builder(
      builder: (context) => Scaffold(
        body: SingleChildScrollView(
          child: dashboardCardFor(
            context,
            DisplayModule.chart,
            shellClass: ProductClass.smartBattery,
            surface: surface,
            tele: tele,
          )!,
        ),
      ),
    );

List<TrendTrackPainter> _painters(WidgetTester t) => t
    .widgetList<CustomPaint>(find.byType(CustomPaint, skipOffstage: false))
    .map((w) => w.painter)
    .whereType<TrendTrackPainter>()
    .toList();

Future<Uint8List> _bytes(WidgetTester t, TrendTrackPainter p, Size size) async {
  late Uint8List out;
  await t.runAsync(() async {
    final rec = ui.PictureRecorder();
    p.paint(Canvas(rec), size);
    final img = await rec.endRecording().toImage(
        size.width.round(), size.height.round());
    out = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!
        .buffer
        .asUint8List();
    img.dispose();
  });
  return out;
}

void main() {
  const plot = Size(400, 120);

  testWidgets('T1 — both shells paint the same bytes from the same source',
      (t) async {
    final buf = _seeded();
    final tele = _tele(buf);

    await t.pumpWidget(_app(_card(tele)));
    await t.pump();
    final fromCard = _painters(t);
    expect(fromCard, isNotEmpty, reason: 'the card must draw through the core');
    final cardBytes = await _bytes(t, fromCard.first, plot);

    await t.pumpWidget(_app(
        LiveTrendChartPage(shellClass: ProductClass.smartBattery, tele: tele)));
    await t.pump(const Duration(milliseconds: 120));
    final fromPage = _painters(t);
    expect(fromPage, isNotEmpty);
    expect(fromPage.first.runtimeType, fromCard.first.runtimeType,
        reason: 'a second painter type IS the defect this file exists for');
    final pageBytes = await _bytes(t, fromPage.first, plot);

    expect(pageBytes, cardBytes,
        reason: 'same source, same track, same size ⇒ the same picture');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('T2 — the card stops ticking while the page covers it',
      (t) async {
    final buf = _seeded(n: 6);
    final tele = _tele(buf);
    await t.pumpWidget(_app(_card(tele)));
    await t.pump(const Duration(milliseconds: 120));
    // The latest PVLT is the card's own live readout, so it is the cheapest
    // observable proof that the ticker ran.
    expect(find.text('13.25 V', skipOffstage: false), findsOneWidget);

    final ctx = t.element(find.byType(Scaffold).first);
    unawaitedPush(ctx, tele);
    await t.pumpAndSettle();

    // 🔴 Scoped to the CARD. The page above it draws the same buffer, so an
    // unscoped `find.text` would be satisfied by the page's own header and this
    // test would pass no matter what the card did.
    Finder onCard(String v) => find.descendant(
        of: find.byType(TrendChartCard, skipOffstage: false),
        matching: find.text(v, skipOffstage: false));

    buf.add(_s(DateTime(2026, 9, 2, 14, 23), pvlt: 99.99, current: -1));
    await t.pump(const Duration(milliseconds: 300));
    expect(onCard('13.25 V'), findsOneWidget,
        reason: 'covered, the card must not have repainted');
    expect(onCard('99.99 V'), findsNothing);

    // ...and picks up again once it is the current route.
    Navigator.of(ctx).pop();
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 120));
    expect(onCard('99.99 V'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  group('the link goes away', () {
    testWidgets('T3/T4 — the picture stays, and says when it stopped',
        (t) async {
      final buf = _seeded();
      await t.pumpWidget(_app(LiveTrendChartPage(
          shellClass: ProductClass.smartBattery, tele: _tele(buf))));
      await t.pump(const Duration(milliseconds: 120));
      expect(_painters(t), isNotEmpty);

      // Exactly what `TelemetryController` does on `disconnected`.
      buf.clear();
      await t.pump(const Duration(milliseconds: 120));

      expect(buf.length, 0, reason: 'the source really is gone');
      expect(_painters(t), isNotEmpty,
          reason: 'the page must already have held a copy');
      expect(
          find.text(_en.liveChartFrozen('14:22:24'), skipOffstage: false),
          findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('T5 — a reconnect starts a new picture, it does not extend one',
        (t) async {
      final buf = _seeded(n: 10);
      await t.pumpWidget(_app(LiveTrendChartPage(
          shellClass: ProductClass.smartBattery, tele: _tele(buf))));
      await t.pump(const Duration(milliseconds: 120));
      buf.clear();
      await t.pump(const Duration(milliseconds: 120));
      expect(find.textContaining('frozen at', skipOffstage: false),
          findsOneWidget);

      for (var i = 0; i < 3; i++) {
        buf.add(_s(DateTime(2026, 9, 2, 15, i),
            pvlt: 12.0, current: -2, temp: 25));
      }
      await t.pump(const Duration(milliseconds: 120));
      await t.pump(const Duration(milliseconds: 120));

      expect(find.text(_en.liveChartRestarted, skipOffstage: false),
          findsOneWidget);
      expect(find.textContaining('frozen at', skipOffstage: false), findsNothing);
      final p = _painters(t);
      expect(p, isNotEmpty);
      expect(p.first.buffer.length, 3,
          reason: 'the ten points from before the drop must be gone, not joined');
      await t.pumpWidget(const SizedBox());
    });
  });

  testWidgets('T6 — the entry is on the device page, never on the home grid',
      (t) async {
    final tele = _tele(_seeded());
    await t.pumpWidget(_app(_card(tele)));
    await t.pump();
    expect(find.text(_en.liveChartExpand), findsOneWidget);

    await t.pumpWidget(_app(_card(tele, surface: CardSurface.home)));
    await t.pump();
    expect(find.text(_en.liveChartExpand), findsNothing,
        reason: 'a 1x1 tile is ~120 px wide — the width that struck once already');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('T7 — labelled, 40x40, and the same glyph as everywhere else',
      (t) async {
    await t.pumpWidget(_app(_card(_tele(_seeded()))));
    await t.pump();
    final btn = find.ancestor(
        of: find.text(_en.liveChartExpand), matching: find.byType(InkWell));
    expect(btn, findsOneWidget);
    final size = t.getSize(btn);
    expect(size.width, greaterThanOrEqualTo(40));
    expect(size.height, greaterThanOrEqualTo(40));
    expect(
        find.descendant(of: btn, matching: find.byIcon(Icons.fullscreen)),
        findsOneWidget);
    // FB-108's wording, pinned to the surface that already had it. Rewording one
    // of the two alone is the drift this assertion exists to catch.
    expect(_en.liveChartExpand, _en.historyChartExpand);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('T8 — landscape is locked on entry and released on exit',
      (t) async {
    final calls = <List<String>>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        calls.add(List<String>.from(call.arguments as List));
      }
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await t.pumpWidget(_app(LiveTrendChartPage(
        shellClass: ProductClass.smartBattery, tele: _tele(_seeded()))));
    await t.pump();
    expect(calls.single.every((o) => o.contains('landscape')), isTrue);

    await t.pumpWidget(const SizedBox());
    await t.pump();
    expect(calls.length, 2);
    expect(calls.last.every((o) => o.contains('portrait')), isTrue);
  });

  group('T9 — the legends follow the flow, then freeze with the picture', () {
    testWidgets('a power bank names its rail from the CURRENT sample',
        (t) async {
      final buf = LiveTrendBuffer(capacity: 90);
      final t0 = DateTime(2026, 9, 2, 14, 0);
      for (var i = 0; i < 6; i++) {
        buf.add(_s(t0.add(Duration(seconds: i)),
            svlt: 5.0 + i * 0.01, current: 1.0, soc: 60 + i));
      }
      Future<void> open(double current) => t.pumpWidget(_app(Builder(
            builder: (c) => Scaffold(
              body: SingleChildScrollView(
                child: dashboardCardFor(c, DisplayModule.chart,
                    shellClass: ProductClass.powerBank,
                    surface: CardSurface.deviceDetail,
                    tele: _tele(buf, current: current, soc: 61))!,
              ),
            ),
          )));

      // Positive is DISCHARGING on a power bank (0x4A − 0x49).
      await open(1.2);
      await t.pump();
      expect(find.text(_en.powerBankTrackOutput), findsOneWidget);

      await open(-1.2);
      await t.pump();
      expect(find.text(_en.powerBankTrackInput), findsOneWidget,
          reason: 'the legend is derived per build, not captured once');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('and the frozen page keeps the legends it had', (t) async {
      final buf = LiveTrendBuffer(capacity: 90);
      final t0 = DateTime(2026, 9, 2, 14, 0);
      for (var i = 0; i < 6; i++) {
        buf.add(_s(t0.add(Duration(seconds: i)),
            svlt: 5.0 + i * 0.01, current: 1.0, soc: 60 + i));
      }
      await t.pumpWidget(_app(LiveTrendChartPage(
          shellClass: ProductClass.powerBank,
          tele: _tele(buf, current: 1.2, soc: 61))));
      await t.pump(const Duration(milliseconds: 120));
      expect(find.text(_en.powerBankTrackOutput, skipOffstage: false),
          findsOneWidget);

      buf.clear();
      await t.pump(const Duration(milliseconds: 120));
      expect(find.text(_en.powerBankTrackOutput, skipOffstage: false),
          findsOneWidget,
          reason: 'a frozen chart labelled 輸入 would be a fresh lie');
      await t.pumpWidget(const SizedBox());
    });
  });

  testWidgets('T10 — while the link is up the page says nothing about a window',
      (t) async {
    await t.pumpWidget(_app(LiveTrendChartPage(
        shellClass: ProductClass.smartBattery, tele: _tele(_seeded()))));
    await t.pump(const Duration(milliseconds: 120));
    // Q1 = NO. No range, no bucket note, no "3 minutes".
    expect(find.textContaining('–', skipOffstage: false), findsNothing);
    expect(find.textContaining('frozen', skipOffstage: false), findsNothing);
    expect(find.text(_en.liveChartRestarted, skipOffstage: false), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  group('Q3 — full screen divides the height, it does not stack fixed bands',
      () {
    test('the relative weights travel; equal shares would flatten the tall one',
        () {
      final w = trackFlexWeights([
        const TrendTrack(
            field: TrendField.current,
            label: 'I',
            unit: 'A',
            color: Color(0xFF000000),
            height: 92),
        const TrendTrack(
            field: TrendField.pvlt,
            label: 'V',
            unit: 'V',
            color: Color(0xFF000000)),
        const TrendTrack(
            field: TrendField.temperature,
            label: 'T',
            unit: 'C',
            color: Color(0xFF000000)),
      ]);
      expect(w, [92, 74, 74],
          reason: 'the current track is taller because it crosses zero');
      expect(trackFlexWeights(const []), isEmpty);
    });

    testWidgets('full screen the plots FLEX; on a card they do not', (t) async {
      final tele = _tele(_seeded());
      await t.pumpWidget(_app(LiveTrendChartPage(
          shellClass: ProductClass.smartBattery, tele: tele)));
      await t.pump(const Duration(milliseconds: 120));
      expect(find.byType(Expanded, skipOffstage: false), findsWidgets);
      // 🔴 The band that overflowed the first implementation by 16 px. Nothing
      // here predicts the chrome any more, so there is nothing to be wrong by.
      expect(t.takeException(), isNull);

      await t.pumpWidget(_app(_card(tele)));
      await t.pump();
      final heights = t
          .widgetList<SizedBox>(find.ancestor(
              of: find.byType(CustomPaint, skipOffstage: false),
              matching: find.byType(SizedBox, skipOffstage: false)))
          .map((b) => b.height)
          .whereType<double>()
          .toSet();
      expect(heights.contains(92) || heights.contains(74), isTrue,
          reason: 'a card still uses the track\'s own height');
      await t.pumpWidget(const SizedBox());
    });
  });
}

/// Push the page the way the card's button does, without awaiting it.
void unawaitedPush(BuildContext context, CardTelemetry tele) {
  showLiveTrendChartPage(context,
      shellClass: ProductClass.smartBattery, tele: tele);
}
