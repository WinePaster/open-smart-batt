/// OpenSmartBatt — dashboard disconnected empty state (mockup `.empty`).
///
/// Shown when no device is connected: a pulsing Bluetooth glyph, a prompt, a
/// quick-select list of saved devices (one-tap reconnect) and a "scan others"
/// button that hands off to the device list.
///
/// It also reports an auto-reconnect in progress, which it did not used to.
/// This screen once read only [ConnectionController.isBusy], and `isBusy` is
/// false during the backoff WAIT between two attempts — the link is genuinely
/// `disconnected` then. So a phone working through a five-attempt reconnect
/// showed a spinner that appeared, vanished for two seconds, reappeared for a
/// fraction of a second, vanished for four. A field capture that spent 15.7 s
/// of a 16.2 s wait in that state is what this addresses. It changes nothing
/// about the reconnect policy or its timing: the state was always there, it was
/// simply not on screen.
///
/// 📦 The WORDS are no longer here. The FB-52 / FB-53 code sets, the branch
/// order and the advice card moved to `ui/devices/connection_failure.dart`
/// (design 0046 Step 1) so the device detail page can show the same report
/// rather than a second, weaker copy of it. This file is now the LAYOUT: glyph,
/// title, body, advice card, quick-pick list, scan button.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../devices/connection_failure.dart';
import '../devices/signal_bars.dart';

/// The dashboard's disconnected placeholder.
class DisconnectedState extends StatelessWidget {
  const DisconnectedState({super.key, this.onScanRequested});

  /// Invoked by the "掃描其他裝置" button. Typically opens the device-list
  /// sheet; falls back to starting a scan if not provided.
  final VoidCallback? onScanRequested;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final conn = context.watch<ConnectionController>();
    final devices = conn.savedDevices;

    // One flag for "the app is working on it", covering both halves of the
    // cycle: the attempt itself (isBusy) and the backoff wait before the next
    // one (isRetrying). Either alone leaves a visible hole.
    final retrying = conn.isRetrying;
    final working = conn.isBusy || retrying;

    // The branch order, the code sets and every string below are
    // `connection_failure.dart`'s — see that file for why each one is there.
    final copy = connectionFailureCopy(
      l10n: l10n,
      lastError: conn.lastError,
      working: working,
      isBusy: conn.isBusy,
      isRetrying: retrying,
      setupStalled: conn.isSetupStalled,
      setupFailures: conn.setupFailures,
      reconnectAttempts: conn.reconnectAttempts,
    );

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight,
            minWidth: constraints.maxWidth, // fill width (IndexedStack passes loose constraints)
          ),
          child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 30),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ConnectionPulseIcon(working: working),
            const SizedBox(height: 24),
            Text(
              copy.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 23,
                letterSpacing: 0.5,
                fontWeight: FontWeight.w700,
                color: context.colors.text,
              ),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(
                copy.body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.7,
                  color: context.colors.muted,
                ),
              ),
            ),
            const SizedBox(height: 26),

            if (copy.hasAdvice) ...[
              ConnectionAdviceCard(
                hint: copy.adviceHint!,
                retryLabel: l10n.disconnectedStalledRetry,
                // `reconnectCurrent` is the right entry point rather than a bare
                // `connect`: it keeps the routing seed, which is the difference
                // between coming back to the same layout and coming back to an
                // unclassified one.
                onRetry: () => unawaited(
                    conn.reconnectCurrent().catchError((Object _) {})),
              ),
              const SizedBox(height: 26),
            ],

            if (devices.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    l10n.disconnectedQuickSelectHeading,
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 2,
                      color: context.colors.muted,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              for (final d in devices)
                _QuickPick(
                  device: d,
                  busy: conn.isBusy && conn.connectedDeviceId == d.id,
                  // FB-44: `connectToSaved` rethrows, and this tap handler
                  // discards the future — so a failed quick-pick reached the
                  // zone handler and was written to the diagnostic log as
                  // `Uncaught:`, ten times in one 40-hour capture. There is
                  // nothing for a caller to do with the exception here (the
                  // controller has already recorded the reason in `lastError`
                  // and in the log, and this widget rebuilds on it), so it is
                  // absorbed deliberately rather than left to look like a
                  // crash. The device sheet's own connect path has always
                  // caught it; this one was simply never given a handler.
                  //
                  // FB-53: absorbed, but no longer silent. `connectToSaved`
                  // classifies the failure into `lastError` before it rethrows
                  // and the give-up branch above renders those codes, so
                  // swallowing the exception now costs the user nothing. It did
                  // cost them something while this screen had nowhere to show
                  // it: R3 stopped wrapping a failed first connect in 108 s of
                  // "Reconnecting…", which would have left the tap looking like
                  // it did nothing at all.
                  onTap: () => unawaited(
                      conn.connectToSaved(d).catchError((Object _) {})),
                ),
              const SizedBox(height: 14),
            ],

            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      (onScanRequested ?? () => conn.startScan())(),
                  icon: const Icon(Icons.bluetooth, size: 16),
                  label: Text(l10n.disconnectedScanButton),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),
          ],
        ),
          ),
        ),
      ),
    );
  }
}

class _QuickPick extends StatelessWidget {
  const _QuickPick({
    required this.device,
    required this.busy,
    required this.onTap,
  });

  final SavedDevice device;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final alias = device.alias.isNotEmpty ? device.alias : device.id;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.colors.panel,
              border: Border.all(color: context.colors.line),
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Row(
              children: [
                const _DeviceGlyph(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        alias,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: context.colors.text,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _metaLine(AppLocalizations.of(context), device),
                        style: AppTextStyles.mono(context).copyWith(
                          fontSize: 10.5,
                          color: context.colors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.amber,
                    ),
                  )
                else
                  SignalBars(level: _recencyLevel(device.lastSeen)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _metaLine(AppLocalizations l10n, SavedDevice d) {
    final parts = <String>[];
    if (d.lastValue != null) {
      parts.add(l10n.quickPickLastValue(d.lastValue!.toStringAsFixed(2)));
    }
    parts.add(_relativeTime(l10n, d.lastSeen));
    return parts.join(' · ');
  }
}

/// Amber capacitor glyph tile (mockup `.qpick .dico`).
class _DeviceGlyph extends StatelessWidget {
  const _DeviceGlyph();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: context.colors.bg,
        border: Border.all(color: context.colors.line),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: const Icon(Icons.battery_charging_full,
          size: 19, color: AppColors.amber),
    );
  }
}

/// Maps last-seen recency to a 1..4 quick-pick signal hint (no live RSSI here).
int _recencyLevel(DateTime? lastSeen) {
  if (lastSeen == null) return 1;
  final d = DateTime.now().difference(lastSeen);
  if (d < const Duration(minutes: 5)) return 4;
  if (d < const Duration(hours: 1)) return 3;
  if (d < const Duration(days: 1)) return 2;
  return 1;
}

/// Coarse relative-time label (e.g. "Just now / 2 minutes ago / 2 days ago").
String _relativeTime(AppLocalizations l10n, DateTime? t) {
  if (t == null) return l10n.relativeNever;
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return l10n.relativeJustNow;
  if (d.inMinutes < 60) return l10n.relativeMinutesAgo(d.inMinutes);
  if (d.inHours < 24) return l10n.relativeHoursAgo(d.inHours);
  return l10n.relativeDaysAgo(d.inDays);
}
