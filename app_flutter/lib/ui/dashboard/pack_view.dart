/// OpenSmartBatt — pack dashboard shell + per-class bodies.
///
/// [PackView] is the pack shell the dashboard router builds for every unit that
/// the device-type byte has identified as NOT a power bank — routing is decided
/// by that byte alone, never by the cosmetic label. Inside the shell we pick the
/// body by the COSMETIC pack label: a settled super-capacitor → [CapacitorView],
/// a smart battery → [BatteryView], and an as-yet-unclassified pack → the
/// bounded [PackControls] fallback.
///
/// That split is deliberate and is the invariant to preserve here: the label may
/// decide GATING (which buttons and readouts appear) but must never decide
/// ROUTING (which layout is drawn). Every branch below renders the same
/// [PackScaffold], so a label that resolves or flips mid-session swaps controls
/// without the page jumping to a different layout under the user's finger.
///
/// The shared chrome is [PackScaffold]: PVLT gauge + SVLT + temperature, plus a
/// DVOL card gated DATA-DRIVEN on `!= null`.
///
/// The CURRENT readout is the exception: it is gated by CLASS, not by data. The
/// old data-driven gate rested on "a capacitor never streams current", and that
/// premise is false. An owner-confirmed capacitor sends 0x2E every second with a
/// constant payload that decodes to 0.0 A. Showing a permanent 0.0 A on a unit
/// that cannot measure current is worse than showing nothing.
///
/// Every one of those CLASS conditions now comes from `display_modules.dart`
/// (design 0034 Phase 0) — six `packLabel` comparisons used to be spread down
/// this file and had to be read together before anyone could state what a
/// capacitor shows. DATA conditions stayed here, where the telemetry is: the
/// registry declares that a readout is class-gated, the `!= null` beside it
/// still decides whether there is anything to draw.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial_card.dart';
import '../widgets/pending_note.dart';
import 'display_modules.dart';
import 'pvlt_gauge.dart';
import 'live_trend_chart.dart';
import 'readout_grid.dart';
import 'readouts_card.dart';
import 'dvol_bars.dart';
import 'status_controls.dart';

/// The pack shell: picks the per-class body by the cosmetic label. GATING,
/// never routing — every branch renders the same [PackScaffold] layout, so this
/// switch only ever changes which controls sit inside it.
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

/// Shared pack chrome: cosmetic label chip + serial + PVLT gauge + data-driven
/// readouts + DVOL card, closing with the protection card whose body is the
/// injected class-specific [controls]. Kept as one widget so the capacitor and
/// battery bodies cannot drift apart in the ~70 % of the page they share, and
/// so switching between them changes nothing but the injected controls.
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
    // Everything this shell does differently per class comes from here.
    // NOTE the lookup is `forPackShell`, not `forClass`: a stray `powerBank`
    // label reaches this shell (see [PackView] above) and has always drawn the
    // unclassified set here — see the doc on that method.
    final modules = DisplayModules.forPackShell(packLabel);
    // Product serial: the full serial (dealer 0x27 + product 0x26, §10.2) once
    // the connect burst arrives; else the tail-only serial; else NOTHING — the
    // row hides itself below.
    //
    // 🔴 There used to be a third fallback to the BLE device id. Two things were
    // wrong with it. It is not a serial, so the label "產品序號" was false —
    // a field screenshot shows a dashboard reading
    // "產品序號: <8-4-4-4-12>", which is an iOS NSUUID. And on ANDROID
    // that id is the MAC address: `log_entry.dart` says so in as many words
    // ("NEVER put this in an exported filename — on Android it is the MAC
    // address"), which is why FB-33 keeps it out of export filenames. Printing
    // it on the main screen under a serial-number label undoes that, in a
    // project whose whole feedback loop runs on users sending screenshots.
    // An empty row is strictly better than a confidently wrong one.
    final serial = tele.fullSerial ?? tele.serial;

    // Centre SOH sub-line for the gauge.
    //
    // Class-gated the same way the current readout below is: a
    // super-capacitor never sends 0x96, so this line could only ever render as
    // "SOH --". A permanent placeholder reads as "we failed to fetch it", not
    // as "this device has no such thing" — so on a capacitor it is omitted.
    // Both the gate AND the wording are the registry's (design 0034 §12.3 #2:
    // the per-class difference here is content, not just presence).
    final sohText = modules.sohGaugeLine?.call(l10n, tele.sohBucket);

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
                  final s = AppTheme.gaugeDiameter(context, c.maxWidth);
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
            ReadoutsCard(
              buffer: tele.trend,
              // Same class gate as the current readout below: a capacitor
              // streams 0x2E as a constant 0.0 A, so a current track would draw
              // a flat line at zero and read as "measured 0 A" — worse than
              // leaving it out. Voltage and temperature do move on a capacitor,
              // so the chart is still offered, just without that track.
              tracks: [
                if (modules.hasTrack(TrendField.current))
                  TrendTrack(
                    field: TrendField.current,
                    label: l10n.dashboardTrackCurrent,
                    unit: 'A',
                    color: AppColors.cyan,
                    // Signed, and the axis must cross zero. 0x2E carries a sign
                    // whose DIRECTION is still unverified, so the axis states
                    // the number and never labels it charge/discharge — but
                    // hiding the sign would erase the reversal that makes a
                    // cranking load recognisable.
                    spanZero: true,
                    minSpan: 10,
                    height: 92,
                  ),
                if (modules.hasTrack(TrendField.pvlt))
                  TrendTrack(
                    field: TrendField.pvlt,
                    label: l10n.dashboardTrackPvlt,
                    unit: 'V',
                    color: AppColors.amber,
                    decimals: 2,
                    minSpan: 0.5,
                  ),
                // A capacitor has one track MORE than a battery, not fewer.
                if (modules.hasTrack(TrendField.svlt))
                  TrendTrack(
                    field: TrendField.svlt,
                    label: l10n.capacitorTrackSvlt,
                    unit: 'V',
                    color: AppColors.cyan,
                    decimals: 2,
                    minSpan: 0.5,
                  ),
                if (modules.hasTrack(TrendField.temperature))
                  TrendTrack(
                    field: TrendField.temperature,
                    label: l10n.dashboardTrackTemperature,
                    unit: '\u00b0C',
                    color: AppColors.good,
                    minSpan: 4,
                  ),
              ],
              chartFootnote: modules.chartFootnote?.call(l10n),
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
                // Class gate from the registry, data gate right here — the two
                // are different questions and are answered in different places
                // (design 0034 §12.3 #2). A capacitor DOES stream 0x2E, but it
                // is a constant 0.0 A, so the readout is hidden rather than
                // shown as a real zero.
                if (modules.showsCurrentReadout && tele.current != null)
                  Readout(
                    icon: Icons.electric_bolt,
                    label: l10n.dashboardReadoutCurrentLabel,
                    value: _fmt1(tele.current),
                    unit: 'A',
                  ),
                if (modules.showsSohReadout && tele.sohBucket != null)
                  Readout(
                    icon: Icons.monitor_heart_outlined,
                    label: l10n.dashboardReadoutSohLabel,
                    value: tele.sohBucket!.toString(),
                    unit: '%',
                  ),
              ],
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

  static String _fmtInt(double? v) => v == null ? '--' : v.round().toString();
  static String _fmt1(double? v) => v == null ? '--' : v.toStringAsFixed(1);
}

/// Product-class chip. The picker appears ONLY when the unit is unclassified:
/// when the device-type byte is recognised the class comes off the wire and
/// wins, so offering a menu that silently could not change it would be a lie.
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
        // Nothing here guesses any more: the telemetry-fingerprint heuristic
        // that used to fill this in was removed after it misread a capacitor as
        // a battery. Say "unclassified" and invite the user to pick, rather
        // than implying an automatic detection is still running.
        return l10n.packLabelUnclassified;
    }
  }
}
