// Live trend buffer + the dashboard's chart mode (design 0030 Phase 0).
//
// The buffer exists because stored history keeps one AVERAGED row per minute,
// and the events users ask about are seconds long. The anchor is a real
// capture: in 2026.08.03/001 the current swung between -29 A and +8 A inside
// one minute, and the row written for that minute reads -0.31 A. Anything here
// that quietly flattens or drops a sample puts that number back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/live_trend_buffer.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/live_trend_chart.dart';
import 'package:open_smart_batt/ui/dashboard/readout_grid.dart';
import 'package:open_smart_batt/ui/dashboard/readouts_card.dart';

TelemetrySample _s(DateTime at, {double? pvlt, double? current, int? temp}) =>
    TelemetrySample.empty().copyWith(
        timestamp: at, pvlt: pvlt, current: current, temperatureC: temp);

Widget _host(Widget child) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  final t0 = DateTime.utc(2026, 8, 3, 18, 21, 54);

  group('LiveTrendBuffer', () {
    test('keeps the newest entries once full, oldest first', () {
      final b = LiveTrendBuffer(capacity: 3);
      for (var i = 0; i < 5; i++) {
        b.add(_s(t0.add(Duration(seconds: i)), pvlt: 13.0 + i));
      }
      expect(b.length, 3);
      expect(
        [for (var i = 0; i < b.length; i++) b.valueAt(TrendField.pvlt, i)],
        [closeTo(15.0, 1e-6), closeTo(16.0, 1e-6), closeTo(17.0, 1e-6)],
        reason: 'the ring must read oldest-first after wrapping',
      );
      expect(b.timeAt(0), t0.add(const Duration(seconds: 2))
          .millisecondsSinceEpoch.toDouble());
    });

    test('a negative current survives — it is the whole point', () {
      final b = LiveTrendBuffer(capacity: 8);
      for (final a in [0.0, -29.0, -12.0, 8.0]) {
        b.add(_s(t0, current: a));
      }
      final r = b.rangeOf(TrendField.current)!;
      expect(r.min, closeTo(-29.0, 1e-6));
      expect(r.max, closeTo(8.0, 1e-6));
    });

    test('a missing field is a gap, never a zero', () {
      final b = LiveTrendBuffer(capacity: 4);
      b.add(_s(t0, pvlt: 13.9));
      b.add(_s(t0.add(const Duration(seconds: 1)))); // no pvlt in this sample
      expect(b.valueAt(TrendField.pvlt, 1).isNaN, isTrue);
      // One finite point is not a line, and rangeOf must not invent a second.
      expect(b.hasData(TrendField.pvlt), isFalse);
      expect(b.rangeOf(TrendField.pvlt)!.min, closeTo(13.9, 1e-6));
      expect(b.rangeOf(TrendField.current), isNull);
    });

    test('revision moves on every mutation, so a painter can gate on it', () {
      final b = LiveTrendBuffer(capacity: 4);
      final before = b.revision;
      b.add(_s(t0, pvlt: 13.0));
      expect(b.revision, greaterThan(before));
      final afterAdd = b.revision;
      b.clear();
      expect(b.revision, greaterThan(afterAdd));
      // Clearing an already-empty buffer is not a mutation.
      final afterClear = b.revision;
      b.clear();
      expect(b.revision, afterClear);
    });

    test('clear() empties it — a trace must not cross a disconnect', () {
      final b = LiveTrendBuffer(capacity: 4);
      b.add(_s(t0, pvlt: 13.0));
      b.clear();
      expect(b.isEmpty, isTrue);
      expect(b.firstMs, isNull);
      expect(b.span, Duration.zero);
    });
  });

  group('ReadoutsCard chart mode', () {
    final items = [
      const Readout(icon: Icons.thermostat, label: 'TEMP', value: '31', unit: 'C'),
    ];
    const tracks = [
      TrendTrack(
          field: TrendField.current,
          label: 'Main current',
          unit: 'A',
          color: AppColors.cyan,
          spanZero: true),
    ];

    // The readout value is a RichText whose spans compose to "<value> <unit>",
    // so the finder both has to look inside RichText and match the whole run.
    testWidgets('starts on numbers and switches to the chart', (tester) async {
      final buffer = LiveTrendBuffer(capacity: 8)
        ..add(_s(t0, current: -29))
        ..add(_s(t0.add(const Duration(seconds: 1)), current: 8));

      await tester.pumpWidget(_host(
          ReadoutsCard(items: items, buffer: buffer, tracks: tracks)));
      expect(find.text('31 C', findRichText: true), findsOneWidget);
      expect(find.byType(LiveTrendChart), findsNothing);

      await tester.tap(find.text('Chart'));
      await tester.pump();
      expect(find.byType(LiveTrendChart), findsOneWidget);
      expect(find.text('31 C', findRichText: true), findsNothing);

      await tester.tap(find.text('Numbers'));
      await tester.pump();
      expect(find.byType(LiveTrendChart), findsNothing);
    });

    testWidgets('no tracks means no toggle at all', (tester) async {
      await tester.pumpWidget(_host(ReadoutsCard(
          items: items, buffer: LiveTrendBuffer(capacity: 4), tracks: const [])));
      expect(find.text('Chart'), findsNothing);
      expect(find.text('31 C', findRichText: true), findsOneWidget);
    });

    testWidgets('an empty buffer says it is waiting rather than drawing a flat line',
        (tester) async {
      await tester.pumpWidget(_host(ReadoutsCard(
          items: items, buffer: LiveTrendBuffer(capacity: 4), tracks: tracks)));
      await tester.tap(find.text('Chart'));
      await tester.pump();
      expect(find.text('Waiting for telemetry…'), findsOneWidget);
    });

    testWidgets('a footnote explains an absent series', (tester) async {
      final buffer = LiveTrendBuffer(capacity: 8)
        ..add(_s(t0, current: 1))
        ..add(_s(t0.add(const Duration(seconds: 1)), current: 2));
      await tester.pumpWidget(_host(ReadoutsCard(
        items: items,
        buffer: buffer,
        tracks: tracks,
        chartFootnote: 'no current here',
      )));
      await tester.tap(find.text('Chart'));
      await tester.pump();
      expect(find.text('no current here'), findsOneWidget);
    });
  });
}
