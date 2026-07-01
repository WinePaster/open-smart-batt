/// OpenSmartBatt — History screen (mockup screen 4).
///
/// Trend chart (voltage + temperature, dual auto-scaled axes, drawn with
/// CustomPaint — no chart dependency) + min/max/avg stats + a record list with
/// CSV export. Time range (today / last 7 days / all) is chosen with a
/// segmented control and is decoupled from the standalone "warnings" toggle
/// (which filters only the list, not the chart). The chart + stats are computed
/// DB-side via [TelemetryController.historyBuckets] / [historyStats] so large
/// ranges never load every row into Dart. Each list row is classified
/// normal / warning / event (mode = reported status 0/2/4, PROTOCOL.md §6.2;
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
import '../util/export_share.dart';
import '../widgets/industrial.dart';

/// Selectable chart/list time range.
enum HistoryRange { today, week, all }

/// Row classification derived from a stored [TelemetrySample].
enum _RowStatus { normal, warning, event }

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const int _rowCap = 1000;
  static const int _targetBucketPoints = 180;

  HistoryRange _range = HistoryRange.today; // default
  bool _warningOnly = false;
  bool _exporting = false;

  late Future<_HistoryData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  TelemetryController get _tele => context.read<TelemetryController>();

  DateTime? _sinceFor(HistoryRange r) {
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

  Future<_HistoryData> _load() async {
    final tele = _tele;
    final since = _sinceFor(_range);
    final total = await tele.historyCount();
    final stats = await tele.historyStats(since: since);
    // Bucket width: aim for ~180 points across the visible span (>= 1 minute).
    final from = since ?? stats.firstAt;
    final spanMs = from == null
        ? 60000
        : DateTime.now().millisecondsSinceEpoch - from.millisecondsSinceEpoch;
    final bucketMs = (spanMs ~/ _targetBucketPoints).clamp(60000, 24 * 3600000);
    final buckets = await tele.historyBuckets(since: since, bucketMs: bucketMs);
    final rows = await tele.history(since: since, limit: _rowCap);
    return _HistoryData(rows: rows, buckets: buckets, stats: stats, total: total);
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

  Future<void> _exportCsv() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // iPad popover anchor (D.7): capture before any await invalidates context.
    final origin = sharePositionFromContext(context);
    try {
      final csv =
          await _tele.exportHistoryCsv(since: _sinceFor(_range), limit: _rowCap);
      if (csv.trim().isEmpty || !csv.contains('\n')) {
        messenger.showSnackBar(SnackBar(
          duration: const Duration(milliseconds: 1600),
          content: Text(l10n.commonNoRecordsToExport),
        ));
        return;
      }
      await shareTextAsFile(
        content: csv,
        filename: 'opensmartbatt-history-${exportStamp()}.csv',
        mimeType: 'text/csv',
        subject: l10n.historyExportSubject,
        sharePositionOrigin: origin,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          duration: const Duration(milliseconds: 1600),
          content: Text(l10n.commonExportFailed('$e'))));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tempUnit = context.watch<SettingsController>().tempUnit;
    final tele = context.watch<TelemetryController>();
    final ov = tele.warnOv, uv = tele.warnUv, ot = tele.warnOt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.amber,
            backgroundColor: context.colors.panel,
            onRefresh: () async => _reload(),
            child: FutureBuilder<_HistoryData>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return _scrollable(
                    const Padding(
                      padding: EdgeInsets.only(top: 80),
                      child: Center(
                        child:
                            CircularProgressIndicator(color: AppColors.amber),
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
                        rows: [], buckets: [], stats: HistoryStats.empty, total: 0);
                final listRows =
                    _applyWarning(data.rows, ov: ov, uv: uv, ot: ot);
                final chartEmpty = data.buckets.length < 2;
                if (data.rows.isEmpty && chartEmpty) {
                  return _scrollable(_message(_emptyText()));
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
                  children: [
                    IndustrialCard(
                      heading: _range == HistoryRange.today
                          ? l10n.historyChartTodayTitle
                          : l10n.historyChartTitle,
                      headingIcon: Icons.show_chart,
                      child: _TrendCard(
                        buckets: data.buckets,
                        stats: data.stats,
                        tempUnit: tempUnit,
                        multiDay: _range != HistoryRange.today,
                      ),
                    ),
                    if (listRows.isEmpty)
                      _message(_emptyText())
                    else
                      IndustrialCard(
                        padding: const EdgeInsets.all(11),
                        child: Column(
                          children: [
                            for (final s in listRows)
                              _HistoryRow(
                                sample: s,
                                tempUnit: tempUnit,
                                status: _classify(s, ov: ov, uv: uv, ot: ot),
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

  Widget _toolbar() {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 8, 15, 4),
      child: Row(
        children: [
          Expanded(
            child: SegmentedControl<HistoryRange>(
              selected: _range,
              onChanged: _setRange,
              options: [
                (value: HistoryRange.today, label: l10n.historyRangeToday),
                (value: HistoryRange.week, label: l10n.historyRangeWeek),
                (value: HistoryRange.all, label: l10n.historyRangeAll),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilterChip2(
            label: l10n.historyFilterWarning,
            icon: Icons.warning_amber_rounded,
            selected: _warningOnly,
            onTap: _toggleWarning,
          ),
          const SizedBox(width: 7),
          _exporting
              ? const SizedBox(
                  width: 28,
                  height: 28,
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.amber),
                    ),
                  ),
                )
              : FilterChip2(
                  label: l10n.historyExportCsv,
                  icon: Icons.file_download_outlined,
                  filled: true,
                  selected: true,
                  onTap: _exportCsv,
                ),
        ],
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
        children: [child],
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

  String _emptyText() {
    final l10n = AppLocalizations.of(context);
    if (_warningOnly) return l10n.historyEmptyWarning;
    return _range == HistoryRange.today
        ? l10n.historyEmptyToday
        : l10n.historyEmptyAll;
  }

  // ---- filtering / classification --------------------------------------

  List<TelemetrySample> _applyWarning(
    List<TelemetrySample> rows, {
    double? ov,
    double? uv,
    double? ot,
  }) {
    if (!_warningOnly) return rows;
    return rows
        .where((s) => _classify(s, ov: ov, uv: uv, ot: ot) != _RowStatus.normal)
        .toList(growable: false);
  }

  static _RowStatus _classify(
    TelemetrySample s, {
    double? ov,
    double? uv,
    double? ot,
  }) {
    final m = s.mode;
    if (m == ReportedStatus.antiTheftActive ||
        m == ReportedStatus.cutOffActive) {
      return _RowStatus.event;
    }
    final v = s.pvlt;
    if (v != null) {
      if (ov != null && v > ov) return _RowStatus.warning;
      if (uv != null && v < uv) return _RowStatus.warning;
    }
    final t = s.temperatureC;
    if (t != null && ot != null && t > ot) return _RowStatus.warning;
    return _RowStatus.normal;
  }
}

class _HistoryData {
  const _HistoryData({
    required this.rows,
    required this.buckets,
    required this.stats,
    required this.total,
  });
  final List<TelemetrySample> rows;
  final List<HistoryBucket> buckets;
  final HistoryStats stats;
  final int total;
}

// ====================== trend chart + stats =============================

double _toDisplayTemp(double c, TempUnit u) =>
    u == TempUnit.fahrenheit ? c * 9 / 5 + 32 : c;

String _tempUnitLabel(TempUnit u) => u == TempUnit.fahrenheit ? '°F' : '°C';

/// Legend + dual-axis chart (tap a point for that bucket's detail) + stats.
class _TrendCard extends StatefulWidget {
  const _TrendCard({
    required this.buckets,
    required this.stats,
    required this.tempUnit,
    required this.multiDay,
  });

  final List<HistoryBucket> buckets;
  final HistoryStats stats;
  final TempUnit tempUnit;
  final bool multiDay;

  @override
  State<_TrendCard> createState() => _TrendCardState();
}

class _TrendCardState extends State<_TrendCard> {
  static const double _chartH = 160;
  int? _selected;

  bool get _hasTemp =>
      widget.buckets.any((b) => b.avgTemp != null) ||
      widget.stats.avgTemp != null;

  @override
  void didUpdateWidget(_TrendCard old) {
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
      return SizedBox(
        height: 120,
        child: Center(
          child: Text(l10n.historyChartInsufficientData,
              style: TextStyle(fontSize: 12, color: context.colors.muted)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Legend.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _LegendDot(color: AppColors.amber, label: l10n.historyLegendVoltage),
            if (hasTemp) ...[
              const SizedBox(width: 16),
              _LegendDot(
                  color: AppColors.cyan, label: l10n.historyLegendTemperature),
            ],
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
                    selected: _selected,
                    vColor: AppColors.amber,
                    tColor: AppColors.cyan,
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
        const SizedBox(height: 10),
        _StatsStrip(stats: widget.stats, tempUnit: widget.tempUnit, hasTemp: hasTemp),
      ],
    );
  }

  Widget _detail(BuildContext context, AppLocalizations l10n, HistoryBucket b,
      bool hasTemp) {
    final fmt = DateFormat(widget.multiDay ? 'MM/dd HH:mm' : 'HH:mm');
    String v(double? x) => x == null ? '--' : x.toStringAsFixed(2);
    final tempStr = b.avgTemp == null
        ? null
        : '${_toDisplayTemp(b.avgTemp!, widget.tempUnit).toStringAsFixed(0)}${_tempUnitLabel(widget.tempUnit)}';
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: context.colors.panel2,
        borderRadius: BorderRadius.circular(8),
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
        _statRow(context, AppColors.amber, l10n.historyLegendVoltage,
            min: v(stats.minPvlt),
            avg: v(stats.avgPvlt),
            max: v(stats.maxPvlt),
            l10n: l10n),
        if (hasTemp) ...[
          const SizedBox(height: 6),
          _statRow(context, AppColors.cyan, l10n.historyLegendTemperature,
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

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.buckets,
    required this.tempUnit,
    required this.hasTemp,
    required this.multiDay,
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
  final int? selected;
  final Color vColor, tColor, grid, text;

  @override
  void paint(Canvas canvas, Size size) {
    final left = 40.0, right = hasTemp ? 40.0 : 8.0, top = 8.0, bottom = 18.0;
    final plotW = size.width - left - right;
    final plotH = size.height - top - bottom;
    final n = buckets.length;

    // Voltage range (left axis).
    double? vmin, vmax;
    for (final b in buckets) {
      final a = b.avgPvlt;
      if (a == null) continue;
      vmin = vmin == null ? a : (a < vmin ? a : vmin);
      vmax = vmax == null ? a : (a > vmax ? a : vmax);
    }
    vmin ??= 0;
    vmax ??= 1;
    var vlo = vmin - 0.2, vhi = vmax + 0.2;
    if (vhi - vlo < 0.5) {
      final m = (vlo + vhi) / 2;
      vlo = m - 0.25;
      vhi = m + 0.25;
    }

    // Temperature range (right axis, display units).
    double? tmin, tmax;
    if (hasTemp) {
      for (final b in buckets) {
        final a = b.avgTemp;
        if (a == null) continue;
        final d = _toDisplayTemp(a, tempUnit);
        tmin = tmin == null ? d : (d < tmin ? d : tmin);
        tmax = tmax == null ? d : (d > tmax ? d : tmax);
      }
    }
    if (tmin == null || tmax == null) {
      tmin = 0;
      tmax = 1;
    }
    var tlo = tmin - 1, thi = tmax + 1;
    if (thi - tlo < 2) {
      final m = (tlo + thi) / 2;
      tlo = m - 1;
      thi = m + 1;
    }

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
    final fmt = DateFormat(multiDay ? 'MM/dd' : 'HH:mm');
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

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.sample,
    required this.tempUnit,
    required this.status,
  });

  final TelemetrySample sample;
  final TempUnit tempUnit;
  final _RowStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colors.panel2,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: context.colors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              DateFormat('HH:mm:ss').format(sample.timestamp),
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
        ],
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
      case _RowStatus.event:
        return sample.mode == ReportedStatus.cutOffActive
            ? l10n.historyRowEventCutOff
            : l10n.historyRowEventAntiTheft;
      case _RowStatus.warning:
        return _warningText(l10n);
      case _RowStatus.normal:
        final bits = <String>[];
        if (sample.sohBucket != null) {
          bits.add(l10n.historyRowSoh(sample.sohBucket!));
        }
        if (sample.current != null) {
          bits.add(l10n.historyRowCurrent(sample.current!.toStringAsFixed(1)));
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

  final _RowStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    late final Color fg;
    late final String label;
    switch (status) {
      case _RowStatus.normal:
        fg = AppColors.good;
        label = l10n.commonNormal;
      case _RowStatus.warning:
        fg = AppColors.amber;
        label = l10n.commonWarning;
      case _RowStatus.event:
        fg = AppColors.cyan;
        label = l10n.historyStatusEvent;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: fg.withValues(alpha: 0.32)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 9, letterSpacing: 1, color: fg),
      ),
    );
  }
}
