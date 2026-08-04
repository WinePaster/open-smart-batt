/// OpenSmartBatt — power-bank dashboard view (RSPB, device-type 0x22).
///
/// A power bank routes here DETERMINISTICALLY, on the device-type byte alone
/// (0x22) — never on a name, a saved label or a register fingerprint, because a
/// guess that picks the wrong view draws a single cell's voltage on a 12 V pack
/// dial. Its instrument is a percent-mode SOC ring fed DIRECTLY by the
/// device-reported state-of-charge (selector 0x96 b6 — there is NO voltage→SOC
/// curve, PROTOCOL.md §9.1), alongside temperature + single-cell voltage
/// readouts. The old USB dual-port card is retired (design 0035); the
/// energy-path row that replaces it lands in Phase 2. A power bank has NO DVOL
/// per-cell card and NO cut-off / anti-theft controls — those live on the pack
/// page, which a power bank never navigates to.
///
/// Since FB-46 the current is SIGNED — discharge positive, charge negative
/// (design 0030, `telemetry_decoder.dart`: `discharging(0x4A) - charge(0x49)`).
/// That sign is the only direction the device gives us, and FB-47 is what
/// happened when nothing on screen said so: a 9.15 V PD charge showed as a bare
/// `-0.43 A` under a hardwired charging icon, and the owner who ruled on the
/// convention read his own device as broken. Everything direction-aware in this
/// file hangs off [PowerFlow] for that reason — one derivation (now shared with
/// the energy-path row via `power_flow.dart`, design 0035 §6), used by the icon,
/// the badge and the SVLT label, so they cannot disagree with each other.
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
    // 0x37 is the port-side voltage: it reads 9.14–9.16 V during a 9 V PD
    // charge (`feedback-analysis/2026.08.04-002.md` §2), i.e. the INPUT. Only
    // the charging case is relabelled — idle, discharging and "no reading at
    // all" keep the original wording, because relabelling those would be a
    // guess rather than a correction.
    final svltLabel = flow == PowerFlow.charging
        ? l10n.powerBankInputVoltageLabel
        : l10n.powerBankOutputVoltageLabel;
    // Sub-line under the SOC value: the single-cell voltage (PVLT is the cell
    // voltage on a power bank, PROTOCOL.md §9.1) or a placeholder.
    final subText = tele.pvlt == null
        ? l10n.powerBankSocSubUnknown
        : l10n.powerBankCellSub(tele.pvlt!.toStringAsFixed(2));

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
              // Order (design 0037): SOC, temperature, output voltage, current,
              // cell voltage, design capacity. The conditional cards (current,
              // capacity) collapse when absent; the surviving order still holds.
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
              Readout(
                icon: Icons.usb,
                label: svltLabel,
                value: _fmt1(tele.svlt),
                unit: 'V',
              ),
              // Magnitude, with the direction in the badge (design 0037,
              // superseding FB-47's signed number). Inside the dead-band the
              // magnitude still shows but the badge drops — no direction to name.
              if (modules.showsCurrentReadout && tele.current != null)
                Readout(
                  icon: _flowIcon(flow),
                  label: l10n.powerBankCurrentLabel,
                  value: _fmtCurrent(tele.current!),
                  unit: 'A',
                  badge: _flowBadge(l10n, flow),
                  badgeColor: _flowColor(flow),
                ),
              Readout(
                icon: Icons.battery_5_bar,
                label: l10n.powerBankCellVoltageLabel,
                value: _fmt2(tele.pvlt),
                unit: 'V',
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
        case DisplayModule.usb:
          // design 0035 Phase 1: the two-port "USB" card is gone (its halves
          // permanently said "unknown"). Its replacement — the standalone
          // energy-path row [PowerPathRow] — exists and is tested, but is NOT
          // placed here yet: doing so has to happen TOGETHER with removing the
          // duplicate 0037 voltage+current tiles above (Q5+Q12: the same number
          // must not appear twice), which is Phase 2. Until then this slot
          // renders nothing rather than show a stale card or a doubled reading.
          return null;
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
  static String _fmt1(double? v) => v == null ? '--' : v.toStringAsFixed(1);
  static String _fmt2(double? v) => v == null ? '--' : v.toStringAsFixed(2);
}

// ---------------------------------------------------------------------------
// Direction (FB-47) — the [PowerFlow] derivation itself lives in
// `power_flow.dart` (shared with the energy-path row, design 0035 §6). What
// stays here is only how THIS page's tiles present it.
// ---------------------------------------------------------------------------

/// Current magnitude — the sign never reaches the readout (design 0037); the
/// badge carries the charge/discharge direction instead. Inside the dead-band
/// the true magnitude still shows (e.g. `0.03`), only the badge drops.
String _fmtCurrent(double v) => v.abs().toStringAsFixed(2);

/// Glyph for [f]. [PowerFlow.unknown] keeps the icon this page has always drawn:
/// with no direction to show, a different glyph would be a different guess,
/// not fewer guesses.
IconData _flowIcon(PowerFlow f) => switch (f) {
      PowerFlow.charging => Icons.battery_charging_full,
      PowerFlow.discharging => Icons.bolt,
      PowerFlow.idle => Icons.pause_circle_outline,
      PowerFlow.unknown => Icons.battery_charging_full,
    };

/// Badge wording, or null when there is no direction to name.
String? _flowBadge(AppLocalizations l10n, PowerFlow f) => switch (f) {
      PowerFlow.charging => l10n.powerBankDirectionCharging,
      PowerFlow.discharging => l10n.powerBankDirectionDischarging,
      // Idle names no state (design 0037): inside the dead-band the direction is
      // noise, so the magnitude shows but the badge drops.
      PowerFlow.idle => null,
      PowerFlow.unknown => null,
    };

/// Badge accent. Idle and unknown fall through to the tile's muted tone —
/// "nothing is happening" does not deserve a colour.
Color? _flowColor(PowerFlow f) => switch (f) {
      PowerFlow.charging => AppColors.good,
      PowerFlow.discharging => AppColors.amber,
      PowerFlow.idle || PowerFlow.unknown => null,
    };
