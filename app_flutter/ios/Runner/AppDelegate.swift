import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // design 0080 P3 (§3.5.1) — flutter_local_notifications' one required
    // native line on iOS.
    //
    // WHY IT MATTERS: without a delegate, iOS silently DROPS a local
    // notification whose app is in the foreground, and it also has nowhere to
    // deliver a tap. FlutterAppDelegate already conforms to
    // UNUserNotificationCenterDelegate and the plugin swizzles onto it, so
    // assigning `self` is the whole of the wiring — but assigning it is not
    // optional: the failure it prevents is invisible (nothing appears, no error
    // anywhere), and it is the failure a user would report as "iPhone never
    // warns me" while Android works.
    //
    // Guarded on the OS version for the same reason the rest of this file is
    // conservative about the embedding: iOS 10 predates the deployment target
    // (15.0, see ios/Podfile), so the branch is unreachable in practice and is
    // the plugin's own documented form.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
