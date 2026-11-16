/// 連線節奏（實驗）— the Android connection-priority switch in Settings >
/// diagnostics (owner ruling 2026-11-16, merged from the `test/conn-priority`
/// side build `26111490`; default 不要求). See [BleService.connectionPriority].
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show ConnectionPriority;
import 'package:open_smart_batt/l10n/app_localizations.dart';

/// The choices, in display order; null = ask nothing (the default).
const List<ConnectionPriority?> connectionPriorityOptions = [
  null,
  ConnectionPriority.lowPower,
  ConnectionPriority.balanced,
  ConnectionPriority.high,
];

String connectionPriorityLabel(AppLocalizations l10n, ConnectionPriority? p) =>
    switch (p) {
      null => l10n.settingsConnPriorityNone,
      ConnectionPriority.lowPower => l10n.settingsConnPriorityLowPower,
      ConnectionPriority.balanced => l10n.settingsConnPriorityBalanced,
      ConnectionPriority.high => l10n.settingsConnPriorityHigh,
    };

/// Tests force the row on; on a device it exists on Android only (iOS has no
/// connection-priority request).
@visibleForTesting
bool? debugShowConnectionPriorityRow;

bool get showConnectionPriorityRow =>
    debugShowConnectionPriorityRow ?? Platform.isAndroid;
