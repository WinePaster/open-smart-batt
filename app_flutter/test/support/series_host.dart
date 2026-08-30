/// 🔵 design 0089 (FB-103) — the shared test host for the history chart.
///
/// `HistoryTrendCard` stopped owning its series on 2026-08-29: the card's
/// HEADING is the voltage/current switch now, because a card titled
/// "Voltage Trend" had already told the reader there was no current to find
/// (and went on saying it after the axis switched). The card is therefore a
/// controlled component, and any test that wants to exercise switching has to
/// reproduce the production arrangement — heading above, card below, one piece
/// of state between them.
///
/// ⛔ **Do not go back to driving the card with an internal toggle.** There is
/// no toolbar `swap_vert` any more (0089 Q3): two controls doing one thing is
/// how the next reader stops knowing which one is authoritative.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/history/history_chart_core.dart';
import 'package:open_smart_batt/ui/history/history_query.dart';
import 'package:open_smart_batt/ui/history/history_series_switch.dart';
import 'package:open_smart_batt/ui/widgets/industrial_card.dart';

typedef SeriesChildBuilder = Widget Function(
    HistoryChartSeries series, ValueChanged<HistoryChartSeries> onChanged);

class SeriesHost extends StatefulWidget {
  const SeriesHost({
    super.key,
    required this.cls,
    required this.child,
    this.sel,
  });

  /// The scope's class. `null` is the ALL-DEVICES scope (current refused).
  final ProductClass? cls;
  final SeriesChildBuilder child;
  final HistoryRangeSel? sel;

  @override
  State<SeriesHost> createState() => _SeriesHostState();
}

class _SeriesHostState extends State<SeriesHost> {
  HistoryChartSeries _series = HistoryChartSeries.voltage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final framing = historyChartFraming(
      l10n,
      widget.sel ?? HistoryRangeSel.initial,
      deviceClass: widget.cls,
      series: _series,
    );
    return IndustrialCard(
      heading: framing.heading,
      headingIcon: Icons.show_chart,
      onHeadingTap: framing.canSwitch
          ? () => setState(() => _series =
              framing.series == HistoryChartSeries.current
                  ? HistoryChartSeries.voltage
                  : HistoryChartSeries.current)
          : null,
      // 🔵 FB-107 — the SAME builder production uses, so a test can assert on
      // the word 「切換」 and mean the thing the user sees.
      headingTrailing: historySeriesSwitchAffordance(context, l10n,
          canSwitch: framing.canSwitch),
      child: widget.child(framing.series, (v) => setState(() => _series = v)),
    );
  }
}

/// The switch's affordance, as a finder — present only when switching is
/// allowed (design 0089 §3.1).
Finder seriesToggle() => find.byIcon(Icons.swap_vert);

/// The heading itself, which IS the switch. By type rather than by text: the
/// label is `toUpperCase()`d and has a "Today's …" variant, so matching on a
/// string makes a test fail for reasons that have nothing to do with it.
Finder chartHeading() => find.byType(CardHeading);
