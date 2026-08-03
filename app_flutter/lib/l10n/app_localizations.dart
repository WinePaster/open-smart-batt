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

  /// No description provided for @navDashboard.
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
  /// **'Temperature TEMP'**
  String get dashboardReadoutTemperatureLabel;

  /// No description provided for @dashboardReadoutSvltLabel.
  ///
  /// In en, this message translates to:
  /// **'Secondary Voltage SVLT'**
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
  /// **'Per-Cell Voltage DVOL'**
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
  /// **'PVLT · Primary Voltage'**
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

  /// No description provided for @statusAdvisoryNoteCapacitor.
  ///
  /// In en, this message translates to:
  /// **'This unit is a super-capacitor (from the device type it reports); only the features it supports are shown. Its own over-voltage / under-voltage / over-temperature protection stays active.'**
  String get statusAdvisoryNoteCapacitor;

  /// No description provided for @statusAdvisoryNoteBattery.
  ///
  /// In en, this message translates to:
  /// **'This unit is a smart battery (from the device type it reports). Anti-theft appears only on models that support it; after releasing the cut-off, avoid re-locking.'**
  String get statusAdvisoryNoteBattery;

  /// No description provided for @statusAdvisoryNoteUnclassified.
  ///
  /// In en, this message translates to:
  /// **'The device type is not recognised yet, so a wider feature set is shown for now (anti-theft excluded). You can set the type above.'**
  String get statusAdvisoryNoteUnclassified;

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

  /// No description provided for @historyRangeWeek.
  ///
  /// In en, this message translates to:
  /// **'7 days'**
  String get historyRangeWeek;

  /// No description provided for @historyRangeAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get historyRangeAll;

  /// No description provided for @historyLegendVoltage.
  ///
  /// In en, this message translates to:
  /// **'Voltage'**
  String get historyLegendVoltage;

  /// No description provided for @historyLegendTemperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get historyLegendTemperature;

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

  /// No description provided for @historyEmptyWarning.
  ///
  /// In en, this message translates to:
  /// **'No warning or event records.'**
  String get historyEmptyWarning;

  /// No description provided for @historyEmptyAll.
  ///
  /// In en, this message translates to:
  /// **'No history yet.\nIt starts accumulating once a device is connected.'**
  String get historyEmptyAll;

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
  /// **'Not enough data to chart (need at least 2 records)'**
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
  /// **'iOS does not support background monitoring: readings stop when the app leaves the foreground or the screen turns off, and the link is eventually dropped by the system. Keep the app in the foreground and turn on \"Keep screen awake while connected\" below.'**
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
  /// **'The device is sending readings but has not said what it is. Reconnecting usually fixes this; you can also set the type by hand.'**
  String get classPendingTimeoutBody;

  /// No description provided for @classPendingRevealButton.
  ///
  /// In en, this message translates to:
  /// **'Show readings anyway'**
  String get classPendingRevealButton;

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
  /// **'Cell -- V'**
  String get powerBankSocSubUnknown;

  /// No description provided for @powerBankCellSub.
  ///
  /// In en, this message translates to:
  /// **'Cell {volts} V'**
  String powerBankCellSub(String volts);

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

  /// No description provided for @powerBankCellVoltageLabel.
  ///
  /// In en, this message translates to:
  /// **'Cell Voltage'**
  String get powerBankCellVoltageLabel;

  /// No description provided for @powerBankOutputVoltageLabel.
  ///
  /// In en, this message translates to:
  /// **'Output Voltage'**
  String get powerBankOutputVoltageLabel;

  /// No description provided for @usbPortsHeading.
  ///
  /// In en, this message translates to:
  /// **'USB Ports'**
  String get usbPortsHeading;

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

  /// No description provided for @usbPortStateUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get usbPortStateUnknown;

  /// No description provided for @usbPortStateSupplying.
  ///
  /// In en, this message translates to:
  /// **'Supplying'**
  String get usbPortStateSupplying;

  /// No description provided for @usbPortStateIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get usbPortStateIdle;

  /// No description provided for @usbPortPendingNote.
  ///
  /// In en, this message translates to:
  /// **'Live port status (supply / fast-charge protocol) will appear once a hardware capture pins down the port-status frame layout.'**
  String get usbPortPendingNote;

  /// No description provided for @dashboardModeNumbers.
  ///
  /// In en, this message translates to:
  /// **'Numbers'**
  String get dashboardModeNumbers;

  /// No description provided for @dashboardModeChart.
  ///
  /// In en, this message translates to:
  /// **'Chart'**
  String get dashboardModeChart;

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

  /// No description provided for @dashboardTrackPvlt.
  ///
  /// In en, this message translates to:
  /// **'PVLT · main voltage'**
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

  /// No description provided for @powerBankTrackOutput.
  ///
  /// In en, this message translates to:
  /// **'Output voltage'**
  String get powerBankTrackOutput;

  /// No description provided for @powerBankTrackSoc.
  ///
  /// In en, this message translates to:
  /// **'Charge level SOC'**
  String get powerBankTrackSoc;

  /// No description provided for @capacitorTrackSvlt.
  ///
  /// In en, this message translates to:
  /// **'Secondary voltage SVLT'**
  String get capacitorTrackSvlt;

  /// No description provided for @capacitorChartNoCurrentNote.
  ///
  /// In en, this message translates to:
  /// **'No current track: this unit reports a constant 0 A, which is not a measurement.'**
  String get capacitorChartNoCurrentNote;
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
