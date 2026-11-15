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
import '../widgets/industrial.dart';
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
      // The settings screen's own confirm shape: panel background, muted
      // cancel, the destructive word in red.
      builder: (ctx) => AlertDialog(
        backgroundColor: context.colors.panel,
        content: Text(
          l10n.vehicleEditorDeleteConfirm(vehicleDisplayName(l10n, v)),
          style: TextStyle(
              fontSize: 13, height: 1.6, color: context.colors.text),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.commonCancel,
                  style: TextStyle(color: context.colors.muted))),
          TextButton(
              key: const ValueKey('vehicle-delete-confirm'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.vehicleEditorDeleteAction,
                  style: const TextStyle(color: AppSemantics.danger))),
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

    // Mock ⑥: the other car(s) a unit is already in, right-aligned and muted.
    String alsoIn(String id) => [
          for (final o in vc.vehiclesOf(id))
            if (o.id != widget.vehicleId && o.isCar) vehicleDisplayName(l10n, o),
        ].join('、');

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: c.text)),
        actions: [
          TextButton(
            key: const ValueKey('vehicle-editor-done'),
            onPressed: _saving ? null : _save,
            child: Text(l10n.vehicleEditorDone,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: _saving ? c.muted : context.accent.accent)),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(15, 6, 15, 24),
            children: [
              if (!personal) ...[
                _NameField(controller: _name),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                  child: Text(l10n.vehicleEditorNameNote,
                      style: TextStyle(
                          fontSize: 10.5, height: 1.5, color: c.muted)),
                ),
              ],
              VehicleSectionLabel(personal
                  ? l10n.vehicleEditorPowerBanks
                  : l10n.vehicleEditorDevices(
                      sel.length, Vehicle.maxDevicesPerCar)),
              IndustrialCard(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
                child: candidates.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(l10n.vehicleEditorNoDevices,
                            style: TextStyle(fontSize: 12, color: c.muted)),
                      )
                    : Column(
                        children: [
                          for (var i = 0; i < candidates.length; i++)
                            Builder(builder: (context) {
                              final d = candidates[i];
                              final on = sel.contains(d.id);
                              return VehicleCheckRow(
                                key: ValueKey('vehicle-device-${d.id}'),
                                value: on,
                                label: d.alias.isEmpty
                                    ? l10n.devicesUnnamed
                                    : d.alias,
                                note: personal ? '' : alsoIn(d.id),
                                last: i == candidates.length - 1,
                                onChanged: (!on && full)
                                    ? null
                                    : (x) => _toggle(d.id, x),
                              );
                            }),
                        ],
                      ),
              ),
              if (!personal)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                  child: Text(l10n.vehicleEditorPowerBankNote,
                      style: TextStyle(
                          fontSize: 10.5, height: 1.5, color: c.muted)),
                ),
              if (v != null) ...[
                const SizedBox(height: 12),
                VehicleOutlineButton(
                  key: const ValueKey('vehicle-edit-layout'),
                  icon: Icons.dashboard_customize_outlined,
                  label: l10n.vehicleEditorEditLayout,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => HomeEditorPage(vehicleId: v.id)),
                  ),
                ),
              ],
              if (v != null && v.isCar)
                VehicleOutlineButton(
                  key: const ValueKey('vehicle-delete'),
                  icon: Icons.delete_outline,
                  label: l10n.vehicleEditorDelete,
                  danger: true,
                  onTap: _delete,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The name box (mock `.fld`): a panel-coloured field with its small label
/// inside the frame, the same block shape as a settings card's rows.
class _NameField extends StatelessWidget {
  const _NameField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 9, 13, 4),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.vehicleEditorName,
              style: TextStyle(fontSize: 10.5, color: c.muted)),
          TextField(
            key: const ValueKey('vehicle-name'),
            controller: controller,
            maxLength: 24,
            style: TextStyle(fontSize: 14, color: c.text),
            decoration: InputDecoration(
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              counterText: '',
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
              hintText: l10n.vehicleEditorNameHint,
              hintStyle: TextStyle(fontSize: 14, color: c.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// One tickable unit (mock `.ck`): an accent square check, the unit's name,
/// and — right-aligned, muted — the other car it is already in.
///
/// [onChanged] null ⇒ the row is drawn faded and ignores taps (a car already
/// holding three units, Q6).
class VehicleCheckRow extends StatelessWidget {
  const VehicleCheckRow({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
    this.note = '',
    this.last = false,
  });

  final bool value;
  final String label;
  final String note;
  final bool last;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accent = context.accent;
    final enabled = onChanged != null;
    return Semantics(
      checked: value,
      enabled: enabled,
      label: label,
      child: InkWell(
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            constraints: const BoxConstraints(minHeight: 46),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
            decoration: BoxDecoration(
              border: last ? null : Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: value ? accent.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    border: Border.all(
                        color: value ? accent.accent : c.line2, width: 1.5),
                  ),
                  child: value
                      ? Icon(Icons.check, size: 14, color: accent.onAccent)
                      : null,
                ),
                const SizedBox(width: 10),
                // Loose on both sides + spaceBetween: the other car's name sits
                // at the right edge (mock ⑥) without taking half the row.
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13.5, color: c.text),
                        ),
                      ),
                      if (note.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                            style: TextStyle(fontSize: 11, color: c.muted),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
