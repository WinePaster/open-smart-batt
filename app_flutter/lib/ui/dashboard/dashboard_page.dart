/// OpenSmartBatt — dashboard screen + product-class router (mockup `#page-dash`).
///
/// When no device is connected this shows [DisconnectedState] (quick-select +
/// scan). Once online, [DashboardRouter] picks the view by the ONLY
/// deterministic signal (design 0001 §3.1 / §3.4): a confirmed power bank
/// (device-type 0x22) gets [PowerBankView]; everything else (super-capacitor /
/// smart battery, or not-yet-identified) gets the data-driven [PackView]. The
/// cosmetic super-capacitor-vs-battery label NEVER influences this choice.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../state/state.dart';
import '../devices/device_list_sheet.dart';
import 'disconnected_state.dart';
import 'pack_view.dart';
import 'power_bank_view.dart';

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
        onScanRequested: onScanRequested ?? () => showDeviceListSheet(context),
      );
    }
    // A stall is not a disconnect: the link stays ready while Android suspends
    // the app, so the readouts below would otherwise sit frozen with no hint.
    final stalled =
        context.select<TelemetryController, bool>((c) => c.telemetryStalled);
    return Column(
      children: [
        if (stalled) const _StaleBanner(),
        const Expanded(child: DashboardRouter()),
      ],
    );
  }
}

/// Shown when the link is up but telemetry has stopped arriving.
class _StaleBanner extends StatelessWidget {
  const _StaleBanner();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Row(
          children: [
            Icon(Icons.pause_circle_outline,
                size: 18, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.dashboardTelemetryStalled,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks the live view by the deterministic power-bank signal (design 0001
/// §3.4). Routing reads [ConnectionController.isPowerBank] — the SAME resolver
/// that drives persistence and capability gating (single source of truth,
/// design 0001 §3.1) — so the chosen layout can never disagree with the stored
/// class. The cosmetic pack label is never consulted here.
class DashboardRouter extends StatelessWidget {
  const DashboardRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final isPowerBank =
        context.select<ConnectionController, bool>((c) => c.isPowerBank);
    return isPowerBank ? const PowerBankView() : const PackView();
  }
}
