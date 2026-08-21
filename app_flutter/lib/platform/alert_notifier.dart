/// OpenSmartBatt — the local-notification handle for design 0080 (P3, §3.5).
///
/// Shaped after [MonitorService] next door, and for the same three reasons that
/// class states in its own header:
///
///   1. **The Dart side stays a substitutable interface.** [NoopAlertNotifier]
///      is what desktop and every test get, which is what lets the whole of
///      §5.1's plan — the state machine, the gate, the de-duplication — run in
///      milliseconds with no phone, no channel and no plugin registrant.
///   2. **The strings come from the CALLER.** Nothing in here is translated and
///      nothing in here reads `AppLocalizations`: a notification is posted from
///      the telemetry path, where there is no `BuildContext` to read one from,
///      and the app's in-app language override is independent of the device
///      locale — so a platform-resourced string would be the wrong language for
///      precisely the user who changed it. [MonitorNotification] made the same
///      choice for the same reason.
///   3. **A failed channel call must never reach the BLE path.** Everything
///      below swallows [PlatformException] / [MissingPluginException] and
///      returns, exactly as `AndroidMonitorService._invoke` does. Losing a
///      notification degrades the feature; letting the exception out would take
///      down the frame handler that produced it.
///
/// ## What this file deliberately does NOT have
///
/// **No notification actions.** Ruling Q2 (§3.4.1) removed them outright, so
/// there is no `AndroidNotificationAction`, no iOS `DarwinNotificationCategory`
/// registration and no action router. The tap is the only interaction and it
/// carries one payload: the device id. The ruling's stated cost — a user on the
/// lock screen needs four steps to mute — is paid down by where the tap LANDS
/// (that unit's alert settings page, not the dashboard), which is the caller's
/// business, not this file's.
///
/// **No scheduling.** `zonedSchedule` is unused: everything design 0080 emits
/// is decided by [AlertEvaluator] at the moment a frame arrives, and a
/// notification scheduled for later would be a claim about a link we may no
/// longer have. §3.3.2's honesty rule, applied to the plugin's API surface.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// The Android channel design 0080 §3.5.3 requires, kept apart from the
/// foreground service's ongoing one.
///
/// 🔴 **A SECOND channel, not a second use of the first one.** The monitor's
/// channel is created by `MonitorService.kt` and carries a permanent, silent,
/// un-dismissable row that says "monitoring". Posting alarms there would give
/// one channel two meanings and — the part that actually costs the user
/// something — would make "stop the alarms waking me" and "stop the monitoring
/// notification cluttering my shade" the same switch in Android's own settings.
/// They are opposite wishes and the OS offers exactly one control per channel.
const String kAlertChannelId = 'alerts';

/// How the system's notification permission currently stands.
///
/// 🔴 **[unknown] is not "denied" and the difference is a shipped defect
/// waiting to happen** (design 0080 §7.6.2 c). On iOS an un-asked permission
/// reports the same value as a refused one, so a screen that rendered "we have
/// asked and been told no" before ever asking would show every new user a red
/// row about a prompt they have never seen — and ruling Q4 turned the whole
/// feature off by default precisely to protect that one-shot prompt. So the
/// status starts [unknown] and only becomes meaningful once the request has
/// actually been made.
enum AlertPermission {
  /// Never asked on this device (or the platform has no such permission).
  unknown,

  /// Allowed — notifications will be shown.
  granted,

  /// Refused, but asking again is still possible.
  denied,

  /// Refused in a way the app cannot re-ask its way out of; the only route left
  /// is the system settings page (§6.2, "一鍵跳系統設定").
  permanentlyDenied,
}

/// One notification to show, fully formed. No formatting, no translation and no
/// arithmetic happen after this object is built.
class AlertNotification {
  const AlertNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.payload,
    required this.channelName,
    required this.channelDescription,
  });

  /// Stable per (unit, kind) — see `alertNotificationId`. 🔑 It is what makes a
  /// repeat UPDATE the existing row instead of stacking a second one, on both
  /// platforms, and it has to survive an app restart for that to hold, which is
  /// why it is derived from the id and the kind rather than from a counter.
  final int id;

  /// e.g. `阿福的機車 · 電壓過低`.
  final String title;

  /// e.g. `目前 10.82 V，門檻 11.00 V · 14:32`.
  final String body;

  /// Handed back on tap. The device id, so the tap can open THAT unit's alert
  /// settings — never "whichever unit is connected" (§3.9).
  final String payload;

  /// Android channel name/description, shown to the user in the system's own
  /// notification settings. Supplied here for reason 2 in the library comment.
  final String channelName;
  final String channelDescription;
}

/// Shows (and withdraws) local notifications.
abstract class AlertNotifier {
  /// Ask the OS for permission, returning whether it ended up granted.
  ///
  /// 🔑 Called from the FIRST-ENABLE flow only (§3.7.3), never at launch: an
  /// iOS prompt is one-shot and irreversible, so it has to be attached to a
  /// deliberate act by the user or the answer is worth nothing.
  Future<AlertPermission> ensurePermission();

  /// Read the status without prompting. See [AlertPermission.unknown] for why
  /// callers must not do this before the feature has been switched on.
  Future<AlertPermission> permissionStatus();

  /// Open the OS's app-settings page. False when it could not be opened.
  Future<bool> openSystemSettings();

  /// Show — or, for an id already on screen, UPDATE — one notification.
  Future<void> post(AlertNotification n);

  /// Withdraw one notification by id.
  Future<void> cancel(int id);

  /// Taps, as the payload the notification carried (the device id).
  Stream<String> get onTapped;

  /// The payload of the notification that launched a cold process, consumed
  /// once. Null when the app was started any other way.
  ///
  /// Separate from [onTapped] because it is not an event: by the time anything
  /// can listen, the tap has already happened. A stream would either have to
  /// replay (and then re-fire on every new listener) or drop it.
  Future<String?> takeLaunchPayload();

  /// Release resources.
  void dispose();

  /// The right implementation for the running platform.
  ///
  /// Desktop and tests get [NoopAlertNotifier] — the same split
  /// `MonitorService.forPlatform` makes, and for the same reason: the plugin
  /// has no registrant there, so every call would be a
  /// [MissingPluginException] the state layer would have to learn about.
  factory AlertNotifier.forPlatform() {
    if (Platform.isAndroid || Platform.isIOS) return LocalAlertNotifier();
    return NoopAlertNotifier();
  }
}

/// Records what it was asked to do and does nothing. Desktop, tests, and any
/// build where the plugin is absent.
///
/// 🔑 It keeps [posted] rather than being a pure no-op, because the assertions
/// design 0080 §5.1 asks for are all COUNTS — "one notification, not a
/// hundred", "zero for an unsaved unit", "the same id twice" — and a test that
/// has to reach into a mock framework to make them is a test nobody writes.
class NoopAlertNotifier implements AlertNotifier {
  final _tapped = StreamController<String>.broadcast();

  /// Everything [post] was handed, in order.
  final List<AlertNotification> posted = <AlertNotification>[];

  /// Ids passed to [cancel], in order.
  final List<int> cancelled = <int>[];

  /// What [ensurePermission] and [permissionStatus] answer. Settable so the
  /// refusal path (§6.2) is testable without a device.
  AlertPermission permission = AlertPermission.granted;

  /// Pretend the user tapped a notification carrying [payload].
  void tap(String payload) => _tapped.add(payload);

  @override
  Future<AlertPermission> ensurePermission() async => permission;

  @override
  Future<AlertPermission> permissionStatus() async => permission;

  @override
  Future<bool> openSystemSettings() async => false;

  @override
  Future<void> post(AlertNotification n) async => posted.add(n);

  @override
  Future<void> cancel(int id) async => cancelled.add(id);

  @override
  Stream<String> get onTapped => _tapped.stream;

  @override
  Future<String?> takeLaunchPayload() async => null;

  @override
  void dispose() => _tapped.close();
}

/// The real one: `flutter_local_notifications` on Android and iOS.
///
/// ## Why the plugin instead of two more platform channels
///
/// design 0080 §3.5.1 weighed it: Android already has half of one (the
/// foreground service's own notification, which is not a general pipeline), and
/// iOS has nothing at all — `UNUserNotificationCenter` would be written from
/// scratch, plus a test double for each side. The same position `wakelock_plus`
/// and `share_plus` already hold in this app: platform detail that a maintained
/// package does better goes to the package, and we keep only what nothing else
/// can do for us (the BLE keep-alive, the foreground service).
///
/// ## Why permission_handler and not the plugin's own request
///
/// The plugin can ask for the permission itself. It is told not to
/// ([DarwinInitializationSettings] with all three request flags false) because
/// this app already has ONE permission story — `permission_handler`, which is
/// what `BleService.ensurePermissions` and `GpsSpeedController` both use, and
/// which is the reason `geolocator` was taken with its own permission API
/// deliberately unused. Two permission stacks means two answers to "may we?",
/// and the day they disagree the user is told one thing on screen and shown
/// another by the OS.
class LocalAlertNotifier implements AlertNotifier {
  LocalAlertNotifier({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final _tapped = StreamController<String>.broadcast();

  bool _initialised = false;
  bool _launchPayloadTaken = false;

  /// Initialise once, lazily, on the first call that needs the plugin.
  ///
  /// Lazy rather than at startup on purpose: ruling Q4 ships the feature OFF,
  /// so on a phone whose owner never turns it on the plugin is never touched at
  /// all — the same "constructed but inert until its gate opens" contract
  /// `GpsSpeedController` and `GForceController` carry.
  Future<void> _ensureInit() async {
    if (_initialised) return;
    _initialised = true; // set first: a failed init must not be retried at 1 Hz
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          // The launcher icon. Android draws it as a silhouette, so an icon
          // with its own colours is not a problem here — it is the same asset
          // the foreground service's notification already uses.
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            // See the class doc: permission_handler owns the asking.
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: _onResponse,
      );
    } on PlatformException catch (e) {
      _warn('initialize failed: $e');
    } on MissingPluginException {
      // No registrant on this host (unit tests, an older embedding).
    }
  }

  void _onResponse(NotificationResponse r) {
    final payload = r.payload;
    // ⚠️ No `actionId` branch, and there must not be one: ruling Q2 means the
    // only response this app can receive is a plain tap. An action arriving
    // here would be evidence of a notification this build did not post.
    if (payload == null || payload.isEmpty || _tapped.isClosed) return;
    _tapped.add(payload);
  }

  @override
  Future<AlertPermission> ensurePermission() async {
    await _ensureInit();
    try {
      return _map(await Permission.notification.request());
    } catch (_) {
      // No plugin channel, or an OEM that refuses to be asked. Reported as
      // "we do not know" rather than "denied" — see [AlertPermission.unknown].
      return AlertPermission.unknown;
    }
  }

  @override
  Future<AlertPermission> permissionStatus() async {
    try {
      return _map(await Permission.notification.status);
    } catch (_) {
      return AlertPermission.unknown;
    }
  }

  @override
  Future<bool> openSystemSettings() async {
    try {
      return await openAppSettings();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> post(AlertNotification n) async {
    await _ensureInit();
    try {
      await _plugin.show(
        id: n.id,
        title: n.title,
        body: n.body,
        payload: n.payload,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            kAlertChannelId,
            n.channelName,
            channelDescription: n.channelDescription,
            // §3.5.3. HIGH is what produces a heads-up: this is the one
            // notification in the app that has to interrupt, because the
            // premise of the whole feature is that the phone is in a pocket.
            importance: Importance.high,
            priority: Priority.high,
            // 🔑 FALSE, and this is the de-duplication half that the id alone
            // does not give you. With `onlyAlertOnce` the repeat at 15 minutes
            // would silently replace the text and never make a sound — an
            // update the user cannot notice is indistinguishable from no
            // update, and §3.4's repeat exists precisely because they may have
            // missed the first one.
            onlyAlertOnce: false,
            category: AndroidNotificationCategory.alarm,
          ),
          iOS: const DarwinNotificationDetails(
            // Group per unit+kind so iOS stacks a repeat onto the same thread
            // rather than fanning it out. Same intent as the shared id.
            threadIdentifier: kAlertChannelId,
          ),
        ),
      );
    } on PlatformException catch (e) {
      _warn('show failed: $e');
    } on MissingPluginException {
      // No channel on this host.
    }
  }

  @override
  Future<void> cancel(int id) async {
    if (!_initialised) return; // nothing was ever posted
    try {
      await _plugin.cancel(id: id);
    } on PlatformException catch (_) {
      // Nothing to withdraw, or the shade refused. Not worth a line.
    } on MissingPluginException {
      // No channel on this host.
    }
  }

  @override
  Stream<String> get onTapped => _tapped.stream;

  @override
  Future<String?> takeLaunchPayload() async {
    if (_launchPayloadTaken) return null;
    _launchPayloadTaken = true;
    await _ensureInit();
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return null;
      final payload = details?.notificationResponse?.payload;
      return (payload == null || payload.isEmpty) ? null : payload;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  void dispose() => _tapped.close();

  static AlertPermission _map(PermissionStatus s) {
    if (s.isGranted || s.isLimited || s.isProvisional) {
      return AlertPermission.granted;
    }
    if (s.isPermanentlyDenied || s.isRestricted) {
      return AlertPermission.permanentlyDenied;
    }
    return AlertPermission.denied;
  }

  static void _warn(String message) {
    if (kDebugMode) debugPrint('alerts: $message');
  }
}
