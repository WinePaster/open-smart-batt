/// OpenSmartBatt — what a unit said about ITSELF (design 0057).
///
/// PURE Dart (no Flutter imports).
///
/// 🔑 The name is the specification. This is **not** a second `SavedDevice` and
/// it is **not** "devices we recognise": every field here was read off the wire
/// during some connection, and none of it is a user preference. `saved_devices`
/// mixes the two — `alias`/`display_layout` are the user's, `name`/
/// `product_class`/`mac`/`serial` are the device's — and its only entrance is
/// the naming dialog, so declining to name a unit threw away the facts it had
/// just told us along with the name it never got (design 0057 §2).
///
/// 🔴 **Nothing in routing may read this.** A cached class here never decides
/// which layout the next connection draws; that stays `saved_devices`-only, so
/// deleting a device really does mean "start again as a stranger" (design 0057
/// §3, and T57-3 in `device_facts_test.dart` pins it). What this table serves is
/// the other direction in time: reading PAST records back out — the history
/// picker's labels, the export header, and whether an exported `ampere` column
/// is a measurement or a capacitor's permanent 0.0 A.
library;

import 'product_class.dart';

/// One BLE id's worth of device-stated facts.
class DeviceFacts {
  const DeviceFacts({
    required this.id,
    required this.firstSeen,
    required this.lastSeen,
    this.name,
    this.productClass = ProductClass.unknown,
    this.mac,
    this.serial,
  });

  /// BLE remote id — the SAME key `history.device_id` and `diag_log.device_id`
  /// are written with, which is what makes an old row's identity findable.
  ///
  /// Deliberately the primary key even though [mac] is the stable identity of
  /// the physical unit: an iOS reinstall gives the same hardware a fresh NSUUID,
  /// and rewriting the old row's id to the new one would orphan every history
  /// row already recorded under the old id. Two rows for one machine is the
  /// intended shape; see [DeviceFactsRepo.observe] (design 0057 §4.1.1).
  final String id;

  /// Advertised local name (e.g. `RCE_RSPB-01`) — a MODEL, not a unit. Two
  /// power banks in the same 2026-07-29 capture both advertise `RCE_RSPB-01`,
  /// which is why anything that shows this to a user shows a short hash beside
  /// it (design 0057 Q2).
  final String? name;

  /// Class decoded from the `0x10` device-type byte. [ProductClass.unknown]
  /// means "no byte seen for this id yet" and is stored as NULL, so "not
  /// observed" stays distinct from a class we actually read.
  ///
  /// 🔴 Only ever written from the WIRE. The user's manual class pick and the
  /// saved-record seed are both excluded on purpose — a table called "facts"
  /// that quietly stores a guess would be worse than no table.
  final ProductClass productClass;

  /// The unit's own BLE address from selector `0x38` — the stable identity of
  /// the physical machine across platforms and reinstalls.
  ///
  /// 🔴 CLEAN-ROOM: raw personal data, fine to hold internally; an export writes
  /// its `shortDeviceHash` and never this (design 0027 §3.1).
  final String? mac;

  /// Full product serial. NULL until observed, and for classes that carry none.
  final String? serial;

  /// When this id was first recorded here, and when it last said anything.
  /// Both NOT NULL: a row exists because a connection happened, so there is
  /// always an instant to name.
  final DateTime firstSeen;
  final DateTime lastSeen;

  Map<String, Object?> toMap() => {
        'id': id,
        // Empty strings are stored as NULL throughout: an advertised name of ''
        // is "the unit advertised nothing", which is the same state as "we have
        // not looked", and inventing a difference between them would give the
        // merge rules in [DeviceFactsRepo.observe] a value to prefer that means
        // nothing.
        'name': (name?.isEmpty ?? true) ? null : name,
        'product_class':
            productClass == ProductClass.unknown ? null : productClass.storageKey,
        'mac': (mac?.isEmpty ?? true) ? null : mac,
        'serial': (serial?.isEmpty ?? true) ? null : serial,
        'first_seen': firstSeen.millisecondsSinceEpoch,
        'last_seen': lastSeen.millisecondsSinceEpoch,
      };

  static DeviceFacts fromMap(Map<String, Object?> m) => DeviceFacts(
        id: m['id'] as String,
        name: m['name'] as String?,
        productClass:
            ProductClass.fromStorageKey(m['product_class'] as String?),
        mac: m['mac'] as String?,
        serial: m['serial'] as String?,
        firstSeen: DateTime.fromMillisecondsSinceEpoch(
            (m['first_seen'] as num?)?.toInt() ?? 0),
        lastSeen: DateTime.fromMillisecondsSinceEpoch(
            (m['last_seen'] as num?)?.toInt() ?? 0),
      );
}
