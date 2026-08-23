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
    // `renderedFor` is the home surface's own resolver — the twin of
    // `renderedModules`, not a user of it (ruled 2026-08-07: the two surfaces
    // stay separate). It drops ghosts and phone modules whose switch is off,
    // and it does both WITHOUT rewriting storage. See its doc.
    final layout =
        (HomeLayout.decode(settings.homeLayout) ??
                HomeLayout.defaultFor(devices.devices))
            .renderedFor(
              devices.devices,
              settings.settings,
              gForceAvailable: context.watch<GForceController>().available,
            );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(15, 10, 15, 14),
          children: [
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
            for (final block in HomeLayout.blocksOf(layout.tiles))
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: block.full != null
                    ? HomeTileView(
                        tile: layout.tiles[block.full!],
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
                                        tile: layout.tiles[i],
                                        onOpenDevices: onOpenDevices,
                                        onOpenDetail: onOpenDetail,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            if (onEdit != null) _EditLayoutRow(onTap: onEdit!),
          ],
        ),
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
