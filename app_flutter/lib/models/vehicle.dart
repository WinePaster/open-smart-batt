/// design 0106 — a vehicle: a named group of saved units with a home layout of
/// its own, and the unit of "which devices should be connected right now".
///
/// Two kinds. A [VehicleKind.car] holds batteries and capacitors — at most
/// [Vehicle.maxDevicesPerCar] of them (ruling R8 / Q6, 「就是最多三個」, which is
/// also the concurrent-link limit, so a whole car can always be connected).
/// The single [VehicleKind.personal] row — shown as 「個人裝置」, never renamed,
/// never deleted — holds power banks and nothing else (ruling R6 / PQ1–PQ4).
/// Keeping power banks out of cars is what keeps a power bank from ever sharing
/// the radio with a car's units (FB-20).
library;

import 'home_layout.dart';

enum VehicleKind {
  car,
  personal;

  String get storageKey => name;

  static VehicleKind fromStorageKey(String? key) =>
      key == 'personal' ? VehicleKind.personal : VehicleKind.car;
}

class Vehicle {
  const Vehicle({
    required this.id,
    required this.kind,
    required this.name,
    required this.sort,
    this.homeLayout,
    this.deviceIds = const <String>[],
    this.lastPowerBankId,
  });

  /// Ruling Q8: at most five cars. The personal row does not count (PQ1).
  static const int maxCars = 5;

  /// Ruling R8 / Q6. Equal to the concurrent-link limit on purpose.
  static const int maxDevicesPerCar = 3;

  /// The personal row is always sorted last.
  static const int personalSort = 999;

  final String id;
  final VehicleKind kind;

  /// The user's name for a car. Empty for the personal row, which the UI always
  /// labels 「個人裝置」. ⛔ Never written to logs or exports — it may be a plate
  /// number (design 0106 §4.3).
  final String name;
  final int sort;

  /// This vehicle's home layout, or null for the generated default. Same model
  /// as the single pre-0106 home layout, per-card auto/user flags included.
  final HomeLayout? homeLayout;

  /// Member units, in the user's order.
  final List<String> deviceIds;

  /// Personal row only: the power bank connected last (PQ2's default).
  final String? lastPowerBankId;

  bool get isPersonal => kind == VehicleKind.personal;
  bool get isCar => kind == VehicleKind.car;

  bool contains(String deviceId) => deviceIds.contains(deviceId);

  @override
  String toString() =>
      'Vehicle(${kind.name} $id devices=${deviceIds.length} sort=$sort)';
}

/// Why a vehicle write was refused. The rules live in the repository, not in
/// the screens (design 0106 §3.2), so every caller gets the same answer.
class VehicleRuleException implements Exception {
  const VehicleRuleException(this.code);

  /// `vehicle_limit` (6th car), `vehicle_device_limit` (4th unit in a car),
  /// `power_bank_in_car`, `personal_only_power_banks`, `unknown_class`,
  /// `personal_fixed` (rename/delete the personal row), `not_found`.
  final String code;

  @override
  String toString() => 'VehicleRuleException($code)';
}
