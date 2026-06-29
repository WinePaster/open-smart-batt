/// Open-RCE-Batt — GATT transport constants (CAPTURE_VERIFIED §1 / PROTOCOL.md §3).
///
/// PURE Dart. UUID strings only; the BLE layer wraps them in plugin types.
library;

/// Vendor BLE GATT identifiers (all byte-proven in CAPTURE_VERIFIED §1 unless
/// noted). The base `…-d55f-5e82-ba44-81c0da86c46c` is shared; only the 16-bit
/// slot differs.
class Gatt {
  Gatt._();

  /// Scan filter service UUID (slot FFF0). Filter purely on this; no name filter.
  static const String serviceUuid = '07b9fff0-d55f-5e82-ba44-81c0da86c46c';

  /// Write characteristic (slot ACE3), value handle 0x0018, props 0x08
  /// = Write-Without-Response only. All commands + keep-alives go here.
  static const String writeCharUuid = '07b9ace3-d55f-5e82-ba44-81c0da86c46c';

  /// Notify characteristic (slot ACE4), value handle 0x001b, props 0x10 = Notify.
  static const String notifyCharUuid = '07b9ace4-d55f-5e82-ba44-81c0da86c46c';

  /// CCCD descriptor UUID (handle 0x001c). Enable notify = write [0x01, 0x00].
  static const String cccdUuid = '00002902-0000-1000-8000-00805f9b34fb';

  /// CCCD enable-notification payload (LE).
  static const List<int> enableNotifyValue = [0x01, 0x00];

  /// No MTU negotiation: leave default ATT MTU 23 (20-byte payload). All
  /// commands fit. Reassemble notifications into one byte stream and frame by LEN.
  static const int defaultMtu = 23;
}
