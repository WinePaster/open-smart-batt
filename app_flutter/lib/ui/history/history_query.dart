/// OpenSmartBatt — the history KERNEL: the vocabulary and the three queries
/// that both history surfaces share (design 0079 S4 / Q5).
///
/// ## Why this file exists
///
/// There are two surfaces onto the same table — the History tab in the bottom
/// navigation bar (every unit, a device picker, a whole-database footer) and
/// the history tab on a device's detail page (one unit, fixed scope). Design
/// 0065 §6 R5 named the risk they create: **two surfaces that load the same
/// unit's history differently show one unit two different pictures, and nobody
/// can tell which is right.**
///
/// Until 2026-08-21 that risk was held off by discipline — a comment in each
/// `_load` saying "the same three, in the same order, with the same arguments
/// as the other one". Discipline is what design 0065 §3.2.1 could offer; it is
/// not what it wanted. The owner ruled on Q5 to consolidate, knowing it steps
/// on design 0065 §1.5's non-goal ("do not change `HistoryScreen`'s query
/// semantics").
///
/// 🔴 **The ruling permits changing the STRUCTURE, not the semantics.** Every
/// query below is byte-for-byte what the two `_load` methods issued on
/// 2026-08-21: same three calls, same order, same arguments, same
/// [kHistoryRowCap], same bucket-width derivation. If a future change wants to
/// alter any of that, it is a new decision and needs its own ruling — the point
/// of this file is that such a change can no longer happen to ONE surface.
///
/// ## What is deliberately NOT here
///
/// The two surfaces still differ, and those differences are theirs:
///
///  * the History tab resolves a device SCOPE (`historyDeviceGroups`, the
///    picker, the seed) and counts the whole database for its footer;
///  * the detail page's tab is pinned to its page's unit and has neither.
///
/// Pulling those in would not remove a duplication — there is none — it would
/// only make one surface carry the other's furniture.
library;

import 'package:open_smart_batt/l10n/app_localizations.dart';

import '../../data/history_repo.dart';
import '../../protocol/protocol.dart';
import '../../state/state.dart';

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

/// How many points the EMBEDDED chart aims for across the visible span.
const int kHistoryTargetBucketPoints = 180;

/// How many the FULL-SCREEN landscape chart aims for — design 0081 §3.4.2.
///
/// 🔴 A second CONSTANT, deliberately, but **not** a second derivation: it is
/// passed to [historyChartBucketMs] like the other one. Two surfaces computing
/// the width their own way is design 0065 §6 R5; two surfaces asking the one
/// derivation for a different point count is just a wider screen.
const int kHistoryLandscapeTargetPoints = 360;

/// 🔵 **Q5a: the narrowest window the landscape chart will zoom to.**
///
/// The bucket floor is one minute (Q5 ruled 分鐘), so past this point zooming
/// stops adding detail and only spreads the same points further apart — an
/// 8-minute window is eight dots on a 780 px screen, which is LESS legible
/// than the 30-minute one it came from, not more.
const int kHistoryMinVisibleSpanMs = 30 * 60000;

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

/// The chart's bucket width for the span [from] → [to]: aim for
/// [kHistoryTargetBucketPoints] points, never narrower than a minute nor wider
/// than a day.
///
/// 🔵 **Both ends are the DATA's, not the range's — design 0081 S1.** Until
/// 2026-08-23 this took one end and measured to `DateTime.now()`, so the
/// divisor was "how long the selected range is" rather than "how long this
/// unit actually recorded for". The two are wildly different things:
///
///  * a unit that rode 07:12–08:05 and again 13:40–14:26 has ~1 h 39 m of
///    data, but "today" opened at 15:00 spans 15 hours ⇒ the width came out at
///    5 minutes and the whole day drew as **21 points**, out of ~5,900 stored
///    seconds (design 0081 §1.1);
///  * worse, the SAME data drew differently depending on **what time of day
///    the screen was opened** — 1 minute before 03:00, 8 minutes at midnight.
///
/// Passing the data's own extremes ([HistoryStats.firstAt] / [lastAt]) makes
/// the width a property of the recording, which is what a reader assumes it
/// already was.
///
/// Either end null means there is nothing to span (an empty range) and the
/// minimum applies — the same fallback as before, reached the same way.
///
/// 🔴 Top-level for [historySinceFor]'s reason, and this one is the sharper
/// half of it: the width decides how much each plotted point averages, so two
/// surfaces computing it "about the same way" would draw two different-looking
/// charts from identical data (design 0065 §6 R5, pinned by `T65-12`).
int historyChartBucketMs(DateTime? from, DateTime? to,
    {int targetPoints = kHistoryTargetBucketPoints}) {
  final spanMs = (from == null || to == null)
      ? kHistoryListBucketMs
      : to.millisecondsSinceEpoch - from.millisecondsSinceEpoch;
  return (spanMs ~/ targetPoints).clamp(kHistoryListBucketMs, 24 * 3600000);
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

/// The result of one [loadHistorySlice] — chart, stats and list for one scope
/// over one range.
///
/// 🔑 The bucket width is CARRIED rather than recomputed at render time, so the
/// note under the chart cannot describe a different width from the one the data
/// was fetched at.
class HistorySlice {
  const HistorySlice({
    required this.rows,
    required this.buckets,
    required this.stats,
    required this.bucketMs,
  });

  static const HistorySlice empty = HistorySlice(
    rows: [],
    buckets: [],
    stats: HistoryStats.empty,
    bucketMs: kHistoryListBucketMs,
  );

  /// One entry per display WINDOW (a minute) — design 0061 T3a.
  final List<HistoryListRow> rows;
  final List<HistoryBucket> buckets;
  final HistoryStats stats;
  final int bucketMs;
}

/// The three queries, in the one order, with the one set of arguments.
///
/// 🔴 **The order is load-bearing and is not alphabetical taste.** `stats` runs
/// first because the chart's bucket width is derived from it — 🔵 since design
/// 0081 S1 that is true on **every** range, not just "all": both ends of the
/// span now come from `stats.firstAt` / `stats.lastAt`. Reordering silently
/// changes the width of every plotted point — a difference that looks like a
/// prettier chart, not like a bug.
///
/// ⚠️ **`deviceId` null means EVERY unit.** Only the History tab may pass null,
/// and only while resolving its scope; design 0043 §3.5 removed "all devices"
/// as a user-selectable option because the three product classes do not share a
/// voltage range and an unscoped chart averages them into a line matching no
/// physical unit.
/// 🔵 **[until] added by design 0083 S1, and it goes to ALL THREE.** The three
/// existing presets are all "from some moment until now", so this whole path
/// only ever needed a lower bound; a custom range has a far end. Passing it to
/// two of the three would produce a chart, a stats strip and a list that cover
/// different spans of one unit — design 0065 §6 R5 in its purest form, and
/// invisible: every number would look plausible.
///
/// 🔴 **Half-open** (`timestamp < until`, design 0074 T1). The caller converts
/// "up to and including the 15th" into midnight on the 16th, never
/// `23:59:59` — see `historyBoundsFor` when S2 lands.
///
/// ⛔ **The three presets pass `until: null` and are bit-for-bit unchanged.**
/// S1 adds no behaviour; it only gives S2 somewhere to attach.
Future<HistorySlice> loadHistorySlice(
  TelemetryController tele, {
  required DateTime? since,
  required DateTime? until,
  required String? deviceId,
}) async {
  final stats =
      await tele.historyStats(since: since, until: until, deviceId: deviceId);
  // 🔴 `historyChartBucketMs`, never an inline "about the same" calculation.
  // The width decides how much each plotted point averages; two surfaces
  // computing it separately is how one unit ends up with two charts.
  //
  // 🔵 **design 0081 S1**: the DATA's own span, not the range's. `stats` is
  // already scoped by `since`, so `firstAt` cannot be earlier than the range's
  // cut-off — no `max()` is needed here, and adding one would imply a case the
  // query makes impossible. Empty range ⇒ both null ⇒ the minute floor, which
  // is exactly what `since ?? firstAt` produced before for an empty "all".
  //
  // 🔵 **design 0083 S1 makes the same argument hold at the OTHER end**: with
  // `until` in the aggregate, `lastAt` cannot be later than the cut-off either,
  // so this line needs no `min()` for the same reason it needs no `max()`. That
  // is the whole point of bounding the aggregate rather than clamping here —
  // a clamp would be a second place where the span is decided.
  final bucketMs = historyChartBucketMs(stats.firstAt, stats.lastAt);
  final buckets = await tele.historyBuckets(
      since: since, until: until, bucketMs: bucketMs, deviceId: deviceId);
  // One entry per MINUTE, not one per stored row (design 0061 T3a). See
  // [kHistoryRowCap] for what the cap counts, and [HistoryListRow] for why the
  // window carries its own min/max.
  final rows = await tele.historyListBuckets(
      since: since,
      until: until,
      bucketMs: kHistoryListBucketMs,
      limit: kHistoryRowCap,
      deviceId: deviceId);
  return HistorySlice(
      rows: rows, buckets: buckets, stats: stats, bucketMs: bucketMs);
}

/// One window of buckets for the landscape chart — design 0081 S3.
///
/// 🔑 **Deliberately NOT a fourth query in [loadHistorySlice].** The landscape
/// page has no list and no stats strip; asking for them would make every pan
/// pay for two aggregates nothing on screen reads. What it DOES share is the
/// width derivation, which is the half that must not drift (design 0065 §6 R5).
Future<({List<HistoryBucket> buckets, int bucketMs})> loadHistoryWindow(
  TelemetryController tele, {
  required DateTime from,
  required DateTime to,
  required String? deviceId,
}) async {
  final bucketMs = historyChartBucketMs(from, to,
      targetPoints: kHistoryLandscapeTargetPoints);
  final buckets = await tele.historyBuckets(
      since: from, until: to, bucketMs: bucketMs, deviceId: deviceId);
  return (buckets: buckets, bucketMs: bucketMs);
}

/// How the trend chart introduces itself for [range].
///
/// 🔑 Both surfaces used to derive these two values from their own `_range`,
/// four lines apart in two files. They are one decision — "is this chart about
/// today or about a span of days" — and it now has one home. A surface that
/// titled a multi-day chart "Today's" while plotting it as multi-day would be
/// wrong in a way no test was watching for.
({String heading, bool multiDay}) historyChartFraming(
  AppLocalizations l10n,
  HistoryRange range,
) =>
    range == HistoryRange.today
        ? (heading: l10n.historyChartTodayTitle, multiDay: false)
        : (heading: l10n.historyChartTitle, multiDay: true);
