/// design 0106 Phase 2 — the vehicles, in memory, for the UI and for
/// [MultiLinkController]'s auto-connect (Phase 3).
///
/// Holds no policy beyond what [VehicleRepo] enforces: the rules are there,
/// this mirrors the tables and tells listeners when they change. INERT for
/// everyone who never creates a car — [hasCars] is false and every reader
/// falls back to the pre-0106 behaviour.
library;

import 'package:flutter/foundation.dart';

import '../data/data.dart';
import '../models/models.dart';
import 'device_controller.dart';

class VehicleController extends ChangeNotifier {
  VehicleController(this._repo, {DeviceController? devices, PendingWrites? pending})
      : _devicesCtl = devices,
        // ignore: prefer_initializing_formals
        _pending = pending {
    _devicesCtl?.addListener(_onDevicesChanged);
  }

  final VehicleRepo _repo;
  final DeviceController? _devicesCtl;
  final PendingWrites? _pending;

  List<Vehicle> _vehicles = const <Vehicle>[];
  String? _currentId;
  String _deviceSig = '';
  bool _disposed = false;

  /// Every vehicle: cars by their order, the personal row last.
  List<Vehicle> get vehicles => _vehicles;

  List<Vehicle> get cars => [for (final v in _vehicles) if (v.isCar) v];

  /// The 「個人裝置」 row, or null before the first car exists.
  Vehicle? get personal {
    for (final v in _vehicles) {
      if (v.isPersonal) return v;
    }
    return null;
  }

  /// Whether vehicle mode exists at all. ⚠️ Not the same as "active": that
  /// also needs the multi-link switch on, which [MultiLinkController] owns.
  bool get hasCars => _vehicles.any((v) => v.isCar);

  Vehicle? get current => vehicleFor(_currentId);

  Vehicle? vehicleFor(String? id) {
    if (id == null) return null;
    for (final v in _vehicles) {
      if (v.id == id) return v;
    }
    return null;
  }

  /// The vehicles [deviceId] belongs to (a battery or capacitor may be in two
  /// cars, ruling Q2; a power bank only ever in the personal row).
  List<Vehicle> vehiclesOf(String deviceId) =>
      [for (final v in _vehicles) if (v.contains(deviceId)) v];

  Future<void> load() async {
    final all = await _repo.getAll();
    final cur = await _repo.currentId();
    if (_disposed) return;
    _vehicles = all;
    _currentId = cur;
    _deviceSig = _sigOf(_devicesCtl);
    notifyListeners();
  }

  /// Select the current vehicle (null = none). Rejects an unknown id.
  Future<void> select(String? id) async {
    if (id == _currentId) return;
    await _repo.setCurrent(id);
    await load();
  }

  Future<Vehicle> createCar(String name) async {
    final v = await _repo.createCar(name);
    await load();
    return v;
  }

  Future<void> rename(String id, String name) async {
    await _repo.rename(id, name);
    await load();
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    await load();
  }

  Future<void> setDevices(String id, List<String> deviceIds) async {
    await _repo.setDevices(id, deviceIds);
    await load();
  }

  Future<void> setHomeLayout(String id, HomeLayout? layout) async {
    await _repo.setHomeLayout(id, layout);
    await load();
  }

  Future<void> reorderCars(List<String> carIds) async {
    await _repo.reorderCars(carIds);
    await load();
  }

  /// PQ2: the power bank just connected becomes the personal row's default.
  /// Fire-and-forget from the link layer, so it is registered with
  /// [PendingWrites] to be drained before the database closes.
  void notePowerBank(String deviceId) {
    final p = personal;
    if (p == null || !p.contains(deviceId) || p.lastPowerBankId == deviceId) {
      return;
    }
    final f = _repo.setLastPowerBank(deviceId).then((_) => load());
    _pending?.add(f);
  }

  /// §3.2: a car member turned out on the wire to be a power bank.
  Future<bool> movePowerBankToPersonal(String deviceId) async {
    final moved = await _repo.movePowerBankToPersonal(deviceId);
    if (moved) await load();
    return moved;
  }

  /// A saved unit was added, removed or re-keyed: the repo already rewrote the
  /// tables in the same transaction (DeviceRepo), so re-read them. Only when
  /// the SET of ids changed — the device list also notifies on every
  /// last-seen touch, which is no reason to query.
  void _onDevicesChanged() {
    if (_disposed) return;
    final sig = _sigOf(_devicesCtl);
    if (sig == _deviceSig) return;
    _deviceSig = sig;
    if (_vehicles.isEmpty) return;
    final f = load();
    _pending?.add(f);
  }

  static String _sigOf(DeviceController? d) {
    if (d == null) return '';
    final ids = [for (final x in d.devices) x.id]..sort();
    return ids.join(',');
  }

  @override
  void dispose() {
    _disposed = true;
    _devicesCtl?.removeListener(_onDevicesChanged);
    super.dispose();
  }
}
