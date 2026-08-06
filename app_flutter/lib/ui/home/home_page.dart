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
/// only ever name a [DisplayModule]. See `models/home_layout.dart`.
///
/// Step 2 places the tab; the grid itself arrives in Step 8.
library;

import 'package:flutter/material.dart';

/// The home tab's body (sits inside the app shell's [Scaffold]).
class HomePage extends StatelessWidget {
  const HomePage({super.key, this.onOpenDevices});

  /// Switch to the devices tab. The empty-state card and, later, the device
  /// tiles route through here rather than pushing anything of their own: the
  /// shell owns tab state through a single entry point (`main.dart`'s
  /// `_setTab`), and a second writer is what let the GNSS gate stay open behind
  /// the Settings page once already.
  final VoidCallback? onOpenDevices;

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
