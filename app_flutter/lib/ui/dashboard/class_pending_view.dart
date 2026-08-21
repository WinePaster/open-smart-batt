/// OpenSmartBatt — "we do not know what this is yet" placeholder.
///
/// Drawn instead of a layout while [RoutingDecision.pending] holds. It shows
/// NOTHING that depends on the product class — no PVLT gauge, no SVLT, no DVOL
/// bars, no USB ports, no class-gated controls.
///
/// That restraint is the entire point. The field report this comes from
/// (a 2026-07-31 field capture) is a screenshot of a power bank whose
/// SINGLE-CELL 3.79 V was drawn as a pack terminal voltage under the label
/// "PVLT 主電壓", on a gauge whose formula pins anything that low to the
/// bottom of its sweep. Every number on that screen was real; the screen was
/// still false, because it asserted a class nobody had established.
///
/// Three states, in order of how long the wait has run:
///
/// 1. under [kClassPendingGrace] — draw nothing. A healthy link answers in
///    well under a second (p50 0.061 s across a day of field logs), so a
///    placeholder here would flash on every connect.
/// 2. under [kClassPendingTimeout] — "identifying device".
/// 3. past it — offer a way out, and say WHY when we know: a non-zero
///    keep-alive failure count is the difference between "this is taking a
///    while" and "our polls are not getting out at all".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../widgets/one_screen_report.dart';

/// Placeholder shown while the product class is undetermined.
class ClassPendingView extends StatefulWidget {
  const ClassPendingView({super.key, required this.deviceId});

  /// The unit this page is about — see [DashboardPage.deviceId].
  ///
  /// 📌 This state is brief — most connects resolve the class in well under a
  /// second — but the unit's stored history is not, so there is something to
  /// show here too (design 0065 §0.4).
  final String deviceId;

  @override
  State<ClassPendingView> createState() => _ClassPendingViewState();
}

class _ClassPendingViewState extends State<ClassPendingView> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The view's content is a function of elapsed time, and nothing else
    // notifies on the passage of time. Coarse on purpose: the two thresholds
    // are 500 ms and 6 s, so a quarter-second tick resolves both without
    // rebuilding on every frame.
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final conn = context.watch<ConnectionController>();
    final elapsed = conn.pendingFor ?? Duration.zero;

    // Grace window: deliberately empty, NOT a spinner. A spinner that appears
    // and vanishes inside the grace window reads as a glitch, and there is
    // nothing to hide — the pack layout is not drawn underneath either.
    if (elapsed < kClassPendingGrace) return const SizedBox.shrink();

    final stalled = elapsed >= kClassPendingTimeout;
    // FB-20: a keep-alive failure count alone does NOT mean the link is
    // unstable. A power bank's single GATT write takes 3.96-4.95 s to complete
    // (4,029 measured intervals, four units, 0.6.11-0.6.14), and our write
    // timeout is 5 s — so ~11.6 per 1000 of its writes cross the line while the
    // unit is answering perfectly well. Reporting that as "connection unstable"
    // is a misdiagnosis of the healthiest failure mode we have.
    //
    // The class cannot be the discriminator here: this view is drawn precisely
    // BECAUSE the class is still unknown, so `isPowerBank` is false for the one
    // case that needs it. What separates the two is whether anything is coming
    // back at all — a slow-writing power bank still pushes 0x19/0x20/0x21/0x37
    // at 1.3-1.65 Hz, while the genuinely stuck link the "unstable" copy was
    // written for produced nothing.
    //
    // Note this is `hasTelemetry`, not `telemetryStalled` and not
    // `telemetryAge`: the stall threshold is 8 s and this view gives up at 6 s,
    // so a stall has not been declared yet when the copy is chosen — and
    // `telemetryAge` is seeded at `ready`, so it is non-null even for a link
    // that never spoke. Only the frame count answers the question being asked.
    final heardFromIt = context.watch<TelemetryController>().hasTelemetry;
    final failures = heardFromIt ? 0 : conn.keepAliveFailures;

    final String title;
    final String body;
    if (!stalled) {
      title = l10n.classPendingTitle;
      body = l10n.classPendingBody;
    } else if (failures > 0) {
      // We know why. Say so — "connection unstable, N polls unanswered" is
      // actionable in a way that "cannot determine device type" is not.
      title = l10n.classPendingStalledTitle;
      body = l10n.classPendingStalledBody(failures);
    } else {
      title = l10n.classPendingTimeoutTitle;
      body = l10n.classPendingTimeoutBody;
    }

    return OneScreenReport(
      // The wait is brief; the unit's stored history is not. Same reasoning as
      // `unidentified_view.dart` — the rows are attributed by session, not by
      // class, so there is something here to show while the class is still
      // unknown (design 0065 §0.4).
      // 🔵 **Design 0079 S1 (2026-08-21)** — see `unidentified_view.dart`.
      // ~~below: DeviceHistorySection(deviceId: widget.deviceId, live: true)~~
      report: [
        _PendingGlyph(stalled: stalled),
        const SizedBox(height: 22),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            letterSpacing: 0.5,
            fontWeight: FontWeight.w700,
            color: context.colors.text,
          ),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.7,
              color: context.colors.muted,
            ),
          ),
        ),
        if (stalled) ...[
          const SizedBox(height: 26),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed:
                        conn.isBusy ? null : () => conn.reconnectCurrent(),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(l10n.classPendingRetryButton),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                // 🔴 「仍要顯示讀數（未分類）」 was REMOVED here on
                // 2026-08-08 (design 0050 D3). It landed on the
                // unclassified pack shell — which was field for field
                // the battery's card set, so "show them anyway" meant
                // "assert a class nobody established". That is the
                // FB-43 shape, and the whole reason this view exists.
                //
                // Retrying is what remains, because it is the only
                // action that can actually change the answer.
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Amber chip glyph; steady while identifying, warning-tinted once stalled.
class _PendingGlyph extends StatelessWidget {
  const _PendingGlyph({required this.stalled});

  final bool stalled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (!stalled)
            SizedBox(
              width: 92,
              height: 92,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: context.accent.accent,
              ),
            ),
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: context.colors.panel,
              border: Border.all(color: context.colors.line),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              stalled ? Icons.help_outline : Icons.memory,
              size: 34,
              color: context.accent.accent,
            ),
          ),
        ],
      ),
    );
  }
}
