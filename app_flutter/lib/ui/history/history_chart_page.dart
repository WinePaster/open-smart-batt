/// OpenSmartBatt — the full-screen LANDSCAPE trend chart (design 0081 S3).
///
/// ## Why this is a second surface rather than a mode on the first
///
/// The embedded card is 160 px tall inside a vertical scroll view, at two
/// landing sites (design 0081 §1.3). Putting a pinch recogniser there would
/// take the page's own scrolling away from a 160 px band, and a "zoom mode"
/// toggle would add a remembered state to two surfaces at once — the shape the
/// corpus has recorded as 「狀態散到兩處」. So the owner ruled two shells with an
/// expand button between them (design 0081, first round).
///
/// 🔑 **The shells share one painter, one geometry and one width derivation**
/// (`history_chart_core.dart`). A second drawing is FB-74 / design 0065 §6 R5:
/// one unit, two pictures, no way to tell which is right.
///
/// ## What was ruled here, in one place
///
///  * **Q2 = B** — the readout FOLLOWS THE FINGER (§_Readout). It overrides
///    this file's own recommendation; the reason to watch it on a device is in
///    design 0081 §9.
///  * **Q3 = A** — the overview strip is operable, not decorative.
///  * **Q4 = C** — double tap is bound to nothing, on purpose.
///  * **Q5 = 分鐘 / Q5a = 30 分鐘** — the bucket floor is a minute and the
///    window will not go below half an hour ([kHistoryMinVisibleSpanMs]).
///  * **Q7 = A / Q7a = A1** — the page LOCKS landscape and is left by the back
///    button alone. It never reads the orientation sensor: once locked, the UI
///    no longer follows the device, so "they turned it back" would need a
///    separate sensor feed that also fires for anyone lying down.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../data/history_repo.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'history_chart_core.dart';
import 'history_query.dart';

/// Open the landscape chart for [deviceId] over [dataFrom] … [dataTo].
///
/// A function rather than a `MaterialPageRoute` at each call site: both landing
/// sites push the SAME page, and a second `push` spelled slightly differently
/// is how two surfaces start differing again.
Future<void> showHistoryChartPage(
  BuildContext context, {
  required String? deviceId,
  required String title,
  required TempUnit tempUnit,
  required DateTime dataFrom,
  required DateTime dataTo,
}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => HistoryChartPage(
        deviceId: deviceId,
        title: title,
        tempUnit: tempUnit,
        dataFrom: dataFrom,
        dataTo: dataTo,
      ),
    ));

class HistoryChartPage extends StatefulWidget {
  const HistoryChartPage({
    super.key,
    required this.deviceId,
    required this.title,
    required this.tempUnit,
    required this.dataFrom,
    required this.dataTo,
  });

  final String? deviceId;
  final String title;
  final TempUnit tempUnit;

  /// The whole recording the user may pan across — the overview strip's extent
  /// and the pan clamp. Supplied by the caller because it already asked
  /// (`stats.firstAt` / `lastAt`), and asking twice would let the two disagree.
  final DateTime dataFrom;
  final DateTime dataTo;

  @override
  State<HistoryChartPage> createState() => _HistoryChartPageState();
}

class _HistoryChartPageState extends State<HistoryChartPage> {
  static const double _topBarH = 44;
  static const double _stripH = 46;

  /// How long after the fingers leave before the window is re-queried.
  ///
  /// Nothing is queried DURING a gesture: the painter maps time to x, so a pan
  /// is a geometric stretch of the points already in hand — free, and exactly
  /// in step with the finger. The query is what makes it sharp again.
  static const Duration _settle = Duration(milliseconds: 120);

  late HistoryChartWindow _win =
      HistoryChartWindow(widget.dataFrom, widget.dataTo);

  List<HistoryBucket> _buckets = const [];
  int _bucketMs = kHistoryListBucketMs;

  /// The whole range at a coarse width, for the strip. Queried once.
  List<HistoryBucket> _overview = const [];

  bool _busy = false;
  Timer? _debounce;

  /// Gesture anchors — see [HistoryChartWindow.apply].
  HistoryChartWindow? _gestureStart;
  double _startFocalFrac = 0.5;

  int? _selected;

  @override
  void initState() {
    super.initState();
    // 🔵 Q7 = A. Restoring happens in [dispose] and NOT in the close button's
    // callback: the system back gesture never reaches that callback, and an
    // app left locked to landscape is the worst outcome this file can produce.
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reload();
      _loadOverview();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    super.dispose();
  }

  TelemetryController get _tele => context.read<TelemetryController>();

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() => _busy = true);
    final win = _win;
    final r = await loadHistoryWindow(_tele,
        from: win.from, to: win.to, deviceId: widget.deviceId);
    // A gesture that landed while the query was in flight wins: its own reload
    // is already scheduled, and painting this answer would show the window the
    // user just left.
    if (!mounted || win != _win) return;
    setState(() {
      _buckets = r.buckets;
      _bucketMs = r.bucketMs;
      _busy = false;
      if (_selected != null && _selected! >= _buckets.length) _selected = null;
    });
  }

  Future<void> _loadOverview() async {
    final r = await loadHistoryWindow(_tele,
        from: widget.dataFrom, to: widget.dataTo, deviceId: widget.deviceId);
    if (mounted) setState(() => _overview = r.buckets);
  }

  void _settleThenReload() {
    _debounce?.cancel();
    _debounce = Timer(_settle, _reload);
  }

  // ---- gestures ----------------------------------------------------------

  HistoryChartGeometry _geometry(double width) => HistoryChartGeometry(
        width: width,
        hasTemp: _hasTemp,
        buckets: _buckets,
        bucketMs: _bucketMs,
        from: _win.from,
        to: _win.to,
      );

  bool get _hasTemp => _buckets.any((b) => b.avgTemp != null);

  double _frac(double dx, double width) {
    final g = _geometry(width);
    if (g.plotW <= 0) return 0.5;
    return ((dx - HistoryChartGeometry.left) / g.plotW).clamp(0.0, 1.0);
  }

  void _onScaleStart(ScaleStartDetails d, double width) {
    _gestureStart = _win;
    _startFocalFrac = _frac(d.localFocalPoint.dx, width);
  }

  void _onScaleUpdate(ScaleUpdateDetails d, double width) {
    final start = _gestureStart;
    if (start == null) return;
    final next = HistoryChartWindow.apply(
      start: start,
      scale: d.horizontalScale == 0 ? d.scale : d.horizontalScale,
      startFocalFrac: _startFocalFrac,
      focalFrac: _frac(d.localFocalPoint.dx, width),
      dataFrom: widget.dataFrom,
      dataTo: widget.dataTo,
    );
    if (next != _win) setState(() => _win = next);
  }

  void _onScaleEnd() {
    _gestureStart = null;
    _settleThenReload();
  }

  void _crosshairTo(double dx, double width) {
    final i = _geometry(width).indexAt(dx);
    if (i == null || i == _selected) return;
    HapticFeedback.selectionClick();
    setState(() => _selected = i);
  }

  // ---- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(l10n),
            Expanded(child: _plot(l10n)),
            SizedBox(height: _stripH, child: _strip()),
          ],
        ),
      ),
    );
  }

  Widget _topBar(AppLocalizations l10n) {
    final multiDay = _win.spanMs > 24 * 3600000;
    final fmt = DateFormat(multiDay ? 'MM/dd HH:mm' : 'HH:mm');
    return SizedBox(
      height: _topBarH,
      child: Row(
        children: [
          IconButton(
            // 🔵 Q7a = A1: this and the system back are the only ways out.
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back, size: 20),
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            padding: EdgeInsets.zero,
          ),
          Expanded(
            child: Text(widget.title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          ),
          // design 0061 T10, landscape edition. 🔴 A bigger screen is not a
          // reason to drop the one line that says how much time a point is.
          Flexible(
            flex: 2,
            child: Text(
              '${fmt.format(_win.from)} – ${fmt.format(_win.to)}'
              '  ·  ${historyBucketWidthNote(l10n, _bucketMs)}',
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.mono(context)
                  .copyWith(fontSize: 11, color: context.colors.muted),
            ),
          ),
          SizedBox(
            width: 66,
            child: _busy
                ? const Center(
                    child: SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _plot(AppLocalizations l10n) => LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final g = _geometry(w);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Pan AND pinch through the one scale recogniser: a one-finger drag
            // arrives with `scale == 1`, which [HistoryChartWindow.apply]
            // already handles as a pure translation.
            onScaleStart: (d) => _onScaleStart(d, w),
            onScaleUpdate: (d) => _onScaleUpdate(d, w),
            onScaleEnd: (_) => _onScaleEnd(),
            // 🔵 Long press, not a bare drag: the drag is the pan now. This is
            // design 0076's scrub with a different door.
            onLongPressStart: (d) => _crosshairTo(d.localPosition.dx, w),
            onLongPressMoveUpdate: (d) => _crosshairTo(d.localPosition.dx, w),
            // ⛔ Q4 = C: no `onDoubleTap`. Deliberately unbound.
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedOpacity(
                    // "Blurs, then sharpens" — never a blank frame. The old
                    // points are still true, only coarser than what is coming.
                    opacity: _busy ? 0.55 : 1,
                    duration: const Duration(milliseconds: 120),
                    child: CustomPaint(
                      painter: _buckets.length < 2
                          ? null
                          : HistoryTrendPainter(
                              buckets: _buckets,
                              from: _win.from,
                              to: _win.to,
                              gapLabel: (d) => _gapLabel(l10n, d),
                              tempUnit: widget.tempUnit,
                              hasTemp: _hasTemp,
                              multiDay: _win.spanMs > 24 * 3600000,
                              bucketMs: _bucketMs,
                              selected: _selected,
                              vColor: context.accent.accent,
                              tColor: context.accent.accentSecondary,
                              grid: context.colors.line,
                              text: context.colors.muted,
                            ),
                      size: Size.infinite,
                    ),
                  ),
                ),
                if (_buckets.length < 2 && !_busy)
                  Center(
                    child: Text(l10n.historyChartInsufficientData,
                        style: TextStyle(
                            fontSize: 12, color: context.colors.muted)),
                  ),
                if (_selected != null && _selected! < _buckets.length)
                  _readout(l10n, g, c.maxHeight),
              ],
            ),
          );
        },
      );

  /// 🔵 **Q2 = B — the readout follows the finger.**
  ///
  /// Three things the ruling makes mandatory, all of them here:
  ///
  ///  1. it sits ABOVE the touch point, or the fingertip covers it;
  ///  2. it flips to stay inside the plot near either edge, rather than being
  ///     clipped;
  ///  3. it has a FIXED width and monospaced figures, so the numbers do not
  ///     jitter as they change while the finger moves.
  Widget _readout(AppLocalizations l10n, HistoryChartGeometry g, double h) {
    const boxW = 268.0;
    final b = _buckets[_selected!];
    final x = g.xAt(_selected!);
    final left = (x + 12).clamp(HistoryChartGeometry.left, g.width - boxW - 8);
    final multiDay = _win.spanMs > 24 * 3600000;
    final stamp =
        DateFormat(multiDay ? 'MM/dd HH:mm' : 'HH:mm').format(b.at);
    String v(double? x) => x == null ? '--' : x.toStringAsFixed(2);
    final t = b.avgTemp == null
        ? ''
        : '  ·  ${historyDisplayTemp(b.avgTemp!, widget.tempUnit).toStringAsFixed(0)}'
            '${historyTempUnitLabel(widget.tempUnit)}';
    return Positioned(
      left: left,
      top: (h * 0.32).clamp(0.0, h - 56),
      width: boxW,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: context.colors.panel,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: context.colors.line2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(stamp,
                style: AppTextStyles.mono(context).copyWith(
                    fontSize: 12, fontWeight: FontWeight.w700)),
            Text(
              '${v(b.avgPvlt)} V (${v(b.minPvlt)}–${v(b.maxPvlt)})$t',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.mono(context)
                  .copyWith(fontSize: 11, color: context.colors.muted),
            ),
          ],
        ),
      ),
    );
  }

  /// 🔵 Q3 = A — operable, not decorative. Dragging it moves the window;
  /// pinching it resizes the window. It is also the answer to "I zoomed in too
  /// far and cannot find my way back", which is why Q4 could be left unbound.
  Widget _strip() => LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          DateTime timeAt(double dx) {
            final frac = (dx / w).clamp(0.0, 1.0);
            final full = widget.dataTo.millisecondsSinceEpoch -
                widget.dataFrom.millisecondsSinceEpoch;
            return DateTime.fromMillisecondsSinceEpoch(
                widget.dataFrom.millisecondsSinceEpoch + (full * frac).round());
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (d) {
              _gestureStart = _win;
              _startFocalFrac = (d.localFocalPoint.dx / w).clamp(0.0, 1.0);
            },
            onScaleUpdate: (d) {
              final start = _gestureStart;
              if (start == null) return;
              final next = d.scale == 1.0
                  ? start.centredOn(timeAt(d.localFocalPoint.dx),
                      dataFrom: widget.dataFrom, dataTo: widget.dataTo)
                  : HistoryChartWindow.apply(
                      start: start,
                      scale: d.scale,
                      startFocalFrac: _startFocalFrac,
                      focalFrac: (d.localFocalPoint.dx / w).clamp(0.0, 1.0),
                      dataFrom: widget.dataFrom,
                      dataTo: widget.dataTo,
                    );
              if (next != _win) setState(() => _win = next);
            },
            onScaleEnd: (_) => _onScaleEnd(),
            child: CustomPaint(
              size: Size.infinite,
              painter: _StripPainter(
                buckets: _overview,
                dataFrom: widget.dataFrom,
                dataTo: widget.dataTo,
                window: _win,
                line: context.colors.muted,
                accent: context.accent.accent,
                panel: context.colors.panel2,
              ),
            ),
          );
        },
      );

  String _gapLabel(AppLocalizations l10n, Duration d) {
    final minutes = d.inMinutes;
    return minutes < 60
        ? l10n.historyChartGapMinutes(minutes)
        : l10n.historyChartGapHours((minutes / 60).round());
  }
}

/// The overview: the whole recording as one coarse line, with the visible
/// window drawn over it.
class _StripPainter extends CustomPainter {
  _StripPainter({
    required this.buckets,
    required this.dataFrom,
    required this.dataTo,
    required this.window,
    required this.line,
    required this.accent,
    required this.panel,
  });

  final List<HistoryBucket> buckets;
  final DateTime dataFrom;
  final DateTime dataTo;
  final HistoryChartWindow window;
  final Color line, accent, panel;

  @override
  void paint(Canvas canvas, Size size) {
    final full =
        dataTo.millisecondsSinceEpoch - dataFrom.millisecondsSinceEpoch;
    if (full <= 0) return;
    double x(DateTime t) =>
        size.width *
        (t.millisecondsSinceEpoch - dataFrom.millisecondsSinceEpoch) /
        full;

    final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 4, size.width, size.height - 12),
        const Radius.circular(4));
    canvas.drawRRect(r, Paint()..color = panel);

    final vals = buckets.map((b) => b.avgPvlt).whereType<double>().toList();
    if (vals.length > 1) {
      final lo = vals.reduce((a, b) => a < b ? a : b);
      final hi = vals.reduce((a, b) => a > b ? a : b);
      final span = (hi - lo).abs() < 0.01 ? 1.0 : hi - lo;
      final path = Path();
      var started = false;
      for (final b in buckets) {
        final v = b.avgPvlt;
        if (v == null) continue;
        final p = Offset(
            x(b.at), 8 + (size.height - 20) * (1 - (v - lo) / span));
        started ? path.lineTo(p.dx, p.dy) : path.moveTo(p.dx, p.dy);
        started = true;
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = line
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }

    final wl = x(window.from), wr = x(window.to);
    final wr2 = RRect.fromRectAndRadius(
        Rect.fromLTRB(wl, 4, wr.clamp(wl + 6, size.width), size.height - 8),
        const Radius.circular(4));
    canvas.drawRRect(wr2, Paint()..color = accent.withValues(alpha: 0.16));
    canvas.drawRRect(
        wr2,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _StripPainter old) =>
      old.window != window ||
      old.buckets.length != buckets.length ||
      old.accent != accent;
}
