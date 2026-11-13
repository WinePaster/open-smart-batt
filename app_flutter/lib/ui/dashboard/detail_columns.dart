/// OpenSmartBatt — the device page's live tab in two columns (design 0105 P4,
/// owner ruling 2026-11-13 Q5 = A).
///
/// In a landscape window wide enough for two [WideLayout] columns, the page
/// that is otherwise one 560-wide column splits into:
///
///   * pack (battery / capacitor): left = the gauge and the numbers grid (and
///     any phone-sensor card); right = cell voltages, the live chart, then
///     the protection card and the warnings entry;
///   * power bank: left = the charge gauge (and any phone-sensor card); right
///     = the energy path, the numbers grid, the chart, then the warnings
///     entry.
///
/// ⚠️ **Where there is no gauge, the chart takes its place on the left.**
/// 0105 §6 P4 and mock §4 were drawn with a gauge on the device page, but the
/// fixed face (design 0051, owner rulings 2026-08-16 / 2026-08-17) draws none
/// for any identified class: a pack page is chart → numbers → cells, a power
/// bank page chart → numbers → energy path. Taken literally the split would
/// leave a pack's left column with the numbers grid alone and a power bank's
/// left column EMPTY. Moving the chart into the gauge's slot keeps the left
/// column "the live reading" and the right column "the detail and the
/// controls", which is what the split was for. With a gauge on the page
/// (an unclassified pack's fallback face) the split is exactly as specified.
///
/// 🔴 Design 0034 §6 says the control card is last, always. Design 0105 Q5 = A
/// relaxes that to **last in the RIGHT column**: in two columns there is no
/// single "last", and the right column is where the eye ends. What did NOT
/// change is the structural half of the rule — there is still no
/// [DisplayModule] for the protection card, so no watchface can move or
/// remove it; the shells append it after every card a face placed, in
/// whichever column layout is in force.
///
/// Portrait — and a landscape window too narrow for two columns — gets the
/// caller's single-column tree, untouched.
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../util/wide_layout.dart';

/// Which modules a two-column device page draws in its RIGHT column; the rest
/// go left, each column keeping the watchface's order.
abstract final class DetailColumns {
  /// Battery / capacitor (0105 §6 P4: 左＝錶盤＋讀數；右＝分串／曲線).
  static const Set<DisplayModule> packRight = {
    DisplayModule.cells,
    DisplayModule.chart,
    DisplayModule.energyPath,
  };

  /// Power bank (0105 §6 P4: 左＝電量錶；右＝能量路徑＋讀數).
  static const Set<DisplayModule> powerBankRight = {
    DisplayModule.energyPath,
    DisplayModule.readouts,
    DisplayModule.chart,
    DisplayModule.cells,
  };

  /// The right-column set actually used for a page drawing [order]: [base],
  /// minus the chart when the page has no gauge (see the library doc).
  static Set<DisplayModule> rightFor(
    Set<DisplayModule> base,
    Iterable<DisplayModule> order,
  ) {
    final hasGauge = order.any(
      (m) => m == DisplayModule.gaugeVoltage || m == DisplayModule.gaugeSoc,
    );
    return hasGauge ? base : base.difference(const {DisplayModule.chart});
  }

  /// Split ([module], card) pairs into left and right, preserving order;
  /// [right] is the base set ([packRight] / [powerBankRight]), adjusted by
  /// [rightFor] here.
  static (List<Widget>, List<Widget>) split(
    List<(DisplayModule, Widget?)> cards,
    Set<DisplayModule> right,
  ) {
    final placed = [
      for (final (m, w) in cards)
        if (w != null) m,
    ];
    final r0 = rightFor(right, placed);
    final l = <Widget>[];
    final r = <Widget>[];
    for (final (m, w) in cards) {
      if (w == null) continue;
      (r0.contains(m) ? r : l).add(w);
    }
    return (l, r);
  }
}

/// Chooses between the caller's [single] column and two columns built from
/// [header], [left] and [right] (see the library doc).
class DetailBody extends StatelessWidget {
  const DetailBody({
    super.key,
    required this.single,
    required this.header,
    required this.left,
    required this.right,
  });

  /// Today's page, returned as-is in portrait.
  final Widget single;

  /// Full-width rows above the columns (class chip, serial).
  final List<Widget> header;

  /// The left column's cards.
  final List<Widget> left;

  /// The right column's cards, ending with the shell-level appends (the
  /// protection card, then the warnings entry).
  final List<Widget> right;

  /// Side padding — the single column's, so the two read alike.
  static const double _hPad = 15;

  @override
  Widget build(BuildContext context) {
    if (!WideLayout.isLandscape(MediaQuery.sizeOf(context))) return single;
    final largeText = WideLayout.largeText(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = WideLayout.columnsFor(
          constraints.maxWidth - 2 * _hPad,
          max: 2,
          largeText: largeText,
        );
        if (columns < 2) return single;
        return ListView(
          key: const ValueKey('detail-two-columns'),
          padding: const EdgeInsets.fromLTRB(_hPad, 3, _hPad, 14),
          children: [
            ...header,
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: WideLayout.maxWidthFor(2),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        key: const ValueKey('detail-left'),
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: left,
                      ),
                    ),
                    const SizedBox(width: WideLayout.columnGap),
                    Expanded(
                      child: Column(
                        key: const ValueKey('detail-right'),
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: right,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
