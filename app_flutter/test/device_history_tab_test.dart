// design 0065 — the history block embedded in a device's detail page.
//
// The dealer's report (2026-08-15) was that reaching one unit's history meant
// leaving its page, switching tabs, and picking the unit again — and that the
// History tab then re-seeded its scope to whichever unit was RECORDING, not the
// one he had been looking at. The owner rejected the cheap fix (a button that
// jumps to the History tab) and ruled for an embedded block.
//
// 🔴 THE ONE THING IN THIS FEATURE THAT CAN PRODUCE WRONG DATA is the question
// "which unit is this about". Everything else fails visibly. So the scope tests
// come first and are the reason this file exists; the rest guard the ways the
// block could quietly stop working.
//
// The export half (`T65-7` … `T65-10`) lives in
// `device_history_export_test.dart` — it is a separately revertable change.
//
// CLEAN-ROOM: expectations derive from this project's own source and captures.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/class_pending_view.dart';
import 'package:open_smart_batt/ui/dashboard/pack_view.dart';
import 'package:open_smart_batt/ui/dashboard/power_bank_view.dart';
import 'package:open_smart_batt/ui/dashboard/unidentified_view.dart';
import 'package:open_smart_batt/ui/devices/device_detail_page.dart';
import 'package:open_smart_batt/ui/history/device_history_tab.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:open_smart_batt/ui/widgets/one_screen_report.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// No radio. [connected] drives the session, which is what makes
/// `recordingDeviceId` non-null — the value the block must NOT be reading.
class _StubBle extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  String? connected;

  @override
  String? get connectedDeviceId => connected;

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);
  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

/// A connection that is already past `ClassPendingView`'s grace window.
///
/// The real `pendingFor` needs a link that reaches `ready` and then real
/// seconds to elapse; `waiting_states_test.dart` already pins those rules, and
/// this file only needs the view in the state where it HAS content to hang the
/// history block under.
class _StalledConn extends ConnectionController {
  _StalledConn(super.ble, {required super.settings});

  @override
  Duration? get pendingFor => const Duration(seconds: 30);
}

/// Counts the three history queries so a test can say WHICH ones ran.
///
/// 🔴 Design 0079 S0. `debugDeviceHistoryQueries` counts `_load` CALLS, which
/// cannot distinguish "loaded" from "loaded and also pulled a thousand rows it
/// never read" — and that distinction is the entire change S0 makes. Counting
/// at the controller is the only seam that sees it.
///
/// Built over a SEPARATE [_StubBle] on purpose: a second controller listening
/// to the shared stub would record every emitted sample a second time, and this
/// file's other tests assert on stored rows.
/// A controller whose `historyStats` never answers.
///
/// 🔴 Design 0079 T79-10's "unknown" case. The obvious way to produce it —
/// pump without a `runAsync` so the real database future stays unresolved —
/// leaves the PAGE's own periodic timers pending and the binding fails the
/// test on `!timersPending`, which is a hygiene assertion that says nothing
/// about the badge. Withholding the answer at the controller lets the rest of
/// the page run normally.
class _NeverStatsTelemetry extends TelemetryController {
  _NeverStatsTelemetry(super.ble,
      {required super.settings, required super.history, required super.logs});

  @override
  Future<HistoryStats> historyStats({DateTime? since, String? deviceId}) =>
      Completer<HistoryStats>().future;
}

class _CountingTelemetry extends TelemetryController {
  _CountingTelemetry(super.ble,
      {required super.settings, required super.history, required super.logs});

  int stats = 0;
  int buckets = 0;
  int listBuckets = 0;

  @override
  Future<HistoryStats> historyStats({DateTime? since, String? deviceId}) {
    stats++;
    return super.historyStats(since: since, deviceId: deviceId);
  }

  @override
  Future<List<HistoryBucket>> historyBuckets(
      {DateTime? since, required int bucketMs, String? deviceId}) {
    buckets++;
    return super
        .historyBuckets(since: since, bucketMs: bucketMs, deviceId: deviceId);
  }

  @override
  Future<List<HistoryListRow>> historyListBuckets({
    DateTime? since,
    required int bucketMs,
    int? limit,
    String? deviceId,
  }) {
    listBuckets++;
    return super.historyListBuckets(
        since: since, bucketMs: bucketMs, limit: limit, deviceId: deviceId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  const unitA = 'DEV-A';
  const unitB = 'DEV-B';

  // Voltages a person could not confuse: A is a 12 V pack, B is a single cell.
  // Every scope assertion below reads the NUMBER ON SCREEN rather than a mock's
  // call log, because the number is what a user would see go wrong.
  const vA = 12.34;
  const vB = 3.91;

  late AppServices services;
  late _StubBle ble;

  Future<void> boot(WidgetTester tester) async {
    debugClearDeviceHistoryCache();
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _StubBle();
      services = await AppServices.create(appDatabase: db, ble: ble);
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(services.dispose);
    });
  }

  /// Seed [count] rows for [deviceId], spread backwards across the part of
  /// TODAY that has already happened, the newest of them at slot [startSlot].
  ///
  /// 🔴 **The spacing is not a fixed minute, and the reason is the only
  /// interesting thing in this helper.** It used to be
  /// `now.subtract(Duration(minutes: fromMinute + i))`, with the comment "rows
  /// are minutes apart so each lands in its own display window" — true while the
  /// ROW LIST was the observable, because a list window is a fixed
  /// [kHistoryListBucketMs]. The list was removed on 2026-08-16, and with it the
  /// only place a stored number reached the screen at minute granularity. What
  /// renders a number now is the stats strip, and that strip lives INSIDE
  /// [HistoryTrendCard] — *after* its `buckets.length < 2` early return. So what
  /// every `showsVoltage` / `30°C` assertion in this file really needs is TWO
  /// CHART POINTS, and a chart point is [historyChartBucketMs] wide:
  /// `(now − LOCAL midnight) / 180`, clamped to [1 min, 24 h].
  ///
  /// That width is a function of how far into the **local** day it is, so a
  /// fixed minute of spacing made this file's outcome depend on the tester's
  /// time zone and wall clock. Measured 2026-08-17 with three rows one minute
  /// apart: **3** chart points at 03:42 UTC (bucket 74 s), **2** at 11:42 in
  /// Asia/Taipei (bucket 234 s), **1** at 20:42 in America/Los_Angeles (bucket
  /// 414 s) — and one point renders "not enough data to chart" with no stats
  /// strip under it, so the assertions flipped with the zone and, in the middle
  /// band, with the minute. Nothing was wrong with the app: aligning buckets to
  /// the viewer's local midnight is FB-71 Q6, ruled 2026-08-14 and landed.
  ///
  /// Spreading the rows over the elapsed part of today instead makes their span
  /// scale with the very quantity the bucket width is derived from, so they
  /// out-span their bucket in every zone at every hour — and, by construction,
  /// every row still lands at or after local midnight, which a fixed offset did
  /// not guarantee either (`now - 3 min` is yesterday at 00:01).
  ///
  /// ⚠️ **One residual, measured rather than assumed** (2026-08-17, by pinning
  /// the local hour with a fixed-offset `TZ`): the file is green at every local
  /// hour tried — 00:01:30, 00:05, 00:45, 03:30, 12:00, 18:00, 23:58 — and red
  /// only inside roughly **the first 90 seconds after local midnight** (00:00:30
  /// ⇒ 12 red, 00:01:00 ⇒ 4 red). That is not a seeding bug and no spacing can
  /// close it: "today" is then shorter than [kHistoryListBucketMs], so the chart
  /// genuinely cannot have two points and the block draws
  /// `historyChartInsufficientData` with no stats strip beneath it.
  ///
  /// 🔑 Which is worth reading twice, because it is also what a USER sees at
  /// 00:00:30 — a unit that has been recording all night shows one sentence and
  /// no numbers, because the strip is inside the chart's early return even
  /// though `historyStats` never needed a bucket. Closing that is a UI change on
  /// two surfaces (the History tab renders the same card), so it is left for a
  /// ruling rather than smuggled in with a test fix.
  Future<void> addRows(WidgetTester tester, String deviceId, double pvlt,
          {int count = 3, int? temp = 30, int? mode, int startSlot = 1}) =>
      tester.runAsync(() async {
        final now = DateTime.now();
        // 🔴 The block's own derivation of "today", not a second one — the same
        // cut-off the query will be run with (§6 R5).
        final since = historySinceFor(HistoryRange.today)!;
        final slots = startSlot + count;
        final step = Duration(
            microseconds: now.difference(since).inMicroseconds ~/ slots);
        for (var i = 0; i < count; i++) {
          await services.historyRepo.insertSample(
            TelemetrySample(
              timestamp: now.subtract(step * (startSlot + i)),
              pvlt: pvlt,
              temperatureC: temp,
              mode: mode ?? ReportedStatus.normal,
            ),
            deviceId: deviceId,
          );
        }
      });

  /// Put unit [id] on the link, so `recordingDeviceId` names it.
  Future<void> connectTo(WidgetTester tester, String id) async {
    ble.connected = id;
    await tester.runAsync(() async {
      ble.emitLink(BleLinkState.ready);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
  }

  Future<void> pumpSection(
    WidgetTester tester, {
    required String deviceId,
    required bool live,
    Locale locale = const Locale('en'),
    TelemetryController? telemetry,
  }) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(
              value: services.settings),
          ChangeNotifierProvider<DeviceController>.value(
              value: services.devices),
          ChangeNotifierProvider<DeviceFactsController>.value(
              value: services.facts),
          ChangeNotifierProvider<ConnectionController>.value(
              value: services.connection),
          ChangeNotifierProvider<TelemetryController>.value(
              value: telemetry ?? services.telemetry),
          ChangeNotifierProvider<AlertController>.value(value: services.alerts),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          // 🔵 **No wrapping `ListView` since design 0079 S2** — the tab IS a
          // `CustomScrollView`, and nesting one scrollable inside another with
          // an unbounded main axis is an assertion, not a layout.
          home: Scaffold(
            body: DeviceHistoryTab(deviceId: deviceId, live: live),
          ),
        ),
      ),
    );
    // Three chained database reads; they need the real event loop.
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.pump();
  }

  /// Pump the real [DeviceDetailPage] — the surface that owns the tabs.
  ///
  /// 🔑 The whole page rather than a view, because design 0079's claim is
  /// structural: the tab bar sits ABOVE the class router, so the assertion has
  /// to be made where the router is.
  Future<void> pumpDetailPage(WidgetTester tester,
      {String deviceId = unitA, TelemetryController? telemetry}) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(
              value: services.settings),
          ChangeNotifierProvider<DeviceController>.value(
              value: services.devices),
          ChangeNotifierProvider<DeviceFactsController>.value(
              value: services.facts),
          ChangeNotifierProvider<ConnectionController>.value(
              value: services.connection),
          ChangeNotifierProvider<TelemetryController>.value(
              value: telemetry ?? services.telemetry),
          ChangeNotifierProvider<AlertController>.value(value: services.alerts),
          ChangeNotifierProvider<GForceController>.value(value: services.gforce),
          ChangeNotifierProvider<GpsSpeedController>.value(value: services.speed),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: DeviceDetailPage(deviceId: deviceId),
        ),
      ),
    );
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.pump();
  }

  /// Tap the history tab and let its two queries land.
  Future<void> openHistoryTab(WidgetTester tester) async {
    await tester.tap(find.text('History'));
    await tester.pump();
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.pump();
  }

  Future<void> tapLiveTab(WidgetTester tester) async {
    await tester.tap(find.text('Live'));
    await tester.pump();
    await tester.pump();
  }

  bool showsVoltage(double v) =>
      find.textContaining(v.toStringAsFixed(2)).evaluate().isNotEmpty;

  // ==========================================================================
  // T65-1 / T65-2 — scope. The half of this feature that can be wrong silently.
  // ==========================================================================
  group('scope is the page, never the link', () {
    testWidgets(
        '🔴 T65-1 — connected to B, looking at A: the block shows A',
        (tester) async {
      // CATCHES: someone replacing the `deviceId` parameter with
      // `conn.connectedDeviceId` or `tele.recordingDeviceId`. Both are one
      // line away in this codebase — `pack_view.dart` already reads the former
      // for its layout lookup — and the result is a page titled A showing B's
      // history. That is FB-41/FB-42's shape in a third place, and nothing on
      // screen would say so.
      await boot(tester);
      await addRows(tester, unitA, vA);
      await addRows(tester, unitB, vB);
      await connectTo(tester, unitB);
      expect(services.telemetry.recordingDeviceId, unitB,
          reason: 'the premise: the LINK holds B');

      await pumpSection(tester, deviceId: unitA, live: false);

      expect(showsVoltage(vA), isTrue,
          reason: "A's own rows are what its page must show");
      expect(showsVoltage(vB), isFalse,
          reason: 'B is merely the unit on the link — its rows belong on its '
              'own page');
    });

    testWidgets('and the mirror image: looking at B shows B', (tester) async {
      // The control. Without it, a block that showed NOTHING would pass the
      // test above.
      await boot(tester);
      await addRows(tester, unitA, vA);
      await addRows(tester, unitB, vB);
      await connectTo(tester, unitB);

      await pumpSection(tester, deviceId: unitB, live: true);

      expect(showsVoltage(vB), isTrue);
      expect(showsVoltage(vA), isFalse);
    });

    testWidgets('T65-2 — offline is exactly when it has to work',
        (tester) async {
      // CATCHES: anyone "simplifying" the block away on a page with no link,
      // which would undo the Q4 ruling and the dealer's actual complaint —
      // he wants history precisely when the unit is not in front of him.
      await boot(tester);
      await addRows(tester, unitA, vA);

      await pumpSection(tester, deviceId: unitA, live: false);

      expect(find.byType(DeviceHistoryTab), findsOneWidget);
      expect(showsVoltage(vA), isTrue);
    });
  });

  // ==========================================================================
  // T65-3 / T65-5 — the block must never be a dead end.
  // ==========================================================================
  group('empty is a state, not an absence', () {
    testWidgets('T65-3 — a unit with no rows still gets the block',
        (tester) async {
      // CATCHES: `if (rows.isEmpty) return const SizedBox.shrink();`. It looks
      // tidy and it is the FB-53 / design 0046 T-new-6 dead-end shape: the one
      // user who most needs to know "there is nothing recorded for this unit"
      // is told nothing at all. With the block expanded by default (Q5) this is
      // what EVERY never-recorded unit shows on open, so it is not an edge.
      await boot(tester);
      await addRows(tester, unitB, vB); // another unit has rows; this one has none

      await pumpSection(tester, deviceId: unitA, live: false);

      expect(find.byType(DeviceHistoryTab), findsOneWidget);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      // Default range is "today", so the honest sentence is the range one.
      expect(find.text(l10n.historyEmptyDeviceRange), findsOneWidget);
      expect(showsVoltage(vB), isFalse, reason: 'and still not the other unit');
    });

    testWidgets('"all" and still nothing ⇒ it says the unit has no records',
        (tester) async {
      await boot(tester);
      await pumpSection(tester, deviceId: unitA, live: false);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      await tester.tap(find.text(l10n.historyRangeAll));
      await tester.pump();
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      expect(find.text(l10n.deviceHistoryEmpty), findsOneWidget,
          reason: 'with no range excluding anything, "no records at all" is '
              'the only honest sentence left');
    });

    testWidgets('T65-5 — an UNSAVED unit does not crash the block',
        (tester) async {
      // CATCHES: the block reaching for `saved.productClass` or `saved.alias`.
      // Design 0055 made "connected but never named" an ordinary way to use
      // the app, so a null saved record is a daily path rather than a corner.
      await boot(tester);
      await addRows(tester, unitA, vA);
      expect(services.devices.deviceFor(unitA), isNull,
          reason: 'the premise: nothing was ever saved for this unit');

      await pumpSection(tester, deviceId: unitA, live: true);

      expect(tester.takeException(), isNull);
      expect(showsVoltage(vA), isTrue);
    });
  });

  // ==========================================================================
  // T65-4b / T65-4c — the memoisation, from both sides.
  // ==========================================================================
  // ==========================================================================
  // ~~P-2′ memoisation (T65-4b / T65-4c)~~ — DELETED 2026-08-21 (design 0079 S2)
  //
  // 🔴 **Deleted, not loosened, and the precedent is design 0065 §0.9's own**:
  // when the owner removed the row list on 2026-08-16, the tests that guarded
  // its slicing were deleted rather than relaxed, because "留著讓它綠等於在測
  // 一段頁面到不了的程式碼" — keeping them green means testing code the page
  // cannot reach.
  //
  // The memo existed because the block hung off `PackScaffold`, which watches
  // `TelemetryController` and therefore rebuilt it several times a second. The
  // history tab is a SIBLING of the live half, not a child of it, so nothing
  // drives that rebuild any more. `debugDeviceHistoryBodyBuilds` went with it.
  //
  // ⚠️ What the two tests actually guarded is worth restating, because it is
  // NOT covered elsewhere and would matter again if a memo ever came back:
  // `T65-4b` pinned that a memo exists at all, and `T65-4c` — the reverse pin —
  // that a change the USER can see still gets through it. A cache key missing
  // an input freezes the surface on stale data, which is much harder to notice
  // than the rebuild it was preventing.
  // ==========================================================================

  group('T65-12 — one unit, one set of numbers', () {
    test('the range cut-off has exactly one derivation', () {
      // CATCHES: a second `_sinceFor` growing back on either surface. "Today"
      // has to mean the same instant on both, or the same unit shows two
      // different charts and nobody can tell which is right.
      final today = historySinceFor(HistoryRange.today)!;
      final now = DateTime.now();
      expect(today, DateTime(now.year, now.month, now.day));
      expect(historySinceFor(HistoryRange.week),
          DateTime(now.year, now.month, now.day)
              .subtract(const Duration(days: 6)));
      expect(historySinceFor(HistoryRange.all), isNull);
    });

    test('the chart bucket width has exactly one derivation', () {
      // CATCHES: `bucketMs` being replaced with a fixed 60000, or with a
      // different target point count. Each plotted point averages that much
      // time, so the two surfaces would draw visibly different charts from
      // identical data (design 0065 §6 R5).
      // 🔵 design 0081 S1: BOTH ends are arguments now. The old form took one
      // end and measured to `DateTime.now()`; see
      // `history_chart_bucket_span_test.dart` for why that had to go.
      final now = DateTime(2026, 8, 16, 12);
      // A minute floor, whatever the span.
      expect(historyChartBucketMs(now, now), kHistoryListBucketMs);
      expect(
          historyChartBucketMs(now.subtract(const Duration(minutes: 30)), now),
          kHistoryListBucketMs);
      // ~180 points across the span, once the span is wide enough for it.
      expect(historyChartBucketMs(now.subtract(const Duration(hours: 24)), now),
          (24 * 3600000) ~/ kHistoryTargetBucketPoints);
      // …and a day-wide ceiling.
      expect(historyChartBucketMs(now.subtract(const Duration(days: 3650)), now),
          24 * 3600000);
      expect(kHistoryTargetBucketPoints, 180);
      expect(kHistoryRowCap, 1000);
    });

    testWidgets('the embedded chart states the same width the tab would',
        (tester) async {
      // The end-to-end half: both surfaces render the "each point averages N"
      // note, and for one unit over one range it has to be the same sentence.
      await boot(tester);
      await addRows(tester, unitA, vA, count: 40);
      await pumpSection(tester, deviceId: unitA, live: false);

      final since = historySinceFor(HistoryRange.today);
      final stats = await tester.runAsync(() =>
          services.telemetry.historyStats(since: since, deviceId: unitA));
      final expected = historyChartBucketMs(stats!.firstAt, stats.lastAt);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final minutes = (expected / 60000).round();
      expect(find.text(l10n.historyChartBucketMinutes(minutes)), findsOneWidget);
    });

    testWidgets('T65-12b — the width follows the DATA, not the clock (0081 S1)',
        (tester) async {
      // 🔵 design 0081 S1, end-to-end through the shared loader — the half a
      // pure-function test cannot reach, because the defect lived in WHICH two
      // instants `loadHistorySlice` handed over (`since` and `now`), not in the
      // arithmetic it handed them to.
      //
      // 🔴 Anchored TEN DAYS BACK on purpose. A fixture whose "now" sits just
      // after the rows makes the old and the new derivation agree, and the
      // first draft of `history_chart_bucket_span_test.dart` did exactly that
      // and passed against the very code it was written to reject. The V2
      // reverse-proof caught it; this shape cannot be fooled that way, at any
      // hour, in any time zone.
      await boot(tester);
      await tester.runAsync(() async {
        final start = DateTime.now().subtract(const Duration(days: 10));
        for (var i = 0; i < 30; i++) {
          await services.historyRepo.insertSample(
            TelemetrySample(
              timestamp: start.add(Duration(minutes: i)),
              pvlt: vA,
              temperatureC: 30,
              mode: ReportedStatus.normal,
            ),
            deviceId: unitA,
          );
        }
      });

      final slice = await tester.runAsync(() =>
          loadHistorySlice(services.telemetry, since: null, deviceId: unitA));
      expect(slice!.stats.count, 30);
      // Thirty minutes of rows ⇒ thirty one-minute points, although the ride
      // ended ten days ago. Measuring to `DateTime.now()` would make it ~80
      // minutes — the whole ride as a single point, getting worse every day it
      // ages while the data never changes.
      expect(slice.bucketMs, kHistoryListBucketMs);
      expect(slice.buckets.length, greaterThan(2));
    });
  });

  // ==========================================================================
  // The measured retreat (design 0065 §3.5.4 ③).
  // ==========================================================================

  // ==========================================================================
  // P-4 — the cache that exists for FB-75's host swap (R3).
  // ==========================================================================
  testWidgets('re-mounting the block within the TTL does not re-query',
      (tester) async {
    // CATCHES: the query cache being made per-State. FB-75 auto-connects on
    // opening a saved unit's page; when it succeeds the page swaps its offline
    // body for the dashboard, which DESTROYS this widget and builds a fresh one
    // in the other subtree. Without a cache that outlives the State, that is
    // three database queries twice inside a second or two (design 0065 R3).
    await boot(tester);
    await addRows(tester, unitA, vA);
    await pumpSection(tester, deviceId: unitA, live: false);
    expect(showsVoltage(vA), isTrue);

    // 🔴 A window of its own. A row sharing a display window with an existing
    // one would be AVERAGED into it, and neither voltage would appear — which
    // would make this test pass for the wrong reason. A far slot rather than
    // "30 minutes ago" because the window's WIDTH moves with the local hour;
    // see `addRows`.
    await addRows(tester, unitA, 9.87, count: 1, startSlot: 30);

    // 🔴 And the widget really has to be DESTROYED, not merely rebuilt.
    // Re-pumping the same tree keeps the State — and therefore the already
    // resolved future — so a test that skipped this would be pinning State
    // preservation while believing it was pinning the cache.
    Future<void> remount(bool live) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await pumpSection(tester, deviceId: unitA, live: live);
    }

    // 🔴 Counted, not inferred from what is on screen. Until 2026-08-16 this
    // read "9.87 is not rendered yet" — the row list was the observable. The
    // list is gone and the stats strip AGGREGATES, so a newer row can arrive
    // and move nothing visible. `debugDeviceHistoryQueries` says the thing this
    // test actually means.
    final queriesBefore = debugDeviceHistoryQueries;
    await remount(true);
    expect(showsVoltage(vA), isTrue);
    expect(debugDeviceHistoryQueries, queriesBefore,
        reason: 'served from the P-4 cache — a re-query would have gone to the '
            'database for the row written since');

    debugClearDeviceHistoryCache();
    await remount(true);
    expect(debugDeviceHistoryQueries, greaterThan(queriesBefore),
        reason: 'and once the entry is gone the block really does re-query');
  });

  // ==========================================================================
  // T65-11 — ~~all FIVE mount points~~ ⇒ THE ROUTE CANNOT LOSE IT (design 0079)
  //
  // 🔵 **The invariant was REWRITTEN on 2026-08-21, not deleted, and the
  // difference matters.** design 0065 Q3 ruled that every route the detail page
  // can take must carry this unit's history — four dashboard routes plus the
  // offline report — and the original five tests asserted the block was mounted
  // inside each of the five. design 0079 S1 dismantled those five mount points
  // and put the history on a TAB, above the router.
  //
  // Deleting the group would have been the easy read ("those mount points are
  // gone"), and it would have thrown away the most expensive ruling in design
  // 0065 — Q3 was argued at length precisely because the first draft proposed
  // shipping only the two pack routes. The ruling has not been reversed; the
  // mechanism that satisfies it has. So the tests now pin the mechanism:
  //
  //   1. no view carries the block any more — a partial revert is caught;
  //   2. the tab sits ABOVE the class router, so no route can lose it, in
  //      either connection state.
  //
  // 🔑 (2) is strictly STRONGER than what the five tests could say. They
  // enumerated the routes that existed in August 2026 and could not speak for a
  // sixth; "above the router" covers routes nobody has written yet.
  // ==========================================================================
  group('T79-1 — the history tab is above the route, so no route can lose it',
      () {
    Future<void> pumpRoute(WidgetTester tester, Widget view) async {
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsController>.value(
                value: services.settings),
            ChangeNotifierProvider<DeviceController>.value(
                value: services.devices),
            ChangeNotifierProvider<DeviceFactsController>.value(
                value: services.facts),
            ChangeNotifierProvider<ConnectionController>.value(
                value: services.connection),
            ChangeNotifierProvider<TelemetryController>.value(
                value: services.telemetry),
            ChangeNotifierProvider<AlertController>.value(
                value: services.alerts),
            ChangeNotifierProvider<GForceController>.value(
                value: services.gforce),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(body: view),
          ),
        ),
      );
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('no dashboard view carries the block itself any more',
        (tester) async {
      // CATCHES: a partial revert — one view getting its history block
      // back, which would put a second copy of this unit's history on the page
      // (the shape design 0079 §5.2 step 2 calls out as a legitimate MID-branch
      // state that must never reach `main`).
      await boot(tester);
      await addRows(tester, unitA, vA);
      final stalled = _StalledConn(ble, settings: services.settings);
      addTearDown(stalled.dispose);

      for (final (name, view) in <(String, Widget)>[
        ('pack', const PackView(deviceId: unitA)),
        ('power bank', const PowerBankView(deviceId: unitA)),
        ('unidentified', const UnidentifiedView(deviceId: unitA)),
        (
          'class pending',
          ChangeNotifierProvider<ConnectionController>.value(
            value: stalled,
            child: const ClassPendingView(deviceId: unitA),
          )
        ),
      ]) {
        await pumpRoute(tester, view);
        expect(find.byType(DeviceHistoryTab), findsNothing,
            reason: '$name must not append the block: it belongs to the page');
      }
    });

    testWidgets('the OFFLINE page offers it — Q4, in its new mechanism',
        (tester) async {
      // design 0065 Q4 verbatim: offline is the case this feature exists for.
      // The dealer wants a unit's history precisely when the unit is not in
      // front of him. Under design 0079 he gets it in one tap instead of
      // scrolling past a full screen of failure report.
      await boot(tester);
      await addRows(tester, unitA, vA);
      await tester.runAsync(
          () => services.devices.saveNew(unitA, 'Cap #1', name: 'RCE-SCAP_II'));
      await pumpDetailPage(tester);

      expect(find.text('History'), findsOneWidget,
          reason: 'the tab is offered with no link at all');
      expect(find.byType(DeviceHistoryTab), findsNothing,
          reason: 'T-1: not mounted until it is asked for');

      await openHistoryTab(tester);
      expect(find.byType(DeviceHistoryTab), findsOneWidget);
      expect(showsVoltage(vA), isTrue, reason: 'and it queried THIS unit');
    });

    testWidgets('and the CONNECTED page offers the same two tabs',
        (tester) async {
      // The other half of "above the router": whichever view the class router
      // picks, the tab bar is the page's, not the view's.
      await boot(tester);
      await addRows(tester, unitA, vA);
      await tester.runAsync(
          () => services.devices.saveNew(unitA, 'Cap #1', name: 'RCE-SCAP_II'));
      await connectTo(tester, unitA);
      await pumpDetailPage(tester);

      expect(find.text('Live'), findsOneWidget);
      expect(find.text('History'), findsOneWidget);

      await openHistoryTab(tester);
      expect(showsVoltage(vA), isTrue);
    });
  });

  // ==========================================================================
  // T79-2 … T79-5, T79-11 — what the TAB buys (design 0079 S1).
  // ==========================================================================
  group('T79 — the tab', () {
    Future<void> savedAndSeeded(WidgetTester tester) async {
      await boot(tester);
      await addRows(tester, unitA, vA);
      await tester.runAsync(
          () => services.devices.saveNew(unitA, 'Cap #1', name: 'RCE-SCAP_II'));
    }

    testWidgets('T79-2 — not opening it queries NOTHING', (tester) async {
      // 🔴 The single largest thing design 0079 buys, and the reason the page
      // does not use a `TabBarView` (which builds the neighbour for the swipe).
      //
      // What it replaces: from design 0065 until 2026-08-21 the block was
      // expanded by default on EVERY detail-page open — every unit, every
      // route, offline ones included — because the owner's Q5 ruling removed
      // the "nobody expanded it so nothing was queried" buffer. That was the
      // right call for a block sitting in the page; it stops being a cost at
      // all once opening it is a deliberate act.
      await savedAndSeeded(tester);
      final before = debugDeviceHistoryQueries;

      await pumpDetailPage(tester);

      // ⚠️ **Precisely stated since S3**: the page DOES make one query on
      // arrival — the `all`-range COUNT behind the tab's badge (design 0079
      // Q3), asserted separately in `T79-10`. What this pins is that the
      // TAB's three have not run. The two are worth keeping apart: the badge
      // is one aggregate over an index, and it replaced a load that pulled a
      // thousand minute windows to answer a boolean (S0).
      expect(debugDeviceHistoryQueries, before,
          reason: "the tab's own queries wait to be asked for");
      expect(find.byType(DeviceHistoryTab), findsNothing,
          reason: 'T-1: not in the tree at all until first selected');
    });

    testWidgets('T79-3 — every arrival is a fresh query (FB-84)',
        (tester) async {
      // FB-84, verbatim: "entering the device detail page does not refresh that
      // unit's history". Both halves of that were real — a 30 s cache in front
      // of the mount query, and no refresh ever after — and the registry
      // records the minimal fix as blocked on "the cost has no number".
      //
      // Under a tab the cost IS the number: zero for anyone who does not open
      // it (T79-2), one query for anyone who does. So the arrival forces past
      // the cache.
      await savedAndSeeded(tester);
      await pumpDetailPage(tester);

      await openHistoryTab(tester);
      final first = debugDeviceHistoryQueries;
      expect(first, greaterThan(0), reason: 'opening it queries');

      // A row lands while the user is on the live tab — the exact scenario the
      // 30 s cache used to swallow.
      await tapLiveTab(tester);
      await addRows(tester, unitA, 9.87, count: 1, startSlot: 30);
      await openHistoryTab(tester);

      expect(debugDeviceHistoryQueries, greaterThan(first),
          reason: 'coming back re-queries — cache or no cache');
    });

    testWidgets('T79-4 — but coming back keeps what the user had chosen',
        (tester) async {
      // T-2. The counterweight to T79-3: re-querying must not also throw away
      // the range the user selected. Design 0065's refresh button made the same
      // distinction (it deliberately did NOT reset the list position, while a
      // range change did).
      await savedAndSeeded(tester);
      await pumpDetailPage(tester);
      await openHistoryTab(tester);

      await tester.tap(find.text('All'));
      await tester.pump();
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      await tapLiveTab(tester);
      await openHistoryTab(tester);

      // 🔴 Asserted on the CHART's own `multiDay`, and both of the obvious
      // alternatives were tried and rejected in the writing of this test:
      //
      //  * `textContaining('Today')` matches the range row's "Today" SEGMENT,
      //    which is rendered whether or not it is the chosen one — it passes
      //    and fails for reasons unrelated to the selection;
      //  * `find.text("Today's Voltage Trend")` never matches anything, because
      //    `CardHeading` renders `text.toUpperCase()` (`industrial_card.dart:182`).
      //    That one is worse than wrong: as a `findsNothing` it passes VACUOUSLY,
      //    and would go on passing if the range really did snap back.
      //
      // `multiDay` is `_range != HistoryRange.today` — the selection itself.
      final chart = tester.widget<HistoryTrendCard>(find.byType(HistoryTrendCard));
      expect(chart.multiDay, isTrue,
          reason: 'the range survived the round trip; it did not snap back');
    });

    testWidgets('T79-5 — the live tab is what it always was', (tester) async {
      // Equivalence, which is S1's entire acceptance criterion. The live half
      // must be the same body as before, and the default tab must be it: a page
      // that opened on history would answer a question the user did not ask.
      await savedAndSeeded(tester);
      await pumpDetailPage(tester);

      // Offline unit ⇒ the live tab is the failure report, unchanged.
      expect(find.byType(OneScreenReport), findsOneWidget,
          reason: 'default tab is live, and live for an offline unit is the '
              'failure report — design 0065 Q4 left it centred and whole');
    });

    testWidgets('T79-11 — there is no horizontal swipe between tabs',
        (tester) async {
      // 🔴 NOT an oversight, and the comment in `_DetailTabBar` says so at
      // length. `HistoryTrendCard` scrubs on a horizontal drag (FB-94 / design
      // 0076), and design 0076 §2 already records that a diagonal start is lost
      // to whichever axis crosses the touch slop first. A page-level horizontal
      // drag would be a second competitor for that gesture, on a control that
      // shipped three days ago and whose feel nobody has tested on a device.
      //
      // CATCHES: someone "finishing the job" with a `TabBarView` — which would
      // also silently undo T79-2, because it builds the neighbour.
      await savedAndSeeded(tester);
      await pumpDetailPage(tester);
      expect(find.byType(TabBarView), findsNothing);

      await tester.drag(find.byType(OneScreenReport), const Offset(-400, 0));
      await tester.pump();
      await tester.pump();

      expect(find.byType(DeviceHistoryTab), findsNothing,
          reason: 'a swipe must not switch tabs, and must not mount history');
    });
  });

  // ===========================================================================
  // 🔑 R1–R2: the refresh button (owner ruling 2026-08-16).
  //
  // 🔴 What this fixes is NOT the 30 s cache TTL. The section has no timer and
  // no listener — it queries on mount, on `deviceId` change, and on range
  // change, and nothing else. Sit on a device page while it charges and it
  // shows the snapshot it took when you arrived, cache or no cache. Setting
  // `kDeviceHistoryCacheTtl` to zero would not have changed that; only an
  // explicit re-query does, which is why these tests assert new ROWS appear
  // rather than asserting anything about the cache.
  // ===========================================================================
  group('R: the refresh button', () {
    testWidgets('R1: it re-queries and picks up rows written since mount',
        (tester) async {
      await boot(tester);
      await addRows(tester, 'A', 12.6, count: 3, startSlot: 1);
      await pumpSection(tester, deviceId: 'A', live: false);
      final before = debugDeviceHistoryQueries;
      expect(before, greaterThan(0), reason: 'it queried once on mount');

      // A row lands while the user is looking at the page.
      await addRows(tester, 'A', 12.4, count: 3, startSlot: 30);
      await tester.pump();
      expect(debugDeviceHistoryQueries, before,
          reason: 'nothing re-queries on its own — this is the gap R1 closes');

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      // Same three chained reads as `pumpSection` — they need the real loop.
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(debugDeviceHistoryQueries, greaterThan(before),
          reason: 'the button must bypass the P-4 cache, not just setState');
    });

    testWidgets('R2: the target is at least 40x40 dp', (tester) async {
      // Measured, not asserted-to-exist — FB-70 was a working feature behind a
      // 14×14 dp hit box. The default IconButton is 48, but a later
      // `visualDensity` change would shrink it silently and nothing else here
      // would notice.
      await boot(tester);
      await addRows(tester, 'A', 12.6, count: 2, startSlot: 1);
      await pumpSection(tester, deviceId: 'A', live: false);
      final size = tester.getSize(find.ancestor(
          of: find.byIcon(Icons.refresh),
          matching: find.byType(IconButton)));
      expect(size.width, greaterThanOrEqualTo(40.0));
      expect(size.height, greaterThanOrEqualTo(40.0));
    });
  });

  // ==========================================================================
  // FB-85 — a curve it cannot draw must not withhold the numbers.
  //
  // 🔴 Found while fixing this file's own time-zone flakiness (2026-08-17): the
  // stats strip was the LAST CHILD of `HistoryTrendCard.build`, below a
  // `buckets.length < 2` early return, so a unit holding a whole night of
  // readings could show one sentence and no number at all. A chart point is
  // `historyChartBucketMs` wide; `HistoryStats` is one aggregate over the range
  // and needs no bucket — two different questions that shared one guard.
  // ==========================================================================
  group('FB-85 — too short to chart still reports what it has', () {
    testWidgets('rows inside ONE bucket: no curve, but the numbers are there',
        (tester) async {
      // Reachable at any hour — a link that came up seconds ago. (The other way
      // in is the first minute after LOCAL midnight, when "today" is shorter
      // than the 1-minute bucket floor; that one needs the clock, this one does
      // not, and both run the same code path.)
      await boot(tester);
      await tester.runAsync(() async {
        final now = DateTime.now();
        for (var i = 0; i < 3; i++) {
          await services.historyRepo.insertSample(
            TelemetrySample(
              timestamp: now.subtract(Duration(milliseconds: 300 * i)),
              pvlt: 13.42,
              temperatureC: 30,
              mode: ReportedStatus.normal,
            ),
            deviceId: 'A',
          );
        }
      });
      await pumpSection(tester, deviceId: 'A', live: false);

      // It still says the curve is not drawable — that part was never wrong.
      expect(find.textContaining('chart'), findsWidgets);
      // 🔑 And this is FB-85: the aggregate it already had is on screen.
      expect(showsVoltage(13.42), isTrue,
          reason: 'a night of readings withheld because the curve could not be '
              'drawn is the defect — the strip needs no bucket');
      expect(find.textContaining('30°C'), findsWidgets);
    });

    testWidgets('but a card with NOTHING shows no strip of dashes', (
      tester,
    ) async {
      // The guard is `stats.count`, not `buckets.isEmpty` — otherwise the fix
      // above would paint "--  --  --" at every never-recorded unit, which is
      // worse than the sentence alone.
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(
          body: HistoryTrendCard(
            buckets: [],
            stats: HistoryStats.empty,
            tempUnit: TempUnit.celsius,
            multiDay: false,
            bucketMs: 60000,
          ),
        ),
      ));
      await tester.pump();

      expect(find.textContaining('--'), findsNothing);
    });

    testWidgets('the copy no longer claims a record count it does not mean', (
      tester,
    ) async {
      // 🔴 It read "need at least 2 records", which is false: at second
      // resolution three minutes is ~180 rows and it still cannot chart. What
      // is short is the SPAN, and telling someone to go and collect more
      // readings is the wrong instruction — the same defect class as FB-44's
      // "connection failed, please try again".
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(
          body: HistoryTrendCard(
            buckets: [],
            stats: HistoryStats.empty,
            tempUnit: TempUnit.celsius,
            multiDay: false,
            bucketMs: 60000,
          ),
        ),
      ));
      await tester.pump();

      expect(find.textContaining('records'), findsNothing);
      expect(find.textContaining('span'), findsOneWidget);
    });
  });
  // ==========================================================================
  // T79-12 — the two surfaces have ONE derivation of the three queries.
  //
  // 🔴 **This is design 0065 §6 R5 finally becoming structural.** Until
  // 2026-08-21 it was held off by a comment in each `_load` saying "the same
  // three, in the same order, with the same arguments as the other one" —
  // discipline, and discipline is what a comment can buy. The owner ruled on
  // Q5 to consolidate; this test is what stops the split growing back.
  //
  // A SOURCE-level check, and deliberately so: the failure it guards against
  // is not a wrong pixel or a wrong number, it is one surface quietly acquiring
  // its own copy of the queries. That produces no error and no visible
  // difference until the day the two copies disagree — and by then whichever
  // one is wrong has been shipping for weeks.
  // ==========================================================================
  group('T79-12 — one derivation of the three queries (Q5)', () {
    const surfaces = <String>[
      'lib/ui/history/history_screen.dart',
      'lib/ui/history/device_history_tab.dart',
    ];

    test('neither surface issues the three itself', () {
      for (final path in surfaces) {
        final src = File(path).readAsStringSync();
        expect(src.contains('loadHistorySlice('), isTrue,
            reason: '$path must go through the shared loader');
        for (final q in ['historyStats(', 'historyBuckets(', 'historyListBuckets(']) {
          expect(src.contains(q), isFalse,
              reason: '$path calls `$q` directly. That is the split design '
                  '0079 S4 closed: the order matters (the chart bucket width '
                  'is derived from `stats.firstAt` on the "all" range), and so '
                  'does `kHistoryRowCap` — two surfaces loading different '
                  'amounts of one unit is design 0065 §6 R5 in its purest '
                  'form. Add it to `loadHistorySlice` instead.');
        }
      }
    });

    test('and the chart frames itself from one place', () {
      // The smaller half of the same rule. `heading` and `multiDay` are one
      // decision — "is this chart about today, or about a span of days" — and
      // it used to be made four lines apart in two files. A surface that
      // titled a multi-day chart "Today's" while plotting it as multi-day
      // would have been wrong in a way nothing was watching for.
      for (final path in surfaces) {
        expect(File(path).readAsStringSync().contains('historyChartFraming('),
            isTrue,
            reason: '$path must not re-derive the chart heading');
      }
    });
  });

  // ==========================================================================
  // T79-10 — the badge on the history tab (design 0079 Q3).
  // ==========================================================================
  group('T79-10 — the tab label says whether there is anything in there', () {
    testWidgets('a unit with rows shows the count, grouped', (tester) async {
      // 🔑 **This is the answer to the objection that killed the cheap fix.**
      // Design 0065 §4 rejected "a button that jumps to the History tab"
      // partly because 「他得先跳過去才知道是空的」 — you have to go there to
      // find out it is empty. A tab has the same flaw unless the label speaks.
      await boot(tester);
      await addRows(tester, unitA, vA, count: 3);
      await tester.runAsync(
          () => services.devices.saveNew(unitA, 'Cap #1', name: 'RCE-SCAP_II'));

      await pumpDetailPage(tester);

      expect(find.text('3'), findsOneWidget,
          reason: 'the figure is on the label before the tab is ever opened');
    });

    testWidgets('a unit with NOTHING shows 0 — not a blank', (tester) async {
      // 🔴 `0` is the answer, not the absence of one. A bare label would leave
      // "has this unit ever recorded?" exactly as unanswered as it was before
      // design 0079, which is the whole point of the badge.
      await boot(tester);
      await tester.runAsync(
          () => services.devices.saveNew(unitA, 'Cap #1', name: 'RCE-SCAP_II'));

      await pumpDetailPage(tester);

      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('the badge costs ONE count query, not the tab\'s three',
        (tester) async {
      // CATCHES: the badge being wired to the tab's loader, which would undo
      // T79-2 (nothing is queried until the tab is opened) by the back door —
      // and it would do it invisibly, because the screen looks identical.
      await boot(tester);
      await addRows(tester, unitA, vA, count: 3);
      await tester.runAsync(
          () => services.devices.saveNew(unitA, 'Cap #1', name: 'RCE-SCAP_II'));
      final spyBle = _StubBle();
      final spy = _CountingTelemetry(spyBle,
          settings: services.settings,
          history: services.historyRepo,
          logs: services.logRepo);
      addTearDown(() async {
        spy.dispose();
        await spyBle.dispose();
      });

      await pumpDetailPage(tester, telemetry: spy);

      expect(spy.stats, 1, reason: 'one aggregate, for the badge');
      expect(spy.buckets, 0, reason: 'no chart is being drawn');
      expect(spy.listBuckets, 0, reason: 'and certainly no thousand rows');
    });

    testWidgets('an unknown count renders NO badge, never a 0', (tester) async {
      // 🔴 **Unknown and zero are different facts.** A `0` shown while the
      // count is in flight — or after it failed — tells the user the history
      // is empty, and they believe it and do not look. The page keeps
      // `_historyCount` null in both cases and the label stays bare.
      //
      // The "in flight" state is produced by a controller that never answers,
      // rather than by refusing to let the future resolve: see
      // [_NeverStatsTelemetry] for why that distinction cost a red run.
      await boot(tester);
      await addRows(tester, unitA, vA, count: 3);
      await tester.runAsync(
          () => services.devices.saveNew(unitA, 'Cap #1', name: 'RCE-SCAP_II'));
      final mute = _StubBle();
      final tele = _NeverStatsTelemetry(mute,
          settings: services.settings,
          history: services.historyRepo,
          logs: services.logRepo);
      addTearDown(() async {
        tele.dispose();
        await mute.dispose();
      });

      await pumpDetailPage(tester, telemetry: tele);

      expect(find.text('History'), findsOneWidget, reason: 'the tab is there');
      expect(find.text('0'), findsNothing,
          reason: 'an unresolved count must not be dressed up as "empty"');
      expect(find.text('3'), findsNothing);
    });
  });

  // ==========================================================================
  // T79-6 … T79-9 — what S2 added: the lazy list, the drill-down, and the
  // thresholds going back to work.
  // ==========================================================================
  group('T79 — the list', () {
    testWidgets('T79-6 — the list is lazy: far fewer rows inflate than loaded',
        (tester) async {
      // 🔴 **The whole technical justification for design 0079 in one number.**
      // design 0065 §0.8.1 measured the same 1,000 rows two ways: as ONE child
      // of a host `ListView` (the block's old shape) ~3,030 elements, and as
      // direct slivers ~417. That gap is why the row list was deleted on
      // 2026-08-16 and why it can come back now.
      //
      // ⚠️ **Two things about this test were got wrong first, and both are
      // worth leaving written down.**
      //
      // ① It seeded with `addRows(count: 1000)` and asserted a total element
      //    ceiling. `addRows` spreads its rows across *the elapsed part of
      //    today* — deliberately, see its own long comment — and the list
      //    groups by MINUTE, so the number of display rows is a function of the
      //    WALL CLOCK. Run at 00:47 it produced **47 rows**, and 47 rows do not
      //    breach any sane element ceiling however eagerly they are built. The
      //    test passed against a deliberately broken build.
      // ② The element ceiling is the wrong instrument anyway. It measures the
      //    whole tree, so it drowns the signal in shell.
      //
      // What is pinned instead is laziness DIRECTLY: fewer `HistoryRow`
      // elements exist than there are rows loaded. Seeded at a fixed
      // one-minute spacing over the `all` range so the count is the tester's,
      // not the clock's.
      const seeded = 400;
      await boot(tester);
      await tester.runAsync(() async {
        final now = DateTime.now();
        for (var i = 0; i < seeded; i++) {
          await services.historyRepo.insertSample(
            TelemetrySample(
              timestamp: now.subtract(Duration(minutes: i + 1)),
              pvlt: vA,
              temperatureC: 30,
              mode: ReportedStatus.normal,
            ),
            deviceId: unitA,
          );
        }
      });
      await pumpSection(tester, deviceId: unitA, live: false);
      // `all`, because 400 minutes back from "now" crosses local midnight and
      // the default range would silently drop most of them — the same trap as
      // ① above, one layer down.
      await tester.tap(find.text('All'));
      await tester.pump();
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();

      final inflated = find.byType(HistoryRow).evaluate().length;
      expect(inflated, greaterThan(0), reason: 'the list is drawn at all');
      expect(inflated, lessThan(seeded ~/ 2),
          reason: '🔴 lazy: the element count tracks the VIEWPORT, not the '
              '$seeded rows behind it. Verified by mutation — putting the rows '
              'in one `SliverToBoxAdapter(child: Column(...))` inflates all of '
              'them and turns this red.');
    });

    testWidgets('T79-7 — tapping a minute opens its seconds (FB-90)',
        (tester) async {
      // design 0074 shipped this on the History TAB in v0.7.28. The detail page
      // could not have it because it had no list to tap — which is half of why
      // design 0079 exists. Nothing here is new code; it is the same sheet.
      await boot(tester);
      await addRows(tester, unitA, vA);
      await pumpSection(tester, deviceId: unitA, live: false);

      await tester.tap(find.byType(HistoryRow).first);
      // ⚠️ **NOT `pumpAndSettle`** — `history_second_drilldown_test.dart:391`
      // already records why, and I re-discovered it the expensive way: the
      // sheet shows a `CircularProgressIndicator` while its query runs, and an
      // indeterminate spinner schedules frames forever, so settling on it is a
      // timeout rather than a pass. The `runAsync` is the other half: the query
      // is real file I/O and the widget-test zone's clock is fake, so without
      // it the future the sheet waits on never completes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump();

      // 🔑 The sheet's own copy, not `find.byType(BottomSheet)` — a modal
      // sheet is pushed as a ROUTE, and the type finder does not reach it.
      // "Seconds in <time>" is `historySecondsSheetTitle`, which every
      // drill-down renders whether or not the minute has seconds in it.
      expect(find.textContaining('Seconds in'), findsOneWidget,
          reason: 'every row opens the drill-down, including minutes with no '
              'seconds in them — design 0074 Q3');
    });

    testWidgets('T79-8 — connected: rows are judged by THIS unit\'s limits',
        (tester) async {
      // 🔵 `ov`/`uv`/`ot` back at work — owner ruling 2026-08-21. Between
      // 2026-08-16 and today nothing read them, and design 0079 proposed
      // deleting them. This is the test that would have gone red if it had.
      await boot(tester);
      // A row far above any plausible over-voltage limit.
      await addRows(tester, unitA, 15.9, count: 3);
      await connectTo(tester, unitA);
      // 🔴 The thresholds come off the WIRE, so a link with no sample on it has
      // none and every row classifies `normal`. Emitting one is what makes this
      // test about the gate rather than about the stub.
      //
      // 🔵 **`deviceType` added 2026-08-22 (design 0080 P2).** The sample used
      // to carry `warnOv` and nothing else, and it passed because the tab read
      // that field directly. It now resolves through `resolveThresholds()`,
      // whose FIRST act is the device-level gate: a unit whose class nothing has
      // established is not watched at all (§7.5.6 C-2), because 14.0 V is not a
      // limit until we know what kind of hardware is reporting it. A real link
      // always answers `0x10` — this is the stub catching up with the wire, not
      // the rule being worked around.
      await tester.runAsync(() async {
        ble.emitTelemetry(TelemetrySample(
          timestamp: DateTime.now(),
          deviceType: 0x02,
          pvlt: 13.0,
          warnOv: 14.0,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      await pumpSection(tester, deviceId: unitA, live: true);

      final rows = tester.widgetList<HistoryRow>(find.byType(HistoryRow));
      expect(rows, isNotEmpty);
      expect(rows.map((r) => r.status), contains(HistoryRowStatus.warning),
          reason: 'with the link up, the wire thresholds classify the rows');
    });

    testWidgets('T79-9 — offline: no thresholds, and no clean bill of health',
        (tester) async {
      // 🔴 **FB-41's shape in a third column** (design 0065 §3.2.2, carried
      // forward by design 0079 §0.3). `warnOv`/`warnUv`/`warnOt` belong to the
      // unit the PHONE is holding. On unit A's page while the phone holds B,
      // ungated, they would judge A's stored rows against B's limits.
      //
      // 🔑 The distinction this pins is subtle and worth stating: the rows are
      // not "fine", they are UNJUDGED. Same pixels, different claim — which is
      // why the withheld case must never be dressed up as a pass.
      await boot(tester);
      await addRows(tester, unitA, 15.9, count: 3);
      // Unit B is the one on the link; A is merely the page being looked at.
      await addRows(tester, unitB, vB);
      await connectTo(tester, unitB);
      await pumpSection(tester, deviceId: unitA, live: false);

      final rows = tester.widgetList<HistoryRow>(find.byType(HistoryRow));
      expect(rows, isNotEmpty);
      expect(rows.map((r) => r.status),
          isNot(contains(HistoryRowStatus.warning)),
          reason: 'B\'s limits may not be applied to A\'s rows');
    });

    testWidgets(
        '🔵 T79-11 (design 0080) — offline, THIS unit\'s own limit still judges',
        (tester) async {
      // 🔑 **What P2 GAINED, and the other half of T79-9.** That test pins that
      // another unit's limits never arrive; this one pins that the page's own
      // do, with the radio off. Before design 0080 the thresholds were read off
      // the live sample, so "not connected" and "no limits" were the same state
      // and an offline unit's rows could never be coloured at all — which is
      // precisely the unit a dealer reads (design 0065 Q4).
      //
      // The limit here comes from LAYER ① (`saved_devices.alert_uv`), which
      // needs no link, and B is on the wire with limits that would classify
      // these rows differently — so a regression to the ambient read shows up
      // as the wrong colour rather than as no colour.
      await boot(tester);
      await addRows(tester, unitA, vA, count: 3); // 12.34 V
      await tester.runAsync(() => services.devices.save(const SavedDevice(
            id: unitA,
            alias: 'A',
            productClass: ProductClass.smartBattery,
            alertUv: 12.8,
          )));
      await addRows(tester, unitB, vB);
      await connectTo(tester, unitB);
      await pumpSection(tester, deviceId: unitA, live: false);

      final rows = tester.widgetList<HistoryRow>(find.byType(HistoryRow));
      expect(rows, isNotEmpty);
      expect(rows.map((r) => r.status), contains(HistoryRowStatus.warning),
          reason: 'the owner asked to be told below 12.8 V, and 12.34 is below '
              'it — no link required to know that');
    });
  });

  // ==========================================================================
  // T79-S0 — ~~two queries, not three~~ ⇒ **one of each, and nothing spare**
  //
  // 🔵 **Rewritten 2026-08-21 (design 0079 S2), not deleted.** S0 pinned that
  // `historyListBuckets` was NOT issued, and that pin was right for the five
  // days it stood: nothing drew a list, so a thousand minute windows were being
  // fetched to answer one `rows.isEmpty`.
  //
  // The rule underneath was never "never fetch the list" — it was **do not
  // fetch what you do not draw**. S2 draws it, so the assertion becomes the
  // one that still says something: each load makes ONE of each query. That
  // catches the duplicate-fetch shape (a stray second call, a load fired twice
  // by two paths) which is what would actually go wrong now.
  //
  // ⚠️ The empty-state half of S0 is unchanged and is asserted below: the gate
  // is `HistoryStats.count`, never the row list.
  // ==========================================================================
  group('T79-S0 — one of each query, and the empty gate is stats.count', () {
    /// Build a controller that counts, over its own stub radio, and hand it to
    /// the block instead of the app's.
    _CountingTelemetry spyFor(WidgetTester tester) {
      final spyBle = _StubBle();
      final spy = _CountingTelemetry(
        spyBle,
        settings: services.settings,
        history: services.historyRepo,
        logs: services.logRepo,
      );
      addTearDown(() async {
        spy.dispose();
        await spyBle.dispose();
      });
      return spy;
    }

    testWidgets('one load ⇒ one of each query', (tester) async {
      // CATCHES: a query issued twice per load — the shape that hid for five
      // days when design 0065 §0.9 announced `historyListBuckets` had been
      // dropped and it had not been. Nothing on screen changes when a query is
      // made and thrown away, so no rendered assertion can see it; only a
      // counter can.
      await boot(tester);
      await addRows(tester, unitA, vA);
      final spy = spyFor(tester);

      await pumpSection(
          tester, deviceId: unitA, live: false, telemetry: spy);

      expect(spy.stats, 1, reason: 'the range aggregate');
      expect(spy.buckets, 1, reason: 'the chart buckets');
      expect(spy.listBuckets, 1,
          reason: 'the row list — fetched because design 0079 S2 draws it');
      expect(find.byType(HistoryRow), findsWidgets,
          reason: '🔴 the other half of the rule: what is fetched is DRAWN. '
              'Without this, the assertion above would be satisfied by the '
              'exact waste S0 removed.');
    });

    testWidgets('and the empty state still knows it is empty', (tester) async {
      // The reverse pin. `stats.count` replaced `rows.isEmpty` as the gate, so
      // a unit with nothing must still say so — otherwise S0 bought a query at
      // the price of a blank card that claims to be a chart.
      await boot(tester);
      final spy = spyFor(tester);

      await pumpSection(
          tester, deviceId: unitA, live: false, telemetry: spy);

      // Default range is `today`, so this is `historyEmptyDeviceRange`; the
      // matched prefix is shared with `deviceHistoryEmpty`, so the assertion
      // survives a range change without pinning which sentence appears.
      expect(find.textContaining('No records for this device'), findsOneWidget,
          reason: 'the "nothing here" copy, not an empty chart card');
    });

    testWidgets('a unit inside ONE chart bucket is not called empty',
        (tester) async {
      // 🔴 The half of the old gate that was load-bearing and is NOT the row
      // list: `count == 0 && chartEmpty`. Rows too close together to make two
      // chart points leave `buckets.length < 2` — and FB-85 ruled that such a
      // unit must still report its numbers. Had S0 dropped the `&& chartEmpty`
      // conjunct, or gated on buckets alone, this unit would read as having no
      // records at all.
      await boot(tester);
      // Three rows within a few seconds ⇒ one chart bucket at any hour.
      await tester.runAsync(() async {
        final now = DateTime.now();
        for (var i = 0; i < 3; i++) {
          await services.historyRepo.insertSample(
            TelemetrySample(
              timestamp: now.subtract(Duration(seconds: i)),
              pvlt: vA,
              temperatureC: 30,
              mode: ReportedStatus.normal,
            ),
            deviceId: unitA,
          );
        }
      });
      final spy = spyFor(tester);

      await pumpSection(
          tester, deviceId: unitA, live: false, telemetry: spy);

      expect(find.textContaining('No records for this device'), findsNothing,
          reason: 'it HAS records — it just cannot be drawn as a curve');
      expect(showsVoltage(vA), isTrue,
          reason: 'FB-85: the stats strip reports what the range holds');
    });
  });
}
