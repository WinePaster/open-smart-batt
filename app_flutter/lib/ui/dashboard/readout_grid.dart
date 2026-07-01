/// OpenSmartBatt — live readout grid (mockup `.grid2` / `.stat`).
///
/// A 2x2 hairline grid of the four headline registers: temperature, main
/// current, secondary voltage (SVLT) and state-of-health (SOH).
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// One readout tile (mockup `.stat`).
class Readout {
  const Readout({
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
  });

  final IconData icon;
  final String label;

  /// Formatted value, or '--' when unknown.
  final String value;

  /// Optional unit suffix (mockup `.v .u`).
  final String? unit;
}

/// The four-up readout grid.
class ReadoutGrid extends StatelessWidget {
  const ReadoutGrid({super.key, required this.items});

  /// Tiles to render (expected length 4 for the 2x2 layout).
  final List<Readout> items;

  @override
  Widget build(BuildContext context) {
    // Hairline grid: 1px line background showing through 1px gaps.
    final line = context.colors.line;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: line,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: line),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var row = 0; row < items.length; row += 2)
              Padding(
                padding: EdgeInsets.only(top: row == 0 ? 0 : 1),
                // IntrinsicHeight bounds the row height so the stretched tiles
                // (equal height) don't try to fill the ListView's unbounded
                // height — that bug left the whole grid unrendered.
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _StatTile(item: items[row])),
                      if (row + 1 < items.length) ...[
                        const SizedBox(width: 1),
                        Expanded(child: _StatTile(item: items[row + 1])),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.item});

  final Readout item;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.colors.panel2,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(item.icon, size: 14, color: context.colors.muted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  item.label.toUpperCase(),
                  style: AppTextStyles.label(context),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          RichText(
            text: TextSpan(
              text: item.value,
              style: AppTextStyles.statValue(context),
              children: [
                if (item.unit != null)
                  TextSpan(
                    text: ' ${item.unit}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: context.colors.muted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
