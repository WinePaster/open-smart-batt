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

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../data/history_repo.dart';
import '../../models/models.dart';
import '../../protocol/protocol.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../dashboard/power_flow.dart';
import '../util/alert_thresholds_lookup.dart';
import '../util/export_scope.dart';
import '../util/history_csv_export.dart';
import '../widgets/industrial.dart';
import 'custom_range_sheet.dart';
import 'history_chart_core.dart';
import 'history_chart_page.dart';
import 'history_query.dart';
import 'minute_seconds_sheet.dart';

// ⚠️ `export` alone does not put those names in THIS library's scope — the
// import above is what lets this file go on using them unchanged.
export 'history_chart_core.dart';
export 'history_query.dart';

// ---------------------------------------------------------------------------
// 🔵 **The shared kernel moved to `history_query.dart` on 2026-08-21**
// (design 0079 S4 / owner ruling Q5): `HistoryRange`, `historyWindowLabel`,
// `HistoryRowStatus`, the three constants, `historySinceFor`,
// `historyChartBucketMs`, `historyClassifyRow` — plus the three queries
// themselves, which both surfaces had been issuing from their own `_load`.
//
// 🔑 **Re-exported below rather than moved-and-fixed-up**, and that is the
// point: every existing importer — this file's own callers, the detail page,
// and a dozen test files — keeps working with no edit at all. A consolidation
// whose first act is to break thirty imports gets reverted; one that is
// invisible from the outside gets kept.
// ---------------------------------------------------------------------------

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

  /// 🔵 **A selection, not just a preset name** (design 0083 S2). It carries
  /// the two ends when the user picks a custom span; the three presets still
  /// derive theirs from the clock at read time. S2 wires the type through so
  /// that S3 only has to add the entry point.
  ///
  /// ⛔ **Not persisted, not shared with the device page** (🔵 Q5／Q6 ruled
  /// 2026-08-23): leaving this screen resets it, and the detail page keeps its
  /// own.
  HistoryRangeSel _sel = HistoryRangeSel.initial;

  /// The SCOPED unit's full span — the calendar's bounds and the button's
  /// enabled state (design 0083 §3.3.4). See the device page's twin; loaded
  /// once per unit, and the picker above this screen can change which unit
  /// that is.
  HistoryStats? _extent;
  String? _extentFor;
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

  ({DateTime? since, DateTime? until}) get _bounds => historyBoundsFor(_sel);

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
    final (:since, :until) = _bounds;

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
        bucketMs: kHistoryListBucketMs,
      );
    }
    // The picker sits OUTSIDE the FutureBuilder so that it does not blink out
    // on every range change — which also means the future completing does not
    // rebuild it. This is the one place that can.
    setState(() {
      _groups = groups;
      _deviceId = scoped;
    });

    // 🔴 The whole-database figure is THIS screen's, and stays here: it counts
    // every unit, which is meaningful under a device picker and would be a
    // confidently wrong number on a single unit's page (design 0065 §3.2.3).
    final total = await tele.historyAttributedCount();
    // 🔵 The three queries now come from [loadHistorySlice] (design 0079 S4).
    // Same three, same order, same arguments as before — the change is that
    // the detail page's tab can no longer drift from them, which is what
    // design 0065 §6 R5 had only a comment to enforce.
    // 🔑 Once per unit, and the device picker is what changes the unit. Not
    // one of "the three" — see [TelemetryController.historyExtent].
    if (_extentFor != scoped) {
      final extent = await tele.historyExtent(deviceId: scoped);
      if (!mounted) {
        return const _HistoryData(
          rows: [],
          buckets: [],
          stats: HistoryStats.empty,
          total: 0,
          bucketMs: kHistoryListBucketMs,
        );
      }
      setState(() {
        _extent = extent;
        _extentFor = scoped;
      });
    }
    final slice = await loadHistorySlice(
      tele,
      since: since,
      until: until,
      deviceId: scoped,
    );
    return _HistoryData(
      rows: slice.rows,
      buckets: slice.buckets,
      stats: slice.stats,
      total: total,
      bucketMs: slice.bucketMs,
    );
  }

  /// The far end of what the landscape page may pan to, or null when there is
  /// nothing to expand into.
  ///
  /// 🔴 **Null when the recording has no width**: a unit whose rows all fall
  /// inside one instant would open a page whose window is zero milliseconds
  /// wide, and every division in [HistoryChartWindow] would be against that.
  /// Hiding the button is the honest answer — there is nothing to zoom.
  DateTime? _expandTarget(HistoryStats stats) {
    final a = stats.firstAt, b = stats.lastAt;
    if (a == null || b == null) return null;
    return b.difference(a).inMilliseconds < kHistoryListBucketMs ? null : b;
  }

  /// The family the CHART may assume, or null when the scope is 「全部裝置」 —
  /// design 0085 S3 (FB-101).
  ///
  /// 🔴 **A wrapper exists because [deviceClassFor] answers the wrong thing for
  /// a null id.** It returns [ProductClass.unknown], which downstream means
  /// "one unit whose family nobody recorded" — a case where current IS plotted
  /// (unsigned-labelled, exactly as the list row does it). The all-devices
  /// scope is not that: `queryBuckets` groups by time and not by `device_id`,
  /// so a single bucket can average a battery's −3 A discharge with a power
  /// bank's +3 A discharge and produce 0 A. Passing `unknown` here would draw
  /// that as a unit sitting at rest.
  ///
  /// ⛔ Do not "simplify" this into a direct [deviceClassFor] call.
  ProductClass? _chartDeviceClass(
    DeviceController devices, {
    DeviceFactsController? facts,
    String? liveDeviceId,
    ProductClass liveClass = ProductClass.unknown,
  }) {
    final id = _deviceId;
    if (id == null) return null;
    return deviceClassFor(
      devices,
      id,
      facts: facts,
      liveDeviceId: liveDeviceId,
      liveClass: liveClass,
    );
  }

  void _reload() => setState(() => _future = _load());

  /// 🔵 **[HistoryRange.custom] opens the picker instead of selecting.**
  /// design 0083 Q1 was re-ruled 2026-08-24 (see [_toolbar]) and this is where
  /// the fourth segment stops being like the other three: the preset segments
  /// ARE the selection, while "custom" is a request for two dates that the
  /// user has not given yet.
  ///
  /// ⚠️ Re-tapping it while a custom range is already in force re-opens the
  /// sheet on the CURRENT span (`initial:` below) rather than doing nothing —
  /// a selected segment that ignores taps is how a user with the wrong month
  /// showing gets stuck.
  void _setRange(HistoryRange r) => r == HistoryRange.custom
      ? _pickCustomRange()
      : _select(HistoryRangeSel.preset(r));

  /// Open the date picker — see the device page's twin.
  Future<void> _pickCustomRange() async {
    final e = _extent;
    if (e?.firstAt == null || e?.lastAt == null) return;
    final picked = await showCustomRangeSheet(
      context,
      firstData: e!.firstAt!,
      lastData: e.lastAt!,
      initial: _sel.isCustom ? _sel : null,
    );
    if (picked != null) _select(picked);
  }

  /// 🔑 The ONE way the selection changes — presets and (from S3) the custom
  /// picker both come through here, so neither can forget to re-query.
  void _select(HistoryRangeSel next) {
    if (next == _sel) return;
    setState(() {
      _sel = next;
      _future = _load();
    });
  }

  void _toggleWarning() => setState(() => _warningOnly = !_warningOnly);

  void _setDevice(String id) {
    if (id == _deviceId) return;
    setState(() {
      _deviceId = id;
      // 🔴 Dropped with the unit — see the device page's twin. Otherwise the
      // calendar would briefly offer the previous unit's dates as this one's.
      _extent = null;
      _extentFor = null;
      _future = _load();
    });
  }

  Future<void> _exportCsv() async {
    if (_exporting) return;
    // The picker chooses WHICH device to export and HOW MUCH DETAIL; it does
    // not replace the time range already chosen on this screen — the two
    // intersect, and the range is what the sheet's size estimate is scoped by.
    // 🔵 **Both ends, everywhere (design 0083 S4).** The picker chooses WHICH
    // device and HOW MUCH DETAIL; it does not replace the time range already
    // chosen on this screen — the two intersect, and the range is what the
    // sheet's size estimate is scoped by.
    final (:since, :until) = _bounds;
    final target = await chooseExportScope(
      context,
      offerSession: false,
      offerGranularity: true,
      since: since,
      until: until,
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
        until: until,
        window: historyWindowLabel(_sel, since),
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
    // 🔵 **Design 0080 §3.8 (P2): resolved per SCOPED unit, not read off the
    // link.** `tele.warnOv/warnUv/warnOt` used to be read here directly, and on
    // this screen that was design 0079 §0.3's defect in its purest form — the
    // picker above chooses which unit's rows are listed, and the thresholds
    // colouring them came from whichever unit the phone happened to be holding.
    // Pick a capacitor while a battery is connected and every row was judged
    // against the battery's limits.
    //
    // It also brings this surface under the one-source rule: a user's own
    // threshold now colours the list here exactly as it does on the device
    // page, instead of the two screens disagreeing about one unit.
    final thresholds = watchAlertThresholds(context, _deviceId);
    final ov = thresholds.ov.value,
        uv = thresholds.uv.value,
        ot = thresholds.ot.value;
    final framing = historyChartFraming(l10n, _sel);

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
                        child: CircularProgressIndicator(
                          color: context.accent.accent,
                        ),
                      ),
                    ),
                  );
                }
                if (snap.hasError) {
                  return _scrollable(
                    _message(l10n.historyLoadFailed('${snap.error}')),
                  );
                }
                final data =
                    snap.data ??
                    const _HistoryData(
                      rows: [],
                      buckets: [],
                      stats: HistoryStats.empty,
                      total: 0,
                      bucketMs: kHistoryListBucketMs,
                    );
                final listRows = _applyWarning(
                  data.rows,
                  ov: ov,
                  uv: uv,
                  ot: ot,
                );
                final chartEmpty = data.buckets.length < 2;
                if (data.rows.isEmpty && chartEmpty) {
                  return _scrollable(_message(_emptyText(data.rows.length)));
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
                  children: [
                    IndustrialCard(
                      // 🔵 One derivation for both surfaces (design 0079 S4).
                      heading: framing.heading,
                      headingIcon: Icons.show_chart,
                      child: HistoryTrendCard(
                        sel: _sel,
                        buckets: data.buckets,
                        stats: data.stats,
                        tempUnit: tempUnit,
                        multiDay: framing.multiDay,
                        bucketMs: data.bucketMs,
                        // 🔴 **null when the scope is 「全部裝置」** — design
                        // 0085 Q4 ③. This screen is the one surface that can
                        // be pointed at several units at once, and
                        // `queryBuckets` groups by TIME, not by `device_id`:
                        // one bucket may hold a battery and a power bank,
                        // whose currents are signed the opposite way round
                        // (`power_flow.dart`). Averaged together they cancel
                        // to 0 A and would be drawn as "at rest".
                        //
                        // ⚠️ `deviceClassFor` cannot express this: it answers
                        // `unknown` for a null id, and `unknown` means "one
                        // unit, family unrecorded" — a case where current IS
                        // drawn. Hence the explicit branch rather than passing
                        // the call through.
                        deviceClass: _chartDeviceClass(
                          devices,
                          facts: facts,
                          liveDeviceId: tele.recordingDeviceId,
                          liveClass: conn.resolvedClass,
                        ),
                        // 🔵 design 0081 S3. The card owns the BUTTON; this
                        // owns the destination — including which unit and how
                        // far back it may pan, both of which this screen has
                        // already resolved and the card deliberately has not.
                        onExpand: _expandTarget(data.stats) == null
                            ? null
                            : () => showHistoryChartPage(
                                context,
                                deviceId: _deviceId,
                                // Same resolution as the card above — the two
                                // shells share one painter, so they must not
                                // disagree about whether current is offered.
                                deviceClass: _chartDeviceClass(
                                  devices,
                                  facts: facts,
                                  liveDeviceId: tele.recordingDeviceId,
                                  liveClass: conn.resolvedClass,
                                ),
                                title: deviceLabelFor(
                                  devices,
                                  _deviceId,
                                  facts: facts,
                                ),
                                tempUnit: tempUnit,
                                dataFrom: data.stats.firstAt!,
                                dataTo: _expandTarget(data.stats)!,
                              ),
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
                                  fontSize: 10.5,
                                  color: context.colors.muted,
                                ),
                              ),
                            ),
                            for (final r in listRows)
                              HistoryRow(
                                row: r,
                                tempUnit: tempUnit,
                                status: historyClassifyRow(
                                  r,
                                  ov: ov,
                                  uv: uv,
                                  ot: ot,
                                ),
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
                  strokeWidth: 2,
                  color: context.accent.accent,
                ),
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

  /// The range picker, alone on its line — and since 2026-08-24 the WHOLE of
  /// it: the calendar button that shared this line became the fourth segment.
  ///
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
      // 🔵 **design 0083 Q1 RE-RULED 2026-08-24: 案 C ⇒ 案 A.** Owner, verbatim:
      // 「我以為你要把歷史紀錄的日期區間的設定按鈕 放在 今天/近7天/全部的右邊
      // 放一個自訂」. 案 C put a bare calendar `IconButton` there instead, and
      // a glyph whose only label is a long-press tooltip does not read as a
      // fourth choice in the same group as the other three.
      //
      // 🔑 Giving the segment back its label costs NOTHING here, and that is
      // the arithmetic 案 C got wrong: the button it replaces was eating
      // `6 + 40` px of this very row, so the control goes 244 px ⇒ **290 px**
      // — the whole line, exactly what it had before design 0083 touched it.
      // Measured 2026-08-24 with `segmentedControlNaturalWidth`, 320 pt:
      // zh four segments need 211.0 / 229.1 / 247.3 / 265.4 at the four text
      // scales this repo tests ⇒ ✅ every one of them.
      //
      // ⚠️ English four segments need 266.0 at 1.0× (✅) and 292.4 at 1.15×,
      // which is 2.4 px over — a KNOWN, logged limit, not an oversight. Unlike
      // the detail row there is nothing else on this line to move to a second
      // one, so the fallback there does not exist here; the failure is an
      // ellipsis, not a missing segment (design 0083 §1.5①).
      child: SegmentedControl<HistoryRange>(
        selected: _sel.kind,
        onChanged: _setRange,
        // 🔴 Disabled rather than absent when the unit has no records. A
        // segment that comes and goes would move the other three under the
        // user's finger the moment a first row lands.
        //
        // ⚠️ `|| _sel.isCustom` because a SELECTED segment that is also inert
        // is a trap: the user would be looking at a custom range with no way
        // back into the sheet to change it. If a span is in force there was
        // data to pick it from, whatever the extent query says now.
        disabled: (_extent != null && _extent!.count > 0) || _sel.isCustom
            ? const {}
            : const {HistoryRange.custom},
        disabledTooltip: l10n.historyCustomRangeNoData,
        options: <({HistoryRange value, String label})>[
          (value: HistoryRange.today, label: l10n.historyRangeToday),
          (value: HistoryRange.week, label: l10n.historyRangeWeek),
          (value: HistoryRange.all, label: l10n.historyRangeAll),
          (value: HistoryRange.custom, label: l10n.historyRangeCustom),
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
        child: _DeviceScopeMenu(
          options: options,
          selected: selected,
          onChanged: _setDevice,
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
  }) => historyApplyWarningFilter(
    rows,
    warningOnly: _warningOnly,
    ov: ov,
    uv: uv,
    ot: ot,
  );
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
      .where(
        (r) =>
            historyClassifyRow(r, ov: ov, uv: uv, ot: ot) !=
            HistoryRowStatus.normal,
      )
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

/// Trigger-row height. 24 pt is exactly what `DropdownButton(isDense: true)`
/// gave the row this replaces (`_kDenseButtonHeight`, `material/dropdown.dart`),
/// pinned so swapping the control moved nothing else on the page.
const double _kScopeRowHeight = 24;

/// Gap between the trigger row and the menu. 6 pt clears the card's own 5 pt
/// bottom padding, so the menu opens just below the card rather than on it.
const double _kScopeMenuGap = 6;

/// Menu-row height floor. Below the 48 pt the Material menu used, because these
/// rows sit in a compact industrial layout — but not so far below that the
/// list stops being tappable with a thumb.
const double _kScopeItemMinHeight = 40;

/// The device picker: a trigger row that fills the scope card, and its menu.
///
/// 🔴 NOT a [DropdownButton], and the reason is geometry. Material 2's dropdown
/// INFLATES the button's rect by `EdgeInsetsDirectional.only(start: 16, end:
/// 24)` before positioning the menu (`_kUnalignedMenuMargin`,
/// `material/dropdown.dart`), then clamps the result onto the screen. Inside
/// this card — 15 pt page margin, 11/7 pt card padding — that arithmetic put
/// the menu at `32 .. screen width` at EVERY width measured (320 / 360 /
/// 411 pt, 2026-08-20): 40 pt wider than the control that opened it, hard
/// against the right edge of the screen, 15 pt outside the card it belongs to
/// while inset 17 pt from it on the left. Reported 2026-08-20 as 「跑版」, and
/// the asymmetry is why it read as broken rather than merely wide.
///
/// [MenuAnchor] puts its menu at `alignment.withinRect(anchorRect)`, so
/// anchoring to the row makes the menu start where the row starts; the width is
/// pinned to the row's own measured width rather than assumed, because the
/// card's padding is the only thing that decides it. Both properties are locked
/// down in `history_device_menu_test.dart` — at the same three widths, since a
/// single width is exactly how the original defect stayed invisible.
class _DeviceScopeMenu extends StatefulWidget {
  const _DeviceScopeMenu({
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<_DeviceOption> options;

  /// Always one of [options] — the caller drops the bar entirely rather than
  /// render a picker that cannot show what it is set to.
  final String selected;

  final ValueChanged<String> onChanged;

  @override
  State<_DeviceScopeMenu> createState() => _DeviceScopeMenuState();
}

class _DeviceScopeMenuState extends State<_DeviceScopeMenu> {
  final MenuController _menu = MenuController();

  /// Drives the caret only. [MenuAnchor] does not rebuild its builder when the
  /// menu opens, so the arrow would otherwise point down at an open menu.
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = widget.options
        .firstWhere((o) => o.id == widget.selected)
        .label;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return MenuAnchor(
          controller: _menu,
          // The tap that dismisses must not ALSO hit whatever is underneath —
          // the chart card and the list rows below both take taps of their own.
          consumeOutsideTap: true,
          onOpen: () => setState(() => _open = true),
          onClose: () => setState(() => _open = false),
          alignmentOffset: const Offset(0, _kScopeMenuGap),
          style: MenuStyle(
            // Explicit: the M3 default for a menu panel is `topEnd`, which is
            // the submenu case, and it would hang this menu off the row's
            // top-right corner.
            alignment: AlignmentDirectional.bottomStart,
            backgroundColor: WidgetStatePropertyAll(colors.panel2),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(4),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(vertical: 4),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                side: BorderSide(color: colors.line),
              ),
            ),
          ),
          menuChildren: [
            for (final o in widget.options)
              _DeviceScopeMenuItem(
                width: width,
                label: o.label,
                selected: o.id == widget.selected,
                onTap: () {
                  _menu.close();
                  // Re-selecting the current unit is a dismissal, not a
                  // reload: `_setDevice` re-queries and rebuilds the chart.
                  if (o.id != widget.selected) widget.onChanged(o.id);
                },
              ),
          ],
          builder: (context, controller, _) => InkWell(
            // The WHOLE row, icon included — that is also what makes the anchor
            // rect the full width of the card's content box, which is what the
            // menu aligns itself to.
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: SizedBox(
              height: _kScopeRowHeight,
              child: Row(
                children: [
                  Icon(Icons.devices_other, size: 15, color: colors.muted),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: colors.text),
                    ),
                  ),
                  Icon(
                    _open ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                    size: 24,
                    color: colors.muted,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One row of the device menu.
///
/// [width] is the anchor row's width, handed down rather than measured again:
/// the menu panel takes its width from its widest child, so this is what keeps
/// the panel exactly as wide as the control that opened it.
class _DeviceScopeMenuItem extends StatelessWidget {
  const _DeviceScopeMenuItem({
    required this.width,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final double width;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: width,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _kScopeItemMinHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w400,
                        color: selected ? context.accent.accent : colors.text,
                      ),
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 7),
                    Icon(Icons.check, size: 14, color: context.accent.accent),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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

/// Legend + dual-axis chart (tap or scrub for a bucket's detail) + stats.
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
    required this.deviceClass,
    this.sel,
    this.onExpand,
  });

  final List<HistoryBucket> buckets;
  final HistoryStats stats;
  final TempUnit tempUnit;
  final bool multiDay;

  /// The family whose rows these buckets are, or **null for a scope holding
  /// more than one unit** — design 0085 S3 (FB-101).
  ///
  /// 🔴 **Required, and required as a NULLABLE**, so that every caller has to
  /// answer rather than inherit a default. The two answers behave in opposite
  /// ways and only one of them is safe to guess wrong in the harmless
  /// direction: a class makes the current series available and picks its
  /// direction wording per family, while null disables it outright
  /// ([historyChartCurrentGate]). A defaulted `unknown` would have silently
  /// enabled current on the "all devices" scope, which is the one case the
  /// ruling exists to prevent.
  ///
  /// ⚠️ [ProductClass.unknown] is NOT null's synonym here: it is one unit whose
  /// family nobody has recorded, and its stored amperes are still one
  /// convention. Current is drawn for it, with the zero line left unlabelled —
  /// the same thing the list row does (`historyCurrentBit`).
  final ProductClass? deviceClass;

  /// What the user selected, so the card can name a custom span
  /// (design 0083 §3.3.5).
  ///
  /// 🔑 In the CARD, like the expand button and for the same reason: both
  /// landing sites get it from one edit. Null (or a preset) draws nothing —
  /// the three existing ranges keep exactly the layout height they had.
  final HistoryRangeSel? sel;

  /// How wide one point is. Design 0061 T10: it ranges from 1 minute to 24
  /// hours depending on the span, and the screen used to say only how many
  /// SAMPLES were behind a point — never how much TIME.
  final int bucketMs;

  /// 🔵 **Q1 = E2 — the expand button, and where the destination lives.**
  ///
  /// The BUTTON is in this card (so both landing sites get it, identically,
  /// from one edit); the PAGE it opens is the caller's business. That split is
  /// why this is a callback and not a `deviceId`: the card stays a widget whose
  /// every input is a plain value and which reads no provider, which is the
  /// property that made it reusable at two sites in the first place.
  ///
  /// Null ⇒ no button. Tests that only care about the curve need not route.
  final VoidCallback? onExpand;

  @override
  State<HistoryTrendCard> createState() => _HistoryTrendCardState();
}

class _HistoryTrendCardState extends State<HistoryTrendCard> {
  static const double _chartH = 160;
  int? _selected;

  /// Which quantity the LEFT axis is drawing — design 0085 §3.1 案 B (FB-101).
  ///
  /// 🔑 **Per card instance, and deliberately not remembered anywhere else.**
  /// The two landing sites are two different questions ("this unit" vs "the
  /// scope I picked"), and a preference shared between them would be a state
  /// with two owners — the shape the corpus files as 「狀態散到兩處」. Voltage is
  /// the opening view because it is what every existing screenshot, every
  /// support answer and the stats strip below all describe.
  HistoryChartSeries _series = HistoryChartSeries.voltage;

  bool get _hasTemp =>
      widget.buckets.any((b) => b.avgTemp != null) ||
      widget.stats.avgTemp != null;

  @override
  void didUpdateWidget(HistoryTrendCard old) {
    super.didUpdateWidget(old);
    // 🔴 A class arriving late must not leave the axis on a series it is no
    // longer allowed to draw. `deviceClassFor` resolves through saved record →
    // cached facts → live link, so a unit CAN go from `unknown` (current
    // offered) to `supercapacitor` (current refused) while this card is on
    // screen. `build` recomputes the effective series from the gate anyway, so
    // the picture is never wrong for a frame — this line is about the state
    // agreeing with the picture, so that a later re-classification does not
    // silently pop current back on.
    if (historyChartCurrentGate(widget.deviceClass) !=
        HistoryChartCurrentGate.available) {
      _series = HistoryChartSeries.voltage;
    }
    // Data reloaded (range change / refresh): drop a now-invalid selection.
    if (_selected != null && _selected! >= widget.buckets.length) {
      _selected = null;
    } else if (old.buckets.length != widget.buckets.length) {
      _selected = null;
    }
  }

  /// 🔵 design 0081 S2: the geometry needs the BUCKETS now, not just how many
  /// of them there are — the x axis is time, so where a point lands depends on
  /// when it was recorded.
  HistoryChartGeometry _geometry(double width) => HistoryChartGeometry(
    width: width,
    hasTemp: _hasTemp,
    buckets: widget.buckets,
    bucketMs: widget.bucketMs,
  );

  /// The bucket the pointer went down on, and whether it was ALREADY the
  /// selected one — the two facts `onTapUp` needs to decide whether this tap
  /// was a "tap the same point again to dismiss" (design 0076 §3.2 ruling B).
  int? _downIndex;
  bool _downWasSelected = false;

  /// Set once the pointer starts scrubbing, so the release does not then read
  /// as a dismissing tap.
  bool _didScrub = false;

  /// Select [i], never clear. 🔴 The toggle lives in [_onTapUp] alone.
  ///
  /// Clearing here is what made the two obvious implementations of a scrub
  /// wrong (design 0076 §3.2): a finger dragged 5 → 6 → 5 would close the
  /// panel on the way back, and a drag that STARTS on the selected point would
  /// blink it shut before the first move event set it again.
  void _select(int i, {bool haptic = false}) {
    if (_selected == i) return; // no rebuild, and no buzz, for the same point
    if (haptic) HapticFeedback.selectionClick();
    setState(() => _selected = i);
  }

  void _onTapDown(double dx, double width) {
    final i = _geometry(width).indexAt(dx);
    if (i == null) return;
    _downIndex = i;
    _downWasSelected = _selected == i;
    _didScrub = false;
    _select(i);
  }

  void _onTapUp() {
    // Tap-to-dismiss: only for a press that neither moved nor landed on a
    // fresh point. (A drag cancels the tap recognizer, so `_didScrub` is belt
    // and braces — it is the one that would bite silently if that ever
    // changed.)
    if (!_didScrub && _downWasSelected && _selected == _downIndex) {
      setState(() => _selected = null);
    }
    _downIndex = null;
    _downWasSelected = false;
  }

  void _scrubTo(double dx, double width) {
    final i = _geometry(width).indexAt(dx);
    if (i == null) return;
    _didScrub = true;
    // Haptic per crossing: while scrubbing the finger covers the plot, so the
    // fingertip is the only channel left that says "you are on a new point".
    _select(i, haptic: true);
  }

  /// Release keeps the selection — reading the numbers is why the finger
  /// stopped (design 0076 §3.6 / Q4).
  void _scrubEnd() {
    _downIndex = null;
    _downWasSelected = false;
    _didScrub = false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final buckets = widget.buckets;
    final hasTemp = _hasTemp;
    // 🔵 design 0085 S3. The gate is resolved BEFORE the series, and the
    // series is derived from both — never read straight out of `_series`. That
    // ordering is what makes "the toggle is disabled" and "the axis is showing
    // voltage" the same fact rather than two that have to be kept in step.
    final gate = historyChartCurrentGate(widget.deviceClass);
    final canSwitch = gate == HistoryChartCurrentGate.available;
    final series = canSwitch ? _series : HistoryChartSeries.voltage;
    final isCurrent = series == HistoryChartSeries.current;
    final gateNote = historyChartCurrentGateNote(l10n, gate);
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
              child: Text(
                l10n.historyChartInsufficientData,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: context.colors.muted),
              ),
            ),
          ),
          if (widget.stats.count > 0) ...[
            const SizedBox(height: 10),
            _StatsStrip(
              stats: widget.stats,
              tempUnit: widget.tempUnit,
              hasTemp: hasTemp,
            ),
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
            _LegendDot(
              color: context.accent.accent,
              // 🔴 The legend is where the switch becomes visible. Current
              // REPLACES voltage on the left axis and reuses its colour
              // (design 0085 案 B), so without this word the same amber line
              // would mean two different quantities with nothing on screen
              // saying which.
              label: isCurrent
                  ? l10n.historyLegendCurrent
                  : l10n.historyLegendVoltage,
            ),
            if (hasTemp) ...[
              const SizedBox(width: 16),
              _LegendDot(
                color: context.accent.accentSecondary,
                label: l10n.historyLegendTemperature,
              ),
            ],
            // FB-74. Unlabelled shading reads as a rendering flourish; this is
            // the one thing on the chart that says an instantaneous event is
            // visible at all, so it gets a legend entry rather than a footnote.
            const SizedBox(width: 16),
            _LegendBand(
              color: context.accent.accent,
              label: l10n.historyLegendRange,
            ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            // Tap AND horizontal drag on the same detector: the two
            // recognizers coexist, and a horizontal move past the touch slop
            // cancels the tap and hands over to the drag.
            //
            // ⚠️ A diagonal start is LOST TO THE SCROLLING host — whichever
            // axis crosses the slop first wins the arena, and both landing
            // sites are inside a vertical scroll view (design 0076 §2). That
            // is the deliberate price of not stealing vertical drags from a
            // 160 px band of the page; the copy must never promise that any
            // gesture scrubs.
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _onTapDown(d.localPosition.dx, w),
              onTapUp: (_) => _onTapUp(),
              onTapCancel: _scrubEnd,
              // `DragStartBehavior.down` so the first scrubbed point is the
              // one under the finger when it went down, not the one it had
              // already slid to by the time the drag was recognised.
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragStart: (d) => _scrubTo(d.localPosition.dx, w),
              onHorizontalDragUpdate: (d) => _scrubTo(d.localPosition.dx, w),
              onHorizontalDragEnd: (_) => _scrubEnd(),
              onHorizontalDragCancel: _scrubEnd,
              child: SizedBox(
                height: _chartH,
                child: CustomPaint(
                  size: Size(w, _chartH),
                  painter: HistoryTrendPainter(
                    buckets: buckets,
                    tempUnit: widget.tempUnit,
                    hasTemp: hasTemp,
                    multiDay: widget.multiDay,
                    bucketMs: widget.bucketMs,
                    selected: _selected,
                    series: series,
                    // Per family, and null for a unit with no family — see
                    // [historyChartCurrentDirectionLabel] for why the pack
                    // wording is not a fallback.
                    currentDirectionLabel: isCurrent
                        ? historyChartCurrentDirectionLabel(
                            l10n,
                            widget.deviceClass,
                          )
                        : null,
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
          _detail(context, l10n, buckets[_selected!], hasTemp,
              isCurrent: isCurrent),
        // design 0061 T10. `historyDetailSamples` says how MANY readings a
        // point folded; nothing said how much TIME it covered, and the width
        // moves between 1 minute and 24 hours with the range. At second
        // resolution the guess a reader would make is further out than ever.
        const SizedBox(height: 8),
        // 🔵 **Q1 = E2**: the footnote row is the "one more row under the chart"
        // the owner asked for — and it already existed, INSIDE the shared
        // widget. The two alternatives the owner also proposed were measured
        // and rejected in design 0081 §4.1: the range row (D) overflows the
        // detail page's segmented control by 20 px, silently clipping 「全部」;
        // a row outside the card (E) exists on one landing site and not the
        // other.
        //
        // The note stays centred on the CARD, not on the space left of the
        // button: two `Spacer`s, so adding or removing the button never moves
        // the sentence.
        // 🔵 **Its own line, above the note** (design 0083 §3.3.5). The row
        // below is a fixed three-column layout that has already overflowed once
        // when its middle `Text` could not wrap — see the comment inside it.
        // Appending the dates there would be re-running that.
        if (widget.sel != null) HistoryCustomRangeLine(sel: widget.sel!),
        Row(
          children: [
            // 🔴 A fixed 40 on the left, matching the button's box on the
            // right, so the note stays centred ON THE CARD whether or not the
            // button is there. The first attempt used `Spacer` + `Expanded`
            // and overflowed by 20 px the moment the English string ("Each
            // point on the chart averages 1 minute") could not wrap — a Row
            // does not give a `Text` the width to break in.
            //
            // 🔵 design 0085 S3 puts the voltage/current toggle INTO that
            // reserved box rather than adding a row for it. The card is 160 px
            // of chart inside a scroll view and the brief was explicitly "the
            // existing toolbar, no new chrome"; the box was already there,
            // already 40x40 (FB-70's floor), and already mirrored by the
            // expand button on the right, so the note stays centred either way.
            SizedBox(
              width: 40,
              child: IconButton(
                // ⛔ Disabled, NOT hidden — design 0085 §3.4. A control that
                // vanishes takes its explanation with it, and the ruling is
                // that the reason has to be on screen (the line below).
                onPressed: canSwitch
                    ? () => setState(() => _series = isCurrent
                        ? HistoryChartSeries.voltage
                        : HistoryChartSeries.current)
                    : null,
                icon: const Icon(Icons.swap_vert, size: 16),
                tooltip: l10n.historyChartSeriesToggle,
                constraints: const BoxConstraints(
                  minWidth: 40,
                  minHeight: 40,
                ),
                padding: EdgeInsets.zero,
                color: context.colors.muted,
              ),
            ),
            Expanded(
              child: Text(
                historyBucketWidthNote(l10n, widget.bucketMs),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: context.colors.muted),
              ),
            ),
            SizedBox(
              width: 40,
              child: widget.onExpand == null
                  ? null
                  : IconButton(
                      onPressed: widget.onExpand,
                      icon: const Icon(Icons.open_in_full, size: 16),
                      tooltip: l10n.historyChartExpand,
                      // 40x40 floor — FB-70 is the entry that cost this
                      // project a user who could not hit a 14x14 control.
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                      padding: EdgeInsets.zero,
                      color: context.colors.muted,
                    ),
            ),
          ],
        ),
        // 🔴 **Q4 ③ / §1.5 — the refusal says WHY, in words, always visible.**
        //
        // ⛔ Not a snackbar on tap and not a tooltip: a disabled button that
        // explains itself only when poked reads as broken, which is the failure
        // design 0074 Q3 already recorded once. It sits under the toggle it
        // belongs to.
        //
        // 🔑 Two different sentences, and the difference matters: the
        // capacitor's says the DEVICE reports a placeholder zero, the "all
        // devices" one says the SCOPE mixes two opposite sign conventions.
        // Neither may be softened into "no current data", which would claim
        // nothing was recorded. See [historyChartCurrentGateNote].
        if (gateNote != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              gateNote,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: context.colors.muted),
            ),
          ),
        const SizedBox(height: 10),
        _StatsStrip(
          stats: widget.stats,
          tempUnit: widget.tempUnit,
          hasTemp: hasTemp,
        ),
      ],
    );
  }

  Widget _detail(
    BuildContext context,
    AppLocalizations l10n,
    HistoryBucket b,
    bool hasTemp, {
    required bool isCurrent,
  }) {
    final fmt = DateFormat(widget.multiDay ? 'MM/dd HH:mm' : 'HH:mm');
    String v(double? x) => x == null ? '--' : x.toStringAsFixed(2);
    // 🔵 One decimal and an `A`, the same precision `historyCurrentBit` prints
    // in the list — design 0065 §6 R5 is that two surfaces must not put
    // different numbers on the same minute. ⛔ And the SIGN is kept: `0x2E` is
    // signed and the sign is the direction (design 0030 §3.2 Q5 rejected
    // `abs()`); the axis's direction key says which half is which.
    String a(double? x) => x == null ? '--' : x.toStringAsFixed(1);
    // FB-74: the temperature half of this line used to be the mean alone, while
    // the voltage half already carried its (min–max). A bucket whose hottest
    // second is the reason the user tapped it would answer with an average.
    String t(double c) =>
        historyDisplayTemp(c, widget.tempUnit).toStringAsFixed(0);
    final u = historyTempUnitLabel(widget.tempUnit);
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
                Text(
                  fmt.format(b.at),
                  style: AppTextStyles.mono(context).copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: context.colors.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  isCurrent
                      ? '${l10n.historyLegendCurrent} ${a(b.avgAmpere)}A '
                            '(${a(b.minAmpere)}–${a(b.maxAmpere)})'
                            '${tempStr != null ? '  ·  ${l10n.historyLegendTemperature} $tempStr' : ''}'
                      : '${l10n.historyLegendVoltage} ${v(b.avgPvlt)}V '
                            '(${v(b.minPvlt)}–${v(b.maxPvlt)})'
                            '${tempStr != null ? '  ·  ${l10n.historyLegendTemperature} $tempStr' : ''}',
                  style: TextStyle(fontSize: 11, color: context.colors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            l10n.historyDetailSamples(b.count),
            style: TextStyle(fontSize: 10, color: context.colors.muted),
          ),
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
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(fontSize: 10.5, color: context.colors.muted),
        ),
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
        Text(
          label,
          style: TextStyle(fontSize: 10.5, color: context.colors.muted),
        ),
      ],
    );
  }
}

class _StatsStrip extends StatelessWidget {
  const _StatsStrip({
    required this.stats,
    required this.tempUnit,
    required this.hasTemp,
  });
  final HistoryStats stats;
  final TempUnit tempUnit;
  final bool hasTemp;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String v(double? x) => x == null ? '--' : '${x.toStringAsFixed(2)}V';
    String t(double? x) => x == null
        ? '--'
        : '${historyDisplayTemp(x, tempUnit).toStringAsFixed(0)}${historyTempUnitLabel(tempUnit)}';
    return Column(
      children: [
        _statRow(
          context,
          context.accent.accent,
          l10n.historyLegendVoltage,
          min: v(stats.minPvlt),
          avg: v(stats.avgPvlt),
          max: v(stats.maxPvlt),
          l10n: l10n,
        ),
        if (hasTemp) ...[
          const SizedBox(height: 6),
          _statRow(
            context,
            context.accent.accentSecondary,
            l10n.historyLegendTemperature,
            min: t(stats.minTemp),
            avg: t(stats.avgTemp),
            max: t(stats.maxTemp),
            l10n: l10n,
          ),
        ],
      ],
    );
  }

  Widget _statRow(
    BuildContext context,
    Color accent,
    String title, {
    required String min,
    required String avg,
    required String max,
    required AppLocalizations l10n,
  }) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 7),
          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
        ),
        SizedBox(
          width: 56,
          child: Text(
            title,
            style: TextStyle(fontSize: 10.5, color: context.colors.muted),
            overflow: TextOverflow.ellipsis,
          ),
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
        Text(
          label,
          style: TextStyle(fontSize: 8.5, color: context.colors.muted),
        ),
        Text(
          value,
          style: AppTextStyles.mono(
            context,
          ).copyWith(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
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
  AppLocalizations l10n,
  ProductClass cls,
  double amps,
) {
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
  final flow = cls == ProductClass.powerBank
      ? powerFlowOf(shown)
      : packFlowOf(shown);
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
    shown.abs().toStringAsFixed(1),
    direction,
  );
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
              DateFormat(
                showSeconds ? 'HH:mm:ss' : 'HH:mm',
              ).format(sample.timestamp),
              style: AppTextStyles.mono(
                context,
              ).copyWith(fontSize: 10.5, color: context.colors.muted),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _primaryLine(),
                  style: AppTextStyles.mono(
                    context,
                  ).copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  _subLine(l10n),
                  style: TextStyle(fontSize: 10.5, color: context.colors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _StatusTag(status: status),
          if (tap != null)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Icon(
                Icons.chevron_right,
                size: 16,
                color: context.colors.muted,
              ),
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
      final unit = historyTempUnitLabel(tempUnit);
      final str = tempUnit == TempUnit.fahrenheit
          ? historyDisplayTemp(t.toDouble(), tempUnit).toStringAsFixed(0)
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
