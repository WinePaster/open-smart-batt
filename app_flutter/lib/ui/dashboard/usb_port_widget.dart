/// OpenSmartBatt — USB dual-port status (power-bank "Command 7" frame).
///
/// ⚠️ SUPERSEDED — this two-port card is being replaced by the single
/// energy-path row (design 0035). Phase 0 has decoded the register it was
/// waiting for (0x4B byte b7 → [TelemetrySample.usbPort] / .isPdIn / .isPdOut /
/// .isOutputActive / .isRailOff), but this widget is NOT yet rewired to it and
/// still renders the neutral / UNKNOWN state it always has — Phase 1 deletes
/// this file and adds the energy-path row. Kept building only so Phase 0 can
/// land alone without touching any on-screen pixels.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';

/// Type-A + Type-C port tiles, rendered neutral until the frame is decoded.
class UsbPortWidget extends StatelessWidget {
  const UsbPortWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Subscribe so this card still repaints with the rest of the dashboard,
    // even though Phase 0 leaves it rendering a constant neutral/UNKNOWN state
    // (the decoded port fields exist now but this superseded widget does not
    // read them — design 0035 Phase 1 replaces it).
    context.watch<TelemetryController>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _PortTile(
                icon: Icons.usb,
                name: l10n.usbPortTypeA,
                // Phase 0 does not rewire this widget — it keeps its neutral
                // UNKNOWN state (design 0035 Phase 1 replaces it). Explicit null.
                isOutput: null,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _PortTile(
                icon: Icons.usb_rounded,
                name: l10n.usbPortTypeC,
                // Phase 0 does not rewire this widget — it keeps its neutral
                // UNKNOWN state (design 0035 Phase 1 replaces it). Explicit null.
                isOutput: null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 11),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 14, color: context.colors.muted),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                l10n.usbPortPendingNote,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.6,
                  color: context.colors.muted,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// One port tile. Shows a neutral UNKNOWN state while [isOutput] is null (the
/// pending-decode case); once decoded it will read supplying / idle.
class _PortTile extends StatelessWidget {
  const _PortTile({
    required this.icon,
    required this.name,
    required this.isOutput,
  });

  final IconData icon;
  final String name;

  /// Whether the port is supplying power, or null when not yet decoded.
  final bool? isOutput;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    // Neutral until decoded — never fabricate a supply/charge state.
    final String stateText;
    final Color accent;
    if (isOutput == null) {
      stateText = l10n.usbPortStateUnknown;
      accent = colors.muted;
    } else if (isOutput!) {
      stateText = l10n.usbPortStateSupplying;
      accent = AppColors.good;
    } else {
      stateText = l10n.usbPortStateIdle;
      accent = colors.muted;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: colors.panel2,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 6),
              Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: colors.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            stateText,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.5,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}
