/// Open-RCE-Batt — dashboard screen (mockup page `#page-dash`).
///
/// Live view: PVLT instrument gauge, the four-up readout grid, the DVOL per-cell
/// bars and the protection-status / mode-controls card. When no device is
/// connected it swaps to [DisconnectedState] (quick-select + scan).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    final tele = context.watch<TelemetryController>();
    final caps = tele.capabilities;

    final typeLabel = _deviceTypeLabel(
      context.select<ConnectionController, String>((c) => c.connectedDeviceName),
    );

    return ListView(
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
                Text('偵測到：$typeLabel',
                    style: AppTextStyles.label(context)),
              ],
            ),
          ),

        // ---- PVLT gauge ----------------------------------------------------
        IndustrialCard(
          child: Center(
            child: PvltGauge(
              pvlt: tele.pvlt,
              fraction: tele.gaugeFraction,
              sohBucket: tele.sohBucket,
            ),
          ),
        ),

        // ---- readout grid --------------------------------------------------
        IndustrialCard(
          heading: '即時讀數',
          headingIcon: Icons.speed,
          child: ReadoutGrid(
            items: [
              // Core readouts (a capacitor reports these): temperature + SVLT.
              Readout(
                icon: Icons.thermostat,
                label: '溫度 TEMP',
                value: _fmtInt(tele.temperatureDisplay),
                unit: tele.temperatureUnitLabel,
              ),
              Readout(
                icon: Icons.bolt,
                label: '次電壓 SVLT',
                value: _fmt1(tele.svlt),
                unit: 'V',
              ),
              // Battery-only extras: shown only once the device actually
              // reports them (a capacitor at idle never sends these).
              if (tele.current != null)
                Readout(
                  icon: Icons.electric_bolt,
                  label: '主電流',
                  value: _fmt1(tele.current),
                  unit: 'A',
                ),
              if (tele.sohBucket != null)
                Readout(
                  icon: Icons.monitor_heart_outlined,
                  label: '健康 SOH',
                  value: tele.sohBucket!.toString(),
                  unit: '%',
                ),
            ],
          ),
        ),

        // ---- DVOL per-cell bars (gated on capability) ----------------------
        if (caps.supportsDvol)
          IndustrialCard(
            heading: '分串電壓 DVOL',
            headingIcon: Icons.battery_std,
            child: DvolBars(cells: tele.dvol),
          ),

        // ---- protection status + controls ----------------------------------
        const IndustrialCard(
          heading: '防護狀態 / 模式',
          headingIcon: Icons.shield_outlined,
          child: StatusControls(),
        ),
      ],
    );
  }

  /// Human device-type from the advertised name (RCE-SCAP_II → 超級電容).
  /// Returns null when the name is unknown (hide the chip).
  static String? _deviceTypeLabel(String name) {
    final raw = name.trim();
    if (raw.isEmpty) return null;
    final n = raw.toUpperCase();
    final type = n.contains('SCAP')
        ? '超級電容'
        : n.contains('BATT')
            ? '智慧電池'
            : (n.contains('POWER') || n.contains('PB'))
                ? '行動電源'
                : 'RCE 裝置';
    return '$type（$raw）';
  }

  static String _fmtInt(double? v) => v == null ? '--' : v.round().toString();
  static String _fmt1(double? v) => v == null ? '--' : v.toStringAsFixed(1);
}
