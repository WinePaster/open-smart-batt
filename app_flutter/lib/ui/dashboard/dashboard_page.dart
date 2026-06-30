/// Open-RCE-Batt — dashboard screen (mockup page `#page-dash`).
///
/// Live view: PVLT instrument gauge, the four-up readout grid, the DVOL per-cell
/// bars and the protection-status / mode-controls card. When no device is
/// connected it swaps to [DisconnectedState] (quick-select + scan).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../devices/device_list_sheet.dart';
import '../widgets/industrial_card.dart';
import 'disconnected_state.dart';
import 'dvol_bars.dart';
import 'pvlt_gauge.dart';
import 'readout_grid.dart';
import 'status_controls.dart';

/// Dashboard body (intended to sit inside the app shell's [Scaffold] body).
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, this.onScanRequested});

  /// Forwarded to [DisconnectedState]'s scan button (open device-list sheet).
  final VoidCallback? onScanRequested;

  @override
  Widget build(BuildContext context) {
    final online = context.select<ConnectionController, bool>((c) => c.isOnline);
    if (!online) {
      return DisconnectedState(
        onScanRequested:
            onScanRequested ?? () => showDeviceListSheet(context),
      );
    }
    return const _LiveDashboard();
  }
}

class _LiveDashboard extends StatelessWidget {
  const _LiveDashboard();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    final caps = tele.capabilities;

    final typeLabel = _deviceTypeLabel(
      l10n,
      context.select<ConnectionController, String>((c) => c.connectedDeviceName),
    );

    // Resolve the gauge's localized centre-stack labels in the host (the
    // gauge's painter/widget tree below has no easy place for l10n lookups —
    // see _deviceTypeLabel). Pass the finished strings into [PvltGauge].
    final soh = tele.sohBucket;
    final sohText = soh == null
        ? l10n.gaugeSohUnknown
        : l10n.gaugeSohValue(soh, _sohLabel(l10n, soh));

    // Cap content width + centre it so cards don't stretch on tablets/wide.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
      padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
      children: [
        // ---- detected device type -----------------------------------------
        if (typeLabel != null)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.memory, size: 14, color: AppColors.amber),
                const SizedBox(width: 6),
                Text(l10n.dashboardDeviceTypeDetected(typeLabel),
                    style: AppTextStyles.label(context)),
              ],
            ),
          ),

        // ---- PVLT gauge ----------------------------------------------------
        IndustrialCard(
          child: LayoutBuilder(
            builder: (context, c) {
              // Size the dial from available width (clamped near the mockup's
              // 206 so the painter's absolute stroke widths still look right).
              final s = (c.maxWidth * 0.74).clamp(180.0, 240.0);
              return Center(
                child: PvltGauge(
                  pvlt: tele.pvlt,
                  fraction: tele.gaugeFraction,
                  pvltLabel: l10n.gaugePvltLabel,
                  sohText: sohText,
                  size: s,
                ),
              );
            },
          ),
        ),

        // ---- readout grid --------------------------------------------------
        IndustrialCard(
          heading: l10n.dashboardReadoutsHeading,
          headingIcon: Icons.speed,
          child: ReadoutGrid(
            items: [
              // Core readouts (a capacitor reports these): temperature + SVLT.
              Readout(
                icon: Icons.thermostat,
                label: l10n.dashboardReadoutTemperatureLabel,
                value: _fmtInt(tele.temperatureDisplay),
                unit: tele.temperatureUnitLabel,
              ),
              Readout(
                icon: Icons.bolt,
                label: l10n.dashboardReadoutSvltLabel,
                value: _fmt1(tele.svlt),
                unit: 'V',
              ),
              // Battery-only extras: shown only once the device actually
              // reports them (a capacitor at idle never sends these).
              if (tele.current != null)
                Readout(
                  icon: Icons.electric_bolt,
                  label: l10n.dashboardReadoutCurrentLabel,
                  value: _fmt1(tele.current),
                  unit: 'A',
                ),
              if (tele.sohBucket != null)
                Readout(
                  icon: Icons.monitor_heart_outlined,
                  label: l10n.dashboardReadoutSohLabel,
                  value: tele.sohBucket!.toString(),
                  unit: '%',
                ),
            ],
          ),
        ),

        // ---- DVOL per-cell bars (gated on capability) ----------------------
        if (caps.supportsDvol)
          IndustrialCard(
            heading: l10n.dashboardDvolHeading,
            headingIcon: Icons.battery_std,
            child: DvolBars(cells: tele.dvol),
          ),

        // ---- protection status + controls ----------------------------------
        IndustrialCard(
          heading: l10n.dashboardProtectionHeading,
          headingIcon: Icons.shield_outlined,
          child: const StatusControls(),
        ),
      ],
        ),
      ),
    );
  }

  /// Human device-type from the advertised name (RCE-SCAP_II → Supercapacitor).
  /// Returns null when the name is unknown (hide the chip).
  static String? _deviceTypeLabel(AppLocalizations l10n, String name) {
    final raw = name.trim();
    if (raw.isEmpty) return null;
    final n = raw.toUpperCase();
    final type = n.contains('SCAP')
        ? l10n.dashboardDeviceTypeSupercapacitor
        : n.contains('BATT')
            ? l10n.dashboardDeviceTypeSmartBattery
            : (n.contains('POWER') || n.contains('PB'))
                ? l10n.dashboardDeviceTypePowerBank
                : l10n.dashboardDeviceTypeRceDevice;
    return l10n.dashboardDeviceTypeWithName(type, raw);
  }

  /// SOH bucket → localized health label (Good / Fair / Degraded).
  static String _sohLabel(AppLocalizations l10n, int soh) {
    if (soh >= 80) return l10n.gaugeSohLabelGood;
    if (soh >= 50) return l10n.gaugeSohLabelFair;
    return l10n.gaugeSohLabelDegraded;
  }

  static String _fmtInt(double? v) => v == null ? '--' : v.round().toString();
  static String _fmt1(double? v) => v == null ? '--' : v.toStringAsFixed(1);
}
