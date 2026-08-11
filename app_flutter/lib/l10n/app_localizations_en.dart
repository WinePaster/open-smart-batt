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
  String get navHome => 'Home';

  @override
  String get navDevices => 'Devices';

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
  String get disconnectedStalledTitle =>
      'Connected, but the device is not answering';

  @override
  String disconnectedStalledBody(int attempts) {
    return 'Bluetooth linked up, but no data came back. Tried $attempts times.';
  }

  @override
  String get disconnectedStalledHint =>
      'Close the app completely and open it again — in the one case we have measured, that is what cleared it. Waiting does not: the same fault ran for 40 minutes.';

  @override
  String get disconnectedStalledRetry => 'Try again';

  @override
  String get disconnectedGaveUpTitle => 'Could not connect to this device';

  @override
  String get disconnectedGaveUpBody =>
      'Several attempts went by without a connection, so it has stopped trying.';

  @override
  String get disconnectedGaveUpHint =>
      'Nothing more happens on its own from here. Check the unit is nearby and powered, then try again — or scan for it below.';

  @override
  String get disconnectedGaveUpAutoConnect =>
      'The device was left to come back on its own and never reappeared, so it has stopped waiting.';

  @override
  String get disconnectedGaveUpRadioHint =>
      'Nothing more happens on its own from here. Sort out the Bluetooth problem above first — connecting and scanning will both keep failing until it is fixed.';

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
  String modeUnchangedRetriedSnack(String action, int count, String status) {
    return '$action sent $count×, but the device still reports: $status. It can take a few tries or a reconnect — please try again shortly.';
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
  String get devicesConnectFailedUnreachable =>
      'This device could not be found. Check it is nearby and switched on';

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
  String devicesSavedCount(int count) {
    return 'Saved · $count';
  }

  @override
  String get deviceBadgeConnected => 'Connected';

  @override
  String get deviceBadgeConnecting => 'Connecting';

  @override
  String get deviceBadgeOffline => 'Not connected';

  @override
  String get deviceBadgeFailed => 'Connection failed';

  @override
  String get deviceBadgeNotAnswering => 'Not answering';

  @override
  String get homeAddFirstDevice => 'Add your first device';

  @override
  String get homeModuleSpeed => 'Speed';

  @override
  String get homeEditTitle => 'Edit home';

  @override
  String get homeEditAddCard => 'Add card';

  @override
  String get homeEditRestoreDefaults => 'Restore default layout';

  @override
  String get homeModuleClock => 'Clock';

  @override
  String get homeStyleTitle => 'Card appearance';

  @override
  String get homeStyleShellSection => 'Frame';

  @override
  String get homeStyleViewSection => 'Content';

  @override
  String get homeStyleApplyShellToAll => 'Apply frame to every card';

  @override
  String get cardShellStandard => 'Standard';

  @override
  String get cardShellMinimal => 'Minimal';

  @override
  String get cardShellDense => 'Compact';

  @override
  String get cardViewReadoutsGrid => 'Grid';

  @override
  String get cardViewReadoutsBig => 'Big number';

  @override
  String get cardViewGaugeDial => 'Dial';

  @override
  String get cardViewGaugeNumeric => 'Numbers';

  @override
  String get cardViewClockDigital => 'Digital';

  @override
  String get homeEditTutorialTitle => 'How editing works';

  @override
  String get homeEditTutorialDragLead =>
      'Only the handle at the top-left drags';

  @override
  String get homeEditTutorialDragBody =>
      'Hold the six-dot handle at a card\'s top-left to move it. Pressing the card itself does nothing — that is left for scrolling the page. Hold the card near the top or bottom edge and the list scrolls along with you.';

  @override
  String get homeEditTutorialDropLead =>
      'Where you let go decides what happens';

  @override
  String get homeEditTutorialDropBody =>
      'Drop on another card and the two swap places, each keeping its own width. Drop on the thin line between two rows and the card takes a row of its own. Drop into a dashed gap and it pairs with that gap\'s neighbour, becoming half width by itself.';

  @override
  String get homeEditTutorialShapeLead =>
      'The shape button switches full and half width';

  @override
  String get homeEditTutorialShapeBody =>
      'The frame button at a card\'s top-right switches it between full width and half width. A card that becomes half width gets a dashed gap beside it, waiting for a second card.';

  @override
  String get homeEditTutorialManageLead => 'Remove, add, and it saves itself';

  @override
  String get homeEditTutorialManageBody =>
      'The cross removes a card. When one card is left it turns grey, because the home page cannot be empty. \"Add card\" below lists the cards your device actually has, and \"Restore default layout\" goes back to the arrangement the app works out by itself. There is no save button — every change is already saved.';

  @override
  String get homeEditTutorialDontShowAgain => 'Don\'t show this again';

  @override
  String get homeEditTutorialGotIt => 'Got it';

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
  String get historyEmptyNoDevices =>
      'No device records yet.\nThey start accumulating once you connect a device and give it a name.';

  @override
  String get historyEmptyDeviceRange =>
      'No records for this device in the selected range.';

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
  String historyRowCurrentDirected(String amps, String direction) {
    return 'Current ${amps}A $direction';
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
      'While the app is in the background or the screen is off, recording continues for as long as the connection can be maintained. Background execution is subject to iOS scheduling and Low Power Mode, so the link is not guaranteed to stay up; periods where it is down are not recorded. Enabling this increases battery use.';

  @override
  String get settingsKeepAwakeLabel => 'Keep screen awake while connected';

  @override
  String get settingsKeepAwakeSub =>
      'Screen won\'t turn off automatically, handy for viewing while riding (active when connected)';

  @override
  String get monitorNotificationTitle => 'OpenSmartBatt · monitoring';

  @override
  String get monitorNotificationTitleConnecting =>
      'OpenSmartBatt · connecting…';

  @override
  String get monitorNotificationTitleStalled => 'OpenSmartBatt · no data';

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
  String get settingsSpeedDetectionLabel => 'Speed detection';

  @override
  String get settingsSpeedDetectionSub =>
      'Add a GPS speed card to the home page. Off by default.';

  @override
  String get settingsSpeedUnitLabel => 'Speed unit';

  @override
  String get speedConsentTitle => 'Turn on speed detection?';

  @override
  String get speedConsentIntro =>
      'This feature uses your phone\'s location. Before turning it on, please note all four of these:';

  @override
  String get speedConsentPointForeground =>
      'GPS is used only on the dashboard while the app is in the foreground; it stops when the app is backgrounded.';

  @override
  String get speedConsentPointRecorded =>
      'Speed recorded while connected is written to history and is included in the diagnostic files you export.';

  @override
  String get speedConsentPointNoLocationStored =>
      'Location coordinates are never stored and never appear in any export.';

  @override
  String get speedConsentPointBattery => 'It increases battery use.';

  @override
  String get speedConsentEnable => 'Enable';

  @override
  String get speedCardWaitingTitle => 'Waiting for a fix';

  @override
  String get speedCardWaitingBody =>
      'Acquiring the first GPS reading. This can take a few seconds after starting, or indoors.';

  @override
  String get speedCardPermissionDeniedTitle => 'No location permission';

  @override
  String get speedCardPermissionDeniedBody =>
      'The system has not granted this app location access, so speed cannot be shown.';

  @override
  String get speedCardPermissionPermanentBody =>
      'Location permission was permanently denied, so the system will not ask again. Grant \"While Using the App\" access in system settings.';

  @override
  String get speedCardOpenSystemSettings => 'Open system settings';

  @override
  String get speedCardHeld => 'Held';

  @override
  String get speedCardNoSignal => 'No signal';

  @override
  String speedCardAccuracy(String value, String unit) {
    return '±$value $unit';
  }

  @override
  String speedCardLastMeasured(String value, String unit, int seconds) {
    return 'Last measured $value $unit, $seconds s ago';
  }

  @override
  String get speedCardAccelLabel => 'Accel';

  @override
  String get speedQualityGood => 'Good';

  @override
  String get speedQualityFair => 'Fair';

  @override
  String get speedQualityPoor => 'Poor';

  @override
  String get speedQualityNone => 'No signal';

  @override
  String get gForceCardHeading => 'G meter';

  @override
  String get gForceLongLabel => 'Long';

  @override
  String get gForceLatLabel => 'Lat';

  @override
  String get gForcePeakLabel => 'Peak';

  @override
  String get gForceAccel => 'accel';

  @override
  String get gForceBrake => 'brake';

  @override
  String get gForceLeft => 'left';

  @override
  String get gForceRight => 'right';

  @override
  String get gForceResetPeakHint => 'Tap the peak to reset';

  @override
  String get settingsGMeterLabel => 'G meter';

  @override
  String get settingsGMeterSub =>
      'Add a longitudinal / lateral G card to the home page. Needs a one-off calibration. Off by default.';

  @override
  String get settingsGCalibrationLabel => 'Calibrate mount';

  @override
  String get settingsGCalibrationNever =>
      'Not calibrated yet - the card will not appear';

  @override
  String get settingsGCalibrationInvalid =>
      'Calibration is no longer valid - the mount seems to have moved';

  @override
  String settingsGCalibrationDone(String when) {
    return 'Last calibrated $when';
  }

  @override
  String get settingsGCalibrationClear => 'Clear calibration';

  @override
  String get settingsGCalibrationCleared => 'Calibration cleared.';

  @override
  String get gConsentTitle => 'Turn on the G meter?';

  @override
  String get gConsentRecorded =>
      'Longitudinal and lateral G are written into recorded history and travel inside every diagnostic export.';

  @override
  String get gConsentCalibration =>
      'The feature stays inactive until you calibrate the phone against the frame. The calibration starts right after this.';

  @override
  String get gConsentEnable => 'Enable';

  @override
  String get gConsentCancel => 'Cancel';

  @override
  String get gWizardTitle => 'Calibrate G meter';

  @override
  String get gWizardMountTitle => 'Mount the phone first';

  @override
  String get gWizardMountBody =>
      'Fix the phone to the frame the way you ride with it. The calibration describes THAT position - moving the phone afterwards means doing this again.';

  @override
  String get gWizardStart => 'Start';

  @override
  String get gWizardStillTitle => 'Hold still';

  @override
  String get gWizardStillBody =>
      'Stand the bike upright — centre stand or level ground, not the side stand — then keep still. Measuring which way is up.';

  @override
  String get gWizardMovedTitle => 'It moved';

  @override
  String get gWizardMovedBody =>
      'Something moved while measuring, so the reading would not have been gravity alone. Try again.';

  @override
  String get gWizardRetry => 'Try again';

  @override
  String get gWizardLaunchTitle => 'Now pull away in a straight line';

  @override
  String get gWizardLaunchBody =>
      'Ride off gently and straight ahead for a couple of seconds. That is how the app learns which way is forward - a launch taken while turning will point it the wrong way.';

  @override
  String get gWizardDoneTitle => 'Calibrated';

  @override
  String get gWizardDoneBody =>
      'Check it: accelerating should push the dot straight up, braking straight down. If it leans, calibrate again.';

  @override
  String get gWizardSave => 'Save';

  @override
  String get gWizardRecalibrate => 'Calibrate again';

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
      'The device is sending readings but has not said what it is. Reconnecting usually fixes this.';

  @override
  String get classPendingRetryButton => 'Reconnect';

  @override
  String get packLabelChoose => 'Set device type';

  @override
  String get powerBankSocCaption => 'SOC · State of Charge';

  @override
  String get powerBankSocSubUnknown => 'NO READING';

  @override
  String get powerBankCurrentLabel => 'Current';

  @override
  String get powerBankDesignCapacityLabel => 'Rated Capacity';

  @override
  String get powerBankSocReadoutLabel => 'Charge SOC';

  @override
  String get powerBankOutputVoltageLabel => 'Output Voltage';

  @override
  String get powerBankInputVoltageLabel => 'Input Voltage';

  @override
  String get powerBankDirectionCharging => 'CHARGING';

  @override
  String get powerBankDirectionDischarging => 'DISCHARGING';

  @override
  String get powerBankDirectionIdle => 'STANDBY';

  @override
  String get packDirectionCharging => 'CHARGING';

  @override
  String get packDirectionDischarging => 'DISCHARGING';

  @override
  String get packDirectionIdle => 'AT REST';

  @override
  String get usbPortTypeA => 'Type-A';

  @override
  String get usbPortTypeC => 'Type-C';

  @override
  String get powerPathHeading => 'Energy Path';

  @override
  String powerPathWaiting(int seconds) {
    return 'Waiting for device · connected ${seconds}s';
  }

  @override
  String get powerPathPd => 'PD';

  @override
  String get powerPathAskWhichPort => 'Which port is this?';

  @override
  String get powerPathTagOther => 'Other / not sure';

  @override
  String powerPathTagSaved(String tag) {
    return 'Reported: $tag';
  }

  @override
  String get dashboardChartHeading => 'Live Trend';

  @override
  String get dashboardChartWaiting => 'Waiting for telemetry…';

  @override
  String get dashboardTrackCurrent => 'Main current';

  @override
  String get dashboardTrackCurrentDirectionKey => '+ charge · − discharge';

  @override
  String get dashboardTrackPvlt => 'PVLT · main voltage';

  @override
  String get dashboardTrackTemperature => 'Temperature';

  @override
  String get powerBankTrackCurrent => 'Current';

  @override
  String get powerBankTrackOutput => 'Output voltage';

  @override
  String get powerBankTrackInput => 'Input voltage';

  @override
  String get powerBankTrackSoc => 'Charge level SOC';

  @override
  String get capacitorTrackSvlt => 'Secondary voltage SVLT';

  @override
  String get capacitorChartNoCurrentNote =>
      'No current track: this unit reports a constant 0 A, which is not a measurement.';

  @override
  String get explainerSpeedTitle => 'How speed is measured';

  @override
  String get explainerGForceTitle => 'How G is measured';

  @override
  String get explainerWhatIsMeasured => 'What is measured';

  @override
  String get explainerWhatIsNotDone => 'What this does not do';

  @override
  String get explainerSpeedWhat =>
      'The speed the phone\'s GNSS chip reports (Doppler), not a figure derived from positions. Coordinates are never stored and never appear in an export.';

  @override
  String get explainerSpeedHoldingLead =>
      'When the signal drops, the number shown is a HELD one, not a measured one.';

  @override
  String get explainerSpeedHolding =>
      'Tunnels, underpasses and overpasses all do it. The screen says so, and after a while it changes to “no signal”. A number marked as held is not your speed right now.';

  @override
  String get explainerSpeedStillLead => 'Anything under 3 km/h reads 0.';

  @override
  String get explainerSpeedStill =>
      'A stationary GNSS receiver invents 1–3 km/h from position jitter, and 2 km/h at a red light is an error everyone spots. The cost is that wheeling the bike, or crawling, also reads 0.';

  @override
  String get explainerSpeedNotDone =>
      'No dead reckoning from the accelerometer (integration drifts), no background recording, no track.';

  @override
  String get explainerGForceWhat =>
      'The phone\'s accelerometer, with gravity removed by the OS. Calibration is how the app learns which way the phone is facing on the bike; without it there is no “forward” and no “left” to report.';

  @override
  String get explainerGForceLeanLead =>
      'Lateral G in a corner reads low. This is a physical limit of two-wheelers.';

  @override
  String get explainerGForceLean =>
      'A motorcycle leans through a corner, and the meter reads the component along the leaned body axis. The harder the corner, the larger the shortfall: about 4% at 0.3 g, 11% at 0.5 g, 22% at 0.8 g. Cars do not have this (they do not lean), so do not compare these numbers with a car\'s.';

  @override
  String get explainerGForceNotDone =>
      'No lean angle from the gyroscope, no speed or distance derived. Only what is measured.';

  @override
  String get settingsSpeedExplainerLabel => 'How speed is measured';

  @override
  String get settingsGForceExplainerLabel => 'How G is measured';

  @override
  String get homeEditLayout => 'Edit layout';

  @override
  String get unidentifiedTitle => 'Device not recognised';

  @override
  String get unidentifiedBody =>
      'This unit reports a device type this build does not know, so nothing can be shown for it — a layout chosen by guesswork would be worse than none.\n\nExport the diagnostic log and send it to us; support for it can then be added in a later version.';
}
