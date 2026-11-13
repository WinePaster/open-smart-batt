/// OpenSmartBatt — the demo mode's three pieces of screen (design 0097 §3).
///
///   * [DemoEntryRow] — the fixed "no device? try a demo unit" row at the
///     bottom of the scan list (§3.1);
///   * [showDemoPicker] — the sheet that picks battery or capacitor;
///   * [DemoBannerFrame] — the banner across EVERY screen while a demo unit is
///     linked (§3.5), with the way out.
///
/// The banner sits above the navigator rather than on individual pages
/// because the demo reaches every page — dashboard, detail, history, settings
/// — and a page that forgot it would show simulated numbers unlabelled.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../demo/demo.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';

/// The localised name of the demo unit [id] names, or null for a real unit.
///
/// Every place that names a device runs its own lookup (alias, advertised
/// name, id), and none of them can know a demo unit; this is the one thing
/// they consult first.
String? demoDisplayName(AppLocalizations l10n, String? id) =>
    switch (DemoKind.fromId(id)) {
      DemoKind.battery => l10n.demoBatteryName,
      DemoKind.capacitor => l10n.demoCapacitorName,
      null => null,
    };

/// The scan list's demo entry.
class DemoEntryRow extends StatelessWidget {
  const DemoEntryRow({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accent = context.accent.accent;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('demo-entry'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(color: context.colors.line),
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Row(
              children: [
                Icon(Icons.play_circle_outline, color: accent, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.demoEntryTitle,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: context.colors.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.demoEntrySubtitle,
                        style:
                            TextStyle(fontSize: 11.5, color: context.colors.muted),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: context.colors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Ask which demo unit to connect. Null when dismissed.
Future<DemoKind?> showDemoPicker(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  return showModalBottomSheet<DemoKind>(
    context: context,
    showDragHandle: true,
    // design 0105 P5: scrollable. A sheet without `isScrollControlled` is
    // capped at 9/16 of the window, ≈ 219 dp on a phone on its side — less
    // than the handle, the title and two two-line rows. Where it fits (every
    // portrait phone) the scroll view is exactly as tall as the column, so
    // nothing moves.
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                l10n.demoPickTitle,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            for (final k in DemoKind.values)
              ListTile(
                key: ValueKey('demo-pick-${k.id}'),
                leading: Icon(
                  k == DemoKind.battery
                      ? Icons.battery_full
                      : Icons.electric_bolt_outlined,
                  color: sheet.accent.accent,
                ),
                title: Text(demoDisplayName(l10n, k.id)!),
                subtitle: Text(k == DemoKind.battery
                    ? l10n.demoBatteryDesc
                    : l10n.demoCapacitorDesc),
                onTap: () => Navigator.of(sheet).pop(k),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// Puts the demo banner above [child] while a demo unit is the target.
///
/// Keyed on [ConnectionController.connectedDeviceId], which also names a unit
/// that is still connecting — the banner is up from the first tap, so no
/// frame of simulated data is ever on screen unlabelled.
class DemoBannerFrame extends StatelessWidget {
  const DemoBannerFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    if (!isDemoDeviceId(conn.connectedDeviceId)) return child;
    final l10n = AppLocalizations.of(context);
    final mq = MediaQuery.of(context);
    return Column(
      children: [
        Material(
          key: const ValueKey('demo-banner'),
          color: AppSemantics.warn,
          child: Padding(
            padding: EdgeInsets.only(top: mq.padding.top),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
              child: Row(
                children: [
                  const Icon(Icons.science_outlined,
                      size: 18, color: Color(0xFF1A1200)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.demoBanner,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1200),
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('demo-end'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF1A1200),
                      textStyle: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                    onPressed: conn.disconnect,
                    child: Text(l10n.demoBannerEnd),
                  ),
                ],
              ),
            ),
          ),
        ),
        // The banner consumed the status-bar inset; the pages below must not
        // pad for it a second time.
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    );
  }
}
