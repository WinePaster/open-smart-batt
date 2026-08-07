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

import 'package:flutter/material.dart';

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
/// 🔒 Do NOT lower below 0.03 A. There are now TWO load-bearing reasons, and
/// they point the same way:
///
///  1. (design 0035 §6 seam 1 / Q8) A power bank with its boost rail off
///     (`0x4B` b7 == 0x00) still reports a 36–39 mA `0x49` offset, computing to
///     ≈ −0.039 A. This band is what naturally swallows that offset so a
///     standby unit does not read as "charging".
///  2. (2026-08-05) The energy-path row now uses `powerFlowOf(...) == idle` as
///     the same-burst CORROBORATION for `b7 == 0x00` — see
///     `power_path_row.dart`'s "why standby needs corroboration" note. That
///     works only because reason 1 holds: a real rail-off computes inside the
///     band, while the 5 spurious `0x00` frames in the corpus sit at 2,718 /
///     251 / 68 mA, two orders of magnitude out. Lower this constant far enough
///     and a genuine rail-off stops reading idle — at which point the guard
///     inverts and the app starts BELIEVING the spurious standby readings it
///     was written to reject.
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

/// The glyph a direction is drawn with, wherever it is drawn.
///
/// Beside [powerFlowColor] for the same reason: the type chip, the SOC readout
/// tile and the energy-path row all show a direction, and a second copy of this
/// table is how one page ends up telling three stories. [PowerFlow.unknown]
/// keeps the icon the page has always drawn — with no direction to show, a
/// different glyph would be a different guess, not fewer guesses.
///
/// 📦 Was `_flowIcon`, private to `power_bank_view.dart`; hoisted by design
/// 0046 Step 7 when the card factory left that file. Value for value unchanged.
IconData powerFlowIcon(PowerFlow f) => switch (f) {
      PowerFlow.charging => Icons.battery_charging_full,
      PowerFlow.discharging => Icons.bolt,
      PowerFlow.idle => Icons.pause_circle_outline,
      PowerFlow.unknown => Icons.battery_charging_full,
    };
