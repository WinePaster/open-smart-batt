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

import '../../data/ack_marker.dart';
import '../../demo/demo.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../widgets/dashed_border.dart';
import 'vehicle_editor_page.dart';
import 'vehicles_page.dart';

/// The vehicles, when vehicle mode is visible (see the library comment); null
/// otherwise. Subscribes to the switch and to the vehicle list.
///
/// Watches the multi-link controller through `select` on its ON flag only: the
/// controller notifies on every link event, and a home grid rebuilt at sample
/// rate would be the price of a one-bit question.
VehicleController? visibleVehicles(BuildContext context) {
  // design 0107: ACTIVE, not the stored switch — simple mode withholds
  // vehicles together with multi-link.
  final on = context.select<MultiLinkController?, bool>(
      (m) => m?.active ?? false);
  final vc = context.watch<VehicleController?>();
  if (!on || vc == null || !vc.hasCars) return null;
  return vc;
}

/// [visibleVehicles] for handlers (no subscription).
VehicleController? readVisibleVehicles(BuildContext context) {
  final ml = context.read<MultiLinkController?>();
  final vc = context.read<VehicleController?>();
  if (ml == null || !ml.active || vc == null || !vc.hasCars) return null;
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

/// The home title in vehicle mode (mock ①): 「A 車 ▾」 at the size of a page
/// title, a 離線 tag when none of its devices is nearby (Q3), and the offline
/// banner under it.
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
    // Left-aligned like a page title (mock ①), inside the same 560 column the
    // grid under it uses — `Center` alone would shrink-wrap and centre it.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(15, 8, 15, 0),
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
                    // 40 px tall target (FB-70) around a 15 px title.
                    padding: const EdgeInsets.fromLTRB(0, 10, 8, 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: c.text,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.expand_more,
                            size: 18, color: context.accent.accent),
                        if (offline) ...[
                          const SizedBox(width: 6),
                          Text(
                            l10n.vehicleOffline,
                            maxLines: 1,
                            style: TextStyle(fontSize: 11, color: c.muted),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (offline && cur.isCar)
                VehicleNoticeBanner(
                  key: const ValueKey('vehicle-offline-banner'),
                  text: l10n.vehicleOfflineBanner(name),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The mock's dashed notice box (`.banner`): panel2 fill, dashed line2 frame,
/// small muted text. For a state the user should know about but need not act
/// on — a warning colour would overstate it.
class VehicleNoticeBanner extends StatelessWidget {
  const VehicleNoticeBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: CustomPaint(
        foregroundPainter:
            DashedBorderPainter(color: c.line2, radius: AppTheme.radiusMd),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: c.panel2,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          child: Text(
            text,
            style: TextStyle(fontSize: 11.5, color: c.muted, height: 1.45),
          ),
        ),
      ),
    );
  }
}

/// One-time hint that vehicles exist, at the top of the Saved devices list
/// (owner, 2026-11-15: existing users had no way to learn about the feature —
/// it sits behind an experimental switch that defaults off).
///
/// Not on the home page: that page carries no explanatory text (design 0046
/// R11, 0053). Shown only while all of these hold, so it reaches the users the
/// feature is for and nobody else:
///  * the build carries the multi-device switch (a [VehicleController] and a
///    [MultiLinkController] are provided);
///  * no car exists yet;
///  * at least two saved units that could go in a car (power banks, demo and
///    unknown units do not count — [vehicleCandidates]);
///  * the user has not tapped it or closed it ([vehicleHintMarker]).
///
/// Tapping the action also counts as seen: with the switch off it goes to
/// Settings (the user still has to turn the switch on themselves — the hint
/// never flips an experimental switch on their behalf); with it on, straight
/// to the vehicle list.
class VehicleDiscoveryHint extends StatefulWidget {
  const VehicleDiscoveryHint({super.key, this.onOpenSettings});

  /// Show the Settings tab (the shell's entry point, as [DevicesPage] has it).
  /// Null ⇒ with the switch off there is no action, only the close button.
  final VoidCallback? onOpenSettings;

  @override
  State<VehicleDiscoveryHint> createState() => _VehicleDiscoveryHintState();
}

/// `<feature>_ack_v<N>`; bump the version to show a rewritten hint again.
const AckMarker vehicleHintMarker = AckMarker('vehicle_hint_ack_v1');

class _VehicleDiscoveryHintState extends State<VehicleDiscoveryHint> {
  /// Null until the marker has been read: never flash the hint for a frame to
  /// a user who already closed it.
  bool? _seen;

  @override
  void initState() {
    super.initState();
    unawaited(vehicleHintMarker.acknowledged().then((v) {
      if (mounted) setState(() => _seen = v);
    }));
  }

  void _dismiss() {
    setState(() => _seen = true);
    unawaited(vehicleHintMarker.markAcknowledged());
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.watch<VehicleController?>();
    final on = context.select<MultiLinkController?, bool?>((m) => m?.enabled);
    // design 0107: no vehicle hint in simple mode — vehicles are held off
    // there, and its buttons lead to a switch the user cannot flip.
    final simple = context.select<SettingsController, bool>(
        (s) => s.mode == AppMode.advanced);
    final devices = context.watch<DeviceController>();
    if (_seen != false ||
        vc == null ||
        on == null ||
        vc.hasCars ||
        simple) {
      return const SizedBox.shrink();
    }
    if (vehicleCandidates(devices.devices, VehicleKind.car).length < 2) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final VoidCallback? go = on
        ? () {
            _dismiss();
            unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const VehiclesPage())));
          }
        : widget.onOpenSettings == null
            ? null
            : () {
                _dismiss();
                widget.onOpenSettings!();
              };
    return Container(
      key: const ValueKey('vehicle-hint'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: c.panel2,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: c.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.directions_car_outlined,
                size: 18, color: context.accent.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.vehicleHintTitle,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.text)),
                const SizedBox(height: 3),
                Text(on ? l10n.vehicleHintBodyOn : l10n.vehicleHintBodyOff,
                    style: TextStyle(
                        fontSize: 11.5, height: 1.45, color: c.muted)),
                if (go != null)
                  InkWell(
                    key: const ValueKey('vehicle-hint-go'),
                    onTap: go,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 2),
                      child: Text(
                        '${on ? l10n.vehicleHintSetUp : l10n.vehicleHintOpenSettings} →',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: context.accent.accentSecondary),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('vehicle-hint-close'),
            tooltip: l10n.vehicleHintDismiss,
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            color: c.muted,
            onPressed: _dismiss,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// A group label above a card (mock `.gh`): small, muted, slightly spaced.
class VehicleSectionLabel extends StatelessWidget {
  const VehicleSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: context.colors.muted,
        ),
      ),
    );
  }
}

/// A full-width outlined button (mock `.btn` / `.btn.dz`): accent frame and
/// text, or — [danger] — a quiet frame with red text, so a destructive action
/// is legible without shouting louder than the page's main one.
class VehicleOutlineButton extends StatelessWidget {
  const VehicleOutlineButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final off = onTap == null;
    final fg = off
        ? c.muted
        : (danger ? AppSemantics.danger : context.accent.accent);
    final frame = off || danger ? c.line2 : context.accent.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          child: Container(
            constraints: const BoxConstraints(minHeight: 42),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(color: frame),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: fg),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
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

/// The picker (mock ①b): cars with a nearby dot, 「個人裝置」 fixed last,
/// 「＋ 新增車輛（n／5）」 and 「管理車輛…」.
Future<void> showVehiclePicker(BuildContext context) async {
  final vc = readVisibleVehicles(context);
  if (vc == null) return;
  final nav = Navigator.of(context);
  final c = context.colors;
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: c.panel,
    shape: RoundedRectangleBorder(
      borderRadius:
          const BorderRadius.vertical(top: Radius.circular(AppTheme.radiusLg)),
      side: BorderSide(color: c.line2),
    ),
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

/// The member names of [v], joined the way every vehicle surface lists them.
String vehicleMemberNames(
    AppLocalizations l10n, DeviceController devices, Vehicle v) {
  final names = <String>[];
  for (final id in v.deviceIds) {
    final d = devices.deviceFor(id);
    if (d != null) names.add(d.alias.isEmpty ? l10n.devicesUnnamed : d.alias);
  }
  return names.join('、');
}

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

    Widget sep() => Divider(height: 9, thickness: 1, color: c.line);

    Widget option(Vehicle v) {
      final on = vehicles.current?.id == v.id;
      final near = vehicleNearby(v, ml, conn);
      final members = vehicleMemberNames(l10n, devices, v);
      final detail = [
        if (members.isNotEmpty) members,
        if (near) l10n.vehiclePickerNearby,
      ].join(' · ');
      return InkWell(
        key: ValueKey('vehicle-option-${v.id}'),
        onTap: () => Navigator.of(context).pop(v.id),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 46),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            // spaceBetween, both sides loose: the members sit at the right edge
            // (mock ①b) and the name keeps whatever it needs first.
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          vehicleDisplayName(l10n, v),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight:
                                on ? FontWeight.w700 : FontWeight.w400,
                            color: on ? context.accent.accent : c.text,
                          ),
                        ),
                      ),
                      if (near) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                              color: AppSemantics.good,
                              shape: BoxShape.circle),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 11.5, color: c.muted),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget action(
            {required Key key,
            required String label,
            IconData? icon,
            required VoidCallback? onTap}) {
      final fg = onTap == null ? c.muted : context.accent.accentSecondary;
      return
        InkWell(
          key: key,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
              child: Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: fg),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: fg),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
                      fontSize: 11.5,
                      letterSpacing: 0.5,
                      color: c.muted,
                      fontWeight: FontWeight.w600)),
            ),
            for (final v in cars) option(v),
            if (personal != null) ...[
              sep(),
              option(personal),
            ],
            sep(),
            action(
              key: const ValueKey('vehicle-option-add'),
              icon: Icons.add,
              label: l10n.vehiclePickerAdd(cars.length, Vehicle.maxCars),
              onTap: canAdd ? () => Navigator.of(context).pop(_addKey) : null,
            ),
            action(
              key: const ValueKey('vehicle-option-manage'),
              label: l10n.vehiclePickerManage,
              onTap: () => Navigator.of(context).pop(_manageKey),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
