/// OpenSmartBatt — saved-device controller (mockup screen 3).
///
/// Owns the list of user-remembered batteries + their editable aliases for the
/// quick-reconnect flow. Backed by [DeviceRepo]; the BLE id is the stable key.
library;

import 'package:flutter/foundation.dart';

import '../data/data.dart';
import '../models/models.dart';

/// ChangeNotifier over the `saved_devices` table.
class DeviceController extends ChangeNotifier {
  DeviceController(this._repo);

  final DeviceRepo _repo;

  List<SavedDevice> _devices = const [];
  bool _loaded = false;

  /// Saved devices, most-recently-seen first (nulls last).
  List<SavedDevice> get devices => _devices;

  /// True once the table has been read at least once.
  bool get loaded => _loaded;

  /// Reload the saved-device list.
  Future<void> load() async {
    _devices = await _repo.getSavedDevices();
    _loaded = true;
    notifyListeners();
  }

  /// True if [id] is currently in the saved list.
  bool isSaved(String id) => _devices.any((d) => d.id == id);

  /// The saved entry for [id], or null.
  SavedDevice? deviceFor(String id) {
    for (final d in _devices) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Display alias for [id]: the saved alias if present and non-empty,
  /// otherwise [fallback] (typically the advertised name).
  String aliasFor(String id, {String fallback = ''}) {
    final d = deviceFor(id);
    final a = d?.alias ?? '';
    return a.isNotEmpty ? a : fallback;
  }

  /// Insert/replace a saved device, then reload.
  Future<void> save(SavedDevice device) async {
    await _repo.upsertSavedDevice(device);
    await load();
  }

  /// Convenience: save a freshly-connected device with an alias (mockup's
  /// post-connect "儲存裝置" dialog).
  Future<void> saveNew(
    String id,
    String alias, {
    String name = '',
    DateTime? lastSeen,
    double? lastValue,
    ProductClass productClass = ProductClass.unknown,
  }) {
    return save(SavedDevice(
      id: id,
      alias: alias,
      name: name,
      lastSeen: lastSeen ?? DateTime.now(),
      lastValue: lastValue,
      productClass: productClass,
    ));
  }

  /// Rename an existing device (mockup alias edit pencil), then reload.
  Future<void> rename(String id, String alias) async {
    await _repo.updateAlias(id, alias);
    await load();
  }

  /// Update last-seen / last-value meta for [id] (no-op if not saved).
  Future<void> touch(String id, {DateTime? lastSeen, double? lastValue}) async {
    if (!isSaved(id)) return;
    await _repo.touch(id, lastSeen: lastSeen, lastValue: lastValue);
    await load();
  }

  /// Persist the resolved product class / cosmetic pack label for [id] (design
  /// 0001 §5 Phase 5). No-op if the device is not saved or already at [value].
  Future<void> setProductClass(String id, ProductClass value) async {
    final existing = deviceFor(id);
    if (existing == null || existing.productClass == value) return;
    await _repo.setProductClass(id, value);
    await load();
  }

  /// The dashboard layout stored for [id].
  ///
  /// An unsaved device — and an id of `null` — has no layout of its own and
  /// gets [DisplayLayout.defaults], which draws today's screen. The dashboard
  /// therefore never has to special-case "not saved yet".
  DisplayLayout layoutFor(String? id) =>
      id == null ? DisplayLayout.defaults : deviceFor(id)?.displayLayout ?? DisplayLayout.defaults;

  /// Persist the dashboard layout for [id] (design 0034 Q3: bound to the
  /// device). No-op if the device is not saved or already at [value].
  ///
  /// Saving is NOT done implicitly here. A device the user declined to name is
  /// one they declined to remember, and quietly adding it to the saved list as
  /// a side effect of changing a watchface would put a row in the device
  /// picker that they never asked for. The settings row disables itself
  /// instead, and says why.
  Future<void> setDisplayLayout(String id, DisplayLayout value) async {
    final existing = deviceFor(id);
    if (existing == null || existing.displayLayout == value) return;
    await _repo.setDisplayLayout(id, value);
    await load();
  }

  /// Persist the device's own BLE address (0x38 MAC) and/or full serial for
  /// [id] (design 0027 §3.2). No-op if the device is not saved or if every
  /// supplied value already matches what is stored, so a live connection's
  /// repeated 0x38 frames do not each cost a DB write + reload.
  Future<void> setIdentity(String id, {String? mac, String? serial}) async {
    final existing = deviceFor(id);
    if (existing == null) return;
    final macChanged = mac != null && mac != existing.mac;
    final serialChanged = serial != null && serial != existing.serial;
    if (!macChanged && !serialChanged) return;
    await _repo.setIdentity(
      id,
      mac: macChanged ? mac : null,
      serial: serialChanged ? serial : null,
    );
    await load();
  }

  /// Forget a saved device, then reload.
  Future<void> remove(String id) async {
    await _repo.deleteSavedDevice(id);
    await load();
  }
}
