/// OpenSmartBatt — one [DisplayModule], one card (design 0034 Phase 5).
///
/// 📦 EXTRACTED, NOT REWRITTEN (design 0046 Step 7). This was `cardFor`, a
/// closure inside `PackScaffold.build` and a second one inside
/// `PowerBankView.build`, capturing `tele` / `l10n` / `modules` / `sohText` /
/// `soc` / `flow`. Being closures made them unreachable from anywhere else —
/// and design 0046's home page places the SAME modules, so it would have had to
/// grow a parallel set of cards. Two renderers for one vocabulary is how the
/// home page and the dashboard end up disagreeing about what `readouts` means.
///
/// 🔴 Every branch below is the original, value for value. The judgement of that
/// claim is not this comment: it is `watchface_ui_test.dart`'s T1 / T2 / T2b,
/// `dashboard_split_test.dart` and `product_ui_test.dart` passing WITHOUT
/// modification.
///
/// ## The split that looks like duplication and is not
///
/// `chart` and `readouts` render differently on a power bank than on a pack —
/// different tracks, different legends, different tiles — so this file branches
/// on [shellClass]. That is exactly the branch the two closures were: the pack
/// shell only ever passes `DisplayModules.packShellClass(label)`, which maps a
/// stray `powerBank` label to `unknown`, and [PowerBankView] passes
/// `ProductClass.powerBank`. Preserving that quirk verbatim is deliberate —
/// see [DisplayModules.forPackShell].
///
/// ## What is NOT here
///
/// The protection card. Design 0034 §6 makes "controls last, always, never
/// customisable" an invariant enforced structurally: there is no
/// [DisplayModule] for it, so no caller of this function can ask for one. The
/// pack shell appends it after its loop; a power bank grows no empty one.
library;

import 'package:flutter/material.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial_card.dart';
import '../widgets/pending_note.dart';
import 'clock_card.dart';
import 'display_modules.dart';
import 'dvol_bars.dart';
import 'g_force_card.dart';
import 'live_trend_chart.dart';
import 'power_flow.dart';
import 'power_path_row.dart';
import 'pvlt_gauge.dart';
import 'readout_grid.dart';
import 'readouts_card.dart';
import 'speed_card.dart';

/// One module → one card, or null when its DATA condition is unmet.
///
/// The split design 0034 §12.3 #2 asked for, made visible: the watchface (or
/// the home layout) decides WHICH cards and in what order, and the card itself
/// still decides whether it has anything to draw. A face that includes `cells`
/// on a session with no DVOL yields no DVOL card — exactly as before this
/// existed — while the export preamble still reports `cells`, which is how a
/// reader tells "no data" apart from "not on the page".
///
/// 🔴 [tele] is a PARAMETER, not a `context.watch` (design 0051 §5). This
/// function used to read `TelemetryController` out of the provider tree itself,
/// which is right on the two surfaces that show real readings and wrong on the
/// third: the home editor has to draw these cards with FAKE data so a layout
/// can be judged with nothing connected. Handing the data in is what makes that
/// possible WITHOUT a `previewMode` flag — see [CardTelemetry] for why a flag
/// was refused. Every caller watches its own source and passes it; the real
/// paths physically cannot pass a fake one.
Widget? dashboardCardFor(
  BuildContext context,
  DisplayModule m, {
  required ProductClass shellClass,
  required CardTelemetry tele,
}) {
  final l10n = AppLocalizations.of(context);
  // 🔴 `?? packFallback` and NOT a D3 early-return.
  //
  // This function is reached only after routing has decided the link is a pack
  // (`RoutingDecision.pack`), and the `shellClass` it is handed has already been
  // through `packShellClass`, which maps a stray `powerBank` LABEL to `unknown`
  // on purpose. So null here means "a pack with a label we cannot use", not "we
  // do not know what this is" — and the answer to it is the generic pack entry,
  // exactly as before design 0050 renamed it.
  //
  // Design 0050 D3 ("no class ⇒ no class-specific cards") is enforced on the
  // HOME surface instead, where a device really can have no class: see
  // `HomeLayout.renderedFor` and `_ModuleTile`.
  final modules =
      DisplayModules.forClass(shellClass) ?? DisplayModules.packFallback;
  final isPowerBank = shellClass == ProductClass.powerBank;

  switch (m) {
    case DisplayModule.gaugeVoltage:
      if (isPowerBank) return null;
      // Centre SOH sub-line for the gauge.
      //
      // Class-gated the same way the current readout below is: a
      // super-capacitor never sends 0x96, so this line could only ever render
      // as "SOH --". A permanent placeholder reads as "we failed to fetch it",
      // not as "this device has no such thing" — so on a capacitor it is
      // omitted. Both the gate AND the wording are the registry's (design 0034
      // §12.3 #2: the per-class difference here is content, not just presence).
      final sohText = modules.sohGaugeLine?.call(l10n, tele.sohBucket);
      return IndustrialCard(
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
      );

    case DisplayModule.gaugeSoc:
      if (!isPowerBank) return null;
      // SOC ring (percent mode, direct 0x96 b6).
      final flow = powerFlowOf(tele.current, portFlagsRaw: tele.portFlagsRaw);
      // Sub-line under the SOC value: the DIRECTION, which is what the caption
      // above it has always promised ("電量 · 充電狀態" / "CHARGE · STATE").
      //
      // It used to be the single-cell voltage, and that was wrong twice over:
      // the caption named a charging state the dial never drew, and the same
      // `pvlt` was printed a second time in the readouts grid below — the
      // duplication `power_bank_view.dart`'s Q5+Q12 note forbids for current and
      // port voltage. Both were reported from the field on v0.7.2, in a
      // 2026-08-04 owner-run controlled capture.
      // `unknown` is the absence of a reading, not a fourth state, so it renders
      // as a placeholder rather than a word.
      final subText = switch (flow) {
        PowerFlow.charging => l10n.powerBankDirectionCharging,
        PowerFlow.discharging => l10n.powerBankDirectionDischarging,
        PowerFlow.idle => l10n.powerBankDirectionIdle,
        PowerFlow.unknown => l10n.powerBankSocSubUnknown,
      };
      return IndustrialCard(
        child: LayoutBuilder(
          builder: (context, c) {
            final s = AppTheme.gaugeDiameter(context, c.maxWidth);
            return Center(
              child: PvltGauge.percent(
                percent: tele.socPercent,
                caption: l10n.powerBankSocCaption,
                subText: subText,
                // Same glyph as the type chip and the same colour as the
                // energy-path row — one direction, three places, no chance of
                // them disagreeing.
                subIcon:
                    flow == PowerFlow.unknown ? null : powerFlowIcon(flow),
                subColor: flow == PowerFlow.unknown
                    ? null
                    : powerFlowColor(context, flow),
                size: s,
              ),
            );
          },
        ),
      );

    case DisplayModule.chart:
      if (isPowerBank) {
        final flow =
            powerFlowOf(tele.current, portFlagsRaw: tele.portFlagsRaw);
        return TrendChartCard(
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
                // Direction-aware, exactly like the energy-path row's own
                // voltage label. The two are separate CARDS on the same page
                // (design 0040 split the chart out of the readouts card), which
                // makes this matter more, not less: a legend reading "output
                // voltage" a few centimetres below a row reading "input" is
                // self-contradictory on one screen.
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
        );
      }
      return TrendChartCard(
        buffer: tele.trend,
        // Same class gate as the current readout below: a capacitor streams
        // 0x2E as a constant 0.0 A, so a current track would draw a flat line
        // at zero and read as "measured 0 A" — worse than leaving it out.
        // Voltage and temperature do move on a capacitor, so the chart is still
        // offered, just without that track.
        tracks: [
          if (modules.hasTrack(TrendField.current))
            TrendTrack(
              field: TrendField.current,
              label: l10n.dashboardTrackCurrent,
              unit: 'A',
              color: AppColors.cyan,
              // Signed, and the axis must cross zero. 0x2E carries a sign whose
              // DIRECTION is still unverified, so the axis states the number and
              // never labels it charge/discharge — but hiding the sign would
              // erase the reversal that makes a cranking load recognisable.
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
              unit: '°C',
              color: AppColors.good,
              minSpan: 4,
            ),
        ],
        // Travels with the CHART, not with the readouts (design 0040 §3.1). On
        // a capacitor this is the line explaining that the absent current track
        // is the device's own constant zero, not a fetch the app got wrong —
        // the single most losable piece of this whole split.
        chartFootnote: modules.chartFootnote?.call(l10n),
      );

    case DisplayModule.readouts:
      if (isPowerBank) {
        final flow =
            powerFlowOf(tele.current, portFlagsRaw: tele.portFlagsRaw);
        final soc = tele.socPercent;
        return ReadoutsCard(
          items: [
            // Order (design 0035 §6, Q5+Q12): SOC, temperature, design
            // capacity. The 0037 "output voltage" and "current" tiles are GONE
            // from here — the energy-path row carries both now, so showing them
            // again would print the same number twice. The capacity tile still
            // collapses when absent; the surviving order holds.
            //
            // The CELL VOLTAGE tile is gone too (2026-08-05, owner's call on a
            // 2026-08-04 controlled capture). On a 1S bank it duplicated the
            // dial's sub-line, and the sub-line is now the direction. If it ever
            // comes back it belongs in ONE place, not two.
            Readout(
              icon: powerFlowIcon(flow),
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
      }
      return ReadoutsCard(
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
          // Class gate from the registry, data gate right here — the two are
          // different questions and are answered in different places (design
          // 0034 §12.3 #2). A capacitor DOES stream 0x2E, but it is a constant
          // 0.0 A, so the readout is hidden rather than shown as a real zero.
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
      );

    case DisplayModule.cells:
      if (isPowerBank) return null;
      if (tele.dvol != null) {
        return IndustrialCard(
          heading: l10n.dashboardDvolHeading,
          headingIcon: Icons.battery_std,
          child: DvolBars(cells: tele.dvol),
        );
      }
      // DVOL frames arriving but VADJ (scaling) not yet known: show a pending
      // note rather than a bogus voltage. See PROTOCOL.md §8.2.
      if (tele.dvolPending) {
        return IndustrialCard(
          heading: l10n.dashboardDvolHeading,
          headingIcon: Icons.battery_std,
          child: PendingNote(text: l10n.dashboardDvolPendingNote),
        );
      }
      return null;

    case DisplayModule.energyPath:
      if (!isPowerBank) return null;
      // design 0035 Phase 2: the two-port "USB" card (whose halves permanently
      // said "unknown") is replaced by the energy-path row. It carries the
      // port-side voltage AND the current, which is why the 0037 "output
      // voltage" and "current" tiles were removed from the grid above (Q5+Q12:
      // the same number must not appear twice).
      //
      // The one module card that reads a provider of its own, so it is the one
      // that needs both facts handed down (design 0051 §5). [shellClass] in
      // particular: the row's own "am I a power bank" gate used to read
      // `ConnectionController.packLabel`, which answers `unknown` in the home
      // editor and would have drawn the preview as an empty box.
      return PowerPathRow(tele: tele, shellClass: shellClass);

    // design 0042. UNCONDITIONAL, and that is the design: availability is
    // applied one level up — by `HomeLayout.renderedFor` on the home surface,
    // which since design 0051 is the ONLY surface that places this module. A
    // second `settings.speedDetection ? … : null` here would be a duplicate
    // decision point, the exact shape that let a `riding` face render as a copy
    // of `compact` (design 0042 §3.9). The card has its own waiting /
    // no-permission states and never vanishes.
    //
    // 🔴 MOUNTING THIS OPENS THE GNSS GATE. `SpeedCard.didChangeDependencies`
    // calls `setFaceWantsSpeed(true)`, so this line is condition 1 of design
    // 0042 §3.4 — which is why the home EDITOR must never reach it. It does not:
    // `_ModuleTile` sends phone modules to `previewPhoneCard` instead, through
    // an exhaustive switch that a new phone module cannot slip past.
    case DisplayModule.speed:
      return const SpeedCard();

    // design 0045. UNCONDITIONAL for the same reason as `speed` above, and it
    // is worth spelling out because this module has TWO conditions rather than
    // one: the switch, and a valid calibration. Both are applied by the home
    // resolver, so reaching this line means the card has axes to name. A
    // `controller.available ? … : null` here would be the duplicate decision
    // point the 2026-08-07 ruling removed — and a second place for the two
    // answers to drift apart. Mounting it starts the accelerometer, so the same
    // editor rule applies.
    case DisplayModule.gForce:
      return const GForceCard();

    // design 0052. 🔴 The one branch of this function that can NEVER return
    // null, and never draws a waiting state either — it has no upstream to
    // wait for. Every `?? HomeWaitingTile(...)` at a call site is dead code
    // for this module, and `clock_card.dart`'s library comment says so where
    // somebody reasoning about "what does an offline home page look like" will
    // read it.
    //
    // Mounting it arms a one-minute timer, so the editor rule that applies to
    // the two modules above applies here too — for a much smaller reason
    // (wasted rebuilds, not a sensor) but through the same seam:
    // `previewCardFor` mounts `ClockCardBody` with a fixed time.
    case DisplayModule.clock:
      return const ClockCard();
  }
}

String _fmtInt(double? v) => v == null ? '--' : v.round().toString();
String _fmt1(double? v) => v == null ? '--' : v.toStringAsFixed(1);
