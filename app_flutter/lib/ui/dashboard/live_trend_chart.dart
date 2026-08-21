/// OpenSmartBatt — the dashboard's chart mode: stacked sparkline tracks over
/// [LiveTrendBuffer].
///
/// Kept out of the readouts' rebuild path on purpose. The buffer notifies on
/// every decoded sample (~4.8 Hz in the field), and the readout grid is a
/// listener of `TelemetryController`, which notifies at the same rate. Painting
/// several hundred points inside that same rebuild would multiply the cost of a
/// repaint that already happens; here the chart listens to the buffer directly
/// and repaints at its own capped rate.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../state/live_trend_buffer.dart';
import '../../theme/app_theme.dart';

/// One stacked track: which series, how to label it, how to format its value.
class TrendTrack {
  const TrendTrack({
    required this.field,
    required this.label,
    required this.unit,
    required this.color,
    this.decimals = 0,
    this.spanZero = false,
    this.height = 74,
    this.minSpan = 1,
    this.directionKey,
  });

  final TrendField field;
  final String label;
  final String unit;
  final Color color;

  /// Decimal places for the axis and the live value.
  final int decimals;

  /// Force the Y range to include 0 and draw a zero rule.
  ///
  /// Set for signed current. A current axis that does not cross zero hides the
  /// one feature worth seeing — the moment the sign flips — by pushing it off
  /// the bottom of the plot.
  final bool spanZero;

  final double height;

  /// Smallest Y span to show. Without it, a reading that is flat to the
  /// millivolt fills the track with amplified noise.
  final double minSpan;

  /// What the two halves of a signed axis MEAN, e.g. 「＋充電 · −放電」.
  ///
  /// Only for a [spanZero] track, and only where the direction is established:
  /// it is a claim about the hardware, not decoration. Drawn under the plot
  /// rather than in the header row, because the header already holds a legend
  /// and a live value that fight for width on a 1x1 home tile (see
  /// [_TrackHeader]) — a third element there would ellipsise one of them.
  ///
  /// 🔴 It does NOT change the data. The 2026-08-03 ruling that the current
  /// track stays signed and zero-crossing (design 0030 §3.2 / §7 Q5) is
  /// untouched; that ruling's companion clause — "axis text says only 電流 A,
  /// never 充電／放電" — rested on the direction being unverified, which stopped
  /// being true on 2026-08-11 (`telemetry-decoding.md` §8.2). Design 0056 is
  /// the ruling that replaces it. `abs()` remains forbidden.
  final String? directionKey;
}

/// Stacked live tracks.
///
/// 🔴 This said "with a scrub cursor" until 2026-08-21 and there has never been
/// one — the chart takes no gestures at all, and the only value on screen is
/// each track's latest ([_TrackHeader]). The history chart grew a scrub in
/// design 0076; doing the same here is design 0077's question, and it is NOT
/// the same job: this buffer advances ~4.8 times a second, so a cursor has to
/// decide whether the time window freezes under the finger and when it catches
/// up again (0076 §3.8 ③).
class LiveTrendChart extends StatefulWidget {
  const LiveTrendChart({
    super.key,
    required this.buffer,
    required this.tracks,
    this.emptyLabel,
  });

  final LiveTrendBuffer buffer;
  final List<TrendTrack> tracks;

  /// Shown instead of the tracks while nothing has arrived yet.
  final String? emptyLabel;

  /// Repaint ceiling. The link delivers ~4.8 samples a second; redrawing on
  /// each one buys nothing a viewer can see and competes with BLE decoding on
  /// the same isolate.
  static const Duration frameInterval = Duration(milliseconds: 100);

  @override
  State<LiveTrendChart> createState() => _LiveTrendChartState();
}

class _LiveTrendChartState extends State<LiveTrendChart> {
  Timer? _ticker;
  int _paintedRevision = -1;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(LiveTrendChart.frameInterval, (_) {
      // Only rebuild when something actually landed. A parked link would
      // otherwise rebuild ten times a second forever.
      if (widget.buffer.revision != _paintedRevision && mounted) {
        setState(() => _paintedRevision = widget.buffer.revision);
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final buffer = widget.buffer;
    final colors = context.colors;
    final drawable =
        widget.tracks.where((t) => buffer.hasData(t.field)).toList();

    if (drawable.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Text(
          widget.emptyLabel ?? '',
          textAlign: TextAlign.center,
          style: AppTextStyles.label(context),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final track in drawable) ...[
          _TrackHeader(track: track, buffer: buffer),
          const SizedBox(height: 3),
          SizedBox(
            height: track.height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.panel2,
                border: Border.all(color: colors.line),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: CustomPaint(
                painter: _TrackPainter(
                  buffer: buffer,
                  track: track,
                  revision: buffer.revision,
                  gridColor: colors.line,
                  axisColor: colors.muted,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          // Under the plot and right-aligned: the left edge is where the axis
          // numbers are, and this is a key to the axis, not another value.
          if (track.directionKey != null) ...[
            const SizedBox(height: 3),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                track.directionKey!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.label(context),
              ),
            ),
          ],
          const SizedBox(height: 9),
        ],
      ],
    );
  }
}

/// Track label on the left, latest value on the right.
class _TrackHeader extends StatelessWidget {
  const _TrackHeader({required this.track, required this.buffer});

  final TrendTrack track;
  final LiveTrendBuffer buffer;

  @override
  Widget build(BuildContext context) {
    double? latest;
    for (var i = buffer.length - 1; i >= 0; i--) {
      final v = buffer.valueAt(track.field, i);
      if (v.isFinite) {
        latest = v;
        break;
      }
    }
    // 🔴 Both sides `Flexible`, the LABEL ellipsising first.
    //
    // A legend and its latest value at opposite ends of a row need ~200 px on
    // a pack ("MAIN CURRENT" + "-29.00 A"); a 1x1 home tile on a 320 dp phone
    // gives ~120, and the difference was a striped RenderFlex bar across the
    // top of the chart. Surfaced by design 0051's editor preview — the first
    // screen that draws a real chart at 1x1 — but reachable on the live home
    // page since design 0046 put the chart on the grid.
    //
    // The value is `flex: 0` so it is never the one that loses characters: a
    // truncated NUMBER is a wrong reading, while a truncated legend is still
    // recognisable from the track's colour and position.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            track.label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.label(context),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          flex: 0,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              latest == null
                  ? '--'
                  : '${latest.toStringAsFixed(track.decimals)} ${track.unit}',
              maxLines: 1,
              softWrap: false,
              style: AppTextStyles.mono(context).copyWith(color: track.color),
            ),
          ),
        ),
      ],
    );
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter({
    required this.buffer,
    required this.track,
    required this.revision,
    required this.gridColor,
    required this.axisColor,
  });

  final LiveTrendBuffer buffer;
  final TrendTrack track;
  final int revision;
  final Color gridColor;
  final Color axisColor;

  static const double _padLeft = 38, _padRight = 8, _padTop = 8, _padBottom = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final range = buffer.rangeOf(track.field);
    final firstMs = buffer.firstMs, lastMs = buffer.lastMs;
    if (range == null || firstMs == null || lastMs == null) return;

    var lo = range.min, hi = range.max;
    if (track.spanZero) {
      lo = math.min(lo, 0);
      hi = math.max(hi, 0);
    }
    if (hi - lo < track.minSpan) {
      final mid = (hi + lo) / 2;
      lo = mid - track.minSpan / 2;
      hi = mid + track.minSpan / 2;
    }
    final pad = (hi - lo) * 0.12;
    lo -= pad;
    hi += pad;

    // A parked link makes lastMs == firstMs; a zero denominator would put every
    // point at the same x and draw nothing.
    final tSpan = math.max(lastMs - firstMs, 1.0);
    final plotW = size.width - _padLeft - _padRight;
    final plotH = size.height - _padTop - _padBottom;
    double x(double ms) => _padLeft + (ms - firstMs) / tSpan * plotW;
    double y(double v) => _padTop + (1 - (v - lo) / (hi - lo)) * plotH;

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final value = lo + (hi - lo) * i / 2;
      final gy = y(value).roundToDouble() + 0.5;
      canvas.drawLine(Offset(_padLeft, gy), Offset(size.width - _padRight, gy), grid);
      _label(canvas, value.toStringAsFixed(track.decimals), _padLeft - 4, gy);
    }
    if (track.spanZero && lo < 0 && hi > 0) {
      _dashedZero(canvas, size, y(0).roundToDouble() + 0.5);
    }

    final path = Path();
    var started = false;
    Offset? last;
    for (var i = 0; i < buffer.length; i++) {
      final v = buffer.valueAt(track.field, i);
      if (!v.isFinite) continue; // a gap, not a zero
      final p = Offset(x(buffer.timeAt(i)), y(v));
      started ? path.lineTo(p.dx, p.dy) : path.moveTo(p.dx, p.dy);
      started = true;
      last = p;
    }
    if (!started || last == null) return;

    final fill = Path.from(path)
      ..lineTo(last.dx, size.height - _padBottom)
      ..lineTo(_padLeft, size.height - _padBottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [track.color.withValues(alpha: 0.30), track.color.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, _padTop, size.width, plotH)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = track.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(last, 3.2, Paint()..color = track.color);
  }

  void _dashedZero(Canvas canvas, Size size, double gy) {
    final paint = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    for (var dx = _padLeft; dx < size.width - _padRight; dx += 6) {
      canvas.drawLine(
          Offset(dx, gy), Offset(math.min(dx + 3, size.width - _padRight), gy), paint);
    }
  }

  void _label(Canvas canvas, String text, double right, double centerY) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: axisColor,
          fontSize: 10,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(right - tp.width, centerY - tp.height / 2));
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.revision != revision ||
      old.track != track ||
      old.gridColor != gridColor;
}
