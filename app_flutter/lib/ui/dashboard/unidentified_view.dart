/// OpenSmartBatt — "this build does not know what this is".
///
/// Drawn for [RoutingDecision.unclassified]: the unit answered with a
/// device-type byte, and it is not one of the four this build maps
/// (`0x02` battery, `0x17`/`0x18` capacitor, `0x22` power bank — see
/// [ProductClass.fromDeviceType]).
///
/// ## Why this is a dead end on purpose (design 0050 D3 / D7 / D8)
///
/// It used to reach the PACK SHELL carrying a「未分類（請指定）」chip, and the
/// chip opened a menu letting the user name the class themselves. Two things
/// were wrong with that, and the owner's ruling of 2026-08-08 removed both:
///
///  * **The shell itself was a guess.** `DisplayModules.unclassified` was field
///    for field the battery's entry, so an unidentified unit was drawn with a
///    voltage gauge, a numbers grid and per-cell bars — the exact shape of
///    FB-43, where a power bank's single-cell 3.79 V was drawn under
///    「PVLT 主電壓」on a gauge that pins it to the bottom of its sweep. Every
///    number on that screen was real and the screen was still false.
///  * **Classifying is not the user's job.** They cannot know, and a wrong
///    answer is indistinguishable from a right one until something looks odd.
///    It is OUR job: the owner sends a log, the device-type byte gets a mapping,
///    the next build knows. `0x18` went through exactly that route on
///    2026-08-01 — three units, three unrelated reporters, and this project's
///    own protocol notes had said it did not exist.
///
/// So this view asserts nothing about the hardware and offers one action: the
/// diagnostic export, which is the thing that actually gets the device
/// supported.
///
/// ⚠️ It is NOT [ClassPendingView]. That one is a WAIT — no byte has arrived —
/// and it resolves itself on almost every connect within a second. This is a
/// RESTING state: the byte arrived, we read it, we do not know it, and nothing
/// about this session will change that.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../widgets/one_screen_report.dart';

/// Shown when the device-type byte is one this build does not map.
class UnidentifiedView extends StatelessWidget {
  const UnidentifiedView({super.key, this.onExportLog});

  /// Route to the diagnostic export. Null hides the button — the view still
  /// says what it knows, which is the part that must never depend on a caller.
  final VoidCallback? onExportLog;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final conn = context.watch<ConnectionController>();
    return OneScreenReport(
      report: [
        Icon(Icons.help_outline, size: 44, color: context.colors.muted),
        const SizedBox(height: 22),
        Text(
          l10n.unidentifiedTitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            letterSpacing: 0.5,
            fontWeight: FontWeight.w700,
            color: context.colors.text,
          ),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Text(
            l10n.unidentifiedBody,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.7,
              color: context.colors.muted,
            ),
          ),
        ),
        const SizedBox(height: 26),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Column(
            children: [
              if (onExportLog != null)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onExportLog,
                    icon: const Icon(Icons.file_download_outlined, size: 16),
                    label: Text(l10n.settingsExportLogLabel),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              // Reconnecting cannot change the answer — the byte is
              // what it is — but a re-read costs nothing and rules out
              // a corrupted frame, which is the one way this state can
              // be reached by accident rather than by hardware.
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed:
                      conn.isBusy ? null : () => conn.reconnectCurrent(),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(l10n.classPendingRetryButton),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
