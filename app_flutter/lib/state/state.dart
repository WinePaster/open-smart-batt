/// Open-RCE-Batt — state layer barrel (provider + ChangeNotifier).
///
/// The UI imports this to reach the controllers and the composition root.
/// Controllers own all IO (BLE/DB/timers); the protocol + models layers stay
/// pure Dart. Wire them via `MultiProvider` in `main.dart`.
library;

export 'app_services.dart';
export 'connection_controller.dart';
export 'device_controller.dart';
export 'settings_controller.dart';
export 'telemetry_controller.dart';
