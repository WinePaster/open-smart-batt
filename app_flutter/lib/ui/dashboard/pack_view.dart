/// OpenSmartBatt — pack dashboard shell + per-class bodies (design 0004 §3.4).
///
/// [PackView] is the pack shell the dashboard router builds for every
/// non-power-bank unit (design 0004 §3.1: routing is by device-type; the router
/// does `isPowerBank ? PowerBankView : PackView`). Inside the shell we pick the
/// body by the COSMETIC pack label (routing option 3): a settled super-capacitor
/// → [CapacitorView], a smart battery → [BatteryView], and an as-yet-unclassified
/// pack → the bounded [PackControls] fallback. This is GATING (show/hide), NOT
/// routing — the same layout ([PackScaffold]) is used either way, so a mid-session
/// label flip never jumps the layout.
///
/// The shared chrome is [PackScaffold]: PVLT gauge + SVLT + temperature, plus a
/// DVOL card gated DATA-DRIVEN on `!= null`.
///
/// The CURRENT readout is gated by CLASS, not by data (design 0007). The old
/// data-driven gate rested on "a capacitor never streams current", which the
/// 2026-07-27 capture falsified: an owner-confirmed capacitor sends 0x2E every
/// second with a constant payload decoding to 0.0 A. Showing a permanent 0.0 A
/// on a unit that cannot measure current is worse than showing nothing.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial_card.dart';
import '../widgets/pending_note.dart';
import 'pvlt_gauge.dart';
import 'readout_grid.dart';
import 'dvol_bars.dart';
import 'status_controls.dart';

/// The pack shell: picks the per-class body by the cosmetic label (design 0004
/// §3.4, routing option 3). GATING, never routing — every branch renders the
/// same [PackScaffold] layout.
class PackView extends StatelessWidget {
  const PackView({super.key});

  @override
  Widget build(BuildContext context) {
    final label =
        context.select<ConnectionController, ProductClass>((c) => c.packLabel);
    switch (label) {
      case ProductClass.supercapacitor:
        return const CapacitorView();
      case ProductClass.smartBattery:
        return const BatteryView();
      case ProductClass.powerBank:
      case ProductClass.unknown:
        // Still identifying (or a stray power-bank label a pack can never truly
        // be): the bounded fallback — union of controls except anti-theft.
        return const PackScaffold(controls: PackControls());
    }
  }
}

/// Super-capacitor body: the shared pack shell with [CapacitorControls].
class CapacitorView extends StatelessWidget {
  const CapacitorView({super.key});

  @override
  Widget build(BuildContext context) =>
      const PackScaffold(controls: CapacitorControls());
}

/// Smart-battery body: the shared pack shell with [BatteryControls].
class BatteryView extends StatelessWidget {
  const BatteryView({super.key});

  @override
  Widget build(BuildContext context) =>
      const PackScaffold(controls: BatteryControls());
}

/// Shared pack chrome (design 0004 §3.4): cosmetic label chip + serial + PVLT
/// gauge + data-driven readouts + DVOL card, closing with the protection card
/// whose body is the injected class-specific [controls].
class PackScaffold extends StatelessWidget {
  const PackScaffold({super.key, required this.controls});

  /// The class-specific protection body (CapacitorControls / BatteryControls /
  /// PackControls).
  final Widget controls;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    final packLabel =
        context.select<ConnectionController, ProductClass>((c) => c.packLabel);
    // Product serial: the full serial (dealer 0x27 + product 0x26, §10.2) once the
    // connect burst arrives; else the tail-only serial; else the BLE device id
    // (MAC on Android, opaque UUID on iOS) as a placeholder.
    final serial = tele.fullSerial ??
        tele.serial ??
        context.select<ConnectionController, String?>(
            (c) => c.connectedDeviceId);

    // Centre SOH sub-line for the gauge (resolved here where l10n is available).
    //
    // Class-gated the same way the current readout below is (design 0007): a
    // super-capacitor never sends 0x96, so this line could only ever render as
    // "SOH --". A permanent placeholder reads as "we failed to fetch it", not
    // as "this device has no such thing" — so on a capacitor it is omitted.
    final soh = tele.sohBucket;
    final showSoh = packLabel != ProductClass.supercapacitor;
    final sohText = !showSoh
        ? null
        : soh == null
            ? l10n.gaugeSohUnknown
            : l10n.gaugeSohValue(soh, _sohLabel(l10n, soh));

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
          children: [
            // ---- cosmetic pack-class chip (TEXT ONLY) --------------------
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: _PackLabelChip(label: packLabel),
            ),

            // ---- product serial / device id (shown once connected) -------
            if (serial != null && serial.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.qr_code_2, size: 13, color: context.colors.muted),
                    const SizedBox(width: 6),
                    Text('${l10n.dashboardSerialLabel}: ',
                        style: TextStyle(
                            fontSize: 11, color: context.colors.muted)),
                    Flexible(
                      child: Text(
                        serial,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.mono(context).copyWith(
                            fontSize: 11, color: context.colors.text),
                      ),
                    ),
                  ],
                ),
              ),

            // ---- PVLT voltage gauge (ALWAYS) -----------------------------
            IndustrialCard(
              child: LayoutBuilder(
                builder: (context, c) {
                  final s = (c.maxWidth * 0.74).clamp(180.0, 240.0);
                  return Center(
                    child: PvltGauge.voltage(
                      volts: tele.pvlt,
                      caption: l10n.gaugePvltLabel,
                      subText: sohText,
                      size: s,
                    ),
                  );
                },
              ),
            ),

            // ---- readouts: TEMP + SVLT always; current only if present ---
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
                    icon: Icons.bolt,
                    label: l10n.dashboardReadoutSvltLabel,
                    value: _fmt1(tele.svlt),
                    unit: 'V',
                  ),
                  // Class-gated (design 0007): a capacitor DOES stream 0x2E, but
                  // it is a constant 0.0 A — it cannot measure current, so the
                  // readout is hidden rather than shown as a real zero.
                  if (packLabel != ProductClass.supercapacitor &&
                      tele.current != null)
                    Readout(
                      icon: Icons.electric_bolt,
                      label: l10n.dashboardReadoutCurrentLabel,
                      value: _fmt1(tele.current),
                      unit: 'A',
                    ),
                  if (showSoh && tele.sohBucket != null)
                    Readout(
                      icon: Icons.monitor_heart_outlined,
                      label: l10n.dashboardReadoutSohLabel,
                      value: tele.sohBucket!.toString(),
                      unit: '%',
                    ),
                ],
              ),
            ),

            // ---- DVOL per-cell bars: ONLY when the unit streams them ------
            if (tele.dvol != null)
              IndustrialCard(
                heading: l10n.dashboardDvolHeading,
                headingIcon: Icons.battery_std,
                child: DvolBars(cells: tele.dvol),
              )
            // DVOL frames arriving but VADJ (scaling) not yet known: show a
            // pending note rather than a bogus voltage. See PROTOCOL.md §8.2.
            else if (tele.dvolPending)
              IndustrialCard(
                heading: l10n.dashboardDvolHeading,
                headingIcon: Icons.battery_std,
                child: PendingNote(text: l10n.dashboardDvolPendingNote),
              ),

            // ---- protection status + class-specific controls -------------
            IndustrialCard(
              heading: l10n.dashboardProtectionHeading,
              headingIcon: Icons.shield_outlined,
              child: controls,
            ),
          ],
        ),
      ),
    );
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

/// Product-class chip. The picker appears ONLY when the unit is unclassified
/// (design 0007): when the device-type byte is recognised the class comes off
/// the wire and a picker that silently could not change it would be a lie.
class _PackLabelChip extends StatelessWidget {
  const _PackLabelChip({required this.label});

  final ProductClass label;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final conn = context.read<ConnectionController>();
    final text = _labelText(l10n, label);
    final pickable = label == ProductClass.unknown;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.memory, size: 14, color: AppColors.amber),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            l10n.dashboardDeviceTypeDetected(text),
            style: AppTextStyles.label(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (pickable) ...[
          const SizedBox(width: 4),
          PopupMenuButton<ProductClass?>(
            tooltip: l10n.packLabelChoose,
            padding: EdgeInsets.zero,
            icon: Icon(Icons.expand_more, size: 16, color: context.colors.muted),
            onSelected: conn.setPackLabelOverride,
            itemBuilder: (_) => [
              PopupMenuItem<ProductClass?>(
                value: ProductClass.supercapacitor,
                child: Text(l10n.dashboardDeviceTypeSupercapacitor),
              ),
              PopupMenuItem<ProductClass?>(
                value: ProductClass.smartBattery,
                child: Text(l10n.dashboardDeviceTypeSmartBattery),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static String _labelText(AppLocalizations l10n, ProductClass label) {
    switch (label) {
      case ProductClass.supercapacitor:
        return l10n.dashboardDeviceTypeSupercapacitor;
      case ProductClass.smartBattery:
        return l10n.dashboardDeviceTypeSmartBattery;
      case ProductClass.powerBank:
      case ProductClass.unknown:
        // No guessing left (design 0007): say it is unclassified and invite the
        // user to pick, instead of implying detection is still in progress.
        return l10n.packLabelUnclassified;
    }
  }
}
