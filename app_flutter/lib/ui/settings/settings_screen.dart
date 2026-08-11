/// OpenSmartBatt — Settings screen (mockup screen 5).
///
/// Five cards: 連線 (connection), 顯示 (display), 資料 (data), 診斷/開發者
/// (diagnostics — raw BLE packet log DEFAULT OFF + export `.log`), and 關於
/// (about: version / GitHub / PROTOCOL.md / copyright). All settings bind to
/// [SettingsController]; data/log actions go through [TelemetryController].
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../dashboard/capture_mark_labels.dart';
import '../dashboard/watchfaces.dart';
import '../diagnostics/capture_wizard.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../util/export_header.dart';
import '../util/export_naming.dart';
import '../util/export_scope.dart';
import '../util/export_share.dart';
import '../util/update_check.dart';
import '../widgets/industrial.dart';
import 'g_calibration_wizard.dart';
import 'measurement_explainer.dart';
import 'g_meter_consent_dialog.dart';
import 'speed_consent_dialog.dart';


/// Community project links (mockup startup disclaimer + About card).
const String kGithubUrl = 'https://github.com/WinePaster/open-smart-batt';
const String kProtocolUrl =
    'https://github.com/WinePaster/open-smart-batt/blob/main/docs/PROTOCOL.md';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, this.deviceInfoPanelBuilder});

  // 🔴 `onOpenDevices` is GONE (design 0051). It existed for exactly one row —
  // the design 0046 R20 signpost to the watchface picker — and that row went
  // with the picker. A callback threaded from the shell to nothing is how a
  // screen quietly grows a second navigation path later, so it is removed
  // rather than left available.

  /// Optional device-info panel supplied by a closed-source build. NULL on the
  /// open build, where nothing is rendered and the screen is byte-identical to
  /// before the slot existed.
  ///
  /// The open side knows only WHERE the panel goes, never what it contains: a
  /// closed composition root passes `bootstrap(deviceInfoPanelBuilder: …)` and
  /// reads its own [DeviceMetadata] inside the builder. No closed selector,
  /// label or field name is referenced here.
  final WidgetBuilder? deviceInfoPanelBuilder;

  @override
  Widget build(BuildContext context) {
    final panel = deviceInfoPanelBuilder;
    return ListView(
      padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
      children: [
        const _ConnectionCard(),
        if (panel != null) panel(context),
        const _DisplayCard(),
        const _DataCard(),
        const _DiagnosticsCard(),
        const _AboutCard(),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 連線 / Connection
// ---------------------------------------------------------------------------

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.settingsConnectionHeading,
      headingIcon: Icons.bluetooth,
      child: Column(
        children: [
          SettingsRow(
            label: l10n.settingsAutoReconnectLabel,
            sub: l10n.settingsAutoReconnectSub,
            trailing: _Toggle(
              value: s.autoReconnect,
              onChanged: s.setAutoReconnect,
            ),
          ),
          // Background execution and keeping the screen on are two different
          // things. They shared one setting while the wakelock was the only
          // mitigation available; now they are separate.
          // Platform-split copy, ONE live switch (design 0047 Phase 1 — the
          // iOS disable that FB-26 put here is gone, because the thing the
          // switch controls now exists there: bluetooth-central background
          // mode + notify-driven keep-alive). The value/setter dispatch to the
          // platform's own field inside SettingsController; iOS defaults OFF
          // (0047 Q4) and its copy promises only "recorded while the link can
          // be maintained" — iOS scheduling and Low Power Mode still own the
          // schedule, and suspended-and-disconnected minutes leave no rows.
          SettingsRow(
            label: l10n.settingsBackgroundMonitorLabel,
            sub: Platform.isIOS
                ? l10n.settingsBackgroundMonitorSubIos
                : l10n.settingsBackgroundMonitorSubAndroid,
            trailing: _Toggle(
              value: s.backgroundMonitoring,
              onChanged: s.setBackgroundMonitoring,
            ),
          ),
          SettingsRow(
            label: l10n.settingsKeepAwakeLabel,
            sub: l10n.settingsKeepAwakeSub,
            last: true,
            trailing: _Toggle(
              value: s.keepScreenAwake,
              onChanged: s.setKeepScreenAwake,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 顯示 / Display
// ---------------------------------------------------------------------------

class _DisplayCard extends StatelessWidget {
  const _DisplayCard();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.settingsDisplayHeading,
      headingIcon: Icons.speed,
      child: Column(
        children: [
          SettingsRow(
            label: l10n.settingsThemeLabel,
            sub: l10n.settingsThemeSub,
            trailing: SegmentedControl<AppThemeMode>(
              selected: s.themeMode,
              onChanged: s.setThemeMode,
              options: [
                (value: AppThemeMode.light, label: l10n.settingsThemeLight),
                (value: AppThemeMode.dark, label: l10n.settingsThemeDark),
                (value: AppThemeMode.auto, label: l10n.settingsThemeAuto),
              ],
            ),
          ),
          SettingsRow(
            label: l10n.settingsLanguageLabel,
            sub: l10n.settingsLanguageSub,
            trailing: SegmentedControl<AppLang>(
              selected: s.lang,
              onChanged: (v) => context.read<SettingsController>().setLang(v),
              options: [
                (value: AppLang.zhHant, label: l10n.settingsLanguageZhHant),
                (value: AppLang.en, label: l10n.settingsLanguageEnglish),
                (value: AppLang.system, label: l10n.settingsLanguageSystem),
              ],
            ),
          ),
          SettingsRow(
            label: l10n.settingsTempUnitLabel,
            trailing: SegmentedControl<TempUnit>(
              selected: s.tempUnit,
              onChanged: s.setTempUnit,
              options: const [
                (value: TempUnit.celsius, label: '°C'),
                (value: TempUnit.fahrenheit, label: '°F'),
              ],
            ),
          ),
          const _SpeedDetectionRow(),
          if (s.speedDetection)
            SettingsRow(
              label: l10n.settingsSpeedUnitLabel,
              trailing: SegmentedControl<SpeedUnit>(
                selected: s.speedUnit,
                onChanged: s.setSpeedUnit,
                options: const [
                  (value: SpeedUnit.kmh, label: 'km/h'),
                  (value: SpeedUnit.mph, label: 'mph'),
                ],
              ),
            ),
          // design 0042 §3.9b. Always shown, switch or no switch: the question
          // it answers ("why does it say 0 / why is it stuck?") is asked by
          // people already using the feature, and the consent dialog they saw
          // when they turned it on is not reachable again.
          SettingsLinkRow(
            icon: Icons.help_outline,
            label: l10n.settingsSpeedExplainerLabel,
            onTap: () => showSpeedMeasurementExplainer(context),
          ),
          const _GMeterRow(),
          if (s.gMeterEnabled) const _GCalibrationRow(),
          // design 0045 §3.6b — same shape, same reason.
          SettingsLinkRow(
            icon: Icons.help_outline,
            label: l10n.settingsGForceExplainerLabel,
            onTap: () => showGForceMeasurementExplainer(context),
          ),
          // 🔴 The 錶盤 signpost row is gone (design 0051, 2026-08-09). Design
          // 0046 R20 kept it because "設定 → 錶盤" had shipped and a user who
          // learned that path had to find out where it went. There is now
          // nowhere for it to point: the picker itself is gone, and a row that
          // said "the watchface moved" and then "there is no watchface" in two
          // releases would be worse than the silence.
        ],
      ),
    );
  }
}

/// The GPS speed master switch (design 0042 §3.9).
///
/// Stateful only to hold [_busy]: the consent dialog and the OS permission
/// prompt are two awaits, and a second tap on the switch while either is up
/// would start a parallel flow whose two answers race to write the setting.
///
/// ⚠️ The switch reflects the STORED value at all times, never an optimistic
/// one. A switch that flips first and reverts on cancel makes cancelling look
/// like a failure; this one simply does not move until consent is given.
class _SpeedDetectionRow extends StatefulWidget {
  const _SpeedDetectionRow();

  @override
  State<_SpeedDetectionRow> createState() => _SpeedDetectionRowState();
}

class _SpeedDetectionRowState extends State<_SpeedDetectionRow> {
  bool _busy = false;

  Future<void> _onChanged(bool next) async {
    if (_busy) return;
    final settings = context.read<SettingsController>();
    // Turning it OFF is not a decision anyone has to be walked through, and
    // asking would train the user to dismiss the dialog that matters.
    if (!next) {
      await settings.setSpeedDetection(false);
      return;
    }
    setState(() => _busy = true);
    try {
      final gps = context.read<GpsSpeedController>();
      final agreed = await showSpeedDetectionConsentDialog(context);
      // Cancel is ZERO side effects: nothing written, nothing asked of the OS.
      if (!agreed) return;
      await settings.setSpeedDetection(true);
      // Straight into the OS prompt, while the user is still inside the context
      // they just agreed to (design 0042 §3.5). A refusal leaves the switch ON
      // — consent was given, the OS is what is missing — and the card says so
      // with a route to the settings page.
      await gps.requestPermission();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final on = context.select<SettingsController, bool>(
        (s) => s.settings.speedDetection);
    return SettingsRow(
      label: l10n.settingsSpeedDetectionLabel,
      sub: l10n.settingsSpeedDetectionSub,
      subHighlight: !on,
      trailing: _Toggle(
        value: on,
        onChanged: _busy ? null : (v) => unawaited(_onChanged(v)),
      ),
    );
  }
}

/// The G meter master switch (design 0045 §3.5 / Q2).
///
/// Stateful for [_SpeedDetectionRow]'s reason: the consent dialog and the
/// wizard are two awaits, and a second tap while either is up would start a
/// parallel flow. The switch reflects the STORED value at all times.
///
/// 🔴 Consent then wizard, in one gesture. Design 0045 R1 calls "switched on
/// but never calibrated" this feature's biggest risk, because Q8 leaves the
/// dashboard with nothing at all to say about it — so the flow does not offer a
/// natural place to stop halfway. Cancelling the wizard is still allowed (a
/// modal you cannot leave is worse), and the row below then says what is
/// missing, permanently.
class _GMeterRow extends StatefulWidget {
  const _GMeterRow();

  @override
  State<_GMeterRow> createState() => _GMeterRowState();
}

class _GMeterRowState extends State<_GMeterRow> {
  bool _busy = false;

  Future<void> _onChanged(bool next) async {
    if (_busy) return;
    final settings = context.read<SettingsController>();
    if (!next) {
      // Off needs no walking through, and asking would train the user to
      // dismiss the dialog that matters. The stored calibration is left alone
      // — the mount has not moved because a feature was switched off.
      await settings.setGMeterEnabled(false);
      return;
    }
    setState(() => _busy = true);
    try {
      final agreed = await showGMeterConsentDialog(context);
      if (!agreed) return;
      await settings.setGMeterEnabled(true);
      if (!mounted) return;
      // Straight into the wizard, while the user is still inside the context
      // they just agreed to.
      await showGCalibrationWizard(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final on = context.select<SettingsController, bool>(
        (s) => s.settings.gMeterEnabled);
    return SettingsRow(
      label: l10n.settingsGMeterLabel,
      sub: l10n.settingsGMeterSub,
      subHighlight: !on,
      trailing: _Toggle(
        value: on,
        onChanged: _busy ? null : (v) => unawaited(_onChanged(v)),
      ),
    );
  }
}

/// Calibration state, and the two things you can do about it.
///
/// 🔑 This row is where ALL of the feature's guidance lives. Design 0045 Q8
/// ruled that an uncalibrated G meter shows nothing on the dashboard — no card,
/// no placeholder, no hint — so if this row does not say what is missing,
/// nothing does. That is why the sub-line states the CONSEQUENCE ("the card
/// will not appear") rather than only the state.
///
/// Three states, and they are genuinely different:
///
///  * never calibrated — the wizard has not been run;
///  * invalid — it was run, and the still-window check has since decided the
///    mount moved (§3.2). Distinct because "do it again" means something
///    different when you have already done it once;
///  * calibrated — with the date, so "I set this up before I moved the mount"
///    is answerable without guessing.
///
/// "Clear calibration" is separate from the switch on purpose: design 0045
/// §3.5's "校準歸零" is a statement about the MOUNT, and turning a feature off
/// is not one.
class _GCalibrationRow extends StatelessWidget {
  const _GCalibrationRow();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final g = context.watch<GForceController>();
    final at = g.calibratedAt;
    final sub = switch (g) {
      _ when at == null => l10n.settingsGCalibrationNever,
      _ => l10n.settingsGCalibrationDone(_calibratedWhen(at)),
    };
    return Column(
      children: [
        // `SettingsRow` + `InkWell` rather than `SettingsLinkRow`, which has no
        // sub-line — and the sub-line is the entire point of this row.
        InkWell(
          onTap: () => unawaited(showGCalibrationWizard(context)),
          child: SettingsRow(
            label: l10n.settingsGCalibrationLabel,
            sub: sub,
            subHighlight: !g.calibrated,
            trailing:
                Icon(Icons.chevron_right, size: 16, color: context.colors.muted),
          ),
        ),
        if (at != null)
          SettingsLinkRow(
            icon: Icons.restart_alt,
            label: l10n.settingsGCalibrationClear,
            last: true,
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              final done = l10n.settingsGCalibrationCleared;
              await context.read<SettingsController>().setGCalibration(null);
              messenger.showSnackBar(SnackBar(
                duration: const Duration(milliseconds: 1600),
                content: Text(done),
              ));
            },
          ),
      ],
    );
  }
}

/// Local date-time for the calibration row.
///
/// Deliberately NOT the export preamble's ISO-8601: this string is read by the
/// person holding the phone, in their own timezone, and the preamble's rule
/// (never localized, read by whoever receives the file) does not apply to a
/// settings row.
String _calibratedWhen(DateTime at) {
  final l = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}';
}

// 🔴 The watchface signpost row was DELETED on 2026-08-09 (design 0051).
//
// It was a signpost to the per-device watchface picker, which design 0046 R20
// had moved out of this screen. Both are gone now: there is one dashboard
// layout and nothing to pick. T-new-7 ("Settings is a link, never a second
// writer of `display_layout`") is satisfied vacuously — this file no longer
// mentions the column at all, which is the strongest form of that rule.

// ---------------------------------------------------------------------------
// 資料 / Data
// ---------------------------------------------------------------------------

class _DataCard extends StatefulWidget {
  const _DataCard();

  @override
  State<_DataCard> createState() => _DataCardState();
}

class _DataCardState extends State<_DataCard> {
  bool _busy = false;

  Future<void> _exportAll() async {
    if (_busy) return;
    // Pick the unit BEFORE showing the spinner — the sheet is the user's
    // decision point, not work.
    final target = await chooseExportScope(context, offerSession: false);
    if (target == null || !mounted) return;
    setState(() => _busy = true);
    final tele = context.read<TelemetryController>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    // Captured now: the label lookup runs after an await, when this screen may
    // already be gone.
    final devices = context.read<DeviceController>();
    final services = context.read<AppServices>();
    String labelFor(String? id) => deviceLabelFor(devices, id);
    ProductClass classFor(String? id) => deviceClassFor(devices, id);
    // iPad popover anchor (D.7): capture before any await invalidates context.
    final origin = sharePositionFromContext(context);
    // The dashboard layout in force right now (design 0034 §8). Captured here
    // with the other context reads — by the time the CSV is built this screen
    // may be gone.
    final layout = currentExportLayoutValue(context);
    // design 0046 Step 10. Same capture rule as `layout` above: read before the
    // first await, because by the time the file is written the screen may be
    // gone.
    final home = currentExportHomeValue(context);
    // design 0042 §3.9: emitted unconditionally, `off` included, so that an
    // empty `speed` column has one reading instead of two.
    final speedDetection = context.read<SettingsController>().speedDetection;
    final gMeter = context.read<SettingsController>().gMeterEnabled;
    try {
      final filename = exportFileName(
        base: 'opensmartbatt-history',
        classSlug: target.classSlug,
        ident: target.ident,
        stamp: exportStamp(),
        extension: 'csv',
      );
      final file = await exportTempFile(filename);
      // "Export all data" means all of it, and it always did — this path never
      // carried a row cap. What it DID carry was the whole table in memory
      // three times over, which is the same defect as the History screen's cap
      // seen from the other side: one lost rows silently, this one fell over
      // silently. Both now stream page by page (design 0030 T4b).
      final rows = await tele.exportHistoryCsvToFile(
        file,
        deviceId: target.deviceId,
        labelFor: labelFor,
        classFor: classFor,
        header: exportHeaderLines(
          title: 'OpenSmartBatt history export',
          exportedAt: DateTime.now(),
          appBuild: services.appBuild,
          platform: services.platform,
          scope: exportScopeLabel(target),
          // FB-60. Unconditional here and always `all`: this button has no
          // range picker, so the file has to say so rather than leave the
          // recipient to infer it from a missing line.
          window: 'all',
          // Same column, same rule as the History screen's export — the two
          // paths write the same CSV shape and must describe it identically.
          ampereColumn: true,
          layout: layout,
          home: home,
          speedDetection: speedDetection,
          gMeter: gMeter,
        ),
      );
      // Row count, not text emptiness: the preamble means the file is never
      // empty, so the older `!csv.contains('\n')` test would always pass and
      // hand the user a header-only file with no warning.
      if (rows == 0) {
        await file.delete().catchError((_) => file);
        messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.commonNoRecordsToExport)));
        return;
      }
      await shareExportFile(
        file: file,
        filename: filename,
        mimeType: 'text/csv',
        subject: l10n.settingsExportSubjectAllData,
        sharePositionOrigin: origin,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.commonExportFailed('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final tele = context.read<TelemetryController>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final ok = await _confirm(
      context,
      title: l10n.settingsClearHistoryTitle,
      body: l10n.settingsClearHistoryBody,
      danger: true,
      confirmLabel: l10n.settingsClearConfirm,
    );
    if (!ok) return;
    await tele.clearHistory();
    messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.settingsHistoryCleared)));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.settingsDataHeading,
      headingIcon: Icons.description_outlined,
      child: Column(
        children: [
          SettingsRow(
            label: l10n.settingsRetentionLabel,
            sub: l10n.settingsRetentionSub,
            trailing: SegmentedControl<RetentionPolicy>(
              selected: s.retention,
              onChanged: s.setRetention,
              options: [
                (value: RetentionPolicy.days30, label: l10n.retention30Days),
                (value: RetentionPolicy.days90, label: l10n.retention90Days),
                (value: RetentionPolicy.days365, label: l10n.retention365Days),
                (value: RetentionPolicy.forever, label: l10n.retentionForever),
              ],
            ),
          ),
          SettingsLinkRow(
            icon: Icons.file_download_outlined,
            label: l10n.settingsExportAllLabel,
            onTap: _exportAll,
            trailing: _busy ? const _SmallSpinner() : null,
          ),
          SettingsLinkRow(
            icon: Icons.delete_outline,
            label: l10n.settingsClearHistoryLabel,
            onTap: _clear,
            last: true,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 診斷 / Diagnostics
// ---------------------------------------------------------------------------

class _DiagnosticsCard extends StatefulWidget {
  const _DiagnosticsCard();

  @override
  State<_DiagnosticsCard> createState() => _DiagnosticsCardState();
}

class _DiagnosticsCardState extends State<_DiagnosticsCard> {
  bool _busy = false;

  /// Run the guided capture script for the connected unit.
  ///
  /// Requires a live connection: the marks describe states of a device we are
  /// recording, and running it disconnected would write ground truth for
  /// nothing.
  Future<void> _runCaptureWizard() async {
    final l10n = AppLocalizations.of(context);
    final conn = context.read<ConnectionController>();
    final messenger = ScaffoldMessenger.of(context);
    if (!conn.isOnline) {
      messenger.showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1800),
        content: Text(l10n.disconnectedTitle),
      ));
      return;
    }
    final marks = CaptureMark.forClass(conn.packLabel)
        .where((m) => m != CaptureMark.note)
        .toList();
    if (marks.isEmpty) {
      // An unclassified unit has no script — offering one would invite the
      // mislabelled ground truth this feature exists to prevent.
      messenger.showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1800),
        content: Text(l10n.packLabelUnclassified),
      ));
      return;
    }
    final done = await showCaptureWizard(
      context,
      marks: marks,
      labelFor: (m) => captureMarkLabel(l10n, m),
    );
    if (!done) return;
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 2600),
      content: Text(l10n.captureWizardFinished),
    ));
  }

  Future<void> _exportLog() async {
    if (_busy) return;
    // FB-32: say it BEFORE the scope sheet. Otherwise the reporter picks a
    // scope, shares a file, and only we find out it holds nothing.
    // Exactly one "here is what this file is" dialog, either way: off means it
    // carries almost nothing (FB-32), on means it carries the device's own BLE
    // address (FB-37). Both are things the sender should know BEFORE sharing.
    if (context.read<SettingsController>().rawPacketLog) {
      if (!await _confirmRawLogContents()) return;
    } else {
      if (!await _warnRawPacketLogOff()) return;
    }
    if (!mounted) return;
    // The diagnostic log is the one export where "this connection only" is
    // useful — that is the slice we ask a reporter for, since the table
    // accumulates across every connection to every unit the phone has seen.
    final target = await chooseExportScope(context, offerSession: true);
    if (target == null || !mounted) return;
    setState(() => _busy = true);
    final tele = context.read<TelemetryController>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    // Captured now: the lookup runs after an await, when this screen may be gone.
    final devices = context.read<DeviceController>();
    final services = context.read<AppServices>();
    final rawLog = context.read<SettingsController>().rawPacketLog;
    final speedOn = context.read<SettingsController>().speedDetection;
    final gMeterOn = context.read<SettingsController>().gMeterEnabled;
    // The dashboard layout in force right now (design 0034 §8), captured with
    // the other context reads for the same reason. The home grid likewise
    // (design 0046 Step 10).
    final layout = currentExportLayoutValue(context);
    final home = currentExportHomeValue(context);
    String labelFor(String? id) => deviceLabelFor(devices, id);
    // iPad popover anchor (D.7): capture before any await invalidates context.
    final origin = sharePositionFromContext(context);
    try {
      // design 0027 §3.1: name every unit this export touches in the header,
      // even an all-devices export where the rows carry only nicknames.
      final identities = await exportDeviceIdentities(devices, tele, target);
      final header =
          await _logHeader(
              tele, services, target, rawLog, speedOn, gMeterOn, layout,
              home, identities);
      final log = await tele.exportLog(
        deviceId: target.deviceId,
        sessionId: target.sessionId,
        header: header,
        labelFor: labelFor,
      );
      if (log.trim().isEmpty) {
        messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.settingsLogEmpty)));
        return;
      }
      await shareTextAsFile(
        content: log,
        filename: exportFileName(
          base: 'opensmartbatt',
          classSlug: target.classSlug,
          ident: target.ident,
          stamp: exportStamp(),
          extension: 'log',
        ),
        mimeType: 'text/plain',
        subject: l10n.settingsExportSubjectDiagLog,
        sharePositionOrigin: origin,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.commonExportFailed('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// FB-37 (ruled 2026-07-30: disclose, do not redact). Returns true to export.
  ///
  /// `0x38` is the device reporting its own BLE address as ASCII, so a raw
  /// frame dump carries a hardware address — on iOS too, which is why FB-33's
  /// "only Android exposes a MAC" premise did not cover this. Twelve distinct
  /// addresses already sit across fifteen collected captures.
  ///
  /// Redaction was considered and rejected: the frame is XOR-checksummed, so
  /// substituting the payload either breaks the checksum (our own corruption
  /// becomes indistinguishable from real corruption) or requires forging it,
  /// which would put bytes the device never sent into a file we treat as
  /// evidence. Dropping the whole frame is clean but costs the register.
  ///
  /// So the file keeps the address and the sender is told, once, that it is
  /// there — because the realistic harm is not that the address exists (a BLE
  /// peripheral broadcasts it continuously to anyone in range) but that a file
  /// tying it to a named reporter could be posted somewhere permanent.
  Future<bool> _confirmRawLogContents() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.rawLogContentsDialogTitle),
        content: SingleChildScrollView(
          child: Text(
            l10n.rawLogContentsDialogBody,
            style: TextStyle(color: ctx.colors.muted, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.rawLogContentsContinue),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// FB-32 §3.2. Returns true to carry on with the export.
  ///
  /// Enabling deliberately CANCELS the export instead of continuing: the rows
  /// do not exist yet, so carrying on would hand the user an equally empty file
  /// while making them believe the problem was solved — worse than not warning
  /// at all.
  Future<bool> _warnRawPacketLogOff() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final settings = context.read<SettingsController>();
    final choice = await showDialog<_RawLogChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.rawLogOffDialogTitle),
        content: SingleChildScrollView(
          child: Text(
            l10n.rawLogOffDialogBody,
            style: TextStyle(color: ctx.colors.muted, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_RawLogChoice.exportAnyway),
            child: Text(l10n.rawLogOffExportAnyway),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_RawLogChoice.enable),
            child: Text(l10n.rawLogOffEnable),
          ),
        ],
      ),
    );
    if (choice == _RawLogChoice.enable) {
      await settings.setRawPacketLog(true);
      messenger.showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 3200),
        content: Text(l10n.rawLogEnabledSnack),
      ));
      return false;
    }
    return choice == _RawLogChoice.exportAnyway;
  }

  /// The `#`-prefixed preamble telling whoever receives the diagnostic log
  /// which unit it covers, which app build produced it, how many connections it
  /// spans and whether raw packets were being recorded at all. Without it a
  /// recipient cannot tell a genuinely quiet capture from one the app never
  /// wrote, and has to guess at the version — which is how an app-side bug once
  /// got read as a hardware limitation.
  Future<List<String>> _logHeader(
    TelemetryController tele,
    AppServices services,
    ExportTarget target,
    // Passed in, not read here: this method awaits first, by which time the
    // screen may be gone and a `context.read` would throw mid-export — the same
    // reason `labelFor` is captured by the caller.
    bool rawPacketLog,
    bool speedDetection,
    bool gMeter,
    String layout,
    String home,
    List<ExportDeviceIdentity> devices,
  ) async {
    final sessions = target.scope == ExportScope.currentSession
        ? 1
        : await tele.logSessionCount(deviceId: target.deviceId);
    return exportHeaderLines(
      title: 'OpenSmartBatt diagnostic log',
      exportedAt: DateTime.now(),
      appBuild: services.appBuild,
      platform: services.platform,
      scope: exportScopeLabel(target),
      layout: layout,
      home: home,
      speedDetection: speedDetection,
      gMeter: gMeter,
      connections: sessions,
      rawPacketLog: rawPacketLog,
      devices: devices,
    );
  }

  Future<void> _clearLog() async {
    final tele = context.read<TelemetryController>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final ok = await _confirm(
      context,
      title: l10n.settingsClearLogTitle,
      body: l10n.settingsClearLogBody,
      danger: true,
      confirmLabel: l10n.settingsClearConfirm,
    );
    if (!ok) return;
    await tele.clearLog();
    messenger.showSnackBar(SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.settingsLogCleared)));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.settingsDiagnosticsHeading,
      headingIcon: Icons.bug_report_outlined,
      child: Column(
        children: [
          SettingsRow(
            label: l10n.settingsRawPacketLogLabel,
            sub: l10n.settingsRawPacketLogSub,
            subHighlight: true,
            trailing: _Toggle(
              value: s.rawPacketLog,
              onChanged: s.setRawPacketLog,
            ),
          ),
          SettingsRow(
            label: l10n.settingsLogMaxSizeLabel,
            sub: l10n.settingsLogMaxSizeSub,
            trailing: SegmentedControl<int>(
              selected: s.logMaxBytes,
              onChanged: s.setLogMaxBytes,
              options: [
                (value: 100 * 1024 * 1024, label: '100 MB'),
                (
                  value: AppSettings.unlimitedLogBytes,
                  label: l10n.settingsLogMaxUnlimited,
                ),
              ],
            ),
          ),
          // The guided capture run lives in Diagnostics rather than on the
          // dashboard because it is a deliberate procedure, not a quick action —
          // the dashboard bar covers spontaneous marking.
          SettingsLinkRow(
            icon: Icons.assignment_turned_in_outlined,
            label: l10n.captureWizardTitle,
            onTap: _runCaptureWizard,
          ),
          SettingsLinkRow(
            icon: Icons.file_download_outlined,
            label: l10n.settingsExportLogLabel,
            onTap: _exportLog,
            trailing: _busy ? const _SmallSpinner() : null,
          ),
          SettingsLinkRow(
            icon: Icons.delete_outline,
            label: l10n.settingsClearLogLabel,
            onTap: _clearLog,
            last: true,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 關於 / About
// ---------------------------------------------------------------------------

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  Future<void> _copy(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    var opened = false;
    try {
      opened = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: url));
      messenger.showSnackBar(
          SnackBar(duration: const Duration(milliseconds: 1600), content: Text(l10n.commonOpenBrowserFailed(url))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: l10n.settingsAboutHeading,
      child: Column(
        children: [
          SettingsRow(
            label: l10n.settingsVersionLabel,
            sub: l10n.settingsVersionSub,
            trailing: FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snap) {
                final v = snap.hasData
                    ? 'v${snap.data!.version} (+${snap.data!.buildNumber})'
                    : '…';
                return Text(
                  v,
                  style: AppTextStyles.mono(context).copyWith(
                    color: context.colors.muted,
                  ),
                );
              },
            ),
          ),
          // Android-only: iOS updates come via TestFlight / the App Store, and
          // GitHub releases carry only the Android APK, so hide this on iOS.
          if (!Platform.isIOS)
            SettingsLinkRow(
              icon: Icons.system_update_alt,
              label: l10n.settingsCheckUpdateLabel,
              onTap: () => runUpdateCheck(context, manual: true),
            ),
          SettingsLinkRow(
            icon: Icons.code,
            label: l10n.settingsGithubLabel,
            onTap: () => _copy(context, kGithubUrl),
          ),
          SettingsLinkRow(
            icon: Icons.description_outlined,
            label: l10n.settingsProtocolDocLabel,
            onTap: () => _copy(context, kProtocolUrl),
          ),
          SettingsLinkRow(
            icon: Icons.link,
            label: l10n.settingsCopyrightLabel,
            onTap: () => _showAbout(context),
            last: true,
          ),
        ],
      ),
    );
  }
}

void _showAbout(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: context.colors.panel,
      title: Text(l10n.settingsAboutDialogTitle, style: const TextStyle(fontSize: 17)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsAboutDialogBody,
              style: TextStyle(
                  fontSize: 12.5, height: 1.7, color: context.colors.muted),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.amber.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(color: AppColors.amber.withValues(alpha: 0.28)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 15, color: AppColors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.settingsAboutDialogWarning,
                      style: const TextStyle(
                          fontSize: 11, height: 1.5, color: AppColors.amber),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.commonClose, style: const TextStyle(color: AppColors.amber)),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// shared small bits
// ---------------------------------------------------------------------------

/// Compact themed switch used by the settings rows.
///
/// A null [onChanged] renders the switch disabled but still shows its value —
/// used where a setting exists and is stored, but the platform cannot honour
/// it. Showing it disabled beats hiding it: a user who has heard of the feature
/// and cannot find it assumes they are looking in the wrong place, whereas a
/// greyed row with a reason is an answer. The stored value is left alone so the
/// choice survives a move to a platform that does support it.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      onChanged: onChanged,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _SmallSpinner extends StatelessWidget {
  const _SmallSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.amber),
    );
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  bool danger = false,
  String? confirmLabel,
}) async {
  final l10n = AppLocalizations.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: context.colors.panel,
      title: Text(title, style: const TextStyle(fontSize: 17)),
      content: Text(
        body,
        style: TextStyle(
            fontSize: 12.5, height: 1.6, color: context.colors.muted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.commonCancel, style: TextStyle(color: context.colors.muted)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            confirmLabel ?? l10n.commonConfirm,
            style: TextStyle(color: danger ? AppColors.danger : AppColors.amber),
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// FB-32: what the "raw packet log is off" dialog resolved to. Dismissing it
/// yields null, which cancels — an accidental tap outside must not ship a file
/// the user was just told is nearly empty.
enum _RawLogChoice { exportAnyway, enable }
