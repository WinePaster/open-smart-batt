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

  /// Rows are minutes apart so each lands in its own display window.
  Future<void> addRows(WidgetTester tester, String deviceId, double pvlt,
          {int count = 3, int? temp = 30, int? mode, int fromMinute = 1}) =>
      tester.runAsync(() async {
        final now = DateTime.now();
        for (var i = 0; i < count; i++) {
          await services.historyRepo.insertSample(
            TelemetrySample(
              timestamp: now.subtract(Duration(minutes: fromMinute + i)),
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

      // (c) the warnings filter.
      final buildsBeforeFilter = debugDeviceHistoryBodyBuilds;
      await tester.tap(find.text(l10n.historyFilterWarning));
      await tester.pump();
      expect(debugDeviceHistoryBodyBuilds, greaterThan(buildsBeforeFilter));
    });
  });

  // ==========================================================================
  // T65-13 — what the block is allowed to claim when it is offline.
  // ==========================================================================
  group('the warnings filter never over-claims', () {
    testWidgets('🔴 T65-13 — offline, an empty filter result says WHY',
        (tester) async {
      // CATCHES: reusing the History tab's `historyEmptyWarning` here. That
      // sentence is already careful about one thing — it counts only the rows
      // it loaded — but on this page there is a SECOND thing it has not seen:
      // the over-voltage / under-voltage / over-temperature limits come off the
      // live wire, and there is no wire. An unqualified "no warnings" would be
      // an all-clear nobody checked.
      await boot(tester);
      await addRows(tester, unitA, vA, count: 3);
      await pumpSection(tester, deviceId: unitA, live: false);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      await tester.tap(find.text(l10n.historyFilterWarning));
      await tester.pump();

      expect(find.text(l10n.deviceHistoryEmptyWarningOffline(3)), findsOneWidget);
      expect(find.text(l10n.historyEmptyWarning(3)), findsNothing,
          reason: 'the History tab\'s wording omits the missing thresholds');
      // …and the sentence actually carries the qualification, so the assertion
      // above cannot be satisfied by changing the l10n string to the same text.
      expect(l10n.deviceHistoryEmptyWarningOffline(3).toLowerCase(),
          contains('not connected'));
    });

    testWidgets('offline still shows device-reported EVENTS', (tester) async {
      // Losing the wire loses the `warning` class ONLY. A cut-off is a status
      // code the device itself recorded, and it survives — which is why
      // `historyClassifyRow` must keep classifying `event` with null
      // thresholds.
      await boot(tester);
      await addRows(tester, unitA, vA,
          count: 2, mode: ReportedStatus.cutOffActive);
      await pumpSection(tester, deviceId: unitA, live: false);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      await tester.tap(find.text(l10n.historyFilterWarning));
      await tester.pump();

      expect(find.text(l10n.historyStatusEvent), findsWidgets,
          reason: 'a cut-off is the device speaking, not a threshold we set');
    });
  });

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
  group('the list renders in slices', () {
    testWidgets('a long list starts short and says how much is left',
        (tester) async {
      // 1,000 rows in a Column inflate 24,207 elements (measured 2026-08-16,
      // `T65-4` M4) — over the plan's own 8,000 "must be lazy" line. Unlike the
      // History tab, this block is built on EVERY detail-page open. The slice
      // is the one retreat that touches neither the scroll skeleton (Q6, the
      // owner's to rule) nor the row cap (which would make the two surfaces
      // disagree about how much they loaded).
      await boot(tester);
      await addRows(tester, unitA, vA, count: kDeviceHistoryInitialRows + 30);
      await pumpSection(tester, deviceId: unitA, live: false);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.byType(HistoryRow), findsNWidgets(kDeviceHistoryInitialRows));
      expect(find.text(l10n.deviceHistoryShowMore(30)), findsOneWidget,
          reason: 'a "show more" that does not say how much is left could be '
              'a button that does nothing');

      // 60 rows put the button well below the fold; a tap on an off-screen
      // widget lands nowhere.
      await tester.ensureVisible(find.text(l10n.deviceHistoryShowMore(30)));
      await tester.pump();
      await tester.tap(find.text(l10n.deviceHistoryShowMore(30)));
      await tester.pump();
      expect(find.byType(HistoryRow),
          findsNWidgets(kDeviceHistoryInitialRows + 30));
      expect(find.textContaining('Show'), findsNothing,
          reason: 'nothing left to show');
    });

    testWidgets('a short list has no button at all', (tester) async {
      await boot(tester);
      await addRows(tester, unitA, vA, count: 3);
      await pumpSection(tester, deviceId: unitA, live: false);
      expect(find.byType(HistoryRow), findsNWidgets(3));
      expect(find.textContaining('Show'), findsNothing);
    });
  });

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

    // 🔴 A minute of its own. A row sharing a display window with an existing
    // one would be AVERAGED into it, and neither voltage would appear — which
    // would make this test pass for the wrong reason.
    await addRows(tester, unitA, 9.87, count: 1, fromMinute: 30);

    // 🔴 And the widget really has to be DESTROYED, not merely rebuilt.
    // Re-pumping the same tree keeps the State — and therefore the already
    // resolved future — so a test that skipped this would be pinning State
    // preservation while believing it was pinning the cache.
    Future<void> remount(bool live) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await pumpSection(tester, deviceId: unitA, live: live);
    }

    await remount(true);
    expect(showsVoltage(vA), isTrue);
    expect(showsVoltage(9.87), isFalse,
        reason: 'served from the P-4 cache — a re-query would have found the '
            'row written since');

    debugClearDeviceHistoryCache();
    await remount(true);
    expect(showsVoltage(9.87), isTrue,
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
}
