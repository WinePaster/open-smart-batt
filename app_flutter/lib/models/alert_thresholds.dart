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
///   ③ our default table, keyed on the WIRE's class  (§3.2.1, a fallback)
///        — the declaration only breaks the bike-vs-car tie (§7.5.6 C-1)
///   ④ nobody knows                             ⇒ do not evaluate, do not guess
///
/// …and sitting above all four, a DEVICE-level gate: a unit whose class we do
/// not recognise is not watched at all, whatever any layer could offer
/// (§7.5.6 C-2). See [AlertsDisabledReason].
///
/// 🔵 **What the DECLARATION may and may not do (design 0080 §7.5.1 and
/// §7.5.6, two rulings on 2026-08-22).** ~~Layer ③ is keyed on
/// [DeclaredCategory], and that is the whole of its involvement: it hands over
/// a NUMBER.~~ 🔴 **Narrowed hours later by §7.5.6 C-1**: layer ③ is keyed on
/// the wire's [ProductClass], and the declaration is now consulted for exactly
/// **one** question — a `0x02` battery's bike UV 11.0 versus car UV 12.0, the
/// one volt the wire genuinely cannot resolve. Whether a field is watched at
/// all — the power bank's two voltage rows — was already the wire's call.
/// Design 0066 therefore still needs no amendment, and stands further from the
/// line than it did an hour earlier: a declared value gates nothing, and now
/// barely numbers anything either. See [kPowerBankWatchesTemperatureOnly] for
/// the incident that forced the first half of that split and
/// [categoryDefaultsFor] for the second.
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
import 'product_class.dart';
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

/// Why the WHOLE unit is unwatched — design 0080 §7.5.6 C-2.
///
/// 🔴 **[ProductClass.unknown] ⇒ no warnings at all, no exceptions.** The
/// resolution stops before layer ① is consulted, so all three fields come back
/// [ThresholdSource.none] even when there is something to say. The owner ruled
/// out both of the back doors that suggest themselves, and they are named here
/// because each one WILL look like an obvious improvement to somebody later:
///
///   * the unit **did report a `0x2B`** — the normal look of new hardware, and
///     tempting because layer ② is per-unit evidence that needs no table. Still
///     no warning: we would be comparing a number we can read against a
///     quantity we cannot name. The power bank is the standing proof that
///     "voltage" is not one quantity across classes — PVLT there is a ~3.7 V
///     cell — so an unrecognised class makes 12.0 V neither a limit nor an
///     error, just an uninterpretable pair of digits;
///   * the **user typed a threshold themselves**. Same answer, and it is the
///     harder one to accept, because layer ① normally wins everything. But a
///     user typing "12.0" into a unit neither of us has identified is making
///     the same guess we just refused to make, and we would be the ones
///     ringing the alarm.
///
/// This is layer ④'s 不猜勝於猜錯 raised from the field to the device. Its price
/// is stated and accepted: a new hardware generation gets no warnings until
/// somebody captures its device-type byte — which is what `0x18` did for a full
/// day in 2026-08 — and `product_class.dart` grows one measured byte at a time
/// by design.
///
/// 🔑 **The two reasons are kept apart for the UI's sake** (§7.5.6 C-3). Every
/// connection passes through [deviceTypePending] for the first few frames, and
/// a screen that rendered "we cannot warn about this device" during those
/// frames would flash a false alarm about the alarms at every single connect.
/// Only [deviceTypeUnrecognised] is a lasting fact about the hardware and only
/// it should be shown. Callers holding a [TelemetrySample] could tell the two
/// apart themselves — `deviceType == null` is the whole test — but then every
/// call site would have to re-derive it, and the one that forgot would be the
/// one shipping the flash.
enum AlertsDisabledReason {
  /// Not disabled. The three fields mean what their own [ThresholdSource]s say.
  none,

  /// No device-type byte yet: the `0x10` frame has not arrived on this link, or
  /// there is no link (an offline saved device with no persisted class).
  ///
  /// Transient and expected. **Do not surface this in the UI** — see the enum
  /// doc.
  deviceTypePending,

  /// A device-type byte arrived and this build does not recognise it, and no
  /// persisted class stood in for it either.
  ///
  /// The durable case, and the one §7.5.6 C-3 puts on screen: switch disabled,
  /// "尚未辨識此裝置類型，無法提供警告". It is also the actionable one for us —
  /// it means a byte exists that `product_class.dart` should be taught.
  deviceTypeUnrecognised,
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
  const AlertThresholds({
    required this.ov,
    required this.uv,
    required this.ot,
    this.disabledReason = AlertsDisabledReason.none,
  });

  /// Every field on layer ④ — nobody could answer for any of the three, on a
  /// unit we nevertheless recognise.
  static const AlertThresholds none = AlertThresholds(
    ov: ResolvedThreshold.unavailable,
    uv: ResolvedThreshold.unavailable,
    ot: ResolvedThreshold.unavailable,
  );

  /// The unit itself is out of scope (§7.5.6 C-2) — three empty fields again,
  /// but for a reason that lives one level up and that the UI must render
  /// differently: [none] says "we have no numbers for this device", this says
  /// "we do not know what this device is".
  const AlertThresholds.unwatched(this.disabledReason)
      : ov = ResolvedThreshold.unavailable,
        uv = ResolvedThreshold.unavailable,
        ot = ResolvedThreshold.unavailable;

  final ResolvedThreshold ov;
  final ResolvedThreshold uv;
  final ResolvedThreshold ot;

  /// [AlertsDisabledReason.none] unless the device-level gate fired.
  ///
  /// Carried on the value rather than returned beside it because P2 stores one
  /// [AlertThresholds] per device and diffs it; a reason travelling separately
  /// is the "one piece of state, two places" shape this repo has three logged
  /// incidents of.
  final AlertsDisabledReason disabledReason;

  /// True when the three empty fields are the device-level gate (§7.5.6 C-2)
  /// rather than four layers that happened to come up empty.
  ///
  /// [hasAny] is false in both cases and cannot tell them apart, which is fine
  /// for the evaluator (both mean "evaluate nothing") and NOT fine for the
  /// screen: only this one licences the "無法提供警告" copy, and only when
  /// [disabledReason] is [AlertsDisabledReason.deviceTypeUnrecognised].
  bool get isDeviceUnwatched => disabledReason != AlertsDisabledReason.none;

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
      other.ot == ot &&
      other.disabledReason == disabledReason;

  @override
  int get hashCode => Object.hash(ov, uv, ot, disabledReason);

  @override
  String toString() => isDeviceUnwatched
      ? 'AlertThresholds.unwatched(${disabledReason.name})'
      : 'AlertThresholds(ov: $ov, uv: $uv, ot: $ot)';
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
/// 🔵 **A table of NUMBERS — no longer the layer's index** (design 0080
/// §7.5.6 C-1). ~~Still keyed on [DeclaredCategory] after the 2026-08-22
/// ruling, and that is deliberate (§7.5.1.1 D): a map from what the owner
/// tapped to three numbers does not violate design 0066, because a number is
/// not a gate.~~ 🔴 The second ruling of the same day took the LOOKUP away from
/// the declaration entirely: [categoryDefaultsFor] picks the row from the
/// wire's [ProductClass] and asks the declaration only to break the one tie the
/// wire cannot — a bike battery's UV 11.0 against a car battery's 12.0, a
/// distinction `0x02` does not carry (see `declared_device_model.dart` on why
/// the field exists at all).
///
/// The rows keep their [DeclaredCategory] keys anyway, and that is not
/// leftovers: this is the vocabulary the numbers were tabulated in (§3.2.1),
/// two of the five rows have no wire class of their own to be keyed on, and a
/// map is not a policy. The policy moved out; the measurements stayed.
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
/// 🔴 **Keyed on the WIRE's [ProductClass], never on [DeclaredCategory]**
/// (design 0080 §7.5.1 / §7.5.1.1 A, owner ruling 2026-08-22). The first cut of
/// [resolveThresholds] asked `category == DeclaredCategory.powerBank`, and that
/// was wrong twice over:
///
///   * it broke design 0066's standing rule, written verbatim in
///     `declared_device_model.dart`: **a declared value gates nothing and
///     displays nothing** — because a user who taps the wrong entry must not
///     end up somewhere we cannot reproduce from their bug report;
///   * and it broke it at a price higher than 0066 was even arguing about. What
///     a mis-tap switched off there is not a screen, it is **a set of alarms**.
///     Declare a power bank as a car battery and its ~3.7 V cell reading is
///     measured against UV 12.0 V — a permanent under-voltage warning that the
///     owner cannot clear and that we would have manufactured out of a dropdown.
///     Declare a car battery as a power bank and its real under-voltage alarm is
///     silently switched off.
///
/// Device-type `0x22` is measured, not asserted (`product_class.dart`,
/// PROTOCOL.md §8.2/§9), so keying on it also puts this back on the standing
/// invariant next door: **gating follows the wire, routing follows the wire.**
///
/// ⚠️ **Deliberately applied AFTER layers ① and ②, not instead of them** — see
/// [resolveThresholds]. The design specifies the UI will not offer the two
/// voltage rows for this class at all (§3.2.2, "不是顯示成灰色停用"), so a
/// user-set voltage should be unreachable; this constant makes the pure
/// function safe anyway rather than trusting that no future screen, import or
/// migration ever puts a number in those columns. Reason 2 above does not stop
/// being true because a row exists.
///
/// 🔴 ~~⚠️ **Silence is not the default when the class is unknown**
/// (§7.5.1.1 C). A unit whose `0x10` has not arrived, or whose byte this build
/// does not recognise, is [ProductClass.unknown] and its voltages are evaluated
/// normally: nothing has said it is a power bank, and suppressing an alarm on
/// the strength of no evidence is the same mistake in the other
/// direction.~~ — **overruled the same day by §7.5.6 C-2**, which stops the
/// resolution for an unknown class before this constant is ever read. The
/// argument above was not shown to be wrong so much as answering a question
/// that no longer arises: it asked WHICH alarms to run on an unidentified unit,
/// and the ruling's answer is none of them. See [AlertsDisabledReason].
const bool kPowerBankWatchesTemperatureOnly = true;

/// Layer ③, indexed by the WIRE (design 0080 §7.5.6 C-1). Null ⇒ layer ③ says
/// nothing and each field falls through to layer ④.
///
/// 🔑 **The class is the key; the declaration is a tie-breaker for one class.**
/// The first cut of this layer keyed the whole table on [DeclaredCategory] and
/// then, after §7.5.1.1 B, refused it whenever the wire contradicted it. Both
/// halves of that failed together on the device they were meant to protect: a
/// power bank whose owner had declared nothing got no OT (no declaration ⇒ no
/// row), and one whose owner had declared it a car battery got no OT either
/// (contradicted ⇒ no row) — so the class the ruling had just decided to watch
/// for heat was, for every user who had not filled in an optional form,
/// watched for nothing. Keying on the wire fixes both at once, and the
/// contradiction check disappears rather than being fixed: a declaration that
/// does not select rows cannot select a wrong one.
///
/// Per class:
///
///   * [ProductClass.powerBank] — one row, OT only. The declaration is not
///     read, so a mis-tap cannot cost this unit its only alarm.
///   * [ProductClass.supercapacitor] — one row, because the bike and car
///     capacitor rows are **identical** (§3.2.1). The wire cannot separate the
///     two (both `0x17`/`0x18`) and here it does not need to: there is nothing
///     to separate.
///   * [ProductClass.smartBattery] — the wire is **not enough**. Bike UV 11.0
///     against car UV 12.0 is a real 1 V difference, so an absent declaration
///     (or one naming a non-battery, which is the same thing as contradicting
///     `0x02`) leaves layer ③ silent. Layers ① and ② are untouched by this —
///     the unit's own `0x2B` and the user's own number still answer.
///   * [ProductClass.unknown] — unreachable from [resolveThresholds], which
///     returns at the device-level gate first (§7.5.6 C-2). Handled anyway so
///     the switch is exhaustive and so a direct caller gets the safe answer.
///
/// 📌 **The one gap left — the battery with no declaration — is nearly empty in
/// practice.** `tools/fb.py counter 0x2B` (2026-08-22) has 194 batch×device
/// rows covering batteries AND capacitors; the only class that never reports a
/// `0x2B` is the power bank, which is precisely the class that needs no
/// declaration here. A battery therefore almost always answers on layer ②, long
/// before layer ③ is asked.
CategoryAlertDefaults? categoryDefaultsFor({
  required ProductClass wireClass,
  DeclaredCategory? category,
}) {
  switch (wireClass) {
    case ProductClass.powerBank:
      return kCategoryDefaults[DeclaredCategory.powerBank];
    case ProductClass.supercapacitor:
      // Either capacitor row would do — they are equal by construction, and
      // `alert_thresholds_test.dart` asserts that they stay equal. Picking one
      // arbitrarily is honest here; inventing a difference to justify reading
      // the declaration would not be.
      return kCategoryDefaults[DeclaredCategory.carCapacitor];
    case ProductClass.smartBattery:
      if (category == DeclaredCategory.carBattery ||
          category == DeclaredCategory.motorcycleBattery) {
        return kCategoryDefaults[category];
      }
      return null;
    case ProductClass.unknown:
      return null;
  }
}

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
/// that class of mistake costs. Null when nothing is on the link. Its
/// `deviceType` is also the freshest source of [wireClass], below.
///
/// [category] is what the owner declared (design 0066). After §7.5.6 C-1 it is
/// a **tie-breaker, not an index**: it is read only when the wire says `0x02`,
/// and only to pick the bike row (UV 11.0) over the car row (UV 12.0). A power
/// bank or a capacitor does not consult it at all — one row each. Null is the
/// common case (the declaration is optional) and costs those two classes
/// nothing.
/// 🔑 It still supplies **numbers only**, and now fewer of them: which fields
/// exist, and whether anything is evaluated at all, are [wireClass]'s. That is
/// why design 0066 stands unamended (§7.5.1.1 D) and stands further from the
/// line than it did an hour earlier.
///
/// [wireClass] is what the WIRE says this unit is, defaulting to
/// [ProductClass.unknown] so an unclassified unit needs no special call site.
/// Callers holding a live sample may leave it alone (the sample's `deviceType`
/// wins anyway); callers resolving an OFFLINE saved device pass the persisted
/// `SavedDevice.productClass`, which is the only evidence available with no
/// link open.
///
/// It decides three things, and none of them is a number:
///
///   1. **whether the unit is watched at all** — [ProductClass.unknown] returns
///      [AlertThresholds.unwatched] before layer ① is even looked at
///      (§7.5.6 C-2, no exceptions — see [AlertsDisabledReason]);
///   2. **whether voltage is watched** — see
///      [kPowerBankWatchesTemperatureOnly] (§7.5.1.1 A);
///   3. **which row layer ③ reads** — [categoryDefaultsFor] (§7.5.6 C-1).
///      ~~and whether layer ③ may speak at all: a declaration the wire
///      CONTRADICTS supplies nothing (§7.5.1.1 B)~~ 🔴 that check is gone, not
///      relaxed. It was a guard against the declaration selecting a wrong row,
///      and the declaration no longer selects rows. Its intent survives inside
///      [categoryDefaultsFor]: a category that disagrees with `0x02` is simply
///      not one of the two rows a battery may take.
///
/// Returns [ThresholdSource.none] with a null value for any field none of the
/// layers could answer. That field is then not evaluated at all (layer ④).
AlertThresholds resolveThresholds({
  double? userOv,
  double? userUv,
  double? userOt,
  TelemetrySample? reported,
  DeclaredCategory? category,
  ProductClass wireClass = ProductClass.unknown,
}) {
  // The live byte outranks the argument: `0x10 b4` is what THIS link just said,
  // while [wireClass] is a value persisted in some earlier session. They agree
  // in every ordinary case; the ordering matters only for a unit whose class
  // changed under us (a re-used MAC, a restored backup), where the thing in
  // front of us is the better evidence. Before the frame arrives
  // `fromDeviceType(null)` is [ProductClass.unknown] and the stored answer
  // stands in, which is what keeps an offline saved device resolvable at all.
  final live = ProductClass.fromDeviceType(reported?.deviceType);
  final wire = live == ProductClass.unknown ? wireClass : live;

  // 🔴 §7.5.6 C-2 — the device-level gate, and it is deliberately the FIRST
  // statement after the class is known. Everything below this line interprets
  // numbers in the light of what the unit is; if that is not known, there is
  // nothing to interpret them in the light of. Placing the check here rather
  // than folding it into `pick` is what makes "no exceptions" structural: a
  // later edit cannot let a user value through by accident, because by then the
  // function has already returned.
  if (wire == ProductClass.unknown) {
    // `deviceType == null` is the whole difference between "the 0x10 has not
    // arrived yet" and "it arrived and we do not know the byte" — see
    // [AlertsDisabledReason] for why the UI must not conflate them. Note this
    // reads the RAW byte, not `live`: an unrecognised byte and an absent one
    // both map to [ProductClass.unknown], which is exactly the distinction the
    // class enum throws away.
    return AlertThresholds.unwatched(reported?.deviceType == null
        ? AlertsDisabledReason.deviceTypePending
        : AlertsDisabledReason.deviceTypeUnrecognised);
  }

  // §7.5.1.1 A — the suppression reads the wire. See
  // [kPowerBankWatchesTemperatureOnly] for why this is not `category`.
  final voltageMuted =
      kPowerBankWatchesTemperatureOnly && wire == ProductClass.powerBank;

  // §7.5.6 C-1 — layer ③ is indexed by the wire; `category` only breaks the
  // battery's bike/car tie. The former `declaredWireMismatch` guard here is
  // gone: it existed to stop a contradicted declaration selecting a row, and
  // the declaration no longer selects rows.
  final defaults = categoryDefaultsFor(wireClass: wire, category: category);

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
