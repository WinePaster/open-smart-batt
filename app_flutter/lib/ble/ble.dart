/// OpenSmartBatt — BLE layer barrel.
///
/// The State controllers import this; everything BLE-plugin-specific lives
/// behind [BleService].
library;

export 'ble_models.dart';
export 'ble_service.dart';
export 'exec_gap_tracker.dart';
export 'notify_keepalive_pacer.dart';
