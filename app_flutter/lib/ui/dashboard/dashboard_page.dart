/// OpenSmartBatt — dashboard screen + product-class router (mockup `#page-dash`).
///
/// 📦 Since design 0046 this page is the body of ONE DEVICE'S detail page, and
/// it no longer owns the "nothing is connected" case: the detail page decides
/// that, because after 0046 the question is "is THIS unit live" rather than "is
/// anything live". [DisconnectedState] is still the dashboard's own empty state
/// and is still exercised by `give_up_visibility_test.dart` /
/// `setup_stall_test.dart` / `waiting_states_test.dart`; what moved is who
/// chooses to show it.
///
/// [DashboardRouter] picks the view from the device-type
/// byte the unit reports — the ONLY deterministic signal there is: a confirmed
/// power bank (device-type 0x22) gets [PowerBankView]; a confirmed pack
/// (super-capacitor or smart battery) gets the data-driven [PackView]; a unit
/// that has not said what it is yet gets [ClassPendingView] and NO layout at
/// all — every layout here asserts a class, so withholding one is the only
/// honest option while the class is undetermined.
/// The cosmetic super-capacitor-vs-battery label NEVER influences this choice.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'capture_mark_bar.dart';
import 'class_pending_view.dart';
import 'pack_view.dart';
import 'unidentified_view.dart';
import 'power_bank_view.dart';

/// Dashboard body (intended to sit inside the app shell's [Scaffold] body).
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, this.onOpenSettings});

  /// Switch to the Settings tab. The stale banner links there, because that is
  /// where the platform-specific explanation now lives — next to the
  /// "background monitoring" switch it is about, with one text for Android
  /// (exclude the app from battery optimisation) and a different one for iOS
  /// (background monitoring does not exist there; keep the app in the
  /// foreground). The banner itself only states what is happening, and says
  /// nothing about how to fix it: it has no platform knowledge, and when it
  /// tried to have some it told every iOS user to change an Android-only
  /// setting.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    // A stall is not a disconnect: the link stays ready while Android suspends
    // the app, so the readouts below would otherwise sit frozen with no hint.
    final stalled =
        context.select<TelemetryController, bool>((c) => c.telemetryStalled);
    // The banner no longer branches on `monitorRunning`. It said one of two
    // things depending on whether the foreground service was up — and BOTH
    // pointed at Android-only remedies, while `_monitorRunning` has no platform
    // check and the setting defaults to on, so every connected iOS user got the
    // "battery optimisation" advice for a setting that is a no-op there
    // (FB-26). Platform differences now live in exactly one place: Settings.
    return Column(
      children: [
        if (stalled) _StaleBanner(onOpenSettings: onOpenSettings),
        const Expanded(child: DashboardRouter()),
        // Renders only while raw packet logging is on: it stamps user-supplied
        // ground truth into the capture, and a mark with no packets beside it
        // correlates with nothing. Rationale for the gate is in the widget.
        const CaptureMarkBar(),
      ],
    );
  }
}

/// Freshness note for the readings below — NOT a warning.
///
/// It carries the AGE of the newest sample rather than an adjective: "paused"
/// is a state, "24 seconds ago" is a fact, and it climbs. That distinction is
/// what tells a user whether to ignore it (12 s) or act on it (6 min), and it
/// survives into screenshots, which is how we read field reports.
///
/// Colour is deliberately neutral with an amber icon, not an amber fill: the
/// fault banner and the nav indicator already use amber at α=0.16, and a third
/// amber bar would flatten the severity ordering we just fixed. Its real
/// prominence is structural — full width, pinned above the readings, not
/// dismissible.
class _StaleBanner extends StatefulWidget {
  const _StaleBanner({this.onOpenSettings});

  final VoidCallback? onOpenSettings;

  @override
  State<_StaleBanner> createState() => _StaleBannerState();
}

class _StaleBannerState extends State<_StaleBanner> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Ticks this widget only. Making the controller notify every second while
    // stalled would rebuild the whole dashboard subtree — gauge, readouts,
    // controls — none of which is changing. The rebuild should be exactly as
    // wide as the text that moves.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Seconds-resolution age. `disconnected_state.dart`'s helper collapses
  /// anything under a minute to "just now", which is useless for a banner that
  /// appears after 8 seconds.
  String _age(AppLocalizations l10n, Duration? d) {
    if (d == null) return l10n.gaugeSohUnknown;
    if (d.inMinutes < 1) return l10n.relativeSecondsAgo(d.inSeconds);
    if (d.inHours < 1) return l10n.relativeMinutesAgo(d.inMinutes);
    return l10n.relativeHoursAgo(d.inHours);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    final age = context.read<TelemetryController>().telemetryAge;
    return Material(
      color: colors.panel2,
      child: InkWell(
        onTap: widget.onOpenSettings,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Row(
            children: [
              // "Pause glyph in amber" is the app's one idiom for "what you
              // are looking at is not live" — here for stale telemetry, in
              // `speed_card.dart`'s held badge for a frozen reading. Fixed
              // (design 0064): both sites must keep saying it the same way,
              // and neither is a brand surface.
              const Icon(Icons.pause_circle_outline,
                  size: 18, color: AppSemantics.warn),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.dashboardTelemetryStale(_age(l10n, age)),
                  style: TextStyle(fontSize: 11.5, color: colors.muted),
                ),
              ),
              if (widget.onOpenSettings != null)
                Icon(Icons.chevron_right, size: 16, color: colors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Picks the live view from the deterministic routing decision. Reads
/// [ConnectionController.routing] — derived from the SAME resolver that drives
/// persistence and capability gating, so the product class has exactly one
/// source of truth and the chosen layout can never disagree with the stored
/// class or with which buttons are on screen. The cosmetic pack label is never
/// consulted here.
///
/// This used to be `isPowerBank ? PowerBankView : PackView`. A bool cannot
/// express "not yet known", so that form silently routed an unidentified unit
/// to the pack layout — and the pack layout leads with a 12 V terminal-voltage
/// gauge. FB-43's field screenshot is a power bank in exactly that state, its
/// single-cell 3.79 V presented as a pack's main voltage.
class DashboardRouter extends StatelessWidget {
  const DashboardRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final routing =
        context.select<ConnectionController, RoutingDecision>((c) => c.routing);
    // Exhaustive on purpose, and that is why [RoutingDecision] is an enum: when
    // the pack shell is split into battery and capacitor, this switch stops
    // compiling until every site has chosen, rather than defaulting one of them
    // somewhere silently.
    switch (routing) {
      case RoutingDecision.powerBank:
        return const PowerBankView();
      case RoutingDecision.pack:
        return const PackView();
      // 🔴 design 0050 D8. This used to fall through to `PackView` — an
      // unidentified unit drawn with the battery's cards. See
      // `unidentified_view.dart` for why that is the FB-43 shape and why
      // naming the class is our job rather than the owner's.
      case RoutingDecision.unclassified:
        return const UnidentifiedView();
      case RoutingDecision.pending:
        return const ClassPendingView();
    }
  }
}
