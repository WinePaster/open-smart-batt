/// OpenSmartBatt — power-bank dashboard view (RSPB, device-type 0x22).
///
/// Design 0001 §3.4: a power bank routes here DETERMINISTICALLY (device-type
/// 0x22). Its instrument is a percent-mode SOC ring fed DIRECTLY by the
/// device-reported state-of-charge (selector 0x96 b6 — there is NO voltage→SOC
/// curve, PROTOCOL.md §12.3), alongside temperature + single-cell voltage
/// readouts and the (scaffolded) USB dual-port status. A power bank has NO DVOL
/// per-cell card and NO cut-off / anti-theft controls — those live on the pack
/// page, which a power bank never navigates to.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../state/state.dart';
import '../widgets/industrial_card.dart';
import 'pvlt_gauge.dart';
import 'readout_grid.dart';
import 'usb_port_widget.dart';

/// The power-bank dashboard body.
class PowerBankView extends StatelessWidget {
  const PowerBankView({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();

    final soc = tele.socPercent;
    // Sub-line under the SOC value: the single-cell voltage (PVLT is the cell
    // voltage on a power bank, PROTOCOL.md §12.2) or a placeholder.
    final subText = tele.pvlt == null
        ? l10n.powerBankSocSubUnknown
        : l10n.powerBankCellSub(tele.pvlt!.toStringAsFixed(2));

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
          children: [
            // ---- device-type chip (deterministic) -----------------------
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.battery_charging_full,
                      size: 14, color: Color(0xFFF0A030)),
                  const SizedBox(width: 6),
                  Text(
                    l10n.dashboardDeviceTypeDetected(
                        l10n.dashboardDeviceTypePowerBank),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),

            // ---- SOC ring (percent mode, direct 0x96 b6) ----------------
            IndustrialCard(
              child: LayoutBuilder(
                builder: (context, c) {
                  final s = (c.maxWidth * 0.74).clamp(180.0, 240.0);
                  return Center(
                    child: PvltGauge.percent(
                      percent: soc,
                      caption: l10n.powerBankSocCaption,
                      subText: subText,
                      size: s,
                    ),
                  );
                },
              ),
            ),

            // ---- readouts: temperature + cell + output voltage ----------
            IndustrialCard(
              heading: l10n.dashboardReadoutsHeading,
              headingIcon: Icons.speed,
              child: ReadoutGrid(
                items: [
                  Readout(
                    icon: Icons.thermostat,
                    label: l10n.dashboardReadoutTemperatureLabel,
                    value: _fmtInt(tele.temperatureDisplay),
                    unit: tele.temperatureUnitLabel,
                  ),
                  Readout(
                    icon: Icons.battery_5_bar,
                    label: l10n.powerBankCellVoltageLabel,
                    value: _fmt2(tele.pvlt),
                    unit: 'V',
                  ),
                  Readout(
                    icon: Icons.usb,
                    label: l10n.powerBankOutputVoltageLabel,
                    value: _fmt1(tele.svlt),
                    unit: 'V',
                  ),
                  Readout(
                    icon: Icons.battery_charging_full,
                    label: l10n.powerBankSocReadoutLabel,
                    value: soc == null ? '--' : soc.toString(),
                    unit: '%',
                  ),
                  // Magnitude, no direction — the register's charge/discharge
                  // attribution is unresolved (see Selectors.discharge), so the
                  // label deliberately says "Current", not "Output"/"Charge".
                  if (tele.current != null)
                    Readout(
                      icon: Icons.electric_bolt,
                      label: l10n.powerBankCurrentLabel,
                      value: tele.current!.toStringAsFixed(2),
                      unit: 'A',
                    ),
                  if (tele.sample.designCapacityMah != null)
                    Readout(
                      icon: Icons.battery_std,
                      label: l10n.powerBankDesignCapacityLabel,
                      value: tele.sample.designCapacityMah!.toString(),
                      unit: 'mAh',
                    ),
                ],
              ),
            ),

            // ---- USB dual-port status (scaffold; Phase 4) ----------------
            IndustrialCard(
              heading: l10n.usbPortsHeading,
              headingIcon: Icons.usb,
              child: const UsbPortWidget(),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtInt(double? v) => v == null ? '--' : v.round().toString();
  static String _fmt1(double? v) => v == null ? '--' : v.toStringAsFixed(1);
  static String _fmt2(double? v) => v == null ? '--' : v.toStringAsFixed(2);
}
