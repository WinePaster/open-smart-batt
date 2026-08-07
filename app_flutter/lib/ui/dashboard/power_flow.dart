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
/// 🔒 Do NOT lower below 0.03 A: a power bank with its boost rail off (`0x4B`
/// b7 == 0x00) still reports a charge-side `0x49` offset, and this band is the
/// first thing keeping such a unit from reading as "charging".
///
/// ⚠️ The band is NOT sufficient for that on its own, and must not be asked to
/// be. The rail-off residual varies BY UNIT: 36–39 mA on one unit (inside the
/// band) but a constant 58–69 mA on another — beyond any width this band could
/// honestly have, since genuine charge/discharge onset currents start not far
/// above it. The out-of-band residuals are handled by the rail-off veto in
/// [powerFlowOf] (see [kRailOffChargeVetoA]); widening this band to swallow
/// them would trade a per-unit standby bug for misreading real low-rate flow
/// as idle on every unit.
const double kPowerFlowDeadbandA = 0.05;

/// Amps below which a charging-signed current can be VETOED by a rail-off b7.
///
/// A rail-off unit can report a charge-side `0x49` residual beyond the
/// dead-band (58–69 mA observed), which the sign alone would print as a
/// permanent "charging 0.06 A" on a bank that is doing nothing. When the SAME
/// burst's b7 reads 0x00 (rail off, every bit clear) and the magnitude is
/// under this line, [powerFlowOf] reads idle instead of charging.
///
/// 🔒 The threshold must keep clear margin to two populations at once:
///
///  * ABOVE every observed rail-off charge residual (36–69 mA), or a genuine
///    standby keeps misreading as "charging";
///  * WELL BELOW the smallest genuinely-charging frame ever seen with a
///    spurious b7 == 0x00 (667 mA; the other is 2,712 mA), or a one-frame
///    flag glitch vetoes a real charge into "standby".
///
/// 0.3 A sits roughly an order of magnitude from both edges. The veto is
/// ONE-WAY: it can only downgrade a charging verdict to idle — it never
/// invents a direction, and it never touches the discharge sign.
const double kRailOffChargeVetoA = 0.3;

/// Direction from the SIGN of the signed current. Sign only — the magnitude
/// never decides a direction, only whether there is one at all.
///
/// [portFlagsRaw] is the same burst's raw `0x4B` b7, when the caller has one
/// (power banks only). It can only VETO: a charging-signed current under
/// [kRailOffChargeVetoA] with b7 == 0x00 reads idle — the rail is off and the
/// small magnitude is a per-unit sense residual, not energy moving. It never
/// creates a direction; with it null (a non-power-bank, or `0x4B` not yet
/// arrived) the derivation is exactly the sign-and-band logic it always was.
PowerFlow powerFlowOf(double? current, {int? portFlagsRaw}) {
  if (current == null) return PowerFlow.unknown;
  if (current.abs() < kPowerFlowDeadbandA) return PowerFlow.idle;
  // Rail-off veto (2026-08-07): charging sign + small magnitude + b7 == 0x00.
  // Deliberately NOT a positive rule in either direction — no bit ever makes
  // a "charging" claim (bit1 is cable-present, bit3 is one-way), and a
  // discharge is never vetoed here.
  if (current < 0 &&
      current.abs() < kRailOffChargeVetoA &&
      portFlagsRaw == 0x00) {
    return PowerFlow.idle;
  }
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
