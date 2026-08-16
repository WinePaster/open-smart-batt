/// OpenSmartBatt — "how this is measured" modals (design 0042 §3.9b / 0045 §3.6b).
///
/// Two sheets, one shape: what the sensor actually measures, where it is known
/// to be wrong, and what the app deliberately does not do.
///
/// ## Why these exist at all, given the copy discipline
///
/// Design 0046 §4.7 says text is only for (1) warnings before an irreversible
/// action and (2) objective limits the user cannot infer from the screen.
/// Everything here is category 2, and each line was chosen because a user CAN
/// hit it and CANNOT explain it:
///
///  * a 0.8 g corner reading 0.62 g (a leaning bike projects the lateral
///    component onto a tilted axis — cars do not have this),
///  * a speed that stops moving in a tunnel,
///  * a speed of 0 while wheeling the bike at walking pace.
///
/// Without these, the honest answer the user arrives at is "this app is
/// inaccurate", which is worse than the truth and unfalsifiable from their side.
///
/// ## Why not the consent dialog
///
/// Both features already have one (0042 §3.9, 0045 Q4) and both are shown ONCE,
/// at off→on. "How is this calculated?" is a question people ask AFTER using
/// something — the moment the number looks wrong. Someone who enabled the
/// switch three months ago can never see that dialog again.
///
/// ⚠️ These carry NUMBERS that the road test will change (`vStillMps`, `tHold`,
/// `tLost`). They are listed in each design's road-test acceptance for exactly
/// that reason: a threshold moved without the sentence moving leaves the app
/// stating something that is no longer true.
library;

import 'package:flutter/material.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// One paragraph: an optional 🔴 marker, a bold lead, and the body.
class _Para {
  const _Para(this.lead, this.body, {this.warn = false});
  final String lead;
  final String body;
  final bool warn;
}

/// design 0042 §3.9b.
Future<void> showSpeedMeasurementExplainer(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  return _show(context, l10n.explainerSpeedTitle, [
    _Para(l10n.explainerWhatIsMeasured, l10n.explainerSpeedWhat),
    _Para(l10n.explainerSpeedHoldingLead, l10n.explainerSpeedHolding, warn: true),
    _Para(l10n.explainerSpeedStillLead, l10n.explainerSpeedStill, warn: true),
    _Para(l10n.explainerWhatIsNotDone, l10n.explainerSpeedNotDone),
  ]);
}

/// design 0045 §3.6b.
Future<void> showGForceMeasurementExplainer(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  return _show(context, l10n.explainerGForceTitle, [
    _Para(l10n.explainerWhatIsMeasured, l10n.explainerGForceWhat),
    _Para(l10n.explainerGForceLeanLead, l10n.explainerGForceLean, warn: true),
    _Para(l10n.explainerWhatIsNotDone, l10n.explainerGForceNotDone),
  ]);
}

Future<void> _show(BuildContext context, String title, List<_Para> paras) {
  final colors = context.colors;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: colors.panel,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: colors.text)),
              const SizedBox(height: 16),
              for (final p in paras) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The flag is literally named `warn`: this is a caution
                    // tone, not the accent (design 0064). Not in the design's
                    // classification list — found during the work.
                    if (p.warn) ...[
                      const Icon(Icons.priority_high,
                          size: 15, color: AppSemantics.warn),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(p.lead,
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: p.warn ? AppSemantics.warn : colors.text)),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(p.body,
                    style: TextStyle(
                        fontSize: 12.5, height: 1.75, color: colors.muted)),
                const SizedBox(height: 18),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
