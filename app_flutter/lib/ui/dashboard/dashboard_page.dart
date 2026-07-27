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
import '../../theme/app_theme.dart';
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
    // Device-reported fault bit. Deliberately NOT blocking: the driver is in a
    // vehicle and a dialog over the readings is worse than a banner.
    final fault = context
        .select<TelemetryController, bool>((c) => c.sample.hasDeviceFaultFlag);
    final twf = context.select<TelemetryController, int?>((c) => c.twfRaw);
    return Column(
      children: [
        if (stalled) const _StaleBanner(),
        if (fault) _FaultBanner(twfRaw: twf),
        const Expanded(child: DashboardRouter()),
      ],
    );
  }
}

/// Shown when the device sets its fault bit (TWF 0x20).
///
/// Wording is "suspected" on purpose: the bit→meaning mapping is unverified
/// (PROTOCOL.md §10), so the app reports what the device said rather than
/// asserting a diagnosis. The raw byte rides along so a user can report it and
/// let us pin the semantics down.
class _FaultBanner extends StatelessWidget {
  const _FaultBanner({required this.twfRaw});

  final int? twfRaw;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final code =
        twfRaw == null ? '--' : '0x${twfRaw!.toRadixString(16).padLeft(2, '0')}';
    return Material(
      color: AppColors.amber.withValues(alpha: 0.16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                size: 18, color: AppColors.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.dashboardDeviceFaultSuspected(code),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
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
