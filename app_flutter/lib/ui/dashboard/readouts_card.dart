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
/// mechanism for the same question.
///
/// ⚠️ The chart's home is the `diagnostic` face, and ONLY that face
/// (`watchfaces.dart`). Design 0040 Q1 proposed giving `standard` a copy so
/// that nobody would lose the curve; the owner reversed that on review, knowing
/// the consequence — **a user who never opens Settings can no longer see the
/// live chart at all**, where before this build the header toggle put it one
/// tap away. That is a capability withdrawn from the default install. It is
/// written here because this file is where someone will come looking after
/// asking "where did the chart go".
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/card_view.dart';
import '../../state/live_trend_buffer.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial_card.dart';
import 'readout_grid.dart';
import 'live_trend_chart.dart';

/// The numbers grid, as a card.
///
/// The per-class decision about WHICH readouts appear is made by the registry
/// and handed in as [items]; this card only decides how they are ARRANGED.
///
/// 🔴 That division is design 0054 S-R1 / F5, and it is why [view] can exist at
/// all: a content variant may change the arrangement and may never change the
/// list. Nothing below inspects, filters or reorders [items].
class ReadoutsCard extends StatelessWidget {
  const ReadoutsCard({
    super.key,
    required this.items,
    this.view = ReadoutsView.grid,
  });

  final List<Readout> items;

  /// Which arrangement. Scoped to THIS card — see `card_view.dart`.
  final ReadoutsView view;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.dashboardReadoutsHeading,
      headingIcon: Icons.speed,
      // Exhaustive, no `default`: a new [ReadoutsView] is a compile error here
      // rather than a silent fall-back to the grid.
      child: switch (view) {
        ReadoutsView.grid => ReadoutGrid(items: items),
        ReadoutsView.big => ReadoutHero(items: items),
      },
    );
  }
}

/// The `big` view: the FIRST readout at gauge size, the rest on one line.
///
/// ## Zero information loss, and why that is a hard requirement
///
/// Every item's label, value, unit AND badge is still on screen. Design 0054 F4
/// permits a view to print less only when it buys emphasis with what it gave up;
/// this one gives up nothing at all, it re-weights. A version that simply
/// dropped the tail would leave the user unable to discover what they had lost —
/// the defect F4 is named after.
///
/// ⚠️ The hero is `items.first` and the user cannot pick it (design 0054 Q1). On
/// a battery that means the TEMPERATURE is what gets enlarged, which is a known
/// and accepted cost: making it selectable is the per-card × per-field Cartesian
/// product design 0040 Q4 refused, and reordering is the registry's job.
class ReadoutHero extends StatelessWidget {
  const ReadoutHero({super.key, required this.items});

  final List<Readout> items;

  @override
  Widget build(BuildContext context) {
    // A card with nothing in it has no first item to promote. The grid renders
    // an empty list as an empty box, which is the same honest nothing.
    if (items.isEmpty) return ReadoutGrid(items: items);
    final hero = items.first;
    final rest = items.skip(1).toList(growable: false);
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(hero.icon, size: 12, color: colors.muted),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                hero.label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.label(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        // Same overflow remedy as `_BigValue` and the clock: `Expanded` +
        // `FittedBox(scaleDown)`, so a 50 px number in a half-width tile shrinks
        // instead of drawing a striped RenderFlex bar over the one value this
        // view exists to show.
        Row(
          children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text.rich(
                  TextSpan(
                    text: hero.value,
                    style: AppTextStyles.gaugeValue(context),
                    children: [
                      if (hero.unit != null)
                        TextSpan(
                          text: ' ${hero.unit}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colors.muted,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                ),
              ),
            ),
          ],
        ),
        if (hero.badge != null) ...[
          const SizedBox(height: 6),
          ReadoutBadgePill(text: hero.badge!, accent: hero.badgeColor),
        ],
        if (rest.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.only(top: 9),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.line)),
            ),
            child: Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                for (final r in rest) _RestItem(item: r),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// One of the demoted readouts: label, value, unit and badge on a single line.
///
/// ⚠️ The LABEL is the flexible part, and the value is not.
///
/// A demoted row is `TEMPERATURE TEMP 41 °C`, and one such item can be wider
/// than the whole card — found by design 0054's own editor test, which lays a
/// card out at 330 px for the appearance thumbnails and drew a striped
/// RenderFlex bar across it. Ellipsising the LABEL is the correct failure, the
/// same choice `CardHeading` makes: a label is a name and survives losing its
/// tail; a reading that has lost digits is a lie.
class _RestItem extends StatelessWidget {
  const _RestItem({required this.item});

  final Readout item;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            item.label.toUpperCase(),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.label(context),
          ),
        ),
        const SizedBox(width: 5),
        Text.rich(
          TextSpan(
            text: item.value,
            style: AppTextStyles.mono(context).copyWith(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: colors.text,
            ),
            children: [
              if (item.unit != null)
                TextSpan(
                  text: ' ${item.unit}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: colors.muted,
                  ),
                ),
            ],
          ),
          maxLines: 1,
          softWrap: false,
        ),
        // Never dropped — see [ReadoutBadgePill].
        if (item.badge != null) ...[
          const SizedBox(width: 5),
          ReadoutBadgePill(text: item.badge!, accent: item.badgeColor),
        ],
      ],
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
