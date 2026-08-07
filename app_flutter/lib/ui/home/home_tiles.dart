/// OpenSmartBatt — one home tile, drawn (design 0046 P2).
///
/// ## The data-honesty floor, which is the whole of this file's difficulty
///
/// A [SavedDevice] stores exactly TWO numeric facts about a unit that is not
/// connected: `lastValue` and `lastSeen` (`saved_device.dart`). There is no
/// cached current, no cached temperature, no cached per-cell voltage — the
/// advertisement carries none of it (`ble_service.dart` reads only advName /
/// rssi / serviceUuids). So:
///
///  * an OFFLINE device card may show `lastValue`, and MUST show its age
///    beside it (T-new-3). Showing a stored number as if it were live is FB-43
///    in general form — a power bank's single-cell 3.79 V presented as a pack's
///    main voltage — and the timestamp is what makes it a fact rather than a
///    claim. It is rendered as an ordinary line, NOT as a warning: it is not an
///    error that a device you are not watching is not being watched.
///  * an OFFLINE module tile shows the WAITING state (`--`). 🔴 It must not be
///    filled from `lastValue`: there is nothing stored for a temperature or a
///    cell voltage to be filled FROM, and a gauge that showed the last known
///    pack voltage without an age would be the same defect one card along.
///  * a module tile bound to a unit that is not the connected one likewise
///    shows `--` rather than the connected unit's telemetry. That is FB-41's
///    attribution mistake moved into the UI.
///
/// ## No control card here, and no check for it either
///
/// Design 0034 §6 / design 0046 R4: there is no [DisplayModule] for the
/// protection card, so [HomeTile] cannot name one. This file therefore contains
/// no guard against controls — the type already refused.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../dashboard/dashboard_cards.dart';
import '../widgets/industrial_card.dart';
import '../util/relative_time.dart';

/// The heading a module is named by, on the home grid and in its editor.
///
/// Most reuse the heading their own card already carries (design 0046 §4.2
/// mitigation ①: the home editor and the watchface picker must not invent a
/// second name for one module). `speed` and `gForce` are the exceptions because
/// their cards have no heading of their own.
///
/// `gForce` is present for completeness — the enum is exhaustive here — but the
/// home editor does not offer it, so this entry is only reachable if a future
/// change starts offering it.
String homeModuleLabel(AppLocalizations l10n, DisplayModule m) => switch (m) {
      DisplayModule.gaugeVoltage => l10n.gaugePvltLabel,
      DisplayModule.gaugeSoc => l10n.powerBankSocReadoutLabel,
      DisplayModule.readouts => l10n.dashboardReadoutsHeading,
      DisplayModule.chart => l10n.dashboardChartHeading,
      DisplayModule.cells => l10n.dashboardDvolHeading,
      DisplayModule.energyPath => l10n.powerPathHeading,
      DisplayModule.speed => l10n.homeModuleSpeed,
      DisplayModule.gForce => l10n.gForceCardHeading,
    };

/// The glyph a module is drawn with, matching its own card's heading icon.
IconData homeModuleIcon(DisplayModule m) => switch (m) {
      DisplayModule.gaugeVoltage => Icons.bolt,
      DisplayModule.gaugeSoc => Icons.battery_std,
      DisplayModule.readouts => Icons.speed,
      DisplayModule.chart => Icons.show_chart,
      DisplayModule.cells => Icons.battery_std,
      DisplayModule.energyPath => Icons.bolt,
      DisplayModule.speed => Icons.navigation_outlined,
      DisplayModule.gForce => Icons.adjust,
    };

/// One tile of the home grid.
class HomeTileView extends StatelessWidget {
  const HomeTileView({
    super.key,
    required this.tile,
    this.onOpenDevices,
    this.onOpenDetail,
  });

  final HomeTile tile;

  /// Switch to the devices tab (the empty-state card's action).
  final VoidCallback? onOpenDevices;

  /// Open one unit's page (a device card's action).
  final void Function(String deviceId)? onOpenDetail;

  @override
  Widget build(BuildContext context) {
    switch (tile.kind) {
      case HomeTileKind.addDevice:
        return _AddDeviceTile(onTap: onOpenDevices);
      case HomeTileKind.deviceCard:
        return _DeviceTile(
          deviceId: tile.deviceId!,
          onTap: onOpenDetail,
        );
      case HomeTileKind.module:
        return _ModuleTile(module: tile.module!, deviceId: tile.deviceId);
    }
  }
}

/// The zero-device empty state. One card, one action, no explanation — the
/// state is expressed by what the button does (design 0046 §4.7).
class _AddDeviceTile extends StatelessWidget {
  const _AddDeviceTile({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 26),
          child: Column(
            children: [
              const Icon(Icons.add_circle_outline,
                  size: 36, color: AppColors.amber),
              const SizedBox(height: 12),
              Text(
                l10n.homeAddFirstDevice,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: context.colors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One unit's summary: live values, or the last one WITH its age.
class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.deviceId, this.onTap});

  final String deviceId;
  final void Function(String deviceId)? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final devices = context.watch<DeviceController>();
    final conn = context.watch<ConnectionController>();
    final saved = devices.deviceFor(deviceId);
    // 🔴 `isOnline && it is THIS unit`. Reading `isOnline` alone would draw the
    // connected device's telemetry under another unit's name — FB-41's
    // attribution mistake, in the UI.
    //
    // 📌 交付二 seam: this one expression becomes `conn.isOnlineFor(deviceId)`
    // when several links may be up at once (design 0046 §8 seam 1).
    final live = conn.isOnline && conn.connectedDeviceId == deviceId;
    final alias = (saved?.alias.isNotEmpty ?? false)
        ? saved!.alias
        : l10n.devicesUnnamed;

    return IndustrialCard(
      child: InkWell(
        onTap: onTap == null ? null : () => onTap!(deviceId),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: context.colors.bg,
                    border: Border.all(color: context.colors.line),
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                  child: Icon(Icons.battery_full,
                      size: 17,
                      color: live ? AppColors.amber : context.colors.muted),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    alias,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: live ? context.colors.text : context.colors.muted,
                    ),
                  ),
                ),
                // The ONLY marking a live card carries (design 0046 §4.6). The
                // offline one carries none — its timestamp says everything the
                // badge would.
                if (live) const _LiveDot(),
              ],
            ),
            const SizedBox(height: 11),
            if (live)
              _LiveReading(deviceId: deviceId)
            else
              _CachedReading(device: saved),
          ],
        ),
      ),
    );
  }
}

class _LiveDot extends StatelessWidget {
  const _LiveDot();

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(
              color: AppColors.good,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          const Text('LIVE',
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 1,
                fontWeight: FontWeight.w700,
                color: AppColors.good,
              )),
        ],
      );
}

/// The connected unit's reading. Its instrument follows the class, the same way
/// `watchfaces.dart` picks one: a power bank reads state of charge, everything
/// else reads the rail.
class _LiveReading extends StatelessWidget {
  const _LiveReading({required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final tele = context.watch<TelemetryController>();
    final conn = context.watch<ConnectionController>();
    final isBank = conn.displayClass == ProductClass.powerBank;
    final value = isBank
        ? (tele.socPercent == null ? '--' : tele.socPercent.toString())
        : (tele.pvlt == null ? '--' : tele.pvlt!.toStringAsFixed(2));
    return _BigValue(value: value, unit: isBank ? '%' : 'V', muted: false);
  }
}

/// The last reading, and HOW OLD IT IS — never one without the other.
///
/// 🔴 T-new-3. With no `lastSeen` there is no age to state, so the number is
/// withheld entirely rather than shown undated. That is the stricter of the two
/// honest options and the only one that cannot be misread.
class _CachedReading extends StatelessWidget {
  const _CachedReading({required this.device});

  final SavedDevice? device;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final d = device;
    final hasDatedValue = d?.lastValue != null && d?.lastSeen != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BigValue(
          value: hasDatedValue ? d!.lastValue!.toStringAsFixed(2) : '--',
          unit: 'V',
          muted: true,
        ),
        const SizedBox(height: 8),
        Text(
          relativeTime(l10n, d?.lastSeen),
          style: AppTextStyles.mono(context).copyWith(
            fontSize: 11,
            color: context.colors.muted,
          ),
        ),
      ],
    );
  }
}

class _BigValue extends StatelessWidget {
  const _BigValue({
    required this.value,
    required this.unit,
    required this.muted,
  });

  final String value;
  final String unit;
  final bool muted;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            value,
            style: AppTextStyles.mono(context).copyWith(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              height: 1,
              color: muted ? context.colors.muted : context.colors.text,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            unit,
            style: TextStyle(
              fontSize: 13,
              color: muted ? context.colors.muted : AppColors.amber,
            ),
          ),
        ],
      );
}

/// A [DisplayModule] on the home grid.
///
/// Live, it is the dashboard's own card — literally the same function
/// (`dashboardCardFor`), so the home page and the device page cannot render one
/// module two ways. Otherwise it is the waiting state, and that is a hard rule
/// rather than a fallback: see the library comment.
class _ModuleTile extends StatelessWidget {
  const _ModuleTile({required this.module, this.deviceId});

  final DisplayModule module;

  /// Null for a module that reads no device at all (design 0042's `speed` reads
  /// the phone's own GNSS), in which case it is ALWAYS live.
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final id = deviceId;
    // No phone-module gate here, deliberately: `HomeLayout.renderedFor` — the
    // home surface's single resolver — has already dropped any module whose
    // switch is off. A second check would be the duplicate decision point
    // design 0042 W4 removed, just on a different surface.
    final live =
        id == null || (conn.isOnline && conn.connectedDeviceId == id);
    if (!live) return _WaitingTile(module: module);
    final shellClass = homeTileShellClass(id, conn);
    return dashboardCardFor(context, module, shellClass: shellClass) ??
        _WaitingTile(module: module);
  }
}

/// A module with nothing to draw: its name, and `--`.
///
/// No sentence explaining why (design 0046 §4.7) — the device card above it
/// already says when that unit was last seen, and tapping through is how you
/// get a live one.
class _WaitingTile extends StatelessWidget {
  const _WaitingTile({required this.module});

  final DisplayModule module;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      heading: homeModuleLabel(l10n, module),
      headingIcon: homeModuleIcon(module),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          '--',
          style: AppTextStyles.mono(context).copyWith(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: context.colors.muted,
          ),
        ),
      ),
    );
  }
}

/// Which class's card set a home module tile draws with.
///
/// 🔴 `displayClass`, NOT `packShellClass(displayClass)`. The two look
/// interchangeable and are not.
///
/// [DisplayModules.packShellClass] exists for the PACK SHELL, which is handed
/// the raw cosmetic label and has to fold a stray `powerBank` LABEL into the
/// unclassified set (`pack_view.dart:110`). [ConnectionController.displayClass]
/// has already answered that question — it reports what will actually be drawn.
/// Applying the quirk a second time maps a REAL power bank (`isPowerBank`, so
/// `displayClass` == `powerBank`) to `unknown`.
///
/// That shipped, briefly, and the symptom was a home page of `--`: `gaugeSoc`
/// and `energyPath` do not exist for `unknown`, so `dashboardCardFor` returned
/// null for both and `readouts` drew a pack's voltage grid. It hit the DEFAULT
/// layout head-on — [HomeLayout.defaultFor] gives a single power bank exactly
/// `[gaugeSoc, readouts]` — so the first thing a power-bank owner would have
/// seen on the new home tab was two empty cards.
///
/// It is a named function rather than two lines inside `build` because that is
/// what makes the decision reachable from a test. The 1052-test suite was green
/// throughout: `home_layout_test` only covers the model, and `home_tiles_test`
/// had never pumped a live power bank. Same shape as the 0042 defect where the
/// Android sampling period sat at 5 s past 940 green tests — the input to the
/// decision had no test looking at it.
@visibleForTesting
ProductClass homeTileShellClass(String? deviceId, ConnectionController conn) =>
    deviceId == null ? ProductClass.unknown : conn.displayClass;
