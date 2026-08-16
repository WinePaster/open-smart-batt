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
import '../widgets/card_device_scope.dart';
import '../widgets/industrial_card.dart';
import '../util/relative_time.dart';
import 'home_preview.dart';

/// The heading a module is named by, on the home grid and in its editor.
///
/// Most reuse the heading their own card already carries (design 0046 §4.2
/// mitigation ①: the home editor and the watchface picker must not invent a
/// second name for one module). `speed` is the exception because its card has
/// no heading of its own; `clock` is the reverse of that exception — its card
/// reads its heading FROM here (`clock_card.dart`), so there is still exactly
/// one string.
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
      DisplayModule.clock => l10n.homeModuleClock,
    };

/// The name of a [CardShell] in the editor's appearance sheet (design 0054).
///
/// 🔴 A LABEL, never the stored value. The wire value is the enum name
/// (`card_shell.dart`) and is not localized — same rule as [DisplayModule].
/// Exhaustive, so a new shell is a compile error here rather than a blank chip.
String cardShellLabel(AppLocalizations l10n, CardShell s) => switch (s) {
      CardShell.standard => l10n.cardShellStandard,
      CardShell.minimal => l10n.cardShellMinimal,
      CardShell.dense => l10n.cardShellDense,
    };

/// The name of one of [m]'s own view slugs.
///
/// Takes the MODULE as well as the slug, because that is what a scoped name
/// space means: `numeric` on a gauge and a hypothetical `numeric` somewhere else
/// are different words that happen to be spelled alike, and this function is the
/// place that would otherwise pretend they are one.
String cardViewLabel(AppLocalizations l10n, DisplayModule m, String slug) {
  switch (m) {
    case DisplayModule.readouts:
      return switch (ReadoutsView.fromSlug(slug) ?? ReadoutsView.grid) {
        ReadoutsView.grid => l10n.cardViewReadoutsGrid,
        ReadoutsView.big => l10n.cardViewReadoutsBig,
      };
    case DisplayModule.gaugeVoltage:
    case DisplayModule.gaugeSoc:
      return switch (GaugeView.fromSlug(slug) ?? GaugeView.dial) {
        GaugeView.dial => l10n.cardViewGaugeDial,
        GaugeView.numeric => l10n.cardViewGaugeNumeric,
      };
    case DisplayModule.clock:
      return switch (ClockView.fromSlug(slug) ?? ClockView.digital) {
        ClockView.digital => l10n.cardViewClockDigital,
      };
    // Modules that declare no views (`cardViewSlugs`) never reach this — the
    // editor iterates that same list, so there is no slug to name. Returning the
    // slug is a visible marker if that ever stops being true, rather than a
    // crash or an empty chip.
    case DisplayModule.chart:
    case DisplayModule.cells:
    case DisplayModule.energyPath:
    case DisplayModule.speed:
    case DisplayModule.gForce:
      return slug;
  }
}

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
      DisplayModule.clock => Icons.schedule,
    };

/// One tile of the home grid.
class HomeTileView extends StatelessWidget {
  const HomeTileView({
    super.key,
    required this.tile,
    this.onOpenDevices,
    this.onOpenDetail,
    this.preview,
  });

  final HomeTile tile;

  /// Non-null ONLY in the layout editor (design 0051 §5). When it is set every
  /// tile below draws from it and nothing reads a controller — which is how the
  /// editor stops mounting live speed / G cards, and how it stops showing eight
  /// identical `--` boxes when nothing is connected.
  ///
  /// 🔴 It is a parameter rather than a `previewMode` flag on purpose. The
  /// failure mode of a flag is "forget to clear it and the real dashboard draws
  /// plausible fake voltages"; there is no equivalent here, because the real
  /// call sites (`home_page.dart`) simply do not pass one. See
  /// [CardTelemetry]'s library comment for the four times this codebase has
  /// been bitten by the other shape.
  final HomePreview? preview;

  /// Switch to the devices tab (the empty-state card's action).
  final VoidCallback? onOpenDevices;

  /// Open one unit's page (a device card's action).
  final void Function(String deviceId)? onOpenDetail;

  @override
  Widget build(BuildContext context) {
    switch (tile.kind) {
      case HomeTileKind.addDevice:
        return _shell(_AddDeviceTile(onTap: onOpenDevices));
      case HomeTileKind.deviceCard:
        return _shell(_DeviceTile(
          deviceId: tile.deviceId!,
          onTap: onOpenDetail,
          preview: preview,
        ));
      case HomeTileKind.module:
        return _shell(_ModuleTile(
          module: tile.module!,
          deviceId: tile.deviceId,
          view: tile.view,
          preview: preview,
        ));
      // 🔴 Nothing at all on the HOME page — the gap beside a lone 1x1 is the
      // point of it, and drawing a dotted box there would put a control-looking
      // thing on a page with no controls. The editor draws it visibly, because
      // there the slot IS a target. See [HomeTileKind.empty].
      case HomeTileKind.empty:
        return const SizedBox.shrink();
    }
  }

  /// 🔴 The ONLY place a [CardShell] is published (design 0054).
  ///
  /// It is a scope around each tile rather than a theme extension because the
  /// same [IndustrialCard] draws the settings screen, the history screen and the
  /// G-calibration wizard — 11 of its ~26 call sites — and choosing `minimal`
  /// for a home page must not unframe any of them. `card_style.dart` has the
  /// full argument.
  ///
  /// The WAITING tile is inside the scope too, deliberately: a card that looked
  /// like a different card when the unit went offline would make the layout
  /// unrecognisable exactly when the user is trying to work out what happened.
  /// Only `view` stops at that boundary — see [HomeWaitingTile].
  Widget _shell(Widget child) =>
      CardStyleScope(shell: tile.shell, child: child);
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
              Icon(Icons.add_circle_outline,
                  size: 36, color: context.accent.accent),
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
  const _DeviceTile({required this.deviceId, this.onTap, this.preview});

  final String deviceId;
  final void Function(String deviceId)? onTap;
  final HomePreview? preview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final p = preview;
    // 🔴 Every provider read below is inside the `p == null` branch. In the
    // editor this tile touches no controller at all — not for the alias, not
    // for the link state, not for the reading (design 0051 §5).
    final SavedDevice? saved;
    final bool live;
    if (p != null) {
      saved = p.device;
      live = p.live;
    } else {
      final devices = context.watch<DeviceController>();
      final conn = context.watch<ConnectionController>();
      saved = devices.deviceFor(deviceId);
      // 🔴 `isOnline && it is THIS unit`. Reading `isOnline` alone would draw
      // the connected device's telemetry under another unit's name — FB-41's
      // attribution mistake, in the UI.
      //
      // 📌 交付二 seam: this one expression becomes `conn.isOnlineFor(deviceId)`
      // when several links may be up at once (design 0046 §8 seam 1).
      live = conn.isOnline && conn.connectedDeviceId == deviceId;
    }
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
                      color: live ? context.accent.accent : context.colors.muted),
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
              _LiveReading(deviceId: deviceId, preview: preview)
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
              color: AppSemantics.good,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          const Text('LIVE',
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 1,
                fontWeight: FontWeight.w700,
                color: AppSemantics.good,
              )),
        ],
      );
}

/// The connected unit's reading. Its instrument follows the class, the same way
/// `watchfaces.dart` picks one: a power bank reads state of charge, everything
/// else reads the rail.
class _LiveReading extends StatelessWidget {
  const _LiveReading({required this.deviceId, this.preview});

  final String deviceId;
  final HomePreview? preview;

  @override
  Widget build(BuildContext context) {
    final p = preview;
    final CardTelemetry tele;
    final bool isBank;
    if (p != null) {
      tele = p.tele;
      isBank = p.shellClass == ProductClass.powerBank;
    } else {
      tele = context.watch<TelemetryController>();
      isBank = context.watch<ConnectionController>().displayClass ==
          ProductClass.powerBank;
    }
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

  /// 🔴 The number and its unit scale together, and never wrap.
  ///
  /// Found by design 0051's editor preview, which draws a real 13.87 V instead
  /// of `--`: at 32 px, four significant figures plus ` V` need ~180 px, and a
  /// half-width device tile on a 320 dp phone offers 107. Unfixed it is a
  /// RenderFlex overflow — the striped bar drawn across the one number the card
  /// exists to show. It was in the shipped build; nothing had ever rendered a
  /// live half-width device tile at that width.
  ///
  /// `scaleDown` rather than a smaller font, and `Expanded` around it rather
  /// than a bare `FittedBox`: at full width nothing scales at all, so the
  /// common case is byte-for-byte what it was. Same remedy, same reasoning and
  /// the same field-report lineage as `_GReadout` and `SpeedCard._Reading`.
  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    softWrap: false,
                    style: AppTextStyles.mono(context).copyWith(
                      // Shell-scaled (design 0054): `mono` carries no size, so
                      // this reading asks for the multiplier explicitly.
                      fontSize: context.cardValueSize(32),
                      fontWeight: FontWeight.w700,
                      height: 1,
                      color:
                          muted ? context.colors.muted : context.colors.text,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    unit,
                    maxLines: 1,
                    softWrap: false,
                    // The unit marker `clock_card.dart:244` points at by name.
                    // Fixed, not the accent — design 0064 Q2; same reasoning
                    // as the gauge's own unit in `pvlt_gauge.dart`.
                    style: TextStyle(
                      fontSize: 13,
                      color: muted ? context.colors.muted : AppSemantics.warn,
                    ),
                  ),
                ],
              ),
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
  const _ModuleTile(
      {required this.module, this.deviceId, this.view, this.preview});

  final DisplayModule module;

  /// Null for a module that reads no device at all (design 0042's `speed` reads
  /// the phone's own GNSS), in which case it is ALWAYS live.
  final String? deviceId;

  /// The stored content-variant slug, or null for this module's default.
  final String? view;

  final HomePreview? preview;

  @override
  Widget build(BuildContext context) {
    final p = preview;
    if (p != null) {
      // 🔴 PHONE MODULES NEVER REACH `dashboardCardFor` HERE.
      //
      // Not an optimisation — a leak fix. `dashboardCardFor(speed)` returns a
      // real `SpeedCard`, which calls `setFaceWantsSpeed(true)` from
      // `didChangeDependencies`; the editor is a pushed route while the shell's
      // tab is still `home`, so all three of design 0042's gate conditions were
      // open and the GNSS receiver ran for as long as somebody was arranging
      // their home page. `previewCardFor` draws the extracted bodies instead.
      //
      // Routed on `isPhoneModule`, an exhaustive switch, NOT on an
      // `== speed || == gForce` chain — see `display_module.dart` for why that
      // shape has failed here four times.
      if (module.isPhoneModule) return previewCardFor(module, p, view: view);
      // A device module with fake data. It can still return null — a class that
      // has no such card must not grow one in the editor either — and the
      // waiting tile is the honest rendering of that.
      return dashboardCardFor(context, module,
              shellClass: p.shellClass, tele: p.tele, view: view) ??
          HomeWaitingTile(module: module);
    }
    final conn = context.watch<ConnectionController>();
    final id = deviceId;
    // No phone-module gate here, deliberately: `HomeLayout.renderedFor` — the
    // home surface's single resolver — has already dropped any module whose
    // switch is off. A second check would be the duplicate decision point
    // design 0042 W4 removed, just on a different surface.
    final live =
        id == null || (conn.isOnline && conn.connectedDeviceId == id);
    final Widget card;
    if (!live) {
      card = HomeWaitingTile(module: module);
    } else {
      final shellClass = homeTileShellClass(id, conn);
      card = dashboardCardFor(context, module,
              shellClass: shellClass,
              tele: context.watch<TelemetryController>(),
              view: view) ??
          HomeWaitingTile(module: module);
    }

    // 🔴 The unit's name, published to the card's heading (owner ruling
    // 2026-08-15, from `2026.08.14-001.md` §1.3 建議 4 / R1: 「主頁的各裝置卡片…
    // 要不要改為 [裝置名]分串電壓 這樣的標題」).
    //
    // It is a SCOPE rather than an argument threaded through `dashboardCardFor`
    // — `card_device_scope.dart` carries the full reasoning, of which the part
    // that matters here is: the ruling was 「已經被擺放到主頁，而不是編輯卡片的
    // 時候」, and this is the only place a scope is placed, so the dashboard and
    // the editor preview are excluded by construction rather than by anyone
    // remembering to leave the argument out.
    //
    // 🔑 BELOW the `preview` early-return above, and that is load-bearing twice
    // over: the editor must not name a unit (the ruling), and it must not touch
    // a controller at all (design 0051 §5) — `aliasFor` is a `DeviceController`
    // read. One early return keeps both true.
    //
    // Placed around the WAITING tile too. An offline tile keeps the unit's name
    // for the same reason it keeps the shell: a card that changed shape when
    // its unit went offline would make the layout unrecognisable exactly when
    // the user is working out what happened.
    if (id == null) return card; // a phone module — there is no unit to name
    final l10n = AppLocalizations.of(context);
    return CardDeviceScope(
      // Empty aliases are a supported value (FB-61), so the fallback is the
      // same string the device list shows rather than a blank line.
      deviceLabel: context
          .watch<DeviceController>()
          .aliasFor(id, fallback: l10n.devicesUnnamed),
      child: card,
    );
  }
}

/// A module with nothing to draw: its name, and `--`.
///
/// PUBLIC only so a test can name it (design 0051 §6, test T-editor-2): the
/// editor's guarantee is "no tile in this screen is a waiting tile", and that
/// sentence needs a type to point at. It is not part of any other file's
/// vocabulary — nothing outside this file constructs one.
///
/// No sentence explaining why (design 0046 §4.7) — the device card says when
/// that unit was last seen, and tapping through is how you get a live one.
///
/// 🔴 COMPACT, on purpose. It used to be a full card: heading, then 28 px
/// `--` inside 10 px of vertical padding, then the card's own 15 px. A phone
/// that is not connected — which is how the app is opened most of the time —
/// therefore showed two tall white rectangles containing four characters
/// between them. Reported 2026-08-07 with a photo:「這樣的版面設計真的很醜」.
///
/// A card with nothing to say should take the room of something with nothing
/// to say. The heading still identifies it, so the layout is still legible as
/// the arrangement the user chose; it just stops shouting.
///
/// 🔴 **Takes no `view`, and never will** (design 0054 §2, last row). With no
/// data there is no content to vary, and a "big-number version of `--`" would
/// dress the honesty floor up as decoration. The SHELL still applies, because
/// otherwise one card would look like two different cards depending on whether
/// the unit happened to be connected.
///
/// That is also why design 0054's T-V2 is written as "either the renderings
/// differ OR both are waiting tiles, asserted" — on this path the second arm is
/// the correct answer, and a test that let it pass silently would be green
/// forever.
class HomeWaitingTile extends StatelessWidget {
  const HomeWaitingTile({super.key, required this.module});

  final DisplayModule module;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IndustrialCard(
      padding: const EdgeInsets.fromLTRB(15, 11, 15, 11),
      heading: homeModuleLabel(l10n, module),
      headingIcon: homeModuleIcon(module),
      child: Text(
        '--',
        style: AppTextStyles.mono(context).copyWith(
          fontSize: 18,
          height: 1,
          fontWeight: FontWeight.w700,
          color: context.colors.muted,
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
