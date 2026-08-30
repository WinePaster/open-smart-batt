/// OpenSmartBatt — the voltage/current switch's AFFORDANCE, in one place.
///
/// 🔵 design 0089 (FB-103) made the chart card's heading the switch and hung a
/// bare 14 px `swap_vert` off `IndustrialCard.headingTrailing` to advertise it.
/// 🔴 **FB-107 (2026-08-30, owner) — that was still not findable.** Verbatim:
/// 「切換電壓跟電流趨勢的 icon 很不明顯 可以在按鈕旁邊放切換兩個字嗎？」 —
/// which is FB-70's shape a third time: an entry point the user cannot see is
/// the same as a feature that is not there.
///
/// So the glyph now travels with a WORD. One builder, three call sites
/// (`history_screen.dart`, `device_history_tab.dart`, and the tests' own
/// `SeriesHost`) — the same reason design 0079 S4 gave for `historyChartFraming`:
/// an affordance spelled out at each call site is an affordance that drifts.
///
/// ⛔ **Not applied to the landscape page.** Owner ruling 2026-08-30: its
/// control already carries a word (the series NAME, 「電壓」/「電流」), and its
/// 44 px bar has no room — English 'Voltage' + 'Switch' + the glyph overruns
/// the 96 px cap `history_chart_page.dart` reserves. See that file's
/// `_seriesSwitch`.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// The trailing control for the chart card's heading, or `null` when the gate
/// is shut.
///
/// 🔑 Returns `null` rather than a greyed-out control, and the ternary lives
/// HERE rather than at each call site. design 0089 §3.1 ruled that a disabled
/// heading is unreadable (nobody knows what a greyed-out title means) while the
/// REFUSAL SENTENCE stays on the plot either way — so nothing is lost by the
/// control going away. Keeping that decision inside the builder is what stops
/// the three call sites from answering it differently.
Widget? historySeriesSwitchAffordance(
  BuildContext context,
  AppLocalizations l10n, {
  required bool canSwitch,
}) {
  if (!canSwitch) return null;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      // ⚠️ The word comes FIRST, glyph second. The heading row reads
      // left-to-right and ends at this slot; a glyph before its own label puts
      // the unlabelled thing back in the position FB-107 was reported about.
      //
      // Not `toUpperCase()`d, unlike the heading it sits beside: this is not
      // part of the title, it is the label of a control, and the app's other
      // control labels (`historyChartExpand`, the stepper rows) are sentence
      // case.
      Text(
        l10n.historyChartSeriesSwitchLabel,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: context.colors.muted,
        ),
      ),
      const SizedBox(width: 3),
      Icon(Icons.swap_vert, size: 14, color: context.colors.muted),
    ],
  );
}
