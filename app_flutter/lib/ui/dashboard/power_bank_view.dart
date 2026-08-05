/// OpenSmartBatt — power-bank dashboard view (RSPB, device-type 0x22).
///
/// A power bank routes here DETERMINISTICALLY, on the device-type byte alone
/// (0x22) — never on a name, a saved label or a register fingerprint, because a
/// guess that picks the wrong view draws a single cell's voltage on a 12 V pack
/// dial. Its instrument is a percent-mode SOC ring fed DIRECTLY by the
/// device-reported state-of-charge (selector 0x96 b6 — there is NO voltage→SOC
/// curve, PROTOCOL.md §9.1), alongside temperature + single-cell voltage
/// readouts. The old USB dual-port card is retired (design 0035) and its slot
/// now holds the [PowerPathRow] energy-path line — which is also why the
/// current and port-voltage tiles are gone from the grid here (Q5+Q12: the row
/// carries them, and one number must not print twice). A power bank has NO DVOL
/// per-cell card and NO cut-off / anti-theft controls — those live on the pack
/// page, which a power bank never navigates to.
///
/// Since FB-46 the current is SIGNED — discharge positive, charge negative
/// (design 0030, `telemetry_decoder.dart`: `discharging(0x4A) - charge(0x49)`).
/// That sign is the only direction the device gives us, and FB-47 is what
/// happened when nothing on screen said so: a 9.15 V PD charge showed as a bare
/// `-0.43 A` under a hardwired charging icon, and the owner who ruled on the
/// convention read his own device as broken. Everything direction-aware in this
/// file hangs off [PowerFlow] for that reason — one derivation (shared with the
/// energy-path row via `power_flow.dart`, design 0035 §6), used by the type-chip
/// glyph and the chart's input/output voltage legend, so they cannot disagree.
/// The current and voltage READOUTS themselves now live on the energy-path row
/// (design 0035 Phase 2), not in this grid.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial_card.dart';
import 'display_modules.dart';
import 'pvlt_gauge.dart';
import 'live_trend_chart.dart';
import 'power_flow.dart';
import 'power_path_row.dart';
import 'readout_grid.dart';
import 'readouts_card.dart';
import 'watchfaces.dart';

/// The power-bank dashboard body.
class PowerBankView extends StatelessWidget {
  const PowerBankView({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    // This view is only ever built for a confirmed power bank, so the class is
    // a constant here rather than a lookup on a label. Going through the
    // registry anyway is what keeps the declaration honest: an entry that no
    // code reads is an entry nothing can contradict (design 0034 Phase 0).
    const modules = DisplayModules.powerBank;

    final soc = tele.socPercent;
    // The ONE derivation of direction on this page (FB-47). Everything that
    // claims a direction below reads this variable, so the icon, the badge and
    // the SVLT label cannot end up telling three different stories.
    final flow = powerFlowOf(tele.current);
    // Sub-line under the SOC value: the DIRECTION, which is what the caption
    // above it has always promised ("電量 · 充電狀態" / "CHARGE · STATE").
    //
    // It used to be the single-cell voltage, and that was wrong twice over: the
    // caption named a charging state the dial never drew, and the same `pvlt`
    // was printed a second time in the readouts grid below — the duplication
    // this file's own Q5+Q12 note forbids for current and port voltage. Both
    // were both reported from the field on v0.7.2, in a 2026-08-04 owner-run
    // controlled capture.
    // `unknown` is the absence of a reading, not a fourth state, so it renders
    // as a placeholder rather than a word.
    final subText = switch (flow) {
      PowerFlow.charging => l10n.powerBankDirectionCharging,
      PowerFlow.discharging => l10n.powerBankDirectionDischarging,
      PowerFlow.idle => l10n.powerBankDirectionIdle,
      PowerFlow.unknown => l10n.powerBankSocSubUnknown,
    };

    // WHICH cards, in WHAT order (design 0034 Phase 5). The layout is stored
    // against the connected unit (Q3), so both providers are read: the id moves
    // on connect, the stored layout moves when Settings writes it.
    final deviceId =
        context.select<ConnectionController, String?>((c) => c.connectedDeviceId);
    final stored = context.watch<DeviceController>().layoutFor(deviceId);
    final order = watchfaceModules(ProductClass.powerBank,
        effectiveWatchface(ProductClass.powerBank, stored.watchface));

    /// One module → one card. The SOC and readouts cards are unconditional: a
    /// missing SOC renders as `--` inside the ring rather than removing it. The
    /// old USB card is gone (design 0035); its `usb` slot renders nothing until
    /// Phase 2 places the energy-path row here.
    Widget? cardFor(DisplayModule m) {
      switch (m) {
        case DisplayModule.gaugeSoc:
          // SOC ring (percent mode, direct 0x96 b6).
          return IndustrialCard(
            child: LayoutBuilder(
              builder: (context, c) {
                final s = AppTheme.gaugeDiameter(context, c.maxWidth);
                return Center(
                  child: PvltGauge.percent(
                    percent: soc,
                    caption: l10n.powerBankSocCaption,
                    subText: subText,
                    // Same glyph as the type chip above (this file's
                    // [_flowIcon]) and the same colour as the energy-path row
                    // below ([powerFlowColor]) — one direction, three places,
                    // no chance of them disagreeing.
                    subIcon: flow == PowerFlow.unknown ? null : _flowIcon(flow),
                    subColor: flow == PowerFlow.unknown
                        ? null
                        : powerFlowColor(context, flow),
                    size: s,
                  ),
                );
              },
            ),
          );
        case DisplayModule.readouts:
          return ReadoutsCard(
            buffer: tele.trend,
            // A power bank's current has its direction spread over two
            // registers — 0x49 while charging, 0x4A while discharging — and
            // since FB-46 both reach `current` as one signed number. The track
            // stays signed and zero-crossing, and MUST: a sign flip mid-window
            // is how a start-up load is recognised at a glance, which no
            // magnitude plot can show. Nothing here is direction-switched.
            tracks: [
              if (modules.hasTrack(TrendField.current))
                TrendTrack(
                  field: TrendField.current,
                  label: l10n.powerBankTrackCurrent,
                  unit: 'A',
                  color: AppColors.cyan,
                  decimals: 2,
                  spanZero: true,
                  minSpan: 1,
                  height: 92,
                ),
              if (modules.hasTrack(TrendField.svlt))
                TrendTrack(
                  field: TrendField.svlt,
                  // Same relabel as the readout beside it. The chart is the
                  // OTHER face of this one card (a toggle, not another page),
                  // so a legend that still said "output" while the tile said
                  // "input" would be visibly self-contradictory.
                  label: flow == PowerFlow.charging
                      ? l10n.powerBankTrackInput
                      : l10n.powerBankTrackOutput,
                  unit: 'V',
                  color: AppColors.amber,
                  decimals: 2,
                  minSpan: 0.5,
                ),
              if (modules.hasTrack(TrendField.soc))
                TrendTrack(
                  field: TrendField.soc,
                  label: l10n.powerBankTrackSoc,
                  unit: '%',
                  color: AppColors.good,
                  minSpan: 5,
                ),
            ],
            items: [
              // Order (design 0035 §6, Q5+Q12): SOC, temperature, design
              // capacity. The 0037 "output voltage" and "current" tiles are
              // GONE from here — the energy-path row carries both now, so
              // showing them again would print the same number twice. The
              // capacity tile still collapses when absent; the surviving order
              // holds.
              //
              // The CELL VOLTAGE tile is gone too (2026-08-05, owner's call on
              // 2026-08-04 controlled capture). On a 1S bank it duplicated
              // the dial's sub-line, and the sub-line is now the direction. If
              // it ever comes back it belongs in ONE place, not two.
              Readout(
                icon: _flowIcon(flow),
                label: l10n.powerBankSocReadoutLabel,
                value: soc == null ? '--' : soc.toString(),
                unit: '%',
              ),
              Readout(
                icon: Icons.thermostat,
                label: l10n.dashboardReadoutTemperatureLabel,
                value: _fmtInt(tele.temperatureDisplay),
                unit: tele.temperatureUnitLabel,
              ),
              if (tele.sample.designCapacityMah != null)
                Readout(
                  icon: Icons.battery_std,
                  label: l10n.powerBankDesignCapacityLabel,
                  value: tele.sample.designCapacityMah!.toString(),
                  unit: 'mAh',
                ),
            ],
          );
        case DisplayModule.energyPath:
          // design 0035 Phase 2: the two-port "USB" card (whose halves
          // permanently said "unknown") is replaced by the energy-path row.
          // It carries the port-side voltage AND the current, which is why the
          // 0037 "output voltage" and "current" tiles were removed from the
          // grid above (Q5+Q12: the same number must not appear twice).
          return const PowerPathRow();
        case DisplayModule.gaugeVoltage:
        case DisplayModule.chart:
        case DisplayModule.cells:
          // Not cards of this view, and unreachable through [order] — it is
          // built from this class's own registry entry. Listed explicitly so
          // that a NEW module fails to compile here rather than silently
          // drawing nothing.
          return null;
      }
    }

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
                  // The glyph follows the flow. It used to be a hardwired
                  // charging battery, which meant a bank being drained down
                  // still showed a charging icon (FB-47, symptom 1).
                  Icon(_flowIcon(flow),
                      size: 14, color: const Color(0xFFF0A030)),
                  const SizedBox(width: 6),
                  Text(
                    l10n.dashboardDeviceTypeDetected(
                        l10n.dashboardDeviceTypePowerBank),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),

            // ---- the watchface: which cards, in what order --------------
            //
            // NOTHING is appended after this loop, and that is design 0034 §6
            // rule 3 rather than an omission: a power bank has no protection
            // controls, and must not grow an empty control card for the sake of
            // looking like the pack page. An always-empty card is the same
            // mistake as a permanent `--`.
            for (final m in order) ?cardFor(m),
          ],
        ),
      ),
    );
  }

  static String _fmtInt(double? v) => v == null ? '--' : v.round().toString();
}

// ---------------------------------------------------------------------------
// Direction (FB-47) — the [PowerFlow] derivation itself lives in
// `power_flow.dart` (shared with the energy-path row, design 0035 §6). What
// stays here is only how THIS page's tiles present it: since design 0035
// Phase 2 the current/voltage tiles moved to the energy-path row, so all that
// remains here is the glyph on the type chip and the SOC tile.
// ---------------------------------------------------------------------------

/// Glyph for [f]. [PowerFlow.unknown] keeps the icon this page has always drawn:
/// with no direction to show, a different glyph would be a different guess,
/// not fewer guesses.
IconData _flowIcon(PowerFlow f) => switch (f) {
      PowerFlow.charging => Icons.battery_charging_full,
      PowerFlow.discharging => Icons.bolt,
      PowerFlow.idle => Icons.pause_circle_outline,
      PowerFlow.unknown => Icons.battery_charging_full,
    };
