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
import 'package:open_smart_batt/ui/history/device_history_section.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
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
    debugDeviceHistoryBodyBuilds = 0;
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
              value: services.telemetry),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: Scaffold(
            body: ListView(
              children: [
                DeviceHistorySection(deviceId: deviceId, live: live),
              ],
            ),
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

      expect(find.byType(DeviceHistorySection), findsOneWidget);
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

      expect(find.byType(DeviceHistorySection), findsOneWidget);
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
  group('P-2′ memoisation', () {
    testWidgets(
        '🔴 T65-4b — 20 telemetry samples rebuild the body ZERO extra times',
        (tester) async {
      // CATCHES: the memoised subtree being dropped, or the block being
      // switched to `context.watch<TelemetryController>()`. Either one puts up
      // to 1,000 list rows on the ~4.7 Hz telemetry rebuild path. The symptom
      // is not a crash and not an error — it is heat and dropped frames on the
      // phones least able to absorb them, which is why a counter is the only
      // witness that can see it (design 0065 §6 R2).
      await boot(tester);
      await addRows(tester, unitA, vA);
      await connectTo(tester, unitA);
      await pumpSection(tester, deviceId: unitA, live: true);

      final before = debugDeviceHistoryBodyBuilds;
      expect(before, greaterThan(0), reason: 'it did build once');

      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() async {
          ble.emitTelemetry(TelemetrySample(
              timestamp: DateTime.now(), pvlt: vA, temperatureC: 30));
          await Future<void>.delayed(const Duration(milliseconds: 5));
        });
        await tester.pump();
      }

      expect(debugDeviceHistoryBodyBuilds, before,
          reason: 'a telemetry sample changes nothing this block renders, so '
              'it must not cost a rebuild of it');
    });

    testWidgets('T65-4c — but a change the user CAN see still gets through',
        (tester) async {
      // 🔴 The reverse pin, and the more dangerous direction of the two. A
      // cache key that is too WIDE freezes the block on stale data, and a
      // frozen-but-plausible screen is far harder to notice than a rebuild.
      // Three inputs, three ways in: a setting, the range control, the filter.
      await boot(tester);
      await addRows(tester, unitA, vA, temp: 30);
      await pumpSection(tester, deviceId: unitA, live: false);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      // (a) a SETTING changed elsewhere — the easiest one to leave out of the
      //     key, because the user changes it on another screen and walks back.
      expect(find.textContaining('30°C'), findsWidgets);
      await tester.runAsync(
          () => services.settings.setTempUnit(TempUnit.fahrenheit));
      await tester.pump();
      expect(find.textContaining('86°F'), findsWidgets,
          reason: '`tempUnit` is missing from the memo key');
      expect(find.textContaining('30°C'), findsNothing);

      // (b) the range control.
      final buildsBeforeRange = debugDeviceHistoryBodyBuilds;
      await tester.tap(find.text(l10n.historyRangeWeek));
      await tester.pump();
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(debugDeviceHistoryBodyBuilds, greaterThan(buildsBeforeRange));
      // CardHeading upper-cases what it is given.
      expect(find.text(l10n.historyChartTitle.toUpperCase()), findsOneWidget,
          reason: 'a multi-day range retitles the chart');

      // ~~(c) the warnings filter.~~ 🔴 Removed 2026-08-16 with the filter
      // itself (owner ruling). The two cases above still cover what this test
      // is for — that the P-2′ memo lets a user-visible change through — and
      // they exercise the two remaining kinds of key: a settings value
      // (`tempUnit`) and a state field (`_range`).
    });
  });

  // ==========================================================================
  // T65-13 — what the block is allowed to claim when it is offline.
  // ==========================================================================

  // ==========================================================================
  // T65-12 — the two surfaces must agree about one unit.
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
      final now = DateTime(2026, 8, 16, 12);
      // A minute floor, whatever the span.
      expect(historyChartBucketMs(now, now: now), kHistoryListBucketMs);
      expect(
          historyChartBucketMs(now.subtract(const Duration(minutes: 30)),
              now: now),
          kHistoryListBucketMs);
      // ~180 points across the span, once the span is wide enough for it.
      expect(
          historyChartBucketMs(now.subtract(const Duration(hours: 24)),
              now: now),
          (24 * 3600000) ~/ kHistoryTargetBucketPoints);
      // …and a day-wide ceiling.
      expect(
          historyChartBucketMs(now.subtract(const Duration(days: 3650)),
              now: now),
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
      final expected = historyChartBucketMs(since ?? stats!.firstAt);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final minutes = (expected / 60000).round();
      expect(find.text(l10n.historyChartBucketMinutes(minutes)), findsOneWidget);
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
  // T65-11 — all FIVE mount points, not just the easy two.
  // ==========================================================================
  group('T65-11 — every route the detail page can take carries the block', () {
    // CATCHES: shipping only the pack routes — which is what the design's own
    // first draft proposed before the owner ruled for all four (Q3) — or a
    // later refactor quietly dropping the two short-lived states, which are
    // the easiest to forget precisely because they are brief.
    //
    // 📌 The short-lived routes are NOT empty shells: `history.device_id` is
    // written from the session, never from the product class, so an
    // unclassified or still-identifying unit has ordinary readable rows.
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

    testWidgets('pack (battery / capacitor)', (tester) async {
      await boot(tester);
      await addRows(tester, unitA, vA);
      await pumpRoute(tester, const PackView(deviceId: unitA));
      expect(find.byType(DeviceHistorySection), findsOneWidget);
      expect(showsVoltage(vA), isTrue, reason: 'and it actually queried');
    });

    testWidgets('power bank', (tester) async {
      await boot(tester);
      await addRows(tester, unitA, vA);
      await pumpRoute(tester, const PowerBankView(deviceId: unitA));
      expect(find.byType(DeviceHistorySection), findsOneWidget);
      expect(showsVoltage(vA), isTrue);
    });

    testWidgets('unidentified — a RESTING state, and it has rows',
        (tester) async {
      await boot(tester);
      await addRows(tester, unitA, vA);
      await pumpRoute(tester, const UnidentifiedView(deviceId: unitA));
      expect(find.byType(DeviceHistorySection), findsOneWidget);
      expect(showsVoltage(vA), isTrue);
    });

    testWidgets('class pending', (tester) async {
      await boot(tester);
      await addRows(tester, unitA, vA);
      // The view draws nothing at all inside its grace window, deliberately —
      // so the block is asserted on the state where the view has content.
      final stalled = _StalledConn(ble, settings: services.settings);
      addTearDown(stalled.dispose);
      await pumpRoute(
        tester,
        ChangeNotifierProvider<ConnectionController>.value(
          value: stalled,
          child: const ClassPendingView(deviceId: unitA),
        ),
      );
      expect(find.byType(DeviceHistorySection), findsOneWidget);
      expect(showsVoltage(vA), isTrue);
    });

    testWidgets('and the offline body, which is the whole point (Q4)',
        (tester) async {
      await boot(tester);
      await addRows(tester, unitA, vA);
      await tester.runAsync(
          () => services.devices.saveNew(unitA, 'Cap #1', name: 'RCE-SCAP_II'));
      await pumpRoute(
        tester,
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GpsSpeedController>.value(
                value: services.speed),
          ],
          child: const DeviceDetailPage(deviceId: unitA),
        ),
      );
      expect(find.byType(DeviceHistorySection), findsOneWidget);
      expect(showsVoltage(vA), isTrue);
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

}
