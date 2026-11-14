/// design 0106 Phase 4 — the vehicle list (mock ⑨'s destination): add, order,
/// open a car's editor; 「個人裝置」 fixed last and never deletable (PQ1).
///
/// Reached from Settings (below the multi-device switch, only while it is on)
/// and from the home picker's 「管理車輛…」.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';

import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'vehicle_editor_page.dart';
import 'vehicle_ui.dart';

class VehiclesPage extends StatelessWidget {
  const VehiclesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final vc = context.watch<VehicleController>();
    final devices = context.watch<DeviceController>();
    final cars = vc.cars;
    final personal = vc.personal;
    final canAdd = cars.length < Vehicle.maxCars;

    void open(String? id) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => VehicleEditorPage(vehicleId: id)));

    String members(Vehicle v) => [
          for (final id in v.deviceIds)
            if (devices.deviceFor(id) case final d?)
              d.alias.isEmpty ? l10n.devicesUnnamed : d.alias,
        ].join('、');

    Widget tile(Vehicle v, {Widget? trailing}) => ListTile(
          key: ValueKey('vehicles-row-${v.id}'),
          title: Text(vehicleDisplayName(l10n, v),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: v.deviceIds.isEmpty
              ? null
              : Text(members(v),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: c.muted)),
          trailing: trailing,
          onTap: () => open(v.id),
        );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.vehiclesPageTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (cars.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Text(l10n.vehiclesPageEmpty,
                  style: TextStyle(color: c.muted)),
            )
          else
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) {
                final ids = [for (final v in cars) v.id];
                final id = ids.removeAt(from);
                ids.insert(to, id);
                vc.reorderCars(ids);
              },
              children: [
                for (var i = 0; i < cars.length; i++)
                  KeyedSubtree(
                    key: ValueKey('vehicles-car-${cars[i].id}'),
                    child: tile(
                      cars[i],
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: Icon(Icons.drag_handle, color: c.muted),
                      ),
                    ),
                  ),
              ],
            ),
          if (personal != null) ...[
            const Divider(),
            tile(personal),
          ],
          const Divider(),
          ListTile(
            key: const ValueKey('vehicles-add'),
            enabled: canAdd,
            leading: const Icon(Icons.add),
            title: Text(l10n.vehiclePickerAdd(cars.length, Vehicle.maxCars)),
            onTap: canAdd ? () => open(null) : null,
          ),
        ],
      ),
    );
  }
}
