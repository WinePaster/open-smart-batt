/// OpenSmartBatt — state layer barrel (provider + ChangeNotifier).
///
/// The UI imports this to reach the controllers and the composition root.
/// Controllers own all IO (BLE/DB/timers); the protocol + models layers stay
/// pure Dart. Wire them via `MultiProvider` in `main.dart`.
library;

export 'accel_estimator.dart';
export 'app_services.dart';
export 'build_info.dart';
export 'connection_controller.dart';
export 'device_controller.dart';
export 'g_force_config.dart';
export 'g_force_controller.dart';
export 'g_force_estimator.dart';
export 'gps_speed_controller.dart';
export 'live_trend_buffer.dart';
export 'session_context.dart';
export 'settings_controller.dart';
export 'speed_estimator.dart';
export 'speed_lifecycle_gate.dart';
export 'telemetry_controller.dart';
export 'telemetry_health.dart';
