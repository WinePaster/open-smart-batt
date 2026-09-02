/// OpenSmartBatt — the dashboard's chart mode: stacked sparkline tracks over
/// [LiveTrendBuffer].
///
/// Kept out of the readouts' rebuild path on purpose. The buffer notifies on
/// every decoded sample (~4.8 Hz in the field), and the readout grid is a
/// listener of `TelemetryController`, which notifies at the same rate. Painting
/// several hundred points inside that same rebuild would multiply the cost of a
/// repaint that already happens; here the chart listens to the buffer directly
/// and repaints at its own capped rate.
///
/// 📦 The PICTURE itself now lives in `live_trend_chart_core.dart` (design 0093
/// §3.1) and is re-exported here, so every existing import of [TrendTrack] keeps
/// working. This file is one of the core's two shells; the other is
/// `live_trend_chart_page.dart`.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/live_trend_buffer.dart';
import '../../theme/app_theme.dart';
import 'live_trend_chart_core.dart';

export 'live_trend_chart_core.dart';

/// Stacked live tracks.
///
/// 🔴 This said "with a scrub cursor" until 2026-08-21 and there has never been
/// one — the chart takes no gestures at all, and the only value on screen is
/// each track's latest ([TrendTrackHeader]). The history chart grew a scrub in
/// design 0076; doing the same here is **design 0093 §4 Q2**, and it is NOT the
/// same job: this buffer advances ~4.8 times a second, so a cursor has to decide
/// whether the time window freezes under the finger and when it catches up again
/// (0076 §3.8 ③).
///
/// 🔵 **Ruled NO on 2026-09-02** (owner, 逐字「Q2 NO」): neither shell takes a
/// gesture, full screen included.
/// ⚠️ Until then this comment said the question was design **0078**'s. It is not
/// — 0078 is 〈遙測幀不帶裝置身分〉, and no design doc had ever covered this.
class LiveTrendChart extends StatefulWidget {
  const LiveTrendChart({
    super.key,
    required this.buffer,
    required this.tracks,
    this.emptyLabel,
    this.fillHeight = false,
  });

  /// 🔑 [TrendSource], not [LiveTrendBuffer]: the full-screen shell draws a
  /// [FrozenTrendSnapshot] after a disconnect (design 0093 §3.3) and it must be
  /// the SAME widget doing it. A second rendering of a frozen chart is FB-74 /
  /// design 0065 §6 R5 with the added twist that nobody could tell which one had
  /// stopped.
  final TrendSource buffer;

  final List<TrendTrack> tracks;

  /// Shown instead of the tracks while nothing has arrived yet.
  final String? emptyLabel;

  /// Divide the available height between the tracks instead of using each
  /// track's own [TrendTrack.height] (design 0093 §4 Q3).
  ///
  /// False on a card, where the chart sits in a vertical scroll view and has no
  /// height to divide. True full screen, where it does.
  final bool fillHeight;

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
  bool _routeIsCurrent = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 🔵 design 0093 §3.2 (owner, 2026-09-02). While the full-screen shell is
    // pushed on top, the card underneath must stop ticking.
    //
    // 🔴 `TickerMode` cannot do this and neither can `Offstage`: the repaint
    // clock here is a `Timer.periodic`, which both leave running — the same
    // trap `device_detail_page.dart` records for `Offstage` and `build`. Reading
    // the route is what actually stops it, and it stops it for a dialog or any
    // other pushed route too, which is the same answer for the same reason.
    //
    // `ModalRoute.of` depends on `_ModalScopeStatus`, so this method runs again
    // when the route stops being the current one. Outside any route (widget
    // tests that pump a bare card) there is nothing covering us, so: active.
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    if (current == _routeIsCurrent && _ticker != null) return;
    _routeIsCurrent = current;
    _syncTicker();
  }

  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (!_routeIsCurrent) return;
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

    return _stack(context, drawable,
        widget.fillHeight ? trackFlexWeights(drawable) : null);
  }

  /// [weights] null ⇒ each plot is its track's own height (the card). Non-null
  /// ⇒ the plots share what the column has left, in that ratio (full screen).
  Widget _stack(
    BuildContext context,
    List<TrendTrack> drawable,
    List<int>? weights,
  ) {
    final buffer = widget.buffer;
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, track) in drawable.indexed) ...[
          TrendTrackHeader(track: track, buffer: buffer),
          const SizedBox(height: 3),
          _plotBox(
            weight: weights?[i],
            height: track.height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.panel2,
                border: Border.all(color: colors.line),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: CustomPaint(
                painter: TrendTrackPainter(
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

  /// A fixed band on a card, a proportional one full screen.
  Widget _plotBox({
    required int? weight,
    required double height,
    required Widget child,
  }) =>
      weight == null
          ? SizedBox(height: height, child: child)
          : Expanded(flex: weight, child: child);
}
