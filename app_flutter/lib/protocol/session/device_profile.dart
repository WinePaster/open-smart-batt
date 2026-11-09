/// The static half of the device-profile seam (design 0099 §3.2, §3.4).
///
/// A [DeviceProfile] describes one protocol family: which GATT endpoints it
/// talks through, how to recognise it, and how to open a [ProtocolSession] for
/// one link. PURE Dart — the transport converts plugin types into the plain
/// [GattSnapshot] / [AdvertisementEvidence] values below before asking.
library;

import 'protocol_session.dart';

/// How strongly a GATT table says "this link speaks my protocol".
enum ProfileMatch {
  /// Not this protocol.
  none,

  /// Could be this protocol, but the endpoints are generic enough that other
  /// hardware shares them. Never enough to open a session or write a byte
  /// (design 0099 §3.4 rule 2).
  candidate,

  /// This protocol. The only state that opens a session.
  confirmed,
}

/// The characteristics a protocol writes to and listens on.
class GattEndpoints {
  const GattEndpoints({
    required this.serviceUuid,
    required this.writeCharUuid,
    required this.notifyCharUuid,
  });

  /// The service the characteristics are expected under. Preferred, not
  /// required: see [pickEndpoints].
  final String serviceUuid;
  final String writeCharUuid;
  final String notifyCharUuid;
}

/// One characteristic as discovery reported it.
class GattCharacteristicInfo {
  const GattCharacteristicInfo(
    this.uuid, {
    this.read = false,
    this.write = false,
    this.writeWithoutResponse = false,
    this.notify = false,
    this.indicate = false,
  });

  /// Normalised with [normaliseUuid].
  final String uuid;
  final bool read;
  final bool write;
  final bool writeWithoutResponse;
  final bool notify;
  final bool indicate;
}

/// One service and its characteristics, in discovery order.
class GattServiceInfo {
  const GattServiceInfo(this.uuid, this.characteristics);

  /// Normalised with [normaliseUuid].
  final String uuid;
  final List<GattCharacteristicInfo> characteristics;
}

/// A whole discovered GATT table, in discovery order.
class GattSnapshot {
  const GattSnapshot(this.services);
  final List<GattServiceInfo> services;
}

/// What a scan result says about a peripheral. Soft evidence only.
class AdvertisementEvidence {
  const AdvertisementEvidence({
    required this.name,
    this.serviceUuids = const [],
  });

  /// The platform name, or the advertised name when the platform has none.
  final String name;

  /// Normalised with [normaliseUuid].
  final List<String> serviceUuids;
}

/// One protocol family.
abstract interface class DeviceProfile {
  /// Stable slug for logs (and any future persistence).
  String get id;

  GattEndpoints get endpoints;

  /// Soft signal: list ordering and the "vendor" filter. Never decides the
  /// protocol.
  bool looksLikeThisDevice(AdvertisementEvidence ad);

  /// Hard signal: may this link speak this protocol?
  ProfileMatch matchGatt(GattSnapshot gatt);

  /// A fresh session for one link. Called only after this profile was the
  /// single [ProfileMatch.confirmed] match (see `resolveProfile`).
  ProtocolSession openSession();
}

/// Lower-case 128-bit form, so `fff0`, `FFF0` and the full Bluetooth-base
/// spelling compare equal. Anything that is not a 16- or 32-bit short form is
/// only lower-cased.
String normaliseUuid(String uuid) {
  final u = uuid.toLowerCase();
  if (u.length == 4) return '0000$u-0000-1000-8000-00805f9b34fb';
  if (u.length == 8) return '$u-0000-1000-8000-00805f9b34fb';
  return u;
}

/// Where, in a [GattSnapshot], a profile's write and notify characteristics
/// are: service index and characteristic index for each.
class EndpointPick {
  const EndpointPick({
    required this.writeService,
    required this.writeChar,
    required this.notifyService,
    required this.notifyChar,
  });
  final int writeService;
  final int writeChar;
  final int notifyService;
  final int notifyChar;
}

/// Pick [endpoints]' characteristics out of [gatt], or null when either is
/// missing.
///
/// The rule is the one the transport always used (moved verbatim from
/// `BleService._setupConnection`): prefer characteristics under the expected
/// service, but fall back to a full sweep — for RCE the service linkage is
/// inferred, not byte-fixed. Within that, the LAST match wins, as it did.
EndpointPick? pickEndpoints(GattSnapshot gatt, GattEndpoints endpoints) {
  final svcUuid = normaliseUuid(endpoints.serviceUuid);
  final writeUuid = normaliseUuid(endpoints.writeCharUuid);
  final notifyUuid = normaliseUuid(endpoints.notifyCharUuid);
  int? ws, wc, ns, nc;
  for (var i = 0; i < gatt.services.length; i++) {
    final svc = gatt.services[i];
    final preferred = svc.uuid == svcUuid;
    for (var j = 0; j < svc.characteristics.length; j++) {
      final c = svc.characteristics[j];
      if (c.uuid == writeUuid && (ws == null || preferred)) {
        ws = i;
        wc = j;
      }
      if (c.uuid == notifyUuid && (ns == null || preferred)) {
        ns = i;
        nc = j;
      }
    }
  }
  if (ws == null || ns == null) return null;
  return EndpointPick(
    writeService: ws,
    writeChar: wc!,
    notifyService: ns,
    notifyChar: nc!,
  );
}

/// Why [resolveProfile] did or did not pick a profile.
enum ProfileResolution {
  /// Exactly one profile confirmed.
  resolved,

  /// No profile matched at all.
  noMatch,

  /// Only candidates: plausible, never enough to write.
  candidatesOnly,

  /// More than one profile confirmed — a profile-list bug, not a device fact.
  ambiguous,
}

/// The outcome of [resolveProfile].
class ProfileChoice {
  const ProfileChoice(
    this.resolution, {
    this.profile,
    this.candidates = const [],
    this.confirmed = const [],
  });
  final ProfileResolution resolution;

  /// Set only when [resolution] is [ProfileResolution.resolved].
  final DeviceProfile? profile;

  /// Ids of the profiles that said [ProfileMatch.candidate].
  final List<String> candidates;

  /// Ids of the profiles that said [ProfileMatch.confirmed].
  final List<String> confirmed;
}

/// Design 0099 §3.4: a session opens only for EXACTLY ONE confirmed profile.
/// Candidates alone, or several confirmed, open nothing — and nothing opened
/// means nothing written.
ProfileChoice resolveProfile(List<DeviceProfile> profiles, GattSnapshot gatt) {
  final confirmed = <DeviceProfile>[];
  final candidates = <String>[];
  for (final p in profiles) {
    switch (p.matchGatt(gatt)) {
      case ProfileMatch.confirmed:
        confirmed.add(p);
      case ProfileMatch.candidate:
        candidates.add(p.id);
      case ProfileMatch.none:
        break;
    }
  }
  final ids = [for (final p in confirmed) p.id];
  if (confirmed.length == 1) {
    return ProfileChoice(
      ProfileResolution.resolved,
      profile: confirmed.single,
      candidates: candidates,
      confirmed: ids,
    );
  }
  if (confirmed.length > 1) {
    return ProfileChoice(
      ProfileResolution.ambiguous,
      candidates: candidates,
      confirmed: ids,
    );
  }
  if (candidates.isNotEmpty) {
    return ProfileChoice(
      ProfileResolution.candidatesOnly,
      candidates: candidates,
    );
  }
  return const ProfileChoice(ProfileResolution.noMatch);
}
