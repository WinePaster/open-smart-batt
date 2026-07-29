/// OpenSmartBatt — USB dual-port status (power-bank "Command 7" frame).
///
/// SCAFFOLD ONLY (design 0001 §5 Phase 4). Renders the Type-A and Type-C port
/// tiles from the port-status fields on [TelemetrySample]
/// ([TelemetrySample.isTypeAOutput], [TelemetrySample.isTypeCOutput],
/// [TelemetrySample.inputFastChargeType], [TelemetrySample.outputFastChargeType]).
///
/// TODO(design 0001 §7 Q1 / PROTOCOL.md §9.1): those fields are NOT yet
/// populated — the exact "Command 7" SELECTOR value and the bit offsets of the
/// supply bits + input/output fast-charge value fields are UNKNOWN pending a
/// live `!#` capture on a power bank. The value→label tables (PD / QC / FCP / …)
/// are certain, but the bit positions are not, so the decoder deliberately
/// leaves these fields NULL (see TelemetryDecoder.applyPortStatus). Until the
/// wire layout is pinned down we render a clear neutral / UNKNOWN state and do
/// NOT fabricate supply or protocol readings.
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
    final tele = context.watch<TelemetryController>();
    final sample = tele.sample;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _PortTile(
                icon: Icons.usb,
                name: l10n.usbPortTypeA,
                // TODO(design 0001 §7 Q1): supply bit not yet decoded → null.
                isOutput: sample.isTypeAOutput,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _PortTile(
                icon: Icons.usb_rounded,
                name: l10n.usbPortTypeC,
                // TODO(design 0001 §7 Q1): supply bit not yet decoded → null.
                isOutput: sample.isTypeCOutput,
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
