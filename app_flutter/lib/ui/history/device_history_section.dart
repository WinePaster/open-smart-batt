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

/// How many list rows are rendered before the "show more" step.
///
/// 🔴 **Measured, not guessed** (design 0065 `T65-4` M4, 2026-08-16). One
/// [HistoryRow] inflates ~24 elements, and the list is a `Column` — not a lazy
/// sliver — so the full [kHistoryRowCap] of 1,000 windows comes to **24,207
/// elements** in one subtree. The plan's own threshold for "this must be lazy"
/// is 8,000.
///
/// ⚠️ The History TAB already pays that, and has since design 0061; this is not
/// a cost design 0065 introduced. What design 0065 changes is WHEN it is paid:
/// the tab is opened deliberately, while this block is expanded on EVERY detail
/// page open, for every unit, including offline ones.
///
/// The retreat taken is design 0065 §3.5.4 option ③ — render the list in slices
/// — because it is the only one of the three that touches neither the scroll
/// skeleton (Q6, still the owner's to rule) nor [kHistoryRowCap] (which would
/// make this block and the History tab disagree about how much they loaded,
/// §6 R5). One hour of windows is what fits the question the block answers:
/// "what has this unit been doing".
const int kDeviceHistoryInitialRows = 60;

/// Rows added per "show more" tap. Not "all the rest": the whole point of the
/// slice is that the element count grows in steps a phone can absorb.
const int kDeviceHistoryRowStep = 120;

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

class DeviceHistorySection extends StatefulWidget {
  const DeviceHistorySection({
    super.key,
    required this.deviceId,
    required this.live,
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
  final bool live;

  @override
  State<DeviceHistorySection> createState() => _DeviceHistorySectionState();
}

class _DeviceHistorySectionState extends State<DeviceHistorySection> {
  /// Same default as the History tab (`today`), and that matters: two surfaces
  /// opening on different ranges would show one unit two different pictures
  /// (§6 R5).
  HistoryRange _range = HistoryRange.today;
  bool _warningOnly = false;
  bool _exporting = false;
  int _visibleRows = kDeviceHistoryInitialRows;

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
      _visibleRows = kDeviceHistoryInitialRows;
      _future = _load();
    }
  }

  /// The three queries — the same three, in the same order, with the same
  /// arguments as `_HistoryScreenState._load` (§3.2.1). Nothing here is a new
  /// query: the per-device data layer landed with FB-38 in v0.6.13.
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
    final since = historySinceFor(range);
    final stats = await tele.historyStats(since: since, deviceId: deviceId);
    // 🔴 `historyChartBucketMs`, never an inline "about the same" calculation.
    // The width decides how much each plotted point averages; two surfaces
    // computing it separately is how one unit ends up with two charts (§6 R5).
    final bucketMs = historyChartBucketMs(since ?? stats.firstAt);
    final buckets = await tele.historyBuckets(
        since: since, bucketMs: bucketMs, deviceId: deviceId);
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
      _visibleRows = kDeviceHistoryInitialRows;
      _future = _load();
    });
  }

  /// Client-side only — the filter runs over rows already fetched, exactly as
  /// it does on the History tab. No re-query, and therefore no throttle to
  /// think about.
  void _toggleWarning() => setState(() => _warningOnly = !_warningOnly);

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

  void _showMore(int remaining) => setState(() =>
      _visibleRows += remaining < kDeviceHistoryRowStep
          ? remaining
          : kDeviceHistoryRowStep);

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
      _warningOnly,
      _exporting,
      _visibleRows,
      tempUnit,
      ov,
      uv,
      ot,
      // The future's identity, so a reload rebuilds even when nothing else
      // moved. (Its RESULT arriving is handled inside the FutureBuilder.)
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
          // ② Range. Same three options, same order, same widget as the
          // History tab's toolbar.
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
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
    final listRows = historyApplyWarningFilter(
      data.rows,
      warningOnly: _warningOnly,
      ov: ov,
      uv: uv,
      ot: ot,
    );
    final chartEmpty = data.buckets.length < 2;
    // 🔴 The block is still DRAWN when there is nothing in it. A section that
    // vanishes for a unit with no records is the dead-end shape FB-53 and
    // design 0046 T-new-6 were both about — and with the block expanded by
    // default it is what every never-recorded unit would show on open. Reading
    // "not started yet" is the whole job of the copy.
    if (data.rows.isEmpty && chartEmpty) {
      return _message(_emptyText(l10n, 0));
    }
    // The class that decides whether the current column means anything. The
    // live pair is offered ONLY for a page whose unit is on the link — the same
    // restriction `deviceClassFor` documents, for the same FB-41 reason.
    final devices = context.watch<DeviceController>();
    final facts = context.watch<DeviceFactsController?>();
    final conn = context.read<ConnectionController>();
    final deviceClass = deviceClassFor(
      devices,
      widget.deviceId,
      facts: facts,
      liveDeviceId: widget.live ? widget.deviceId : null,
      liveClass: conn.resolvedClass,
    );
    final shown = listRows.length <= _visibleRows
        ? listRows
        : listRows.sublist(0, _visibleRows);
    final remaining = listRows.length - shown.length;

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
        // ④ The actions, right-aligned — same position as the History tab's
        // (ruled 2026-08-07: between the summary and the rows, where both of
        // their objects begin).
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilterChip2(
                  label: l10n.historyFilterWarning,
                  icon: Icons.warning_amber_rounded,
                  selected: _warningOnly,
                  onTap: _toggleWarning,
                ),
                const SizedBox(width: 7),
                if (_exporting)
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: context.accent.accent),
                      ),
                    ),
                  )
                else
                  FilterChip2(
                    label: l10n.historyExportCsv,
                    icon: Icons.file_download_outlined,
                    filled: true,
                    selected: true,
                    onTap: _exportCsv,
                  ),
              ],
            ),
          ),
        ),
        // ⑤ The rows.
        if (listRows.isEmpty)
          _message(_emptyText(l10n, data.rows.length))
        else
          IndustrialCard(
            padding: const EdgeInsets.all(11),
            child: Column(
              children: [
                // design 0061 T3a, in the History tab's own words: without this
                // the `HH:mm` stamps read as a stored reading rather than as
                // the window they summarise.
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: Text(
                    l10n.historyListMinuteNote,
                    style:
                        TextStyle(fontSize: 10.5, color: context.colors.muted),
                  ),
                ),
                for (final r in shown)
                  HistoryRow(
                    row: r,
                    tempUnit: tempUnit,
                    status: historyClassifyRow(r, ov: ov, uv: uv, ot: ot),
                    deviceClass: deviceClass,
                  ),
                if (remaining > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: TextButton(
                      onPressed: () => _showMore(remaining),
                      child: Text(l10n.deviceHistoryShowMore(remaining)),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// [loaded] is how many windows the query actually returned.
  String _emptyText(AppLocalizations l10n, int loaded) {
    if (_warningOnly) {
      // 🔴 Never "this device has no warnings". The filter runs in Dart AFTER
      // the SQL `LIMIT`, so it has only ever seen the newest [kHistoryRowCap]
      // windows — the History tab wrote the same reasoning down first. Offline
      // there is a SECOND thing it has not seen: the thresholds themselves,
      // which come off the live wire. The copy has to name both, or an empty
      // result reads as an all-clear that nobody actually checked.
      return widget.live
          ? l10n.historyEmptyWarning(loaded)
          : l10n.deviceHistoryEmptyWarningOffline(loaded);
    }
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
