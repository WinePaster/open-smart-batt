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
import 'live_trend_chart_page.dart';
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
/// 🔴 [surface] is WHERE this card is being drawn, and it is REQUIRED — see
/// `card_surface.dart` for why it is a parameter with no default rather than a
/// scope. Exactly ONE branch reads it today (the power bank's 標示容量 tile,
/// owner ruling 2026-08-21: off the device page, kept on the home grid), and it
/// is deliberately not used for anything else. A surface flag is a licence to
/// make any card differ per page, which is how two surfaces stop being the same
/// card factory at all — the thing this file's own doc comment says it exists
/// to prevent. Every new use needs its own ruling.
///
/// [view] is the tile's stored CONTENT VARIANT slug, or null for that card's
/// default (design 0054). It arrives as a raw string because the vocabulary is
/// scoped to the module — `card_view.dart` argues why there is no global enum —
/// and each branch below resolves it against its own, falling back to the
/// default for anything it does not recognise.
///
/// 🔴 It reaches NO decision about which values are read or drawn (S-R1 / F5).
/// Every gate above and below stays where it was: the class gates, the data
/// gates and the registry lookups are all upstream of the `switch (view)`.
Widget? dashboardCardFor(
  BuildContext context,
  DisplayModule m, {
  required ProductClass shellClass,
  required CardSurface surface,
  required CardTelemetry tele,
  String? view,
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
      // design 0054. The caption and the sub-line are the SAME in both views —
      // only the instrument around them changes. That is the whole point of
      // `GaugeReadoutStack` being shared: a gauge card has no heading, so the
      // caption is its identity and cannot be allowed to differ per view (F1).
      if ((GaugeView.fromSlug(view) ?? GaugeView.dial) == GaugeView.numeric) {
        return IndustrialCard(
          child: PvltNumeric.voltage(
            volts: tele.pvlt,
            caption: l10n.gaugePvltLabel,
            subText: sohText,
          ),
        );
      }
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
      if ((GaugeView.fromSlug(view) ?? GaugeView.dial) == GaugeView.numeric) {
        return IndustrialCard(
          child: PvltNumeric.percent(
            percent: tele.socPercent,
            caption: l10n.powerBankSocCaption,
            subText: subText,
            subIcon: flow == PowerFlow.unknown ? null : powerFlowIcon(flow),
            subColor: flow == PowerFlow.unknown
                ? null
                : powerFlowColor(context, flow),
          ),
        );
      }
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
      // 📦 The TRACKS moved to `live_trend_chart_core.dart` on 2026-09-02
      // (design 0093 §4 Q6), value for value. They had to: the full-screen
      // shell draws the same chart, and a copy of this list taken at push time
      // would freeze a power bank's 輸入／輸出 legend against a flow that keeps
      // changing. One list, two shells — the same rule as the painter.
      return TrendChartCard(
        buffer: tele.trend,
        tracks: chartTracksFor(
          context,
          modules: modules,
          isPowerBank: isPowerBank,
          tele: tele,
        ),
        // Travels with the CHART, not with the readouts (design 0040 §3.1). On
        // a capacitor this is the line explaining that the absent current track
        // is the device's own constant zero, not a fetch the app got wrong —
        // the single most losable piece of this whole split. (Null for a power
        // bank, as it always has been: `DisplayModules.powerBank` declares no
        // footnote, so folding the two branches together changed nothing.)
        chartFootnote: modules.chartFootnote?.call(l10n),
        // 🔵 design 0093 §4 Q4 — the device page gets the full-screen entry,
        // the home grid does not. Decided from the surface rather than from the
        // tile's size, and by the same parameter the 標示容量 tile is decided
        // by (`card_surface.dart`, owner ruling 2026-08-21).
        onExpand: surface == CardSurface.deviceDetail
            ? () => showLiveTrendChartPage(context,
                shellClass: shellClass, tele: tele)
            : null,
      );

    case DisplayModule.readouts:
      // design 0054. Resolved once and handed to both branches: the ITEM LIST
      // differs per class, the ARRANGEMENT does not.
      final readoutsView = ReadoutsView.fromSlug(view) ?? ReadoutsView.grid;
      if (isPowerBank) {
        final flow =
            powerFlowOf(tele.current, portFlagsRaw: tele.portFlagsRaw);
        final soc = tele.socPercent;
        return ReadoutsCard(
          view: readoutsView,
          items: [
            // Order (design 0035 §6, Q5+Q12): SOC, temperature, design
            // capacity — the last of which is HOME-ONLY since 2026-08-21, so on
            // the device page this list is two tiles long. The surviving order
            // is unchanged either way, which is what the note below promises.
            // The 0037 "output voltage" and "current" tiles are GONE
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
            // 🔴 HOME GRID ONLY since 2026-08-21 (owner: 「數字格 移除
            // 10000mAh」). On the device page this grid is now SOC + temperature
            // and nothing else.
            //
            // 🔑 Removed rather than moved, and the difference matters: the
            // 標示容量 is the NAMEPLATE (`0x4B` b4b5 — a constant the unit
            // reports about itself, 10000 on a unit rated 10000 mAh), not a
            // measurement. Nothing on the page is read against it and it never
            // changes while you watch, so the rule that forced PVLT into this
            // grid when its dial went away — a dropped card must not be the
            // only home of a live number — does not apply to it.
            //
            // The tile SURVIVES on the home grid because that layout is the
            // user's, not ours (`card_surface.dart`), so the l10n key and the
            // `designCapacityMah` decode both stay live and this is not a
            // retired-key cleanup.
            if (surface == CardSurface.home &&
                tele.sample.designCapacityMah != null)
              Readout(
                icon: Icons.battery_std,
                label: l10n.powerBankDesignCapacityLabel,
                value: tele.sample.designCapacityMah!.toString(),
                unit: 'mAh',
              ),
          ],
        );
      }
      // Derived once, beside the power-bank branch's own `flow` and by the
      // deliberately DIFFERENT function — see `power_flow.dart` for why a pack
      // and a power bank cannot share one derivation.
      final packFlow = packFlowOf(tele.current);
      return ReadoutsCard(
        view: readoutsView,
        items: [
          // 🔴 PVLT FIRST, added 2026-08-16 (owner ruling, from a v0.7.21
          // screenshot). Until then the pack's main voltage appeared on this
          // page in exactly one place — the dial — so a grid that listed SVLT
          // and temperature omitted the number both of those are read against.
          //
          // 🔑 On a capacitor that omission became a deletion: the same ruling
          // drops the dial for that class (`watchfaces.dart`), and without this
          // row PVLT would have had nowhere left to be.
          //
          // ⚠️ On a BATTERY this is deliberately redundant with the dial it
          // keeps. They answer different questions — the dial says where in the
          // range the pack is sitting, this says what the number is — and
          // design 0017 §3.2's own argument for the dial is the POSITION, not
          // the digits.
          //
          // Order is PVLT → SVLT → temperature, matching the chart's track
          // order directly above it. Two surfaces on one screen listing the
          // same three quantities in different orders is a reading error
          // waiting to happen.
          //
          // 🔴 TWO decimals on the voltages (FB-81, owner's 2026-08-17 ruling).
          // The paragraph above aligned the ORDER with the chart track directly
          // overhead and stopped there, so the same screen printed 13.28 on the
          // curve and 13.3 in the cell — the reading error it was written to
          // prevent, one line further down. `0x19`/`0x37` decode as `u16/100`,
          // so the second decimal is measured, not interpolated, and rounding
          // it away costs up to 0.05 V — five times the 10 mV quantum.
          //
          // The CURRENT cell below deliberately keeps one decimal: `0x2E` is
          // `512 - u16`, integer amps, so its `.0` is typography either way and
          // widening it would only claim a precision the wire does not carry
          // (design 0067 §3.1). Same ruling, opposite answer, because the
          // question is what the register can support — not what looks tidy.
          Readout(
            icon: Icons.bolt,
            label: l10n.gaugePvltLabel,
            value: _fmt2(tele.pvlt),
            unit: 'V',
          ),
          // 🔴 CLASS-GATED since FB-106 (2026-08-30) — absent on a smart
          // battery, present on a capacitor. The registry holds the argument
          // (`display_modules.dart`, [DisplayModules.showsSvltReadout]); what
          // belongs here is why there is no DATA gate beside it: this tile is
          // not being hidden when the number is missing, it is being removed
          // from a class that has the same number twice already. A capacitor
          // keeps it because it has no DVOL card for it to duplicate.
          //
          // ⚠️ Ordering note above still holds for the classes that show it:
          // PVLT → SVLT → temperature. On a battery the list simply closes up
          // to PVLT → temperature, which is the chart's track order minus a
          // series the battery's chart never plotted either.
          if (modules.showsSvltReadout)
            Readout(
              icon: Icons.bolt,
              label: l10n.dashboardReadoutSvltLabel,
              value: _fmt2(tele.svlt),
              unit: 'V',
            ),
          Readout(
            icon: Icons.thermostat,
            label: l10n.dashboardReadoutTemperatureLabel,
            value: _fmtInt(tele.temperatureDisplay),
            unit: tele.temperatureUnitLabel,
          ),
          // Class gate from the registry, data gate right here — the two are
          // different questions and are answered in different places (design
          // 0034 §12.3 #2). A capacitor DOES stream 0x2E, but it is a constant
          // 0.0 A, so the readout is hidden rather than shown as a real zero.
          //
          // 🔴 MAGNITUDE + DIRECTION BADGE, not a signed number (design 0056,
          // owner's 2026-08-11 ruling B). It printed `-35.0 A` until then, and
          // a bare signed number with no word beside it is the defect FB-47 was
          // filed for — twice over, since both times the person who misread it
          // was the one who had ruled on the sign convention. The sign is NOT
          // flipped (ruling A): it is spent here on choosing the word.
          //
          // Same three-part language as the power bank's tiles (design 0037):
          // one glyph table, one colour table, one vocabulary — read from
          // `packFlowOf`, which signs a pack the opposite way to `powerFlowOf`.
          if (modules.showsCurrentReadout && tele.current != null)
            Readout(
              icon: powerFlowIcon(packFlow),
              label: l10n.dashboardReadoutCurrentLabel,
              value: _fmt1(tele.current!.abs()),
              unit: 'A',
              // `unknown` shares the idle word rather than getting one of its
              // own: it is unreachable under the `!= null` gate above, and a
              // fourth string for a state this tile cannot be in would be a
              // claim nobody could ever see to check.
              badge: switch (packFlow) {
                PowerFlow.charging => l10n.packDirectionCharging,
                PowerFlow.discharging => l10n.packDirectionDischarging,
                PowerFlow.idle || PowerFlow.unknown => l10n.packDirectionIdle,
              },
              badgeColor: powerFlowColor(context, packFlow),
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
      return ClockCard(view: ClockView.fromSlug(view) ?? ClockView.digital);
  }
}

String _fmtInt(double? v) => v == null ? '--' : v.round().toString();
String _fmt1(double? v) => v == null ? '--' : v.toStringAsFixed(1);

/// Voltages only. Kept beside [_fmt1] rather than replacing it: the two now
/// mean different things — "as fine as the register goes" and "one decimal
/// because that is the house style for a quantity whose register has none".
String _fmt2(double? v) => v == null ? '--' : v.toStringAsFixed(2);
