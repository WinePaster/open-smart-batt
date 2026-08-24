/// OpenSmartBatt — one unit's warning settings, and the row that opens them
/// (design 0080 §3.7.1, P2).
///
/// ## Why this is a per-DEVICE screen and not a Settings section
///
/// The original request said "put it in the Settings tab". Ruling B made the
/// thresholds per unit, and that changes where the screen belongs: a global page
/// would have to open with a device picker, and the picker is exactly what a
/// device's own page does not need — you are already on the unit. So the four
/// GLOBAL parameters (how long, how often, how many) stay in Settings and
/// everything that is about ONE battery lives here.
///
/// ## The ~~four~~ three states this screen has to draw, and why they are three
///
/// They come straight from the mockup and from §7.5.6 C-3, and the thing worth
/// keeping straight is that TWO of them look like "no warnings" and mean
/// entirely different things:
///
///   * **A — every row from the device.** The ordinary case: the unit reported
///     `0x2B`, three 「裝置回報」 badges, the user has to do nothing. 🔵 Since
///     2026-08-25 this is also the ONLY thing a user can do about a threshold:
///     read it.
///   * ~~**B — the user changed one field.** That row alone becomes 「自訂」 and
///     accented, with the device's own value still shown beside a 「還原」.~~
///     🔵 **Gone 2026-08-25 (FB-100, design 0080 §0.3): the thresholds are
///     READ-ONLY.** The dealer read the editable rows as the app changing the
///     hardware's protection points, and the owner ruled the fix is to stop
///     offering the edit — read `0x2B`, fall back to the table, take nothing
///     from the user. Two defects left with it: the dialog had no bounds at all
///     (an under-voltage of 5.0 V silenced the alarm with nothing on screen
///     saying so), and 「出廠值 X」 was never actually wired up, so an edited row
///     hid the very number it had replaced. Three states remain: A, C and D.
///   * **C — the device type is not recognised.** The whole page is disabled
///     (§7.5.6 C-2, "no exceptions": not even a reported `0x2B`, not even a
///     value the user typed). 🔴 **Only [AlertsDisabledReason.deviceTypeUnrecognised]
///     may draw this.** Its sibling [AlertsDisabledReason.deviceTypePending] is
///     the first few frames of EVERY connection, and a screen that flashed
///     「無法提供警告」 there would raise a false alarm about the alarms on every
///     single connect — which is why [_PendingBody] exists and says something
///     else entirely.
///   * **D — a power bank.** ONE row, over-temperature. The two voltage rows are
///     **absent, not greyed** (§3.2.2 verbatim: 「不是顯示成灰色停用 —— 那會讓
///     使用者以為是自己少設了什麼」), and the 50 °C carries an 「App 預設」 badge
///     because it is the one number in the table nobody measured.
///
/// ## What P2 does NOT do
///
/// Nothing here evaluates anything and nothing here notifies. `AlertEvaluator`
/// still has no caller (§5, P2/P3 boundary): the two mute controls store their
/// state and stop there, because the gate they feed is the same gate the
/// notifier needs, and building it twice is how one gate ends up with two
/// versions.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../devices/save_device_flow.dart';
import '../util/alert_thresholds_lookup.dart';
import '../widgets/industrial.dart';

// The two value formatters moved to the models layer in P3 (see the note at the
// foot of this file); re-exported so the four call sites that already import
// this page keep reaching them by the same name.
export 'package:open_smart_batt/models/alert_thresholds.dart'
    show formatVolts, formatCelsius;

// 🔵 **`kAlertNearVolts` / `kAlertNearCelsius` removed 2026-08-25 (FB-100).**
// They existed for §6.2's 「設定值離目前讀數過近時就地提示」, which only ever
// fired on a value the USER had typed — a threshold the DEVICE reports sitting
// near today's reading is information about the hardware, not a mistake anyone
// just made. With no user values there is nothing left for the notice to warn
// about, so both the notice and its two constants go rather than linger as a
// rule with no input. The derivation is worth keeping on the record in case a
// later ruling brings editing back: each was 2 × §3.3's release band
// (0.3 V / 3 °C), on the reasoning that one band inside the reading is an alarm
// that can never clear and two is one you are about to build.

/// The mute window offered by 「靜音 1 小時」 (§3.4 gate ②).
const Duration kAlertMuteWindow = Duration(hours: 1);

// ---------------------------------------------------------------------------
// Entry row — device detail page
// ---------------------------------------------------------------------------

/// The 「警告通知」 row on a unit's page (mockup §1.1, right-hand phone).
///
/// 🔴 **An unsaved unit gets the row but not the screen** (§3.6.3). Both halves
/// matter and they pull in opposite directions:
///
///   * showing it is the point — design 0055 made "connected but never named"
///     an ordinary way to use the app, and a feature that is simply INVISIBLE
///     there is one the user cannot discover, ask about, or work out they are
///     missing;
///   * not opening it is forced by the data — layer ①, the per-device switch and
///     the mute instant are all columns of `saved_devices`, and an unsaved unit
///     has no row to put them in. So the tap runs the naming prompt instead of
///     pushing a screen whose every control would silently discard its input.
///
/// It deliberately does NOT save the device by itself. Quietly adding a record
/// as a side effect of opening a settings screen is the position
/// `DeviceController.setDisplayLayout` already refused: a unit the user declined
/// to name is one they declined to remember.
class AlertSettingsEntry extends StatelessWidget {
  const AlertSettingsEntry({super.key, required this.deviceId});

  /// The unit this row is about — never "whoever is connected" (§3.9).
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final devices = context.watch<DeviceController>();
    final saved = devices.deviceFor(deviceId);
    final thresholds = watchAlertThresholds(context, deviceId);
    final wireClass = watchAlertWireClass(context, deviceId);

    final sub = saved == null
        ? l10n.alertsEntrySummaryUnsaved
        : _summary(l10n, thresholds, wireClass);

    // Composed rather than built from `SettingsLinkRow`: that widget has no
    // sub-caption slot, and its five other callers do not want one — widening
    // its API for this one surface would be the cheaper change and the wrong
    // one, because a `sub` nobody else passes is a parameter that rots.
    return IndustrialCard(
      padding: const EdgeInsets.fromLTRB(13, 4, 13, 4),
      child: InkWell(
        onTap: () => unawaited(_open(context, saved != null)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
          child: Row(
            children: [
              Icon(Icons.notifications_active_outlined,
                  size: 15, color: context.accent.accentSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.alertsEntryTitle,
                        style: TextStyle(
                            fontSize: 13.5, color: context.colors.text)),
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.45,
                          color: context.colors.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (saved != null) _EntryBadge(saved: saved),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 16, color: context.colors.muted),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, bool saved) async {
    if (!saved) {
      // §3.6.3 — name it first. `promptAndSaveDevice` is design 0055's own
      // dialog, so the two entrances to naming a unit cannot describe it
      // differently.
      await promptAndSaveDevice(context, deviceId);
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AlertSettingsPage(deviceId: deviceId),
    ));
  }

  static String _summary(
    AppLocalizations l10n,
    AlertThresholds t,
    ProductClass wireClass,
  ) {
    if (t.disabledReason == AlertsDisabledReason.deviceTypeUnrecognised) {
      return l10n.alertsEntrySummaryUnrecognised;
    }
    if (!alertVoltageWatched(wireClass)) {
      return t.ot.isSet
          ? l10n.alertsEntrySummaryTempOnly(formatCelsius(t.ot.value!))
          : l10n.alertsEntrySummaryUnknown;
    }
    if (t.ov.isSet && t.uv.isSet && t.ot.isSet) {
      return l10n.alertsEntrySummaryFull(
        formatVolts(t.uv.value!),
        formatVolts(t.ov.value!),
        formatCelsius(t.ot.value!),
      );
    }
    // 🔴 Never "no limits". `0x2B` is persisted nowhere (§7.5.2), so an offline
    // unit's factory limits are genuinely unknown rather than absent — and the
    // copy has to say which of the two it is.
    return l10n.alertsEntrySummaryUnknown;
  }
}

/// On / Off / Muted, for the entry row's right edge.
class _EntryBadge extends StatelessWidget {
  const _EntryBadge({required this.saved});

  final SavedDevice saved;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The clock is read once, here, rather than by the model — see
    // [SavedDevice.isMutedAt]. Nothing on this row ticks: a badge that had to
    // re-render on the minute would put a timer on the dashboard for a word.
    final muted = saved.isMutedAt(DateTime.now());
    final (label, color) = muted
        ? (l10n.alertsEntryBadgeMuted, AppSemantics.warn)
        : saved.alertEnabled
            ? (l10n.alertsEntryBadgeOn, AppSemantics.good)
            : (l10n.alertsEntryBadgeOff, context.colors.muted);
    return _Pill(label: label, color: color);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: color,
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------

/// One unit's warning settings (design 0080 §3.7.1).
class AlertSettingsPage extends StatefulWidget {
  const AlertSettingsPage({super.key, required this.deviceId});

  final String deviceId;

  @override
  State<AlertSettingsPage> createState() => _AlertSettingsPageState();
}

class _AlertSettingsPageState extends State<AlertSettingsPage> {
  // 🔵 **P3 moved gate ③ off this widget** (§7.6.4 hand-over 1).
  //
  // ~~bool _sessionMuted = false;~~ — 「本次連線不再提醒」 used to live here,
  // because P2 had no object that could observe a connection. That made it die
  // when the user popped the page, and §3.4 asks for it to die when the LINK
  // does; the two are different by exactly the amount that matters, since
  // reading the mute setting is the most likely reason to leave the page.
  //
  // It now lives on [AlertController], beside the evaluator whose emissions it
  // suppresses. Still memory-only: the asymmetry with the 1-hour mute (which IS
  // persisted) is the design, not an omission — "for an hour" is a promise
  // about wall-clock time and must survive a restart; "not again this
  // connection" ends when the connection does.

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final devices = context.watch<DeviceController>();
    final saved = devices.deviceFor(widget.deviceId);
    final thresholds = watchAlertThresholds(context, widget.deviceId);
    final wireClass = watchAlertWireClass(context, widget.deviceId);
    final tele = context.watch<TelemetryController>();
    final live = tele.recordingDeviceId == widget.deviceId;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.alertsPageTitle,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                height: 1.25,
                color: context.colors.text,
              ),
            ),
            if (saved != null && saved.alias.isNotEmpty)
              Text(
                saved.alias,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.mono(context)
                    .copyWith(fontSize: 10.5, color: context.colors.muted),
              ),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
            children: _body(
              l10n: l10n,
              saved: saved,
              thresholds: thresholds,
              wireClass: wireClass,
              tele: tele,
              live: live,
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body({
    required AppLocalizations l10n,
    required SavedDevice? saved,
    required AlertThresholds thresholds,
    required ProductClass wireClass,
    required TelemetryController tele,
    required bool live,
  }) {
    // The unit stopped being saved under us (deleted from another screen).
    // Nothing here has anywhere to write, so say the same thing the entry row
    // says rather than drawing controls that discard their input.
    if (saved == null) return const [_UnsavedBody()];

    // 🔴 State C, and ONLY for the durable reason. See the library comment.
    if (thresholds.disabledReason ==
        AlertsDisabledReason.deviceTypeUnrecognised) {
      return [_UnrecognisedBody(deviceType: tele.sample.deviceType)];
    }

    final voltage = alertVoltageWatched(wireClass);
    final kinds = <AlertKind>[
      if (voltage) AlertKind.overVoltage,
      if (voltage) AlertKind.underVoltage,
      AlertKind.overTemperature,
    ];

    return [
      IndustrialCard(
        child: SettingsRow(
          label: l10n.alertsDeviceSwitchTitle,
          sub: voltage
              ? l10n.alertsDeviceSwitchSub
              : l10n.alertsDeviceSwitchSubTempOnly,
          last: true,
          trailing: Switch(
            value: saved.alertEnabled,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) => unawaited(_write(saved.copyWith(alertEnabled: v))),
          ),
        ),
      ),

      // 🔴 The TRANSIENT state, and it must not borrow state C's words
      // (§7.5.6 C-3 / landmine 2). Reached only when no byte has arrived AND no
      // class was ever persisted, which is the first frames of a connection to a
      // unit nobody has classified yet.
      if (thresholds.disabledReason == AlertsDisabledReason.deviceTypePending)
        const _PendingBody()
      else ...[
        IndustrialCard(
          heading: l10n.alertsThresholdsHeading,
          headingIcon: Icons.tune,
          child: Column(
            children: [
              for (var i = 0; i < kinds.length; i++)
                _ThresholdRow(
                  kind: kinds[i],
                  resolved: thresholds[kinds[i]],
                  reading: _readingFor(kinds[i], tele),
                  live: live,
                  last: i == kinds.length - 1,
                ),
            ],
          ),
        ),
        // 🔵 2026-08-25 (FB-100) — the §6.2 「離目前讀數過近」 notices went with
        // the values that could be too near. See the note where their two
        // constants used to be.
        _Note(text: l10n.alertsReadOnlyNote),
        if (!live) _Note(text: l10n.alertsOfflineNote),
        if (!voltage) ...[
          _Note(
            text: l10n.alertsPowerBankOtNote,
            mono: l10n.alertsPowerBankOtEvidence,
          ),
          _Note(
            title: l10n.alertsPowerBankNoteTitle,
            text: l10n.alertsPowerBankNoteBody,
          ),
        ],
      ],

      IndustrialCard(
        heading: l10n.alertsMuteHeading,
        headingIcon: Icons.notifications_paused_outlined,
        child: Column(
          children: [
            _MuteRow(
              saved: saved,
              onMute: () => unawaited(_write(saved.copyWith(
                  alertMutedUntilMs: DateTime.now()
                      .add(kAlertMuteWindow)
                      .millisecondsSinceEpoch))),
              onClear: () =>
                  unawaited(_write(saved.copyWith(clearAlertMutedUntil: true))),
            ),
            SettingsRow(
              label: l10n.alertsSessionMuteTitle,
              sub: l10n.alertsSessionMuteSub,
              last: true,
              trailing: Switch(
                value: context
                    .watch<AlertController>()
                    .isSessionSilenced(widget.deviceId),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) => context
                    .read<AlertController>()
                    .setSessionSilenced(widget.deviceId, v),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// The live value this row is judged against, or null when nothing has
  /// arrived. Temperature stays in °C — see [_ThresholdRow].
  double? _readingFor(AlertKind kind, TelemetryController tele) =>
      kind.isVoltage ? tele.pvlt : tele.temperatureC?.toDouble();

  // 🔵 **`_nearNotice`, `_edit` and `_restore` removed 2026-08-25 (FB-100).**
  // All three existed only to serve layer ①. `_write` stays: the switch and the
  // two mutes are still settings, and they are still per unit — what the ruling
  // took away is the ability to type a NUMBER, not the ability to say "warn me
  // about this one" or "not for the next hour".
  Future<void> _write(SavedDevice next) =>
      context.read<DeviceController>().setAlertSettings(next);
}

/// One 「過壓 / 欠壓 / 過溫」 row: name, live reading, source badge, value.
///
/// 🔑 **The badge is a mitigation, not decoration** (§6.2 / §3.2.2). A user
/// looking at "80 °C" cannot otherwise tell whether their unit said that or
/// whether we did, and those two carry very different licence to be edited. The
/// power bank's 50 °C is the case that forced it into the design.
class _ThresholdRow extends StatelessWidget {
  const _ThresholdRow({
    required this.kind,
    required this.resolved,
    required this.reading,
    required this.live,
    required this.last,
  });

  final AlertKind kind;
  final ResolvedThreshold resolved;
  final double? reading;

  /// Whether this unit is the one being recorded right now. Only used to word
  /// an EMPTY row: offline, "we cannot know yet" is the truth (§7.5.2); online
  /// with nothing to show, "no basis" is.
  final bool live;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 🔵 2026-08-25 (FB-100) — was an `InkWell(onTap: onEdit)`. A plain
    // `Container` rather than a disabled `InkWell`: a row that ripples and then
    // does nothing reads as a bug, and design 0080 §3.2.2 already took this
    // position once for the power bank's absent voltage rows ("不是顯示成灰色
    // 停用 —— 那會讓使用者以為是自己少設了什麼").
    return Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        decoration: BoxDecoration(
          border: last
              ? null
              : Border(bottom: BorderSide(color: context.colors.line)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 78,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(kindLabel(l10n, kind),
                      style:
                          TextStyle(fontSize: 13.5, color: context.colors.text)),
                  Text(
                    kind == AlertKind.underVoltage
                        ? l10n.alertsRowBelowWarns
                        : l10n.alertsRowAboveWarns,
                    style:
                        TextStyle(fontSize: 10.5, color: context.colors.muted),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Text(
                reading == null
                    ? '--'
                    : kind.isVoltage
                        ? l10n.alertsVoltsValue(formatVolts(reading!))
                        : l10n.alertsCelsiusValue(formatCelsius(reading!)),
                textAlign: TextAlign.right,
                style: AppTextStyles.mono(context)
                    .copyWith(fontSize: 12.5, color: context.colors.muted),
              ),
            ),
            const SizedBox(width: 8),
            _SourceBadge(source: resolved.source, live: live),
            const SizedBox(width: 6),
            Text(
              resolved.isSet
                  ? (kind.isVoltage
                      ? l10n.alertsVoltsValue(formatVolts(resolved.value!))
                      : l10n.alertsCelsiusValue(formatCelsius(resolved.value!)))
                  : l10n.alertsValueUnset,
              style: AppTextStyles.mono(context).copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: context.colors.text,
              ),
            ),
          ],
        ),
    );
  }
}

/// Layer ②/③/④, as one word (there is no layer ① since FB-100).
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source, required this.live});

  final ThresholdSource source;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (label, color) = switch (source) {
      // 🔵 ~~ThresholdSource.user => (l10n.alertsSourceUser, ...)~~ — removed
      // 2026-08-25 (FB-100) along with the enum value it matched.
      ThresholdSource.device => (
          l10n.alertsSourceDevice,
          context.accent.accentSecondary
        ),
      ThresholdSource.appDefault => (
          l10n.alertsSourceApp,
          context.colors.muted
        ),
      // 🔴 Two different sentences for one enum value, and the difference is
      // §7.5.2's known gap rather than a nicety: `0x2B` is persisted NOWHERE, so
      // an offline unit has no layer ② and never will until it is connected.
      // Saying 「無依據」 there would report a permanent absence where the truth
      // is "ask again when the link is up" — and the alternative, quietly
      // caching the last triple against the device id, is what the design
      // refused, because a stale factory limit is indistinguishable from a live
      // one on screen.
      ThresholdSource.none => (
          live ? l10n.alertsSourceNone : l10n.alertsSourceOffline,
          live ? AppSemantics.danger : context.colors.muted
        ),
    };
    return _Pill(label: label, color: color);
  }
}

/// 「靜音 1 小時」 / 「靜音中 · 剩 N 分鐘」.
class _MuteRow extends StatelessWidget {
  const _MuteRow({
    required this.saved,
    required this.onMute,
    required this.onClear,
  });

  final SavedDevice saved;
  final VoidCallback onMute;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final until = saved.alertMutedUntil;
    if (until == null || !saved.isMutedAt(now)) {
      return SettingsRow(
        label: l10n.alertsMuteHourTitle,
        sub: l10n.alertsMuteHourSub,
        trailing: OutlinedButton(
          onPressed: onMute,
          child: Text(l10n.alertsMuteInactive),
        ),
      );
    }
    final left = until.difference(now).inMinutes + 1;
    return SettingsRow(
      label: l10n.alertsMutedTitle,
      sub: l10n.alertsMutedSub(
        TimeOfDay.fromDateTime(until).format(context),
        '$left',
      ),
      trailing: OutlinedButton(
        onPressed: onClear,
        child: Text(l10n.alertsMuteClear),
      ),
    );
  }
}

/// State C — the device type is not one this build knows (§7.5.6 C-2).
class _UnrecognisedBody extends StatelessWidget {
  const _UnrecognisedBody({this.deviceType});

  /// The byte itself, shown verbatim. It is the actionable part: it tells us
  /// which value `product_class.dart` has to be taught, and a user reading it
  /// off their screen into a report is how `0x18` got mapped in a day.
  final int? deviceType;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hex =
        deviceType == null ? null : '0x${deviceType!.toRadixString(16).padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Drawn, disabled, and NOT hidden. A switch that vanished would leave a
        // user who has heard of the feature looking for it on the wrong screen;
        // a greyed one beside a reason is an answer.
        Opacity(
          opacity: 0.55,
          child: IndustrialCard(
            child: SettingsRow(
              label: l10n.alertsDeviceSwitchTitle,
              sub: l10n.alertsDeviceSwitchSubUnrecognised,
              last: true,
              trailing: const Switch(value: false, onChanged: null),
            ),
          ),
        ),
        IndustrialCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.alertsUnrecognisedTitle,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.7,
                  fontWeight: FontWeight.w700,
                  color: AppSemantics.danger,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.alertsUnrecognisedBody,
                style:
                    TextStyle(fontSize: 12, height: 1.7, color: context.colors.muted),
              ),
              if (hex != null) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.alertsUnrecognisedDeviceType(hex),
                  style: AppTextStyles.mono(context)
                      .copyWith(fontSize: 10.5, color: context.colors.muted),
                ),
              ],
            ],
          ),
        ),
        // 🔑 The mockup's third card, and it is not filler: this page is the one
        // place a user meets the word "unrecognised", and without this they have
        // no way to tell whether the whole app has given up on their device.
        IndustrialCard(
          heading: l10n.alertsStillAvailableHeading,
          headingIcon: Icons.check_circle_outline,
          child: Text(
            l10n.alertsStillAvailableBody,
            style: TextStyle(
                fontSize: 11.5, height: 1.6, color: context.colors.muted),
          ),
        ),
      ],
    );
  }
}

/// The TRANSIENT counterpart of [_UnrecognisedBody] — no byte has arrived yet.
///
/// 🔴 It exists so that the two cannot share copy. Every connection passes
/// through this state for its first frames, so anything alarming written here
/// fires on every connect, about a condition that resolves itself in under a
/// second (§7.5.6 C-3).
class _PendingBody extends StatelessWidget {
  const _PendingBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.alertsPendingTitle,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: context.colors.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.alertsPendingBody,
            style: TextStyle(
                fontSize: 11.5, height: 1.6, color: context.colors.muted),
          ),
        ],
      ),
    );
  }
}

/// The unit lost its saved record while this page was open.
class _UnsavedBody extends StatelessWidget {
  const _UnsavedBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.alertsUnsavedTitle,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: context.colors.text)),
          const SizedBox(height: 8),
          Text(l10n.alertsUnsavedBody,
              style: TextStyle(
                  fontSize: 11.5, height: 1.6, color: context.colors.muted)),
        ],
      ),
    );
  }
}

/// A muted explanatory block under a card.
///
/// 🔵 2026-08-25 (FB-100) — ~~`warn`~~, which painted the block amber, went with
/// the §6.2 near-reading notice, its only caller. Every note this screen still
/// draws is an explanation rather than a caution.
class _Note extends StatelessWidget {
  const _Note({required this.text, this.title, this.mono});

  final String text;
  final String? title;
  final String? mono;

  @override
  Widget build(BuildContext context) {
    final color = context.colors.muted;
    return IndustrialCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(title!,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: context.colors.text)),
            const SizedBox(height: 6),
          ],
          Text(text,
              style: TextStyle(fontSize: 11.5, height: 1.6, color: color)),
          if (mono != null) ...[
            const SizedBox(height: 6),
            Text(mono!,
                style: AppTextStyles.mono(context)
                    .copyWith(fontSize: 10.5, color: context.colors.muted)),
          ],
        ],
      ),
    );
  }
}

// 🔵 **`_ThresholdDialog` removed 2026-08-25 (FB-100).** It was the only way a
// number ever entered layer ①, and it is worth recording what it did NOT do:
// `_submit()` parsed the text and accepted anything that parsed. No range, no
// direction, no sanity check against the device's own `0x2B` — so 「欠壓 5.0」
// was a valid entry that silently guaranteed the alarm could never fire, and
// nothing on the screen said so. That defect is what made the dealer's
// read-only request the cheap answer rather than a loss.


// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------
//
// 🔵 **P3 moved `formatVolts` / `formatCelsius` into `models/alert_thresholds`**
// and this file now re-exports them (see the `export` beside the imports). They
// had to leave the UI layer because the NOTIFICATION body quotes the same two
// numbers — "目前 10.82 V，門檻 11.00 V" — and it is built on the telemetry
// path, where importing a widget file to reach a formatter would be the wrong
// direction. Two `toStringAsFixed`s, one in `lib/state` and one here, is the
// shape that ends with the screen and the alarm disagreeing in the last digit.

/// The user-facing name of one [AlertKind].
String kindLabel(AppLocalizations l10n, AlertKind kind) => switch (kind) {
      AlertKind.overVoltage => l10n.alertsRowOverVoltage,
      AlertKind.underVoltage => l10n.alertsRowUnderVoltage,
      AlertKind.overTemperature => l10n.alertsRowOverTemperature,
    };
