import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonConfirm.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get commonConfirm;

  /// No description provided for @commonContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get commonContinue;

  /// No description provided for @commonClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get commonClose;

  /// No description provided for @commonNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get commonNormal;

  /// No description provided for @commonWarning.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get commonWarning;

  /// No description provided for @commonCutOff.
  ///
  /// In en, this message translates to:
  /// **'Cut-off'**
  String get commonCutOff;

  /// No description provided for @commonAntiTheft.
  ///
  /// In en, this message translates to:
  /// **'Anti-theft'**
  String get commonAntiTheft;

  /// No description provided for @commonReleaseCutOff.
  ///
  /// In en, this message translates to:
  /// **'Restore Power'**
  String get commonReleaseCutOff;

  /// No description provided for @commonNoRecordsToExport.
  ///
  /// In en, this message translates to:
  /// **'No records to export'**
  String get commonNoRecordsToExport;

  /// No description provided for @commonExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String commonExportFailed(String error);

  /// No description provided for @commonOpenBrowserFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open browser; link copied: {url}'**
  String commonOpenBrowserFailed(String url);

  /// No description provided for @relativeNever.
  ///
  /// In en, this message translates to:
  /// **'Never connected'**
  String get relativeNever;

  /// No description provided for @relativeJustNow.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get relativeJustNow;

  /// No description provided for @relativeSecondsAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 second ago} other{{count} seconds ago}}'**
  String relativeSecondsAgo(int count);

  /// No description provided for @relativeMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute ago} other{{count} minutes ago}}'**
  String relativeMinutesAgo(int count);

  /// No description provided for @relativeHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour ago} other{{count} hours ago}}'**
  String relativeHoursAgo(int count);

  /// No description provided for @relativeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day ago} other{{count} days ago}}'**
  String relativeDaysAgo(int count);

  /// No description provided for @navHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

  /// No description provided for @navDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get navDevices;

  /// Legacy label for the pre-0046 first tab, which was the dashboard but was LABELLED 'Devices'. Unreferenced since design 0046 moved that label to navDevices; kept because deleting a shipped key is how two builds end up disagreeing about what a screenshot showed.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get navDashboard;

  /// No description provided for @navHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get navHistory;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @disclaimerCommunityEdition.
  ///
  /// In en, this message translates to:
  /// **'Community Self-Help Edition · COMMUNITY EDITION'**
  String get disclaimerCommunityEdition;

  /// No description provided for @disclaimerBodyPara1.
  ///
  /// In en, this message translates to:
  /// **'This app is an open-source tool independently developed by the community, based on public reverse-engineering research, communicating over Bluetooth with the RCE smart capacitor/battery you already own.'**
  String get disclaimerBodyPara1;

  /// No description provided for @disclaimerBodyPara2.
  ///
  /// In en, this message translates to:
  /// **'This project is NOT an official RCE product and has no affiliation with the manufacturer; it is intended solely for personal, non-commercial use by owners who have purchased the hardware.'**
  String get disclaimerBodyPara2;

  /// No description provided for @disclaimerDoNotRelock.
  ///
  /// In en, this message translates to:
  /// **'After clearing the power cut-off, do not re-lock; the capacitor\'s own over-voltage / under-voltage / over-temperature protections remain active.'**
  String get disclaimerDoNotRelock;

  /// No description provided for @disclaimerAcknowledgeButton.
  ///
  /// In en, this message translates to:
  /// **'I understand, get started'**
  String get disclaimerAcknowledgeButton;

  /// No description provided for @disclaimerViewGithub.
  ///
  /// In en, this message translates to:
  /// **'View GitHub project and docs'**
  String get disclaimerViewGithub;

  /// No description provided for @updateAlreadyLatest.
  ///
  /// In en, this message translates to:
  /// **'Already up to date (or temporarily offline)'**
  String get updateAlreadyLatest;

  /// No description provided for @updateAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'New version available {tag}'**
  String updateAvailableTitle(String tag);

  /// No description provided for @updateAvailableBody.
  ///
  /// In en, this message translates to:
  /// **'Current version v{version}. Go to GitHub to download the latest APK; uninstall the old version first before installing (a different signature prevents overwriting).'**
  String updateAvailableBody(String version);

  /// No description provided for @updateAvailableBodyIos.
  ///
  /// In en, this message translates to:
  /// **'Current version v{version}. Open the GitHub release page to view the latest version and installation notes.'**
  String updateAvailableBodyIos(String version);

  /// No description provided for @updateLaterButton.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get updateLaterButton;

  /// No description provided for @updateDownloadButton.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get updateDownloadButton;

  /// No description provided for @dashboardDeviceTypeDetected.
  ///
  /// In en, this message translates to:
  /// **'Detected: {type}'**
  String dashboardDeviceTypeDetected(String type);

  /// No description provided for @dashboardDeviceTypeSupercapacitor.
  ///
  /// In en, this message translates to:
  /// **'Supercapacitor'**
  String get dashboardDeviceTypeSupercapacitor;

  /// No description provided for @dashboardDeviceTypeSmartBattery.
  ///
  /// In en, this message translates to:
  /// **'Smart Battery'**
  String get dashboardDeviceTypeSmartBattery;

  /// No description provided for @dashboardDeviceTypePowerBank.
  ///
  /// In en, this message translates to:
  /// **'Power Bank'**
  String get dashboardDeviceTypePowerBank;

  /// No description provided for @dashboardDeviceTypeRceDevice.
  ///
  /// In en, this message translates to:
  /// **'RCE Device'**
  String get dashboardDeviceTypeRceDevice;

  /// No description provided for @dashboardDeviceTypeWithName.
  ///
  /// In en, this message translates to:
  /// **'{type} ({name})'**
  String dashboardDeviceTypeWithName(String type, String name);

  /// No description provided for @dashboardReadoutsHeading.
  ///
  /// In en, this message translates to:
  /// **'Live Readings'**
  String get dashboardReadoutsHeading;

  /// No description provided for @dashboardReadoutTemperatureLabel.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get dashboardReadoutTemperatureLabel;

  /// No description provided for @dashboardReadoutSvltLabel.
  ///
  /// In en, this message translates to:
  /// **'Secondary Voltage'**
  String get dashboardReadoutSvltLabel;

  /// No description provided for @dashboardReadoutCurrentLabel.
  ///
  /// In en, this message translates to:
  /// **'Main Current'**
  String get dashboardReadoutCurrentLabel;

  /// No description provided for @dashboardReadoutSohLabel.
  ///
  /// In en, this message translates to:
  /// **'Health SOH'**
  String get dashboardReadoutSohLabel;

  /// No description provided for @dashboardSerialLabel.
  ///
  /// In en, this message translates to:
  /// **'Serial No.'**
  String get dashboardSerialLabel;

  /// No description provided for @dashboardDvolHeading.
  ///
  /// In en, this message translates to:
  /// **'Per-Cell Voltage'**
  String get dashboardDvolHeading;

  /// No description provided for @dashboardDvolPendingNote.
  ///
  /// In en, this message translates to:
  /// **'Per-cell voltages are streaming, but the voltage-scaling factor (VADJ) has not been received yet, so the calibrated values will appear once it arrives.'**
  String get dashboardDvolPendingNote;

  /// No description provided for @dashboardTelemetryStale.
  ///
  /// In en, this message translates to:
  /// **'Readings paused · last update {age}'**
  String dashboardTelemetryStale(String age);

  /// No description provided for @captureMarkHeading.
  ///
  /// In en, this message translates to:
  /// **'Mark what you are doing'**
  String get captureMarkHeading;

  /// No description provided for @captureMarkSub.
  ///
  /// In en, this message translates to:
  /// **'Writes one line into the diagnostic log so we can tell which reading belongs to which situation.'**
  String get captureMarkSub;

  /// No description provided for @captureMarkSaved.
  ///
  /// In en, this message translates to:
  /// **'Marked: {label}'**
  String captureMarkSaved(String label);

  /// No description provided for @captureMarkPbOutA.
  ///
  /// In en, this message translates to:
  /// **'Type-A output only'**
  String get captureMarkPbOutA;

  /// No description provided for @captureMarkPbOutC5v.
  ///
  /// In en, this message translates to:
  /// **'Type-C output (5 V)'**
  String get captureMarkPbOutC5v;

  /// No description provided for @captureMarkPbOutCPd.
  ///
  /// In en, this message translates to:
  /// **'Type-C output (PD)'**
  String get captureMarkPbOutCPd;

  /// No description provided for @captureMarkPbOutBoth.
  ///
  /// In en, this message translates to:
  /// **'Both ports output'**
  String get captureMarkPbOutBoth;

  /// No description provided for @captureMarkPbIn.
  ///
  /// In en, this message translates to:
  /// **'Charging input only'**
  String get captureMarkPbIn;

  /// No description provided for @captureMarkPbIdle.
  ///
  /// In en, this message translates to:
  /// **'Everything unplugged'**
  String get captureMarkPbIdle;

  /// No description provided for @captureMarkPackIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle (not charging or loaded)'**
  String get captureMarkPackIdle;

  /// No description provided for @captureMarkPackCharging.
  ///
  /// In en, this message translates to:
  /// **'Charging'**
  String get captureMarkPackCharging;

  /// No description provided for @captureMarkPackLoad.
  ///
  /// In en, this message translates to:
  /// **'Under load'**
  String get captureMarkPackLoad;

  /// No description provided for @captureMarkNote.
  ///
  /// In en, this message translates to:
  /// **'Custom note'**
  String get captureMarkNote;

  /// No description provided for @captureWizardTitle.
  ///
  /// In en, this message translates to:
  /// **'Guided capture'**
  String get captureWizardTitle;

  /// No description provided for @captureWizardSub.
  ///
  /// In en, this message translates to:
  /// **'Walks through the standard script, holding each state long enough to be usable.'**
  String get captureWizardSub;

  /// No description provided for @captureWizardStep.
  ///
  /// In en, this message translates to:
  /// **'Step {n} of {total}'**
  String captureWizardStep(int n, int total);

  /// No description provided for @captureWizardHold.
  ///
  /// In en, this message translates to:
  /// **'Hold this state… {seconds} s'**
  String captureWizardHold(int seconds);

  /// No description provided for @captureWizardHoldDone.
  ///
  /// In en, this message translates to:
  /// **'Long enough — you can move on'**
  String get captureWizardHoldDone;

  /// No description provided for @captureWizardNext.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get captureWizardNext;

  /// No description provided for @captureWizardSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get captureWizardSkip;

  /// No description provided for @captureWizardAbort.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get captureWizardAbort;

  /// No description provided for @captureWizardFinished.
  ///
  /// In en, this message translates to:
  /// **'Capture finished. Export the diagnostic log and send it to us.'**
  String get captureWizardFinished;

  /// No description provided for @dashboardProtectionHeading.
  ///
  /// In en, this message translates to:
  /// **'Protection Status / Mode'**
  String get dashboardProtectionHeading;

  /// No description provided for @gaugePvltLabel.
  ///
  /// In en, this message translates to:
  /// **'Primary Voltage'**
  String get gaugePvltLabel;

  /// No description provided for @gaugeSohUnknown.
  ///
  /// In en, this message translates to:
  /// **'SOH --'**
  String get gaugeSohUnknown;

  /// No description provided for @gaugeSohValue.
  ///
  /// In en, this message translates to:
  /// **'SOH {soh}% · Health {label}'**
  String gaugeSohValue(int soh, String label);

  /// No description provided for @gaugeSohLabelGood.
  ///
  /// In en, this message translates to:
  /// **'Good'**
  String get gaugeSohLabelGood;

  /// No description provided for @gaugeSohLabelFair.
  ///
  /// In en, this message translates to:
  /// **'Fair'**
  String get gaugeSohLabelFair;

  /// No description provided for @gaugeSohLabelDegraded.
  ///
  /// In en, this message translates to:
  /// **'Degraded'**
  String get gaugeSohLabelDegraded;

  /// No description provided for @disconnectedTitle.
  ///
  /// In en, this message translates to:
  /// **'No device connected'**
  String get disconnectedTitle;

  /// No description provided for @disconnectedBody.
  ///
  /// In en, this message translates to:
  /// **'Reconnect to a saved device, or scan for nearby RCE devices.'**
  String get disconnectedBody;

  /// No description provided for @disconnectedQuickSelectHeading.
  ///
  /// In en, this message translates to:
  /// **'Quick Select'**
  String get disconnectedQuickSelectHeading;

  /// No description provided for @disconnectedScanButton.
  ///
  /// In en, this message translates to:
  /// **'Scan other devices'**
  String get disconnectedScanButton;

  /// No description provided for @disconnectedConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get disconnectedConnecting;

  /// No description provided for @disconnectedRetrying.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting… (attempt {attempt} of {max})'**
  String disconnectedRetrying(int attempt, int max);

  /// No description provided for @disconnectedRetryingBody.
  ///
  /// In en, this message translates to:
  /// **'The device did not answer. Waiting before the next attempt — this is normal on a link that has just dropped.'**
  String get disconnectedRetryingBody;

  /// No description provided for @disconnectedAutoConnecting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the device to come back…'**
  String get disconnectedAutoConnecting;

  /// No description provided for @disconnectedAutoConnectingBody.
  ///
  /// In en, this message translates to:
  /// **'The link dropped, so iOS is watching for this device and will connect the moment it is in range. This can take up to {minutes} minutes. You can keep waiting, or scan for it yourself below.'**
  String disconnectedAutoConnectingBody(int minutes);

  /// No description provided for @disconnectedStalledTitle.
  ///
  /// In en, this message translates to:
  /// **'Connected, but the device is not answering'**
  String get disconnectedStalledTitle;

  /// No description provided for @disconnectedStalledBody.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth linked up, but no data came back. Tried {attempts} times.'**
  String disconnectedStalledBody(int attempts);

  /// No description provided for @disconnectedStalledHint.
  ///
  /// In en, this message translates to:
  /// **'Close the app completely and open it again — in the one case we have measured, that is what cleared it. Waiting does not: the same fault ran for 40 minutes.'**
  String get disconnectedStalledHint;

  /// No description provided for @disconnectedStalledRetry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get disconnectedStalledRetry;

  /// No description provided for @disconnectedGaveUpTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not connect to this device'**
  String get disconnectedGaveUpTitle;

  /// No description provided for @disconnectedGaveUpBody.
  ///
  /// In en, this message translates to:
  /// **'Several attempts went by without a connection, so it has stopped trying.'**
  String get disconnectedGaveUpBody;

  /// No description provided for @disconnectedGaveUpHint.
  ///
  /// In en, this message translates to:
  /// **'Nothing more happens on its own from here. Check the unit is nearby and powered, then try again — or scan for it below.'**
  String get disconnectedGaveUpHint;

  /// The autoConnect watchdog expired. Deliberately not the 'several attempts' wording: the hand-off makes no attempts of ours to count.
  ///
  /// In en, this message translates to:
  /// **'The device was left to come back on its own and never reappeared, so it has stopped waiting.'**
  String get disconnectedGaveUpAutoConnect;

  /// Advice card for bluetooth_off / bluetooth_unauthorized / permission_denied. The standing hint sends the user to check the device and to scan, and neither can work with the radio down.
  ///
  /// In en, this message translates to:
  /// **'Nothing more happens on its own from here. Sort out the Bluetooth problem above first — connecting and scanning will both keep failing until it is fixed.'**
  String get disconnectedGaveUpRadioHint;

  /// Advice card for wrong_device (design 0068 C). The standing hint says 'check it is nearby and powered', which is the wrong instruction here: the unit answered, it was simply not this one.
  ///
  /// In en, this message translates to:
  /// **'The saved entry is pointing at another unit with the same name. Scan again and pick the right one, or remove this entry and add it back.'**
  String get disconnectedWrongDeviceHint;

  /// No description provided for @quickPickLastValue.
  ///
  /// In en, this message translates to:
  /// **'Last {value} V'**
  String quickPickLastValue(String value);

  /// No description provided for @statusBadgeRunModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Run Mode'**
  String get statusBadgeRunModeLabel;

  /// No description provided for @statusBadgeCapacitorLabel.
  ///
  /// In en, this message translates to:
  /// **'Capacitor Status'**
  String get statusBadgeCapacitorLabel;

  /// No description provided for @statusBadgeCapacitorUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unrecognised'**
  String get statusBadgeCapacitorUnknown;

  /// No description provided for @statusBadgeCutOffOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get statusBadgeCutOffOn;

  /// No description provided for @statusBadgeCutOffOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get statusBadgeCutOffOff;

  /// No description provided for @controlDetectCapacitor.
  ///
  /// In en, this message translates to:
  /// **'Check Capacitor'**
  String get controlDetectCapacitor;

  /// No description provided for @statusAdvisoryCapacitorUnknown.
  ///
  /// In en, this message translates to:
  /// **'This unit is reporting a status this app does not recognise. It may be normal. Please export the diagnostic log (Settings) and send it to us — the log carries the detail we need.'**
  String get statusAdvisoryCapacitorUnknown;

  /// No description provided for @statusAdvisoryThresholdBreach.
  ///
  /// In en, this message translates to:
  /// **'A live reading is outside the warning range the device reports (over-voltage / under-voltage / over-temperature). This is computed by the app from the thresholds it read, not a fault reported by the device.'**
  String get statusAdvisoryThresholdBreach;

  /// No description provided for @capacitorCheckNoData.
  ///
  /// In en, this message translates to:
  /// **'No capacitor readings yet; please wait for live data to update.'**
  String get capacitorCheckNoData;

  /// No description provided for @capacitorCheckReadout.
  ///
  /// In en, this message translates to:
  /// **'SOH {soh}% · Secondary Voltage {svlt} V · Primary Voltage {pvlt} V'**
  String capacitorCheckReadout(String soh, String svlt, String pvlt);

  /// No description provided for @capacitorCheckSnack.
  ///
  /// In en, this message translates to:
  /// **'Capacitor check: {msg}'**
  String capacitorCheckSnack(String msg);

  /// No description provided for @releaseSentNoAuthSnack.
  ///
  /// In en, this message translates to:
  /// **'Release command sent (experimental: no auth)'**
  String get releaseSentNoAuthSnack;

  /// No description provided for @releaseSentSnack.
  ///
  /// In en, this message translates to:
  /// **'Release cut-off command sent'**
  String get releaseSentSnack;

  /// No description provided for @releaseFailedSnack.
  ///
  /// In en, this message translates to:
  /// **'Release failed: {error}'**
  String releaseFailedSnack(String error);

  /// No description provided for @commonCutOffAction.
  ///
  /// In en, this message translates to:
  /// **'Cut Off'**
  String get commonCutOffAction;

  /// No description provided for @modeSentSnack.
  ///
  /// In en, this message translates to:
  /// **'{action} command sent. The device currently reports: {status}. This model sends no acknowledgement — watch the actual state.'**
  String modeSentSnack(String action, String status);

  /// No description provided for @modeSentNoAuthSnack.
  ///
  /// In en, this message translates to:
  /// **'{action} command sent without auth (experimental). The device currently reports: {status}.'**
  String modeSentNoAuthSnack(String action, String status);

  /// No description provided for @modeChangedSnack.
  ///
  /// In en, this message translates to:
  /// **'{action} done — the device now reports: {status}.'**
  String modeChangedSnack(String action, String status);

  /// No description provided for @modeUnchangedSnack.
  ///
  /// In en, this message translates to:
  /// **'{action} command sent, but the device state did not change (still: {status}).'**
  String modeUnchangedSnack(String action, String status);

  /// No description provided for @modeUnchangedNoAuthSnack.
  ///
  /// In en, this message translates to:
  /// **'{action} sent without auth (experimental); the device state did not change (still: {status}).'**
  String modeUnchangedNoAuthSnack(String action, String status);

  /// No description provided for @modeUnchangedRetriedSnack.
  ///
  /// In en, this message translates to:
  /// **'{action} sent {count}×, but the device still reports: {status}. It can take a few tries or a reconnect — please try again shortly.'**
  String modeUnchangedRetriedSnack(String action, int count, String status);

  /// No description provided for @cutOffDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Send Cut-off Command'**
  String get cutOffDialogTitle;

  /// No description provided for @cutOffDialogBody.
  ///
  /// In en, this message translates to:
  /// **'Cutting off makes the battery stop supplying power. The vehicle will not start.\n\nReleasing the cut-off is NOT yet proven to work. No capture we hold shows a device responding to a mode command, and the way the auth value is derived is still being verified. If the release fails, this app cannot bring the battery back.\n\nMake sure you have another way to restore power (the vendor tool, or your dealer) before continuing. You are taking this risk yourself.'**
  String get cutOffDialogBody;

  /// No description provided for @cutOffDialogConfirm.
  ///
  /// In en, this message translates to:
  /// **'I understand — send it'**
  String get cutOffDialogConfirm;

  /// No description provided for @cutOffFailedSnack.
  ///
  /// In en, this message translates to:
  /// **'Cut-off command failed: {error}'**
  String cutOffFailedSnack(String error);

  /// No description provided for @cutOffDisabledNote.
  ///
  /// In en, this message translates to:
  /// **'The cut-off command can only be sent while the device reports it is running normally.'**
  String get cutOffDisabledNote;

  /// No description provided for @releaseDisabledNote.
  ///
  /// In en, this message translates to:
  /// **'The device reports it is running normally — not in cut-off or anti-theft mode, so there is nothing to restore.'**
  String get releaseDisabledNote;

  /// No description provided for @antiTheftDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable Anti-theft Mode'**
  String get antiTheftDialogTitle;

  /// No description provided for @antiTheftDialogBody.
  ///
  /// In en, this message translates to:
  /// **'Anti-theft mode is not fully verified and appears only on supported models. Are you sure you want to send the anti-theft command?'**
  String get antiTheftDialogBody;

  /// No description provided for @antiTheftSentSnack.
  ///
  /// In en, this message translates to:
  /// **'Anti-theft command sent'**
  String get antiTheftSentSnack;

  /// No description provided for @antiTheftFailedSnack.
  ///
  /// In en, this message translates to:
  /// **'Command failed: {error}'**
  String antiTheftFailedSnack(String error);

  /// No description provided for @releaseConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore normal operation'**
  String get releaseConfirmTitle;

  /// No description provided for @releaseConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Use this if your battery is in anti-theft or cut-off mode — it asks the pack to return to normal.\\n\\nThis is still an experimental function. Please use it with care.'**
  String get releaseConfirmBody;

  /// No description provided for @releaseConfirmContinue.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get releaseConfirmContinue;

  /// No description provided for @releaseDialogErrorAuthFormat.
  ///
  /// In en, this message translates to:
  /// **'Invalid auth value format (use decimal or 0x hexadecimal)'**
  String get releaseDialogErrorAuthFormat;

  /// No description provided for @releaseDialogErrorDealerLength.
  ///
  /// In en, this message translates to:
  /// **'Dealer code must be at least 8 digits'**
  String get releaseDialogErrorDealerLength;

  /// No description provided for @releaseDialogBody.
  ///
  /// In en, this message translates to:
  /// **'Sends the known-safe \"release\" command (mode 0x06). Use the cut-off password, or enter your auth values directly.'**
  String get releaseDialogBody;

  /// No description provided for @releaseDialogAuthModePassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get releaseDialogAuthModePassword;

  /// No description provided for @releaseDialogAuthModeCode.
  ///
  /// In en, this message translates to:
  /// **'Advanced: My Code'**
  String get releaseDialogAuthModeCode;

  /// No description provided for @releaseDialogDealerCodeHint.
  ///
  /// In en, this message translates to:
  /// **'Dealer code (auto-filled when connected)'**
  String get releaseDialogDealerCodeHint;

  /// No description provided for @releaseDialogPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Cut-off password'**
  String get releaseDialogPasswordHint;

  /// No description provided for @releaseDialogCbHint.
  ///
  /// In en, this message translates to:
  /// **'cb (dealer code value, e.g. 168 or 0xA8)'**
  String get releaseDialogCbHint;

  /// No description provided for @releaseDialogPwSumHint.
  ///
  /// In en, this message translates to:
  /// **'pwSum (password checksum, e.g. 204 or 0xCC)'**
  String get releaseDialogPwSumHint;

  /// No description provided for @releaseDialogSkipAuthToggle.
  ///
  /// In en, this message translates to:
  /// **'Experimental: send mode only, skip auth (unproven, fallback)'**
  String get releaseDialogSkipAuthToggle;

  /// No description provided for @releaseDialogWarnBox.
  ///
  /// In en, this message translates to:
  /// **'After releasing, do not re-lock; the capacitor\'s own over-voltage / under-voltage / over-temperature protection stays active.'**
  String get releaseDialogWarnBox;

  /// No description provided for @releaseDialogConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm Release'**
  String get releaseDialogConfirm;

  /// No description provided for @devicesConnectFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed, please try again'**
  String get devicesConnectFailed;

  /// No description provided for @devicesConnectFailedBluetoothOff.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is off — turn it on and try again'**
  String get devicesConnectFailedBluetoothOff;

  /// No description provided for @devicesConnectFailedBluetoothUnauthorized.
  ///
  /// In en, this message translates to:
  /// **'This app is not allowed to use Bluetooth. Enable it in Settings'**
  String get devicesConnectFailedBluetoothUnauthorized;

  /// No description provided for @devicesConnectFailedPermission.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth permission is missing. Grant it in Settings'**
  String get devicesConnectFailedPermission;

  /// No description provided for @devicesConnectFailedStale.
  ///
  /// In en, this message translates to:
  /// **'This unit could not be found — scan again, then reconnect'**
  String get devicesConnectFailedStale;

  /// No description provided for @devicesConnectFailedUnreachable.
  ///
  /// In en, this message translates to:
  /// **'This device could not be found. Check it is nearby and switched on'**
  String get devicesConnectFailedUnreachable;

  /// No description provided for @devicesConnectFailedWrongDevice.
  ///
  /// In en, this message translates to:
  /// **'That is a different unit — its address does not match the one you saved. Disconnected'**
  String get devicesConnectFailedWrongDevice;

  /// No description provided for @devicesRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove device'**
  String get devicesRemoveTitle;

  /// No description provided for @devicesRemoveBody.
  ///
  /// In en, this message translates to:
  /// **'Remove \"{alias}\" from your saved list? (The device itself is unaffected.)'**
  String devicesRemoveBody(String alias);

  /// No description provided for @devicesRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get devicesRemove;

  /// No description provided for @devicesSavedSection.
  ///
  /// In en, this message translates to:
  /// **'Saved devices'**
  String get devicesSavedSection;

  /// No description provided for @devicesSavedCount.
  ///
  /// In en, this message translates to:
  /// **'Saved · {count}'**
  String devicesSavedCount(int count);

  /// No description provided for @deviceBadgeConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get deviceBadgeConnected;

  /// No description provided for @deviceBadgeConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get deviceBadgeConnecting;

  /// No description provided for @deviceBadgeOffline.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get deviceBadgeOffline;

  /// No description provided for @deviceBadgeFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get deviceBadgeFailed;

  /// No description provided for @deviceBadgeNotAnswering.
  ///
  /// In en, this message translates to:
  /// **'Not answering'**
  String get deviceBadgeNotAnswering;

  /// No description provided for @homeAddFirstDevice.
  ///
  /// In en, this message translates to:
  /// **'Add your first device'**
  String get homeAddFirstDevice;

  /// Home-grid heading for the GPS speed module. The other six modules reuse the headings their cards already carry (design 0046 §4.2: the home editor and the watchface picker must name a module the same way), and speed is the one with no card heading of its own.
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get homeModuleSpeed;

  /// No description provided for @homeEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit home'**
  String get homeEditTitle;

  /// No description provided for @homeEditAddCard.
  ///
  /// In en, this message translates to:
  /// **'Add card'**
  String get homeEditAddCard;

  /// No description provided for @homeEditRestoreDefaults.
  ///
  /// In en, this message translates to:
  /// **'Restore default layout'**
  String get homeEditRestoreDefaults;

  /// Heading for the clock card (design 0052), used both on the card itself and in the home editor's add menu — the card reads this same key, so there is exactly one name for the module. No AM/PM or 12/24-hour wording belongs here: the day-period abbreviation comes from Flutter's own MaterialLocalizations, and the hour format follows the operating system.
  ///
  /// In en, this message translates to:
  /// **'Clock'**
  String get homeModuleClock;

  /// Title of the home editor's per-card appearance sheet (design 0054). Deliberately not the word 'style' alone: the sheet holds TWO axes — the shell (frame, fill, spacing) and the card's own content variant.
  ///
  /// In en, this message translates to:
  /// **'Card appearance'**
  String get homeStyleTitle;

  /// Section label above the shell thumbnails. 'Frame' rather than 'style' because the difference between the three shells is pinned on the frame and the fill — see CardShell.minimal.
  ///
  /// In en, this message translates to:
  /// **'Frame'**
  String get homeStyleShellSection;

  /// Section label above the content-variant thumbnails. Shown only for a card that declares two or more views; a picker with one option is worse than no picker (design 0054 §1.1).
  ///
  /// In en, this message translates to:
  /// **'Content'**
  String get homeStyleViewSection;

  /// Applies THIS card's frame to every card on the grid. Frame only — content variants are scoped to one card and have no meaning on another. Chosen over a global setting because a second source of truth would need a precedence rule between 'global' and 'per card', and inventing one is how design 0041 happened.
  ///
  /// In en, this message translates to:
  /// **'Apply frame to every card'**
  String get homeStyleApplyShellToAll;

  /// Shell name. NEVER the stored value — the wire value is the enum name in card_shell.dart and is not localized.
  ///
  /// In en, this message translates to:
  /// **'Standard'**
  String get cardShellStandard;

  /// Shell name: no frame, no fill, a hairline between cards.
  ///
  /// In en, this message translates to:
  /// **'Minimal'**
  String get cardShellMinimal;

  /// Shell name: frame and fill kept, padding and value type tightened. 'Compact' rather than a literal translation of 'dense' — it describes what the user gets, not the token bundle.
  ///
  /// In en, this message translates to:
  /// **'Compact'**
  String get cardShellDense;

  /// Readouts card, default view: the two-column hairline grid.
  ///
  /// In en, this message translates to:
  /// **'Grid'**
  String get cardViewReadoutsGrid;

  /// Readouts card, hero view: the first item at gauge size, the rest on one line. Every value is still shown — this names an emphasis, not a shorter card.
  ///
  /// In en, this message translates to:
  /// **'Big number'**
  String get cardViewReadoutsBig;

  /// Gauge card, default view: the tick-ring dial.
  ///
  /// In en, this message translates to:
  /// **'Dial'**
  String get cardViewGaugeDial;

  /// Gauge card, numeric view: the dial removed, caption and sub-line kept.
  ///
  /// In en, this message translates to:
  /// **'Numbers'**
  String get cardViewGaugeNumeric;

  /// Clock card, V1 view: hours and minutes. The clock declares only this one today, so the picker does not appear for it.
  ///
  /// In en, this message translates to:
  /// **'Digital'**
  String get cardViewClockDigital;

  /// Title of the home-editor tutorial dialog (design 0053), and the tooltip of the help action that re-opens it.
  ///
  /// In en, this message translates to:
  /// **'How editing works'**
  String get homeEditTutorialTitle;

  /// Design 0053 step 1 lead. The six-dot Icons.drag_indicator is the ONLY Draggable in the editor; the card body sits inside an AbsorbPointer.
  ///
  /// In en, this message translates to:
  /// **'Only the handle at the top-left drags'**
  String get homeEditTutorialDragLead;

  /// Design 0053 step 1 body. The edge auto-scroll is _onDragMoved / _autoScrollTick in home_editor_page.dart.
  ///
  /// In en, this message translates to:
  /// **'Hold the six-dot handle at a card\'s top-left to move it. Pressing the card itself does nothing — that is left for scrolling the page. Hold the card near the top or bottom edge and the list scrolls along with you.'**
  String get homeEditTutorialDragBody;

  /// Design 0053 step 2 lead: the editor has three distinct drop targets.
  ///
  /// In en, this message translates to:
  /// **'Where you let go decides what happens'**
  String get homeEditTutorialDropLead;

  /// Design 0053 step 2 body. Sources: HomeGridOps.swap (each keeps its span), moveToOwnRow, moveIntoSlot (sets span half — no shape button needed first, design 0049 §3.3).
  ///
  /// In en, this message translates to:
  /// **'Drop on another card and the two swap places, each keeping its own width. Drop on the thin line between two rows and the card takes a row of its own. Drop into a dashed gap and it pairs with that gap\'s neighbour, becoming half width by itself.'**
  String get homeEditTutorialDropBody;

  /// Design 0053 step 3 lead. The control is the Icons.crop_16_9 / Icons.crop_square IconButton at a card's top-right.
  ///
  /// In en, this message translates to:
  /// **'The shape button switches full and half width'**
  String get homeEditTutorialShapeLead;

  /// Design 0053 step 3 body. HomeGridOps.toggleSpan; normalise() is what gives a new half its empty partner.
  ///
  /// In en, this message translates to:
  /// **'The frame button at a card\'s top-right switches it between full width and half width. A card that becomes half width gets a dashed gap beside it, waiting for a second card.'**
  String get homeEditTutorialShapeBody;

  /// Design 0053 step 4 lead.
  ///
  /// In en, this message translates to:
  /// **'Remove, add, and it saves itself'**
  String get homeEditTutorialManageLead;

  /// Design 0053 step 4 body. The floor is a disabled IconButton (design 0046 §4.9); _showAddSheet filters by product class; _apply calls _persist on every change.
  ///
  /// In en, this message translates to:
  /// **'The cross removes a card. When one card is left it turns grey, because the home page cannot be empty. \"Add card\" below lists the cards your device actually has, and \"Restore default layout\" goes back to the arrangement the app works out by itself. There is no save button — every change is already saved.'**
  String get homeEditTutorialManageBody;

  /// Design 0053 checkbox, above the dialog's button. Starts CHECKED; unchecking clears the marker so the dialog returns on the next visit.
  ///
  /// In en, this message translates to:
  /// **'Don\'t show this again'**
  String get homeEditTutorialDontShowAgain;

  /// The tutorial dialog's only button.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get homeEditTutorialGotIt;

  /// No description provided for @devicesNoSaved.
  ///
  /// In en, this message translates to:
  /// **'No saved devices yet'**
  String get devicesNoSaved;

  /// No description provided for @devicesUnnamed.
  ///
  /// In en, this message translates to:
  /// **'Unnamed device'**
  String get devicesUnnamed;

  /// No description provided for @devicesScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning…'**
  String get devicesScanning;

  /// No description provided for @devicesNearbyNotFound.
  ///
  /// In en, this message translates to:
  /// **'No nearby devices found (make sure the device is powered on, Bluetooth is enabled, and you are close by)'**
  String get devicesNearbyNotFound;

  /// No description provided for @devicesNearbyNoneVendor.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 Bluetooth device is nearby, but none of them looks like an RCE device. If yours is missing, tap Show all above.} other{{count} Bluetooth devices are nearby, but none of them looks like an RCE device. If yours is missing, tap Show all above.}}'**
  String devicesNearbyNoneVendor(int count);

  /// No description provided for @devicesUnknownName.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get devicesUnknownName;

  /// No description provided for @devicesShowRceOnly.
  ///
  /// In en, this message translates to:
  /// **'Show RCE devices only'**
  String get devicesShowRceOnly;

  /// No description provided for @devicesShowAllWithHidden.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Show all BLE devices (1 non-RCE hidden)} other{Show all BLE devices ({count} non-RCE hidden)}}'**
  String devicesShowAllWithHidden(int count);

  /// No description provided for @devicesShowAll.
  ///
  /// In en, this message translates to:
  /// **'Show all BLE devices'**
  String get devicesShowAll;

  /// No description provided for @devicesMetaLastSeen.
  ///
  /// In en, this message translates to:
  /// **'Last {time}'**
  String devicesMetaLastSeen(String time);

  /// No description provided for @devicesSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Select device'**
  String get devicesSheetTitle;

  /// No description provided for @devicesRescan.
  ///
  /// In en, this message translates to:
  /// **'Rescan'**
  String get devicesRescan;

  /// No description provided for @devicesNearbyScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning nearby…'**
  String get devicesNearbyScanning;

  /// No description provided for @devicesNearby.
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get devicesNearby;

  /// No description provided for @devicesDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get devicesDisconnect;

  /// No description provided for @devicesConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get devicesConnect;

  /// No description provided for @devicesAdapterOff.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is off. Turn on Bluetooth before scanning.'**
  String get devicesAdapterOff;

  /// No description provided for @devicesAliasSuggestion1.
  ///
  /// In en, this message translates to:
  /// **'Capacitor #1 (front car)'**
  String get devicesAliasSuggestion1;

  /// No description provided for @devicesAliasSuggestion2.
  ///
  /// In en, this message translates to:
  /// **'Capacitor #2 (backup)'**
  String get devicesAliasSuggestion2;

  /// No description provided for @devicesAliasSuggestion3.
  ///
  /// In en, this message translates to:
  /// **'Motorcycle capacitor'**
  String get devicesAliasSuggestion3;

  /// No description provided for @devicesAliasRenameTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get devicesAliasRenameTitle;

  /// No description provided for @devicesAliasSaveTitle.
  ///
  /// In en, this message translates to:
  /// **'Save device'**
  String get devicesAliasSaveTitle;

  /// No description provided for @devicesAliasRenameBody.
  ///
  /// In en, this message translates to:
  /// **'Set a new alias for this device.'**
  String get devicesAliasRenameBody;

  /// No description provided for @devicesAliasSaveBody.
  ///
  /// In en, this message translates to:
  /// **'Connected successfully. Give this device a memorable alias so you can quickly reconnect from \"Saved devices\" next time.'**
  String get devicesAliasSaveBody;

  /// No description provided for @devicesAliasSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get devicesAliasSave;

  /// No description provided for @devicesAliasSaveAlias.
  ///
  /// In en, this message translates to:
  /// **'Save alias'**
  String get devicesAliasSaveAlias;

  /// No description provided for @devicesAliasSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get devicesAliasSkip;

  /// No description provided for @devicesAliasHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Capacitor #1 (front car)'**
  String get devicesAliasHint;

  /// No description provided for @historyFilterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get historyFilterAll;

  /// No description provided for @historyFilterToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get historyFilterToday;

  /// No description provided for @historyScopeAllDevices.
  ///
  /// In en, this message translates to:
  /// **'All devices'**
  String get historyScopeAllDevices;

  /// No description provided for @historyScopeHiddenNote.
  ///
  /// In en, this message translates to:
  /// **'{count} more record(s) are not shown: they were saved before the app had identified which unit they came from.'**
  String historyScopeHiddenNote(int count);

  /// No description provided for @historyFilterWarning.
  ///
  /// In en, this message translates to:
  /// **'Warnings'**
  String get historyFilterWarning;

  /// No description provided for @historyExportCsv.
  ///
  /// In en, this message translates to:
  /// **'Export CSV'**
  String get historyExportCsv;

  /// No description provided for @historyExportSubject.
  ///
  /// In en, this message translates to:
  /// **'OpenSmartBatt History'**
  String get historyExportSubject;

  /// No description provided for @historyChartTodayTitle.
  ///
  /// In en, this message translates to:
  /// **'Today\'s Voltage Trend'**
  String get historyChartTodayTitle;

  /// No description provided for @historyChartTitle.
  ///
  /// In en, this message translates to:
  /// **'Voltage Trend'**
  String get historyChartTitle;

  /// No description provided for @historyRangeToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get historyRangeToday;

  /// Shortened from "7 days" by design 0083 S3. Measured with segmentedControlNaturalWidth: the three English labels needed 225.5 px at 1.0x against the device detail row's 204 px budget, so they were ALREADY ellipsising before this change; "7d" brings them to 180.5 and clears 1.0x and 1.15x on both surfaces. 1.3x and above still truncate on the detail page — see design 0083 R4.
  ///
  /// In en, this message translates to:
  /// **'7d'**
  String get historyRangeWeek;

  /// No description provided for @historyRangeAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get historyRangeAll;

  /// The custom date range — the FOURTH segment of the range control on both history surfaces, and the range line under the chart. Was the calendar button's tooltip until 2026-08-24, when design 0083 Q1 was re-ruled from case C to case A; it is on screen now, so it is read at a glance rather than on long-press.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get historyRangeCustom;

  /// No description provided for @historyCustomRangeTitle.
  ///
  /// In en, this message translates to:
  /// **'Select time range'**
  String get historyCustomRangeTitle;

  /// No description provided for @historyCustomRangeFrom.
  ///
  /// In en, this message translates to:
  /// **'From'**
  String get historyCustomRangeFrom;

  /// No description provided for @historyCustomRangeTo.
  ///
  /// In en, this message translates to:
  /// **'To'**
  String get historyCustomRangeTo;

  /// No description provided for @historyCustomRangeApply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get historyCustomRangeApply;

  /// The selected span, shown on its own line above the chart's bucket-width note. Both ends are the days the user picked, i.e. INCLUSIVE — the exclusive end stored internally is never shown, because "to Aug 16" for a range ending on the 15th reads as an off-by-one.
  ///
  /// In en, this message translates to:
  /// **'{from} – {to}'**
  String historyCustomRangeLabel(String from, String to);

  /// Tooltip on the disabled calendar button. Offering a date picker with nothing to pick from would let the user choose a span that is guaranteed empty.
  ///
  /// In en, this message translates to:
  /// **'No records for this unit yet'**
  String get historyCustomRangeNoData;

  /// The overflow menu holding Refresh and Export on the device detail history row (design 0083 case C). The two buttons collapsed into it to free the width for the calendar button, keeping the row at ONE row (design 0065 R-refresh).
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get deviceHistoryMore;

  /// No description provided for @historyLegendVoltage.
  ///
  /// In en, this message translates to:
  /// **'Voltage'**
  String get historyLegendVoltage;

  /// Legend entry for the left-axis trace when the history chart is switched to current (design 0085 案 B, FB-101). It REPLACES the voltage entry rather than joining it: the two share one axis and one colour, and only one is drawn at a time.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get historyLegendCurrent;

  /// Tooltip on the button that swaps the history chart's LEFT axis between voltage and current. Temperature keeps the right axis in both modes. Disabled, with a reason stated beside it, for a super-capacitor (constant 0 A) and for the All devices scope (families sign current the opposite way round).
  ///
  /// In en, this message translates to:
  /// **'Switch between voltage and current'**
  String get historyChartSeriesToggle;

  /// Design 0085 Q4 ③ — the ONE sentence this design adds. Shown beside the disabled voltage/current toggle when the history scope is All devices. 🔴 It must attribute the absence to the SCOPE: the chart's buckets are grouped by time and not by device_id, so a battery discharging at −3 A and a power bank discharging at +3 A would be averaged to 0 A and drawn as at rest. Wording it as plain “no current data” would state a second falsehood — that nothing was measured.
  ///
  /// In en, this message translates to:
  /// **'Current is not shown for “All devices”: battery and power-bank units sign current the opposite way round, so averaging them together would cancel the direction out. Pick one device to see its current.'**
  String get historyChartAllDevicesNoCurrentNote;

  /// No description provided for @historyLegendTemperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get historyLegendTemperature;

  /// Legend entry for the shaded min-max band behind each trend line (FB-74). The line is the bucket's mean and a bucket is 1 minute to 24 hours wide, so one over-voltage second moves it by millivolts; the band is the only thing on the chart that shows the instant happened. Unlabelled shading reads as decoration, hence a legend entry.
  ///
  /// In en, this message translates to:
  /// **'Range (min–max)'**
  String get historyLegendRange;

  /// No description provided for @historyStatMin.
  ///
  /// In en, this message translates to:
  /// **'MIN'**
  String get historyStatMin;

  /// No description provided for @historyStatAvg.
  ///
  /// In en, this message translates to:
  /// **'AVG'**
  String get historyStatAvg;

  /// No description provided for @historyStatMax.
  ///
  /// In en, this message translates to:
  /// **'MAX'**
  String get historyStatMax;

  /// No description provided for @historyDetailSamples.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 sample} other{{count} samples}}'**
  String historyDetailSamples(int count);

  /// No description provided for @historyLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load history: {error}'**
  String historyLoadFailed(String error);

  /// No description provided for @historyEmptyToday.
  ///
  /// In en, this message translates to:
  /// **'No records today.\nThey start accumulating once a device is connected.'**
  String get historyEmptyToday;

  /// Empty state for the 'warnings only' filter. The count is how many rows were ACTUALLY LOADED, never the row cap: the filter runs in Dart after the SQL LIMIT, so the screen can only speak for the newest N windows it fetched. Claiming 'no warnings' full stop was an assertion about data it had not looked at (design 0061 T12).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No records loaded, so there are no warnings to show.} =1{No warnings or events in the most recent record.} other{No warnings or events in the most recent {count} records.}}'**
  String historyEmptyWarning(int count);

  /// No description provided for @historyEmptyAll.
  ///
  /// In en, this message translates to:
  /// **'No history yet.\nIt starts accumulating once a device is connected.'**
  String get historyEmptyAll;

  /// History is empty because no device has any rows yet. It names the naming step on purpose: saving a device is a manual step the user can cancel, which is where people get stuck.
  ///
  /// In en, this message translates to:
  /// **'No device records yet.\nThey start accumulating once you connect a device and give it a name.'**
  String get historyEmptyNoDevices;

  /// The view is always scoped to one device, so 'no records' has to say WHOSE — history may well hold plenty of rows, just for another unit.
  ///
  /// In en, this message translates to:
  /// **'No records for this device in the selected range.'**
  String get historyEmptyDeviceRange;

  /// First of the two sub-tabs on a device's detail page (design 0079 Q2): the live dashboard, or — when the unit is not connected — the failure report. Kept to one word because the tab bar sits under an app bar that already carries a two-line title, and the row costs 40 dp of the live readings' height.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get deviceDetailTabLive;

  /// Second of the two sub-tabs on a device's detail page (design 0079 Q2): THIS unit's stored records. Not the same surface as the History tab in the bottom navigation bar, which spans every unit and keeps records for units that have been deleted.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get deviceDetailTabHistory;

  /// Heading of the history block embedded in the device detail page (design 0065). It has to say WHOSE records these are: the block is scoped to the unit whose page this is, which may not be the unit currently connected, and the page around it shows the connected unit's live readings.
  ///
  /// In en, this message translates to:
  /// **'This device\'s records'**
  String get deviceHistorySectionTitle;

  /// Empty state of the embedded history block. It must read as 'not started yet' rather than as 'something is broken' — since the block is expanded by default (design 0065 Q5), this is what every never-recorded device shows on open. The block itself must NEVER disappear when empty (FB-53 / design 0046 T-new-6).
  ///
  /// In en, this message translates to:
  /// **'No records for this device yet.\nThey start accumulating once it is connected.'**
  String get deviceHistoryEmpty;

  /// Warnings-only empty state on a detail page whose unit is NOT on the link. Two things it must not say. (1) 'This device has no warnings' — the filter has only seen the newest N windows, never the whole history (design 0061 T12). (2) Anything implying the check was complete: the over-voltage / under-voltage / over-temperature thresholds come off the live wire, so with no link the only classification left is the device's own reported status code. Saying so is the difference between an honest empty result and a false all-clear.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No records loaded, so there are no warnings to show.} other{No warnings or events in the most recent {count} records. Not connected, so only the status the device itself reported could be judged.}}'**
  String deviceHistoryEmptyWarningOffline(int count);

  /// Shown while the block's three queries run. The block is expanded by default, so this runs on every detail-page open; the placeholder is a FIXED height so the scroll position does not jump when the data lands (design 0065 P-5).
  ///
  /// In en, this message translates to:
  /// **'Reading this device\'s records…'**
  String get deviceHistoryLoading;

  /// The embedded list renders in slices rather than all at once. Measured 2026-08-16: 1,000 rows in a Column inflate 24,207 elements, and unlike the History tab this block is expanded on every detail-page open. Says HOW MANY more remain, so it is never a button that might do nothing.
  ///
  /// In en, this message translates to:
  /// **'Show {count} more'**
  String deviceHistoryShowMore(int count);

  /// No description provided for @deviceHistoryRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get deviceHistoryRefresh;

  /// Sits above the record list. Storage is per second since design 0061; the list aggregates to a minute so it stays readable, and this line keeps the HH:mm stamps from reading as a single stored reading. Reworded by design 0074 Q5: it used to point at the export, which was the only way to see seconds until the drill-down existed.
  ///
  /// In en, this message translates to:
  /// **'The list shows one row per minute. Tap a row to see the seconds inside it.'**
  String get historyListMinuteNote;

  /// Title of the drill-down sheet opened from a history row (design 0074).
  ///
  /// In en, this message translates to:
  /// **'Seconds in {time}'**
  String historySecondsSheetTitle(String time);

  /// How many seconds of this minute are actually stored. 🔴 The numerator only, never 'n/60' — nothing in the data says how many seconds SHOULD be there (design 0074 R2).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 second recorded} other{{count} seconds recorded}}'**
  String historySecondsCount(int count);

  /// Total `samples` behind the whole minute. Shown once in the sheet header, never per row (design 0074 Q2).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 telemetry snapshot} other{{count} telemetry snapshots}}'**
  String historySecondsSamples(int count);

  /// Shown when every row of the minute is bucket_s = 60. 🔴 It must not read as an error or as missing data (design 0074 R3), and the 60 identical seconds must not be invented (design 0061 E3).
  ///
  /// In en, this message translates to:
  /// **'This minute was recorded before the app stored per-second data, so only the minute average exists. Nothing was lost — there simply are no per-second readings for it.'**
  String get historySecondsLegacyOnly;

  /// Labels the one legacy row inside a MIXED minute (the upgrade minute holds both). It is shown rather than dropped: dropping it would be silent data loss (design 0074 §3.2).
  ///
  /// In en, this message translates to:
  /// **'Minute average — recorded before per-second storage'**
  String get historySecondsLegacyRow;

  /// The window has not ended yet, so it will keep filling up (design 0074 §3.5).
  ///
  /// In en, this message translates to:
  /// **'This minute is still being recorded.'**
  String get historySecondsInProgress;

  /// Reachable only if the rows went away between the list query and the tap — a retention purge, or a cleared history.
  ///
  /// In en, this message translates to:
  /// **'No readings stored for this minute.'**
  String get historySecondsEmpty;

  /// Tooltip/label for the button that opens the full-screen landscape chart (design 0081 Q1 = E2). It sits at the right end of the bucket-width footnote row, inside the trend card, so it is in the one place both landing sites share.
  ///
  /// In en, this message translates to:
  /// **'Expand chart'**
  String get historyChartExpand;

  /// Drawn inside a hatched gap on the LANDSCAPE chart only (design 0081 Q6 = C). Says a stretch of time holds no rows at all — the app was not connected. The embedded card uses the hatch alone (Q6 = B) because 244 px cannot hold this sentence.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Not connected for 1 minute} other{Not connected for {count} minutes}}'**
  String historyChartGapMinutes(num count);

  /// Hours form of historyChartGapMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Not connected for 1 hour} other{Not connected for {count} hours}}'**
  String historyChartGapHours(num count);

  /// The chart's bucket width is dynamic (1 minute to 24 hours) and appeared nowhere on screen before design 0061 T10.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Each point on the chart averages 1 minute} other{Each point on the chart averages {count} minutes}}'**
  String historyChartBucketMinutes(int count);

  /// Hours form of historyChartBucketMinutes; 'averages 1440 minutes' is a number nobody converts.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Each point on the chart averages 1 hour} other{Each point on the chart averages {count} hours}}'**
  String historyChartBucketHours(int count);

  /// No description provided for @historyFooter.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record · Local SQLite · Export CSV / Share} other{{count} records · Local SQLite · Export CSV / Share}}'**
  String historyFooter(int count);

  /// No description provided for @historyRowEventCutOff.
  ///
  /// In en, this message translates to:
  /// **'Cut-off mode activated'**
  String get historyRowEventCutOff;

  /// No description provided for @historyRowEventAntiTheft.
  ///
  /// In en, this message translates to:
  /// **'Anti-theft mode activated'**
  String get historyRowEventAntiTheft;

  /// No description provided for @historyRowEventCutOffAndAntiTheft.
  ///
  /// In en, this message translates to:
  /// **'Cut-off and anti-theft both activated in this minute'**
  String get historyRowEventCutOffAndAntiTheft;

  /// No description provided for @historyRowSoh.
  ///
  /// In en, this message translates to:
  /// **'SOH {percent}%'**
  String historyRowSoh(int percent);

  /// No description provided for @historyRowCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current {amps}A'**
  String historyRowCurrent(String amps);

  /// History row current for a family whose sign convention is established: the MAGNITUDE plus a direction word, so no bare signed number reaches the reader. {direction} is one of the packDirection* strings (design 0056).
  ///
  /// In en, this message translates to:
  /// **'Current {amps}A {direction}'**
  String historyRowCurrentDirected(String amps, String direction);

  /// No description provided for @historyRowThresholdWarning.
  ///
  /// In en, this message translates to:
  /// **'Protection threshold warning'**
  String get historyRowThresholdWarning;

  /// No description provided for @historyStatusEvent.
  ///
  /// In en, this message translates to:
  /// **'Event'**
  String get historyStatusEvent;

  /// No description provided for @historyChartInsufficientData.
  ///
  /// In en, this message translates to:
  /// **'Too short a span to chart yet'**
  String get historyChartInsufficientData;

  /// No description provided for @settingsConnectionHeading.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get settingsConnectionHeading;

  /// No description provided for @settingsAutoReconnectLabel.
  ///
  /// In en, this message translates to:
  /// **'Auto-reconnect'**
  String get settingsAutoReconnectLabel;

  /// No description provided for @settingsAutoReconnectSub.
  ///
  /// In en, this message translates to:
  /// **'Automatically attempt to reconnect when the connection drops'**
  String get settingsAutoReconnectSub;

  /// No description provided for @settingsBackgroundMonitorLabel.
  ///
  /// In en, this message translates to:
  /// **'Keep monitoring in the background'**
  String get settingsBackgroundMonitorLabel;

  /// No description provided for @settingsBackgroundMonitorSubAndroid.
  ///
  /// In en, this message translates to:
  /// **'Keeps recording while the screen is off or you switch apps; a persistent notification is shown while connected. If readings still stop, exclude this app from battery optimisation in system settings.'**
  String get settingsBackgroundMonitorSubAndroid;

  /// No description provided for @settingsBackgroundMonitorSubIos.
  ///
  /// In en, this message translates to:
  /// **'While the app is in the background or the screen is off, recording continues for as long as the connection can be maintained. Background execution is subject to iOS scheduling and Low Power Mode, so the link is not guaranteed to stay up; periods where it is down are not recorded. Enabling this increases battery use.'**
  String get settingsBackgroundMonitorSubIos;

  /// No description provided for @settingsKeepAwakeLabel.
  ///
  /// In en, this message translates to:
  /// **'Keep screen awake while connected'**
  String get settingsKeepAwakeLabel;

  /// No description provided for @settingsKeepAwakeSub.
  ///
  /// In en, this message translates to:
  /// **'Screen won\'t turn off automatically, handy for viewing while riding (active when connected)'**
  String get settingsKeepAwakeSub;

  /// No description provided for @monitorNotificationTitle.
  ///
  /// In en, this message translates to:
  /// **'OpenSmartBatt · monitoring'**
  String get monitorNotificationTitle;

  /// No description provided for @monitorNotificationTitleConnecting.
  ///
  /// In en, this message translates to:
  /// **'OpenSmartBatt · connecting…'**
  String get monitorNotificationTitleConnecting;

  /// No description provided for @monitorNotificationTitleStalled.
  ///
  /// In en, this message translates to:
  /// **'OpenSmartBatt · no data'**
  String get monitorNotificationTitleStalled;

  /// No description provided for @monitorNotificationStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get monitorNotificationStop;

  /// No description provided for @monitorChannelName.
  ///
  /// In en, this message translates to:
  /// **'Background monitoring'**
  String get monitorChannelName;

  /// No description provided for @monitorChannelDescription.
  ///
  /// In en, this message translates to:
  /// **'Ongoing notification showing live voltage and charge while connected'**
  String get monitorChannelDescription;

  /// No description provided for @settingsDisplayHeading.
  ///
  /// In en, this message translates to:
  /// **'Display'**
  String get settingsDisplayHeading;

  /// design 0063. Deliberately just 'Mode' rather than 'App mode' or 'Display mode': it is the first row of the Display card and the sub-line says what it does. 🔴 The VALUE labels are the ones that were argued over — see settingsAppModeAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get settingsAppModeLabel;

  /// It names ALL THREE consequences, not just the tab. Design 0063 Q3 ruled the two features are genuinely disabled rather than merely hidden, so a sub-line mentioning only the tab would leave the user to discover the rest by finding two switches they cannot touch. This row sits FIRST in the card because it changes the availability of two rows below it, and a control should be read before what it governs.
  ///
  /// In en, this message translates to:
  /// **'Simple mode removes 主頁 (Home) from the bottom menu, and turns off speed detection and the G meter with it.'**
  String get settingsAppModeSub;

  /// No description provided for @settingsAppModePersonal.
  ///
  /// In en, this message translates to:
  /// **'Personal'**
  String get settingsAppModePersonal;

  /// 🔴 RENAMED TWICE. Original text kept: ~~It was 'Diagnostic' throughout design and was renamed on the owner's ruling (design 0063 §0.8 Q8). The mode diagnoses nothing — it is three ordinary tabs — so 'Diagnostic' would send people looking for raw frames and undecoded fields that are not there. 'Advanced' promises only what it delivers: skip the dashboard, go straight to the units.~~ 🔵 2026-08-20 owner's ruling: 'Advanced' (進階) → 'Simple' (簡易), zh and en together. Same reasoning applied one step further — the mode ADDS nothing and REMOVES the home grid, speed detection and the G meter, so a label promising something more advanced overstates it in the opposite direction. The enum value `AppMode.advanced` and the ARB KEYS (settingsAppModeAdvanced / settingsDisabledByAdvancedMode) are deliberately UNCHANGED: the enum name is what is written to SharedPreferences, so renaming it would silently reset every existing user to personal mode.
  ///
  /// In en, this message translates to:
  /// **'Simple'**
  String get settingsAppModeAdvanced;

  /// design 0063 Q3 / §3.0.4. A greyed-out switch with no explanation is indistinguishable from a broken one, which is what the project's own warning about silently vanishing features is about. The second sentence is the part that matters: it promises the stored choice is still there (Q9), which is exactly what the switch's own position is showing while it is disabled.
  ///
  /// In en, this message translates to:
  /// **'Simple mode has turned this off. Switch back to Personal to restore your setting.'**
  String get settingsDisabledByAdvancedMode;

  /// No description provided for @settingsThemeLabel.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get settingsThemeLabel;

  /// No description provided for @settingsThemeSub.
  ///
  /// In en, this message translates to:
  /// **'Interface colors (Auto: follow system)'**
  String get settingsThemeSub;

  /// No description provided for @settingsThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsThemeDark;

  /// No description provided for @settingsThemeAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get settingsThemeAuto;

  /// No description provided for @settingsAccentThemeLabel.
  ///
  /// In en, this message translates to:
  /// **'Accent colour'**
  String get settingsAccentThemeLabel;

  /// No description provided for @settingsAccentThemeSub.
  ///
  /// In en, this message translates to:
  /// **'Two colours, not one — the second is what charts draw temperature with'**
  String get settingsAccentThemeSub;

  /// No description provided for @accentThemeAmber.
  ///
  /// In en, this message translates to:
  /// **'Amber'**
  String get accentThemeAmber;

  /// No description provided for @accentThemeAzure.
  ///
  /// In en, this message translates to:
  /// **'Azure'**
  String get accentThemeAzure;

  /// No description provided for @accentThemeViolet.
  ///
  /// In en, this message translates to:
  /// **'Violet'**
  String get accentThemeViolet;

  /// No description provided for @accentThemeMagenta.
  ///
  /// In en, this message translates to:
  /// **'Magenta'**
  String get accentThemeMagenta;

  /// No description provided for @accentThemeLime.
  ///
  /// In en, this message translates to:
  /// **'Lime'**
  String get accentThemeLime;

  /// No description provided for @accentThemeTeal.
  ///
  /// In en, this message translates to:
  /// **'Teal'**
  String get accentThemeTeal;

  /// No description provided for @settingsSpeedDetectionLabel.
  ///
  /// In en, this message translates to:
  /// **'Speed detection'**
  String get settingsSpeedDetectionLabel;

  /// design 0042 §3.9. The master switch is off by default because turning it on costs a location permission, continuous GNSS and a speed series inside every export. 🔴 REWRITTEN 2026-08-09 (design 0051): it used to say 'on the dashboard (adds the Riding watchface)' and both halves became false in the same commit — the watchface picker was removed and the speed module was taken off every face. A sub-line naming a surface the card is no longer on is worse than no sub-line: it sends the user who turned the switch on to look in the wrong place.
  ///
  /// In en, this message translates to:
  /// **'Add a GPS speed card to the home page. Off by default.'**
  String get settingsSpeedDetectionSub;

  /// No description provided for @settingsSpeedUnitLabel.
  ///
  /// In en, this message translates to:
  /// **'Speed unit'**
  String get settingsSpeedUnitLabel;

  /// No description provided for @speedConsentTitle.
  ///
  /// In en, this message translates to:
  /// **'Turn on speed detection?'**
  String get speedConsentTitle;

  /// No description provided for @speedConsentIntro.
  ///
  /// In en, this message translates to:
  /// **'This feature uses your phone\'s location. Before turning it on, please note all four of these:'**
  String get speedConsentIntro;

  /// No description provided for @speedConsentPointForeground.
  ///
  /// In en, this message translates to:
  /// **'GPS is used only on the dashboard while the app is in the foreground; it stops when the app is backgrounded.'**
  String get speedConsentPointForeground;

  /// design 0042 §3.9 point 2, scoped by the (b)+(d) ruling of 2026-08-07: history rows exist per connected device, so with nothing connected there is no row for a speed to join and none is written.
  ///
  /// In en, this message translates to:
  /// **'Speed recorded while connected is written to history and is included in the diagnostic files you export.'**
  String get speedConsentPointRecorded;

  /// No description provided for @speedConsentPointNoLocationStored.
  ///
  /// In en, this message translates to:
  /// **'Location coordinates are never stored and never appear in any export.'**
  String get speedConsentPointNoLocationStored;

  /// No description provided for @speedConsentPointBattery.
  ///
  /// In en, this message translates to:
  /// **'It increases battery use.'**
  String get speedConsentPointBattery;

  /// No description provided for @speedConsentEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get speedConsentEnable;

  /// No description provided for @speedCardWaitingTitle.
  ///
  /// In en, this message translates to:
  /// **'Waiting for a fix'**
  String get speedCardWaitingTitle;

  /// No description provided for @speedCardWaitingBody.
  ///
  /// In en, this message translates to:
  /// **'Acquiring the first GPS reading. This can take a few seconds after starting, or indoors.'**
  String get speedCardWaitingBody;

  /// No description provided for @speedCardPermissionDeniedTitle.
  ///
  /// In en, this message translates to:
  /// **'No location permission'**
  String get speedCardPermissionDeniedTitle;

  /// No description provided for @speedCardPermissionDeniedBody.
  ///
  /// In en, this message translates to:
  /// **'The system has not granted this app location access, so speed cannot be shown.'**
  String get speedCardPermissionDeniedBody;

  /// No description provided for @speedCardPermissionPermanentBody.
  ///
  /// In en, this message translates to:
  /// **'Location permission was permanently denied, so the system will not ask again. Grant \"While Using the App\" access in system settings.'**
  String get speedCardPermissionPermanentBody;

  /// No description provided for @speedCardOpenSystemSettings.
  ///
  /// In en, this message translates to:
  /// **'Open system settings'**
  String get speedCardOpenSystemSettings;

  /// design 0042 G2: the badge on a frozen reading. Without it a held value and a live one are indistinguishable, which is the one thing the state machine exists to prevent.
  ///
  /// In en, this message translates to:
  /// **'Held'**
  String get speedCardHeld;

  /// No description provided for @speedCardNoSignal.
  ///
  /// In en, this message translates to:
  /// **'No signal'**
  String get speedCardNoSignal;

  /// No description provided for @speedCardAccuracy.
  ///
  /// In en, this message translates to:
  /// **'±{value} {unit}'**
  String speedCardAccuracy(String value, String unit);

  /// No description provided for @speedCardLastMeasured.
  ///
  /// In en, this message translates to:
  /// **'Last measured {value} {unit}, {seconds} s ago'**
  String speedCardLastMeasured(String value, String unit, int seconds);

  /// Label of the acceleration sub-readout under the big speed number (design 0044 §3.3). The value beside it always carries a sign and its unit is the speed unit per second (km/h/s or mph/s), so this word only has to say WHICH quantity it is. The row is absent whenever there is no measured slope — it is never rendered with a zero to fill the space.
  ///
  /// In en, this message translates to:
  /// **'Accel'**
  String get speedCardAccelLabel;

  /// No description provided for @speedQualityGood.
  ///
  /// In en, this message translates to:
  /// **'Good'**
  String get speedQualityGood;

  /// No description provided for @speedQualityFair.
  ///
  /// In en, this message translates to:
  /// **'Fair'**
  String get speedQualityFair;

  /// No description provided for @speedQualityPoor.
  ///
  /// In en, this message translates to:
  /// **'Poor'**
  String get speedQualityPoor;

  /// No description provided for @speedQualityNone.
  ///
  /// In en, this message translates to:
  /// **'No signal'**
  String get speedQualityNone;

  /// Heading of the G meter card and its name in the module vocabulary (design 0045 §3.6). "G" is the racing convention for multiples of gravity and is left untranslated in both locales for that reason.
  ///
  /// In en, this message translates to:
  /// **'G meter'**
  String get gForceCardHeading;

  /// Label of the longitudinal (forward/back) G readout. Short because it sits under a two-decimal number in a three-across row; the accel/brake word beside the value says which way.
  ///
  /// In en, this message translates to:
  /// **'Long'**
  String get gForceLongLabel;

  /// Label of the lateral (side to side) G readout.
  ///
  /// In en, this message translates to:
  /// **'Lat'**
  String get gForceLatLabel;

  /// Label of the peak-hold readout. Tapping it zeroes the peaks (design 0045 Q5). Peaks never leave the current ride and are never recorded.
  ///
  /// In en, this message translates to:
  /// **'Peak'**
  String get gForcePeakLabel;

  /// Direction word beside a POSITIVE longitudinal G. Lower case: it qualifies the number rather than titling it.
  ///
  /// In en, this message translates to:
  /// **'accel'**
  String get gForceAccel;

  /// Direction word beside a NEGATIVE longitudinal G.
  ///
  /// In en, this message translates to:
  /// **'brake'**
  String get gForceBrake;

  /// Direction word beside a lateral G pointing left - i.e. a left-hand corner.
  ///
  /// In en, this message translates to:
  /// **'left'**
  String get gForceLeft;

  /// Direction word beside a lateral G pointing right.
  ///
  /// In en, this message translates to:
  /// **'right'**
  String get gForceRight;

  /// One-line hint under the readouts. The peak readout is a tap target and nothing about a number looks tappable.
  ///
  /// In en, this message translates to:
  /// **'Tap the peak to reset'**
  String get gForceResetPeakHint;

  /// Label of the G meter master switch (design 0045 Q2). Independent of speed detection: it uses the accelerometer, not GPS.
  ///
  /// In en, this message translates to:
  /// **'G meter'**
  String get settingsGMeterLabel;

  /// Sub-line of the G meter switch. It names the calibration because a user who turns this on and sees nothing has hit exactly that. 🔴 REWRITTEN 2026-08-09 (design 0051): it used to name the 'Riding' watchface, which no longer carries this card — or exists as a choice. Same reasoning as settingsSpeedDetectionSub.
  ///
  /// In en, this message translates to:
  /// **'Add a longitudinal / lateral G card to the home page. Needs a one-off calibration. Off by default.'**
  String get settingsGMeterSub;

  /// Label of the calibration row, under the switch. It both starts a first calibration and redoes an existing one (design 0045 section 3.5 - the wizard lives in Settings, never on the dashboard).
  ///
  /// In en, this message translates to:
  /// **'Calibrate mount'**
  String get settingsGCalibrationLabel;

  /// Sub-line when there is no stored calibration. It states the CONSEQUENCE rather than only the state, because design 0045 Q8 removed the dashboard placeholder that used to explain it and R1 warns this is now the likeliest long-term state.
  ///
  /// In en, this message translates to:
  /// **'Not calibrated yet - the card will not appear'**
  String get settingsGCalibrationNever;

  /// Sub-line after the still-window check rejected the stored calibration (design 0045 section 3.2).
  ///
  /// In en, this message translates to:
  /// **'Calibration is no longer valid - the mount seems to have moved'**
  String get settingsGCalibrationInvalid;

  /// Sub-line when a valid calibration exists.
  ///
  /// In en, this message translates to:
  /// **'Last calibrated {when}'**
  String settingsGCalibrationDone(String when);

  /// Destructive-ish row that discards the stored matrix. Separate from the switch: turning the feature off is not a statement about the mount.
  ///
  /// In en, this message translates to:
  /// **'Clear calibration'**
  String get settingsGCalibrationClear;

  /// Snackbar confirming the clear.
  ///
  /// In en, this message translates to:
  /// **'Calibration cleared.'**
  String get settingsGCalibrationCleared;

  /// Title of the confirmation dialog. Design 0045 Q2 ruled the switch independent of GPS but NOT free of consent, because Q4 records G values.
  ///
  /// In en, this message translates to:
  /// **'Turn on the G meter?'**
  String get gConsentTitle;

  /// First consequence. Same disclosure rule as the speed dialog: what is recorded is stated before it is recorded, not after.
  ///
  /// In en, this message translates to:
  /// **'Longitudinal and lateral G are written into recorded history and travel inside every diagnostic export.'**
  String get gConsentRecorded;

  /// Second consequence. Stated because a switch that turns on and shows nothing reads as broken.
  ///
  /// In en, this message translates to:
  /// **'The feature stays inactive until you calibrate the phone against the frame. The calibration starts right after this.'**
  String get gConsentCalibration;

  /// Confirm button.
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get gConsentEnable;

  /// Dismiss button. Cancel writes nothing at all.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get gConsentCancel;

  /// Title of the calibration wizard route.
  ///
  /// In en, this message translates to:
  /// **'Calibrate G meter'**
  String get gWizardTitle;

  /// Step 0 heading.
  ///
  /// In en, this message translates to:
  /// **'Mount the phone first'**
  String get gWizardMountTitle;

  /// Step 0 body.
  ///
  /// In en, this message translates to:
  /// **'Fix the phone to the frame the way you ride with it. The calibration describes THAT position - moving the phone afterwards means doing this again.'**
  String get gWizardMountBody;

  /// Button that begins the still measurement.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get gWizardStart;

  /// Step 1 heading.
  ///
  /// In en, this message translates to:
  /// **'Hold still'**
  String get gWizardStillTitle;

  /// Step 1 body.
  ///
  /// In en, this message translates to:
  /// **'Stand the bike upright — centre stand or level ground, not the side stand — then keep still. Measuring which way is up.'**
  String get gWizardStillBody;

  /// Shown when the still window was broken.
  ///
  /// In en, this message translates to:
  /// **'It moved'**
  String get gWizardMovedTitle;

  /// Body of the failed-motion state.
  ///
  /// In en, this message translates to:
  /// **'Something moved while measuring, so the reading would not have been gravity alone. Try again.'**
  String get gWizardMovedBody;

  /// Restarts the wizard from the still step.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get gWizardRetry;

  /// Step 2 heading.
  ///
  /// In en, this message translates to:
  /// **'Now pull away in a straight line'**
  String get gWizardLaunchTitle;

  /// Step 2 body. It says why, because the accuracy of the whole feature depends on the user understanding this one instruction.
  ///
  /// In en, this message translates to:
  /// **'Ride off gently and straight ahead for a couple of seconds. That is how the app learns which way is forward - a launch taken while turning will point it the wrong way.'**
  String get gWizardLaunchBody;

  /// Step 3 heading.
  ///
  /// In en, this message translates to:
  /// **'Calibrated'**
  String get gWizardDoneTitle;

  /// Step 3 body - the visual check that backs up the straight-launch assumption (design 0045 section 3.2).
  ///
  /// In en, this message translates to:
  /// **'Check it: accelerating should push the dot straight up, braking straight down. If it leans, calibrate again.'**
  String get gWizardDoneBody;

  /// Commits the calibration.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get gWizardSave;

  /// Discards this attempt and restarts.
  ///
  /// In en, this message translates to:
  /// **'Calibrate again'**
  String get gWizardRecalibrate;

  /// No description provided for @settingsTempUnitLabel.
  ///
  /// In en, this message translates to:
  /// **'Temperature unit'**
  String get settingsTempUnitLabel;

  /// No description provided for @settingsLanguageLabel.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguageLabel;

  /// No description provided for @settingsLanguageSub.
  ///
  /// In en, this message translates to:
  /// **'Interface language (System: follow device)'**
  String get settingsLanguageSub;

  /// No description provided for @settingsLanguageZhHant.
  ///
  /// In en, this message translates to:
  /// **'繁體中文'**
  String get settingsLanguageZhHant;

  /// No description provided for @settingsLanguageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get settingsLanguageEnglish;

  /// No description provided for @settingsLanguageSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsLanguageSystem;

  /// No description provided for @settingsDataHeading.
  ///
  /// In en, this message translates to:
  /// **'Data'**
  String get settingsDataHeading;

  /// No description provided for @settingsRetentionLabel.
  ///
  /// In en, this message translates to:
  /// **'Keep history for'**
  String get settingsRetentionLabel;

  /// No description provided for @settingsRetentionSub.
  ///
  /// In en, this message translates to:
  /// **'Telemetry is always recorded while connected; this decides how long it is kept. Shortening it deletes older records immediately and cannot be undone.'**
  String get settingsRetentionSub;

  /// No description provided for @retention30Days.
  ///
  /// In en, this message translates to:
  /// **'30 days'**
  String get retention30Days;

  /// No description provided for @retention90Days.
  ///
  /// In en, this message translates to:
  /// **'90 days'**
  String get retention90Days;

  /// No description provided for @retention365Days.
  ///
  /// In en, this message translates to:
  /// **'1 year'**
  String get retention365Days;

  /// No description provided for @retentionForever.
  ///
  /// In en, this message translates to:
  /// **'Forever'**
  String get retentionForever;

  /// design 0061 T8c. Per-second storage costs roughly 360 MB a unit a year against 6 MB before, and existing phones keep 'forever', so the retention control above this needs a number beside it to be a real choice.
  ///
  /// In en, this message translates to:
  /// **'History storage used'**
  String get settingsHistorySizeLabel;

  /// Both figures are estimates from this phone's own data - rows so far, and the rate they arrived at. Never shown as 0.
  ///
  /// In en, this message translates to:
  /// **'Currently {used}; grows by roughly {perYear} a year at this rate. The retention setting above controls this.'**
  String settingsHistorySizeSub(String used, String perYear);

  /// Used when there is under a day of history, which is too short a span to extrapolate a yearly rate from honestly.
  ///
  /// In en, this message translates to:
  /// **'Currently {used}. The retention setting above controls this.'**
  String settingsHistorySizeSubShort(String used);

  /// No description provided for @settingsExportAllLabel.
  ///
  /// In en, this message translates to:
  /// **'Export all data (CSV)'**
  String get settingsExportAllLabel;

  /// No description provided for @settingsClearHistoryLabel.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get settingsClearHistoryLabel;

  /// No description provided for @settingsExportSubjectAllData.
  ///
  /// In en, this message translates to:
  /// **'OpenSmartBatt all data'**
  String get settingsExportSubjectAllData;

  /// No description provided for @settingsClearHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get settingsClearHistoryTitle;

  /// No description provided for @settingsClearHistoryBody.
  ///
  /// In en, this message translates to:
  /// **'This will delete all telemetry history on this device. This action cannot be undone.'**
  String get settingsClearHistoryBody;

  /// No description provided for @settingsClearConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get settingsClearConfirm;

  /// No description provided for @settingsHistoryCleared.
  ///
  /// In en, this message translates to:
  /// **'History cleared'**
  String get settingsHistoryCleared;

  /// No description provided for @settingsDiagnosticsHeading.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics / Developer'**
  String get settingsDiagnosticsHeading;

  /// No description provided for @rawLogOffDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'This log will have no packet contents'**
  String get rawLogOffDialogTitle;

  /// No description provided for @rawLogOffDialogBody.
  ///
  /// In en, this message translates to:
  /// **'\"Log raw Bluetooth packets\" is currently off, so this file will contain only connection events — none of the data the device actually sent. If you are reporting a problem to the developers, it will not help much.\n\nAfter enabling it you need to reconnect and use the device once before anything is recorded.'**
  String get rawLogOffDialogBody;

  /// No description provided for @rawLogOffExportAnyway.
  ///
  /// In en, this message translates to:
  /// **'Export anyway'**
  String get rawLogOffExportAnyway;

  /// No description provided for @rawLogOffEnable.
  ///
  /// In en, this message translates to:
  /// **'Turn it on'**
  String get rawLogOffEnable;

  /// No description provided for @rawLogEnabledSnack.
  ///
  /// In en, this message translates to:
  /// **'Raw packet logging is on. Reconnect, use the device for a while, then export again.'**
  String get rawLogEnabledSnack;

  /// No description provided for @rawLogContentsDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'This log contains your device\'s Bluetooth address'**
  String get rawLogContentsDialogTitle;

  /// No description provided for @rawLogContentsDialogBody.
  ///
  /// In en, this message translates to:
  /// **'Raw packet logging is on, so this file includes the frames the device sent — and one of them is the device reporting its own Bluetooth hardware address.\n\nThis is your own hardware, not personal data, and the device already broadcasts it to anything in range. It is kept in the file on purpose: removing it would break the frame checksums that make a capture usable as evidence.\n\nJust be aware of it before posting the file somewhere public.'**
  String get rawLogContentsDialogBody;

  /// No description provided for @rawLogContentsContinue.
  ///
  /// In en, this message translates to:
  /// **'Got it, export'**
  String get rawLogContentsContinue;

  /// No description provided for @settingsRawPacketLogLabel.
  ///
  /// In en, this message translates to:
  /// **'Log raw Bluetooth packets'**
  String get settingsRawPacketLogLabel;

  /// No description provided for @settingsRawPacketLogSub.
  ///
  /// In en, this message translates to:
  /// **'Logs raw TX/RX hex for reporting issues or helping decode unknown commands. Off by default. Includes the device\'s own Bluetooth address.'**
  String get settingsRawPacketLogSub;

  /// No description provided for @settingsLogMaxSizeLabel.
  ///
  /// In en, this message translates to:
  /// **'Log size limit'**
  String get settingsLogMaxSizeLabel;

  /// No description provided for @settingsLogMaxSizeSub.
  ///
  /// In en, this message translates to:
  /// **'Automatically rotates and overwrites when exceeded'**
  String get settingsLogMaxSizeSub;

  /// No description provided for @settingsLogMaxUnlimited.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get settingsLogMaxUnlimited;

  /// No description provided for @settingsExportLogLabel.
  ///
  /// In en, this message translates to:
  /// **'Export diagnostic log (.log)'**
  String get settingsExportLogLabel;

  /// No description provided for @settingsClearLogLabel.
  ///
  /// In en, this message translates to:
  /// **'Clear diagnostic log'**
  String get settingsClearLogLabel;

  /// No description provided for @settingsLogEmpty.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic log is empty'**
  String get settingsLogEmpty;

  /// No description provided for @settingsExportSubjectDiagLog.
  ///
  /// In en, this message translates to:
  /// **'OpenSmartBatt diagnostic log'**
  String get settingsExportSubjectDiagLog;

  /// No description provided for @startupFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t start'**
  String get startupFailedTitle;

  /// No description provided for @startupFailedBody.
  ///
  /// In en, this message translates to:
  /// **'The database could not be opened. Try again first; if it keeps failing, resetting the database is the last resort (it deletes all records).'**
  String get startupFailedBody;

  /// No description provided for @startupDowngradeTitle.
  ///
  /// In en, this message translates to:
  /// **'App is older than your data'**
  String get startupDowngradeTitle;

  /// No description provided for @startupDowngradeBody.
  ///
  /// In en, this message translates to:
  /// **'Your data was written by a newer version (schema v{stored}); this build only supports v{app}, so it was left untouched rather than risk damaging it. Please reinstall the newer app — your records are intact.'**
  String startupDowngradeBody(int stored, int app);

  /// No description provided for @startupRetry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get startupRetry;

  /// No description provided for @startupResetDb.
  ///
  /// In en, this message translates to:
  /// **'Reset database (deletes all records)'**
  String get startupResetDb;

  /// No description provided for @startupResetTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset the database?'**
  String get startupResetTitle;

  /// No description provided for @startupResetBody.
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes all history, saved devices and settings.'**
  String get startupResetBody;

  /// Heading of the export sheet's granularity picker (design 0061 T4c). Storage is per second; this decides what a row of the FILE is.
  ///
  /// In en, this message translates to:
  /// **'Level of detail'**
  String get exportResolutionTitle;

  /// No description provided for @exportResolutionMinute.
  ///
  /// In en, this message translates to:
  /// **'One row per minute (averaged)'**
  String get exportResolutionMinute;

  /// The default. The judgement behind it is design 0030 Q4b's: can the reporter actually send the file. Seven days is about 12 MB this way and about 77 MB per second.
  ///
  /// In en, this message translates to:
  /// **'Smaller file — easy to send by LINE or email.'**
  String get exportResolutionMinuteSub;

  /// No description provided for @exportResolutionSecond.
  ///
  /// In en, this message translates to:
  /// **'One row per second (full detail)'**
  String get exportResolutionSecond;

  /// Stands on its own as the qualitative fallback: when the size estimate cannot be computed, this sentence is all the user gets, and it must still be enough to decide on (design 0061 Q4 condition 3 — never show a fabricated 0 MB).
  ///
  /// In en, this message translates to:
  /// **'Shows moment-to-moment changes such as a start-up surge. Much larger file.'**
  String get exportResolutionSecondSub;

  /// Appended to a granularity option once its size has been counted. Approximate by construction — rows x a measured bytes-per-row figure — hence 'about'.
  ///
  /// In en, this message translates to:
  /// **'About {size}.'**
  String exportResolutionApproxSize(String size);

  /// No description provided for @exportScopeTitle.
  ///
  /// In en, this message translates to:
  /// **'Export scope'**
  String get exportScopeTitle;

  /// No description provided for @exportScopeThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device only ({label})'**
  String exportScopeThisDevice(String label);

  /// No description provided for @exportScopeThisSession.
  ///
  /// In en, this message translates to:
  /// **'This connection only'**
  String get exportScopeThisSession;

  /// No description provided for @exportScopeAllDevices.
  ///
  /// In en, this message translates to:
  /// **'All devices'**
  String get exportScopeAllDevices;

  /// No description provided for @settingsClearLogTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear diagnostic log'**
  String get settingsClearLogTitle;

  /// No description provided for @settingsClearLogBody.
  ///
  /// In en, this message translates to:
  /// **'This will delete all raw TX/RX packet records on this device.'**
  String get settingsClearLogBody;

  /// No description provided for @settingsLogCleared.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic log cleared'**
  String get settingsLogCleared;

  /// No description provided for @settingsAboutHeading.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAboutHeading;

  /// No description provided for @settingsVersionLabel.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get settingsVersionLabel;

  /// No description provided for @settingsVersionSub.
  ///
  /// In en, this message translates to:
  /// **'OpenSmartBatt Community Edition'**
  String get settingsVersionSub;

  /// No description provided for @settingsCheckUpdateLabel.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get settingsCheckUpdateLabel;

  /// No description provided for @settingsGithubLabel.
  ///
  /// In en, this message translates to:
  /// **'GitHub project page'**
  String get settingsGithubLabel;

  /// No description provided for @settingsProtocolDocLabel.
  ///
  /// In en, this message translates to:
  /// **'Protocol document PROTOCOL.md'**
  String get settingsProtocolDocLabel;

  /// No description provided for @settingsCopyrightLabel.
  ///
  /// In en, this message translates to:
  /// **'Copyright & disclaimer'**
  String get settingsCopyrightLabel;

  /// No description provided for @settingsAboutDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Copyright & disclaimer'**
  String get settingsAboutDialogTitle;

  /// No description provided for @settingsAboutDialogBody.
  ///
  /// In en, this message translates to:
  /// **'This app is an independent, community-developed open-source tool based on public reverse-engineering research, communicating via Bluetooth with the RCE smart capacitor/battery you have purchased.\n\nThis project is not an official RCE product and has no affiliation with the manufacturer; it is intended solely for personal, non-commercial use by owners of the hardware.'**
  String get settingsAboutDialogBody;

  /// No description provided for @settingsAboutDialogWarning.
  ///
  /// In en, this message translates to:
  /// **'Do not re-lock after releasing the power cut-off; the capacitor\'s own over-voltage / under-voltage / over-temperature protection remains active.'**
  String get settingsAboutDialogWarning;

  /// No description provided for @dashboardTelemetryStalled.
  ///
  /// In en, this message translates to:
  /// **'Readings have stopped updating (the link is still up). This happens while the system suspends the app; turning on \"Keep monitoring in the background\" avoids it.'**
  String get dashboardTelemetryStalled;

  /// No description provided for @packLabelUnclassified.
  ///
  /// In en, this message translates to:
  /// **'Unclassified (tap to set)'**
  String get packLabelUnclassified;

  /// No description provided for @classPendingTitle.
  ///
  /// In en, this message translates to:
  /// **'Identifying device'**
  String get classPendingTitle;

  /// No description provided for @classPendingBody.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the device to report its type. Readings are hidden until then, because the same number means different things on a pack and on a power bank.'**
  String get classPendingBody;

  /// No description provided for @classPendingStalledTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection unstable'**
  String get classPendingStalledTitle;

  /// No description provided for @classPendingStalledBody.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{A poll has gone unanswered, so the device has not reported its type yet.} other{{count} polls have gone unanswered, so the device has not reported its type yet.}}'**
  String classPendingStalledBody(int count);

  /// No description provided for @classPendingTimeoutTitle.
  ///
  /// In en, this message translates to:
  /// **'Device type unavailable'**
  String get classPendingTimeoutTitle;

  /// No description provided for @classPendingTimeoutBody.
  ///
  /// In en, this message translates to:
  /// **'The device is sending readings but has not said what it is. Reconnecting usually fixes this.'**
  String get classPendingTimeoutBody;

  /// No description provided for @classPendingRetryButton.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get classPendingRetryButton;

  /// No description provided for @packLabelChoose.
  ///
  /// In en, this message translates to:
  /// **'Set device type'**
  String get packLabelChoose;

  /// No description provided for @powerBankSocCaption.
  ///
  /// In en, this message translates to:
  /// **'SOC · State of Charge'**
  String get powerBankSocCaption;

  /// No description provided for @powerBankSocSubUnknown.
  ///
  /// In en, this message translates to:
  /// **'NO READING'**
  String get powerBankSocSubUnknown;

  /// No description provided for @powerBankCurrentLabel.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get powerBankCurrentLabel;

  /// No description provided for @powerBankDesignCapacityLabel.
  ///
  /// In en, this message translates to:
  /// **'Rated Capacity'**
  String get powerBankDesignCapacityLabel;

  /// No description provided for @powerBankSocReadoutLabel.
  ///
  /// In en, this message translates to:
  /// **'Charge SOC'**
  String get powerBankSocReadoutLabel;

  /// No description provided for @powerBankOutputVoltageLabel.
  ///
  /// In en, this message translates to:
  /// **'Output Voltage'**
  String get powerBankOutputVoltageLabel;

  /// No description provided for @powerBankInputVoltageLabel.
  ///
  /// In en, this message translates to:
  /// **'Input Voltage'**
  String get powerBankInputVoltageLabel;

  /// No description provided for @powerBankDirectionCharging.
  ///
  /// In en, this message translates to:
  /// **'CHARGING'**
  String get powerBankDirectionCharging;

  /// No description provided for @powerBankDirectionDischarging.
  ///
  /// In en, this message translates to:
  /// **'DISCHARGING'**
  String get powerBankDirectionDischarging;

  /// No description provided for @powerBankDirectionIdle.
  ///
  /// In en, this message translates to:
  /// **'STANDBY'**
  String get powerBankDirectionIdle;

  /// Badge under a pack's main-current reading, shown when 0x2E is positive. Deliberately NOT the powerBankDirection* keys: the two families sign current the opposite way round, and one shared key would invite a caller to reuse the wrong derivation (design 0056).
  ///
  /// In en, this message translates to:
  /// **'CHARGING'**
  String get packDirectionCharging;

  /// No description provided for @packDirectionDischarging.
  ///
  /// In en, this message translates to:
  /// **'DISCHARGING'**
  String get packDirectionDischarging;

  /// Pack current inside the quantisation dead-band: a magnitude, no direction. 'At rest' rather than 'standby' — a vehicle battery is never on standby, it is parked.
  ///
  /// In en, this message translates to:
  /// **'AT REST'**
  String get packDirectionIdle;

  /// No description provided for @usbPortTypeA.
  ///
  /// In en, this message translates to:
  /// **'Type-A'**
  String get usbPortTypeA;

  /// No description provided for @usbPortTypeC.
  ///
  /// In en, this message translates to:
  /// **'Type-C'**
  String get usbPortTypeC;

  /// No description provided for @powerPathHeading.
  ///
  /// In en, this message translates to:
  /// **'Energy Path'**
  String get powerPathHeading;

  /// No description provided for @powerPathWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for device · connected {seconds}s'**
  String powerPathWaiting(int seconds);

  /// No description provided for @powerPathPd.
  ///
  /// In en, this message translates to:
  /// **'PD'**
  String get powerPathPd;

  /// No description provided for @powerPathAskWhichPort.
  ///
  /// In en, this message translates to:
  /// **'Which port is this?'**
  String get powerPathAskWhichPort;

  /// No description provided for @powerPathTagOther.
  ///
  /// In en, this message translates to:
  /// **'Other / not sure'**
  String get powerPathTagOther;

  /// No description provided for @powerPathTagSaved.
  ///
  /// In en, this message translates to:
  /// **'Reported: {tag}'**
  String powerPathTagSaved(String tag);

  /// No description provided for @dashboardChartHeading.
  ///
  /// In en, this message translates to:
  /// **'Live Trend'**
  String get dashboardChartHeading;

  /// No description provided for @dashboardChartWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for telemetry…'**
  String get dashboardChartWaiting;

  /// No description provided for @dashboardTrackCurrent.
  ///
  /// In en, this message translates to:
  /// **'Main current'**
  String get dashboardTrackCurrent;

  /// Direction key under the pack current track. The track itself stays SIGNED and zero-crossing (2026-08-03 ruling); this line is what tells the reader which half of the axis is which, now that 0x2E's direction is established (design 0056).
  ///
  /// In en, this message translates to:
  /// **'+ charge · − discharge'**
  String get dashboardTrackCurrentDirectionKey;

  /// No description provided for @dashboardTrackPvlt.
  ///
  /// In en, this message translates to:
  /// **'Primary voltage'**
  String get dashboardTrackPvlt;

  /// No description provided for @dashboardTrackTemperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get dashboardTrackTemperature;

  /// No description provided for @powerBankTrackCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get powerBankTrackCurrent;

  /// Direction key for a POWER BANK's current axis — 🔴 deliberately the MIRROR of dashboardTrackCurrentDirectionKey, not a copy of it. A power bank derives current from 0x4A − 0x49, where POSITIVE is discharging; a pack derives it from 0x2E = 512 − u16, where negative is discharging (power_flow.dart: “THE SIGN IS THE OPPOSITE”). Two keys rather than one reworded at the call site, for the same reason packDirection*/powerBankDirection* are two sets: a wording change made for a car battery must not silently reach a power bank.
  ///
  /// In en, this message translates to:
  /// **'+ discharge · − charge'**
  String get powerBankTrackCurrentDirectionKey;

  /// No description provided for @powerBankTrackOutput.
  ///
  /// In en, this message translates to:
  /// **'Output voltage'**
  String get powerBankTrackOutput;

  /// No description provided for @powerBankTrackInput.
  ///
  /// In en, this message translates to:
  /// **'Input voltage'**
  String get powerBankTrackInput;

  /// No description provided for @powerBankTrackSoc.
  ///
  /// In en, this message translates to:
  /// **'Charge level SOC'**
  String get powerBankTrackSoc;

  /// No description provided for @capacitorTrackSvlt.
  ///
  /// In en, this message translates to:
  /// **'Secondary voltage'**
  String get capacitorTrackSvlt;

  /// No description provided for @capacitorChartNoCurrentNote.
  ///
  /// In en, this message translates to:
  /// **'No current track: this unit reports a constant 0 A, which is not a measurement.'**
  String get capacitorChartNoCurrentNote;

  /// No description provided for @explainerSpeedTitle.
  ///
  /// In en, this message translates to:
  /// **'How speed is measured'**
  String get explainerSpeedTitle;

  /// No description provided for @explainerGForceTitle.
  ///
  /// In en, this message translates to:
  /// **'How G is measured'**
  String get explainerGForceTitle;

  /// No description provided for @explainerWhatIsMeasured.
  ///
  /// In en, this message translates to:
  /// **'What is measured'**
  String get explainerWhatIsMeasured;

  /// No description provided for @explainerWhatIsNotDone.
  ///
  /// In en, this message translates to:
  /// **'What this does not do'**
  String get explainerWhatIsNotDone;

  /// No description provided for @explainerSpeedWhat.
  ///
  /// In en, this message translates to:
  /// **'The speed the phone\'s GNSS chip reports (Doppler), not a figure derived from positions. Coordinates are never stored and never appear in an export.'**
  String get explainerSpeedWhat;

  /// No description provided for @explainerSpeedHoldingLead.
  ///
  /// In en, this message translates to:
  /// **'When the signal drops, the number shown is a HELD one, not a measured one.'**
  String get explainerSpeedHoldingLead;

  /// No description provided for @explainerSpeedHolding.
  ///
  /// In en, this message translates to:
  /// **'Tunnels, underpasses and overpasses all do it. The screen says so, and after a while it changes to “no signal”. A number marked as held is not your speed right now.'**
  String get explainerSpeedHolding;

  /// No description provided for @explainerSpeedStillLead.
  ///
  /// In en, this message translates to:
  /// **'Anything under 3 km/h reads 0.'**
  String get explainerSpeedStillLead;

  /// No description provided for @explainerSpeedStill.
  ///
  /// In en, this message translates to:
  /// **'A stationary GNSS receiver invents 1–3 km/h from position jitter, and 2 km/h at a red light is an error everyone spots. The cost is that wheeling the bike, or crawling, also reads 0.'**
  String get explainerSpeedStill;

  /// No description provided for @explainerSpeedNotDone.
  ///
  /// In en, this message translates to:
  /// **'No dead reckoning from the accelerometer (integration drifts), no background recording, no track.'**
  String get explainerSpeedNotDone;

  /// No description provided for @explainerGForceWhat.
  ///
  /// In en, this message translates to:
  /// **'The phone\'s accelerometer, with gravity removed by the OS. Calibration is how the app learns which way the phone is facing on the bike; without it there is no “forward” and no “left” to report.'**
  String get explainerGForceWhat;

  /// No description provided for @explainerGForceLeanLead.
  ///
  /// In en, this message translates to:
  /// **'Lateral G in a corner reads low. This is a physical limit of two-wheelers.'**
  String get explainerGForceLeanLead;

  /// No description provided for @explainerGForceLean.
  ///
  /// In en, this message translates to:
  /// **'A motorcycle leans through a corner, and the meter reads the component along the leaned body axis. The harder the corner, the larger the shortfall: about 4% at 0.3 g, 11% at 0.5 g, 22% at 0.8 g. Cars do not have this (they do not lean), so do not compare these numbers with a car\'s.'**
  String get explainerGForceLean;

  /// No description provided for @explainerGForceNotDone.
  ///
  /// In en, this message translates to:
  /// **'No lean angle from the gyroscope, no speed or distance derived. Only what is measured.'**
  String get explainerGForceNotDone;

  /// No description provided for @settingsSpeedExplainerLabel.
  ///
  /// In en, this message translates to:
  /// **'How speed is measured'**
  String get settingsSpeedExplainerLabel;

  /// No description provided for @settingsGForceExplainerLabel.
  ///
  /// In en, this message translates to:
  /// **'How G is measured'**
  String get settingsGForceExplainerLabel;

  /// No description provided for @homeEditLayout.
  ///
  /// In en, this message translates to:
  /// **'Edit layout'**
  String get homeEditLayout;

  /// No description provided for @unidentifiedTitle.
  ///
  /// In en, this message translates to:
  /// **'Device not recognised'**
  String get unidentifiedTitle;

  /// No description provided for @unidentifiedBody.
  ///
  /// In en, this message translates to:
  /// **'This unit reports a device type this build does not know, so nothing can be shown for it — a layout chosen by guesswork would be worse than none.\n\nExport the diagnostic log and send it to us; support for it can then be added in a later version.'**
  String get unidentifiedBody;

  /// No description provided for @devicesTabSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get devicesTabSaved;

  /// No description provided for @devicesTabScan.
  ///
  /// In en, this message translates to:
  /// **'Scan'**
  String get devicesTabScan;

  /// No description provided for @devicesUnsavedTitle.
  ///
  /// In en, this message translates to:
  /// **'This device is not saved'**
  String get devicesUnsavedTitle;

  /// No description provided for @devicesUnsavedBody.
  ///
  /// In en, this message translates to:
  /// **'Save it to put it on the home page and keep its history.'**
  String get devicesUnsavedBody;

  /// FB-82 Q4. Shown UNDER the connection failure report on a saved unit's page, never instead of it. It reports that THIS VISIT made no automatic attempt — not why a connection failed, which the card above already answers.
  ///
  /// In en, this message translates to:
  /// **'No automatic connection this time'**
  String get devicesAutoConnectSkippedTitle;

  /// FB-82 Q4, the `last error not cleared` gate. The error code is deliberately not repeated here — it is already in the card above, turned into an instruction.
  ///
  /// In en, this message translates to:
  /// **'The previous connection problem has not been cleared, so opening this page made no attempt of its own. Use the button below to connect now.'**
  String get devicesAutoConnectSkippedLastError;

  /// FB-82 Q4, the `setup stalled` gate (FB-50: linked but never ready).
  ///
  /// In en, this message translates to:
  /// **'The previous connection is still stuck part-way through setup, so opening this page made no attempt of its own. Use the button below to connect now.'**
  String get devicesAutoConnectSkippedStalled;

  /// No description provided for @devicesSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get devicesSave;

  /// No description provided for @devicesNoAdvertisedName.
  ///
  /// In en, this message translates to:
  /// **'No advertised name'**
  String get devicesNoAdvertisedName;

  /// No description provided for @devicesLinkedNoAdvert.
  ///
  /// In en, this message translates to:
  /// **'Linked · not advertising, so no scan finds it'**
  String get devicesLinkedNoAdvert;

  /// No description provided for @fullscreenEnter.
  ///
  /// In en, this message translates to:
  /// **'Full screen'**
  String get fullscreenEnter;

  /// No description provided for @fullscreenExit.
  ///
  /// In en, this message translates to:
  /// **'Exit full screen'**
  String get fullscreenExit;

  /// Saved-device row action, beside Rename. Kept to ONE word: the row carries three labelled buttons on a 320 pt phone (design 0066 §3.7).
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get declaredRowAction;

  /// No description provided for @declaredTitle.
  ///
  /// In en, this message translates to:
  /// **'Set model'**
  String get declaredTitle;

  /// No description provided for @declaredBody.
  ///
  /// In en, this message translates to:
  /// **'Tell us what this unit is. Anything you are not sure of can be left blank.'**
  String get declaredBody;

  /// No description provided for @declaredNotDisplayed.
  ///
  /// In en, this message translates to:
  /// **'This is collected for us to read; it changes nothing on your screens.'**
  String get declaredNotDisplayed;

  /// No description provided for @declaredSectionCategory.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get declaredSectionCategory;

  /// No description provided for @declaredSectionModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get declaredSectionModel;

  /// No description provided for @declaredSectionRegion.
  ///
  /// In en, this message translates to:
  /// **'Case standard'**
  String get declaredSectionRegion;

  /// No description provided for @declaredSectionLabel.
  ///
  /// In en, this message translates to:
  /// **'Label colour'**
  String get declaredSectionLabel;

  /// No description provided for @declaredSectionCapacity.
  ///
  /// In en, this message translates to:
  /// **'Nominal capacity'**
  String get declaredSectionCapacity;

  /// No description provided for @declaredSectionNote.
  ///
  /// In en, this message translates to:
  /// **'Note'**
  String get declaredSectionNote;

  /// No description provided for @declaredOptional.
  ///
  /// In en, this message translates to:
  /// **'optional'**
  String get declaredOptional;

  /// No description provided for @declaredClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get declaredClear;

  /// No description provided for @declaredCategoryMotorcycleCapacitor.
  ///
  /// In en, this message translates to:
  /// **'Motorcycle capacitor'**
  String get declaredCategoryMotorcycleCapacitor;

  /// No description provided for @declaredCategoryCarCapacitor.
  ///
  /// In en, this message translates to:
  /// **'Car capacitor'**
  String get declaredCategoryCarCapacitor;

  /// No description provided for @declaredCategoryMotorcycleBattery.
  ///
  /// In en, this message translates to:
  /// **'Motorcycle battery'**
  String get declaredCategoryMotorcycleBattery;

  /// No description provided for @declaredCategoryCarBattery.
  ///
  /// In en, this message translates to:
  /// **'Car battery'**
  String get declaredCategoryCarBattery;

  /// No description provided for @declaredCategoryPowerBank.
  ///
  /// In en, this message translates to:
  /// **'Power bank'**
  String get declaredCategoryPowerBank;

  /// No description provided for @declaredGenerationGen1.
  ///
  /// In en, this message translates to:
  /// **'Gen 1'**
  String get declaredGenerationGen1;

  /// No description provided for @declaredGenerationGen2.
  ///
  /// In en, this message translates to:
  /// **'Gen 2'**
  String get declaredGenerationGen2;

  /// No description provided for @declaredGenerationFlagship.
  ///
  /// In en, this message translates to:
  /// **'Flagship'**
  String get declaredGenerationFlagship;

  /// No description provided for @declaredGroupOldGen.
  ///
  /// In en, this message translates to:
  /// **'Old catalogue'**
  String get declaredGroupOldGen;

  /// No description provided for @declaredGroupNewGenB.
  ///
  /// In en, this message translates to:
  /// **'New catalogue · B (65 mm case)'**
  String get declaredGroupNewGenB;

  /// No description provided for @declaredGroupNewGenA.
  ///
  /// In en, this message translates to:
  /// **'New catalogue · A (87 mm case)'**
  String get declaredGroupNewGenA;

  /// No description provided for @declaredSectionRetrofit.
  ///
  /// In en, this message translates to:
  /// **'Retrofit'**
  String get declaredSectionRetrofit;

  /// No description provided for @declaredModelRetrofitLid.
  ///
  /// In en, this message translates to:
  /// **'Retrofit smart lid'**
  String get declaredModelRetrofitLid;

  /// No description provided for @declaredRetrofitNotePrompt.
  ///
  /// In en, this message translates to:
  /// **'You can tell us which battery is under the lid in the note below.'**
  String get declaredRetrofitNotePrompt;

  /// No description provided for @declaredNoteHint.
  ///
  /// In en, this message translates to:
  /// **'Anything else worth telling us'**
  String get declaredNoteHint;

  /// No description provided for @declaredRegionJp.
  ///
  /// In en, this message translates to:
  /// **'JIS (Japan)'**
  String get declaredRegionJp;

  /// No description provided for @declaredRegionEu.
  ///
  /// In en, this message translates to:
  /// **'DIN (Europe)'**
  String get declaredRegionEu;

  /// No description provided for @declaredLabelOrange.
  ///
  /// In en, this message translates to:
  /// **'Orange label'**
  String get declaredLabelOrange;

  /// No description provided for @declaredLabelPurple.
  ///
  /// In en, this message translates to:
  /// **'Purple label'**
  String get declaredLabelPurple;

  /// No description provided for @declaredCapacityHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. 48, or 40B19L from the label'**
  String get declaredCapacityHint;

  /// No description provided for @declaredCapacityFreeText.
  ///
  /// In en, this message translates to:
  /// **'The four buttons are suggestions, not a list. Type whatever the label actually says.'**
  String get declaredCapacityFreeText;

  /// No description provided for @declaredMismatchCapacitor.
  ///
  /// In en, this message translates to:
  /// **'This unit did not report itself as a capacitor. You can still save — if it is hardware we have not seen, that is exactly what we want to know.'**
  String get declaredMismatchCapacitor;

  /// No description provided for @declaredMismatchBattery.
  ///
  /// In en, this message translates to:
  /// **'This unit did not report itself as a battery. You can still save — if it is hardware we have not seen, that is exactly what we want to know.'**
  String get declaredMismatchBattery;

  /// No description provided for @declaredMismatchPowerBank.
  ///
  /// In en, this message translates to:
  /// **'This unit did not report itself as a power bank. You can still save — if it is hardware we have not seen, that is exactly what we want to know.'**
  String get declaredMismatchPowerBank;

  /// No description provided for @declaredMismatchFlagship.
  ///
  /// In en, this message translates to:
  /// **'This unit did not report itself as a flagship. You can still save — if it is hardware we have not seen, that is exactly what we want to know.'**
  String get declaredMismatchFlagship;

  /// design 0066 §3.9 — PLAIN TEXT by owner ruling. It must not become a tappable link.
  ///
  /// In en, this message translates to:
  /// **'If you are not sure how to fill this in, ask in the LINE community.'**
  String get declaredHelpLine;

  /// Catalogue part number, NOT a sentence. Identical in every locale — do not translate (design 0066).
  ///
  /// In en, this message translates to:
  /// **'6.0A'**
  String get declaredModel60A;

  /// Catalogue part number, NOT a sentence. Identical in every locale — do not translate (design 0066).
  ///
  /// In en, this message translates to:
  /// **'6.0B'**
  String get declaredModel60B;

  /// Catalogue part number, NOT a sentence. Identical in every locale — do not translate (design 0066).
  ///
  /// In en, this message translates to:
  /// **'9.0A'**
  String get declaredModel90A;

  /// Catalogue part number, NOT a sentence. Identical in every locale — do not translate (design 0066).
  ///
  /// In en, this message translates to:
  /// **'5.0Ah-B'**
  String get declaredModel50AhB;

  /// Catalogue part number, NOT a sentence. Identical in every locale — do not translate (design 0066).
  ///
  /// In en, this message translates to:
  /// **'7.5Ah-B'**
  String get declaredModel75AhB;

  /// Catalogue part number, NOT a sentence. Identical in every locale — do not translate (design 0066).
  ///
  /// In en, this message translates to:
  /// **'10.0Ah-B'**
  String get declaredModel100AhB;

  /// Catalogue part number, NOT a sentence. Identical in every locale — do not translate (design 0066).
  ///
  /// In en, this message translates to:
  /// **'5.0Ah-A'**
  String get declaredModel50AhA;

  /// Catalogue part number, NOT a sentence. Identical in every locale — do not translate (design 0066).
  ///
  /// In en, this message translates to:
  /// **'7.5Ah-A'**
  String get declaredModel75AhA;

  /// Catalogue part number, NOT a sentence. Identical in every locale — do not translate (design 0066).
  ///
  /// In en, this message translates to:
  /// **'10.0Ah-A'**
  String get declaredModel100AhA;

  /// Catalogue part number, NOT a sentence. Identical in every locale — do not translate (design 0066).
  ///
  /// In en, this message translates to:
  /// **'12.5Ah-A'**
  String get declaredModel125AhA;

  /// Catalogue part number, NOT a sentence. Identical in every locale — do not translate (design 0066).
  ///
  /// In en, this message translates to:
  /// **'17.5Ah-A'**
  String get declaredModel175AhA;

  /// design 0080 §3.7.1 — the device detail page's row into this unit's alert settings.
  ///
  /// In en, this message translates to:
  /// **'Warning notifications'**
  String get alertsEntryTitle;

  /// No description provided for @alertsEntrySummaryFull.
  ///
  /// In en, this message translates to:
  /// **'Limits {uv} – {ov} V · {ot} °C'**
  String alertsEntrySummaryFull(String uv, String ov, String ot);

  /// No description provided for @alertsEntrySummaryTempOnly.
  ///
  /// In en, this message translates to:
  /// **'Over-temperature limit {ot} °C'**
  String alertsEntrySummaryTempOnly(String ot);

  /// design 0080 §7.5.2 — 0x2B is persisted nowhere, so an offline unit genuinely cannot say. Never dress this up as 'no limits'.
  ///
  /// In en, this message translates to:
  /// **'Known once connected'**
  String get alertsEntrySummaryUnknown;

  /// No description provided for @alertsEntrySummaryUnrecognised.
  ///
  /// In en, this message translates to:
  /// **'This device type is not recognised yet'**
  String get alertsEntrySummaryUnrecognised;

  /// No description provided for @alertsEntrySummaryUnsaved.
  ///
  /// In en, this message translates to:
  /// **'Save this device first to set warnings'**
  String get alertsEntrySummaryUnsaved;

  /// No description provided for @alertsEntryBadgeOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get alertsEntryBadgeOn;

  /// No description provided for @alertsEntryBadgeOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get alertsEntryBadgeOff;

  /// No description provided for @alertsEntryBadgeMuted.
  ///
  /// In en, this message translates to:
  /// **'Muted'**
  String get alertsEntryBadgeMuted;

  /// No description provided for @alertsPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Warning notifications'**
  String get alertsPageTitle;

  /// No description provided for @alertsDeviceSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Notify me about this device'**
  String get alertsDeviceSwitchTitle;

  /// design 0080 §6.1 RED LINE — 'while connected' is not optional wording. Never 'tell me when the battery has a fault'.
  ///
  /// In en, this message translates to:
  /// **'While connected, tell me when a reading passes a limit'**
  String get alertsDeviceSwitchSub;

  /// No description provided for @alertsDeviceSwitchSubTempOnly.
  ///
  /// In en, this message translates to:
  /// **'While connected, tell me when it runs hot'**
  String get alertsDeviceSwitchSubTempOnly;

  /// No description provided for @alertsDeviceSwitchSubUnrecognised.
  ///
  /// In en, this message translates to:
  /// **'This device type is not recognised yet'**
  String get alertsDeviceSwitchSubUnrecognised;

  /// No description provided for @alertsThresholdsHeading.
  ///
  /// In en, this message translates to:
  /// **'Limits'**
  String get alertsThresholdsHeading;

  /// No description provided for @alertsLiveReadingHeading.
  ///
  /// In en, this message translates to:
  /// **'Now'**
  String get alertsLiveReadingHeading;

  /// No description provided for @alertsRowOverVoltage.
  ///
  /// In en, this message translates to:
  /// **'Over-voltage'**
  String get alertsRowOverVoltage;

  /// No description provided for @alertsRowUnderVoltage.
  ///
  /// In en, this message translates to:
  /// **'Under-voltage'**
  String get alertsRowUnderVoltage;

  /// No description provided for @alertsRowOverTemperature.
  ///
  /// In en, this message translates to:
  /// **'Over-temperature'**
  String get alertsRowOverTemperature;

  /// No description provided for @alertsRowAboveWarns.
  ///
  /// In en, this message translates to:
  /// **'Warn above'**
  String get alertsRowAboveWarns;

  /// No description provided for @alertsRowBelowWarns.
  ///
  /// In en, this message translates to:
  /// **'Warn below'**
  String get alertsRowBelowWarns;

  /// Layer ② badge — the unit's own 0x2B.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get alertsSourceDevice;

  /// design 0080 §3.2.2 — the power bank's 50 °C is the one number nobody measured, and the screen is REQUIRED to say so.
  ///
  /// In en, this message translates to:
  /// **'App default'**
  String get alertsSourceApp;

  /// No description provided for @alertsSourceNone.
  ///
  /// In en, this message translates to:
  /// **'No basis'**
  String get alertsSourceNone;

  /// No description provided for @alertsSourceOffline.
  ///
  /// In en, this message translates to:
  /// **'Known once connected'**
  String get alertsSourceOffline;

  /// No description provided for @alertsValueUnset.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get alertsValueUnset;

  /// No description provided for @alertsVoltsValue.
  ///
  /// In en, this message translates to:
  /// **'{v} V'**
  String alertsVoltsValue(String v);

  /// No description provided for @alertsCelsiusValue.
  ///
  /// In en, this message translates to:
  /// **'{v} °C'**
  String alertsCelsiusValue(String v);

  /// No description provided for @alertsOfflineNote.
  ///
  /// In en, this message translates to:
  /// **'Not connected — this device\'s own factory limits are only readable while connected.'**
  String get alertsOfflineNote;

  /// No description provided for @alertsReadOnlyNote.
  ///
  /// In en, this message translates to:
  /// **'These limits are the device’s own factory settings. The app only reads them to warn you — it never changes the device.'**
  String get alertsReadOnlyNote;

  /// design 0080 §7.5.6 C-3 / §7.5.7 — the TRANSIENT state. It must never borrow the words of alertsUnrecognisedTitle: every connect passes through here.
  ///
  /// In en, this message translates to:
  /// **'Still identifying this device'**
  String get alertsPendingTitle;

  /// No description provided for @alertsPendingBody.
  ///
  /// In en, this message translates to:
  /// **'Which warnings this device can offer is known once it has said what it is. Nothing is switched off — there is simply nothing to show yet.'**
  String get alertsPendingBody;

  /// No description provided for @alertsPowerBankNoteTitle.
  ///
  /// In en, this message translates to:
  /// **'Why is there no voltage warning?'**
  String get alertsPowerBankNoteTitle;

  /// No description provided for @alertsPowerBankNoteBody.
  ///
  /// In en, this message translates to:
  /// **'A power bank reports CELL voltage (around 3.7 V), which is not the same quantity as a battery\'s or a capacitor\'s pack voltage — and it reports no factory warning limits at all, so we have nothing to judge it against.'**
  String get alertsPowerBankNoteBody;

  /// No description provided for @alertsPowerBankOtNote.
  ///
  /// In en, this message translates to:
  /// **'This device reports no warning limits, so 50 °C is the app’s own default.'**
  String get alertsPowerBankOtNote;

  /// No description provided for @alertsPowerBankOtEvidence.
  ///
  /// In en, this message translates to:
  /// **'Highest observed across 49 captures: 40 °C'**
  String get alertsPowerBankOtEvidence;

  /// No description provided for @alertsUnrecognisedTitle.
  ///
  /// In en, this message translates to:
  /// **'This device type is not recognised, so no warnings are offered.'**
  String get alertsUnrecognisedTitle;

  /// No description provided for @alertsUnrecognisedBody.
  ///
  /// In en, this message translates to:
  /// **'This device reports a type code we do not know yet. Until we can identify it, the app cannot tell which readings are normal — so it offers no warnings rather than a set of limits that may be wrong.'**
  String get alertsUnrecognisedBody;

  /// No description provided for @alertsUnrecognisedDeviceType.
  ///
  /// In en, this message translates to:
  /// **'device-type = {hex} (not catalogued)'**
  String alertsUnrecognisedDeviceType(String hex);

  /// No description provided for @alertsStillAvailableHeading.
  ///
  /// In en, this message translates to:
  /// **'Still available'**
  String get alertsStillAvailableHeading;

  /// No description provided for @alertsStillAvailableBody.
  ///
  /// In en, this message translates to:
  /// **'Live monitoring, history and export are unaffected — only warnings are switched off.'**
  String get alertsStillAvailableBody;

  /// No description provided for @alertsMuteHeading.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get alertsMuteHeading;

  /// No description provided for @alertsMuteHourTitle.
  ///
  /// In en, this message translates to:
  /// **'Mute for 1 hour'**
  String get alertsMuteHourTitle;

  /// No description provided for @alertsMuteHourSub.
  ///
  /// In en, this message translates to:
  /// **'Still counts after the app is closed'**
  String get alertsMuteHourSub;

  /// No description provided for @alertsMutedTitle.
  ///
  /// In en, this message translates to:
  /// **'Muted'**
  String get alertsMutedTitle;

  /// No description provided for @alertsMutedSub.
  ///
  /// In en, this message translates to:
  /// **'Until {time} · {minutes} min left'**
  String alertsMutedSub(String time, String minutes);

  /// No description provided for @alertsMuteInactive.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get alertsMuteInactive;

  /// No description provided for @alertsMuteClear.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get alertsMuteClear;

  /// No description provided for @alertsSessionMuteTitle.
  ///
  /// In en, this message translates to:
  /// **'Not again this connection'**
  String get alertsSessionMuteTitle;

  /// design 0080 §3.4 gate ③ — memory only, deliberately NOT persisted.
  ///
  /// In en, this message translates to:
  /// **'Ends when the link drops'**
  String get alertsSessionMuteSub;

  /// No description provided for @alertsUnsavedTitle.
  ///
  /// In en, this message translates to:
  /// **'This device is not saved'**
  String get alertsUnsavedTitle;

  /// No description provided for @alertsUnsavedBody.
  ///
  /// In en, this message translates to:
  /// **'Warning settings are stored per device, so this one needs a name first.'**
  String get alertsUnsavedBody;

  /// No description provided for @settingsAlertsHeading.
  ///
  /// In en, this message translates to:
  /// **'Warnings'**
  String get settingsAlertsHeading;

  /// No description provided for @settingsAlertsEnableLabel.
  ///
  /// In en, this message translates to:
  /// **'Enable warning notifications'**
  String get settingsAlertsEnableLabel;

  /// No description provided for @settingsAlertsEnableSub.
  ///
  /// In en, this message translates to:
  /// **'While connected, notify me when a reading passes a limit'**
  String get settingsAlertsEnableSub;

  /// No description provided for @settingsAlertsPermissionLabel.
  ///
  /// In en, this message translates to:
  /// **'System notification permission'**
  String get settingsAlertsPermissionLabel;

  /// design 0080 — the NOT-YET-ASKED wording, kept from P2 now that P3 runs the flow. It is still the only honest thing to show before the first-enable dialog: on iOS an un-asked permission and a refused one report the same value, so a status read early would show every new user a red 'refused'.
  ///
  /// In en, this message translates to:
  /// **'Requested when you turn notifications on'**
  String get settingsAlertsPermissionPending;

  /// No description provided for @settingsAlertsSustainLabel.
  ///
  /// In en, this message translates to:
  /// **'How long before it counts'**
  String get settingsAlertsSustainLabel;

  /// No description provided for @settingsAlertsSustainSub.
  ///
  /// In en, this message translates to:
  /// **'So a momentary bad contact does not notify you'**
  String get settingsAlertsSustainSub;

  /// No description provided for @settingsAlertsRepeatLabel.
  ///
  /// In en, this message translates to:
  /// **'Repeat reminder every'**
  String get settingsAlertsRepeatLabel;

  /// No description provided for @settingsAlertsRepeatSub.
  ///
  /// In en, this message translates to:
  /// **'While one event is still going'**
  String get settingsAlertsRepeatSub;

  /// No description provided for @settingsAlertsMaxLabel.
  ///
  /// In en, this message translates to:
  /// **'Reminders per event'**
  String get settingsAlertsMaxLabel;

  /// No description provided for @settingsAlertsMaxSub.
  ///
  /// In en, this message translates to:
  /// **'After the limit it goes quiet until the reading recovers'**
  String get settingsAlertsMaxSub;

  /// No description provided for @settingsAlertsSecondsValue.
  ///
  /// In en, this message translates to:
  /// **'{n} s'**
  String settingsAlertsSecondsValue(String n);

  /// No description provided for @settingsAlertsMinutesValue.
  ///
  /// In en, this message translates to:
  /// **'{n} min'**
  String settingsAlertsMinutesValue(String n);

  /// No description provided for @settingsAlertsCountValue.
  ///
  /// In en, this message translates to:
  /// **'{n}'**
  String settingsAlertsCountValue(String n);

  /// design 0080 §6.1 RED LINE. Never '24-hour monitoring', never 'offline guardian', never any iOS background promise.
  ///
  /// In en, this message translates to:
  /// **'What this feature can do'**
  String get settingsAlertsLimitsTitle;

  /// No description provided for @settingsAlertsLimitsBody.
  ///
  /// In en, this message translates to:
  /// **'Detection only happens while the app is CONNECTED to the device. Nothing is checked after the link drops.'**
  String get settingsAlertsLimitsBody;

  /// No description provided for @settingsAlertsLimitsAndroid.
  ///
  /// In en, this message translates to:
  /// **'Android: detection continues while connected, even with the screen off.'**
  String get settingsAlertsLimitsAndroid;

  /// No description provided for @settingsAlertsLimitsIos.
  ///
  /// In en, this message translates to:
  /// **'iPhone: in the background, detection only happens during the short windows where the device\'s data wakes the app; it stops once the system reclaims the app.'**
  String get settingsAlertsLimitsIos;

  /// No description provided for @settingsAlertsStepDown.
  ///
  /// In en, this message translates to:
  /// **'Decrease'**
  String get settingsAlertsStepDown;

  /// No description provided for @settingsAlertsStepUp.
  ///
  /// In en, this message translates to:
  /// **'Increase'**
  String get settingsAlertsStepUp;

  /// No description provided for @settingsAlertsPermissionGranted.
  ///
  /// In en, this message translates to:
  /// **'Allowed'**
  String get settingsAlertsPermissionGranted;

  /// design 0080 §6.2 RED. Precedent design 0008 §3.4: a refused permission left the service running and only hid its notification, so what the user experienced was 'I turned it on and nothing arrives'. This row must never fail silently.
  ///
  /// In en, this message translates to:
  /// **'Refused — nothing will reach your phone'**
  String get settingsAlertsPermissionDenied;

  /// No description provided for @settingsAlertsPermissionUnknown.
  ///
  /// In en, this message translates to:
  /// **'Not confirmed yet'**
  String get settingsAlertsPermissionUnknown;

  /// No description provided for @settingsAlertsPermissionOpen.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get settingsAlertsPermissionOpen;

  /// No description provided for @settingsAlertsPermissionDeniedHelp.
  ///
  /// In en, this message translates to:
  /// **'Warnings are still evaluated and still appear on the device screen — only the phone staying quiet is the difference.'**
  String get settingsAlertsPermissionDeniedHelp;

  /// No description provided for @alertsConsentTitle.
  ///
  /// In en, this message translates to:
  /// **'Turn on warning notifications'**
  String get alertsConsentTitle;

  /// No description provided for @alertsConsentIntro.
  ///
  /// In en, this message translates to:
  /// **'Before you turn this on, what it does and does not do:'**
  String get alertsConsentIntro;

  /// No description provided for @alertsConsentPointConnected.
  ///
  /// In en, this message translates to:
  /// **'Detection only happens while the app is CONNECTED to a device. Nothing is checked after the link drops.'**
  String get alertsConsentPointConnected;

  /// No description provided for @alertsConsentPointAndroid.
  ///
  /// In en, this message translates to:
  /// **'Android: detection continues while connected, even with the screen off.'**
  String get alertsConsentPointAndroid;

  /// No description provided for @alertsConsentPointIos.
  ///
  /// In en, this message translates to:
  /// **'iPhone: in the background, detection only happens during the short windows where the device\'s data wakes the app; it stops once the system reclaims the app.'**
  String get alertsConsentPointIos;

  /// No description provided for @alertsConsentPointPermission.
  ///
  /// In en, this message translates to:
  /// **'Next you will be asked to allow system notifications. You can refuse — warnings still appear on screen, your phone just stays quiet.'**
  String get alertsConsentPointPermission;

  /// No description provided for @alertsConsentPointThresholds.
  ///
  /// In en, this message translates to:
  /// **'Limits are set per device, under 「Warnings」 on each device\'s page.'**
  String get alertsConsentPointThresholds;

  /// No description provided for @alertsConsentEnable.
  ///
  /// In en, this message translates to:
  /// **'Turn on'**
  String get alertsConsentEnable;

  /// design 0080 §3.5.3: a SECOND Android channel, separate from the foreground service's ongoing one, so the user can silence one without the other.
  ///
  /// In en, this message translates to:
  /// **'Warnings'**
  String get alertsChannelName;

  /// No description provided for @alertsChannelDescription.
  ///
  /// In en, this message translates to:
  /// **'A reading passed a limit you set'**
  String get alertsChannelDescription;

  /// No description provided for @alertsNotificationOverVoltage.
  ///
  /// In en, this message translates to:
  /// **'voltage too high'**
  String get alertsNotificationOverVoltage;

  /// No description provided for @alertsNotificationUnderVoltage.
  ///
  /// In en, this message translates to:
  /// **'voltage too low'**
  String get alertsNotificationUnderVoltage;

  /// No description provided for @alertsNotificationOverTemperature.
  ///
  /// In en, this message translates to:
  /// **'temperature too high'**
  String get alertsNotificationOverTemperature;

  /// No description provided for @alertsNotificationTitle.
  ///
  /// In en, this message translates to:
  /// **'{alias} · {kind}'**
  String alertsNotificationTitle(String alias, String kind);

  /// design 0080 §3.5.3 — the body carries the reading AND the limit so the severity is readable without opening the app.
  ///
  /// In en, this message translates to:
  /// **'Now {reading} V, limit {threshold} V · {time}'**
  String alertsNotificationBodyVolts(
    String reading,
    String threshold,
    String time,
  );

  /// No description provided for @alertsNotificationBodyCelsius.
  ///
  /// In en, this message translates to:
  /// **'Now {reading} °C, limit {threshold} °C · {time}'**
  String alertsNotificationBodyCelsius(
    String reading,
    String threshold,
    String time,
  );

  /// No description provided for @alertsBannerHeading.
  ///
  /// In en, this message translates to:
  /// **'Warning raised'**
  String get alertsBannerHeading;

  /// No description provided for @alertsBannerRowVolts.
  ///
  /// In en, this message translates to:
  /// **'{kind} · now {reading} V, limit {threshold} V'**
  String alertsBannerRowVolts(String kind, String reading, String threshold);

  /// No description provided for @alertsBannerRowCelsius.
  ///
  /// In en, this message translates to:
  /// **'{kind} · now {reading} °C, limit {threshold} °C'**
  String alertsBannerRowCelsius(String kind, String reading, String threshold);

  /// No description provided for @alertsBannerFor.
  ///
  /// In en, this message translates to:
  /// **'for {duration}'**
  String alertsBannerFor(String duration);

  /// No description provided for @alertsBannerDurationSeconds.
  ///
  /// In en, this message translates to:
  /// **'{n} s'**
  String alertsBannerDurationSeconds(String n);

  /// No description provided for @alertsBannerDurationMinutes.
  ///
  /// In en, this message translates to:
  /// **'{n} min'**
  String alertsBannerDurationMinutes(String n);

  /// No description provided for @alertsBannerDurationHours.
  ///
  /// In en, this message translates to:
  /// **'{h} h {m} min'**
  String alertsBannerDurationHours(String h, String m);

  /// design 0080 ruling Q3 / §0.2.1: an unsaved unit is evaluated and DRAWN; only the notification is withheld.
  ///
  /// In en, this message translates to:
  /// **'This device is not saved, so this stays on screen and your phone will not ring.'**
  String get alertsBannerUnsavedNote;

  /// No description provided for @alertsBannerSilencedNote.
  ///
  /// In en, this message translates to:
  /// **'Notifications for this device are paused. The warning itself is still being tracked.'**
  String get alertsBannerSilencedNote;

  /// No description provided for @alertsBannerGloballyOffNote.
  ///
  /// In en, this message translates to:
  /// **'Warning notifications are off in Settings. The warning itself is still being tracked.'**
  String get alertsBannerGloballyOffNote;

  /// No description provided for @alertsBannerOpen.
  ///
  /// In en, this message translates to:
  /// **'Warnings'**
  String get alertsBannerOpen;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
