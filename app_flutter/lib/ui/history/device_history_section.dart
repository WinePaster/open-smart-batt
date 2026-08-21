/// OpenSmartBatt — this unit's history, embedded in its detail page
/// (design 0065).
///
/// ## Why it exists
///
/// The dealer's report of 2026-08-15, verbatim: 「如果我點進去裝置詳情，我想要看
/// 歷史紀錄，然後還要上一頁、切換到『歷史』tab，這樣太不友善。」 — and the
/// journey he describes was literally true: leaving this page dropped the unit's
/// context, and the History tab then re-seeded its own scope to whichever unit
/// was RECORDING, not the one he had just been looking at. The owner rejected
/// the cheap fix (a button that jumps to the History tab with a filter) and
/// ruled for an embedded query block instead.
///
/// It is the second independent report of the same thing; the first
/// (2026-08-07) was filed as "cannot find the history" and left unanswered.
///
/// ## The three red lines (design 0065 §3.1)
///
/// 1. 🔴 **[deviceId] comes from the caller. This widget never asks
///    [ConnectionController] or [TelemetryController] which unit is live.**
///    "The unit being looked at" and "the unit on the link" are different
///    questions, and answering the first with the second is precisely how
///    FB-41 / FB-42 filed one unit's telemetry under another's.
/// 2. 🔴 **It never `watch`es [TelemetryController].** Everything it needs from
///    there is a one-shot call. Watching would subscribe it to a notify that
///    fires on every telemetry sample — ~4.7 Hz on a live link.
/// 3. 🔴 **It is expanded by default** (ruled 2026-08-15, Q5), which removes the
///    "nobody expanded it so nothing was queried" buffer the first draft leaned
///    on. Everything below about caching and slicing exists because of that.
///
/// ## What it does NOT take from the History tab (§3.2.3)
///
///  * **the device picker** — the scope is fixed by the page it sits on, and a
///    dropdown that cannot change anything is a control that only explains
///    itself after the fact (design 0046 §4.7);
///  * **the whole-database row-count footer** — that number counts EVERY unit.
///    On one unit's page a reader would take it for this unit's total: a
///    confident wrong number, which is worse than none;
///  * **pull-to-refresh** — the block lives inside somebody else's scroll view,
///    so the gesture is not its to take.
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
/// 🔴 The cache is DELIBERATELY outside the widget's State, and that is not an
/// optimisation — it is the fix for R3. Opening a saved unit's page fires
/// FB-75's one-shot auto-connect; when it succeeds the page swaps
/// `_OfflineBody` for the dashboard, which destroys this widget's State and
/// builds a fresh one somewhere else in the tree. Without a cache that outlives
/// the State, every successful auto-connect would run the three queries twice
/// within a second or two.
const Duration kDeviceHistoryCacheTtl = Duration(seconds: 30);

/// One block's worth of query results.
///
/// 🔴 **No `rows` field, and that is design 0079 S0 finally doing what design
/// 0065 §0.9 SAID had been done.** That section, written 2026-08-16, reads
/// "`historyListBuckets` is no longer queried by this block ⇒ three queries
/// become two". It never was: `_load` went on issuing it with
/// `limit: kHistoryRowCap` — **1,000 minute windows** — and the whole result
/// was consumed by one `rows.isEmpty` in `_results`. A thousand rows to answer
/// a boolean, on every detail-page open, for every unit, offline ones included.
///
/// [HistoryStats.count] answers the same question from a query this block was
/// making anyway. The two are equivalent by construction, not by inspection:
/// `aggregate` and `queryListBuckets` build their WHERE from the same
/// `_scope(since:, deviceId:)`, so `count` is the row total over exactly the
/// set the buckets would group — and `LIMIT` can truncate a non-empty result
/// but never empties one.
///
/// 🔑 `HistoryTrendCard` had already reached this conclusion for itself
/// (FB-85, `history_screen.dart:1226`): "`stats.count` rather than
/// `buckets.isEmpty` is the gate … the callers that draw their own empty state
/// (`device_history_section`) check rows, which can disagree". This is that
/// caller agreeing.
///
/// ⚠️ The list comes BACK in design 0079 S2, as a `SliverList.builder` inside
/// the history tab's own scroll view. It does not come back here.
class DeviceHistoryData {
  const DeviceHistoryData({
    required this.buckets,
    required this.stats,
    required this.bucketMs,
  });

  static const DeviceHistoryData empty = DeviceHistoryData(
    buckets: [],
    stats: HistoryStats.empty,
    bucketMs: kHistoryListBucketMs,
  );

  final List<HistoryBucket> buckets;
  final HistoryStats stats;

  /// The chart's bucket width, from [historyChartBucketMs]. Carried rather than
  /// recomputed at render time so the note under the chart cannot describe a
  /// different width from the one the data was fetched at.
  final int bucketMs;
}

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

/// How many times any section has actually rebuilt its body subtree.
///
/// 🔴 The witness for P-2′ (`T65-4b`). The defect it guards against — the
/// memoised subtree being "simplified" away, so that 1,000 rows rebuild at the
/// telemetry rate — produces no error, no log and no visible difference. A
/// counter is the only thing that can see it.
@visibleForTesting
int debugDeviceHistoryBodyBuilds = 0;

/// How many times the block has actually gone to the database.
///
/// 🔑 A seam, not a statistic. The P-4 cache and the refresh button are both
/// about "did this re-query?", and until 2026-08-16 the tests inferred that
/// from rendered numbers — a row appearing in the list. The owner's ruling that
/// day removed the list, and the inference went with it: the stats strip
/// aggregates, so a newer row can arrive and change nothing on screen. Counting
/// the queries says the thing those tests mean.
@visibleForTesting
int debugDeviceHistoryQueries = 0;

class DeviceHistorySection extends StatefulWidget {
  const DeviceHistorySection({
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
  /// 🔴 It gates the warning thresholds, and only those. `warnOv` / `warnUv` /
  /// `warnOt` are read from the LIVE sample, so on a page showing unit A while
  /// the phone holds unit B they would judge A's stored rows against B's
  /// limits. That is FB-41's shape in a third column, and the block refuses to
  /// do it: with [live] false the classification falls back to the status the
  /// device itself recorded, and the copy says so rather than claiming a clean
  /// bill of health (§3.2.2).
  ///
  /// 🔵 **Ruled 2026-08-21: this stays, and so do the three thresholds it
  /// gates** (owner, verbatim: 「警告用的 ov uv ot 要留之後要做」). Design 0079
  /// had proposed deleting all four as dead parameters — since the warning
  /// filter was removed on 2026-08-16 nothing reads them, and they are threaded
  /// through five call sites and the memo key for no visible effect. That
  /// proposal is overruled and the reason is not sentiment: design 0079 S2
  /// classifies each list row through `historyClassifyRow(ov:, uv:, ot:)`, so
  /// the gate goes back to work the moment the list returns. What is still to
  /// come is the FILTER ("show only warnings"), not the thresholds.
  final bool live;

  /// Bumped by the host every time this surface becomes visible again.
  ///
  /// 🔴 Design 0079 T-3, and the whole of FB-84's fix. The block has never
  /// refreshed itself — no timer, no listener — so it shows the snapshot it
  /// took when it was mounted (see [_refresh]). Under a tab, "becoming visible"
  /// is a real event with a real moment, and each one forces a re-query past
  /// the P-4 cache.
  ///
  /// ⚠️ Defaults to 0 and is IGNORED by hosts that do not pass it, which is why
  /// the five design 0065 mount points needed no change on the way out.
  final int activationEpoch;

  @override
  State<DeviceHistorySection> createState() => _DeviceHistorySectionState();
}

class _DeviceHistorySectionState extends State<DeviceHistorySection> {
  /// Same default as the History tab (`today`), and that matters: two surfaces
  /// opening on different ranges would show one unit two different pictures
  /// (§6 R5).
  HistoryRange _range = HistoryRange.today;
  bool _exporting = false;

  late Future<DeviceHistoryData> _future;

  /// P-2′ — the memoised subtree and the key it was built for.
  ///
  /// 🔴 **Why memoising is necessary at all.** `PackScaffold` — the shell this
  /// block hangs off for batteries and capacitors — calls
  /// `context.watch<TelemetryController>()`, and that controller notifies on
  /// every telemetry sample. So this widget's `build` runs several times a
  /// second on a live link, for the entire time the page is open.
  ///
  /// 🔴 **Why `const` cannot do it** (the first draft said it could): a `const`
  /// constructor needs compile-time arguments and [deviceId] is a runtime
  /// string off a navigation route. Flutter's own short-circuit is
  /// `Element.updateChild`'s `child.widget == newWidget`, and `Widget` does not
  /// override `==` — so it means *the identical object*. Returning the same
  /// instance from `build` is therefore the run-time way to buy exactly what
  /// `const` buys.
  ///
  /// ⚠️ **The cache key is the single most dangerous line in this file.** Miss
  /// an input and the block freezes on stale data — a failure much harder to
  /// notice than the rebuild it is preventing. `T65-4c` is the reverse pin.
  Widget? _cached;
  Object? _cacheKey;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(DeviceHistorySection old) {
    super.didUpdateWidget(old);
    // The host can be handed a different unit without this State being
    // destroyed. Re-query rather than keep showing the previous unit's rows.
    if (old.deviceId != widget.deviceId) {
      _future = _load();
      return;
    }
    // 🔴 `force: true` — design 0079 T-3. Serving this from the P-4 cache would
    // make the tap that brought the user here do nothing, which is FB-84's
    // complaint restated rather than fixed.
    //
    // 🔑 The `return` above matters: a host that changes BOTH at once (a page
    // handed a different unit while its history tab is showing) must not run
    // two loads and leave the later-resolving one to win.
    if (old.activationEpoch != widget.activationEpoch) {
      _future = _load(force: true);
    }
  }

  /// The TWO queries — design 0079 S0. They are the first two of
  /// `_HistoryScreenState._load`'s three (§3.2.1), in the same order, with the
  /// same arguments; the third (`historyListBuckets`) is not issued here, and
  /// [DeviceHistoryData] says why at length.
  ///
  /// ⚠️ The History TAB still makes all three, and must: it renders the list.
  /// "Two surfaces, same queries" (§6 R5) was never a rule that both had to
  /// fetch what only one of them draws.
  Future<DeviceHistoryData> _load({bool force = false}) async {
    // Captured before the first await, for the History tab's reason: this runs
    // from `initState`, and a `context.read` after an await may be addressing a
    // page that has already gone.
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
    final data =
        DeviceHistoryData(buckets: buckets, stats: stats, bucketMs: bucketMs);
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

  /// Re-run the three queries, ignoring the P-4 cache (owner ruling 2026-08-16).
  ///
  /// 🔴 **This block does not refresh itself, and that — not the 30 s TTL — was
  /// the real gap.** There is no timer and no listener here: the queries run on
  /// `initState`, when `deviceId` changes, and when the range changes. Sit on a
  /// device page while it charges and the section shows the snapshot it took
  /// when you arrived, cache or no cache. Dropping [kDeviceHistoryCacheTtl] to
  /// zero would not have fixed that; only an explicit re-query does.
  ///
  /// ⚠️ **A button rather than pull-to-refresh, and that is forced.**
  /// `RefreshIndicator` needs a Scrollable *below* it, and this widget is a
  /// [Column] hosted inside somebody else's scroll view — five of them
  /// (two `ListView`s, two `SingleChildScrollView`s, and `OneScreenReport`).
  /// Pull would have to wrap each host and then reach back in here, and on four
  /// of those hosts the rest of the page is already live, so "pull to refresh"
  /// would promise something only one block on the page can do.
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
  /// 裝置，不管是不是連線他。」 Passing [DeviceHistorySection.deviceId] to
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
    // Watched: the user can change it in Settings and walk straight back here.
    final tempUnit = context.watch<SettingsController>().tempUnit;
    // 🔴 `read`, not `watch` — red line 2. The values still arrive fresh,
    // because the shell above this one is already rebuilding on every sample;
    // what `read` avoids is subscribing a SECOND listener to that firehose.
    final tele = context.read<TelemetryController>();
    // 🔴 Withheld unless this page's unit is the unit on the link (§3.2.2).
    final ov = widget.live ? tele.warnOv : null;
    final uv = widget.live ? tele.warnUv : null;
    final ot = widget.live ? tele.warnOt : null;

    // Every input `_buildBody` reads. Values, never object identities, for
    // `ov`/`uv`/`ot`: they are device settings that do not move during a
    // session, but they arrive on a sample object that is replaced several
    // times a second — keying on the sample would make the memo miss every
    // time, which is the same as not having one.
    final key = Object.hashAll(<Object?>[
      widget.deviceId,
      widget.live,
      _range,
      _exporting,
      tempUnit,
      ov,
      uv,
      ot,
      // The future's identity, so a reload rebuilds even when nothing else
      // moved. (Its RESULT arriving is handled inside the FutureBuilder.)
      //
      // 🔑 This is also what carries [DeviceHistorySection.activationEpoch]
      // into the memo: an epoch bump replaces `_future`, so the identity moves
      // with it. The epoch is NOT listed separately on purpose — a key input
      // that cannot change the rendered output would make the memo miss for
      // nothing, and this key's own comment is about exactly that mistake in
      // the other direction.
      identityHashCode(_future),
    ]);
    if (_cached == null || key != _cacheKey) {
      _cacheKey = key;
      debugDeviceHistoryBodyBuilds++;
      _cached = _buildBody(tempUnit: tempUnit, ov: ov, uv: uv, ot: ot);
    }
    return _cached!;
  }

  Widget _buildBody({
    required TempUnit tempUnit,
    double? ov,
    double? uv,
    double? ot,
  }) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ① The heading. NOT an expander (Q5 ruled expanded), so it is a
          // label saying which unit's records these are — the page around it
          // shows the CONNECTED unit's live values, which need not be the same
          // unit.
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
            child: Row(
              children: [
                Icon(Icons.history, size: 15, color: context.colors.muted),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    l10n.deviceHistorySectionTitle,
                    style: AppTextStyles.label(context),
                  ),
                ),
              ],
            ),
          ),
          // ② Range, refresh and export — ONE row (owner ruling 2026-08-16).
          //
          // They were on two rows: the range here, and refresh/export in a
          // right-aligned strip below the chart ("between the summary and the
          // rows, where both of their objects begin", ruled 2026-08-07 for the
          // History TAB). That placement rule died with the rows — see ⑤ —
          // and a lone action strip floating mid-block had nothing left to sit
          // between.
          //
          // 🔑 Both controls live OUTSIDE the `FutureBuilder` below, which is
          // what makes this row possible at all: neither needs the query's
          // result. Refresh replaces the future; `_exportCsv` re-derives its
          // own scope from `_range` and `widget.deviceId`.
          Padding(
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
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
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
                    constraints:
                        const BoxConstraints(minWidth: 40, minHeight: 40),
                    padding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
          FutureBuilder<DeviceHistoryData>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return _loading(l10n);
              }
              if (snap.hasError) {
                return _message(l10n.historyLoadFailed('${snap.error}'));
              }
              return _results(
                l10n,
                snap.data ?? DeviceHistoryData.empty,
                tempUnit: tempUnit,
                ov: ov,
                uv: uv,
                ot: ot,
              );
            },
          ),
        ],
      ),
    );
  }

  /// P-5 — a FIXED-height placeholder, not a shrink-wrapped spinner.
  ///
  /// The block is expanded by default, so this runs on every page open. A
  /// placeholder shorter than its result makes the whole page below it jump
  /// upward the instant the query lands — and the user is often mid-scroll
  /// through the live readings when that happens. The height is the chart
  /// card's, which is the part that is always there.
  Widget _loading(AppLocalizations l10n) => IndustrialCard(
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
                  style:
                      TextStyle(fontSize: 11.5, color: context.colors.muted),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _results(
    AppLocalizations l10n,
    DeviceHistoryData data, {
    required TempUnit tempUnit,
    double? ov,
    double? uv,
    double? ot,
  }) {
    final chartEmpty = data.buckets.length < 2;
    // 🔴 The block is still DRAWN when there is nothing in it. A section that
    // vanishes for a unit with no records is the dead-end shape FB-53 and
    // design 0046 T-new-6 were both about — and with the block expanded by
    // default it is what every never-recorded unit would show on open. Reading
    // "not started yet" is the whole job of the copy.
    // 🔴 `stats.count`, not a row list — design 0079 S0. See [DeviceHistoryData]
    // for why the thousand-row query that used to answer this is gone. The
    // `&& chartEmpty` half is unchanged and still load-bearing: a unit whose
    // rows all fall inside ONE chart bucket has `count > 0` and fewer than two
    // points, and FB-85 is the ruling that it must still report its numbers
    // rather than claim to be empty.
    if (data.stats.count == 0 && chartEmpty) {
      return _message(_emptyText(l10n, 0));
    }
    // 🔑 `deviceClassFor` and its three provider reads went with the row list:
    // the class was only ever needed to decide whether a row's CURRENT column
    // meant anything. The chart does not have that column.

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ③ Chart + stats strip. The strip is INSIDE the card — see
        // [HistoryTrendCard].
        IndustrialCard(
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
        // ④／⑤ REMOVED 2026-08-16 (owner ruling): the warning filter, the
        // per-minute row list, and the action strip that sat above them.
        //
        // What is left is the chart plus its stats strip — the question this
        // block exists to answer on a device page is "what has this unit been
        // doing", and the curve answers it at a glance. The row list answered a
        // different question ("what exactly was the value at 14:03"), and the
        // History tab still answers that one, for every unit including ones no
        // longer in range.
        //
        // 🔑 Three things went with them, and none is a loss to mourn:
        //  * the slicing UI (`_showMore`, 60 + 120) existed only to keep the
        //    row list from inflating thousands of elements — no rows, no need;
        //  * the warning filter needed OV/UV/OT thresholds, and those come from
        //    the CONNECTED unit (`telemetry_controller`), i.e. the FB-41 shape
        //    in a third field. Design 0065 §6 risk E is now moot HERE (it still
        //    stands on the History tab, which is where it was filed);
        //  * `historyListBuckets` is no longer queried, so the block is two
        //    queries rather than three.
      ],
    );
  }

  /// [loaded] is how many windows the query actually returned.
  String _emptyText(AppLocalizations l10n, int loaded) {
    // "All" and still nothing ⇒ this unit genuinely has no records. Any other
    // range ⇒ say it is the range, because there may well be plenty just
    // outside it.
    return _range == HistoryRange.all
        ? l10n.deviceHistoryEmpty
        : l10n.historyEmptyDeviceRange;
  }

  Widget _message(String text) => IndustrialCard(
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
      );
}
