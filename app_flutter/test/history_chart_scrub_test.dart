/// design 0076 — drag across the history chart to walk its points.
///
/// 🔴 These are the FIRST tests of this chart's SELECTION at all. The two
/// existing `HistoryTrendCard` tests (`device_history_section_test.dart`) both
/// stop at the `buckets.length < 2` early return, so until now "tap a point,
/// get its numbers" — shipped and in daily use — was pinned by nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/history_repo.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';

/// 11 buckets a minute apart, one distinguishable voltage each.
///
/// The minute is what the assertions key on: the detail row prints `HH:mm`, so
/// "which point am I on" is readable from the widget tree without reaching
/// into private state.
final _buckets = List<HistoryBucket>.generate(
  11,
  (i) => HistoryBucket(
    at: DateTime(2026, 8, 21, 10, i),
    avgPvlt: 12.0 + i * 0.1,
    minPvlt: 11.9 + i * 0.1,
    maxPvlt: 12.1 + i * 0.1,
    count: 60,
  ),
);

String _label(int i) => '10:${i.toString().padLeft(2, '0')}';

const _stats = HistoryStats(
  minPvlt: 11.9,
  maxPvlt: 13.1,
  avgPvlt: 12.5,
  count: 660,
);

/// Card inside a REAL vertical scroll view.
///
/// 🔑 Not a convenience: both landing sites are inside one (design 0076 §1.1),
/// and the horizontal scrub has to win the gesture arena against it. Hosting
/// the card in a bare `body` would test the one arrangement that cannot fail.
Widget _host({ScrollController? controller}) => MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: ListView(
            controller: controller,
            children: [
              HistoryTrendCard(
                buckets: _buckets,
                stats: _stats,
                tempUnit: TempUnit.celsius,
                multiDay: false,
                bucketMs: 60000,
              ),
              const SizedBox(height: 1200),
            ],
          ),
        ),
      ),
    );

/// The plot band — the `SizedBox` of chart height inside the gesture detector.
Finder get _plot => find.byWidgetPredicate(
      (w) => w is SizedBox && w.height == 160,
    );

/// Centre of the touch target for bucket [i], mirroring `_TrendGeometry`.
Offset _atIndex(WidgetTester tester, int i) {
  final r = tester.getRect(_plot);
  const left = 40.0, right = 8.0; // no temperature series in these fixtures
  final plotW = r.width - left - right;
  return Offset(r.left + left + plotW * i / (_buckets.length - 1), r.center.dy);
}

/// Press at bucket [i] and let the gesture arena resolve.
///
/// 🔑 The 120 ms is not padding. Both landing sites are inside a scroll view,
/// so the tap recognizer cannot claim the pointer immediately — `onTapDown`
/// fires when it wins the arena or when `kPressTimeout` (100 ms) expires,
/// whichever comes first. Assert before that and NOTHING is selected yet, which
/// is a property of hosting a chart in a `ListView`, not of design 0076. (A
/// flick that moves within those 100 ms simply skips the tap entirely and the
/// drag does the first selection.)
Future<TestGesture> _pressAt(WidgetTester tester, int i) async {
  final g = await tester.startGesture(_atIndex(tester, i));
  await tester.pump(const Duration(milliseconds: 120));
  return g;
}

void main() {
  testWidgets('T1 a single tap still selects that bucket', (tester) async {
    await tester.pumpWidget(_host());
    await tester.tapAt(_atIndex(tester, 3));
    await tester.pump();

    expect(find.text(_label(3)), findsOneWidget);
  });

  testWidgets('T2 dragging moves the selection to the point under the finger',
      (tester) async {
    await tester.pumpWidget(_host());

    final g = await _pressAt(tester, 2);
    expect(find.text(_label(2)), findsOneWidget);

    await g.moveTo(_atIndex(tester, 7));
    await tester.pump();
    expect(find.text(_label(7)), findsOneWidget,
        reason: 'the whole point of design 0076');
    expect(find.text(_label(2)), findsNothing);

    await g.up();
  });

  testWidgets('T3 a drag that doubles back never blanks the panel',
      (tester) async {
    // The failure this pins: a scrub written as a toggle closes the detail
    // panel the moment the finger passes a point it already visited.
    await tester.pumpWidget(_host());

    final g = await _pressAt(tester, 5);

    for (final i in [6, 7, 6, 5, 4, 5]) {
      await g.moveTo(_atIndex(tester, i));
      await tester.pump();
      expect(find.byIcon(Icons.close), findsOneWidget,
          reason: 'panel vanished while scrubbing back over index $i');
      expect(find.text(_label(i)), findsOneWidget);
    }

    await g.up();
  });

  testWidgets('T4 a drag STARTING on the selected point does not blink it shut',
      (tester) async {
    // design 0076 §3.2: with the toggle left on tap-DOWN, pressing the already
    // selected point clears it, and the first move event sets it back.
    await tester.pumpWidget(_host());
    await tester.tapAt(_atIndex(tester, 4));
    await tester.pump();
    expect(find.text(_label(4)), findsOneWidget);

    final g = await _pressAt(tester, 4);
    expect(find.text(_label(4)), findsOneWidget,
        reason: 'pressing the selected point must not clear it');

    await g.moveTo(_atIndex(tester, 8));
    await tester.pump();
    expect(find.text(_label(8)), findsOneWidget);
    await g.up();
  });

  testWidgets('T5 dragging past either edge holds the end points',
      (tester) async {
    await tester.pumpWidget(_host());
    final r = tester.getRect(_plot);

    final g = await _pressAt(tester, 5);

    await g.moveTo(Offset(r.left - 200, r.center.dy));
    await tester.pump();
    expect(find.text(_label(0)), findsOneWidget);

    await g.moveTo(Offset(r.right + 200, r.center.dy));
    await tester.pump();
    expect(find.text(_label(10)), findsOneWidget);

    await g.up();
    await tester.pump();
  });

  testWidgets('T6 the selection survives the release', (tester) async {
    await tester.pumpWidget(_host());

    final g = await tester.startGesture(_atIndex(tester, 1));
    await g.moveTo(_atIndex(tester, 6));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    expect(find.text(_label(6)), findsOneWidget,
        reason: 'the finger stopped in order to READ the numbers');
  });

  testWidgets('T7 a vertical drag still scrolls the host, selecting nothing',
      (tester) async {
    // The declared price of design 0076 §2 — and the thing that would silently
    // disappear if anyone ever "fixed" the diagonal case with an eager
    // recognizer.
    final c = ScrollController();
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(controller: c));

    await tester.drag(_plot, const Offset(0, -180));
    await tester.pumpAndSettle();

    expect(c.offset, greaterThan(0), reason: 'the page must still scroll');
    expect(find.byIcon(Icons.close), findsNothing,
        reason: 'scrolling is not selecting');
  });

  testWidgets('T8 tapping the same point twice still dismisses it (ruling B)',
      (tester) async {
    await tester.pumpWidget(_host());

    await tester.tapAt(_atIndex(tester, 3));
    await tester.pump();
    expect(find.text(_label(3)), findsOneWidget);

    await tester.tapAt(_atIndex(tester, 3));
    await tester.pump();
    expect(find.text(_label(3)), findsNothing,
        reason: 'Q1 ruling B keeps tap-to-dismiss; only the drag path may not '
            'toggle');
  });

  testWidgets('T9 one haptic per crossing, and none for a repeated point',
      (tester) async {
    // Q2. The app had no `HapticFeedback` call anywhere before this, so the
    // count is worth pinning: a buzz per MOVE EVENT rather than per crossing
    // is the mistake that makes a scrub feel broken.
    final buzzes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          buzzes.add('${call.arguments}');
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(_host());

    final g = await _pressAt(tester, 0);
    expect(buzzes, isEmpty,
        reason: 'the tap that opens a scrub is not a crossing — and the tap '
            'path never buzzes at all');

    await g.moveTo(_atIndex(tester, 3));
    await tester.pump();
    await g.moveTo(_atIndex(tester, 3)); // same point again
    await tester.pump();
    expect(buzzes.length, 1);

    await g.moveTo(_atIndex(tester, 4));
    await tester.pump();
    expect(buzzes.length, 2);

    await g.up();
  });
}
