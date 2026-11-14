/// OpenSmartBatt — the home tab (design 0046 P2).
///
/// The app's default entry point since design 0046 R3, which deliberately
/// overturns design 0034 G4 ("a user who never opens the setting sees no
/// change"): the first screen is no longer one device's dashboard but a grid of
/// widgets that has something to say whether or not anything is connected.
///
/// 🔴 The control card cannot appear here, and that needs no check. Design 0034
/// §6 enforces "controls are last, always, and never customisable" structurally
/// — there is no [DisplayModule] for the protection card — and this page's tiles
/// only ever name one. See `models/home_layout.dart`.
///
/// ## Where the layout comes from
///
/// `settings.home_layout`, or — when that is NULL or unreadable —
/// [HomeLayout.defaultFor] over the devices the user has RIGHT NOW. That
/// fallback is the feature, not the error path: a user who never opens the
/// editor still gets a sensible page, and one saved next week appears by itself
/// (design 0046 R5 / §4.6).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';

import '../../models/models.dart';
import '../../state/state.dart';
import '../util/wide_layout.dart';
import '../vehicles/vehicle_ui.dart';
import '../widgets/flow_columns.dart';
import 'home_plan.dart';
import 'home_tiles.dart';

/// The home tab's body (sits inside the app shell's [Scaffold]).
class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    this.onOpenDevices,
    this.onOpenDetail,
    this.onEdit,
  });

  /// Switch to the devices tab. Routed through the shell rather than pushed
  /// here: the shell owns tab state through a single entry point (`main.dart`'s
  /// `_setTab`), and a second writer is what let the GNSS gate stay open behind
  /// the Settings page once already.
  final VoidCallback? onOpenDevices;

  /// Open one unit's page.
  final void Function(String deviceId)? onOpenDetail;

  /// Open the layout editor.
  ///
  /// 🔴 A row at the bottom of the grid, not only the app-bar action.
  ///
  /// The editor shipped as an 18 px grey `Icons.tune` beside the connection
  /// pill, and the first field test reported the feature as missing
  /// (2026-08-07: 「主頁不是會有個主頁編輯的功能嗎…沒有這個功能呢」). It was
  /// there the whole time. A control nobody finds is a control that does not
  /// exist, and the honest fix is to put it where the thing it edits ends
  /// rather than to make the icon louder.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final devices = context.watch<DeviceController>();
    // design 0106 Phase 4: in vehicle mode (switch on AND a car exists) the
    // page is the CURRENT vehicle's — its own layout over its member units,
    // under a 「A 車 ▾」 title. Otherwise [vehicles] is null and everything
    // below is exactly the pre-0106 page (mock ⑦ / ⑧).
    final vehicles = visibleVehicles(context);
    final current = vehicles?.current;
    final pool = current == null
        ? devices.devices
        : [for (final d in devices.devices) if (current.contains(d.id)) d];
    final stored = current == null
        ? HomeLayout.decode(settings.homeLayout)
        : current.homeLayout;
    // `renderedFor` is the home surface's own resolver — the twin of
    // `renderedModules`, not a user of it (ruled 2026-08-07: the two surfaces
    // stay separate). It drops ghosts and phone modules whose switch is off,
    // and it does both WITHOUT rewriting storage. See its doc.
    final layout =
        (stored ?? HomeLayout.defaultFor(pool))
            .renderedFor(
              pool,
              settings.settings,
              gForceAvailable: context.watch<GForceController>().available,
            );
    final header =
        vehicles == null ? null : VehicleHeader(vehicles: vehicles);

    final editRow = onEdit != null ? _EditLayoutRow(onTap: onEdit!) : null;
    final largeText = WideLayout.largeText(context);

    // design 0105 P3 (Q4 = A): a landscape window lays the SAME sections, in
    // the same order, into 2–3 columns. 🔵 design 0106 §6.4 (Q-S1): so does a
    // PORTRAIT window wide enough for two columns (a tablet) — a phone in
    // portrait is far narrower than that and keeps the single column exactly.
    final size = MediaQuery.sizeOf(context);
    final multi = WideLayout.isLandscape(size) || WideLayout.wideEnough(size);

    Widget planned(int columns, double content) => HomePlanned(
          tiles: layout.tiles,
          widths: HomePlanWidths.forContent(content),
          builder: (context, placed) {
            final sections = [
              for (final block in HomeLayout.blocksOf(placed))
                _section(block, placed),
            ];
            final body = columns == 1
                ? _singleColumn(sections, editRow)
                : _multiColumn(sections, editRow, columns);
            if (header == null) return body;
            return Column(
              children: [header, Expanded(child: body)],
            );
          },
        );

    // A phone in portrait never reaches the LayoutBuilder (design 0105's
    // "portrait is today"): it fills the window, so the window IS its width.
    if (!multi) {
      return planned(1, size.width.clamp(0.0, 560.0) - 2 * _hPad);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final avail = constraints.maxWidth - 2 * _hPad;
        final columns = WideLayout.columnsFor(avail, largeText: largeText);
        // The width a full-width card is drawn at — what the plan heights of
        // design 0106 §6.3 are measured against.
        final content = columns == 1
            ? (constraints.maxWidth.clamp(0.0, 560.0) - 2 * _hPad)
            : (avail.clamp(0.0, WideLayout.maxWidthFor(columns)) -
                    (columns - 1) * WideLayout.columnGap) /
                columns;
        return planned(columns, content);
      },
    );
  }

  /// Side padding of the grid, both layouts.
  static const double _hPad = 15;

  /// Today's page: one column, at most 560 wide, centred. Every portrait
  /// window, and a landscape one too narrow for two columns.
  Widget _singleColumn(List<Widget> sections, Widget? editRow) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(_hPad, 10, _hPad, 14),
          children: [
            ...sections,
            ?editRow,
          ],
        ),
      ),
    );
  }

  /// design 0105 P3: [columns] columns, each at most
  /// [WideLayout.columnMaxWidth], filled IN ORDER by [FlowColumns]. The
  /// "edit layout" row stays the last thing on the page, under the columns,
  /// at the single-column width.
  Widget _multiColumn(List<Widget> sections, Widget? editRow, int columns) {
    return ListView(
      key: const ValueKey('home-multi-column'),
      padding: const EdgeInsets.fromLTRB(_hPad, 10, _hPad, 14),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: WideLayout.maxWidthFor(columns),
            ),
            child: FlowColumns(
              columns: columns,
              gap: WideLayout.columnGap,
              children: sections,
            ),
          ),
        ),
        if (editRow != null)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: WideLayout.columnMaxWidth,
              ),
              child: editRow,
            ),
          ),
      ],
    );
  }

  /// One [HomeBlock] as a widget — identical in every layout. Design 0105
  /// moves whole sections between columns and never opens one up, so design
  /// 0084's rules below hold inside each landscape column unchanged.
  Widget _section(HomeBlock block, List<HomeTile> tiles) {
    // 🔴 COLUMNS, NOT ROWS, since design 0084 S2 — and the difference
    // is the whole feature. A row makes both sides advance together,
    // so the card under a short one starts where the TALLEST card of
    // that row ends; measured on a 390 pt phone that hole is 135–190
    // px. A column starts it where the short card itself ends.
    //
    // 🔴 1x1 STILL MEANS 1x1, and this does not touch that ruling.
    //
    // It was ruled twice. On 2026-08-07 a lone half was promoted to
    // fill its row, because the default layout was orphaning the G
    // meter (`speed_detection` defaults off, so its partner was
    // filtered away) and a ragged empty column read as broken.
    // Reported the next day from TestFlight: setting one tile to 1x1
    // and its neighbour to 1x2 drew BOTH full width — the same control
    // failing to work, from the other direction. The second ruling
    // stands: an orphan made by FILTERING is not a layout the user
    // asked for (and `_phoneTiles` is full-span now, so the default has
    // no pair to lose), while an orphan the user MADE is drawn as
    // asked.
    //
    // 🔑 In this model a lone 1x1 is simply a block whose other column
    // is empty. The tile keeps its half width because the column keeps
    // its half of the row — nothing has to remember to leave a gap
    // beside it, which is what the old `Expanded(SizedBox.shrink())`
    // was for. Same picture, one fewer thing to get wrong.
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: block.full != null
          ? HomeTileView(
              tile: tiles[block.full!],
              onOpenDevices: onOpenDevices,
              onOpenDetail: onOpenDetail,
            )
          : Row(
              // The two columns are independent, and their bottoms
              // are ALLOWED to disagree — owner ruled 2026-08-23
              // 「可以不等長」. `start` is what permits that; any
              // stretch here would quietly re-impose the row.
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (c, column) in [
                  block.left,
                  block.right,
                ].indexed)
                  Expanded(
                    // 🔑 HALF the gap on each column's INNER edge,
                    // never the whole gap on one of them. `Expanded`
                    // splits the row evenly and padding comes out of
                    // the child, so all 6 px on the right column
                    // would leave it 6 px NARROWER than the left —
                    // two "equal" halves that are not (caught by
                    // `home_column_layout_test.dart` T-0084-1b).
                    //
                    // The outer edges stay unpadded, so the block
                    // still starts and ends flush with the
                    // full-width cards above and below it. See
                    // [kHomeColumnGap] for why the editor and this
                    // page share the value.
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: c == 0 ? 0 : kHomeColumnGap / 2,
                        right: c == 0 ? kHomeColumnGap / 2 : 0,
                      ),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final i in column)
                            HomeTileView(
                              tile: tiles[i],
                              onOpenDevices: onOpenDevices,
                              onOpenDetail: onOpenDetail,
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// "Edit layout" — the last thing in the grid, after the cards it edits.
class _EditLayoutRow extends StatelessWidget {
  const _EditLayoutRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.tune, size: 15, color: colors.muted),
                const SizedBox(width: 8),
                Text(
                  AppLocalizations.of(context).homeEditLayout,
                  style: TextStyle(
                    fontSize: 12.5,
                    letterSpacing: 0.4,
                    color: colors.muted,
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
