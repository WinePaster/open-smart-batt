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
import 'dashboard_cards.dart';
import 'display_modules.dart';
import 'status_controls.dart';
import 'watchfaces.dart';

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
    // NOTE the lookup is by `packShellClass`, not the raw label: a stray
    // `powerBank` label reaches this shell (see [PackView] above) and has
    // always drawn the unclassified set here — see the doc on that method.
    final shellClass = DisplayModules.packShellClass(packLabel);
    // WHICH cards, in WHAT order (design 0034 Phase 5). The layout is stored
    // against the connected unit (Q3), so both providers are read: the id moves
    // on connect, the stored layout moves when Settings writes it.
    //
    // `effectiveWatchface` is what makes Q4 true here — an unclassified pack
    // gets the standard face whatever is stored, so the page a user is being
    // asked to identify is never rearranged under them.
    final deviceId =
        context.select<ConnectionController, String?>((c) => c.connectedDeviceId);
    final stored = context.watch<DeviceController>().layoutFor(deviceId);
    // The two master switches reach the LAYOUT, not just their own cards: with
    // both off a stored `riding` renders as `standard` rather than as a copy of
    // `compact` (design 0042 §3.9, revised 2026-08-07), and with only one on
    // the face draws without the other's card (design 0045 Q3, ruling (iv) of
    // 2026-08-07). Selected on the whole settings object because its identity
    // only changes when something is written — this is not on the telemetry
    // rebuild path.
    final settings =
        context.select<SettingsController, AppSettings>((s) => s.settings);
    // 🔴 Runtime, not stored: the G meter is available only while a valid
    // calibration exists, and the still-window check can withdraw that
    // mid-ride. `renderedModules` therefore has to be re-evaluated when this
    // changes, which is what `select` on the controller buys.
    final gAvailable =
        context.select<GForceController, bool>((c) => c.available);
    final order = renderedModules(shellClass, stored.watchface, settings,
        gForceAvailable: gAvailable);
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

            // ---- the watchface: which cards, in what order ---------------
            //
            // The protection card below is NOT in this loop and cannot be:
            // design 0034 §6 makes "controls last, always, never customisable"
            // an invariant, and it is enforced structurally — there is no
            // DisplayModule for it, so no watchface can name it.
            for (final m in order)
              ?dashboardCardFor(context, m,
                  shellClass: shellClass, tele: tele),

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
    final text = _labelText(l10n, label);
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
        // 🔴 The class picker was REMOVED here on 2026-08-08 (design 0050
        // D7). Classifying a unit is not the owner's job — they cannot know,
        // and a wrong answer looks exactly like a right one until something
        // reads oddly. It is ours: they send a log, the device-type byte gets
        // a mapping, the next build knows. `0x18` went through precisely that
        // route on 2026-08-01.
        //
        // An unidentified unit no longer reaches this shell at all
        // (`unidentified_view.dart`), so what remains here is the label chip
        // stating what the wire said — and nothing that invites a guess.
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
