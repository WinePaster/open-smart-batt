/// Open-RCE-Batt — per-cell DVOL bars (mockup `.cell` / `.bar`).
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

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 50,
          child: Text(
            'CELL ${index + 1}',
            style: AppTextStyles.mono(context).copyWith(
              fontSize: 10,
              letterSpacing: 1,
              color: context.colors.muted,
            ),
          ),
        ),
        const SizedBox(width: 11),
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
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [AppColors.amberDark, AppColors.amber],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 11),
        SizedBox(
          width: 54,
          child: Text(
            value == null ? '-- V' : '${value!.toStringAsFixed(2)} V',
            textAlign: TextAlign.right,
            style: AppTextStyles.mono(context).copyWith(fontSize: 12),
          ),
        ),
      ],
    );
  }
}
