/// OpenSmartBatt — locale labels for [CaptureMark] (design 0013).
///
/// Kept apart from the enum so the model layer stays free of Flutter, and
/// shared by the dashboard bar and the guided run so a label can never drift
/// between the two places a user meets the same step.
///
/// Only the LABEL is translated. `CaptureMark.code` is the identifier tooling
/// matches on and is never localised.
library;

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';

/// Display text for [m] in the active locale.
String captureMarkLabel(AppLocalizations l10n, CaptureMark m) => switch (m) {
      CaptureMark.powerBankOutA => l10n.captureMarkPbOutA,
      CaptureMark.powerBankOutC5v => l10n.captureMarkPbOutC5v,
      CaptureMark.powerBankOutCPd => l10n.captureMarkPbOutCPd,
      CaptureMark.powerBankOutBoth => l10n.captureMarkPbOutBoth,
      CaptureMark.powerBankIn => l10n.captureMarkPbIn,
      CaptureMark.powerBankIdle => l10n.captureMarkPbIdle,
      CaptureMark.packIdle => l10n.captureMarkPackIdle,
      CaptureMark.packCharging => l10n.captureMarkPackCharging,
      CaptureMark.packLoad => l10n.captureMarkPackLoad,
      CaptureMark.note => l10n.captureMarkNote,
    };
