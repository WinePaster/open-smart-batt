/// OpenSmartBatt — the in-memory view of `device_facts` (design 0057).
///
/// 🔴 Read the boundary on [DeviceFacts] first. This controller exists to serve
/// the READ-BACK of past records — history labels, export identity, whether an
/// exported `ampere` column is a measurement — and routing must never consult
/// it. `ConnectionController` holds one purely to WRITE.
library;

import 'package:flutter/foundation.dart';

import '../data/data.dart';
import '../models/models.dart';

/// ChangeNotifier over the `device_facts` table.
///
/// Holds the whole table in memory, like [DeviceController] does: the callers
/// are synchronous render paths (a history row's current column, a picker
/// label) that cannot await, and the table has one row per BLE id the phone has
/// ever connected to.
class DeviceFactsController extends ChangeNotifier {
  DeviceFactsController(this._repo);

  final DeviceFactsRepo _repo;

  Map<String, DeviceFacts> _byId = const {};
  bool _loaded = false;

  /// True once the table has been read at least once.
  bool get loaded => _loaded;

  /// Every cached row, oldest-first-seen first.
  List<DeviceFacts> get facts => _byId.values.toList(growable: false);

  /// What [id] has said about itself, or null if it never connected under this
  /// id (including every unit that only ever connected before schema v15 —
  /// there is no backfill, by design).
  DeviceFacts? factFor(String? id) => id == null ? null : _byId[id];

  /// Reload the whole table.
  Future<void> load() async {
    final all = await _repo.getAll();
    _byId = {for (final f in all) f.id: f};
    _loaded = true;
    notifyListeners();
  }

  /// How stale `last_seen` is allowed to get before a write happens purely to
  /// refresh it.
  ///
  /// Telemetry arrives at ~5 Hz and almost none of it is news, so without this
  /// a connected unit would rewrite its unchanged row 18,000 times an hour.
  /// Same value and same reasoning as [ConnectionController.lastSeenInterval],
  /// which throttles the equivalent write on `saved_devices`.
  static const Duration touchInterval = Duration(minutes: 1);

  /// Record what [id] just told us. Safe to call on every telemetry sample.
  ///
  /// Returns without touching the database when the cached row already carries
  /// every supplied value AND its `last_seen` is fresher than [touchInterval] —
  /// so the cost of the common case (a frame that repeats what we know) is a
  /// map lookup and four comparisons.
  ///
  /// 🔴 [productClass] must come from the WIRE. Passing the user's manual pick
  /// or a class seeded out of `saved_devices` would put a guess into a table
  /// named for facts, and — on a rebound iOS id — would copy one unit's class
  /// onto another's row, which is FB-25 from the other direction.
  Future<void> record(
    String id, {
    String? name,
    ProductClass? productClass,
    String? mac,
    String? serial,
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now();
    final existing = _byId[id];
    if (existing != null &&
        !_isNews(existing,
            name: name, productClass: productClass, mac: mac, serial: serial) &&
        now.difference(existing.lastSeen) < touchInterval) {
      return;
    }
    await _repo.observe(
      id,
      name: name,
      productClass: productClass,
      mac: mac,
      serial: serial,
      at: now,
    );
    // Reload rather than patch the one entry: [DeviceFactsRepo.observe] may
    // also have filled gaps in OTHER rows (the MAC reconcile, §4.1.1), and a
    // cache that only refreshed the row we wrote would miss exactly the case
    // that rule exists for.
    await load();
  }

  /// Does any supplied value say something the cached row does not already say?
  /// Absent and empty arguments are "nothing observed" and never count.
  bool _isNews(
    DeviceFacts existing, {
    String? name,
    ProductClass? productClass,
    String? mac,
    String? serial,
  }) {
    if (_differs(name, existing.name)) return true;
    if (_differs(mac, existing.mac)) return true;
    if (_differs(serial, existing.serial)) return true;
    return productClass != null &&
        productClass != ProductClass.unknown &&
        productClass != existing.productClass;
  }

  static bool _differs(String? observed, String? stored) =>
      observed != null && observed.isNotEmpty && observed != stored;
}
