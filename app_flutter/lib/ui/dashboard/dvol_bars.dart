/// OpenSmartBatt — per-cell DVOL bars (mockup `.cell` / `.bar`).
///
/// Renders the four series-cell voltages (selector 0x24) as labelled amber
/// fill bars with a numeric readout. The fill fraction maps each cell voltage
/// across a nominal LiFePO4-ish window; this is a *display* scaling only — DVOL
/// units are not firmly pinned by the protocol facts, so the numeric value is
/// the source of truth and the bar is indicative.
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Four-cell DVOL bar list.
class DvolBars extends StatelessWidget {
  const DvolBars({super.key, required this.cells});

  /// Per-cell voltages (V). Null / short lists render `--` placeholders.
  final List<double>? cells;

  // Nominal display window for the fill fraction (indicative only).
  static const double _vMin = 2.5;
  static const double _vMax = 3.65;
  static const int _cellCount = 4;

  @override
  Widget build(BuildContext context) {
    final cells = this.cells;
    return Column(
      children: [
        for (var i = 0; i < _cellCount; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 2 : 8, bottom: 2),
            child: _CellRow(
              index: i,
              value: (cells != null && i < cells.length) ? cells[i] : null,
              fraction: _fractionFor(
                (cells != null && i < cells.length) ? cells[i] : null,
              ),
            ),
          ),
      ],
    );
  }

  static double _fractionFor(double? v) {
    if (v == null) return 0;
    final f = (v - _vMin) / (_vMax - _vMin);
    return f.clamp(0.0, 1.0);
  }
}

class _CellRow extends StatelessWidget {
  const _CellRow({
    required this.index,
    required this.value,
    required this.fraction,
  });

  final int index;
  final double? value;
  final double fraction;

  /// Width of the label column, the gutters and the value column — narrowed
  /// together below a threshold.
  ///
  /// 🔴 The three fixed costs used to add up to 126 px whatever the width, so
  /// a 1x1 home tile on a 320 dp phone (~113 px of inner room) overflowed by
  /// 13 px before the bar itself had a single pixel. Surfaced by design 0051's
  /// editor preview — the first screen that draws a real DVOL card at 1x1 —
  /// and reachable on the live home page since design 0046 put this card on
  /// the grid.
  ///
  /// A threshold rather than making the columns flexible: `Expanded` on the
  /// bar plus `Flexible` on the labels would split the row three ways and
  /// shrink the BAR at full width, which is the one part of this card that
  /// carries information by size. At 170 px and above nothing changes at all.
  static const double _tightBelow = 170;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final tight = c.maxWidth < _tightBelow;
      return _row(context, tight: tight);
    });
  }

  Widget _row(BuildContext context, {required bool tight}) {
    final gap = tight ? 6.0 : 11.0;
    return Row(
      children: [
        SizedBox(
          width: tight ? 36 : 50,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              'CELL ${index + 1}',
              maxLines: 1,
              softWrap: false,
              style: AppTextStyles.mono(context).copyWith(
                fontSize: 10,
                letterSpacing: 1,
                color: context.colors.muted,
              ),
            ),
          ),
        ),
        SizedBox(width: gap),
        Expanded(
          child: Container(
            height: 7,
            decoration: BoxDecoration(
              color: context.colors.panel2,
              border: Border.all(color: context.colors.line),
              borderRadius: BorderRadius.circular(3),
            ),
            clipBehavior: Clip.antiAlias,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: fraction,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [context.accent.accentMuted, context.accent.accent],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: gap),
        SizedBox(
          width: tight ? 44 : 54,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              value == null ? '-- V' : '${value!.toStringAsFixed(2)} V',
              maxLines: 1,
              softWrap: false,
              textAlign: TextAlign.right,
              style: AppTextStyles.mono(context).copyWith(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}
