/// OpenSmartBatt — shared industrial-theme form widgets (History + Settings).
///
/// Replicates the look of the project's own UI mockup (mockup/index.html):
/// amber segmented controls, amber filter chips, and the settings-style rows
/// (toggle / segmented / link / value). The panel card itself lives in
/// `industrial_card.dart` ([IndustrialCard] / [CardHeading]) and is re-exported
/// here so a single import covers a screen. Colors/metrics come from
/// [AppColors] / [AppTheme] only — no hard-coded hex.
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

export 'industrial_card.dart' show IndustrialCard, CardHeading;

/// Amber segmented control (mockup `.seg`). [options] pairs a value with its
/// label; the [selected] value renders amber/onAmber, the rest muted.
class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<({T value, String label})> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.panel2,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: context.colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      // Measured 2026-08-03: at 320 pt the history toolbar gives this control
      // 175.7 px while its three zh labels need 184.1 — and because the Row was
      // unconditionally `mainAxisSize.min` inside `Clip.antiAlias`, the third
      // segment was simply CUT OFF, silently, with no error in a release build.
      // That is what `feedback-attachments/our-app.md` `2026.07.30/009` shows.
      //
      // So: when the slot is bounded, every segment becomes flexible and the
      // labels ellipsise instead. A visible "近 7…" is a bad layout; a segment
      // that is not there at all is a missing feature.
      child: LayoutBuilder(
        builder: (context, c) {
          final buttons = <Widget>[
            for (final o in options)
              _SegButton(
                label: o.label,
                selected: o.value == selected,
                onTap: () => onChanged(o.value),
              ),
          ];
          // The settings rows lay this control out at its natural width, i.e.
          // with an UNBOUNDED main axis, where a flex child would throw.
          if (!c.hasBoundedWidth) {
            return Row(mainAxisSize: MainAxisSize.min, children: buttons);
          }
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (final b in buttons) Flexible(child: b)],
          );
        },
      ),
    );
  }
}

// Segment metrics. Shared by [_SegButton] and [segmentedControlNaturalWidth]
// so a padding tweak cannot desync the widget from the measurement that
// decides whether it still fits.
const double _kSegFontSize = 11;
const double _kSegPadH = 11;

/// Widest rendering of [text] across [weights], at this context's text scale.
///
/// Every label is measured in BOTH the selected and unselected weight and the
/// wider one wins. Measuring the actual current weight would make the layout
/// re-flow each time the user changes the selection — and "bold is wider" does
/// not hold for every font: with the CJK fallback the w500 label measures
/// 0.75 px WIDER than the w700 one.
double _widestAt(
  BuildContext context,
  String text, {
  required List<FontWeight> weights,
  required double fontSize,
  double? letterSpacing,
}) {
  final scaler = MediaQuery.textScalerOf(context);
  // Start from the ambient style, exactly as [Text] does. Painting a bare
  // TextStyle instead measures a DIFFERENT font from the one on screen — it
  // came out 0.75 px per label narrow, which is how the toolbar would decide
  // it still fits when it does not.
  final ambient = DefaultTextStyle.of(context).style;
  var widest = 0.0;
  for (final weight in weights) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: ambient.merge(TextStyle(
          fontSize: fontSize,
          fontWeight: weight,
          letterSpacing: letterSpacing,
        )),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    if (painter.width > widest) widest = painter.width;
  }
  return widest;
}

/// Width a [SegmentedControl] needs before it starts ellipsising, at this
/// context's text scale. An UPPER bound — see [_widestAt].
double segmentedControlNaturalWidth(BuildContext context, List<String> labels) {
  var width = 2.0; // the 1 px border on either side
  for (final label in labels) {
    width += _widestAt(
          context,
          label,
          weights: const [FontWeight.w500, FontWeight.w700],
          fontSize: _kSegFontSize,
        ) +
        _kSegPadH * 2;
  }
  return width;
}

class _SegButton extends StatelessWidget {
  const _SegButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? context.accent.accent : Colors.transparent,
        padding: const EdgeInsets.symmetric(
            horizontal: _kSegPadH, vertical: 7),
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: _kSegFontSize,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? context.accent.onAccent : context.colors.muted,
          ),
        ),
      ),
    );
  }
}

// Chip metrics, shared with [filterChipNaturalWidth] for the same reason as
// the segment metrics above.
const double _kChipFontSize = 11;
const double _kChipPadH = 12;
const double _kChipIconSize = 13;
const double _kChipIconGap = 6;

/// Width a [FilterChip2] occupies at this context's text scale. An UPPER
/// bound: both the on and off weights are measured — see [_widestAt].
///
/// The icon is NOT scaled: [Icon] ignores the text scaler unless
/// `applyTextScaling` is set, and this app never sets it.
double filterChipNaturalWidth(
  BuildContext context,
  String label, {
  bool hasIcon = false,
}) =>
    _widestAt(
      context,
      label,
      weights: const [FontWeight.w400, FontWeight.w700],
      fontSize: _kChipFontSize,
      letterSpacing: 0.5,
    ) +
    _kChipPadH * 2 +
    (hasIcon ? _kChipIconSize + _kChipIconGap : 0);

/// Small amber-fill "chip" pill (mockup `.chip` / `.chip.on`).
class FilterChip2 extends StatelessWidget {
  const FilterChip2({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.filled = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  /// Always-amber action variant (e.g. the "匯出 CSV" chip in the mockup).
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final on = selected || filled;
    return InkWell(
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: _kChipPadH, vertical: 7),
        decoration: BoxDecoration(
          color: on ? context.accent.accent : context.colors.panel2,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border:
              Border.all(color: on ? Colors.transparent : context.colors.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: _kChipIconSize,
                  color: on ? context.accent.onAccent : context.colors.text),
              const SizedBox(width: _kChipIconGap),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: _kChipFontSize,
                letterSpacing: 0.5,
                fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                color: on ? context.accent.onAccent : context.colors.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A settings list row (mockup `.srow`): a label + optional sub-caption on the
/// left and an arbitrary [trailing] control on the right, with a bottom hairline
/// unless [last].
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    this.sub,
    this.subHighlight = false,
    required this.trailing,
    this.last = false,
  });

  final String label;
  final String? sub;

  /// Render the (tail of the) sub-caption in amber — used for "DEFAULT OFF".
  final bool subHighlight;
  final Widget trailing;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 2),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: context.colors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 13, color: context.colors.text)),
                if (sub != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    sub!,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.5,
                      color:
                          subHighlight ? context.accent.accent : context.colors.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }
}

/// A tappable settings "link" row (mockup `.srow .sl.link`): cyan icon+label on
/// the left, a muted chevron on the right.
class SettingsLinkRow extends StatelessWidget {
  const SettingsLinkRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.last = false,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool last;

  /// Optional trailing widget replacing the default chevron (e.g. a value).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 2),
        decoration: BoxDecoration(
          border: last
              ? null
              : Border(bottom: BorderSide(color: context.colors.line)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 15, color: context.accent.accentSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 13, color: context.accent.accentSecondary)),
            ),
            trailing ??
                Icon(Icons.chevron_right,
                    size: 16, color: context.colors.muted),
          ],
        ),
      ),
    );
  }
}
