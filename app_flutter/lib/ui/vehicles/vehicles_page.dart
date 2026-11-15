/// design 0106 Phase 4 — the vehicle list (mock ⑨'s destination): add, order,
/// open a car's editor; 「個人裝置」 fixed last and never deletable (PQ1).
///
/// Reached from Settings (below the multi-device switch, only while it is on)
/// and from the home picker's 「管理車輛…」.
///
/// Drawn in the settings idiom — [IndustrialCard]s of [SettingsRow]-shaped
/// rows — because that is where the user arrives from; a stock Material list
/// here read as a different app (owner, 2026-11-15).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';

import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial.dart';
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

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(
          l10n.vehiclesPageTitle,
          style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700, color: c.text),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
            children: [
              // No card heading: the app bar already says 車輛, and a second
              // 車輛 one line below it reads as a mistake.
              IndustrialCard(
                child: cars.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(l10n.vehiclesPageEmpty,
                            style: TextStyle(
                                fontSize: 12, height: 1.5, color: c.muted)),
                      )
                    : ReorderableListView(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        buildDefaultDragHandles: false,
                        // Keep the lifted row in the card's own colours rather
                        // than Material's default elevated white sheet.
                        proxyDecorator: (child, _, _) => Material(
                          color: c.panel2,
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMd),
                          child: child,
                        ),
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
                              child: _VehicleRow(
                                vehicle: cars[i],
                                members: vehicleMemberNames(
                                    l10n, devices, cars[i]),
                                last: i == cars.length - 1,
                                onTap: () => open(cars[i].id),
                                handle: ReorderableDragStartListener(
                                  index: i,
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Icon(Icons.drag_handle,
                                        size: 20, color: c.muted),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
              if (personal != null)
                IndustrialCard(
                  child: _VehicleRow(
                    vehicle: personal,
                    members: vehicleMemberNames(l10n, devices, personal),
                    last: true,
                    onTap: () => open(personal.id),
                  ),
                ),
              const SizedBox(height: 4),
              VehicleOutlineButton(
                key: const ValueKey('vehicles-add'),
                icon: Icons.add,
                label: l10n.vehiclePickerAdd(cars.length, Vehicle.maxCars),
                onTap: canAdd ? () => open(null) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One vehicle, in the [SettingsRow] shape: name, its devices underneath, a
/// chevron (and, for a car, the drag handle) on the right.
class _VehicleRow extends StatelessWidget {
  const _VehicleRow({
    required this.vehicle,
    required this.members,
    required this.onTap,
    required this.last,
    this.handle,
  });

  final Vehicle vehicle;
  final String members;
  final VoidCallback onTap;
  final bool last;
  final Widget? handle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    return InkWell(
      key: ValueKey('vehicles-row-${vehicle.id}'),
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.fromLTRB(2, 11, handle == null ? 2 : 0, 11),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: c.line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    vehicleDisplayName(l10n, vehicle),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, color: c.text),
                  ),
                  if (members.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      members,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10.5, height: 1.5, color: c.muted),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 16, color: c.muted),
            ?handle,
          ],
        ),
      ),
    );
  }
}
