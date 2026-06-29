/// Open-RCE-Batt — History screen (mockup screen 4).
///
/// Lists persisted telemetry records (newest-first) with filter chips
/// (全部 / 今天 / 警告) and a CSV export → share action. Records come from our
/// own SQLite via [TelemetryController.history]; export via
/// [TelemetryController.exportHistoryCsv]. Each row is classified normal /
/// warning / event from the stored sample (mode = reported status 0/2/4,
/// PROTOCOL.md §6.2; warning compared against the device's live OV/UV/OT
/// thresholds when known).
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../protocol/protocol.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../util/export_share.dart';
import '../widgets/industrial.dart';

/// Filter applied to the history list (mockup chips).
enum HistoryFilter { all, today, warning }

/// Row classification derived from a stored [TelemetrySample].
enum _RowStatus { normal, warning, event }

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const int _rowCap = 1000;

  HistoryFilter _filter = HistoryFilter.today; // default to today
  bool _exporting = false;

  late Future<_HistoryData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  TelemetryController get _tele => context.read<TelemetryController>();

  Future<_HistoryData> _load() async {
    final tele = _tele;
    final DateTime? since =
        _filter == HistoryFilter.today ? _startOfToday() : null;
    final rows = await tele.history(since: since, limit: _rowCap);
    final total = await tele.historyCount();
    return _HistoryData(rows: rows, total: total);
  }

  static DateTime _startOfToday() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  void _reload() => setState(() => _future = _load());

  void _setFilter(HistoryFilter f) {
    if (f == _filter) return;
    setState(() {
      _filter = f;
      _future = _load();
    });
  }

  Future<void> _exportCsv() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final since = _filter == HistoryFilter.today ? _startOfToday() : null;
      final csv = await _tele.exportHistoryCsv(since: since, limit: _rowCap);
      if (csv.trim().isEmpty || !csv.contains('\n')) {
        messenger.showSnackBar(
          const SnackBar(duration: Duration(milliseconds: 1600), content: Text('沒有可匯出的紀錄')),
        );
        return;
      }
      await shareTextAsFile(
        content: csv,
        filename: 'open-rce-batt-history-${exportStamp()}.csv',
        mimeType: 'text/csv',
        subject: 'Open-RCE-Batt 歷史紀錄',
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text('匯出失敗：$e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tempUnit = context.watch<SettingsController>().tempUnit;
    // Warning thresholds from the live device (null when disconnected/unknown).
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
                        child: CircularProgressIndicator(color: AppColors.amber),
                      ),
                    ),
                  );
                }
                if (snap.hasError) {
                  return _scrollable(_message('讀取歷史失敗：${snap.error}'));
                }
                final data = snap.data ?? const _HistoryData(rows: [], total: 0);
                final rows = _applyFilter(data.rows, ov: ov, uv: uv, ot: ot);
                if (rows.isEmpty) {
                  return _scrollable(_message(_emptyText()));
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
                  children: [
                    IndustrialCard(
                      heading: _filter == HistoryFilter.today
                          ? '今日電壓趨勢'
                          : '電壓趨勢',
                      headingIcon: Icons.show_chart,
                      child: _VoltageChart(samples: rows),
                    ),
                    IndustrialCard(
                      padding: const EdgeInsets.all(11),
                      child: Column(
                        children: [
                          for (final s in rows)
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 8, 15, 4),
      child: Row(
        children: [
          FilterChip2(
            label: '全部',
            selected: _filter == HistoryFilter.all,
            onTap: () => _setFilter(HistoryFilter.all),
          ),
          const SizedBox(width: 7),
          FilterChip2(
            label: '今天',
            selected: _filter == HistoryFilter.today,
            onTap: () => _setFilter(HistoryFilter.today),
          ),
          const SizedBox(width: 7),
          FilterChip2(
            label: '警告',
            selected: _filter == HistoryFilter.warning,
            onTap: () => _setFilter(HistoryFilter.warning),
          ),
          const Spacer(),
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
                  label: '匯出 CSV',
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
    final n = NumberFormat.decimalPattern().format(total);
    return IndustrialCard(
      child: Text(
        '共 $n 筆 · 本機 SQLite · 可匯出 CSV / 分享',
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
    switch (_filter) {
      case HistoryFilter.today:
        return '今天還沒有紀錄。\n連線裝置後會自動寫入歷史。';
      case HistoryFilter.warning:
        return '沒有警告或事件紀錄。';
      case HistoryFilter.all:
        return '尚無歷史紀錄。\n連線裝置並開啟「自動紀錄」即可開始累積。';
    }
  }

  // ---- filtering / classification --------------------------------------

  List<TelemetrySample> _applyFilter(
    List<TelemetrySample> rows, {
    double? ov,
    double? uv,
    double? ot,
  }) {
    if (_filter != HistoryFilter.warning) return rows;
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
    // Reported status code space (PROTOCOL.md §6.2): 2 = anti-theft active,
    // 4 = cut-off active. Both surface as user-visible "events".
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
  const _HistoryData({required this.rows, required this.total});
  final List<TelemetrySample> rows;
  final int total;
}

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
                Text(_primaryLine(), style: AppTextStyles.mono(context).copyWith(
                  fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(
                  _subLine(),
                  style: TextStyle(
                      fontSize: 10.5, color: context.colors.muted),
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
      final shown = tempUnit == TempUnit.fahrenheit ? (t * 9 / 5 + 32) : t;
      final unit = tempUnit == TempUnit.fahrenheit ? '°F' : '°C';
      final str = tempUnit == TempUnit.fahrenheit
          ? shown.toStringAsFixed(0)
          : t.toString();
      parts.add('$str$unit');
    }
    return parts.join(' · ');
  }

  String _subLine() {
    switch (status) {
      case _RowStatus.event:
        return sample.mode == ReportedStatus.cutOffActive
            ? '斷電模式已啟動'
            : '防盜模式已啟動';
      case _RowStatus.warning:
        return _warningText();
      case _RowStatus.normal:
        final bits = <String>[];
        if (sample.sohBucket != null) bits.add('SOH ${sample.sohBucket}%');
        if (sample.current != null) {
          bits.add('電流 ${sample.current!.toStringAsFixed(1)}A');
        }
        return bits.isEmpty ? '正常' : bits.join(' · ');
    }
  }

  String _warningText() {
    final bits = <String>[];
    if (sample.sohBucket != null) bits.add('SOH ${sample.sohBucket}%');
    bits.add('保護門檻警告');
    return bits.join(' · ');
  }
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.status});

  final _RowStatus status;

  @override
  Widget build(BuildContext context) {
    late final Color fg;
    late final String label;
    switch (status) {
      case _RowStatus.normal:
        fg = AppColors.good;
        label = '正常';
      case _RowStatus.warning:
        fg = AppColors.amber;
        label = '警告';
      case _RowStatus.event:
        fg = AppColors.cyan;
        label = '事件';
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

/// Lightweight PVLT line chart (CustomPaint — no chart dependency).
class _VoltageChart extends StatelessWidget {
  const _VoltageChart({required this.samples});

  final List<TelemetrySample> samples;

  @override
  Widget build(BuildContext context) {
    final pts = samples.where((s) => s.pvlt != null).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (pts.length < 2) {
      return SizedBox(
        height: 130,
        child: Center(
          child: Text('資料不足以繪圖（需至少 2 筆）',
              style: TextStyle(fontSize: 12, color: context.colors.muted)),
        ),
      );
    }
    return SizedBox(
      height: 160,
      child: CustomPaint(
        size: Size.infinite,
        painter: _ChartPainter(
          pts,
          line: AppColors.amber,
          grid: context.colors.line,
          text: context.colors.muted,
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.pts,
      {required this.line, required this.grid, required this.text});

  final List<TelemetrySample> pts; // sorted ascending, pvlt non-null
  final Color line;
  final Color grid;
  final Color text;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 38.0, bottom = 18.0, top = 8.0, right = 6.0;
    final plotW = size.width - left - right;
    final plotH = size.height - top - bottom;

    var minV = pts.first.pvlt!, maxV = minV;
    for (final p in pts) {
      final v = p.pvlt!;
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    // Pad the range; avoid a zero span.
    var lo = minV - 0.2, hi = maxV + 0.2;
    if (hi - lo < 0.5) {
      final mid = (lo + hi) / 2;
      lo = mid - 0.25;
      hi = mid + 0.25;
    }

    double xAt(int i) => left + plotW * (i / (pts.length - 1));
    double yAt(double v) => top + plotH * (1 - (v - lo) / (hi - lo));

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    void tp(String s, double x, double y, {bool rightAlign = false}) {
      final painter = TextPainter(
        text: TextSpan(
            text: s, style: TextStyle(color: text, fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, Offset(rightAlign ? x - painter.width : x, y));
    }

    // Y grid: lo / mid / hi.
    for (final v in [lo, (lo + hi) / 2, hi]) {
      final y = yAt(v);
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y),
          gridPaint..color = grid.withValues(alpha: 0.5));
      tp(v.toStringAsFixed(1), left - 4, y - 6, rightAlign: true);
    }

    // Time labels (start / end).
    final fmt = DateFormat('HH:mm');
    tp(fmt.format(pts.first.timestamp), left, size.height - 12);
    tp(fmt.format(pts.last.timestamp), size.width - right, size.height - 12,
        rightAlign: true);

    // The voltage polyline.
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final x = xAt(i), y = yAt(pts[i].pvlt!);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // Latest point marker.
    final lx = xAt(pts.length - 1), ly = yAt(pts.last.pvlt!);
    canvas.drawCircle(Offset(lx, ly), 3, Paint()..color = line);
    tp('${pts.last.pvlt!.toStringAsFixed(2)}V', lx - 2, ly - 16,
        rightAlign: true);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.pts.length != pts.length ||
      (pts.isNotEmpty &&
          old.pts.isNotEmpty &&
          old.pts.last.timestamp != pts.last.timestamp);
}
