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
  String get commonReleaseCutOff => 'Release Cut-off';

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
  String get dashboardDvolHeading => 'Per-Cell Voltage DVOL';

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
      'Pick a saved device to reconnect quickly, or scan for nearby RCE capacitors.';

  @override
  String get disconnectedQuickSelectHeading => 'Quick Select';

  @override
  String get disconnectedScanButton => 'Scan other devices';

  @override
  String quickPickLastValue(String value) {
    return 'Last $value V';
  }

  @override
  String get statusBadgeRunModeLabel => 'Run Mode';

  @override
  String get statusBadgeCapacitorLabel => 'Capacitor Status';

  @override
  String get statusBadgeCutOffOn => 'On';

  @override
  String get statusBadgeCutOffOff => 'Off';

  @override
  String get controlDetectCapacitor => 'Check Capacitor';

  @override
  String get statusAdvisoryNote =>
      'This unit is detected as a Supercapacitor; only supported features are shown (anti-theft appears only on battery models that support it). After releasing the cut-off, avoid re-locking; the capacitor\'s own over-voltage / under-voltage / over-temperature protection remains active.';

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
      'No nearby devices found (make sure the capacitor is powered on, Bluetooth is enabled, and you are close by)';

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
      'No records today.\nHistory is written automatically once a device is connected.';

  @override
  String get historyEmptyWarning => 'No warning or event records.';

  @override
  String get historyEmptyAll =>
      'No history yet.\nConnect a device and enable \"Auto-logging\" to start accumulating.';

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
  String get settingsKeepAwakeLabel => 'Keep screen awake while connected';

  @override
  String get settingsKeepAwakeSub =>
      'Screen won\'t turn off automatically, handy for viewing while riding (active when connected)';

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
  String get settingsAutoLogLabel => 'Auto-record';

  @override
  String get settingsAutoLogSub =>
      'Automatically write to history while connected';

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
  String get settingsRawPacketLogLabel => 'Log raw Bluetooth packets';

  @override
  String get settingsRawPacketLogSub =>
      'Logs raw TX/RX hex for reporting issues or helping decode unknown commands. Off by default';

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
}
