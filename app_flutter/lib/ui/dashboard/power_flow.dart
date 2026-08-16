/// OpenSmartBatt — energy direction (single source), per product family.
///
/// Direction is the SIGN of the signed current. It must be derived in exactly
/// ONE place per family so the readout tiles (design 0037), the energy-path row
/// (design 0035) and the pack current tile (design 0056) can never tell two
/// different stories about which way energy is moving.
///
/// 🔴 THE TWO FAMILIES SIGN CURRENT THE OPPOSITE WAY ROUND, and that is a wire
/// fact, not a choice this layer may normalise away:
///
///  * **power bank** — `0x4A` − `0x49`, **positive = discharge** (design 0030).
///    Derived by [powerFlowOf].
///  * **pack** (battery / capacitor) — `0x2E` = `512 − u16`, **negative =
///    discharge, positive = charge** (`docs/protocol/telemetry-decoding.md`
///    §8.2, corrected 2026-08-11). Derived by [packFlowOf].
///
/// Two functions rather than one with a class parameter, because the two have
/// nothing in common below the enum: different sign, different quantisation,
/// different dead-band, and one of them has a flag veto the other has no
/// register for. A single `if (isPack)` body is how a change made for one
/// family silently lands on the other — the exact hazard design 0056 §4 names.
/// The owner's 2026-08-11 ruling A is that neither wire sign is flipped: the
/// DISPLAY names the direction, the number keeps the convention it was decoded
/// with.
///
/// [powerFlowOf] was `_flowOf` / `_Flow` private to `power_bank_view.dart`
/// (design 0037). Design 0035 §6 converged it here so the energy-path row
/// reuses the same derivation and, critically, the SAME dead-band — a second
/// copy of the ±0.05 A band that drifted would reintroduce exactly the
/// disagreement this prevents.
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Which way energy is moving through a device.
///
/// Family-neutral since design 0056: the same four states describe a pack and a
/// power bank, only the derivation differs (see the library comment). Sharing
/// the enum is what lets [powerFlowColor] and [powerFlowIcon] stay one table —
/// "charging is green with a charging glyph" must not be answered twice.
///
/// [unknown] is NOT a fourth state to render — it is the absence of a reading
/// (no current yet). A page with no current has nothing to say about direction,
/// and saying it anyway is how FB-47's original defect was written. [idle] is
/// the in-band near-zero case: a magnitude worth showing but no charge/discharge
/// state to name.
enum PowerFlow { charging, discharging, idle, unknown }

/// Amps below which a POWER BANK's current is noise rather than a direction
/// (design 0037).
///
/// ⚠️ Power-bank scale only. A pack's `0x2E` is quantised to whole amps and has
/// its own, much coarser band — see [kPackFlowDeadbandA]. Reusing this number
/// there would make every single quantisation step a direction claim.
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

/// A POWER BANK's direction, from the SIGN of its signed current. Sign only —
/// the magnitude never decides a direction, only whether there is one at all.
///
/// 🔴 Power banks ONLY, and the sign it reads is the power bank's
/// (positive = discharge). A pack is the other way round; call [packFlowOf],
/// which is not a wrapper around this one for exactly that reason.
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

/// Amps below which a PACK's current names no direction (design 0056).
///
/// 🔑 This is a QUANTISATION band, not a noise filter, and the difference is
/// why it may not be tuned like [kPowerFlowDeadbandA]. `0x2E` decodes as
/// `512 − u16` in whole amperes — 1 A per count — so the readings a pack can
/// produce near zero are exactly …, −2, −1, 0, +1, +2, …. There is no fine
/// structure between them to filter.
///
/// At 1 A/LSB a ±1 reading is ONE count away from zero, i.e. inside the
/// device's own rounding, and its sign is the least trustworthy bit it emits.
/// A resting vehicle whose reading dithers 0 / −1 would otherwise flash
/// 「放電中」at a parked car — the FB-47 failure mode in reverse: a direction
/// asserted where the wire cannot support one. ±2 is the first magnitude that
/// survives a full count of quantisation error in either direction, so the line
/// sits at 1.5 A — the MIDPOINT between the two counts, so that no float
/// representation of an integer ampere can land on the boundary.
///
/// 🔒 Do NOT raise this to swallow "small" currents. Nothing a driver cares
/// about lives near it: alternator charge runs tens of amps and a cranking load
/// runs hundreds (`docs/devices/car-battery.md`), so widening the band buys
/// nothing and would start hiding real low-rate charge on a bench supply.
const double kPackFlowDeadbandA = 1.5;

/// A PACK's direction (battery / capacitor), from the sign of `0x2E`.
///
/// 🔴 THE SIGN IS THE OPPOSITE of [powerFlowOf]'s: on a pack **negative is
/// discharge and positive is charge** (`docs/protocol/telemetry-decoding.md`
/// §8.2, corrected 2026-08-11 — five engine-start events reading −211…−446 A
/// while PVLT collapsed, then positive as PVLT climbed). Delegating to
/// [powerFlowOf] with a negated argument was considered and rejected: it would
/// make one function's dead-band and its power-bank-only rail-off veto apply to
/// a family that has neither, and it would hide the sign flip inside a call.
///
/// There is no flag veto here because a pack has no `0x4B` — the sign of
/// `0x2E` is the whole of what the device says about direction.
///
/// [PowerFlow.unknown] is the absence of a reading, [PowerFlow.idle] the
/// in-band near-zero case: a magnitude worth showing but no direction to name.
PowerFlow packFlowOf(double? current) {
  if (current == null) return PowerFlow.unknown;
  if (current.abs() < kPackFlowDeadbandA) return PowerFlow.idle;
  return current > 0 ? PowerFlow.charging : PowerFlow.discharging;
}

/// The colour a direction is drawn in, wherever it is drawn.
///
/// Lives beside [powerFlowOf] for the same reason the derivation does: the SOC
/// gauge's sub-line and the energy-path row now both name a direction, and a
/// second copy of this table is how "charging" ends up green on one line and
/// amber on the line below it.
/// 🔴 Status colours, never the accent (design 0064). Charging and discharging
/// are told apart by colour alone on the SOC tile, and this table was NOT in
/// the design's classification list — found while doing the work. A green
/// accent would have merged the two directions everywhere they are drawn.
Color powerFlowColor(BuildContext context, PowerFlow flow) => switch (flow) {
      PowerFlow.charging => AppSemantics.good,
      PowerFlow.discharging => AppSemantics.warn,
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
