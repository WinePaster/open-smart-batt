/// design 0106 Phase 4 — the small shared pieces of the vehicle UI: when it is
/// visible at all, what a vehicle is called on screen, the picker opened from
/// the home title, and F3 ("opening a unit switches the home page to its
/// vehicle").
///
/// 🔴 Visibility rule, the one every vehicle surface goes through: the
/// multi-device switch is ON **and** at least one car exists. Switch off, or no
/// car ⇒ [visibleVehicles] is null and every caller draws exactly what it drew
/// before 0106 (mock ⑦ / ⑧). That is what keeps single-device users and anyone
/// who never opened the experiment free of any change.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';

import '../../demo/demo.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'vehicle_editor_page.dart';
import 'vehicles_page.dart';

/// The vehicles, when vehicle mode is visible (see the library comment); null
/// otherwise. Subscribes to the switch and to the vehicle list.
///
/// Watches the multi-link controller through `select` on its ON flag only: the
/// controller notifies on every link event, and a home grid rebuilt at sample
/// rate would be the price of a one-bit question.
VehicleController? visibleVehicles(BuildContext context) {
  final on = context.select<MultiLinkController?, bool>(
      (m) => m?.enabled ?? false);
  final vc = context.watch<VehicleController?>();
  if (!on || vc == null || !vc.hasCars) return null;
  return vc;
}

/// [visibleVehicles] for handlers (no subscription).
VehicleController? readVisibleVehicles(BuildContext context) {
  final ml = context.read<MultiLinkController?>();
  final vc = context.read<VehicleController?>();
  if (ml == null || !ml.enabled || vc == null || !vc.hasCars) return null;
  return vc;
}

/// What a vehicle is called on screen. The personal row is always 「個人裝置」
/// (PQ4); an empty car name falls back rather than drawing nothing.
String vehicleDisplayName(AppLocalizations l10n, Vehicle v) {
  if (v.isPersonal) return l10n.vehiclePersonal;
  return v.name.trim().isEmpty ? l10n.vehicleUnnamed : v.name;
}

/// [VehicleRuleException.code] → a sentence a user can act on.
String vehicleRuleMessage(AppLocalizations l10n, String code) =>
    switch (code) {
      'vehicle_limit' => l10n.vehicleErrorLimit,
      'vehicle_device_limit' => l10n.vehicleErrorDeviceLimit,
      'power_bank_in_car' => l10n.vehicleErrorPowerBankInCar,
      'personal_only_power_banks' => l10n.vehicleErrorPersonalOnlyPowerBanks,
      'unknown_class' => l10n.vehicleErrorUnknownClass,
      'personal_fixed' => l10n.vehicleErrorPersonalFixed,
      _ => l10n.vehicleErrorNotFound,
    };

/// Whether any member of [v] is in range by auto-connect's own rule (live on a
/// secondary, the live primary, or seen within the presence window).
bool vehicleNearby(Vehicle v, MultiLinkController? ml, ConnectionController? conn) {
  for (final id in v.deviceIds) {
    if (ml?.isNearby(id) ?? false) return true;
    if (conn != null && conn.isOnline && conn.connectedDeviceId == id) {
      return true;
    }
  }
  return false;
}

/// Saved units that can join [v]: batteries and capacitors for a car, power
/// banks for the personal row. Unknown class and demo units are never offered
/// (the repository refuses them too — `unknown_class`).
List<SavedDevice> vehicleCandidates(List<SavedDevice> saved, VehicleKind kind) => [
      for (final d in saved)
        if (!isDemoDeviceId(d.id) &&
            d.productClass != ProductClass.unknown &&
            ((kind == VehicleKind.personal) ==
                (d.productClass == ProductClass.powerBank)))
          d,
    ];

/// Create a car from a name, and on the FIRST car put every saved power bank
/// into the personal row (mock ④ shows them there without the user doing
/// anything — and a power bank outside it could never be connected in vehicle
/// mode, R6).
Future<Vehicle> createCarWithDefaults(
    VehicleController vc, DeviceController devices, String name) async {
  final first = !vc.hasCars;
  final car = await vc.createCar(name);
  final personal = vc.personal;
  if (first && personal != null && personal.deviceIds.isEmpty) {
    final banks = [
      for (final d in vehicleCandidates(devices.devices, VehicleKind.personal))
        d.id,
    ];
    if (banks.isNotEmpty) {
      try {
        await vc.setDevices(personal.id, banks);
      } on VehicleRuleException {
        // A bank the repo will not take is simply left out; nothing to show.
      }
    }
  }
  return car;
}

/// F3 (design 0106 Q2): a unit was opened from the saved list. If it belongs to
/// exactly ONE vehicle that is not the current one, the home page follows it
/// (a power bank ⇒ 「個人裝置」), with a one-time snackbar. A unit shared by two
/// cars, or in none, changes nothing.
void followDeviceToVehicle(BuildContext context, String deviceId,
    {String alias = ''}) {
  final vc = readVisibleVehicles(context);
  if (vc == null) return;
  final owners = vc.vehiclesOf(deviceId);
  if (owners.length != 1) return;
  final target = owners.single;
  if (vc.current?.id == target.id) return;
  final l10n = AppLocalizations.of(context);
  final name = vehicleDisplayName(l10n, target);
  final messenger = ScaffoldMessenger.maybeOf(context);
  unawaited(vc.select(target.id, source: 'device-page'));
  messenger?.showSnackBar(SnackBar(
    duration: const Duration(milliseconds: 2400),
    content: Text(l10n.vehicleSwitchedToast(
        name, alias.isEmpty ? l10n.devicesUnnamed : alias)),
  ));
}

/// The home title in vehicle mode: 「A 車 ▾」, a 離線 tag when none of its
/// devices is nearby (Q3), and the offline banner under it.
class VehicleHeader extends StatelessWidget {
  const VehicleHeader({super.key, required this.vehicles});

  final VehicleController vehicles;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    // The nearby dot / offline tag read presence, which moves with the radio:
    // this small widget subscribes, the grid under it does not.
    final ml = context.watch<MultiLinkController?>();
    final conn = context.watch<ConnectionController?>();
    final cur = vehicles.current;
    final name = cur == null ? l10n.vehiclePickerTitle : vehicleDisplayName(l10n, cur);
    final offline = cur != null &&
        cur.deviceIds.isNotEmpty &&
        !vehicleNearby(cur, ml, conn);
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 8, 15, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: name,
            child: InkWell(
              key: const ValueKey('vehicle-title'),
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              onTap: () => showVehiclePicker(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: c.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.expand_more,
                        size: 22, color: context.accent.accent),
                    if (offline) ...[
                      const SizedBox(width: 6),
                      Text(
                        l10n.vehicleOffline,
                        maxLines: 1,
                        style: TextStyle(fontSize: 12, color: c.muted),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (offline && cur.isCar)
            Container(
              key: const ValueKey('vehicle-offline-banner'),
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4, bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: c.panel2,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(color: c.line2),
              ),
              child: Text(
                l10n.vehicleOfflineBanner(name),
                style: TextStyle(fontSize: 12.5, color: c.muted, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }
}

/// The picker (mock ①b): cars with a nearby dot, 「個人裝置」 fixed last,
/// 「＋ 新增車輛（n／5）」 and 「管理車輛…」.
Future<void> showVehiclePicker(BuildContext context) async {
  final vc = readVisibleVehicles(context);
  if (vc == null) return;
  final nav = Navigator.of(context);
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _VehiclePickerSheet(vehicles: vc),
  );
  if (picked == null) return;
  if (picked == _addKey) {
    await nav.push(MaterialPageRoute<void>(
        builder: (_) => const VehicleEditorPage(vehicleId: null)));
  } else if (picked == _manageKey) {
    await nav.push(
        MaterialPageRoute<void>(builder: (_) => const VehiclesPage()));
  } else {
    await vc.select(picked, source: 'home');
  }
}

const String _addKey = '\u0000add';
const String _manageKey = '\u0000manage';

class _VehiclePickerSheet extends StatelessWidget {
  const _VehiclePickerSheet({required this.vehicles});

  final VehicleController vehicles;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final ml = context.watch<MultiLinkController?>();
    final conn = context.watch<ConnectionController?>();
    final devices = context.watch<DeviceController>();
    String members(Vehicle v) {
      final names = <String>[];
      for (final id in v.deviceIds) {
        final d = devices.deviceFor(id);
        if (d != null) names.add(d.alias.isEmpty ? l10n.devicesUnnamed : d.alias);
      }
      return names.join('、');
    }

    Widget option(Vehicle v) {
      final on = vehicles.current?.id == v.id;
      final near = vehicleNearby(v, ml, conn);
      return ListTile(
        key: ValueKey('vehicle-option-${v.id}'),
        title: Row(
          children: [
            Flexible(
              child: Text(
                vehicleDisplayName(l10n, v),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: on ? FontWeight.w800 : FontWeight.w500,
                  color: on ? context.accent.accent : c.text,
                ),
              ),
            ),
            if (near) ...[
              const SizedBox(width: 6),
              Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(color: AppSemantics.good, shape: BoxShape.circle),
              ),
              const SizedBox(width: 4),
              Text(l10n.vehiclePickerNearby,
                  style: TextStyle(fontSize: 11, color: c.muted)),
            ],
          ],
        ),
        subtitle: v.deviceIds.isEmpty
            ? null
            : Text(members(v),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: c.muted)),
        trailing: on ? Icon(Icons.check, color: context.accent.accent) : null,
        onTap: () => Navigator.of(context).pop(v.id),
      );
    }

    final cars = vehicles.cars;
    final personal = vehicles.personal;
    final canAdd = cars.length < Vehicle.maxCars;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Text(l10n.vehiclePickerTitle,
                  style: TextStyle(
                      fontSize: 13, color: c.muted, fontWeight: FontWeight.w600)),
            ),
            for (final v in cars) option(v),
            if (personal != null) ...[
              const Divider(height: 8),
              option(personal),
            ],
            const Divider(height: 8),
            ListTile(
              key: const ValueKey('vehicle-option-add'),
              enabled: canAdd,
              leading: const Icon(Icons.add),
              title: Text(l10n.vehiclePickerAdd(cars.length, Vehicle.maxCars)),
              onTap: canAdd ? () => Navigator.of(context).pop(_addKey) : null,
            ),
            ListTile(
              key: const ValueKey('vehicle-option-manage'),
              leading: const Icon(Icons.tune),
              title: Text(l10n.vehiclePickerManage),
              onTap: () => Navigator.of(context).pop(_manageKey),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
