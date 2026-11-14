/// design 0106 Phase 4 — edit one vehicle (mock ⑥): its name, which saved
/// units belong to it, an entry to its own home layout, and delete.
///
/// The rules are the repository's (design 0106 §3.2) — at most three units in
/// a car (Q6), power banks only in 「個人裝置」 (R6), unknown classes nowhere —
/// and this page only mirrors them so a refused write is rare. When one is
/// refused anyway the code is turned into a sentence ([vehicleRuleMessage]).
///
/// ⛔ The name is never exported or logged (§4.3: it may be a plate number);
/// the note under the field says so to the user.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';

import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../home/home_editor_page.dart';
import 'vehicle_ui.dart';

class VehicleEditorPage extends StatefulWidget {
  /// Null creates a new car.
  const VehicleEditorPage({super.key, required this.vehicleId});

  final String? vehicleId;

  @override
  State<VehicleEditorPage> createState() => _VehicleEditorPageState();
}

class _VehicleEditorPageState extends State<VehicleEditorPage> {
  final _name = TextEditingController();
  List<String>? _selected;
  bool _saving = false;

  Vehicle? get _vehicle =>
      context.read<VehicleController>().vehicleFor(widget.vehicleId);

  VehicleKind get _kind => _vehicle?.kind ?? VehicleKind.car;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selected == null) {
      final v = _vehicle;
      _name.text = v?.isCar ?? false ? v!.name : '';
      _selected = List<String>.of(v?.deviceIds ?? const <String>[]);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final vc = context.read<VehicleController>();
    final devices = context.read<DeviceController>();
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final l10n = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      var v = _vehicle;
      if (v == null) {
        v = await createCarWithDefaults(vc, devices, _name.text.trim());
      } else if (v.isCar && v.name != _name.text.trim()) {
        await vc.rename(v.id, _name.text.trim());
      }
      final ids = _selected!;
      if (!_sameList(ids, v.deviceIds)) await vc.setDevices(v.id, ids);
      nav.pop();
    } on VehicleRuleException catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text(vehicleRuleMessage(l10n, e.code))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _delete() async {
    final v = _vehicle;
    if (v == null || !v.isCar) return;
    final l10n = AppLocalizations.of(context);
    final vc = context.read<VehicleController>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(
            l10n.vehicleEditorDeleteConfirm(vehicleDisplayName(l10n, v))),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.commonCancel)),
          TextButton(
              key: const ValueKey('vehicle-delete-confirm'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.vehicleEditorDeleteAction)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await vc.delete(v.id);
      nav.pop();
    } on VehicleRuleException catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text(vehicleRuleMessage(l10n, e.code))));
    }
  }

  void _toggle(String id, bool on) {
    setState(() {
      if (on) {
        if (!_selected!.contains(id)) _selected!.add(id);
      } else {
        _selected!.remove(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final vc = context.watch<VehicleController>();
    final devices = context.watch<DeviceController>();
    final v = vc.vehicleFor(widget.vehicleId);
    final isNew = widget.vehicleId == null;
    final kind = _kind;
    final personal = kind == VehicleKind.personal;
    final candidates = vehicleCandidates(devices.devices, kind);
    final sel = _selected!;
    final full = !personal && sel.length >= Vehicle.maxDevicesPerCar;
    final title = isNew
        ? l10n.vehicleEditorNewTitle
        : personal
            ? l10n.vehiclePersonal
            : l10n.vehicleEditorTitle;

    String alsoIn(String id) {
      final others = [
        for (final o in vc.vehiclesOf(id))
          if (o.id != widget.vehicleId && o.isCar) vehicleDisplayName(l10n, o),
      ];
      return others.isEmpty ? '' : l10n.vehicleEditorAlsoIn(others.join('、'));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            key: const ValueKey('vehicle-editor-done'),
            onPressed: _saving ? null : _save,
            child: Text(l10n.vehicleEditorDone),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (!personal) ...[
            TextField(
              key: const ValueKey('vehicle-name'),
              controller: _name,
              maxLength: 24,
              decoration: InputDecoration(
                labelText: l10n.vehicleEditorName,
                hintText: l10n.vehicleEditorNameHint,
              ),
            ),
            Text(l10n.vehicleEditorNameNote,
                style: TextStyle(fontSize: 12, color: c.muted)),
            const SizedBox(height: 16),
          ],
          Text(
            personal
                ? l10n.vehicleEditorPowerBanks
                : l10n.vehicleEditorDevices(
                    sel.length, Vehicle.maxDevicesPerCar),
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: c.muted),
          ),
          const SizedBox(height: 6),
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l10n.vehicleEditorNoDevices,
                  style: TextStyle(color: c.muted)),
            )
          else
            for (final d in candidates)
              Builder(builder: (context) {
                final on = sel.contains(d.id);
                final note = personal ? '' : alsoIn(d.id);
                return CheckboxListTile(
                  key: ValueKey('vehicle-device-${d.id}'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: on,
                  onChanged: (!on && full)
                      ? null
                      : (x) => _toggle(d.id, x ?? false),
                  title: Text(
                      d.alias.isEmpty ? l10n.devicesUnnamed : d.alias,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  subtitle: note.isEmpty
                      ? null
                      : Text(note,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: c.muted)),
                );
              }),
          if (!personal)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(l10n.vehicleEditorPowerBankNote,
                  style: TextStyle(fontSize: 12, color: c.muted)),
            ),
          if (v != null) ...[
            const SizedBox(height: 20),
            OutlinedButton.icon(
              key: const ValueKey('vehicle-edit-layout'),
              icon: const Icon(Icons.dashboard_customize_outlined),
              label: Text(l10n.vehicleEditorEditLayout),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => HomeEditorPage(vehicleId: v.id)),
              ),
            ),
          ],
          if (v != null && v.isCar) ...[
            const SizedBox(height: 10),
            TextButton.icon(
              key: const ValueKey('vehicle-delete'),
              icon: const Icon(Icons.delete_outline, color: AppSemantics.danger),
              label: Text(l10n.vehicleEditorDelete,
                  style: const TextStyle(color: AppSemantics.danger)),
              onPressed: _delete,
            ),
          ],
        ],
      ),
    );
  }
}
