/// OpenSmartBatt — the one-time explainer in front of warning notifications
/// (design 0080 §3.7.3, ruling Q4).
///
/// Same shape as `speed_consent_dialog` / `g_meter_consent_dialog`, and for the
/// same two reasons those exist:
///
///  1. **The master switch ships OFF and this is the only way past it.** Ruling
///     Q4. A notification is an interruption, and an interruption the user did
///     not ask for is one they turn off for good.
///  2. **The OS prompt that follows is one-shot.** On iOS a refusal cannot be
///     re-asked from inside the app; the only route back is the Settings app.
///     So the request has to be attached to a deliberate act, with the reason
///     stated first — asking at launch buys a high refusal rate on a permission
///     you get one chance at.
///
/// ## 🔴 The five bullets are the honesty clause (§6.1), not marketing
///
/// Three of them are what the feature CANNOT do. They are here rather than only
/// in Settings because this dialog is the moment the user forms their
/// expectation, and every wrong expectation formed here comes back later as
/// "the app did not warn me". The forbidden sentences are named in §6.1 and in
/// the `.arb` description on `settingsAlertsLimitsTitle`: never 「電池有異常會
/// 通知你」, never "24-hour monitoring", never "offline guardian", and never any
/// claim about iOS delivering in the background.
///
/// Cancelling writes nothing and asks for nothing — the switch springs back and
/// the OS never sees a request. That is the difference between an opt-in and a
/// formality.
library;

import 'package:flutter/material.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// Show the explainer. True only if the user pressed "turn on"; a dismissal
/// (tap outside, back button) yields null and counts as cancel, because an
/// accidental tap must not spend the one iOS prompt.
Future<bool> showAlertsConsentDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final colors = ctx.colors;
      final bodyStyle =
          TextStyle(fontSize: 12.5, height: 1.6, color: colors.muted);
      return AlertDialog(
        backgroundColor: colors.panel,
        title:
            Text(l10n.alertsConsentTitle, style: const TextStyle(fontSize: 17)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.alertsConsentIntro, style: bodyStyle),
              const SizedBox(height: 10),
              // Both platforms' lines are shown on both platforms, following
              // the Settings card's precedent: a user reads this to decide
              // whether to trust the feature, and one line about the phone in
              // their hand does not tell them what they lose by switching.
              for (final line in [
                l10n.alertsConsentPointConnected,
                l10n.alertsConsentPointAndroid,
                l10n.alertsConsentPointIos,
                l10n.alertsConsentPointPermission,
                l10n.alertsConsentPointThresholds,
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('· ', style: bodyStyle),
                      Expanded(child: Text(line, style: bodyStyle)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
                Text(l10n.commonCancel, style: TextStyle(color: colors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.alertsConsentEnable,
                style: TextStyle(color: context.accent.accent)),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
