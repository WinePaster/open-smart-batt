/// OpenSmartBatt — dashboard disconnected empty state (mockup `.empty`).
///
/// Shown when no device is connected: a pulsing Bluetooth glyph, a prompt, a
/// quick-select list of saved devices (one-tap reconnect) and a "scan others"
/// button that hands off to the device-list sheet.
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
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../devices/signal_bars.dart';

/// The `lastError` codes that mean "we have stopped, and nothing else is
/// coming" — as opposed to the ones a retry is already under way for.
///
/// Named here rather than inlined because this set is the contract between the
/// controller and this screen: a give-up code added to [ConnectionController]
/// and not to this set goes back to being invisible, which is the whole FB-53
/// complaint.
///
/// 🔴 That is not a hypothetical. The set shipped with four of the seven codes
/// the controller can actually produce, and the three it left out are the three
/// a user meets FIRST: turning Bluetooth off and then tapping a quick-pick
/// short-circuits in `connect()`'s preflight (`bluetooth_off`,
/// `bluetooth_unauthorized`) or in its permission check (`permission_denied`),
/// none of which throws — so the tap set `lastError`, returned quietly, and the
/// screen fell straight back to "No device connected". Which is FB-53's
/// original report, still reproducible after FB-53 shipped.
///
/// `give_up_visibility_test.dart` now derives the controller's codes from its
/// source and fails if any of them lands nowhere, so the next one added cannot
/// repeat this.
const _gaveUpCodes = <String>{
  'reconnect_exhausted',
  'device_stale',
  'device_unreachable',
  // The one that catches the rest. Android has no equivalent of
  // the stale-NSUUID fallback, so before this every connect failure the plugin
  // did not raise itself — a relayed GATT 133 is the ordinary one — reached the
  // screen as a raw exception string and matched nothing here. That was
  // survivable only while a failed first connect still bought a minute of
  // "Reconnecting… (attempt N of 5)"; with the ladder now reserved for links
  // that existed, a quick-pick tap ended in a screen identical to the one
  // before the tap. Which is the FB-53 complaint, word for word.
  'connect_failed',
  // The three that never reach BLE at all. They are refusals, not failures:
  // `connect()` returns without throwing, so the quick-pick tap handler sees a
  // clean future and there is nothing anywhere else to report them.
  'bluetooth_off',
  'bluetooth_unauthorized',
  'permission_denied',
};

/// The subset of [_gaveUpCodes] whose remedy is the phone, not the device.
///
/// They need their own hint because the standing one — "check the unit is
/// nearby and powered, then try again — or scan for it below" — is three
/// instructions that cannot work with the radio down, and the last of them
/// sends the user to a scan that will fail for the same reason.
const _radioCodes = <String>{
  'bluetooth_off',
  'bluetooth_unauthorized',
  'permission_denied',
};

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

    // FB-52: the link has come up several times and never said anything. This
    // has to outrank the plain "not connected" copy — the user watched the
    // spinner and was told nothing, for forty minutes, in the capture that
    // motivated it. It is gated on `!working` so a manual retry still shows
    // progress: `connect()` clears `lastError`, so the failure only comes back
    // once the retry has failed too.
    final stalled = !working && conn.lastError == 'gatt_setup_stalled';

    // FB-53: the three ways an attempt can END, which this screen used to sit
    // through in silence. The backoff ladder runs its 60 s, `lastError` is set,
    // `isRetrying` goes false — and the copy falls back to "no device
    // connected", the same words shown before anyone had tapped anything. So
    // the app stopped trying and the only way to find out was that the spinner
    // was gone. Same `!working` gate as `stalled`, for the same reason: a
    // manual retry has to look like progress, and `connect()` clears
    // `lastError`, so the message only returns once the retry has failed too.
    final gaveUp = !working && _gaveUpCodes.contains(conn.lastError);

    final String title;
    final String body;
    if (stalled) {
      title = l10n.disconnectedStalledTitle;
      body = l10n.disconnectedStalledBody(conn.setupFailures);
    } else if (gaveUp) {
      title = l10n.disconnectedGaveUpTitle;
      // One title, three reasons — because the remedy is what differs, and the
      // remedy is the only part worth reading. `device_unreachable` is the one
      // FB-53 split out of `device_stale`: "walk over to it" and "scan again"
      // are different instructions, and the alarming one used to win by default.
      body = switch (conn.lastError) {
        'device_unreachable' => l10n.devicesConnectFailedUnreachable,
        'device_stale' => l10n.devicesConnectFailedStale,
        // The three refusals. Same strings the device sheet's snackbar shows
        // for the same codes — deliberately, so that "Bluetooth is off" reads
        // identically whichever screen the user happened to be on. Minting a
        // second wording per code is how two screens end up disagreeing about
        // what one state means.
        'bluetooth_off' => l10n.devicesConnectFailedBluetoothOff,
        'bluetooth_unauthorized' =>
          l10n.devicesConnectFailedBluetoothUnauthorized,
        'permission_denied' => l10n.devicesConnectFailedPermission,
        // The vague one, borrowed verbatim from the device sheet's snackbar so
        // that one code reads the same wherever it surfaces. Not
        // `disconnectedGaveUpBody`: "several attempts went by" is a claim, and
        // a single manual tap that failed once did not make several attempts —
        // R3 is precisely the change that stopped it from making them.
        'connect_failed' => l10n.devicesConnectFailed,
        _ => l10n.disconnectedGaveUpBody,
      };
    } else if (retrying) {
      title = l10n.disconnectedRetrying(
          conn.reconnectAttempts, ConnectionController.maxReconnectAttempts);
      body = l10n.disconnectedRetryingBody;
    } else if (conn.isBusy) {
      title = l10n.disconnectedConnecting;
      body = l10n.disconnectedBody;
    } else {
      title = l10n.disconnectedTitle;
      body = l10n.disconnectedBody;
    }

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
            _PulseIcon(working: working),
            const SizedBox(height: 24),
            Text(
              title,
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
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.7,
                  color: context.colors.muted,
                ),
              ),
            ),
            const SizedBox(height: 26),

            if (stalled || gaveUp) ...[
              _AdviceCard(
                hint: stalled
                    ? l10n.disconnectedStalledHint
                    : _radioCodes.contains(conn.lastError)
                        ? l10n.disconnectedGaveUpRadioHint
                        : l10n.disconnectedGaveUpHint,
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

/// The failure that STAYS on screen, with the one thing left to do about it.
///
/// FB-52 built this for the stalled-setup case; FB-53 gives it the three
/// give-up codes as well, because they end the same way — nothing further will
/// happen unless the user does something.
///
/// Deliberately not a SnackBar. FB-44 gives the connect failures a snackbar and
/// that is right for them — they resolve in seconds. These do not: the capture
/// behind the stalled case ran fourteen minutes inside a forty-minute episode,
/// and a 3.2 s toast shown once at minute one is worth nothing to someone still
/// staring at the screen at minute thirty.
///
/// The stalled instruction is the blunt one on purpose (ruled 2026-08-03).
/// "Close the app completely and open it again" is the only action with field
/// evidence behind it — it is what the reporter did, unprompted, and it worked.
/// Telling them to wait would be worse than saying nothing, because waiting is
/// precisely what was already tried for forty minutes.
class _AdviceCard extends StatelessWidget {
  const _AdviceCard({
    required this.hint,
    required this.retryLabel,
    required this.onRetry,
  });

  final String hint;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: context.colors.panel2,
          border: Border.all(color: context.colors.line),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              hint,
              style: TextStyle(
                fontSize: 13,
                height: 1.7,
                color: context.colors.text,
              ),
            ),
            const SizedBox(height: 14),
            InkWell(
              onTap: onRetry,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.amber,
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Text(
                  retryLabel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onAmber,
                  ),
                ),
              ),
            ),
          ],
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

/// Pulsing Bluetooth glyph (mockup `.bigico` + ring animation).
///
/// When [working] it also carries a steady progress ring. Steady is the point:
/// the ring must not blink out during the backoff wait, or it reports "stopped
/// trying" for the majority of a multi-attempt reconnect.
class _PulseIcon extends StatefulWidget {
  const _PulseIcon({required this.working});

  /// An attempt is running or scheduled — see [DisconnectedState].
  final bool working;

  @override
  State<_PulseIcon> createState() => _PulseIconState();
}

class _PulseIconState extends State<_PulseIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 120,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = _c.value;
              return Transform.scale(
                scale: 1 + 0.25 * t,
                child: Opacity(
                  opacity: (0.35 * (1 - t)).clamp(0.0, 1.0),
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: AppColors.amber),
                    ),
                  ),
                ),
              );
            },
          ),
          if (widget.working)
            const SizedBox(
              width: 112,
              height: 112,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.amber,
              ),
            ),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: context.colors.panel,
              border: Border.all(color: context.colors.line),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(Icons.bluetooth, size: 42, color: AppColors.amber),
          ),
        ],
      ),
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
