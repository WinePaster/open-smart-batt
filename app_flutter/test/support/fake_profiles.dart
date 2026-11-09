// Test-only profiles for the device-profile seam (design 0099).
import 'package:open_smart_batt/models/telemetry_sample.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

/// A profile whose GATT verdict is fixed by the test.
class FixedMatchProfile implements DeviceProfile {
  FixedMatchProfile(
    this.id,
    this.match, {
    this.endpoints = const GattEndpoints(
      serviceUuid: '0000aa00-0000-1000-8000-00805f9b34fb',
      writeCharUuid: '0000aa01-0000-1000-8000-00805f9b34fb',
      notifyCharUuid: '0000aa02-0000-1000-8000-00805f9b34fb',
    ),
  });

  @override
  final String id;
  final ProfileMatch match;
  @override
  final GattEndpoints endpoints;
  int sessionsOpened = 0;

  @override
  bool looksLikeThisDevice(AdvertisementEvidence ad) => false;

  @override
  ProfileMatch matchGatt(GattSnapshot gatt) => match;

  @override
  ProtocolSession openSession() {
    sessionsOpened++;
    return SilentSession();
  }
}

/// A session that never polls and refuses every write.
class SilentSession implements ProtocolSession {
  final TelemetrySample _sample = TelemetrySample.empty();
  @override
  Duration get tickInterval => const Duration(seconds: 1);
  @override
  Duration get stallThreshold => const Duration(seconds: 8);
  @override
  List<int>? nextPoll(int tick) => null;
  @override
  bool ingest(List<int> chunk, DateTime at) => false;
  @override
  TelemetrySample get sample => _sample;
  @override
  DeviceMetadata get metadata => const EmptyDeviceMetadata();
  @override
  void discardPartial() {}
  @override
  bool allowsWrite(List<int> bytes) => false;
}
