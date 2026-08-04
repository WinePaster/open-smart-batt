/// OpenSmartBatt — the readouts card and the trend-chart card.
///
/// These were ONE card with a numbers/chart toggle in its header until design
/// 0034 Phase 1 (implemented by design 0040) split them. Both halves live here
/// because they are still two presentations of the same live values, and the
/// split's whole risk is that the chart's attachments — its footnote above all
/// — get left behind on the readouts side.
///
/// Why a chart at all: the numbers already update several times a second, but a
/// number that flickers cannot show a shape. A cranking load lasts a couple of
/// seconds — long enough to read on a curve, too short to read as digits, and
/// gone entirely from stored history, which keeps one averaged row per minute.
///
/// ## Why the toggle is gone
///
/// A two-state segmented control in the readouts header used to swap this card
/// between numbers and chart, and that state was never persisted — switching
/// device and coming back put you on "numbers" again. (Its identifier is
/// deliberately not repeated here: a test scans `lib/` for it, so that the day
/// someone reintroduces the widget the scan fails rather than matching a
/// comment.) Design 0034 §5.2 ruled that once both are placeable
/// modules the toggle has no meaning: the watchface decides which cards are on
/// the page, and a per-card view switch on top of that is a second, weaker
/// mechanism for the same question. The chart now has a permanent home on the
/// `standard` and `diagnostic` faces (`watchfaces.dart`).
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/live_trend_buffer.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial_card.dart';
import 'readout_grid.dart';
import 'live_trend_chart.dart';

/// The numbers grid, as a card.
///
/// Nothing but a [ReadoutGrid] in an [IndustrialCard]; the per-class decision
/// about WHICH readouts appear is made by the view, from the registry.
class ReadoutsCard extends StatelessWidget {
  const ReadoutsCard({super.key, required this.items});

  final List<Readout> items;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.dashboardReadoutsHeading,
      headingIcon: Icons.speed,
      child: ReadoutGrid(items: items),
    );
  }
}

/// The live trend chart, as a card (design 0034 Phase 1 / design 0040 §3.1).
///
/// ⚠️ [chartFootnote] travels WITH the chart, and that is the point of putting
/// it in this constructor rather than leaving it on the readouts card it used
/// to share. On a super-capacitor the footnote reads "no current track: this
/// unit reports a constant 0 A, which is not a measurement" — it exists to stop
/// an owner concluding the app failed to fetch a current it can see on the
/// battery screens. A chart drawn without it is a chart that silently misses a
/// series, which is worse than the pre-split behaviour.
///
/// No emptiness check here. Two gates already stand upstream and neither can be
/// satisfied by a card-level `if`:
///
///  * a class with no tracks has no `chart` module at all
///    ([DisplayModules.chartTracks] empty ⇒ `chart` absent from `modules`), so
///    no watchface can place this card;
///  * a track whose field has not arrived yet is dropped by [LiveTrendChart]
///    itself, which shows `emptyLabel` when none is left. That is a WAITING
///    state, not an absent card — the same reading design 0035 §4.6 gave the
///    energy-path row, and the reason `chart` is deliberately NOT in
///    `dataGated` (design 0040 Q3).
class TrendChartCard extends StatelessWidget {
  const TrendChartCard({
    super.key,
    required this.buffer,
    required this.tracks,
    this.chartFootnote,
  });

  final LiveTrendBuffer buffer;
  final List<TrendTrack> tracks;

  /// Small note under the chart — used to say why a series a viewer might
  /// expect is absent.
  final String? chartFootnote;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.dashboardChartHeading,
      headingIcon: Icons.show_chart,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LiveTrendChart(
            buffer: buffer,
            tracks: tracks,
            emptyLabel: l10n.dashboardChartWaiting,
          ),
          if (chartFootnote != null) ...[
            const SizedBox(height: 4),
            Text(chartFootnote!, style: AppTextStyles.label(context)),
          ],
        ],
      ),
    );
  }
}
