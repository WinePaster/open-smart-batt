/// OpenSmartBatt — the device detail page's warning banner (design 0080 P3,
/// §5 「詳情頁事件橫幅」 and §0.2.1).
///
/// ## 🔴 It is drawn for an UNSAVED unit too
///
/// That is ruling Q3, and it is the reason the banner is a separate widget from
/// anything in `alert_settings_page.dart`: the settings SCREEN needs a
/// `saved_devices` row to write to, and this needs nothing at all. §0.2.1 lays
/// the three layers out — threshold resolution, on-screen rendering, and the
/// notification — and says only the last is gated. An unsaved unit whose own
/// `0x2B` says 11.0 V and which is reading 10.8 gets the banner; what it does
/// not get is a phone that rings, because there is no alias to title the
/// notification with and nowhere to keep a mute.
///
/// The banner says so, in as many words, instead of leaving the user to notice
/// the absence: [AppLocalizations.alertsBannerUnsavedNote]. Same for a paused
/// unit and for the global switch being off — three different reasons for the
/// same silence, and a user who is not told which one applies has to guess.
///
/// ## Why the reading comes from telemetry and the rest from the controller
///
/// [AlertEvent] deliberately carries no live reading (see its doc): it would
/// have to change several times a second and notify every listener at that
/// rate. So the banner watches [TelemetryController] for the number — which it
/// would be rebuilding for anyway — and [AlertController] for what is raised,
/// since when, and against which limit. One consequence worth knowing: the
/// "for 3 min" line re-renders on the telemetry cadence, so it stays honest
/// without a `Timer` anywhere in this feature.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial.dart';
import 'alert_settings_page.dart';

/// The raised-warning block for one unit, or nothing at all.
///
/// Renders an empty box when nothing is raised — including while a breach is
/// still `pending`, which [AlertEvaluator.activeAlerts] excludes on purpose:
/// showing a breach we have not yet decided to believe would put the debounce
/// on screen and undo it.
class AlertEventBanner extends StatelessWidget {
  const AlertEventBanner({super.key, required this.deviceId});

  /// The unit this banner is about — never "whoever is connected" (§3.9).
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final alerts = context.watch<AlertController>();
    final events = alerts.eventsFor(deviceId);
    if (events.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    final devices = context.watch<DeviceController>();
    final settings = context.watch<SettingsController>();
    final saved = devices.deviceFor(deviceId);
    final now = DateTime.now();

    // Which of the three silences applies, if any. Ordered broadest-first, the
    // same order `AlertGate.evaluate` uses and for its reason: the sentence the
    // user is shown should be the one that explains the most and is furthest
    // from where they are standing.
    final String? quietNote;
    if (!settings.settings.alertsEnabled) {
      quietNote = l10n.alertsBannerGloballyOffNote;
    } else if (saved == null) {
      // 🔵 design 0086 S3 — the brief form, because `_UnsavedNotice` is drawn
      // directly below this and already says "not saved". The screenshot that started
      // 0086 had that sentence twice on one screen. What the card does NOT say
      // is that the phone stays silent, so that half is kept.
      quietNote = l10n.alertsBannerUnsavedNoteBrief;
    } else if (!saved.alertEnabled ||
        saved.isMutedAt(now) ||
        alerts.isSessionSilenced(deviceId)) {
      quietNote = l10n.alertsBannerSilencedNote;
    } else {
      quietNote = null;
    }

    // 🔵 design 0086 — collapsed to one line, on the owner's ruling
    // 「警告的那個block可以打Ｘ縮小 然後再點警告會跳出來」.
    //
    // 🔴 Collapsed is NOT dismissed, and that distinction is what keeps this
    // compatible with design 0080 §5. The line stays where the block was —
    // above the dashboard, outside its ListView, still carrying the danger
    // colour — so 0080's premise ("people are not looking at the screen; a
    // raised warning must not be something you scroll to find") is untouched.
    // A version of this that removed the row, or moved it behind a bell in the
    // title bar, would need that ruling overturned first (mockup option C).
    if (alerts.isBannerCollapsed(deviceId)) {
      return _collapsed(context, l10n, tele, events, alerts);
    }

    return IndustrialCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 16, color: AppSemantics.danger),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  l10n.alertsBannerHeading,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppSemantics.danger,
                  ),
                ),
              ),
              // 🔵 Only for a saved unit, matching `AlertSettingsEntry`: the
              // page it opens writes to columns an unsaved unit has no row for.
              // The entry row below (which runs the naming prompt instead) is
              // still on screen, so the route is not lost — this is a shortcut,
              // not the only door.
              if (saved != null)
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => AlertSettingsPage(deviceId: deviceId),
                  )),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l10n.alertsBannerOpen,
                      style: TextStyle(
                          fontSize: 11.5, color: context.accent.accent)),
                ),
              // design 0086. 40x40 because that is this codebase's floor for an
              // icon target (FB-70 is the entry that cost a user over a 14x14
              // control) — see `kDetailTabBarHeight` for the same reasoning.
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 16),
                color: context.colors.muted,
                tooltip: l10n.alertsBannerCollapse,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: () => alerts.setBannerCollapsed(deviceId, true),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final e in events) ...[
            Text(
              _row(l10n, e, tele),
              style: AppTextStyles.mono(context)
                  .copyWith(fontSize: 11.5, color: context.colors.text),
            ),
            const SizedBox(height: 2),
            Text(
              l10n.alertsBannerFor(formatAlertDuration(l10n, e.ageAt(now))),
              style: TextStyle(fontSize: 10.5, color: context.colors.muted),
            ),
            const SizedBox(height: 6),
          ],
          if (quietNote != null)
            Text(
              quietNote,
              style: TextStyle(
                  fontSize: 11, height: 1.55, color: context.colors.muted),
            ),
        ],
      ),
    );
  }

  /// The collapsed form: one tappable line that still shows severity.
  ///
  /// Carries three things and nothing else — the colour (so it reads without
  /// being read), the worst row (so it says *what*), and a `+n` when more than
  /// one is raised (so collapsing never hides a count). Tapping anywhere on it
  /// expands; there is no separate control, because the owner's words were
  /// 「再點警告會跳出來」 — the warning itself is the target.
  Widget _collapsed(
    BuildContext context,
    AppLocalizations l10n,
    TelemetryController tele,
    List<AlertEvent> events,
    AlertController alerts,
  ) {
    final rest = events.length - 1;
    return Semantics(
      button: true,
      label: l10n.alertsBannerExpand,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => alerts.setBannerCollapsed(deviceId, false),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: AppSemantics.danger.withValues(alpha: 0.12),
            border: Border.all(
                color: AppSemantics.danger.withValues(alpha: 0.42)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                    color: AppSemantics.danger, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _row(l10n, events.first, tele),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.mono(context)
                      .copyWith(fontSize: 11.5, color: context.colors.text),
                ),
              ),
              if (rest > 0) ...[
                const SizedBox(width: 6),
                Text(
                  l10n.alertsBannerMore('$rest'),
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppSemantics.danger),
                ),
              ],
              const SizedBox(width: 6),
              Icon(Icons.expand_more_rounded,
                  size: 16, color: context.colors.muted),
            ],
          ),
        ),
      ),
    );
  }

  /// One line: what is wrong, what it reads now, and what it is being judged
  /// against.
  ///
  /// 🔑 All three, because two of them alone are useless. "Under-voltage" says
  /// nothing about severity; "10.82 V" says nothing about whether that is bad
  /// on this unit. The notification body carries the same triple for the same
  /// reason (§3.5.3).
  String _row(
    AppLocalizations l10n,
    AlertEvent e,
    TelemetryController tele,
  ) {
    final label = kindLabel(l10n, e.kind);
    // The live reading, through the SAME extractor the state machine stepped on
    // — see [AlertKind.readingIn]. A dash where this frame said nothing about
    // the quantity: the event is still raised (a `0x21` frame carrying no PVLT
    // does not clear an under-voltage), and inventing a number for the gap
    // would be the one thing worse than an empty field.
    final reading = e.kind.readingIn(tele.sample);
    final now = reading == null
        ? '--'
        : (e.kind.isVoltage ? formatVolts(reading) : formatCelsius(reading));
    final limit =
        e.kind.isVoltage ? formatVolts(e.threshold) : formatCelsius(e.threshold);
    return e.kind.isVoltage
        ? l10n.alertsBannerRowVolts(label, now, limit)
        : l10n.alertsBannerRowCelsius(label, now, limit);
  }
}

/// "45 s" / "12 min" / "2 h 05 min".
///
/// Three scales rather than one, because the same string has to be readable at
/// both ends of an event's life: a warning is worth reading at ten seconds old
/// and at three hours old, and "10800 s" answers the wrong question. Seconds
/// are dropped past the first minute deliberately — a banner that ticked every
/// second would be the only thing on the page a user could not stop watching.
String formatAlertDuration(AppLocalizations l10n, Duration d) {
  if (d.inMinutes < 1) {
    return l10n.alertsBannerDurationSeconds('${d.inSeconds < 0 ? 0 : d.inSeconds}');
  }
  if (d.inHours < 1) return l10n.alertsBannerDurationMinutes('${d.inMinutes}');
  return l10n.alertsBannerDurationHours(
      '${d.inHours}', '${d.inMinutes % 60}'.padLeft(2, '0'));
}
