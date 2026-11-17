/// 連線節奏 — the Android connection-priority switch in Settings > diagnostics
/// (owner ruling 2026-11-16, merged from the `test/conn-priority` side build
/// `26111490`; default 預設). Remembered since schema v31 (owner ruling
/// 2026-11-17) as [AppSettings.linkPace]. See [BleService.connectionPriority].
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/app_settings.dart' show LinkPace;

/// The choices, in display order; null = ask nothing (the default).
const List<LinkPace?> connectionPriorityOptions = [
  null,
  LinkPace.lowPower,
  LinkPace.balanced,
  LinkPace.high,
];

String connectionPriorityLabel(AppLocalizations l10n, LinkPace? p) =>
    switch (p) {
      null => l10n.settingsConnPriorityNone,
      LinkPace.lowPower => l10n.settingsConnPriorityLowPower,
      LinkPace.balanced => l10n.settingsConnPriorityBalanced,
      LinkPace.high => l10n.settingsConnPriorityHigh,
    };

/// Tests force the row on; on a device it exists on Android only (iOS has no
/// connection-priority request).
@visibleForTesting
bool? debugShowConnectionPriorityRow;

bool get showConnectionPriorityRow =>
    debugShowConnectionPriorityRow ?? Platform.isAndroid;
