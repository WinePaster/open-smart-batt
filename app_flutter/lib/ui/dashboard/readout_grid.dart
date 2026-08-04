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
    this.badge,
    this.badgeColor,
  });

  final IconData icon;
  final String label;

  /// Formatted value, or '--' when unknown.
  final String value;

  /// Optional unit suffix (mockup `.v .u`).
  final String? unit;

  /// Optional pill under the value, for a fact the NUMBER cannot carry on its
  /// own. Added for FB-47: a power bank's current is signed (design 0030 —
  /// discharge positive, charge negative), and a bare `-0.43 A` was read as a
  /// defect by the owner who ruled on the sign convention. The word beside it
  /// is what makes the minus a direction rather than an error.
  ///
  /// Null means "nothing to add" — never an empty pill, which would read as a
  /// missing value.
  final String? badge;

  /// Accent of [badge] (border + text). Falls back to the muted tone.
  final Color? badgeColor;
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
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        decoration: BoxDecoration(
          color: line,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
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
          // Text.rich, NOT RichText: the raw RichText defaults to
          // `TextScaler.noScaling` (Flutter `basic.dart`), so this value —
          // and the gauge readout, the other direct RichText in the app —
          // silently ignored the OS text-size setting entirely, while the
          // label beside it (a plain Text) honoured it.
          Text.rich(
            TextSpan(
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
          if (item.badge != null) ...[
            const SizedBox(height: 6),
            _BadgePill(text: item.badge!, accent: item.badgeColor),
          ],
        ],
      ),
    );
  }
}

/// Small pill under a readout value (mockup `.badge`, tile scale).
///
/// Sits UNDER the value rather than beside the label: the grid is two columns
/// on a phone, and a pill on the label row pushes the label into an ellipsis
/// exactly when the tile matters most.
class _BadgePill extends StatelessWidget {
  const _BadgePill({required this.text, this.accent});

  final String text;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tone = accent ?? colors.muted;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: tone),
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: tone,
          ),
        ),
      ),
    );
  }
}
