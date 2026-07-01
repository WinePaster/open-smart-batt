/// OpenSmartBatt protocol layer — pure Dart, no Flutter, no IO.
///
/// Barrel export. The BLE / State / UI layers depend ONLY on this surface for
/// wire encoding & decoding. Transport constants live in [gatt].
library;

export 'frame.dart';
export 'selectors.dart';
export 'command_builder.dart';
export 'inbound_frame.dart';
export 'telemetry_decoder.dart';
export 'gatt.dart';
