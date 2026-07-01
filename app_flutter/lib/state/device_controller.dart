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
  }) {
    return save(SavedDevice(
      id: id,
      alias: alias,
      name: name,
      lastSeen: lastSeen ?? DateTime.now(),
      lastValue: lastValue,
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

  /// Forget a saved device, then reload.
  Future<void> remove(String id) async {
    await _repo.deleteSavedDevice(id);
    await load();
  }
}
