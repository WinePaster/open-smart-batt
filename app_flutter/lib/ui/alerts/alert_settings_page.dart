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
/// ## The four states this screen has to draw, and why they are four
///
/// They come straight from the mockup and from §7.5.6 C-3, and the thing worth
/// keeping straight is that TWO of them look like "no warnings" and mean
/// entirely different things:
///
///   * **A — every row from the device.** The ordinary case: the unit reported
///     `0x2B`, three 「裝置回報」 badges, the user has to do nothing.
///   * **B — the user changed one field.** That row alone becomes 「自訂」 and
///     accented, with the device's own value still shown beside a 「還原」. The
///     other two rows do not move: §3.1 resolves PER FIELD, for the same reason
///     `BleService.setThresholds` preserves the UT byte — editing one field must
///     not silently erase the ones next to it.
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
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../devices/save_device_flow.dart';
import '../util/alert_thresholds_lookup.dart';
import '../widgets/industrial.dart';

/// How close a threshold may sit to the current reading before the screen says
/// so (design 0080 §6.2, "設定值離目前讀數過近時就地提示").
///
/// 🔑 **Twice the hysteresis band, and that is where the number comes from.**
/// §3.3 fixes the release band at 0.3 V / 3 °C, so a limit set within one band
/// of the present reading describes an alarm that, once raised, cannot clear
/// until the reading moves further than the debounce was ever meant to absorb.
/// One band is therefore "already broken"; two is "you are about to be". The
/// design gave no figure, so this is derived from the one figure it did give
/// rather than chosen — a bare 0.5 would have to be defended on its own and
/// could not be.
const double kAlertNearVolts = 0.6;

/// See [kAlertNearVolts] — 2 × the 3 °C band.
const double kAlertNearCelsius = 6;

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
  /// Gate ③ — 「本次連線不再提醒」 (§3.4).
  ///
  /// 🔴 **Deliberately NOT persisted, and deliberately held HERE.** The
  /// asymmetry with the 1-hour mute is the design: "for an hour" is a promise
  /// about wall-clock time and has to survive a restart, "not again this
  /// connection" is a promise about a link and ends with it. State living on a
  /// widget that the user can pop is admittedly a weaker home than it deserves
  /// — P3 moves it onto whatever holds the evaluator, where "the connection"
  /// is actually observable — but writing it to the database in the meantime
  /// would be the one thing that makes it wrong rather than merely temporary.
  bool _sessionMuted = false;

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
                  onEdit: () => unawaited(_edit(saved, kinds[i], thresholds)),
                  onRestore: () => unawaited(_restore(saved, kinds[i])),
                ),
            ],
          ),
        ),
        // §6.2 — a limit sitting on top of the present reading is a bombardment
        // the user is about to build for themselves; say so beside it.
        for (final k in kinds)
          ?_nearNotice(l10n, k, thresholds[k], _readingFor(k, tele)),
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
                value: _sessionMuted,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) => setState(() => _sessionMuted = v),
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

  Widget? _nearNotice(
    AppLocalizations l10n,
    AlertKind kind,
    ResolvedThreshold resolved,
    double? reading,
  ) {
    // Only for a value the USER set. A device-reported or app-default limit
    // sitting near today's reading is information about the hardware, not a
    // mistake anyone just made, and warning about it on every screen open would
    // be noise the reader cannot act on.
    if (resolved.source != ThresholdSource.user || !resolved.isSet) return null;
    if (reading == null) return null;
    final delta = (resolved.value! - reading).abs();
    final limit = kind.isVoltage ? kAlertNearVolts : kAlertNearCelsius;
    if (delta >= limit) return null;
    final label = kindLabel(l10n, kind);
    return _Note(
      warn: true,
      text: kind.isVoltage
          ? l10n.alertsNearReadingVolts(label, delta.toStringAsFixed(2))
          : l10n.alertsNearReadingCelsius(label, delta.toStringAsFixed(0)),
    );
  }

  Future<void> _write(SavedDevice next) =>
      context.read<DeviceController>().setAlertSettings(next);

  /// 🔴 Clearing one field, never three. See [SavedDevice.copyWith] — the
  /// `clearX` flags exist precisely so 「還原」 can put ONE column back to NULL
  /// while the other two keep whatever the owner typed (§3.1, per field).
  Future<void> _restore(SavedDevice saved, AlertKind kind) => _write(switch (kind) {
        AlertKind.overVoltage => saved.copyWith(clearAlertOv: true),
        AlertKind.underVoltage => saved.copyWith(clearAlertUv: true),
        AlertKind.overTemperature => saved.copyWith(clearAlertOt: true),
      });

  Future<void> _edit(
    SavedDevice saved,
    AlertKind kind,
    AlertThresholds thresholds,
  ) async {
    final value = await showDialog<double>(
      context: context,
      builder: (_) => _ThresholdDialog(
        kind: kind,
        initial: thresholds[kind].value,
      ),
    );
    if (value == null || !mounted) return;
    await _write(switch (kind) {
      AlertKind.overVoltage => saved.copyWith(alertOv: value),
      AlertKind.underVoltage => saved.copyWith(alertUv: value),
      AlertKind.overTemperature => saved.copyWith(alertOt: value),
    });
  }
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
    required this.onEdit,
    required this.onRestore,
  });

  final AlertKind kind;
  final ResolvedThreshold resolved;
  final double? reading;

  /// Whether this unit is the one being recorded right now. Only used to word
  /// an EMPTY row: offline, "we cannot know yet" is the truth (§7.5.2); online
  /// with nothing to show, "no basis" is.
  final bool live;
  final bool last;
  final VoidCallback onEdit;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final custom = resolved.source == ThresholdSource.user;
    final accent = context.accent.accent;
    return InkWell(
      onTap: onEdit,
      child: Container(
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
                color: custom ? accent : context.colors.text,
              ),
            ),
            if (custom) ...[
              const SizedBox(width: 2),
              // 40 dp floor, named rather than inherited — FB-70 is what a
              // control nobody can hit costs.
              IconButton(
                onPressed: onRestore,
                icon: const Icon(Icons.undo, size: 16),
                tooltip: l10n.alertsRestore,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
                color: accent,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Layer ①/②/③/④, as one word.
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source, required this.live});

  final ThresholdSource source;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (label, color) = switch (source) {
      ThresholdSource.user => (l10n.alertsSourceUser, context.accent.accent),
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

/// A muted (or amber) explanatory block under a card.
class _Note extends StatelessWidget {
  const _Note({required this.text, this.title, this.mono, this.warn = false});

  final String text;
  final String? title;
  final String? mono;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final color = warn ? AppSemantics.warn : context.colors.muted;
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

/// Type a threshold, or cancel.
///
/// A dialog rather than an inline text field, unlike the mockup's `.inp` box:
/// an always-live field on this screen would have to decide when a half-typed
/// "1" becomes a threshold, and the answer to that on a screen that RAISES
/// ALARMS should not be "as you type".
class _ThresholdDialog extends StatefulWidget {
  const _ThresholdDialog({required this.kind, this.initial});

  final AlertKind kind;
  final double? initial;

  @override
  State<_ThresholdDialog> createState() => _ThresholdDialogState();
}

class _ThresholdDialogState extends State<_ThresholdDialog> {
  late final TextEditingController _c = TextEditingController(
    text: widget.initial == null
        ? ''
        : (widget.kind.isVoltage
            ? formatVolts(widget.initial!)
            : formatCelsius(widget.initial!)),
  );
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final v = double.tryParse(_c.text.trim());
    if (v == null) {
      setState(() => _error = AppLocalizations.of(context).alertsEditInvalid);
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: context.colors.panel,
      title: Text(l10n.alertsEditDialogTitle(kindLabel(l10n, widget.kind)),
          style: const TextStyle(fontSize: 17)),
      content: TextField(
        controller: _c,
        autofocus: true,
        // `signed: false` — a negative over-voltage limit is not a value anyone
        // means, and the decoder's own arithmetic cannot produce one.
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          hintText: widget.kind.isVoltage
              ? l10n.alertsEditHintVolts
              : l10n.alertsEditHintCelsius,
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel,
              style: TextStyle(color: context.colors.muted)),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(l10n.commonConfirm,
              style: TextStyle(color: context.accent.accent)),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting — shared so the entry row, the rows and the dialog cannot drift
// ---------------------------------------------------------------------------

/// Two decimals, matching how `0x2B` decodes (`b * 0.025 + 14.4`, i.e. 40 mV
/// steps) and how every other voltage on this app's screens is rendered.
String formatVolts(double v) => v.toStringAsFixed(2);

/// 🔴 **Always °C, whatever [TempUnit] the user picked, and this is a known
/// deviation worth stating.** The thresholds are stored in °C because that is
/// what `0x2B` carries (`b6 + 60`), and this screen shows a limit and the live
/// reading side by side — converting one and not the other would be a defect,
/// and converting both would make the value the user TYPES a converted quantity
/// that has to survive a round trip through a byte-resolution field. Design 0080
/// does not rule on it; the mockup is in °C throughout, and this follows the
/// mockup rather than inventing a rule.
String formatCelsius(double v) => v.toStringAsFixed(0);

/// The user-facing name of one [AlertKind].
String kindLabel(AppLocalizations l10n, AlertKind kind) => switch (kind) {
      AlertKind.overVoltage => l10n.alertsRowOverVoltage,
      AlertKind.underVoltage => l10n.alertsRowUnderVoltage,
      AlertKind.overTemperature => l10n.alertsRowOverTemperature,
    };
