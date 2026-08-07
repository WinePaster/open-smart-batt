/// OpenSmartBatt — the G meter confirmation (design 0045 §3.5 / Q2).
///
/// Design 0045 Q2 ruled the switch INDEPENDENT of speed detection — the G meter
/// reads the accelerometer, needs no location permission and no GNSS, so
/// hanging it under the GPS switch would force anyone who wants it to accept a
/// consent they have no use for. "Independent" was NOT a ruling that it is
/// free: Q4 then ruled that G values are recorded, and recording is what needs
/// telling.
///
/// So this dialog is SHORTER than the speed one, and deliberately: two points,
/// because there are two consequences.
///
///  1. **G lands in the record and travels in the export.** The disclosure that
///     makes Q4 defensible. Same rule as the speed dialog: said before it
///     happens, not after somebody notices a column.
///  2. **Nothing appears until the mount is calibrated.** Not a legal point — a
///     usability one, and it is here because design 0045 Q8 removed the
///     dashboard placeholder that used to explain it. Without this sentence a
///     user turns the switch on, sees no change anywhere, and reasonably
///     concludes the feature is broken. R1 names that as this feature's biggest
///     risk.
///
/// Cancelling writes nothing. The switch does not move until consent is given —
/// a control that flips first and springs back makes cancelling look like a
/// failure.
library;

import 'package:flutter/material.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// Show the two-point confirmation. True only if the user pressed "enable" — a
/// dismissal (tap outside, back button) yields null and is treated as cancel.
Future<bool> showGMeterConsentDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final colors = ctx.colors;
      final bodyStyle =
          TextStyle(fontSize: 12.5, height: 1.6, color: colors.muted);
      return AlertDialog(
        backgroundColor: colors.panel,
        title: Text(l10n.gConsentTitle, style: const TextStyle(fontSize: 17)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final line in [
                l10n.gConsentRecorded,
                l10n.gConsentCalibration,
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
            child: Text(l10n.gConsentCancel,
                style: TextStyle(color: colors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.gConsentEnable,
                style: const TextStyle(color: AppColors.amber)),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
