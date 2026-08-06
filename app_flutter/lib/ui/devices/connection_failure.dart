/// OpenSmartBatt — what the app says when a connection attempt has ended.
///
/// Extracted from `ui/dashboard/disconnected_state.dart` (design 0046 Step 1)
/// so the SAME words reach two screens: the dashboard's disconnected placeholder
/// and, from design 0046 onwards, the per-device detail page. Nothing here is
/// new — every set, every branch and every comment below is the FB-52 / FB-53
/// material moved verbatim, because the failure mode this file exists to prevent
/// is losing one of them in the move.
///
/// 🔴 The gatekeeper is `give_up_visibility_test.dart`: it derives the
/// controller's codes from `connection_controller.dart`'s own source and fails
/// if any of them lands nowhere. It is not to be relaxed, and it is why this
/// extraction was done as its own commit with the test count unchanged.
library;

import 'package:flutter/material.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';

/// The `lastError` codes that mean "we have stopped, and nothing else is
/// coming" — as opposed to the ones a retry is already under way for.
///
/// Named here rather than inlined because this set is the contract between the
/// controller and the screens that report it: a give-up code added to
/// [ConnectionController] and not to this set goes back to being invisible,
/// which is the whole FB-53 complaint.
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
const gaveUpCodes = <String>{
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
  // The autoConnect watchdog. Split out of `reconnect_exhausted`, which is a
  // count and belongs to the ladder — this one made no attempts to count.
  'autoconnect_timeout',
  // The three that never reach BLE at all. They are refusals, not failures:
  // `connect()` returns without throwing, so the quick-pick tap handler sees a
  // clean future and there is nothing anywhere else to report them.
  'bluetooth_off',
  'bluetooth_unauthorized',
  'permission_denied',
};

/// The subset of [gaveUpCodes] whose remedy is the phone, not the device.
///
/// They need their own hint because the standing one — "check the unit is
/// nearby and powered, then try again — or scan for it below" — is three
/// instructions that cannot work with the radio down, and the last of them
/// sends the user to a scan that will fail for the same reason.
const radioCodes = <String>{
  'bluetooth_off',
  'bluetooth_unauthorized',
  'permission_denied',
};

/// The four strings a screen needs to report one connection state.
///
/// [adviceHint] is non-null exactly when the attempt has ENDED — the stalled
/// latch or a give-up code — which is also exactly when a retry button has to be
/// on screen. Keeping the two in one object is what stops a caller from drawing
/// the give-up title without the way out of it.
@immutable
class ConnectionFailureCopy {
  const ConnectionFailureCopy({
    required this.title,
    required this.body,
    this.adviceHint,
  });

  final String title;
  final String body;

  /// The advice card's text, or null when nothing has ended yet.
  final String? adviceHint;

  /// Whether the caller must render [ConnectionAdviceCard].
  bool get hasAdvice => adviceHint != null;
}

/// The title / body / advice for a connection state, as one pure function.
///
/// 🔴 THE BRANCH ORDER IS THE SEMANTICS: `stalled → gaveUp → retrying → busy →
/// idle`. `stalled` is a LATCH — only `ready` or switching device clears it —
/// but `lastError` is a single slot, so a manual retry that dies one step
/// earlier (say, a connect timeout) would otherwise overwrite the code and flip
/// the screen to "check the unit is nearby". That advice points the wrong way:
/// the only remedy with field evidence behind it is the stalled card's "close
/// the app fully and reopen it", so as long as the latch is set, the stalled
/// copy wins over whatever failed last (ruled 2026-08-04).
ConnectionFailureCopy connectionFailureCopy({
  required AppLocalizations l10n,
  required String? lastError,
  required bool working,
  required bool isBusy,
  required bool isRetrying,
  required bool setupStalled,
  required int setupFailures,
  required int reconnectAttempts,
}) {
  // FB-52: the link has come up several times and never said anything. This
  // has to outrank the plain "not connected" copy — the user watched the
  // spinner and was told nothing, for forty minutes, in the capture that
  // motivated it. It is gated on `!working` so a manual retry still shows
  // progress: `connect()` clears `lastError`, so the failure only comes back
  // once the retry has failed too.
  final stalled =
      !working && (lastError == 'gatt_setup_stalled' || setupStalled);

  // FB-53: the three ways an attempt can END, which this screen used to sit
  // through in silence. The backoff ladder runs its 60 s, `lastError` is set,
  // `isRetrying` goes false — and the copy falls back to "no device
  // connected", the same words shown before anyone had tapped anything. So
  // the app stopped trying and the only way to find out was that the spinner
  // was gone. Same `!working` gate as `stalled`, for the same reason: a
  // manual retry has to look like progress, and `connect()` clears
  // `lastError`, so the message only returns once the retry has failed too.
  final gaveUp = !working && gaveUpCodes.contains(lastError);

  if (stalled) {
    return ConnectionFailureCopy(
      title: l10n.disconnectedStalledTitle,
      body: l10n.disconnectedStalledBody(setupFailures),
      adviceHint: l10n.disconnectedStalledHint,
    );
  }
  if (gaveUp) {
    return ConnectionFailureCopy(
      title: l10n.disconnectedGaveUpTitle,
      // One title, three reasons — because the remedy is what differs, and the
      // remedy is the only part worth reading. `device_unreachable` is the one
      // FB-53 split out of `device_stale`: "walk over to it" and "scan again"
      // are different instructions, and the alarming one used to win by default.
      body: switch (lastError) {
        'device_unreachable' => l10n.devicesConnectFailedUnreachable,
        'device_stale' => l10n.devicesConnectFailedStale,
        // Not `disconnectedGaveUpBody` — see the note on the code itself. The
        // hand-off makes no attempts of ours, so "several attempts went by"
        // would be inventing work.
        'autoconnect_timeout' => l10n.disconnectedGaveUpAutoConnect,
        // The three refusals. Same strings the device list's snackbar shows
        // for the same codes — deliberately, so that "Bluetooth is off" reads
        // identically whichever screen the user happened to be on. Minting a
        // second wording per code is how two screens end up disagreeing about
        // what one state means.
        'bluetooth_off' => l10n.devicesConnectFailedBluetoothOff,
        'bluetooth_unauthorized' =>
          l10n.devicesConnectFailedBluetoothUnauthorized,
        'permission_denied' => l10n.devicesConnectFailedPermission,
        // The vague one, borrowed verbatim from the device list's snackbar so
        // that one code reads the same wherever it surfaces. Not
        // `disconnectedGaveUpBody`: "several attempts went by" is a claim, and
        // a single manual tap that failed once did not make several attempts —
        // R3 is precisely the change that stopped it from making them.
        'connect_failed' => l10n.devicesConnectFailed,
        _ => l10n.disconnectedGaveUpBody,
      },
      adviceHint: radioCodes.contains(lastError)
          ? l10n.disconnectedGaveUpRadioHint
          : l10n.disconnectedGaveUpHint,
    );
  }
  if (isRetrying) {
    return ConnectionFailureCopy(
      title: l10n.disconnectedRetrying(
          reconnectAttempts, ConnectionController.maxReconnectAttempts),
      body: l10n.disconnectedRetryingBody,
    );
  }
  if (isBusy) {
    return ConnectionFailureCopy(
      title: l10n.disconnectedConnecting,
      body: l10n.disconnectedBody,
    );
  }
  return ConnectionFailureCopy(
    title: l10n.disconnectedTitle,
    body: l10n.disconnectedBody,
  );
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
class ConnectionAdviceCard extends StatelessWidget {
  const ConnectionAdviceCard({
    super.key,
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

/// Pulsing Bluetooth glyph (mockup `.bigico` + ring animation).
///
/// When [working] it also carries a steady progress ring. Steady is the point:
/// the ring must not blink out during the backoff wait, or it reports "stopped
/// trying" for the majority of a multi-attempt reconnect.
class ConnectionPulseIcon extends StatefulWidget {
  const ConnectionPulseIcon({super.key, required this.working});

  /// An attempt is running or scheduled — see [connectionFailureCopy].
  final bool working;

  @override
  State<ConnectionPulseIcon> createState() => _ConnectionPulseIconState();
}

class _ConnectionPulseIconState extends State<ConnectionPulseIcon>
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
