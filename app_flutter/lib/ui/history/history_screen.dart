/// OpenSmartBatt — History screen (mockup screen 4).
///
/// Trend chart (voltage + temperature, dual auto-scaled axes, drawn with
/// CustomPaint — no chart dependency) + min/max/avg stats + a record list with
/// CSV export. Time range (today / last 7 days / all) is chosen with a
/// segmented control and is decoupled from the standalone "warnings" toggle
/// (which filters only the list, not the chart). The chart + stats are computed
/// DB-side via [TelemetryController.historyBuckets] / [historyStats] so large
/// ranges never load every row into Dart. Each list row is classified
/// normal / warning / event (mode = reported status 0/1/2, PROTOCOL.md §6.2;
/// warning compared against the device's live OV/UV/OT thresholds when known).
library;

import 'package:flutter/material.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../data/history_repo.dart';
import '../../models/models.dart';
import '../../protocol/protocol.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../dashboard/power_flow.dart';
import '../util/export_scope.dart';
import '../util/history_csv_export.dart';
import '../widgets/industrial.dart';
import 'minute_seconds_sheet.dart';

/// Selectable chart/list time range.
enum HistoryRange { today, week, all }

/// The export preamble's `window:` value for [r] (FB-60).
///
/// Says WHAT WAS ASKED FOR, which the repo-computed `range: A .. B` cannot: a
/// file whose rows start on Tuesday is a complete "last 7 days" export from a
/// phone that has only been recording since Tuesday, and an incomplete-looking
/// one otherwise. Only this line tells the two apart.
///
/// Machine-stable slugs, never the localized segmented-control captions — the
/// reader of a preamble is whoever receives the file, not the phone that made
/// it (the rule `exportScopeLabel` already follows). [since] is the computed
/// cut-off, appended so the window is reproducible rather than relative to an
/// export timestamp the reader has to do arithmetic on; `all` has none.
String historyWindowLabel(HistoryRange r, DateTime? since) {
  final slug = switch (r) {
    HistoryRange.today => 'today',
    HistoryRange.week => '7d',
    HistoryRange.all => 'all',
  };
  return since == null ? slug : '$slug  since=${since.toIso8601String()}';
}

/// Row classification derived from a stored [TelemetrySample].
///
/// PUBLIC since design 0065: the device detail page renders the same rows with
/// the same three states, and a second enum saying the same three words is how
/// two surfaces start disagreeing about what "warning" means.
enum HistoryRowStatus { normal, warning, event }

/// Most list entries to build widgets for.
///
/// 🔴 **1,000 MINUTE WINDOWS, not 1,000 stored rows** (design 0061 §3.3.3).
/// The number did not change when storage went to one row per second; its
/// meaning did. The list groups by [kHistoryListBucketMs] before this applies,
/// so it still covers 16 h 40 m exactly as it did when a row WAS a minute —
/// that is why the cap did not have to move.
///
/// ⚠️ **It no longer saves any I/O.** It used to bound the rows SQLite
/// touched; it now applies to the output of a `GROUP BY`, and SQLite has to
/// scan and group every row in scope before it knows which windows are the
/// newest — up to 86,400 rows per unit for "today" at second resolution,
/// against 1,440 before. What survives is only the widget bound. The composite
/// `idx_history_device_ts` (schema v17) is what pays for the scan, and it is
/// why that index stopped being optional.
///
/// 🔴 Top-level since design 0065 so the detail page's embedded section uses
/// the SAME cap. A second, smaller cap there would make the two surfaces show
/// different numbers of rows for one unit (design 0065 §6 R5).
const int kHistoryRowCap = 1000;

/// Display window for the list: one minute, always.
///
/// Not the chart's dynamic width. The list is read row by row by a person
/// looking for a moment, so its unit has to stay the same one all day; the
/// chart's job is to fit a span on screen, so its width has to move. They were
/// one number once and it made both worse.
const int kHistoryListBucketMs = 60000;

/// How many points the chart aims for across the visible span.
const int kHistoryTargetBucketPoints = 180;

/// The cut-off for [r] — `null` for [HistoryRange.all], which has none.
///
/// 🔴 Top-level, and the ONLY derivation (design 0065 §6 R5). The History tab
/// and the detail page's embedded section must agree on what "today" means down
/// to the millisecond, or one unit shows two sets of numbers on two screens and
/// the difference is invisible to whoever reports it.
DateTime? historySinceFor(HistoryRange r) {
  final n = DateTime.now();
  switch (r) {
    case HistoryRange.today:
      return DateTime(n.year, n.month, n.day);
    case HistoryRange.week:
      return DateTime(n.year, n.month, n.day).subtract(const Duration(days: 6));
    case HistoryRange.all:
      return null;
  }
}

/// The chart's bucket width for a span starting at [from]: aim for
/// [kHistoryTargetBucketPoints] points, never narrower than a minute nor wider
/// than a day.
///
/// [from] is the range's cut-off, or — for "all" — the oldest stored row; null
/// means there is nothing to span, and the minimum applies.
///
/// 🔴 Top-level for [historySinceFor]'s reason, and this one is the sharper
/// half of it: the width decides how much each plotted point averages, so two
/// surfaces computing it "about the same way" would draw two different-looking
/// charts from identical data (design 0065 §6 R5, pinned by `T65-12`).
int historyChartBucketMs(DateTime? from, {DateTime? now}) {
  final spanMs = from == null
      ? kHistoryListBucketMs
      : (now ?? DateTime.now()).millisecondsSinceEpoch -
          from.millisecondsSinceEpoch;
  return (spanMs ~/ kHistoryTargetBucketPoints)
      .clamp(kHistoryListBucketMs, 24 * 3600000);
}

/// Classify one display window — design 0061 §3.3.2, and the one rule in this
/// file that is worth reading twice.
///
/// 🔴 **Thresholds are judged on the window's EXTREMES, never on its mean.**
/// A minute holds ~60 stored seconds; one of them going over-voltage moves
/// [HistoryListRow.maxPvlt] and leaves the mean flat. Judging on the mean would
/// mark that minute `normal`, drop it out of "warnings only", and so erase — at
/// read time — exactly the instantaneous event that storing seconds exists to
/// preserve. The SQL and this method would both look entirely ordinary while
/// doing it, which is why it is spelled out here and pinned by a test
/// (`history_list_aggregation_test.dart`).
///
/// ⚠️ `mode` reaches here as `MAX(mode)` over the window — "did a cut-off or an
/// anti-theft happen at any point", which is the only reading a discrete status
/// has once a window holds several of them. Averaging a status code is
/// meaningless.
///
/// 🔴 **Null thresholds still classify `event`** and that is load-bearing for
/// design 0065: the detail page withholds `ov`/`uv`/`ot` unless the unit on
/// screen is the unit on the link (§3.2.2), and what survives is the status the
/// DEVICE ITSELF reported. Only the `warning` class is lost. Whoever changes
/// this must not "simplify" the null case into `normal`.
HistoryRowStatus historyClassifyRow(
  HistoryListRow r, {
  double? ov,
  double? uv,
  double? ot,
}) {
  final m = r.sample.mode;
  if (m == ReportedStatus.antiTheftActive ||
      m == ReportedStatus.cutOffActive) {
    return HistoryRowStatus.event;
  }
  // MAX for over-voltage, MIN for under-voltage: each threshold is crossed
  // from its own side, and the extreme on that side is the only value that
  // can answer it.
  final hi = r.maxPvlt;
  final lo = r.minPvlt;
  if (ov != null && hi != null && hi > ov) return HistoryRowStatus.warning;
  if (uv != null && lo != null && lo < uv) return HistoryRowStatus.warning;
  final t = r.maxTemp;
  if (t != null && ot != null && t > ot) return HistoryRowStatus.warning;
  return HistoryRowStatus.normal;
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  // 📌 The three constants that used to live here — the row cap, the list
  // bucket width and the chart's target point count — are now top-level
  // ([kHistoryRowCap] / [kHistoryListBucketMs] / [kHistoryTargetBucketPoints]),
  // shared with design 0065's embedded section. Their documentation moved with
  // them; nothing about their values changed.

  HistoryRange _range = HistoryRange.today; // default
  bool _warningOnly = false;
  bool _exporting = false;

  /// Which unit the chart, the stats AND the list cover.
  ///
  /// Never "all units" any more (design 0043 §3.5). The three product classes
  /// do not share a voltage range — a power bank sits near 3.9 V, a capacitor
  /// near 13.5 V — and the chart aggregates without a device dimension, so an
  /// unscoped view averaged them into a single line matching no physical unit.
  /// Null here means only "not resolved yet"; [_load] fills it on first load
  /// and never leaves it null while [_groups] is non-empty.
  String? _deviceId;

  /// The units history holds rows for — the picker's options, and the reason
  /// the "all devices" entry could be dropped: every row the screen can show
  /// belongs to exactly one of these.
  ///
  /// Kept raw (ids and counts, no labels) so the names and the ordering are
  /// resolved in [build] against the CURRENT saved-device list. Baking labels
  /// in at load time left a unit reading as its hash when the device list
  /// finished loading a moment after this did.
  List<({String deviceId, int count, DateTime lastAt})> _groups = const [];

  late Future<_HistoryData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  TelemetryController get _tele => context.read<TelemetryController>();

  DateTime? _sinceFor(HistoryRange r) => historySinceFor(r);

  Future<_HistoryData> _load() async {
    final tele = _tele;
    // Both controllers are captured now, before the first await: this can be
    // called from initState, and `context.read` after an await may be running
    // against a screen that is already gone. The CONTROLLER is captured, not
    // its list — the saved devices are read at use time, so a device list that
    // finishes loading during this load is still taken into account.
    final devices = context.read<DeviceController>();
    // Same capture rule for design 0057's cache, and the same nullable lookup
    // that lets a harness without one keep working.
    final facts = context.read<DeviceFactsController?>();
    final since = _sinceFor(_range);

    // Options first, and the default chosen FROM them (design 0043 §3.3.1).
    // The seed used to run on the first frame against an already-loaded
    // controller; it now has a database round-trip to lose to, and a seed that
    // loses would leave the scope null with nothing to re-trigger it — an
    // empty screen with no way back. Resolving both inside one load makes that
    // race impossible rather than unlikely.
    final groups = await tele.historyDeviceGroups();
    final options = _optionsFor(groups, devices, facts);
    final known = {for (final o in options) o.id};
    var scoped = _deviceId;
    if (scoped == null || !known.contains(scoped)) {
      // Also the recovery path for a selection that stopped being valid — the
      // unit's rows pruned or cleared away. With no "all devices" entry left,
      // a stale id has no item to sit on.
      scoped = _seedScope(options, tele.recordingDeviceId, devices);
    }
    if (!mounted) {
      return const _HistoryData(
          rows: [],
          buckets: [],
          stats: HistoryStats.empty,
          total: 0,
          bucketMs: kHistoryListBucketMs);
    }
    // The picker sits OUTSIDE the FutureBuilder so that it does not blink out
    // on every range change — which also means the future completing does not
    // rebuild it. This is the one place that can.
    setState(() {
      _groups = groups;
      _deviceId = scoped;
    });

    final total = await tele.historyAttributedCount();
    final stats = await tele.historyStats(since: since, deviceId: scoped);
    // Bucket width: aim for ~180 points across the visible span (>= 1 minute).
    final bucketMs = historyChartBucketMs(since ?? stats.firstAt);
    final buckets = await tele.historyBuckets(
        since: since, bucketMs: bucketMs, deviceId: scoped);
    // One entry per MINUTE, not one per stored row (design 0061 T3a). See
    // [kHistoryRowCap] for what the cap counts now, and [HistoryListRow] for
    // why the window carries its own min/max.
    final rows = await tele.historyListBuckets(
        since: since,
        bucketMs: kHistoryListBucketMs,
        limit: kHistoryRowCap,
        deviceId: scoped);
    return _HistoryData(
        rows: rows,
        buckets: buckets,
        stats: stats,
        total: total,
        bucketMs: bucketMs);
  }

  void _reload() => setState(() => _future = _load());

  void _setRange(HistoryRange r) {
    if (r == _range) return;
    setState(() {
      _range = r;
      _future = _load();
    });
  }

  void _toggleWarning() => setState(() => _warningOnly = !_warningOnly);

  void _setDevice(String id) {
    if (id == _deviceId) return;
    setState(() {
      _deviceId = id;
      _future = _load();
    });
  }

  Future<void> _exportCsv() async {
    if (_exporting) return;
    // The picker chooses WHICH device to export and HOW MUCH DETAIL; it does
    // not replace the time range already chosen on this screen — the two
    // intersect, and the range is what the sheet's size estimate is scoped by.
    final since = _sinceFor(_range);
    final target = await chooseExportScope(
      context,
      offerSession: false,
      offerGranularity: true,
      since: since,
    );
    if (target == null || !mounted) return;
    setState(() => _exporting = true);
    try {
      // 📦 The writing half moved to `history_csv_export.dart` when design 0065
      // gave the device detail page a second export button — unchanged, so that
      // the two surfaces cannot drift into describing one database differently.
      // What stays here is what is genuinely this screen's: its range, and its
      // busy flag.
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
    final tempUnit = context.watch<SettingsController>().tempUnit;
    final tele = context.watch<TelemetryController>();
    final devices = context.watch<DeviceController>();
    // For the class of the unit currently on the link — a never-named unit has
    // no stored class, and the current column is class-gated.
    final conn = context.watch<ConnectionController>();
    // Watched, not read: a fact learned mid-connection (the `0x10` byte for a
    // unit nobody named) has to reach the rows already on screen — that is the
    // whole of design 0057 G2 for the live case.
    final facts = context.watch<DeviceFactsController?>();
    final ov = tele.warnOv, uv = tele.warnUv, ot = tele.warnOt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        ?_deviceBar(),
        Expanded(
          child: RefreshIndicator(
            color: context.accent.accent,
            backgroundColor: context.colors.panel,
            onRefresh: () async => _reload(),
            child: FutureBuilder<_HistoryData>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return _scrollable(
                    Padding(
                      padding: EdgeInsets.only(top: 80),
                      child: Center(
                        child:
                            CircularProgressIndicator(color: context.accent.accent),
                      ),
                    ),
                  );
                }
                if (snap.hasError) {
                  return _scrollable(
                      _message(l10n.historyLoadFailed('${snap.error}')));
                }
                final data = snap.data ??
                    const _HistoryData(
                        rows: [],
                        buckets: [],
                        stats: HistoryStats.empty,
                        total: 0,
                        bucketMs: kHistoryListBucketMs);
                final listRows =
                    _applyWarning(data.rows, ov: ov, uv: uv, ot: ot);
                final chartEmpty = data.buckets.length < 2;
                if (data.rows.isEmpty && chartEmpty) {
                  return _scrollable(_message(_emptyText(data.rows.length)));
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
                  children: [
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
                    _actionRow(),
                    if (listRows.isEmpty)
                      _message(_emptyText(data.rows.length))
                    else
                      IndustrialCard(
                        padding: const EdgeInsets.all(11),
                        child: Column(
                          children: [
                            // design 0061 T3a: the list shows one row per
                            // minute, and says so. Without this line the
                            // `HH:mm` stamps read as a stored reading rather
                            // than as the window they summarise.
                            Padding(
                              padding: const EdgeInsets.only(bottom: 9),
                              child: Text(
                                l10n.historyListMinuteNote,
                                style: TextStyle(
                                    fontSize: 10.5, color: context.colors.muted),
                              ),
                            ),
                            for (final r in listRows)
                              HistoryRow(
                                row: r,
                                tempUnit: tempUnit,
                                status: historyClassifyRow(r,
                                    ov: ov, uv: uv, ot: ot),
                                // design 0074. EVERY row, not only the ones
                                // with seconds in them (Q3): the sheet is
                                // where "this minute predates per-second
                                // recording" gets said, and a row that simply
                                // does not respond says it much worse.
                                onTap: () => showMinuteSecondsSheet(
                                  context,
                                  row: r,
                                  tempUnit: tempUnit,
                                  deviceClass: deviceClassFor(
                                    devices,
                                    r.deviceId,
                                    facts: facts,
                                    liveDeviceId: tele.recordingDeviceId,
                                    liveClass: conn.resolvedClass,
                                  ),
                                  ov: ov,
                                  uv: uv,
                                  ot: ot,
                                ),
                                // Class-gated, not data-driven — and the class
                                // now decides the WORDING as well as the
                                // presence (design 0056). See
                                // [historyCurrentBit] for all three cases.
                                deviceClass: deviceClassFor(
                                  devices,
                                  r.deviceId,
                                  facts: facts,
                                  liveDeviceId: tele.recordingDeviceId,
                                  liveClass: conn.resolvedClass,
                                ),
                              ),
                          ],
                        ),
                      ),
                    _footer(data.total),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  // ---- pieces -----------------------------------------------------------

  /// Gap between the two actions.
  static const double _kToolbarActionGap = 7;

  /// The two actions — filter and export — as one right-aligned group.
  ///
  /// Built here rather than inline because they have TWO homes: normally the
  /// device-scope card (see [_deviceBar]), and the toolbar line when there is
  /// no device bar to put them in. Getting that wrong would make export
  /// unreachable on a phone with nothing saved, which is exactly the phone
  /// whose owner is most likely to be sending us a file.
  /// The two actions, as a right-aligned row of their own.
  ///
  /// 🔴 Position ruled 2026-08-07: BETWEEN the chart card and the list.
  ///
  /// They began on the toolbar line, abutting the range picker — reported as
  /// 「太擠」. They are not view options for the whole screen: the warning
  /// filter acts on the list below, and export acts on what is being shown. So
  /// they sit at the boundary between the summary and the rows, which is where
  /// both of their objects begin.
  ///
  /// ⚠️ Rendered in EVERY branch, including the empty state. A phone whose
  /// entire history predates attribution shows "no device records" — and those
  /// rows are precisely the ones that are still exportable (see the header of
  /// `history_default_scope_test.dart`). An export button that disappears
  /// exactly for the owner who needs it would be the worst possible place to
  /// lose it.
  Widget _actionRow() => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Align(alignment: Alignment.centerRight, child: _actions()),
      );

  Widget _actions() {
    final l10n = AppLocalizations.of(context);
    final warning = FilterChip2(
      label: l10n.historyFilterWarning,
      icon: Icons.warning_amber_rounded,
      selected: _warningOnly,
      onTap: _toggleWarning,
    );
    final export = _exporting
        ? SizedBox(
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
        : FilterChip2(
            label: l10n.historyExportCsv,
            icon: Icons.file_download_outlined,
            filled: true,
            selected: true,
            onTap: _exportCsv,
          );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        warning,
        const SizedBox(width: _kToolbarActionGap),
        export,
      ],
    );
  }

  /// The range picker, alone on its line.
  ///
  /// 🔴 It used to share the line with the two actions, and the measured
  /// breakpoint below is why: on a 320 pt phone the one-line form needed
  /// 184.1 px for the three zh labels and got 175.7, and the overflow was
  /// SILENT — the control clips, so 「全部」 was simply missing.
  ///
  /// Reported 2026-08-07 as「太擠」, which it was even where it fitted: three
  /// unrelated groups of controls abutting each other with 7-8 px between
  /// them. The actions moved into the device-scope card, so this line now has
  /// the width to itself and the breakpoint arithmetic is gone with the
  /// problem it measured.
  Widget _toolbar() {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 8, 15, 8),
      child: SegmentedControl<HistoryRange>(
        selected: _range,
        onChanged: _setRange,
        options: <({HistoryRange value, String label})>[
          (value: HistoryRange.today, label: l10n.historyRangeToday),
          (value: HistoryRange.week, label: l10n.historyRangeWeek),
          (value: HistoryRange.all, label: l10n.historyRangeAll),
        ],
      ),
    );
  }

  /// Device scope. Shown whenever there is anything to show — including with a
  /// single option (design 0043 §3.7). It stopped being a switcher the moment
  /// "all devices" went away: with the view permanently scoped to one unit, the
  /// bar is how the screen says WHICH unit these numbers belong to, and that
  /// sentence is needed just as much when there is only one answer to it.
  Widget? _deviceBar() {
    final options = _optionsFor(
      _groups,
      context.watch<DeviceController>(),
      context.watch<DeviceFactsController?>(),
    );
    final selected = _deviceId;
    // Both empty only before the first load has resolved; `selected` is kept
    // inside `options` by [_load], and a Dropdown whose value is not among its
    // items throws.
    if (options.isEmpty || selected == null) return null;
    if (!options.any((o) => o.id == selected)) return null;
    // 🔴 In a panel, like every other block on this screen.
    //
    // It used to be a bare icon and a dropdown floating on the page
    // background, wedged between the toolbar and the chart card — reported
    // 2026-08-07 as wanting「像 block 一樣加入一白框」. It says WHICH unit every
    // number below belongs to, which is the same kind of statement the cards
    // make, so it should look like one.
    //
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 0, 15, 0),
      child: IndustrialCard(
        padding: const EdgeInsets.fromLTRB(11, 5, 7, 5),
        child: Row(
          children: [
            Icon(Icons.devices_other, size: 15, color: context.colors.muted),
            const SizedBox(width: 7),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: selected,
                  isDense: true,
                  isExpanded: true,
                  style: TextStyle(fontSize: 12.5, color: context.colors.text),
                  dropdownColor: context.colors.panel2,
                  items: [
                    for (final o in options)
                      DropdownMenuItem<String>(
                        value: o.id,
                        child: Text(o.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (id) {
                    if (id != null) _setDevice(id);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(int total) {
    return IndustrialCard(
      child: Text(
        AppLocalizations.of(context).historyFooter(total),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: context.colors.muted),
      ),
    );
  }

  Widget _scrollable(Widget child) => ListView(
        padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
        children: [_actionRow(), child],
      );

  Widget _message(String text) => Padding(
        padding: const EdgeInsets.only(top: 70),
        child: Center(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: context.colors.muted),
          ),
        ),
      );

  /// [loaded] is how many windows the query actually returned — see the
  /// warnings branch.
  String _emptyText(int loaded) {
    final l10n = AppLocalizations.of(context);
    // No unit has a single row: say so once, in these words, whatever else the
    // database still holds (design 0043 §3.6.1). A phone whose entire history
    // predates device attribution lands here and is told nothing about those
    // rows — deliberately. They are not a category a user should have to learn
    // about; they remain on disk and remain exportable.
    if (_groups.isEmpty) return l10n.historyEmptyNoDevices;
    // 🔴 The claim is bounded by what was actually looked at (design 0061 T12 /
    // Q5). "No warnings" was a statement about the whole history, and the
    // filter has never seen the whole history: `_applyWarning` runs in Dart,
    // AFTER the SQL `LIMIT`, so it can only speak for the newest [_rowCap]
    // windows. The defect was not the filter — it was a screen asserting
    // something it had not checked.
    //
    // ⚠️ The number is the rows that CAME BACK, never the `_rowCap` constant: a
    // phone holding 40 minutes of data that announced "no warnings in the last
    // 1,000 records" would be telling a bigger lie in more precise words.
    if (_warningOnly) return l10n.historyEmptyWarning(loaded);
    // The view is always scoped to one unit now, which makes the old "no
    // records today" wrong as often as not: there may be plenty of records,
    // they just belong to a different unit.
    return l10n.historyEmptyDeviceRange;
  }

  /// Order the picker: units the user can still put a name to first, most
  /// recently seen among them first, then the rest by their own newest row.
  ///
  /// Two halves with two sort keys, because they have to be. `lastSeen` lives
  /// in the saved-device table, so a unit whose record was deleted — or never
  /// created, saving being a manual step — has none to sort by. Ordering those
  /// by their newest history row is the closest honest equivalent.
  ///
  /// A unit with no saved record shows as its short hash. Design 0022 rejected
  /// sourcing this list from history for exactly that reason; design 0043 §3.4
  /// reverses the priority, because "ugly but reachable" beats "tidy but
  /// permanently invisible" — and invisible is what those rows were.
  static List<_DeviceOption> _optionsFor(
    List<({String deviceId, int count, DateTime lastAt})> groups,
    DeviceController devices,
    DeviceFactsController? facts,
  ) {
    // DeviceController hands its list back most-recently-seen first, so the
    // index IS the lastSeen order; deriving a second one here would be a second
    // answer to a question already answered.
    final rank = <String, int>{
      for (var i = 0; i < devices.devices.length; i++) devices.devices[i].id: i,
    };
    final named = <({String deviceId, int count, DateTime lastAt})>[];
    final orphans = <({String deviceId, int count, DateTime lastAt})>[];
    for (final g in groups) {
      // 🔴 Asked WITHOUT `facts`, deliberately (design 0057 §4.3). The question
      // here is not "does this unit have a name" but "does it have a place in
      // the saved-device order" — the `named` branch sorts by `rank[id]!`, and
      // only a saved unit has a rank. A unit known solely from `device_facts`
      // now HAS a name, so passing the cache in would put it in the branch that
      // then dereferences a null rank. Its label still shows that name; it is
      // ordered by recency instead, which is the honest order for a unit with
      // no saved record.
      (deviceNameFor(devices, g.deviceId).isNotEmpty ? named : orphans).add(g);
    }
    named.sort((a, b) => rank[a.deviceId]!.compareTo(rank[b.deviceId]!));
    orphans.sort((a, b) => b.lastAt.compareTo(a.lastAt));
    return [
      for (final g in [...named, ...orphans])
        _DeviceOption(
          id: g.deviceId,
          label: deviceLabelFor(devices, g.deviceId, facts: facts),
        ),
    ];
  }

  /// The default unit (design 0043 §3.3): the one being recorded, else the one
  /// seen most recently, else simply the first option.
  ///
  /// Every step is intersected with [options]. Seeding to a unit that has no
  /// history rows — which the saved-device list is full of, since a record
  /// outlives the rows and can exist before any — would open the screen on a
  /// guaranteed-blank chart.
  static String? _seedScope(
    List<_DeviceOption> options,
    String? recording,
    DeviceController devices,
  ) {
    if (options.isEmpty) return null;
    final known = {for (final o in options) o.id};
    if (recording != null && known.contains(recording)) return recording;
    for (final d in devices.devices) {
      if (known.contains(d.id)) return d.id;
    }
    // Nothing in the picker has a saved record left: fall back to the first
    // option, which by [_optionsFor] is the one with the newest row.
    return options.first.id;
  }

  // ---- filtering / classification --------------------------------------

  List<HistoryListRow> _applyWarning(
    List<HistoryListRow> rows, {
    double? ov,
    double? uv,
    double? ot,
  }) =>
      historyApplyWarningFilter(rows,
          warningOnly: _warningOnly, ov: ov, uv: uv, ot: ot);
}

/// The "warnings only" filter, as one function both surfaces call.
///
/// [warningOnly] is passed in rather than read from a screen's state so the
/// pass-through case lives here too — the identity return matters, because a
/// caller memoising on the result's object identity (design 0065 §3.5.2) would
/// otherwise rebuild every time the filter is off.
List<HistoryListRow> historyApplyWarningFilter(
  List<HistoryListRow> rows, {
  required bool warningOnly,
  double? ov,
  double? uv,
  double? ot,
}) {
  if (!warningOnly) return rows;
  return rows
      .where((r) =>
          historyClassifyRow(r, ov: ov, uv: uv, ot: ot) !=
          HistoryRowStatus.normal)
      .toList(growable: false);
}

/// Whether a display window would be filtered INTO the "warnings only" list.
///
/// Exists for one test — the one that pins design 0061 §3.3.2 — so that the
/// min/max rule can be asserted directly instead of through a pumped screen.
/// Returns false for `normal`, true for `warning` and `event`, which is exactly
/// what [historyApplyWarningFilter] keeps.
bool historyWindowIsFlagged(
  HistoryListRow row, {
  double? ov,
  double? uv,
  double? ot,
}) =>
    historyClassifyRow(row, ov: ov, uv: uv, ot: ot) != HistoryRowStatus.normal;

/// One entry in the device picker.
///
/// The group's row count is deliberately NOT carried here: it exists to be
/// summed against [HistoryRepo.countAttributed], and that check belongs where
/// both halves are — in the repository, not in a widget.
class _DeviceOption {
  const _DeviceOption({required this.id, required this.label});

  final String id;

  /// Alias, else advertised name, else the short hash — never blank, and never
  /// the raw id, which is a MAC address on Android.
  final String label;
}

class _HistoryData {
  const _HistoryData({
    required this.rows,
    required this.buckets,
    required this.stats,
    required this.total,
    required this.bucketMs,
  });

  /// One entry per DISPLAY WINDOW (a minute), not per stored row.
  final List<HistoryListRow> rows;
  final List<HistoryBucket> buckets;
  final HistoryStats stats;

  /// The CHART's bucket width for this load — dynamic, 1 minute to 24 hours,
  /// and until design 0061 T10 it appeared nowhere on screen.
  final int bucketMs;

  /// Rows carrying a device — what the screen is able to show, and therefore
  /// what the footer counts (design 0043 §3.2).
  final int total;
}

// ====================== trend chart + stats =============================

double _toDisplayTemp(double c, TempUnit u) =>
    u == TempUnit.fahrenheit ? c * 9 / 5 + 32 : c;

String _tempUnitLabel(TempUnit u) => u == TempUnit.fahrenheit ? '°F' : '°C';

/// Legend + dual-axis chart (tap a point for that bucket's detail) + stats.
///
/// PUBLIC since design 0065 §3.2.1 ③ — the detail page's embedded section shows
/// the same chart for one unit. Every input is a plain value; it reads no
/// provider, which is what makes it reusable at all.
///
/// 🔑 The stats strip is INSIDE this card (the last child of its `build`), so a
/// caller wanting "chart + min/avg/max" needs nothing else.
class HistoryTrendCard extends StatefulWidget {
  const HistoryTrendCard({
    super.key,
    required this.buckets,
    required this.stats,
    required this.tempUnit,
    required this.multiDay,
    required this.bucketMs,
  });

  final List<HistoryBucket> buckets;
  final HistoryStats stats;
  final TempUnit tempUnit;
  final bool multiDay;

  /// How wide one point is. Design 0061 T10: it ranges from 1 minute to 24
  /// hours depending on the span, and the screen used to say only how many
  /// SAMPLES were behind a point — never how much TIME.
  final int bucketMs;

  @override
  State<HistoryTrendCard> createState() => _HistoryTrendCardState();
}

class _HistoryTrendCardState extends State<HistoryTrendCard> {
  static const double _chartH = 160;
  int? _selected;

  bool get _hasTemp =>
      widget.buckets.any((b) => b.avgTemp != null) ||
      widget.stats.avgTemp != null;

  @override
  void didUpdateWidget(HistoryTrendCard old) {
    super.didUpdateWidget(old);
    // Data reloaded (range change / refresh): drop a now-invalid selection.
    if (_selected != null && _selected! >= widget.buckets.length) {
      _selected = null;
    } else if (old.buckets.length != widget.buckets.length) {
      _selected = null;
    }
  }

  void _onTapDown(double dx, double width) {
    final n = widget.buckets.length;
    if (n < 2) return;
    final left = 40.0, right = _hasTemp ? 40.0 : 8.0;
    final plotW = width - left - right;
    if (plotW <= 0) return;
    final frac = ((dx - left) / plotW).clamp(0.0, 1.0);
    final i = (frac * (n - 1)).round().clamp(0, n - 1);
    setState(() => _selected = _selected == i ? null : i);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final buckets = widget.buckets;
    final hasTemp = _hasTemp;
    if (buckets.length < 2) {
      // 🔴 FB-85. The strip used to be skipped with the chart, and the two are
      // not the same question: a chart point is [historyChartBucketMs] wide,
      // but [HistoryStats] is one aggregate over the whole range and needs no
      // bucket at all. So a unit could hold a night's readings and show NO
      // NUMBER — the min/avg/max it already had, withheld because the curve
      // could not be drawn.
      //
      // 🔑 Not a rare edge. `historyChartBucketMs` is `(now − local midnight) /
      // 180`, clamped to a 1-minute floor, so for the whole first minute after
      // LOCAL MIDNIGHT "today" is shorter than one bucket and no amount of data
      // can make two points. A device recording all night hits this every night.
      // (It is also reachable at any hour by a unit whose rows all fall inside
      // one bucket — a link that came up seconds ago.)
      //
      // `stats.count` rather than `buckets.isEmpty` is the gate: it is the
      // question being asked — "is there anything to report" — and the callers
      // that draw their own empty state (`device_history_section`) check rows,
      // which can disagree with buckets by exactly the case above.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: widget.stats.count > 0 ? 64 : 120,
            child: Center(
              child: Text(l10n.historyChartInsufficientData,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: context.colors.muted)),
            ),
          ),
          if (widget.stats.count > 0) ...[
            const SizedBox(height: 10),
            _StatsStrip(
                stats: widget.stats, tempUnit: widget.tempUnit, hasTemp: hasTemp),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Legend.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _LegendDot(color: context.accent.accent, label: l10n.historyLegendVoltage),
            if (hasTemp) ...[
              const SizedBox(width: 16),
              _LegendDot(
                  color: context.accent.accentSecondary, label: l10n.historyLegendTemperature),
            ],
            // FB-74. Unlabelled shading reads as a rendering flourish; this is
            // the one thing on the chart that says an instantaneous event is
            // visible at all, so it gets a legend entry rather than a footnote.
            const SizedBox(width: 16),
            _LegendBand(
                color: context.accent.accent, label: l10n.historyLegendRange),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _onTapDown(d.localPosition.dx, w),
              child: SizedBox(
                height: _chartH,
                child: CustomPaint(
                  size: Size(w, _chartH),
                  painter: _TrendPainter(
                    buckets: buckets,
                    tempUnit: widget.tempUnit,
                    hasTemp: hasTemp,
                    multiDay: widget.multiDay,
                    bucketMs: widget.bucketMs,
                    selected: _selected,
                    vColor: context.accent.accent,
                    tColor: context.accent.accentSecondary,
                    grid: context.colors.line,
                    text: context.colors.muted,
                  ),
                ),
              ),
            );
          },
        ),
        if (_selected != null && _selected! < buckets.length)
          _detail(context, l10n, buckets[_selected!], hasTemp),
        // design 0061 T10. `historyDetailSamples` says how MANY readings a
        // point folded; nothing said how much TIME it covered, and the width
        // moves between 1 minute and 24 hours with the range. At second
        // resolution the guess a reader would make is further out than ever.
        const SizedBox(height: 8),
        Text(
          _bucketWidthNote(l10n, widget.bucketMs),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, color: context.colors.muted),
        ),
        const SizedBox(height: 10),
        _StatsStrip(stats: widget.stats, tempUnit: widget.tempUnit, hasTemp: hasTemp),
      ],
    );
  }

  Widget _detail(BuildContext context, AppLocalizations l10n, HistoryBucket b,
      bool hasTemp) {
    final fmt = DateFormat(widget.multiDay ? 'MM/dd HH:mm' : 'HH:mm');
    String v(double? x) => x == null ? '--' : x.toStringAsFixed(2);
    // FB-74: the temperature half of this line used to be the mean alone, while
    // the voltage half already carried its (min–max). A bucket whose hottest
    // second is the reason the user tapped it would answer with an average.
    String t(double c) =>
        _toDisplayTemp(c, widget.tempUnit).toStringAsFixed(0);
    final u = _tempUnitLabel(widget.tempUnit);
    final tLo = b.minTemp, tHi = b.maxTemp;
    final tempStr = b.avgTemp == null
        ? null
        : (tLo == null || tHi == null)
            ? '${t(b.avgTemp!)}$u'
            : '${t(b.avgTemp!)}$u (${t(tLo)}–${t(tHi)}$u)';
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: context.colors.panel2,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: context.colors.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fmt.format(b.at),
                    style: AppTextStyles.mono(context).copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: context.colors.text)),
                const SizedBox(height: 3),
                Text(
                  '${l10n.historyLegendVoltage} ${v(b.avgPvlt)}V '
                  '(${v(b.minPvlt)}–${v(b.maxPvlt)})'
                  '${tempStr != null ? '  ·  ${l10n.historyLegendTemperature} $tempStr' : ''}',
                  style: TextStyle(fontSize: 11, color: context.colors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(l10n.historyDetailSamples(b.count),
              style: TextStyle(fontSize: 10, color: context.colors.muted)),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => setState(() => _selected = null),
            child: Icon(Icons.close, size: 15, color: context.colors.muted),
          ),
        ],
      ),
    );
  }
}

/// "Each point on the chart averages N minutes / hours" — design 0061 T10.
///
/// Hours once the width reaches one, because "each point averages 1440 minutes"
/// is a number nobody converts. Rounded to whole units: the width is derived
/// from a span divided by a target point count, so it lands on values like
/// 3.7 minutes, and a note reading "3.7 minutes" would be answering a precision
/// question nobody asked.
String _bucketWidthNote(AppLocalizations l10n, int bucketMs) {
  final minutes = (bucketMs / 60000).round().clamp(1, 1 << 30);
  if (minutes < 60) return l10n.historyChartBucketMinutes(minutes);
  return l10n.historyChartBucketHours((minutes / 60).round().clamp(1, 1 << 30));
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(fontSize: 10.5, color: context.colors.muted)),
      ],
    );
  }
}

/// Legend swatch for the min–max band — a translucent slab, drawn with the same
/// alpha the painter fills the band with so the key and the chart match.
class _LegendBand extends StatelessWidget {
  const _LegendBand({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 9,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(fontSize: 10.5, color: context.colors.muted)),
      ],
    );
  }
}

class _StatsStrip extends StatelessWidget {
  const _StatsStrip(
      {required this.stats, required this.tempUnit, required this.hasTemp});
  final HistoryStats stats;
  final TempUnit tempUnit;
  final bool hasTemp;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String v(double? x) => x == null ? '--' : '${x.toStringAsFixed(2)}V';
    String t(double? x) => x == null
        ? '--'
        : '${_toDisplayTemp(x, tempUnit).toStringAsFixed(0)}${_tempUnitLabel(tempUnit)}';
    return Column(
      children: [
        _statRow(context, context.accent.accent, l10n.historyLegendVoltage,
            min: v(stats.minPvlt),
            avg: v(stats.avgPvlt),
            max: v(stats.maxPvlt),
            l10n: l10n),
        if (hasTemp) ...[
          const SizedBox(height: 6),
          _statRow(context, context.accent.accentSecondary, l10n.historyLegendTemperature,
              min: t(stats.minTemp),
              avg: t(stats.avgTemp),
              max: t(stats.maxTemp),
              l10n: l10n),
        ],
      ],
    );
  }

  Widget _statRow(BuildContext context, Color accent, String title,
      {required String min,
      required String avg,
      required String max,
      required AppLocalizations l10n}) {
    return Row(
      children: [
        Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 7),
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
        SizedBox(
          width: 56,
          child: Text(title,
              style: TextStyle(fontSize: 10.5, color: context.colors.muted),
              overflow: TextOverflow.ellipsis),
        ),
        Expanded(child: _stat(context, l10n.historyStatMin, min)),
        Expanded(child: _stat(context, l10n.historyStatAvg, avg)),
        Expanded(child: _stat(context, l10n.historyStatMax, max)),
      ],
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 8.5, color: context.colors.muted)),
        Text(value,
            style: AppTextStyles.mono(context)
                .copyWith(fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// The chart's left-axis window, in volts — FB-74.
///
/// 🔴 **Computed over the buckets' EXTREMES, never over their means alone.**
/// This is the chart-side half of the defect design 0061 §6.0 pinned for the
/// list: one second at 15.5 V inside a one-hour bucket moves `avgPvlt` by about
/// four millivolts, so an axis scaled from the means tops out just above the
/// ordinary running voltage — and the min–max band drawn below would then be
/// clipped off the top of the plot, silently. The stats strip immediately under
/// the chart reports the range-wide `MAX` from raw rows, so an averaged axis
/// also puts a number on screen (15.5 V) that the picture above it flatly
/// contradicts and gives the reader no way to locate in time.
///
/// PUBLIC-ish (used by `history_chart_aggregation_test.dart`) for the same
/// reason [historyWindowIsFlagged] is: the rule is worth pinning without
/// pumping a screen.
({double lo, double hi}) historyChartVoltageRange(List<HistoryBucket> buckets) {
  double? lo, hi;
  void see(double? v) {
    if (v == null) return;
    if (lo == null || v < lo!) lo = v;
    if (hi == null || v > hi!) hi = v;
  }

  for (final b in buckets) {
    see(b.avgPvlt);
    see(b.minPvlt);
    see(b.maxPvlt);
  }
  var vlo = (lo ?? 0) - 0.2, vhi = (hi ?? 1) + 0.2;
  if (vhi - vlo < 0.5) {
    final m = (vlo + vhi) / 2;
    vlo = m - 0.25;
    vhi = m + 0.25;
  }
  return (lo: vlo, hi: vhi);
}

/// The chart's right-axis window, in DISPLAY temperature units — FB-74.
///
/// Same rule and same reason as [historyChartVoltageRange]: a bucket's hottest
/// second is the one worth seeing, and it is not in the mean.
({double lo, double hi}) historyChartTempRange(
    List<HistoryBucket> buckets, TempUnit unit) {
  double? lo, hi;
  void see(double? c) {
    if (c == null) return;
    final d = _toDisplayTemp(c, unit);
    if (lo == null || d < lo!) lo = d;
    if (hi == null || d > hi!) hi = d;
  }

  for (final b in buckets) {
    see(b.avgTemp);
    see(b.minTemp);
    see(b.maxTemp);
  }
  // No temperature anywhere in range: the same placeholder window the axis has
  // always fallen back to, kept identical so a chart with no temperature draws
  // exactly as it did before.
  var tlo = (lo ?? 0) - 1, thi = (hi ?? 1) + 1;
  if (thi - tlo < 2) {
    final m = (tlo + thi) / 2;
    tlo = m - 1;
    thi = m + 1;
  }
  return (lo: tlo, hi: thi);
}

/// Build the chart's painter outside the screen, for `history_chart_aggregation_test.dart`.
///
/// The test drives [CustomPainter.paint] against a recording canvas and asserts
/// that the min–max band is actually on the canvas and actually reaches above
/// the mean line. Reaching that through a pumped History screen would mean
/// standing up a controller, a database and a device picker to assert one thing
/// about one `drawPath`.
CustomPainter historyTrendPainterForTest({
  required List<HistoryBucket> buckets,
  TempUnit tempUnit = TempUnit.celsius,
  bool hasTemp = false,
  bool multiDay = false,
  int bucketMs = 60000,
  int? selected,
  // The test asserts geometry, not hue, so the DEFAULT set is the honest
  // stand-in — but it is a parameter rather than a literal so a colour test
  // can drive the painter with a non-amber set, which is the only way the
  // "voltage series still follows the theme" regression is visible at all
  // (in amber, every one of these colours is what it always was).
  AccentTheme accent = AccentTheme.amber,
}) =>
    _TrendPainter(
      buckets: buckets,
      tempUnit: tempUnit,
      hasTemp: hasTemp,
      multiDay: multiDay,
      bucketMs: bucketMs,
      selected: selected,
      vColor: accent.accent,
      tColor: accent.accentSecondary,
      grid: const Color(0xFF333333),
      text: const Color(0xFF888888),
    );

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.buckets,
    required this.tempUnit,
    required this.hasTemp,
    required this.multiDay,
    required this.bucketMs,
    required this.selected,
    required this.vColor,
    required this.tColor,
    required this.grid,
    required this.text,
  });

  final List<HistoryBucket> buckets;
  final TempUnit tempUnit;
  final bool hasTemp;
  final bool multiDay;
  final int bucketMs;
  final int? selected;
  final Color vColor, tColor, grid, text;

  @override
  void paint(Canvas canvas, Size size) {
    final left = 40.0, right = hasTemp ? 40.0 : 8.0, top = 8.0, bottom = 18.0;
    final plotW = size.width - left - right;
    final plotH = size.height - top - bottom;
    final n = buckets.length;

    // Axis windows. FB-74: both are scaled to include the buckets' MIN/MAX, not
    // just their means — see [historyChartVoltageRange] for why an averaged
    // axis would clip the very thing the band below exists to show.
    final vr = historyChartVoltageRange(buckets);
    final vlo = vr.lo, vhi = vr.hi;
    final tr = historyChartTempRange(hasTemp ? buckets : const [], tempUnit);
    final tlo = tr.lo, thi = tr.hi;

    double xAt(int i) => left + (n == 1 ? plotW / 2 : plotW * (i / (n - 1)));
    double yV(double v) => top + plotH * (1 - (v - vlo) / (vhi - vlo));
    double yT(double v) => top + plotH * (1 - (v - tlo) / (thi - tlo));

    void tp(String s, double x, double y,
        {bool rightAlign = false, Color? c}) {
      final p = TextPainter(
        text: TextSpan(
            text: s, style: TextStyle(color: c ?? text, fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(canvas, Offset(rightAlign ? x - p.width : x, y));
    }

    final gridPaint = Paint()
      ..color = grid.withValues(alpha: 0.5)
      ..strokeWidth = 1;

    // Horizontal grid + left (V) / right (T) axis labels at lo/mid/hi.
    for (final f in [0.0, 0.5, 1.0]) {
      final y = top + plotH * (1 - f);
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), gridPaint);
      tp((vlo + (vhi - vlo) * f).toStringAsFixed(1), left - 4, y - 6,
          rightAlign: true, c: vColor);
      if (hasTemp) {
        tp((tlo + (thi - tlo) * f).toStringAsFixed(0), size.width - right + 4,
            y - 6, c: tColor);
      }
    }

    // X time labels (start / end).
    //
    // 🔴 The format follows the BUCKET WIDTH, not just `multiDay` (design 0061
    // T13b). A bare `MM/dd` only tells the truth when a point IS a day: "last
    // 7 days" buckets at ~56 minutes, so two adjacent points would carry the
    // identical date and the axis would claim a resolution it does not have.
    // Since T13 the day boundary is the viewer's local midnight, so `MM/dd` is
    // finally correct in the one case it applies to.
    final fmt = DateFormat(
        multiDay ? (bucketMs >= 24 * 3600000 ? 'MM/dd' : 'MM/dd HH:mm') : 'HH:mm');
    tp(fmt.format(buckets.first.at), left, size.height - 12);
    tp(fmt.format(buckets.last.at), size.width - right, size.height - 12,
        rightAlign: true);

    // Selection crosshair (vertical guide), drawn under the series.
    final sel = selected;
    if (sel != null && sel >= 0 && sel < n) {
      final sx = xAt(sel);
      canvas.drawLine(
          Offset(sx, top),
          Offset(sx, top + plotH),
          Paint()
            ..color = text.withValues(alpha: 0.55)
            ..strokeWidth = 1);
    }

    // Polyline helper that breaks across nulls.
    void drawLine(double? Function(HistoryBucket) sel, double Function(double) y,
        Color color) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      Path? path;
      for (var i = 0; i < n; i++) {
        final raw = sel(buckets[i]);
        if (raw == null) {
          if (path != null) {
            canvas.drawPath(path, paint);
            path = null;
          }
          continue;
        }
        final pt = Offset(xAt(i), y(raw));
        if (path == null) {
          path = Path()..moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      if (path != null) canvas.drawPath(path, paint);
    }

    /// The MIN–MAX band for one series, filled under its mean line — FB-74.
    ///
    /// 🔴 This is the only thing on the chart that can show an INSTANT. The
    /// line is the bucket's mean, and a bucket is 1 minute to 24 hours wide: a
    /// single second at 15.5 V inside an hour moves the mean by about four
    /// millivolts and is, on the line alone, indistinguishable from nothing
    /// having happened. The user paid 60× the storage for that second (design
    /// 0061); averaging it back out at read time is the same defect §6.0
    /// pinned for the list, wearing different clothes.
    ///
    /// Bands break across nulls exactly where the line does, so a gap in the
    /// data cannot be filled in by a shape that spans it. A run of ONE bucket
    /// has no width, so it is stroked as a vertical whisker instead of filled —
    /// otherwise an isolated bucket (a single minute after a long gap) would
    /// produce a degenerate zero-area path and its spike would be the one thing
    /// on the chart nobody could see.
    void drawBand(double? Function(HistoryBucket) loSel,
        double? Function(HistoryBucket) hiSel, double Function(double) y,
        Color color) {
      final fill = Paint()
        ..color = color.withValues(alpha: 0.22)
        ..style = PaintingStyle.fill;
      final whisker = Paint()
        ..color = color.withValues(alpha: 0.45)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      bool has(int i) => loSel(buckets[i]) != null && hiSel(buckets[i]) != null;
      var i = 0;
      while (i < n) {
        if (!has(i)) {
          i++;
          continue;
        }
        var j = i;
        while (j + 1 < n && has(j + 1)) {
          j++;
        }
        if (i == j) {
          canvas.drawLine(Offset(xAt(i), y(hiSel(buckets[i])!)),
              Offset(xAt(i), y(loSel(buckets[i])!)), whisker);
        } else {
          final path = Path()..moveTo(xAt(i), y(hiSel(buckets[i])!));
          for (var k = i + 1; k <= j; k++) {
            path.lineTo(xAt(k), y(hiSel(buckets[k])!));
          }
          for (var k = j; k >= i; k--) {
            path.lineTo(xAt(k), y(loSel(buckets[k])!));
          }
          canvas.drawPath(path..close(), fill);
        }
        i = j + 1;
      }
    }

    if (hasTemp) {
      double? t(double? c) => c == null ? null : _toDisplayTemp(c, tempUnit);
      drawBand((b) => t(b.minTemp), (b) => t(b.maxTemp), yT, tColor);
    }
    drawBand((b) => b.minPvlt, (b) => b.maxPvlt, yV, vColor);

    if (hasTemp) {
      drawLine((b) => b.avgTemp == null
          ? null
          : _toDisplayTemp(b.avgTemp!, tempUnit), yT, tColor);
    }
    drawLine((b) => b.avgPvlt, yV, vColor);

    // Emphasized markers at the selected bucket (over the series).
    if (sel != null && sel >= 0 && sel < n) {
      final b = buckets[sel];
      final sx = xAt(sel);
      if (b.avgPvlt != null) {
        final c = Offset(sx, yV(b.avgPvlt!));
        canvas.drawCircle(c, 4.5, Paint()..color = vColor);
        canvas.drawCircle(
            c,
            4.5,
            Paint()
              ..color = grid
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
      if (hasTemp && b.avgTemp != null) {
        canvas.drawCircle(
            Offset(sx, yT(_toDisplayTemp(b.avgTemp!, tempUnit))),
            4.5,
            Paint()..color = tColor);
      }
    }

    // Latest voltage marker + value.
    for (var i = n - 1; i >= 0; i--) {
      final a = buckets[i].avgPvlt;
      if (a == null) continue;
      final lx = xAt(i), ly = yV(a);
      canvas.drawCircle(Offset(lx, ly), 3, Paint()..color = vColor);
      tp('${a.toStringAsFixed(2)}V', lx - 2, ly - 16,
          rightAlign: true, c: vColor);
      break;
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.selected != selected ||
      old.buckets.length != buckets.length ||
      old.hasTemp != hasTemp ||
      old.tempUnit != tempUnit ||
      (buckets.isNotEmpty &&
          old.buckets.isNotEmpty &&
          old.buckets.last.at != buckets.last.at);
}

// ====================== list row + status tag ===========================

/// The `電流 …` fragment of a history row's sub-line, or null when the row's
/// unit cannot measure current at all.
///
/// 🔴 THE CLASS DECIDES, and it decides three different things — which is why
/// this is a function and not a `showCurrent` bool (its previous shape):
///
///  * **super-capacitor** — no fragment. Its `0x2E` is pinned at 0.0 A on a
///    unit that cannot measure current, and the CSV already blanks the column;
///    showing it here would have the two disagree about the same row.
///  * **battery** — MAGNITUDE plus a direction word (design 0056, ruled
///    2026-08-11). A bare `-35.0A` is the FB-47 defect: two people who knew the
///    protocol read one as a fault rather than as a direction.
///  * **power bank** — magnitude plus a word as well (ruled 2026-08-11, after
///    the battery shipped), but through its OWN derivation: `0x4A − 0x49` is
///    positive while DIScharging, the exact opposite of `0x2E`, so `packFlowOf`
///    would label it backwards. This is the family FB-47 was actually filed on,
///    which is why leaving it as the only bare signed number in the app did not
///    survive review.
///  * **a row whose class is unknown** — the stored number, signed, exactly as
///    before. Written before history carried a device id at all, it has no
///    family to pick a convention from, and guessing one is FB-43's shape.
///
/// PUBLIC so a test can call it without pumping the whole screen; the widget
/// test that proves the row actually renders it lives beside it.
String? historyCurrentBit(
    AppLocalizations l10n, ProductClass cls, double amps) {
  if (cls == ProductClass.supercapacitor) return null;
  if (cls == ProductClass.unknown) {
    return l10n.historyRowCurrent(amps.toStringAsFixed(1));
  }
  // 🔑 The direction is derived from the number the reader can SEE, not from
  // the stored one. A history row is a MINUTE AVERAGE, so unlike the live card
  // it is a float — and `packFlowOf`'s 1.5 A line would otherwise put −1.46 and
  // −1.52 on opposite sides of it while BOTH print as `1.5A`. Two rows, the
  // same visible number, different words, is a bug report waiting to happen.
  // Rounding first makes the word answerable from the row itself.
  final shown = (amps * 10).roundToDouble() / 10;
  // 🔴 ONE derivation per family, and never the other one's.
  //
  // Each keeps its own dead-band, because each band is a fact about its own
  // register rather than a taste setting:
  //
  //  * pack — the SAME 1.5 A line as the live readout. Averaging does not
  //    recover what quantisation threw away: `0x2E` is 1 A per count and a
  //    device that truncates reports a true 0.4 A as 0 in every sample of the
  //    minute, so an average inside one count is no more trustworthy than an
  //    instantaneous reading inside one count. A second, tighter threshold here
  //    would mean the same battery reads 靜置 on one screen and 放電中 on the
  //    other — the disagreement `power_flow.dart` exists to prevent.
  //  * power bank — its own 0.05 A band, at mA resolution.
  //
  // ⚠️ THE RAIL-OFF VETO CANNOT APPLY HERE, and that is a real limitation
  // rather than an oversight: the veto reads the same burst's `0x4B` b7, and
  // history stores no flag column (see the schema in `app_database.dart`) — a
  // per-minute average of a bit-field would not be one anyway. So a unit with
  // the RSPB-01 residual (a constant 58–69 mA charge-side offset with its boost
  // rail off) will show a small CHARGING row where the live screen reads
  // STANDBY. `powerFlowOf` is called with no flags, which is exactly its
  // documented pre-veto behaviour; widening the band here instead would be a
  // second derivation, which is the thing this comment exists to forbid.
  final flow =
      cls == ProductClass.powerBank ? powerFlowOf(shown) : packFlowOf(shown);
  // Its own vocabulary too. Nothing new was coined for this: `powerBankDirection*`
  // has been on the SOC dial and the energy-path row since design 0037. Sharing
  // ONE set of keys across the families would mean a wording change made for a
  // car battery silently rewording a power bank.
  final direction = cls == ProductClass.powerBank
      ? switch (flow) {
          PowerFlow.charging => l10n.powerBankDirectionCharging,
          PowerFlow.discharging => l10n.powerBankDirectionDischarging,
          PowerFlow.idle || PowerFlow.unknown => l10n.powerBankDirectionIdle,
        }
      : switch (flow) {
          PowerFlow.charging => l10n.packDirectionCharging,
          PowerFlow.discharging => l10n.packDirectionDischarging,
          PowerFlow.idle || PowerFlow.unknown => l10n.packDirectionIdle,
        };
  return l10n.historyRowCurrentDirected(
      shown.abs().toStringAsFixed(1), direction);
}

/// One display window as a list row.
///
/// PUBLIC since design 0065 §3.2.1 ⑤. Every input is a plain value — including
/// [status], which the CALLER classifies: the detail page has to withhold the
/// live thresholds when the unit on screen is not the unit on the link
/// (§3.2.2), and a widget that classified for itself would have to be told the
/// same thing anyway, one layer deeper.
class HistoryRow extends StatelessWidget {
  const HistoryRow({
    super.key,
    required this.row,
    required this.tempUnit,
    required this.status,
    required this.deviceClass,
    this.onTap,
    this.showSeconds = false,
  });

  /// One display WINDOW (a minute), not a stored row — design 0061 T3a.
  final HistoryListRow row;

  /// Opens this window's drill-down (design 0074). Null leaves the row inert
  /// and unchanged — the chevron appears only when there is something to tap.
  ///
  /// 🔑 **Every row gets one, including a minute with no seconds in it**
  /// (design 0074 Q3, ruled 2026-08-19). Rows recorded before per-second
  /// storage cannot be expanded, but making exactly those rows dead is worse
  /// than opening a sheet that says why: the two kinds sit interleaved in one
  /// list, so "half the rows do not respond" is what a broken screen looks
  /// like. The sheet explains; the list does not have to.
  final VoidCallback? onTap;

  /// Print `HH:mm:ss` instead of `HH:mm` — design 0074 §3.6.
  ///
  /// 🔵 **This is the EXTENSION of design 0061 T3c, not a reversal of it.**
  /// T3c forbids a seconds place on the LIST, for two reasons that both hold
  /// there and neither of which holds here: the stamp was always `:00`, and the
  /// row is a minute window over per-second storage so a seconds figure would
  /// name one of sixty readings arbitrarily. Inside the drill-down a row IS one
  /// second's measurement, so the seconds place is the honest part of it. See
  /// the `HH:mm` comment in [build].
  final bool showSeconds;

  TelemetrySample get sample => row.sample;

  /// The stored product class of the row's unit, or [ProductClass.unknown] for
  /// a row written before history rows were attributed to a device at all.
  /// Read only by [historyCurrentBit] — see there for what each value means.
  final ProductClass deviceClass;

  final TempUnit tempUnit;
  final HistoryRowStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tap = onTap;
    final body = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colors.panel2,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: context.colors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              // 🔴 `HH:mm`, not `HH:mm:ss` (design 0061 T3c). The seconds place
              // was always `00` — every stored row was a whole minute — so it
              // was decoration that read as precision. It is now doubly wrong
              // to print: the row is a MINUTE WINDOW over per-second storage,
              // so a seconds figure would name one of sixty readings and
              // there would be no saying which.
              //
              // 🔵 **[showSeconds] is the one exception, and it does not
              // contradict the paragraph above** — design 0074 §3.6 (Q4, ruled
              // 2026-08-19). Inside the drill-down a row is ONE SECOND's
              // measurement, so neither reason applies. Read [showSeconds]
              // before concluding this screen prints seconds anywhere else.
              DateFormat(showSeconds ? 'HH:mm:ss' : 'HH:mm')
                  .format(sample.timestamp),
              style: AppTextStyles.mono(context).copyWith(
                fontSize: 10.5,
                color: context.colors.muted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_primaryLine(),
                    style: AppTextStyles.mono(context)
                        .copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(
                  _subLine(l10n),
                  style:
                      TextStyle(fontSize: 10.5, color: context.colors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _StatusTag(status: status),
          if (tap != null)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Icon(Icons.chevron_right,
                  size: 16, color: context.colors.muted),
            ),
        ],
      ),
    );
    if (tap == null) return body;
    // The ripple has to be UNDER the row's own background or it never shows —
    // the Container above paints `panel2` opaquely over anything Material would
    // draw behind it. Wrapping the other way round (InkWell inside) would put
    // the tap target inside the padding and lose the row's edges.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: body,
      ),
    );
  }

  String _primaryLine() {
    final parts = <String>[];
    final v = sample.pvlt;
    parts.add(v == null ? '—' : '${v.toStringAsFixed(2)} V');
    final t = sample.temperatureC;
    if (t != null) {
      final unit = _tempUnitLabel(tempUnit);
      final str = tempUnit == TempUnit.fahrenheit
          ? _toDisplayTemp(t.toDouble(), tempUnit).toStringAsFixed(0)
          : t.toString();
      parts.add('$str$unit');
    }
    return parts.join(' · ');
  }

  String _subLine(AppLocalizations l10n) {
    switch (status) {
      case HistoryRowStatus.event:
        // FB-79. A window is a minute and a minute can hold BOTH modes, in
        // which case `sample.mode` — `MAX(mode)` — names only the cut-off and
        // the anti-theft leaves no trace on this screen at all. It is the
        // anti-theft that trips later, on a current spike, so this row is
        // exactly where an owner reconstructing "what happened at 19:45" needs
        // to be told both. `row.sawX` are the un-collapsed answer; `status` and
        // the badge still come from `MAX(mode)` and do not move.
        if (row.sawAntiTheft && row.sawCutOff) {
          return l10n.historyRowEventCutOffAndAntiTheft;
        }
        return sample.mode == ReportedStatus.cutOffActive
            ? l10n.historyRowEventCutOff
            : l10n.historyRowEventAntiTheft;
      case HistoryRowStatus.warning:
        return _warningText(l10n);
      case HistoryRowStatus.normal:
        final bits = <String>[];
        if (sample.sohBucket != null) {
          bits.add(l10n.historyRowSoh(sample.sohBucket!));
        }
        if (sample.current != null) {
          final bit = historyCurrentBit(l10n, deviceClass, sample.current!);
          if (bit != null) bits.add(bit);
        }
        return bits.isEmpty ? l10n.commonNormal : bits.join(' · ');
    }
  }

  String _warningText(AppLocalizations l10n) {
    final bits = <String>[];
    if (sample.sohBucket != null) {
      bits.add(l10n.historyRowSoh(sample.sohBucket!));
    }
    bits.add(l10n.historyRowThresholdWarning);
    return bits.join(' · ');
  }
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.status});

  final HistoryRowStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    late final Color fg;
    late final String label;
    // 🔴 Three row states, three fixed status colours (design 0064). `event`
    // used to be `context.accent.accentSecondary` — the same constant the temperature series
    // and the gauge sub-line use, which now follow the accent. Splitting the
    // name is what stops the next person taking this switch along with them.
    switch (status) {
      case HistoryRowStatus.normal:
        fg = AppSemantics.good;
        label = l10n.commonNormal;
      case HistoryRowStatus.warning:
        fg = AppSemantics.warn;
        label = l10n.commonWarning;
      case HistoryRowStatus.event:
        fg = AppSemantics.event;
        label = l10n.historyStatusEvent;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: fg.withValues(alpha: 0.32)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 9, letterSpacing: 1, color: fg),
      ),
    );
  }
}
