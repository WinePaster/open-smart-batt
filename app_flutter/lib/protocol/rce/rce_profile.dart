/// The RCE protocol family as a [DeviceProfile] (design 0099 P2).
///
/// Behaviour is what the transport did before the seam: a link is RCE when
/// discovery finds both the write and the notify characteristic, anywhere in
/// the table; a scan result looks like RCE when it advertises the vendor
/// service or carries a vendor name token.
library;

import '../command_builder.dart';
import '../gatt.dart';
import '../metadata_parser.dart';
import '../session/device_profile.dart';
import '../session/protocol_session.dart';
import 'rce_advertising.dart';
import 'rce_session.dart';

class RceProfile implements DeviceProfile {
  const RceProfile({
    this.parser = const NoopMetadataParser(),
    this.commands = const CommandBuilder(),
  });

  /// Handed to every session's decoder (the open build's is a no-op).
  final MetadataParser parser;

  /// Builds the poll tokens.
  final CommandBuilder commands;

  @override
  String get id => 'rce';

  @override
  GattEndpoints get endpoints => const GattEndpoints(
    serviceUuid: Gatt.serviceUuid,
    writeCharUuid: Gatt.writeCharUuid,
    notifyCharUuid: Gatt.notifyCharUuid,
  );

  @override
  bool looksLikeThisDevice(AdvertisementEvidence ad) =>
      ad.serviceUuids.contains(normaliseUuid(Gatt.serviceUuid)) ||
      looksLikeVendorName(ad.name);

  /// The RCE UUIDs share a vendor-specific base, so finding both is
  /// confirmation, not a guess (design 0099 §2.3).
  @override
  ProfileMatch matchGatt(GattSnapshot gatt) =>
      pickEndpoints(gatt, endpoints) == null
      ? ProfileMatch.none
      : ProfileMatch.confirmed;

  @override
  ProtocolSession openSession() =>
      RceSession(parser: parser, commands: commands);
}
