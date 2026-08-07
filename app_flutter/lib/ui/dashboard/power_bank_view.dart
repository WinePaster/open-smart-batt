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
import 'dashboard_cards.dart';
import 'power_flow.dart';
import 'watchfaces.dart';

/// The power-bank dashboard body.
class PowerBankView extends StatelessWidget {
  const PowerBankView({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    // The ONE derivation of direction on this page (FB-47). The type chip below
    // and every card in `dashboard_cards.dart` read the same function, so they
    // cannot end up telling different stories.
    final flow = powerFlowOf(tele.current);

    // WHICH cards, in WHAT order (design 0034 Phase 5). The layout is stored
    // against the connected unit (Q3), so both providers are read: the id moves
    // on connect, the stored layout moves when Settings writes it.
    final deviceId =
        context.select<ConnectionController, String?>((c) => c.connectedDeviceId);
    final stored = context.watch<DeviceController>().layoutFor(deviceId);
    // See the same read in `pack_view.dart`: the two master switches reach the
    // LAYOUT, not just their own cards (design 0042 §3.9 / design 0045 Q3).
    final settings =
        context.select<SettingsController, AppSettings>((s) => s.settings);
    final gAvailable =
        context.select<GForceController, bool>((c) => c.available);
    final order = renderedModules(
        ProductClass.powerBank, stored.watchface, settings,
        gForceAvailable: gAvailable);

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
                  Icon(powerFlowIcon(flow),
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
            for (final m in order)
              ?dashboardCardFor(context, m,
                  shellClass: ProductClass.powerBank),
          ],
        ),
      ),
    );
  }

}
