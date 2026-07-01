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
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: context.colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in options)
            _SegButton(
              label: o.label,
              selected: o.value == selected,
              onTap: () => onChanged(o.value),
            ),
        ],
      ),
    );
  }
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
        color: selected ? AppColors.amber : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppColors.onAmber : context.colors.muted,
          ),
        ),
      ),
    );
  }
}

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
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: on ? AppColors.amber : context.colors.panel2,
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: on ? Colors.transparent : context.colors.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 13, color: on ? AppColors.onAmber : context.colors.text),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.5,
                fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                color: on ? AppColors.onAmber : context.colors.text,
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
                          subHighlight ? AppColors.amber : context.colors.muted,
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
            Icon(icon, size: 15, color: AppColors.cyan),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style: const TextStyle(fontSize: 13, color: AppColors.cyan)),
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
