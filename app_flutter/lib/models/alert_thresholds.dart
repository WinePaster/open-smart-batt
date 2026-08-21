/// OpenSmartBatt — where an alert threshold comes from, and which one wins
/// (design 0080 §3.1 / §3.2).
///
/// PURE Dart (no Flutter imports), like every other file in `models/`, because
/// the whole of design 0080's logic content lives in this file and its
/// neighbour `state/alert_evaluator.dart` — and P1 exists precisely so that
/// content can be finished and tested before any platform, database or widget
/// is involved (§5, "P1 先行且獨立").
///
/// ## The one thing this file is for
///
/// A threshold is not a constant. The same question — "is 12.3 V too low?" —
/// has up to four different answers depending on who is asked, and the ranking
/// of those four answerers is the entire design:
///
///   ① what the USER set for THIS unit          (most specific, always wins)
///   ② what THIS unit reported in its `0x2B`    (per-unit factory setting)
///   ③ our per-category default table           (§3.2.1, a fallback)
///   ④ nobody knows                             ⇒ do not evaluate, do not guess
///
/// 🔴 **Why ② outranks ③, stated once because it is the load-bearing claim.**
/// `0x2B` is per-UNIT, not per-category: `tools/fb.py counter 0x2B` (2026-08-22)
/// reports 194 batch×device rows, every one of them `uniq=1` — a unit always
/// reports the same triple — while the SAME category spreads over several
/// triples (car batteries alone show five). Across the corpus that is 12 distinct
/// values over 26 pieces of hardware. So the unit's own answer is evidence and
/// our table is an inference, and the gap between them is not small: the third
/// generation capacitor (`0x10`=`0x18`) leaves the factory with OV = 16.0 V,
/// **1.2 V above** what [kCategoryDefaults] would say for a capacitor. Rank the
/// table first and every one of those units gets warned about on a good day.
///
/// ## Per FIELD, not per unit (§3.1)
///
/// A user who typed a UV must keep the device's OV and OT. This is the same
/// rule `BleService.setThresholds` already follows on the write path when it
/// preserves the UT byte, and for the same reason: **editing one field must not
/// silently erase the three next to it.** Hence [ResolvedThreshold] carries its
/// own [ThresholdSource] — one badge per row on screen, not one per unit.
library;

import 'declared_device_model.dart';
import 'telemetry_sample.dart';

/// The three things design 0080 watches.
///
/// Deliberately NOT "low SOC" or "high current": current DIRECTION is derived
/// differently per product family (`ui/dashboard/power_flow.dart` keeps
/// `packFlowOf` and `powerFlowOf` apart on purpose), so a shared current alarm
/// would fire on a charging power bank — the `twfRaw` incident, where a healthy
/// bank at 4 V read as a collapsed 12 V battery. Design 0080 §1.3 rules it out.
enum AlertKind {
  /// PVLT above the over-voltage threshold.
  overVoltage,

  /// PVLT below the under-voltage threshold.
  underVoltage,

  /// Temperature above the over-temperature threshold.
  overTemperature;

  /// True when this kind is measured in volts rather than degrees.
  ///
  /// Used to pick the hysteresis band and to render the value; a `switch` at
  /// each of those call sites would have to be kept in step with this enum by
  /// hand, and there is exactly one axis of difference to encode.
  bool get isVoltage => this != AlertKind.overTemperature;
}

/// Which of design 0080 §3.1's four layers produced a value.
///
/// 🔑 This is carried all the way to the screen, not consumed internally. §6.2
/// makes it a mitigation in its own right: a user looking at "80 °C" has no way
/// to tell whether their unit said that or whether we did, and those two carry
/// very different licence to be edited. The power bank's 50 °C (§3.2.2) is the
/// case that forced it — it is the one number in the whole table that nobody
/// measured, and the UI is required to say so.
enum ThresholdSource {
  /// Layer ① — the user set this for this unit.
  user,

  /// Layer ② — the unit itself reported it in `0x2B`.
  device,

  /// Layer ③ — our per-category fallback table, [kCategoryDefaults].
  appDefault,

  /// Layer ④ — no answer from anywhere. [ResolvedThreshold.value] is null and
  /// the field is NOT evaluated.
  ///
  /// 🔴 A state, not an error. §3.1: a unit that reported no `0x2B` and whose
  /// owner declared no category is one we know nothing about, and a warning
  /// invented for it is a coin toss whose losing side is permanent — the user
  /// stops believing the feature, or worse, reads a real fault as another false
  /// alarm.
  none,
}

/// One threshold and the provenance of it.
class ResolvedThreshold {
  const ResolvedThreshold(this.value, this.source);

  /// Nothing to compare against (layer ④).
  static const ResolvedThreshold unavailable =
      ResolvedThreshold(null, ThresholdSource.none);

  /// Volts for [AlertKind.overVoltage] / [AlertKind.underVoltage], degrees
  /// Celsius for [AlertKind.overTemperature]. Null exactly when [source] is
  /// [ThresholdSource.none].
  final double? value;

  final ThresholdSource source;

  /// True when this field has a number to compare readings against.
  ///
  /// Read this rather than `value != null` at call sites that are deciding
  /// whether to evaluate: it says what the check MEANS, and it cannot drift
  /// away from [source] the way two independent null checks would.
  bool get isSet => value != null;

  @override
  bool operator ==(Object other) =>
      other is ResolvedThreshold &&
      other.value == value &&
      other.source == source;

  @override
  int get hashCode => Object.hash(value, source);

  @override
  String toString() =>
      isSet ? '${value!.toStringAsFixed(2)}(${source.name})' : 'unset';
}

/// The three resolved fields for one unit.
class AlertThresholds {
  const AlertThresholds({required this.ov, required this.uv, required this.ot});

  /// Nothing known about any field — what layer ④ produces for all three.
  static const AlertThresholds none = AlertThresholds(
    ov: ResolvedThreshold.unavailable,
    uv: ResolvedThreshold.unavailable,
    ot: ResolvedThreshold.unavailable,
  );

  final ResolvedThreshold ov;
  final ResolvedThreshold uv;
  final ResolvedThreshold ot;

  /// Index by [AlertKind] so the evaluator can loop over the three kinds
  /// instead of writing the same transition code three times. Three copies of a
  /// state machine is three places for a fix to be applied twice.
  ResolvedThreshold operator [](AlertKind kind) {
    switch (kind) {
      case AlertKind.overVoltage:
        return ov;
      case AlertKind.underVoltage:
        return uv;
      case AlertKind.overTemperature:
        return ot;
    }
  }

  /// True when at least one field can be evaluated. A unit for which this is
  /// false is invisible to the whole feature — no state machine, no banner, no
  /// notification — which is what §3.1 layer ④ asks for.
  bool get hasAny => ov.isSet || uv.isSet || ot.isSet;

  @override
  bool operator ==(Object other) =>
      other is AlertThresholds &&
      other.ov == ov &&
      other.uv == uv &&
      other.ot == ot;

  @override
  int get hashCode => Object.hash(ov, uv, ot);

  @override
  String toString() => 'AlertThresholds(ov: $ov, uv: $uv, ot: $ot)';
}

/// One row of the per-category fallback table (§3.2.1).
class CategoryAlertDefaults {
  const CategoryAlertDefaults({this.ov, this.uv, this.ot});

  /// Volts; null means this category gets no over-voltage default.
  final double? ov;

  /// Volts; null means this category gets no under-voltage default.
  final double? uv;

  /// Degrees Celsius.
  final double? ot;
}

/// 🔴 **A FALLBACK, never a truth** (design 0080 §3.2.1). Layer ③ only.
///
/// Every voltage row below is one real `0x2B` payload observed in the corpus,
/// decoded with the shipping arithmetic (`telemetry_decoder.dart:103-109`:
/// `ov = b4*0.025 + 14.4`, `uv = b5*0.025 + 10.4`, `ot = b6 + 60`) — a
/// representative unit's factory setting, chosen because it is the most common
/// one for that category, NOT a computed safe limit:
///
/// | category              | payload    | OV     | UV     | OT     |
/// |-----------------------|------------|--------|--------|--------|
/// | carBattery            | `18401414` | 15.0 V | 12.0 V | 80 °C  |
/// | motorcycleBattery     | `18181414` | 15.0 V | 11.0 V | 80 °C  |
/// | car / bike capacitor  | `102c2814` | 14.8 V | 11.5 V | 100 °C |
/// | powerBank             | —          | —      | —      | 50 °C  |
///
/// ⚠️ **The bike battery row is why this table is dangerous.**
/// `docs/devices/motorcycle-battery.md:51` decoded `18181414` as
/// "OV 15.0 / UV 12.0 / OT 20 / UT 20" — two of the three fields wrong — and
/// that line sat unchallenged from 2026-07-30 to 2026-08-22 (it was even used
/// as an input to one analysis, `2026.08.08-004.md:130`) for one reason:
/// **it was only ever read, never computed with.** Design 0080 §2.5 corrected
/// it as a prerequisite of this file. The moral is the whole point of the
/// ranking above — the moment a documentation row becomes a program constant it
/// stops being a note and starts being something that warns users, so every
/// cell here has to point at wire evidence and any cell that cannot must be
/// left out rather than filled in.
///
/// ⚠️ The two capacitor rows are IDENTICAL and that is not a copy-paste slip:
/// the wire cannot separate a bike capacitor from a car one (both `0x17`/`0x18`,
/// same `0x10` payload), so there is no second observation to put in the second
/// row. Writing a different number in one of them would be inventing the
/// distinction the hardware refuses to make.
const Map<DeclaredCategory, CategoryAlertDefaults> kCategoryDefaults =
    <DeclaredCategory, CategoryAlertDefaults>{
  DeclaredCategory.carBattery: CategoryAlertDefaults(ov: 15.0, uv: 12.0, ot: 80),
  DeclaredCategory.motorcycleBattery:
      CategoryAlertDefaults(ov: 15.0, uv: 11.0, ot: 80),
  DeclaredCategory.carCapacitor:
      CategoryAlertDefaults(ov: 14.8, uv: 11.5, ot: 100),
  DeclaredCategory.motorcycleCapacitor:
      CategoryAlertDefaults(ov: 14.8, uv: 11.5, ot: 100),
  // 🔴 No `ov` / `uv` — see [kPowerBankWatchesTemperatureOnly]. `ot` is the one
  // number in this map that was never measured off any wire; it is ours.
  DeclaredCategory.powerBank: CategoryAlertDefaults(ot: kPowerBankOtDefaultC),
};

/// The power bank's over-temperature default, in °C — **an app-chosen reminder
/// point, NOT a measured safety limit** (design 0080 §3.2.2, owner ruling
/// 2026-08-22; the design's own proposal had been 45).
///
/// What is actually known: all 49 power-bank batches in the corpus report `0x21`
/// (so the reading exists and today's decoder already handles it — the LEN 2
/// payload's extra byte is ignored, which happens to be correct), and the
/// vendor app agreed with `0x21 b4` at 33 °C. The highest value anywhere in
/// those 49 batches is **40 °C**, with most units sitting at 24–35.
///
/// 🔴 What is NOT known: what temperature is actually unsafe for this hardware.
/// Nobody has measured that and nothing in the corpus implies it. 50 leaves
/// 10 °C of headroom over the observed ceiling, which is a false-alarm budget
/// and nothing more. This is why it resolves as [ThresholdSource.appDefault]
/// and never as [ThresholdSource.device], and why §3.2.2 requires the screen to
/// say "App 預設" beside it — the user has to be able to see that this number
/// is our opinion.
const double kPowerBankOtDefaultC = 50;

/// Power banks are watched for heat and **never for voltage** (§3.2.2, ruling
/// Q1) — regardless of which layer offers a voltage.
///
/// Three independent reasons, and the third is the one that makes this a
/// suppression rather than a missing table row:
///
/// 1. There is no evidence to build a threshold from: `0x2B` appears **zero**
///    times across all 49 power-bank batches, so layer ② is empty for this
///    entire class.
/// 2. "Voltage" is not one quantity here. PVLT on a power bank is CELL voltage
///    (~3.7 V class), `0x49`'s mV field is PORT voltage and `0x4A`'s is cell —
///    so a single OV/UV pair cannot even name what it is comparing.
/// 3. Getting it wrong has a known shape: a charging bank's 4 V once read as a
///    collapsing 12 V battery. `TelemetrySample.twfRaw`'s comment is that
///    incident's headstone.
///
/// ⚠️ **Deliberately applied AFTER layers ① and ②, not instead of them** — see
/// [resolveThresholds]. The design specifies the UI will not offer the two
/// voltage rows for this category at all (§3.2.2, "不是顯示成灰色停用"), so a
/// user-set voltage should be unreachable; this constant makes the pure
/// function safe anyway rather than trusting that no future screen, import or
/// migration ever puts a number in those columns. Reason 2 above does not stop
/// being true because a row exists.
const bool kPowerBankWatchesTemperatureOnly = true;

/// Resolve all three thresholds for ONE unit, per field, per design 0080 §3.1.
///
/// [userOv] / [userUv] / [userOt] are layer ①: what the owner typed for this
/// unit (`saved_devices.alert_ov/uv/ot`, P2). Null means "not answered" and
/// never "zero" — the same NULL-vs-sentinel rule the `declared_*` columns
/// already follow (§3.6.1), because a sentinel makes "who has not answered"
/// uncountable.
///
/// [reported] is layer ②: the unit's own `0x2B`, carried on the live sample.
/// Passed as a whole [TelemetrySample] rather than as three loose doubles
/// deliberately — three same-typed positional-ish arguments in the caller's
/// hand is how OV ends up wired to UV, and the corrections in §2.5 are what
/// that class of mistake costs. Null when nothing is on the link.
///
/// [category] is layer ③: what the owner declared (design 0066). Null — the
/// common case, since the declaration is optional — simply skips the layer.
///
/// Returns [ThresholdSource.none] with a null value for any field none of the
/// layers could answer. That field is then not evaluated at all (layer ④).
AlertThresholds resolveThresholds({
  double? userOv,
  double? userUv,
  double? userOt,
  TelemetrySample? reported,
  DeclaredCategory? category,
}) {
  final defaults = category == null ? null : kCategoryDefaults[category];
  final voltageMuted =
      kPowerBankWatchesTemperatureOnly && category == DeclaredCategory.powerBank;

  ResolvedThreshold pick(double? user, double? device, double? fallback) {
    if (user != null) return ResolvedThreshold(user, ThresholdSource.user);
    if (device != null) return ResolvedThreshold(device, ThresholdSource.device);
    if (fallback != null) {
      return ResolvedThreshold(fallback, ThresholdSource.appDefault);
    }
    return ResolvedThreshold.unavailable;
  }

  return AlertThresholds(
    ov: voltageMuted
        ? ResolvedThreshold.unavailable
        : pick(userOv, reported?.warnOv, defaults?.ov),
    uv: voltageMuted
        ? ResolvedThreshold.unavailable
        : pick(userUv, reported?.warnUv, defaults?.uv),
    ot: pick(userOt, reported?.warnOt, defaults?.ot),
  );
}
