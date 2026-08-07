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

import '../../models/models.dart';
import '../../state/state.dart';
import 'home_tiles.dart';

/// The home tab's body (sits inside the app shell's [Scaffold]).
class HomePage extends StatelessWidget {
  const HomePage({super.key, this.onOpenDevices, this.onOpenDetail});

  /// Switch to the devices tab. Routed through the shell rather than pushed
  /// here: the shell owns tab state through a single entry point (`main.dart`'s
  /// `_setTab`), and a second writer is what let the GNSS gate stay open behind
  /// the Settings page once already.
  final VoidCallback? onOpenDevices;

  /// Open one unit's page.
  final void Function(String deviceId)? onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final devices = context.watch<DeviceController>();
    // `visibleFor` drops tiles whose device is gone WITHOUT rewriting storage —
    // see its doc. A deleted unit must not leave an unremovable empty card, and
    // a unit that comes back must find its card where the user left it.
    final layout = (HomeLayout.decode(settings.homeLayout) ??
            HomeLayout.defaultFor(devices.devices))
        .visibleFor(devices.devices);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(15, 10, 15, 14),
          children: [
            for (final row in layout.rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
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
          ],
        ),
      ),
    );
  }
}
