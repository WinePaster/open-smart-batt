/// OpenSmartBatt — one device's page (design 0046 P1, R21).
///
/// Everything about ONE unit, and the only place controls live (design 0046 R4,
/// inheriting design 0034 §6): connected, this is the dashboard — the same
/// [DashboardPage] the app used to open on, watchface and protection card
/// included. Not connected, it is the FULL failure report: the FB-52 stalled
/// copy, the FB-53 give-up copy, the advice card and its retry button.
///
/// 🔑 That second half is why this page exists at all. Design 0046 R21 moved the
/// per-device status onto the list as ONE WORD, and a one-word status with
/// nowhere to go is FB-53 rebuilt — "the app stopped trying and the only clue
/// was that the spinner had gone". The words come from
/// `connection_failure.dart`, which is the SAME source the dashboard's own
/// disconnected state reads, so the two screens cannot drift into disagreeing
/// about what one error code means.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../dashboard/dashboard_page.dart';
import 'connection_failure.dart';

/// The per-device page, pushed from the devices tab.
class DeviceDetailPage extends StatelessWidget {
  const DeviceDetailPage({
    super.key,
    required this.deviceId,
    this.onOpenSettings,
  });

  /// 🔴 A pure NAVIGATION parameter. It says which unit the user is LOOKING at,
  /// which is a different question from which unit is connected, and design
  /// 0046 §6 R-3 forbids letting it reach any data-attribution path: history
  /// rows, session numbers and export scope all key off the CONNECTED device.
  /// Conflating the two is exactly how FB-41/FB-42 filed one unit's telemetry
  /// under another's, a defect only fixed in v0.6.13.
  final String deviceId;

  /// Handed on to [DashboardPage] for its stale-telemetry banner. See
  /// [DevicesPage.onOpenSettings] for why it is threaded rather than derived.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final devices = context.watch<DeviceController>();
    final conn = context.watch<ConnectionController>();
    final saved = devices.deviceFor(deviceId);
    final l10n = AppLocalizations.of(context);
    final title = (saved?.alias.isNotEmpty ?? false)
        ? saved!.alias
        : l10n.devicesUnnamed;

    // "This unit's live page" is `online AND it is this unit`. Reading only
    // `isOnline` would draw another device's telemetry under this one's name —
    // the same class of mistake as FB-41's session attribution.
    final live = conn.isOnline && conn.connectedDeviceId == deviceId;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: context.colors.text,
          ),
        ),
      ),
      body: live
          ? DashboardPage(onOpenSettings: onOpenSettings)
          : _OfflineBody(deviceId: deviceId),
    );
  }
}

/// The full report for a unit that is not (or not yet) live.
///
/// Layout mirrors the dashboard's own disconnected state on purpose — same
/// glyph, same title/body sizes, same advice card — because they render the same
/// facts and a second visual language for one state is how two screens start
/// disagreeing.
class _OfflineBody extends StatelessWidget {
  const _OfflineBody({required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final conn = context.watch<ConnectionController>();
    final devices = context.watch<DeviceController>();

    // One flag for "the app is working on it", covering both halves of the
    // cycle: the attempt itself (isBusy) and the backoff wait before the next
    // one (isRetrying). Either alone leaves a visible hole.
    final retrying = conn.isRetrying;
    final working = conn.isBusy || retrying;

    // The controller's error/stall state belongs to whichever unit it last
    // worked on. Attributing it to a row the user merely opened would put
    // another device's failure under this one's name, so the copy falls back to
    // the plain idle state unless this IS that unit.
    final mine = conn.connectedDeviceId == deviceId;
    final copy = connectionFailureCopy(
      l10n: l10n,
      lastError: mine ? conn.lastError : null,
      working: mine && working,
      isBusy: mine && conn.isBusy,
      isRetrying: mine && retrying,
      setupStalled: mine && conn.isSetupStalled,
      setupFailures: conn.setupFailures,
      reconnectAttempts: conn.reconnectAttempts,
    );

    final saved = devices.deviceFor(deviceId);

    void retry() {
      if (saved == null) return;
      // `connectToSaved` rather than a bare `connect`: it carries the routing
      // seed, which is the difference between coming back to the same layout
      // and coming back to an unclassified one. The future is absorbed for
      // FB-44's reason — the controller has already recorded the reason in
      // `lastError`, and this widget rebuilds on it.
      unawaited(conn.connectToSaved(saved).catchError((Object _) {}));
    }

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight,
            minWidth: constraints.maxWidth,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 30),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ConnectionPulseIcon(working: mine && working),
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
                    onRetry: retry,
                  ),
                  const SizedBox(height: 26),
                ],
                // The plain way back onto the link when nothing has failed yet.
                // Present in EVERY state, advice card or not: this page is
                // reached from a list whose whole purpose is picking a unit to
                // watch, so "connect" must never require reading a paragraph
                // first.
                if (!copy.hasAdvice)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: (mine && working) || saved == null
                            ? null
                            : retry,
                        icon: const Icon(Icons.bluetooth, size: 16),
                        label: Text(l10n.devicesConnect),
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
