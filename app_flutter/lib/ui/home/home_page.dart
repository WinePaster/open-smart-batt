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
  const HomePage(
      {super.key, this.onOpenDevices, this.onOpenDetail, this.onEdit});

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
    final layout = (HomeLayout.decode(settings.homeLayout) ??
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
            for (final row in layout.rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                // 🔴 A row of one fills the row, WHATEVER its span.
                //
                // `rows` pairs two ADJACENT halves; a half whose neighbour is
                // full, or whose partner was filtered out by `renderedFor`,
                // arrives here alone. Ruled 2026-08-07, from rendered
                // comparisons rather than description: a lone 1x1 keeping its
                // half left a ragged empty column that reads as broken rather
                // than deliberate — and it is the COMMON case, not an edge
                // one, because `speed_detection` defaults off and so the G
                // meter is orphaned on almost every phone.
                //
                // The cost is named rather than hidden: on this page you
                // cannot see that a tile is 1x1 when it is alone. That is
                // half of what「按了沒反應」was. The other half — the editor
                // drawing every preview full width — is fixed, so the shape
                // button still has visible feedback where it is pressed.
                child: row.length == 1
                    ? HomeTileView(
                        tile: row.single,
                        onOpenDevices: onOpenDevices,
                        onOpenDetail: onOpenDetail,
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final t in row)
                            Expanded(
                              child: HomeTileView(
                                tile: t,
                                onOpenDevices: onOpenDevices,
                                onOpenDetail: onOpenDetail,
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
                      color: colors.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
