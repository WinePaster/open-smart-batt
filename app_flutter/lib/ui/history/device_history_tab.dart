/// OpenSmartBatt — the "History" half of a device's detail page (design 0079).
///
/// ## Why it is a tab and not a block
///
/// Until 2026-08-21 this unit's history was a BLOCK appended to the bottom of
/// whatever the detail page happened to be showing — five hosts, four dashboard
/// routes plus the offline failure report (design 0065 §3.3). It shipped in
/// `v0.7.21` and it answered FB-78. What it could not do was grow:
///
///  * the per-minute list was removed on 2026-08-16 because a thousand rows
///    inside ONE child of somebody else's `ListView` inflate ~3,030 elements
///    (the same rows as direct slivers: ~417 — design 0065 §0.8.1, measured
///    twice, by two people);
///  * so when the History TAB gained a minute-to-seconds drill-down four days
///    later (FB-90 / design 0074), the detail page had no list to hang it on.
///
/// The detail page had become strictly weaker than the surface the dealer
/// complained about having to go to. Design 0079 moved it to a tab, which is
/// what makes this file a scroll container in its own right.
///
/// 🔑 **Design 0065 §0.8.2 licensed exactly this**, in as many words: its
/// argument against slivers is scoped to "this component, on these five hosts",
/// and ends "the next person doing a full-screen list page — its own scroll
/// container, no parasite problem — none of the above applies".
///
/// ## The red lines that survived the move (design 0065 §3.1)
///
/// 1. 🔴 **[DeviceHistoryTab.deviceId] comes from the caller. This widget never
///    asks [ConnectionController] or [TelemetryController] which unit is live.**
///    "The unit being looked at" and "the unit on the link" are different
///    questions, and answering the first with the second is how FB-41 / FB-42
///    filed one unit's telemetry under another's.
/// 2. 🔴 **It never `watch`es [TelemetryController].** Everything it needs from
///    there is a one-shot call; watching would subscribe it to a notify that
///    fires on every telemetry sample — ~4.7 Hz on a live link.
///
/// ## What it still does NOT take from the History tab (§3.2.3)
///
///  * **the device picker** — the scope is fixed by the page it sits on, and a
///    dropdown that cannot change anything is a control that only explains
///    itself after the fact (design 0046 §4.7);
///  * **the whole-database row-count footer** — that number counts EVERY unit;
///    on one unit's page a reader would take it for this unit's total;
///  * **pull-to-refresh** — ⚠️ the old reason ("it lives in somebody else's
///    scroll view") EXPIRED with design 0079: this is a `CustomScrollView` and
///    could take the gesture. It is still not taken, for a different reason:
///    the range row already carries a refresh button (design 0065 R-refresh),
///    and two mechanisms for one action is how they drift apart.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../data/history_repo.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../util/export_scope.dart';
import '../util/history_csv_export.dart';
import '../widgets/industrial.dart';
import 'history_screen.dart';
import 'minute_seconds_sheet.dart';

// ---------------------------------------------------------------------------
// 📏 Element counts — the measurements that decided this file's shape.
//
// 🔵 **Moved here from `device_history_section.dart` on 2026-08-21 (S2), where
// they had been dangling above a constant deleted on 2026-08-16.** They belong
// here now: they are no longer an argument for what CANNOT be done, they are
// the reason the list below is a `SliverList.builder`.
// ---------------------------------------------------------------------------
// ⚠️ ~~How many list rows are rendered before the "show more" step.~~
//
// 🔴 **THE CONSTANT THIS DOCUMENTED IS GONE** — `kDeviceHistoryRowStep` went
// with the row list on 2026-08-16 (design 0065 §0.9), and its doc comment was
// left behind, dangling above the next declaration and opening with a sentence
// about a "show more" step this file has not had since. Retitled 2026-08-21
// (design 0079 S0) rather than deleted, and demoted from `///` to `//` so it
// stops pretending to document the constant below it.
//
// 🔑 **The measurements are kept because design 0065 §0.9 ruled they survive
// the list**: what they establish is "why a component parasitic on five hosts
// cannot be a sliver", and that conclusion does not depend on the list.
//
// 🔵 **Design 0079 ends their applicability, and does it the way §0.8.2 itself
// licensed** — "the next person doing a full-screen list page (its own scroll
// container, no parasite problem) — none of the above applies". The history tab
// IS that page: the five hosts below are dismantled in S1, and the list returns
// in S2 as a `SliverList.builder`. The 417-vs-3,207 figure stops being a reason
// not to act and becomes the reason to.
//
// ---- retained verbatim, 2026-08-16 ----------------------------------------
//
// 🔴 **Measured, not guessed** (design 0065 `T65-4` M4, 2026-08-16). One
// [HistoryRow] inflates ~24 elements, and the list is a `Column` — not a lazy
// sliver — so the full [kHistoryRowCap] of 1,000 windows comes to **24,207
// elements** in one subtree. The plan's own threshold for "this must be lazy"
// is 8,000.
//
// ⚠️ The History TAB already pays that, and has since design 0061; this is not
// a cost design 0065 introduced. What design 0065 changes is WHEN it is paid:
// the tab is opened deliberately, while this block is expanded on EVERY detail
// page open, for every unit, including offline ones.
//
// The retreat taken is design 0065 §3.5.4 option ③ — render the list in slices
// — because it is the only one of the three that touches neither the scroll
// skeleton nor [kHistoryRowCap] (which would make this block and the History
// tab disagree about how much they loaded, §6 R5). One hour of windows is what
// fits the question the block answers: "what has this unit been doing".
//
// 🔴 **Ruled 2026-08-16 (Q6): no slivers — but NOT because slivers would not
// help.** Measured the same day: 1,000 rows as a `ListView`'s DIRECT children
// inflate ~242 elements, and the same 1,000 as a `SliverList`'s children
// ~417 — both lazy. It is 1,000 rows inside ONE child of a `ListView` (this
// block's shape) that comes to ~3,030, because a `ListView`'s laziness reaches
// its direct children and stops there. Lifting these rows into slivers really
// would fix it.
//
// The reason not to is architectural: this block hangs off FIVE hosts, and
// three of them ([OneScreenReport], used by `unidentified_view`,
// `class_pending_view` and the offline body) cannot take a sliver — their
// whole job is a `LayoutBuilder` + `ConstrainedBox(minHeight: viewport)` that
// centres a report in one screen, which sliver protocol has no equivalent for.
//



/// How long a completed query stays good for (design 0065 P-4).
///
/// 🔵 **Its original justification is GONE, and the cache is kept anyway.**
/// P-4 existed for design 0065 R3: opening a saved unit's page fires FB-75's
/// one-shot auto-connect, and when it succeeded the page swapped `_OfflineBody`
/// for the dashboard — destroying the block's State and rebuilding a fresh one
/// elsewhere in the tree, so the queries ran twice within a second or two.
/// Under design 0079 that swap happens INSIDE the live tab; this tab is its
/// sibling and is not destroyed by it, so R3 is structurally impossible now.
///
/// What the cache still buys is the cheap round trip: today ⇒ all ⇒ today
/// inside half a minute does not re-query. Worth keeping — and worth being
/// explicit that it is now the ONLY thing this constant does.
///
/// ⚠️ It can never mask an arrival: [DeviceHistoryTab.activationEpoch] loads
/// with `force: true`, which bypasses it (design 0079 T-3 / FB-84).
const Duration kDeviceHistoryCacheTtl = Duration(seconds: 30);

/// The P-4 cache: one entry per (unit, range).
///
/// Bounded hard, because it is process-global. Nothing here is a source of
/// truth — a miss simply re-queries.
class _QueryCache {
  static const int _maxEntries = 8;
  static final Map<String, ({DateTime at, DeviceHistoryData data})> _entries =
      <String, ({DateTime at, DeviceHistoryData data})>{};

  static String keyOf(String deviceId, HistoryRange range) =>
      '$deviceId|${range.name}';

  static DeviceHistoryData? get(String key) {
    final e = _entries[key];
    if (e == null) return null;
    if (DateTime.now().difference(e.at) > kDeviceHistoryCacheTtl) {
      _entries.remove(key);
      return null;
    }
    return e.data;
  }

  static void put(String key, DeviceHistoryData data) {
    // Insertion-ordered, so the first key is the oldest write.
    if (_entries.length >= _maxEntries && !_entries.containsKey(key)) {
      _entries.remove(_entries.keys.first);
    }
    _entries[key] = (at: DateTime.now(), data: data);
  }

  static void clear() => _entries.clear();
}

/// Drop every cached query result.
///
/// For tests, which would otherwise leak one test's rows into the next through
/// a process-global map.
@visibleForTesting
void debugClearDeviceHistoryCache() => _QueryCache.clear();

// 🔵 **`debugDeviceHistoryBodyBuilds` and the P-2' memo it witnessed are GONE
// (design 0079 S2).** The memo existed because `PackScaffold` — the shell the
// block hung off — calls `context.watch<TelemetryController>()`, so the block's
// `build` ran several times a second for as long as the page was open. Its own
// comment called the cache key "the single most dangerous line in this file",
// because a missed input freezes the surface on stale data: a failure far
// harder to notice than the rebuild it prevents.
//
// This tab has no such driver. It is a SIBLING of the live half, not a child of
// it, and it never watches [TelemetryController]. A mechanism kept past the
// problem it solved is only a way to be wrong later.
//
// ⚠️ `T65-4b` / `T65-4c` went with it — see design 0079 §5.4. They pinned a
// mechanism, and the mechanism is the thing that was removed.

/// One tab's worth of query results.
///
/// 🔵 **`rows` is back (design 0079 S2), and it is not a revert of S0.** S0
/// removed a `historyListBuckets` call whose entire result was consumed by one
/// `rows.isEmpty` — a thousand minute windows to answer a boolean. The list is
/// now DRAWN, so the rows are fetched to be read.
///
/// ⚠️ The empty check still goes through [HistoryStats.count], not through
/// `rows`: it is the question being asked ("is there anything to report"), and
/// it stays correct on the FB-85 case where a unit has rows but too few chart
/// points to plot.
class DeviceHistoryData {
  const DeviceHistoryData({
    required this.rows,
    required this.buckets,
    required this.stats,
    required this.bucketMs,
  });

  static const DeviceHistoryData empty = DeviceHistoryData(
    rows: [],
    buckets: [],
    stats: HistoryStats.empty,
    bucketMs: kHistoryListBucketMs,
  );

  /// One entry per display WINDOW (a minute) — design 0061 T3a.
  final List<HistoryListRow> rows;
  final List<HistoryBucket> buckets;
  final HistoryStats stats;

  /// The chart's bucket width, from [historyChartBucketMs]. Carried rather than
  /// recomputed at render time so the note under the chart cannot describe a
  /// different width from the one the data was fetched at.
  final int bucketMs;
}


/// Counts completed queries, for tests.
///
/// 🔑 A seam, not a statistic. Design 0079 T79-2 ("not opening the tab queries
/// nothing") and T79-3 ("every arrival re-queries") are both statements about
/// whether a query ran, and neither is visible on screen — the stats strip
/// aggregates, so a newer row can arrive and change nothing a finder could see.
@visibleForTesting
int debugDeviceHistoryQueries = 0;

/// The history tab's body: range row, chart, stats strip, per-minute list.
class DeviceHistoryTab extends StatefulWidget {
  const DeviceHistoryTab({
    super.key,
    required this.deviceId,
    required this.live,
    this.activationEpoch = 0,
  });

  /// The unit whose page this is. See red line 1 in the library comment.
  final String deviceId;

  /// Whether [deviceId] is the unit currently on the link — the same expression
  /// the detail page computes for itself (`isOnline && connectedDeviceId ==
  /// deviceId`), passed IN rather than derived here.
  ///
  /// 🔴 **It gates the warning thresholds, and only those.** `warnOv` /
  /// `warnUv` / `warnOt` come from [TelemetryController], i.e. from the unit the
  /// phone is holding. On a page showing unit A while the phone holds unit B
  /// they would judge A's stored rows against B's limits — FB-41's shape in a
  /// third column. With [live] false the three are withheld and every row falls
  /// back to the status the device itself recorded.
  ///
  /// 🔵 **Ruled 2026-08-21** (owner, verbatim: 「警告用的 ov uv ot 要留之後要
  /// 做」). Between 2026-08-16 and 2026-08-21 nothing read these — the warning
  /// filter that used them had been removed — and design 0079 proposed deleting
  /// all four as dead parameters. Overruled, and S2 is why: the list below
  /// classifies every row through them. What is still to come is the FILTER
  /// ("show only warnings"), not the thresholds.
  ///
  /// 🔴 **What must NOT happen when this flips true** (auto-connect succeeding
  /// while the user reads history): a re-query. The thresholds are applied at
  /// render time to rows already in hand, so the rows re-classify and nothing
  /// is fetched. See design 0079 §6 R2 — rows changing colour under the reader
  /// is intended, and it is why the offline copy may not claim a clean bill of
  /// health.
  final bool live;

  /// Bumped by the page every time this tab becomes the selected one.
  ///
  /// 🔴 **This is what closes FB-84.** The complaint was "opening a device page
  /// does not refresh its history"; the block did query on mount, but behind a
  /// 30 s cache, and never again afterwards. Both halves were real. Under tabs
  /// the second dissolves — you arrive here by an explicit tap, so "on arrival"
  /// is a moment that exists — and the epoch turns each arrival into a forced
  /// re-query.
  ///
  /// ⚠️ An `int` rather than a `GlobalKey` or a listener: it arrives through
  /// `didUpdateWidget` like any other prop, so a test can drive it without
  /// reaching into anybody's State.
  final int activationEpoch;

  @override
  State<DeviceHistoryTab> createState() => _DeviceHistoryTabState();
}

class _DeviceHistoryTabState extends State<DeviceHistoryTab> {
  /// Same default as the History tab (`today`), and that matters: two surfaces
  /// opening on different ranges would show one unit two different pictures
  /// (design 0065 §6 R5).
  HistoryRange _range = HistoryRange.today;
  bool _exporting = false;

  late Future<DeviceHistoryData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(DeviceHistoryTab old) {
    super.didUpdateWidget(old);
    // The page can be handed a different unit without this State being
    // destroyed. Re-query rather than keep showing the previous unit's rows.
    if (old.deviceId != widget.deviceId) {
      _future = _load();
      return;
    }
    // 🔴 `force: true` — design 0079 T-3. Serving this from the cache would
    // make the tap that brought the user here do nothing, which is FB-84's
    // complaint restated rather than fixed.
    //
    // 🔑 The `return` above matters: a page handed a different unit while its
    // history tab is showing changes BOTH, and two loads racing would leave
    // whichever resolved later on screen.
    if (old.activationEpoch != widget.activationEpoch) {
      _future = _load(force: true);
    }
  }

  /// The three queries — the same three, in the same order, with the same
  /// arguments as `_HistoryScreenState._load` (design 0065 §3.2.1).
  ///
  /// 🔵 **Three again as of S2.** They were three until 2026-08-16, then
  /// nominally two and actually still three (the third was issued and thrown
  /// away — design 0065 §0.9's correction), then genuinely two after S0. The
  /// list makes the third one earn its place.
  Future<DeviceHistoryData> _load({bool force = false}) async {
    // Captured before the first await: this runs from `initState`, and a
    // `context.read` after an await may be addressing a page that has gone.
    final tele = context.read<TelemetryController>();
    final deviceId = widget.deviceId;
    final range = _range;
    final key = _QueryCache.keyOf(deviceId, range);
    if (!force) {
      final hit = _QueryCache.get(key);
      if (hit != null) return hit;
    }
    debugDeviceHistoryQueries++;
    final since = historySinceFor(range);
    final stats = await tele.historyStats(since: since, deviceId: deviceId);
    // 🔴 `historyChartBucketMs`, never an inline "about the same" calculation.
    // The width decides how much each plotted point averages; two surfaces
    // computing it separately is how one unit ends up with two charts (§6 R5).
    final bucketMs = historyChartBucketMs(since ?? stats.firstAt);
    final buckets = await tele.historyBuckets(
        since: since, bucketMs: bucketMs, deviceId: deviceId);
    // 🔴 `kHistoryListBucketMs` and `kHistoryRowCap`, both shared with the
    // History tab. The cap especially: two surfaces loading different amounts
    // of the same unit's history is design 0065 §6 R5 in its purest form, and
    // slivers make the rows cheap to RENDER — not a reason to fetch more.
    final rows = await tele.historyListBuckets(
      since: since,
      bucketMs: kHistoryListBucketMs,
      limit: kHistoryRowCap,
      deviceId: deviceId,
    );
    final data = DeviceHistoryData(
        rows: rows, buckets: buckets, stats: stats, bucketMs: bucketMs);
    _QueryCache.put(key, data);
    return data;
  }

  void _setRange(HistoryRange r) {
    if (r == _range) return;
    setState(() {
      _range = r;
      _future = _load();
    });
  }

  /// Re-run the queries, ignoring the cache (owner ruling 2026-08-16).
  ///
  /// 🔵 **Its original job is now done by [DeviceHistoryTab.activationEpoch]** —
  /// arriving at the tab re-queries. What the button still buys is the case
  /// where the user is ALREADY here: sitting on this tab while the unit charges
  /// shows the snapshot taken on arrival, because there is no timer and no
  /// listener. That was true of the block and it is true of the tab.
  ///
  // 🔴 A BLOCK body, not `setState(() => _future = _load(...))`. The arrow form
  // returns the assigned value — a `Future` — and `setState` asserts against a
  // callback that returns one ("Maybe it is marked as async"). The assertion
  // fires inside the gesture handler, so the tap logs an exception and the
  // rebuild simply never happens: the button looks wired, `_load` even runs and
  // returns the newer rows, and the screen does not change. Cost me a bisect;
  // `_setRange` above already had it right.
  void _refresh() {
    setState(() {
      _future = _load(force: true);
    });
  }

  /// 🔴 The export is pinned to THIS page's unit, connected or not.
  ///
  /// Ruled 2026-08-15 (design 0065 §0.6), owner's words: 「只能是該詳情的那個
  /// 裝置，不管是不是連線他。」 Passing [DeviceHistoryTab.deviceId] to
  /// `chooseExportScope` is the whole of it, and it is not a convenience:
  /// without it the scope would come from `recordingDeviceId`, so exporting
  /// from A's page while the phone holds B would produce B's rows under B's
  /// name in B's filename — and exporting from A's page with nothing connected
  /// would produce the entire database.
  ///
  /// The range is NOT pinned: which unit and how much time are separate
  /// questions, and only the first one was ruled on.
  Future<void> _exportCsv() async {
    if (_exporting) return;
    final since = historySinceFor(_range);
    final target = await chooseExportScope(
      context,
      // No "this connection" entry: the detail page has no session to scope to
      // — it can be open on a unit that has never been connected at all.
      offerSession: false,
      offerGranularity: true,
      since: since,
      deviceId: widget.deviceId,
    );
    if (target == null || !mounted) return;
    setState(() => _exporting = true);
    try {
      await exportHistoryCsv(
        context,
        target: target,
        since: since,
        window: historyWindowLabel(_range, since),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Watched: the user can change it in Settings and walk straight back here.
    final tempUnit = context.watch<SettingsController>().tempUnit;
    // 🔴 `read`, not `watch` — red line 2.
    final tele = context.read<TelemetryController>();
    // 🔴 Withheld unless this page's unit is the unit on the link.
    final ov = widget.live ? tele.warnOv : null;
    final uv = widget.live ? tele.warnUv : null;
    final ot = widget.live ? tele.warnOt : null;

    // The class decides whether a row's CURRENT column means anything, and how
    // it is worded (design 0056). Resolved ONCE here rather than per row: on
    // this surface every row belongs to `widget.deviceId`, so a per-row lookup
    // would be the same three provider reads repeated a thousand times.
    final deviceClass = deviceClassFor(
      context.watch<DeviceController>(),
      widget.deviceId,
      facts: context.watch<DeviceFactsController?>(),
      liveDeviceId: tele.recordingDeviceId,
      liveClass: context.watch<ConnectionController>().resolvedClass,
    );

    // 🔑 The same frame the dashboard routes give their content —
    // `pack_view.dart` and `power_bank_view.dart` both centre a 560-wide column
    // and pad it (15, 3, 15, 14). Matching it is what kept S1 equivalent to
    // look at: the block did not shift sideways when it moved here.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
              sliver: SliverMainAxisGroup(
                slivers: [
                  // Range, refresh and export — ONE row (owner ruling
                  // 2026-08-16). All three live OUTSIDE the `FutureBuilder`
                  // below, which is what makes the row possible: none of them
                  // needs the query's result.
                  SliverToBoxAdapter(child: _rangeRow(l10n)),
                  FutureBuilder<DeviceHistoryData>(
                    future: _future,
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return _loadingSliver(l10n);
                      }
                      if (snap.hasError) {
                        return _messageSliver(
                            l10n.historyLoadFailed('${snap.error}'));
                      }
                      return _resultSlivers(
                        l10n,
                        snap.data ?? DeviceHistoryData.empty,
                        tempUnit: tempUnit,
                        deviceClass: deviceClass,
                        ov: ov,
                        uv: uv,
                        ot: ot,
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rangeRow(AppLocalizations l10n) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Expanded(
              child: SegmentedControl<HistoryRange>(
                selected: _range,
                onChanged: _setRange,
                options: <({HistoryRange value, String label})>[
                  (value: HistoryRange.today, label: l10n.historyRangeToday),
                  (value: HistoryRange.week, label: l10n.historyRangeWeek),
                  (value: HistoryRange.all, label: l10n.historyRangeAll),
                ],
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: l10n.deviceHistoryRefresh,
              // 40 dp floor, named rather than inherited — see FB-70.
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              padding: EdgeInsets.zero,
            ),
            if (_exporting)
              const SizedBox(
                width: 40,
                height: 40,
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              IconButton(
                onPressed: _exportCsv,
                icon: const Icon(Icons.file_download_outlined, size: 18),
                tooltip: l10n.historyExportCsv,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
              ),
          ],
        ),
      );

  /// A FIXED-height placeholder, not a shrink-wrapped spinner.
  ///
  /// ⚠️ **The reason changed with design 0079 and the height did not.** It used
  /// to be that a placeholder shorter than its result made the REST OF THE PAGE
  /// jump upward when the query landed, while the user was mid-scroll through
  /// the live readings. There is no rest of the page now. What remains is this
  /// surface's own scroll offset, which is reason enough on the range switch.
  Widget _loadingSliver(AppLocalizations l10n) =>
      SliverToBoxAdapter(child: IndustrialCard(
        child: SizedBox(
          height: 300,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: context.accent.accent),
                const SizedBox(height: 14),
                Text(
                  l10n.deviceHistoryLoading,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: context.colors.muted),
                ),
              ],
            ),
          ),
        ),
      ));

  Widget _resultSlivers(
    AppLocalizations l10n,
    DeviceHistoryData data, {
    required TempUnit tempUnit,
    required ProductClass deviceClass,
    double? ov,
    double? uv,
    double? ot,
  }) {
    final chartEmpty = data.buckets.length < 2;
    // 🔴 The tab is still DRAWN when there is nothing in it. A surface that
    // vanishes for a unit with no records is the dead-end shape FB-53 and
    // design 0046 T-new-6 were both about.
    //
    // 🔴 `stats.count`, not `rows.isEmpty` — design 0079 S0. And the
    // `&& chartEmpty` half is load-bearing: a unit whose rows all fall inside
    // ONE chart bucket has `count > 0` and fewer than two points, and FB-85
    // ruled it must still report its numbers rather than claim to be empty.
    if (data.stats.count == 0 && chartEmpty) {
      return _messageSliver(_emptyText(l10n));
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: IndustrialCard(
            heading: _range == HistoryRange.today
                ? l10n.historyChartTodayTitle
                : l10n.historyChartTitle,
            headingIcon: Icons.show_chart,
            child: HistoryTrendCard(
              buckets: data.buckets,
              stats: data.stats,
              tempUnit: tempUnit,
              multiDay: _range != HistoryRange.today,
              bucketMs: data.bucketMs,
            ),
          ),
        ),
        if (data.rows.isNotEmpty) ...[
          // design 0061 T3a: the list shows one row per minute, and says so.
          // Without this line the `HH:mm` stamps read as a stored reading
          // rather than as the window they summarise.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 2, 2, 9),
              child: Text(
                l10n.historyListMinuteNote,
                style:
                    TextStyle(fontSize: 10.5, color: context.colors.muted),
              ),
            ),
          ),
          // 🔴 **`SliverList.builder`, and this is the whole technical point of
          // design 0079.** `SliverList(children: [...])` would build every row
          // up front and throw away the 417-vs-3,207 that justified the move.
          // `T79-6` is the pin.
          SliverList.builder(
            itemCount: data.rows.length,
            itemBuilder: (context, i) {
              final r = data.rows[i];
              return HistoryRow(
                row: r,
                tempUnit: tempUnit,
                status: historyClassifyRow(r, ov: ov, uv: uv, ot: ot),
                deviceClass: deviceClass,
                // design 0074 Q3: EVERY row, not only the ones with seconds in
                // them. The sheet is where "this minute predates per-second
                // recording" gets said, and a row that simply does not respond
                // says it much worse.
                onTap: () => showMinuteSecondsSheet(
                  context,
                  row: r,
                  tempUnit: tempUnit,
                  deviceClass: deviceClass,
                  ov: ov,
                  uv: uv,
                  ot: ot,
                ),
              );
            },
          ),
        ],
      ],
    );
  }

  String _emptyText(AppLocalizations l10n) {
    // "All" and still nothing ⇒ this unit genuinely has no records. Any other
    // range ⇒ say it is the range, because there may well be plenty just
    // outside it.
    return _range == HistoryRange.all
        ? l10n.deviceHistoryEmpty
        : l10n.historyEmptyDeviceRange;
  }

  Widget _messageSliver(String text) => SliverToBoxAdapter(
        child: IndustrialCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 26),
            child: Center(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: context.colors.muted),
              ),
            ),
          ),
        ),
      );
}
