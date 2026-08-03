/// OpenSmartBatt — the readouts card, with a numbers/chart toggle.
///
/// One card, two presentations of the SAME live values. The toggle lives in the
/// card header because it changes how this card shows its own contents, not
/// what the device does.
///
/// Why a chart at all: the numbers already update several times a second, but a
/// number that flickers cannot show a shape. A cranking load lasts a couple of
/// seconds — long enough to read on a curve, too short to read as digits, and
/// gone entirely from stored history, which keeps one averaged row per minute.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/live_trend_buffer.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial_card.dart';
import 'readout_grid.dart';
import 'live_trend_chart.dart';

/// Readouts with an optional chart mode.
///
/// [tracks] empty means this product class has nothing worth plotting, and the
/// toggle is not offered at all — a toggle that leads to an empty chart is
/// worse than no toggle.
class ReadoutsCard extends StatefulWidget {
  const ReadoutsCard({
    super.key,
    required this.items,
    required this.buffer,
    required this.tracks,
    this.chartFootnote,
  });

  final List<Readout> items;
  final LiveTrendBuffer buffer;
  final List<TrendTrack> tracks;

  /// Small note under the chart — used to say why a series a viewer might
  /// expect is absent.
  final String? chartFootnote;

  @override
  State<ReadoutsCard> createState() => _ReadoutsCardState();
}

class _ReadoutsCardState extends State<ReadoutsCard> {
  bool _chart = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final offerChart = widget.tracks.isNotEmpty;
    final showChart = _chart && offerChart;

    return IndustrialCard(
      heading: l10n.dashboardReadoutsHeading,
      headingIcon: Icons.speed,
      headingTrailing: offerChart
          ? _ModeToggle(
              chart: showChart,
              onChanged: (v) => setState(() => _chart = v),
            )
          : null,
      child: showChart
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LiveTrendChart(
                  buffer: widget.buffer,
                  tracks: widget.tracks,
                  emptyLabel: l10n.dashboardChartWaiting,
                ),
                if (widget.chartFootnote != null) ...[
                  const SizedBox(height: 4),
                  Text(widget.chartFootnote!,
                      style: AppTextStyles.label(context)),
                ],
              ],
            )
          : ReadoutGrid(items: widget.items),
    );
  }
}

/// Two-state segmented control (mockup `.seg`).
class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.chart, required this.onChanged});

  final bool chart;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.panel2,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(context, l10n.dashboardModeNumbers, !chart, () => onChanged(false)),
          _seg(context, l10n.dashboardModeChart, chart, () => onChanged(true)),
        ],
      ),
    );
  }

  Widget _seg(BuildContext context, String label, bool on, VoidCallback tap) {
    return InkWell(
      onTap: tap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        color: on ? AppColors.amber : Colors.transparent,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1,
            fontWeight: on ? FontWeight.w700 : FontWeight.w400,
            color: on ? AppColors.onAmber : context.colors.muted,
          ),
        ),
      ),
    );
  }
}
