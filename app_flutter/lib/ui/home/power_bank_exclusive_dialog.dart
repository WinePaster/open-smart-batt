/// OpenSmartBatt — the prompt before opening a power bank's page while other
/// devices are connected (design 0103 D2 / §3.4; multi-link builds only).
///
/// 🔵 Amends design 0046 R9 ("the paused state gets no UI"): R9 forbids a
/// PERSISTENT pause label, and there still is none — the paused links are not
/// on screen while the power bank's page is. This is a one-shot confirmation
/// that belongs to the navigation, shown before the user goes in.
///
/// ⛔ Never says a power bank does "not support" multiple links. It does; we
/// give it the connection to itself (0046a §5.5).
library;

import 'package:flutter/material.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';

import '../../config/multi_link_config.dart';
import '../../state/state.dart';

/// Ask before opening a power bank's page. True = go in.
Future<bool> showPowerBankExclusiveDialog(
  BuildContext context,
  MultiLinkController ml,
) async {
  final l10n = AppLocalizations.of(context);
  var dontAsk = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(l10n.multiLinkPowerBankDialogTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The wording follows the mechanism actually in force (D1).
            Text(ml.powerBankOthers == PowerBankOthersMode.pause
                ? l10n.multiLinkPowerBankDialogBodyPause
                : l10n.multiLinkPowerBankDialogBodyDisconnect),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: dontAsk,
              onChanged: (v) => setState(() => dontAsk = v ?? false),
              title: Text(l10n.multiLinkPowerBankDialogDontAsk),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.multiLinkPowerBankDialogEnter),
          ),
        ],
      ),
    ),
  );
  if (ok == true && dontAsk) await ml.skipPowerBankPromptFromNowOn();
  return ok == true;
}
