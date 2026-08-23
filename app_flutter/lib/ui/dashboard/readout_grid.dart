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
  /// discharge positive, charge negative **on that family only**), and a bare
  /// `-0.43 A` was read as a defect by the owner who ruled on the sign
  /// convention. The word beside it is what makes the minus a direction rather
  /// than an error.
  ///
  /// The same shape now carries a PACK's direction too (design 0056), where the
  /// sign runs the other way (`0x2E`: negative = discharge). Two families, one
  /// pill, two derivations — see `power_flow.dart`.
  ///
  /// Null means "nothing to add" — never an empty pill, which would read as a
  /// missing value.
  final String? badge;

  /// Accent of [badge] (border + text). Falls back to the muted tone.
  final Color? badgeColor;
}

/// One [_StatTile]'s own horizontal padding, on each side.
///
/// Named because [ReadoutGrid] has to subtract it to know how much room a cell
/// really offers its text, and a second copy of `14` is how that calculation
/// silently stops matching the tile it describes.
const double kReadoutTilePadH = 14;

/// The narrowest a two-column cell's CONTENT may be before the grid folds to
/// one column (design 0084 §4.5 / S5).
///
/// 🔴 The binding constraint is that a VALUE must never wrap: [_StatTile]
/// prints it with [Text.rich], which has no `maxLines`, so a cell narrower than
/// the widest value string breaks `10000 mAh` across two lines — and a number
/// split over two lines is briefly readable as a different number. That is the
/// same defect the G readout shipped with (`test/narrow_tile_layout_test.dart`
/// header), one card along.
///
/// The widest string this app produces is `10000 mAh` — five tabular digits at
/// the value type's 23 px plus a three-letter unit at 11 px — which needs
/// roughly 101 px in a shipping font. 110 is that with a margin for the text
/// scaler's first notch.
///
/// ⚠️ **It could not be measured in a widget test, and that is worth knowing
/// before anyone "tightens" it.** Flutter's test font draws every glyph as a
/// SQUARE of the font size, so the same string measures ~154 px there. A
/// breakpoint derived from that number would fold a 360 pt phone's FULL-width
/// card to one column — a real regression bought with a test-font artefact. So
/// `readout_grid_narrow_test.dart` pins the arithmetic and the resulting column
/// counts, and deliberately does NOT assert "nothing wraps"; its header says
/// why at length.
///
/// ⚠️ The LABEL is deliberately NOT part of this derivation. `SECONDARY VOLTAGE
/// SVLT` does not fit a two-column cell at any width this app produces, which is
/// why [_StatTile] has always given it `Flexible` + ellipsis. Demanding that it
/// fit would fold every layout to one column and still not achieve it.
const double kReadoutGridMinCellWidth = 110;

/// The four-up readout grid.
///
/// ## Two columns, or one
///
/// 🔴 The 2x2 shape is not unconditional (design 0084 §4.5). At a half-width
/// home tile on a 390 pt phone this grid gets 150 px, so a two-column cell
/// offers `(150 - 1) / 2 - 28` = **46.5 px** of content — less than the icon
/// and its gap — and the card measured **607 px tall**, taller than the same
/// card at FULL width (409), because every value wrapped. The height was the
/// symptom; the wrapped numbers were the defect.
///
/// So the column count is decided from the room actually available, not from
/// the container's identity: a cell whose content would fall below
/// [kReadoutGridMinCellWidth] folds the grid to a single column, where the same
/// 150 px yields 122 px of content — wider than a two-column cell gets even on
/// a 560 px-wide screen.
///
/// 🔑 This is a layout adaptation of ONE view, not a change of view. The user's
/// stored [ReadoutsView] (design 0054) is untouched: an app that quietly
/// swapped the card they chose for a different one because the window was
/// narrow would be fixing a rendering fault by editing a setting.
class ReadoutGrid extends StatelessWidget {
  const ReadoutGrid({super.key, required this.items});

  /// Tiles to render (expected length 4 for the 2x2 layout).
  final List<Readout> items;

  /// Whether [width] leaves a two-column cell enough room for its value.
  ///
  /// Public so the test can assert the breakpoint against the same arithmetic
  /// the widget uses, rather than against a copy of it.
  static bool fitsTwoColumns(double width) =>
      (width - 1) / 2 - kReadoutTilePadH * 2 >= kReadoutGridMinCellWidth;

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
        child: LayoutBuilder(
          builder: (context, constraints) {
            // `maxWidth` is finite here: this grid is always laid out inside a
            // card's stretched Column. Guarded anyway — an unbounded width must
            // read as "plenty of room", never as a fold to one column.
            final perRow = !constraints.maxWidth.isFinite ||
                    fitsTwoColumns(constraints.maxWidth)
                ? 2
                : 1;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var row = 0; row < items.length; row += perRow)
                  Padding(
                    padding: EdgeInsets.only(top: row == 0 ? 0 : 1),
                    // IntrinsicHeight bounds the row height so the stretched
                    // tiles (equal height) don't try to fill the ListView's
                    // unbounded height — that bug left the whole grid
                    // unrendered. A single-column row has nothing to equalise
                    // against, so it does not pay for the extra pass.
                    child: perRow == 1
                        ? _StatTile(item: items[row])
                        : IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: _StatTile(item: items[row])),
                                if (row + 1 < items.length) ...[
                                  const SizedBox(width: 1),
                                  Expanded(
                                      child: _StatTile(item: items[row + 1])),
                                ],
                              ],
                            ),
                          ),
                  ),
              ],
            );
          },
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
      padding: const EdgeInsets.symmetric(
          horizontal: kReadoutTilePadH, vertical: 13),
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
            ReadoutBadgePill(text: item.badge!, accent: item.badgeColor),
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
///
/// PUBLIC since design 0054 so the readouts card's `big` view can print it too.
/// It is not decoration: FB-47's whole point is that a bare `-0.43 A` reads as a
/// defect, and the word beside it is what makes the minus a direction. A view
/// that dropped the pill would be a view that changed the MEANING of a number,
/// which is the line S-R1 draws.
class ReadoutBadgePill extends StatelessWidget {
  const ReadoutBadgePill({super.key, required this.text, this.accent});

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
