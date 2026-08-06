/// OpenSmartBatt — the devices tab (design 0046 P1).
///
/// The device list was a modal bottom sheet until design 0046 R2/R22. It is now
/// a tab of its own, and that is the whole of FB `2026.08.02/004`'s fix C: the
/// sheet popped itself on a successful connect, dropping the user back onto the
/// dashboard's empty state for the 3.1–5.3 s a switch takes, which reads as
/// "the Bluetooth dropped".
///
/// Step 2 places the tab; the list itself arrives in Step 3.
library;

import 'package:flutter/material.dart';

/// The devices tab's body (sits inside the app shell's [Scaffold]).
class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key, this.onOpenSettings});

  /// Switch to the Settings tab, handed down from the shell.
  ///
  /// It is threaded rather than looked up because it must go through the
  /// shell's single `_setTab` entry point: the device detail page (Step 4) hosts
  /// the dashboard, whose stale-telemetry banner links to Settings, and the
  /// 2026-08-07 review found that exact callback writing `_tab` behind the
  /// gate's back — leaving the GNSS receiver running under the Settings page.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
