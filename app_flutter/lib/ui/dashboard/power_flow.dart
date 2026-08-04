/// OpenSmartBatt — power-bank energy direction (single source).
///
/// Direction is the SIGN of the signed current (design 0030: discharge
/// positive, charge negative — `0x4A` − `0x49`). It is the ONLY direction the
/// device gives us, and it must be derived in exactly ONE place so the readout
/// tiles (design 0037) and the energy-path row (design 0035) can never tell
/// two different stories about which way energy is moving.
///
/// This was `_flowOf` / `_Flow` private to `power_bank_view.dart` (design
/// 0037). Design 0035 §6 converges it here so the energy-path row reuses the
/// same derivation and, critically, the SAME dead-band — a second copy of the
/// ±0.05 A band that drifted would reintroduce exactly the disagreement this
/// prevents.
library;

import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';

/// Which way energy is moving through a power bank.
///
/// [unknown] is NOT a fourth state to render — it is the absence of a reading
/// (no current yet). A page with no current has nothing to say about direction,
/// and saying it anyway is how FB-47's original defect was written. [idle] is
/// the in-band near-zero case: a magnitude worth showing but no charge/discharge
/// state to name.
enum PowerFlow { charging, discharging, idle, unknown }

/// Amps below which the current is noise rather than a direction (design 0037).
///
/// 🔒 Do NOT lower below 0.03 A (design 0035 §6 seam 1 / Q8): a power bank with
/// its boost rail off (`0x4B` b7 == 0x00) still reports a 36–39 mA `0x49`
/// offset, computing to ≈ −0.039 A. This band is what naturally swallows that
/// offset so a standby unit does not read as "charging".
const double kPowerFlowDeadbandA = 0.05;

/// Direction from the SIGN of the signed current. Sign only — the magnitude
/// never decides a direction, only whether there is one at all.
PowerFlow powerFlowOf(double? current) {
  if (current == null) return PowerFlow.unknown;
  if (current.abs() < kPowerFlowDeadbandA) return PowerFlow.idle;
  return current < 0 ? PowerFlow.charging : PowerFlow.discharging;
}

/// The colour a direction is drawn in, wherever it is drawn.
///
/// Lives beside [powerFlowOf] for the same reason the derivation does: the SOC
/// gauge's sub-line and the energy-path row now both name a direction, and a
/// second copy of this table is how "charging" ends up green on one line and
/// amber on the line below it.
Color powerFlowColor(BuildContext context, PowerFlow flow) => switch (flow) {
      PowerFlow.charging => AppColors.good,
      PowerFlow.discharging => AppColors.amber,
      PowerFlow.idle || PowerFlow.unknown => context.colors.muted,
    };
