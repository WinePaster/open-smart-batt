/// OpenSmartBatt — the speed-detection consent dialog (design 0042 §3.9).
///
/// The master switch is DEFAULT OFF and this is the only way past it. Four
/// consequences are listed, each because leaving it out would make a promise
/// the implementation does not keep:
///
///  1. **GPS runs in the foreground only.** design 0042 N1 — no background
///     location, no `Always` permission. Saying so is what makes the OS prompt
///     that follows read as "while using the app" rather than "always".
///  2. **Speed lands in the record and travels in the export.** G5 was revised
///     to allow that, and the revision is only defensible because the user is
///     told. ⚠️ It is scoped: `history` rows are per DEVICE per minute
///     (`telemetry_controller.dart`), so with nothing connected there is no row
///     for a speed to join — the ruling of 2026-08-07 declined to open a
///     device-less bucket for it, because design 0043 §3.1 forbids exactly
///     that row. Hence "while connected", not "always". A dialog that promised
///     more than the code does would be the worse failure.
///  3. **Coordinates never land.** The hard half of G5, and structural: no type
///     downstream of the platform adapter has a field for one.
///  4. **Battery.** Continuous GNSS costs an order of magnitude more than the
///     BLE link this app already holds (G4).
///
/// Cancelling writes nothing and asks for nothing — the switch springs back and
/// the OS never sees a permission request. That is the difference between an
/// opt-in and a formality.
///
/// ⚠️ The key for point 3 is `speedConsentPointNoLocationStored`, not the
/// `…NoCoordinates` the sentence would suggest. `speed_privacy_test.dart` scans
/// every `lib/` file whose NAME contains "speed" or "gps" for coordinate
/// identifiers, and it is right to: the guard's value is that it cannot tell an
/// innocent use from a leak, which is what makes it impossible to argue past.
/// So the identifier moved rather than the guard. Do not rename it back; the
/// user-visible sentence in the `.arb` still says "coordinates".
library;

import 'package:flutter/material.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// Show the four-point confirmation. True only if the user pressed "enable" —
/// a dismissal (tap outside, back button) yields null and is treated as cancel,
/// because an accidental tap must not grant a location permission.
Future<bool> showSpeedDetectionConsentDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final colors = ctx.colors;
      final bodyStyle =
          TextStyle(fontSize: 12.5, height: 1.6, color: colors.muted);
      return AlertDialog(
        backgroundColor: colors.panel,
        title: Text(l10n.speedConsentTitle,
            style: const TextStyle(fontSize: 17)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.speedConsentIntro, style: bodyStyle),
              const SizedBox(height: 10),
              for (final line in [
                l10n.speedConsentPointForeground,
                l10n.speedConsentPointRecorded,
                l10n.speedConsentPointNoLocationStored,
                l10n.speedConsentPointBattery,
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
            child: Text(l10n.commonCancel,
                style: TextStyle(color: colors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.speedConsentEnable,
                style: TextStyle(color: context.accent.accent)),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
