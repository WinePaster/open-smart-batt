/// OpenSmartBatt — the watchface picker, now attached to one device.
///
/// Design 0046 R20 moved this out of Settings. It was in the Display card there
/// because that was the only screen that existed for it, and it never fitted:
/// everything else in that card is app-wide while this one setting is bound to a
/// DEVICE (design 0034 Q3), which is why the row had a state none of its
/// neighbours could have — "nothing to apply to" — and a sentence explaining it.
///
/// 🔑 The move also shortens a path we already know is too long. FB
/// `2026.08.02/006` (吳健毓) lost the live curve when v0.7.3 removed the
/// readouts card's chart toggle: the chart still exists, on the `diagnostic`
/// face, but reaching it meant 離開裝置 → 設定 → 錶盤 → 選診斷 → 回裝置. From
/// this sheet it is 詳情頁 → 錶盤. ⚠️ That does NOT close the report — the chart
/// is still off the default face, which is design 0034 Q1's undecided product
/// question and this sheet does not decide it.
///
/// 🔴 T-new-7: this is the ONLY writer of `display_layout` in `lib/ui/**`. Two
/// entry points writing one column is the double-knob problem design 0046 R18
/// had just finished removing elsewhere; the Settings row is now a signpost, not
/// a second editor.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../dashboard/watchfaces.dart';
import '../widgets/industrial.dart';

/// Open the watchface picker for [deviceId].
///
/// Returns false WITHOUT showing anything when [deviceId] is not a saved
/// device. That guard is the surviving form of design 0034 Q3's asset: the
/// layout lives in the `saved_devices` row, so a unit the user declined to name
/// has nowhere to put one, and writing it anyway would add a row to their device
/// picker as a side effect of a display setting. In Settings that state was
/// reachable and the row disabled itself and said why; here it is unreachable by
/// construction — this sheet is only ever opened from a saved unit's page — so
/// the rule is enforced at the API instead of explained on screen.
Future<bool> showWatchfaceSheet(
  BuildContext context, {
  required String deviceId,
}) async {
  if (!context.read<DeviceController>().isSaved(deviceId)) return false;
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0xB804060A),
    builder: (_) => _WatchfaceSheet(deviceId: deviceId),
  );
  return true;
}

/// The picker + "restore defaults", for ONE unit (design 0034 Phase 5, Q6).
///
/// Two rows rather than one because they answer different questions and one of
/// them is destructive-ish; kept together because Q6 ruled that restore belongs
/// beside the thing it restores.
class _WatchfaceSheet extends StatelessWidget {
  const _WatchfaceSheet({required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final devices = context.watch<DeviceController>();
    final layout = devices.layoutFor(deviceId);

    Future<void> apply(DisplayLayout next) =>
        devices.setDisplayLayout(deviceId, next);

    // design 0034 §4.3, "unavailable is not offered". `riding` exists only to
    // carry the speed card, so with the master switch off there is nothing for
    // it to be — and the SAME predicate keeps a stored `riding` from rendering
    // (see `ridingSelectable`), which is what stops it collapsing into a copy
    // of `compact`.
    //
    // ⚠️ The picker's `selected` is the STORED face, which can be `riding`
    // while the option is absent. `SegmentedControl` matches on `==`, so it
    // simply highlights nothing — the honest rendering of "your stored choice
    // is not currently available", and better than silently re-pointing the
    // control at `standard`, which would look like the setting had been changed
    // for the user.
    final settings = context.watch<SettingsController>().settings;

    return SafeArea(
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: context.colors.panel,
          border: Border(top: BorderSide(color: context.colors.line2)),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: context.colors.line2,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                ),
              ),
              SettingsRow(
                label: l10n.settingsWatchfaceLabel,
                sub: l10n.settingsWatchfaceSub,
                trailing: SegmentedControl<Watchface>(
                  selected: layout.watchface,
                  onChanged: (v) => apply(DisplayLayout(watchface: v)),
                  options: [
                    (value: Watchface.standard, label: l10n.watchfaceStandard),
                    (value: Watchface.compact, label: l10n.watchfaceCompact),
                    (
                      value: Watchface.diagnostic,
                      label: l10n.watchfaceDiagnostic
                    ),
                    if (ridingSelectable(settings))
                      (value: Watchface.riding, label: l10n.watchfaceRiding),
                  ],
                ),
              ),
              SettingsLinkRow(
                icon: Icons.restore,
                label: l10n.settingsRestoreDisplayLabel,
                last: true,
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final navigator = Navigator.of(context);
                  final done = l10n.settingsRestoreDisplayDone;
                  await apply(DisplayLayout.defaults);
                  navigator.pop();
                  messenger.showSnackBar(SnackBar(
                    duration: const Duration(milliseconds: 1600),
                    content: Text(done),
                  ));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
