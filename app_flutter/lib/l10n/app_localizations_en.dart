// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonConfirm => 'OK';

  @override
  String get commonContinue => 'Continue';

  @override
  String get commonClose => 'Close';

  @override
  String get commonNormal => 'Normal';

  @override
  String get commonWarning => 'Warning';

  @override
  String get commonCutOff => 'Cut-off';

  @override
  String get commonAntiTheft => 'Anti-theft';

  @override
  String get commonReleaseCutOff => 'Restore Power';

  @override
  String get commonNoRecordsToExport => 'No records to export';

  @override
  String commonExportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String commonOpenBrowserFailed(String url) {
    return 'Could not open browser; link copied: $url';
  }

  @override
  String get relativeNever => 'Never connected';

  @override
  String get relativeJustNow => 'Just now';

  @override
  String relativeSecondsAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count seconds ago',
      one: '1 second ago',
    );
    return '$_temp0';
  }

  @override
  String relativeMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes ago',
      one: '1 minute ago',
    );
    return '$_temp0';
  }

  @override
  String relativeHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String relativeDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }

  @override
  String get navDashboard => 'Devices';

  @override
  String get navHistory => 'History';

  @override
  String get navSettings => 'Settings';

  @override
  String get disclaimerCommunityEdition =>
      'Community Self-Help Edition · COMMUNITY EDITION';

  @override
  String get disclaimerBodyPara1 =>
      'This app is an open-source tool independently developed by the community, based on public reverse-engineering research, communicating over Bluetooth with the RCE smart capacitor/battery you already own.';

  @override
  String get disclaimerBodyPara2 =>
      'This project is NOT an official RCE product and has no affiliation with the manufacturer; it is intended solely for personal, non-commercial use by owners who have purchased the hardware.';

  @override
  String get disclaimerDoNotRelock =>
      'After clearing the power cut-off, do not re-lock; the capacitor\'s own over-voltage / under-voltage / over-temperature protections remain active.';

  @override
  String get disclaimerAcknowledgeButton => 'I understand, get started';

  @override
  String get disclaimerViewGithub => 'View GitHub project and docs';

  @override
  String get updateAlreadyLatest =>
      'Already up to date (or temporarily offline)';

  @override
  String updateAvailableTitle(String tag) {
    return 'New version available $tag';
  }

  @override
  String updateAvailableBody(String version) {
    return 'Current version v$version. Go to GitHub to download the latest APK; uninstall the old version first before installing (a different signature prevents overwriting).';
  }

  @override
  String updateAvailableBodyIos(String version) {
    return 'Current version v$version. Open the GitHub release page to view the latest version and installation notes.';
  }

  @override
  String get updateLaterButton => 'Later';

  @override
  String get updateDownloadButton => 'Download';

  @override
  String dashboardDeviceTypeDetected(String type) {
    return 'Detected: $type';
  }

  @override
  String get dashboardDeviceTypeSupercapacitor => 'Supercapacitor';

  @override
  String get dashboardDeviceTypeSmartBattery => 'Smart Battery';

  @override
  String get dashboardDeviceTypePowerBank => 'Power Bank';

  @override
  String get dashboardDeviceTypeRceDevice => 'RCE Device';

  @override
  String dashboardDeviceTypeWithName(String type, String name) {
    return '$type ($name)';
  }

  @override
  String get dashboardReadoutsHeading => 'Live Readings';

  @override
  String get dashboardReadoutTemperatureLabel => 'Temperature TEMP';

  @override
  String get dashboardReadoutSvltLabel => 'Secondary Voltage SVLT';

  @override
  String get dashboardReadoutCurrentLabel => 'Main Current';

  @override
  String get dashboardReadoutSohLabel => 'Health SOH';

  @override
  String get dashboardSerialLabel => 'Serial No.';

  @override
  String get dashboardDvolHeading => 'Per-Cell Voltage DVOL';

  @override
  String get dashboardDvolPendingNote =>
      'Per-cell voltages are streaming, but the voltage-scaling factor (VADJ) has not been received yet, so the calibrated values will appear once it arrives.';

  @override
  String dashboardTelemetryStale(String age) {
    return 'Readings paused · last update $age';
  }

  @override
  String get captureMarkHeading => 'Mark what you are doing';

  @override
  String get captureMarkSub =>
      'Writes one line into the diagnostic log so we can tell which reading belongs to which situation.';

  @override
  String captureMarkSaved(String label) {
    return 'Marked: $label';
  }

  @override
  String get captureMarkPbOutA => 'Type-A output only';

  @override
  String get captureMarkPbOutC5v => 'Type-C output (5 V)';

  @override
  String get captureMarkPbOutCPd => 'Type-C output (PD)';

  @override
  String get captureMarkPbOutBoth => 'Both ports output';

  @override
  String get captureMarkPbIn => 'Charging input only';

  @override
  String get captureMarkPbIdle => 'Everything unplugged';

  @override
  String get captureMarkPackIdle => 'Idle (not charging or loaded)';

  @override
  String get captureMarkPackCharging => 'Charging';

  @override
  String get captureMarkPackLoad => 'Under load';

  @override
  String get captureMarkNote => 'Custom note';

  @override
  String get captureWizardTitle => 'Guided capture';

  @override
  String get captureWizardSub =>
      'Walks through the standard script, holding each state long enough to be usable.';

  @override
  String captureWizardStep(int n, int total) {
    return 'Step $n of $total';
  }

  @override
  String captureWizardHold(int seconds) {
    return 'Hold this state… $seconds s';
  }

  @override
  String get captureWizardHoldDone => 'Long enough — you can move on';

  @override
  String get captureWizardNext => 'Done';

  @override
  String get captureWizardSkip => 'Skip';

  @override
  String get captureWizardAbort => 'Stop';

  @override
  String get captureWizardFinished =>
      'Capture finished. Export the diagnostic log and send it to us.';

  @override
  String get dashboardProtectionHeading => 'Protection Status / Mode';

  @override
  String get gaugePvltLabel => 'PVLT · Primary Voltage';

  @override
  String get gaugeSohUnknown => 'SOH --';

  @override
  String gaugeSohValue(int soh, String label) {
    return 'SOH $soh% · Health $label';
  }

  @override
  String get gaugeSohLabelGood => 'Good';

  @override
  String get gaugeSohLabelFair => 'Fair';

  @override
  String get gaugeSohLabelDegraded => 'Degraded';

  @override
  String get disconnectedTitle => 'No device connected';

  @override
  String get disconnectedBody =>
      'Reconnect to a saved device, or scan for nearby RCE devices.';

  @override
  String get disconnectedQuickSelectHeading => 'Quick Select';

  @override
  String get disconnectedScanButton => 'Scan other devices';

  @override
  String get disconnectedConnecting => 'Connecting…';

  @override
  String disconnectedRetrying(int attempt, int max) {
    return 'Reconnecting… (attempt $attempt of $max)';
  }

  @override
  String get disconnectedRetryingBody =>
      'The device did not answer. Waiting before the next attempt — this is normal on a link that has just dropped.';

  @override
  String quickPickLastValue(String value) {
    return 'Last $value V';
  }

  @override
  String get statusBadgeRunModeLabel => 'Run Mode';

  @override
  String get statusBadgeCapacitorLabel => 'Capacitor Status';

  @override
  String get statusBadgeCapacitorUnknown => 'Unrecognised';

  @override
  String get statusBadgeCutOffOn => 'On';

  @override
  String get statusBadgeCutOffOff => 'Off';

  @override
  String get controlDetectCapacitor => 'Check Capacitor';

  @override
  String get statusAdvisoryNoteCapacitor =>
      'This unit is a super-capacitor (from the device type it reports); only the features it supports are shown. Its own over-voltage / under-voltage / over-temperature protection stays active.';

  @override
  String get statusAdvisoryNoteBattery =>
      'This unit is a smart battery (from the device type it reports). Anti-theft appears only on models that support it; after releasing the cut-off, avoid re-locking.';

  @override
  String get statusAdvisoryNoteUnclassified =>
      'The device type is not recognised yet, so a wider feature set is shown for now (anti-theft excluded). You can set the type above.';

  @override
  String get statusAdvisoryCapacitorUnknown =>
      'This unit is reporting a status this app does not recognise. It may be normal. Please export the diagnostic log (Settings) and send it to us — the log carries the detail we need.';

  @override
  String get statusAdvisoryThresholdBreach =>
      'A live reading is outside the warning range the device reports (over-voltage / under-voltage / over-temperature). This is computed by the app from the thresholds it read, not a fault reported by the device.';

  @override
  String get capacitorCheckNoData =>
      'No capacitor readings yet; please wait for live data to update.';

  @override
  String capacitorCheckReadout(String soh, String svlt, String pvlt) {
    return 'SOH $soh% · Secondary Voltage $svlt V · Primary Voltage $pvlt V';
  }

  @override
  String capacitorCheckSnack(String msg) {
    return 'Capacitor check: $msg';
  }

  @override
  String get releaseSentNoAuthSnack =>
      'Release command sent (experimental: no auth)';

  @override
  String get releaseSentSnack => 'Release cut-off command sent';

  @override
  String releaseFailedSnack(String error) {
    return 'Release failed: $error';
  }

  @override
  String get commonCutOffAction => 'Cut Off';

  @override
  String modeSentSnack(String action, String status) {
    return '$action command sent. The device currently reports: $status. This model sends no acknowledgement — watch the actual state.';
  }

  @override
  String modeSentNoAuthSnack(String action, String status) {
    return '$action command sent without auth (experimental). The device currently reports: $status.';
  }

  @override
  String modeChangedSnack(String action, String status) {
    return '$action done — the device now reports: $status.';
  }

  @override
  String modeUnchangedSnack(String action, String status) {
    return '$action command sent, but the device state did not change (still: $status).';
  }

  @override
  String modeUnchangedNoAuthSnack(String action, String status) {
    return '$action sent without auth (experimental); the device state did not change (still: $status).';
  }

  @override
  String get cutOffDialogTitle => 'Send Cut-off Command';

  @override
  String get cutOffDialogBody =>
      'Cutting off makes the battery stop supplying power. The vehicle will not start.\n\nReleasing the cut-off is NOT yet proven to work. No capture we hold shows a device responding to a mode command, and the way the auth value is derived is still being verified. If the release fails, this app cannot bring the battery back.\n\nMake sure you have another way to restore power (the vendor tool, or your dealer) before continuing. You are taking this risk yourself.';

  @override
  String get cutOffDialogConfirm => 'I understand — send it';

  @override
  String cutOffFailedSnack(String error) {
    return 'Cut-off command failed: $error';
  }

  @override
  String get cutOffDisabledNote =>
      'The cut-off command can only be sent while the device reports it is running normally.';

  @override
  String get releaseDisabledNote =>
      'The device reports it is running normally — not in cut-off or anti-theft mode, so there is nothing to restore.';

  @override
  String get antiTheftDialogTitle => 'Enable Anti-theft Mode';

  @override
  String get antiTheftDialogBody =>
      'Anti-theft mode is not fully verified and appears only on supported models. Are you sure you want to send the anti-theft command?';

  @override
  String get antiTheftSentSnack => 'Anti-theft command sent';

  @override
  String antiTheftFailedSnack(String error) {
    return 'Command failed: $error';
  }

  @override
  String get releaseConfirmTitle => 'Restore normal operation';

  @override
  String get releaseConfirmBody =>
      'Use this if your battery is in anti-theft or cut-off mode — it asks the pack to return to normal.\\n\\nThis is still an experimental function. Please use it with care.';

  @override
  String get releaseConfirmContinue => 'Restore';

  @override
  String get releaseDialogErrorAuthFormat =>
      'Invalid auth value format (use decimal or 0x hexadecimal)';

  @override
  String get releaseDialogErrorDealerLength =>
      'Dealer code must be at least 8 digits';

  @override
  String get releaseDialogBody =>
      'Sends the known-safe \"release\" command (mode 0x06). Use the cut-off password, or enter your auth values directly.';

  @override
  String get releaseDialogAuthModePassword => 'Password';

  @override
  String get releaseDialogAuthModeCode => 'Advanced: My Code';

  @override
  String get releaseDialogDealerCodeHint =>
      'Dealer code (auto-filled when connected)';

  @override
  String get releaseDialogPasswordHint => 'Cut-off password';

  @override
  String get releaseDialogCbHint => 'cb (dealer code value, e.g. 168 or 0xA8)';

  @override
  String get releaseDialogPwSumHint =>
      'pwSum (password checksum, e.g. 204 or 0xCC)';

  @override
  String get releaseDialogSkipAuthToggle =>
      'Experimental: send mode only, skip auth (unproven, fallback)';

  @override
  String get releaseDialogWarnBox =>
      'After releasing, do not re-lock; the capacitor\'s own over-voltage / under-voltage / over-temperature protection stays active.';

  @override
  String get releaseDialogConfirm => 'Confirm Release';

  @override
  String get devicesConnectFailed => 'Connection failed, please try again';

  @override
  String get devicesConnectFailedBluetoothOff =>
      'Bluetooth is off — turn it on and try again';

  @override
  String get devicesConnectFailedBluetoothUnauthorized =>
      'This app is not allowed to use Bluetooth. Enable it in Settings';

  @override
  String get devicesConnectFailedPermission =>
      'Bluetooth permission is missing. Grant it in Settings';

  @override
  String get devicesConnectFailedStale =>
      'This unit could not be found — scan again, then reconnect';

  @override
  String get devicesRemoveTitle => 'Remove device';

  @override
  String devicesRemoveBody(String alias) {
    return 'Remove \"$alias\" from your saved list? (The device itself is unaffected.)';
  }

  @override
  String get devicesRemove => 'Remove';

  @override
  String get devicesSavedSection => 'Saved devices';

  @override
  String get devicesNoSaved => 'No saved devices yet';

  @override
  String get devicesUnnamed => 'Unnamed device';

  @override
  String get devicesScanning => 'Scanning…';

  @override
  String get devicesNearbyNotFound =>
      'No nearby devices found (make sure the device is powered on, Bluetooth is enabled, and you are close by)';

  @override
  String devicesNearbyNoneVendor(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count Bluetooth devices are nearby, but none of them looks like an RCE device. If yours is missing, tap Show all above.',
      one:
          '1 Bluetooth device is nearby, but none of them looks like an RCE device. If yours is missing, tap Show all above.',
    );
    return '$_temp0';
  }

  @override
  String get devicesUnknownName => 'Unknown';

  @override
  String get devicesShowRceOnly => 'Show RCE devices only';

  @override
  String devicesShowAllWithHidden(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Show all BLE devices ($count non-RCE hidden)',
      one: 'Show all BLE devices (1 non-RCE hidden)',
    );
    return '$_temp0';
  }

  @override
  String get devicesShowAll => 'Show all BLE devices';

  @override
  String devicesMetaLastSeen(String time) {
    return 'Last $time';
  }

  @override
  String get devicesSheetTitle => 'Select device';

  @override
  String get devicesRescan => 'Rescan';

  @override
  String get devicesNearbyScanning => 'Scanning nearby…';

  @override
  String get devicesNearby => 'Nearby';

  @override
  String get devicesDisconnect => 'Disconnect';

  @override
  String get devicesConnect => 'Connect';

  @override
  String get devicesAdapterOff =>
      'Bluetooth is off. Turn on Bluetooth before scanning.';

  @override
  String get devicesAliasSuggestion1 => 'Capacitor #1 (front car)';

  @override
  String get devicesAliasSuggestion2 => 'Capacitor #2 (backup)';

  @override
  String get devicesAliasSuggestion3 => 'Motorcycle capacitor';

  @override
  String get devicesAliasRenameTitle => 'Rename';

  @override
  String get devicesAliasSaveTitle => 'Save device';

  @override
  String get devicesAliasRenameBody => 'Set a new alias for this device.';

  @override
  String get devicesAliasSaveBody =>
      'Connected successfully. Give this device a memorable alias so you can quickly reconnect from \"Saved devices\" next time.';

  @override
  String get devicesAliasSave => 'Save';

  @override
  String get devicesAliasSaveAlias => 'Save alias';

  @override
  String get devicesAliasSkip => 'Skip';

  @override
  String get devicesAliasHint => 'e.g. Capacitor #1 (front car)';

  @override
  String get historyFilterAll => 'All';

  @override
  String get historyFilterToday => 'Today';

  @override
  String get historyScopeAllDevices => 'All devices';

  @override
  String historyScopeHiddenNote(int count) {
    return '$count more record(s) are not shown: they were saved before the app had identified which unit they came from.';
  }

  @override
  String get historyFilterWarning => 'Warnings';

  @override
  String get historyExportCsv => 'Export CSV';

  @override
  String get historyExportSubject => 'OpenSmartBatt History';

  @override
  String get historyChartTodayTitle => 'Today\'s Voltage Trend';

  @override
  String get historyChartTitle => 'Voltage Trend';

  @override
  String get historyRangeToday => 'Today';

  @override
  String get historyRangeWeek => '7 days';

  @override
  String get historyRangeAll => 'All';

  @override
  String get historyLegendVoltage => 'Voltage';

  @override
  String get historyLegendTemperature => 'Temperature';

  @override
  String get historyStatMin => 'MIN';

  @override
  String get historyStatAvg => 'AVG';

  @override
  String get historyStatMax => 'MAX';

  @override
  String historyDetailSamples(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count samples',
      one: '1 sample',
    );
    return '$_temp0';
  }

  @override
  String historyLoadFailed(String error) {
    return 'Failed to load history: $error';
  }

  @override
  String get historyEmptyToday =>
      'No records today.\nThey start accumulating once a device is connected.';

  @override
  String get historyEmptyWarning => 'No warning or event records.';

  @override
  String get historyEmptyAll =>
      'No history yet.\nIt starts accumulating once a device is connected.';

  @override
  String historyFooter(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString records · Local SQLite · Export CSV / Share',
      one: '1 record · Local SQLite · Export CSV / Share',
    );
    return '$_temp0';
  }

  @override
  String get historyRowEventCutOff => 'Cut-off mode activated';

  @override
  String get historyRowEventAntiTheft => 'Anti-theft mode activated';

  @override
  String historyRowSoh(int percent) {
    return 'SOH $percent%';
  }

  @override
  String historyRowCurrent(String amps) {
    return 'Current ${amps}A';
  }

  @override
  String get historyRowThresholdWarning => 'Protection threshold warning';

  @override
  String get historyStatusEvent => 'Event';

  @override
  String get historyChartInsufficientData =>
      'Not enough data to chart (need at least 2 records)';

  @override
  String get settingsConnectionHeading => 'Connection';

  @override
  String get settingsAutoReconnectLabel => 'Auto-reconnect';

  @override
  String get settingsAutoReconnectSub =>
      'Automatically attempt to reconnect when the connection drops';

  @override
  String get settingsBackgroundMonitorLabel =>
      'Keep monitoring in the background';

  @override
  String get settingsBackgroundMonitorSubAndroid =>
      'Keeps recording while the screen is off or you switch apps; a persistent notification is shown while connected. If readings still stop, exclude this app from battery optimisation in system settings.';

  @override
  String get settingsBackgroundMonitorSubIos =>
      'iOS does not support background monitoring: readings stop when the app leaves the foreground or the screen turns off, and the link is eventually dropped by the system. Keep the app in the foreground and turn on \"Keep screen awake while connected\" below.';

  @override
  String get settingsKeepAwakeLabel => 'Keep screen awake while connected';

  @override
  String get settingsKeepAwakeSub =>
      'Screen won\'t turn off automatically, handy for viewing while riding (active when connected)';

  @override
  String get monitorNotificationTitle => 'OpenSmartBatt · monitoring';

  @override
  String get monitorNotificationStop => 'Stop';

  @override
  String get monitorChannelName => 'Background monitoring';

  @override
  String get monitorChannelDescription =>
      'Ongoing notification showing live voltage and charge while connected';

  @override
  String get settingsDisplayHeading => 'Display';

  @override
  String get settingsThemeLabel => 'Theme';

  @override
  String get settingsThemeSub => 'Interface colors (Auto: follow system)';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsThemeAuto => 'Auto';

  @override
  String get settingsTempUnitLabel => 'Temperature unit';

  @override
  String get settingsLanguageLabel => 'Language';

  @override
  String get settingsLanguageSub =>
      'Interface language (System: follow device)';

  @override
  String get settingsLanguageZhHant => '繁體中文';

  @override
  String get settingsLanguageEnglish => 'English';

  @override
  String get settingsLanguageSystem => 'System';

  @override
  String get settingsDataHeading => 'Data';

  @override
  String get settingsRetentionLabel => 'Keep history for';

  @override
  String get settingsRetentionSub =>
      'Telemetry is always recorded while connected; this decides how long it is kept. Shortening it deletes older records immediately and cannot be undone.';

  @override
  String get retention30Days => '30 days';

  @override
  String get retention90Days => '90 days';

  @override
  String get retention365Days => '1 year';

  @override
  String get retentionForever => 'Forever';

  @override
  String get settingsExportAllLabel => 'Export all data (CSV)';

  @override
  String get settingsClearHistoryLabel => 'Clear history';

  @override
  String get settingsExportSubjectAllData => 'OpenSmartBatt all data';

  @override
  String get settingsClearHistoryTitle => 'Clear history';

  @override
  String get settingsClearHistoryBody =>
      'This will delete all telemetry history on this device. This action cannot be undone.';

  @override
  String get settingsClearConfirm => 'Clear';

  @override
  String get settingsHistoryCleared => 'History cleared';

  @override
  String get settingsDiagnosticsHeading => 'Diagnostics / Developer';

  @override
  String get rawLogOffDialogTitle => 'This log will have no packet contents';

  @override
  String get rawLogOffDialogBody =>
      '\"Log raw Bluetooth packets\" is currently off, so this file will contain only connection events — none of the data the device actually sent. If you are reporting a problem to the developers, it will not help much.\n\nAfter enabling it you need to reconnect and use the device once before anything is recorded.';

  @override
  String get rawLogOffExportAnyway => 'Export anyway';

  @override
  String get rawLogOffEnable => 'Turn it on';

  @override
  String get rawLogEnabledSnack =>
      'Raw packet logging is on. Reconnect, use the device for a while, then export again.';

  @override
  String get rawLogContentsDialogTitle =>
      'This log contains your device\'s Bluetooth address';

  @override
  String get rawLogContentsDialogBody =>
      'Raw packet logging is on, so this file includes the frames the device sent — and one of them is the device reporting its own Bluetooth hardware address.\n\nThis is your own hardware, not personal data, and the device already broadcasts it to anything in range. It is kept in the file on purpose: removing it would break the frame checksums that make a capture usable as evidence.\n\nJust be aware of it before posting the file somewhere public.';

  @override
  String get rawLogContentsContinue => 'Got it, export';

  @override
  String get settingsRawPacketLogLabel => 'Log raw Bluetooth packets';

  @override
  String get settingsRawPacketLogSub =>
      'Logs raw TX/RX hex for reporting issues or helping decode unknown commands. Off by default. Includes the device\'s own Bluetooth address.';

  @override
  String get settingsLogMaxSizeLabel => 'Log size limit';

  @override
  String get settingsLogMaxSizeSub =>
      'Automatically rotates and overwrites when exceeded';

  @override
  String get settingsExportLogLabel => 'Export diagnostic log (.log)';

  @override
  String get settingsClearLogLabel => 'Clear diagnostic log';

  @override
  String get settingsLogEmpty => 'Diagnostic log is empty';

  @override
  String get settingsExportSubjectDiagLog => 'OpenSmartBatt diagnostic log';

  @override
  String get startupFailedTitle => 'Couldn\'t start';

  @override
  String get startupFailedBody =>
      'The database could not be opened. Try again first; if it keeps failing, resetting the database is the last resort (it deletes all records).';

  @override
  String get startupDowngradeTitle => 'App is older than your data';

  @override
  String startupDowngradeBody(int stored, int app) {
    return 'Your data was written by a newer version (schema v$stored); this build only supports v$app, so it was left untouched rather than risk damaging it. Please reinstall the newer app — your records are intact.';
  }

  @override
  String get startupRetry => 'Try again';

  @override
  String get startupResetDb => 'Reset database (deletes all records)';

  @override
  String get startupResetTitle => 'Reset the database?';

  @override
  String get startupResetBody =>
      'This permanently deletes all history, saved devices and settings.';

  @override
  String get exportScopeTitle => 'Export scope';

  @override
  String exportScopeThisDevice(String label) {
    return 'This device only ($label)';
  }

  @override
  String get exportScopeThisSession => 'This connection only';

  @override
  String get exportScopeAllDevices => 'All devices';

  @override
  String get settingsClearLogTitle => 'Clear diagnostic log';

  @override
  String get settingsClearLogBody =>
      'This will delete all raw TX/RX packet records on this device.';

  @override
  String get settingsLogCleared => 'Diagnostic log cleared';

  @override
  String get settingsAboutHeading => 'About';

  @override
  String get settingsVersionLabel => 'Version';

  @override
  String get settingsVersionSub => 'OpenSmartBatt Community Edition';

  @override
  String get settingsCheckUpdateLabel => 'Check for updates';

  @override
  String get settingsGithubLabel => 'GitHub project page';

  @override
  String get settingsProtocolDocLabel => 'Protocol document PROTOCOL.md';

  @override
  String get settingsCopyrightLabel => 'Copyright & disclaimer';

  @override
  String get settingsAboutDialogTitle => 'Copyright & disclaimer';

  @override
  String get settingsAboutDialogBody =>
      'This app is an independent, community-developed open-source tool based on public reverse-engineering research, communicating via Bluetooth with the RCE smart capacitor/battery you have purchased.\n\nThis project is not an official RCE product and has no affiliation with the manufacturer; it is intended solely for personal, non-commercial use by owners of the hardware.';

  @override
  String get settingsAboutDialogWarning =>
      'Do not re-lock after releasing the power cut-off; the capacitor\'s own over-voltage / under-voltage / over-temperature protection remains active.';

  @override
  String get dashboardTelemetryStalled =>
      'Readings have stopped updating (the link is still up). This happens while the system suspends the app; turning on \"Keep monitoring in the background\" avoids it.';

  @override
  String get packLabelUnclassified => 'Unclassified (tap to set)';

  @override
  String get classPendingTitle => 'Identifying device';

  @override
  String get classPendingBody =>
      'Waiting for the device to report its type. Readings are hidden until then, because the same number means different things on a pack and on a power bank.';

  @override
  String get classPendingStalledTitle => 'Connection unstable';

  @override
  String classPendingStalledBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count polls have gone unanswered, so the device has not reported its type yet.',
      one:
          'A poll has gone unanswered, so the device has not reported its type yet.',
    );
    return '$_temp0';
  }

  @override
  String get classPendingTimeoutTitle => 'Device type unavailable';

  @override
  String get classPendingTimeoutBody =>
      'The device is sending readings but has not said what it is. Reconnecting usually fixes this; you can also set the type by hand.';

  @override
  String get classPendingRevealButton => 'Show readings anyway';

  @override
  String get classPendingRetryButton => 'Reconnect';

  @override
  String get packLabelChoose => 'Set device type';

  @override
  String get powerBankSocCaption => 'SOC · State of Charge';

  @override
  String get powerBankSocSubUnknown => 'Cell -- V';

  @override
  String powerBankCellSub(String volts) {
    return 'Cell $volts V';
  }

  @override
  String get powerBankCurrentLabel => 'Current';

  @override
  String get powerBankDesignCapacityLabel => 'Rated Capacity';

  @override
  String get powerBankSocReadoutLabel => 'Charge SOC';

  @override
  String get powerBankCellVoltageLabel => 'Cell Voltage';

  @override
  String get powerBankOutputVoltageLabel => 'Output Voltage';

  @override
  String get usbPortsHeading => 'USB Ports';

  @override
  String get usbPortTypeA => 'Type-A';

  @override
  String get usbPortTypeC => 'Type-C';

  @override
  String get usbPortStateUnknown => 'Unknown';

  @override
  String get usbPortStateSupplying => 'Supplying';

  @override
  String get usbPortStateIdle => 'Idle';

  @override
  String get usbPortPendingNote =>
      'Live port status (supply / fast-charge protocol) will appear once a hardware capture pins down the port-status frame layout.';

  @override
  String get dashboardModeNumbers => 'Numbers';

  @override
  String get dashboardModeChart => 'Chart';

  @override
  String get dashboardChartWaiting => 'Waiting for telemetry…';

  @override
  String get dashboardTrackCurrent => 'Main current';

  @override
  String get dashboardTrackPvlt => 'PVLT · main voltage';

  @override
  String get dashboardTrackTemperature => 'Temperature';

  @override
  String get powerBankTrackCurrent => 'Current';

  @override
  String get powerBankTrackOutput => 'Output voltage';

  @override
  String get powerBankTrackSoc => 'Charge level SOC';

  @override
  String get capacitorTrackSvlt => 'Secondary voltage SVLT';

  @override
  String get capacitorChartNoCurrentNote =>
      'No current track: this unit reports a constant 0 A, which is not a measurement.';
}
