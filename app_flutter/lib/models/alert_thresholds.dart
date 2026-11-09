/// OpenSmartBatt — where an alert threshold comes from (design 0080 §3.1 /
/// §3.2, superseded in part by design 0098).
///
/// 🔵 **2026-11-09 ruling (design 0098): the thresholds are the APP's, fixed,
/// and `0x2B` is out.** Owner, verbatim: 「0x2B 我們定義為保護參數/保護數據…
/// 也不放app內, 而我們現在app內的警示 應該是 >=15V警示 或小於等於11.5V,
/// 過溫80度」 and 「app顯示照我們現在設定的, 至於2B本身的數值那個就是電池內的
/// 保護參數 這個不異動」. So:
///
///   * `0x2B` is the unit's internal PROTECTION setting. It is not a warning
///     threshold, it is not shown, and nothing here reads it (layer ② below is
///     gone). The app never writes it either — the write path was deleted.
///   * batteries and capacitors share ONE row, [kAppAlertThresholds]: OV
///     **≥ 15.0 V**, UV **≤ 11.5 V**, OT **≥ 80 °C** (inclusive on all three —
///     see `AlertEvaluator._isBreaching`). The power bank keeps OT 50 °C only.
///   * the row is picked by the WIRE's class alone; the declaration is no
///     longer consulted for anything (bike and car batteries now have the same
///     numbers, so the one tie it used to break is gone).
///   * a threshold no longer needs a link: an OFFLINE saved unit resolves from
///     its persisted class.
///
/// The design-0080 text below is kept as history, struck where it no longer
/// holds, per this repo's convention.
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
///   ~~① what the USER set for THIS unit          (most specific, always wins)~~
///   ~~② what THIS unit reported in its `0x2B`    (per-unit factory setting)~~
///        🔵 gone 2026-11-09 (design 0098) — `0x2B` is a protection parameter
///   ③ our table, keyed on the WIRE's class     (design 0098: THE source)
///        — ~~the declaration only breaks the bike-vs-car tie (§7.5.6 C-1)~~
///   ④ nobody knows                             ⇒ do not evaluate, do not guess
///
/// 🔵 **2026-08-25 ruling (FB-100, design 0080 §0.3): the thresholds are
/// READ-ONLY and layer ① is gone.** The dealer read the editable rows as the
/// app CHANGING the hardware's protection points, and the owner ruled the way
/// out is to stop offering the edit at all: read `0x2B`, fall back to our
/// table, and never take a number from the user. Two defects went with it —
/// the input dialog had no bounds of any kind (an under-voltage of 5.0 V
/// silenced the alarm with nothing on screen saying so), and nowhere did the
/// screen state that editing never reached the device. What the user keeps is
/// the per-unit switch and the two mutes; what they lose is asking to be warned
/// EARLIER than the factory point, which design 0080 §4.1 had counted as the
/// reason not to write `0x2B` back. That trade is the ruling.
///
/// 🔑 **The ①–④ numbering below is kept exactly as design 0080 §3.1 wrote it,
/// with ① struck out rather than closed up.** Renumbering the survivors to
/// ①②③ would have been tidier here and wrong everywhere else: the same four
/// numbers name the same four things in the design doc, in
/// `alert_thresholds_lookup.dart` and in the tests, and a file that quietly
/// renumbers them is the "one fact, two versions" failure this repo keeps
/// logging. There is no layer ①; the other three keep their names.
///
/// …and sitting above ~~all four~~ the three that are left, a DEVICE-level
/// gate: a unit whose class we do not recognise is not watched at all, whatever
/// any layer could offer (§7.5.6 C-2). See [AlertsDisabledReason].
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
/// ~~[categoryDefaultsFor]~~ (now [appThresholdsFor]) for the second.
///
/// 🔵 **2026-11-09: the paragraph below argued for a layer that no longer
/// exists.** It is kept because its facts are still true — `0x2B` really is
/// per unit — and design 0098 did not dispute them: it decided that a per-unit
/// PROTECTION point is not what the app should warn on.
///
/// ~~🔴 **Why ② outranks ③, stated once because it is the load-bearing claim.**~~
/// `0x2B` is per-UNIT, not per-category: `tools/fb.py counter 0x2B` (2026-08-22)
/// reports 194 batch×device rows, every one of them `uniq=1` — a unit always
/// reports the same triple — while the SAME category spreads over several
/// triples (car batteries alone show five). Across the corpus that is 12 distinct
/// values over 26 pieces of hardware. So the unit's own answer is evidence and
/// our table is an inference, and the gap between them is not small: the third
/// generation capacitor (`0x10`=`0x18`) leaves the factory with OV = 16.0 V,
/// **1.2 V above** what ~~`kCategoryDefaults`~~ would say for a capacitor. Rank the
/// table first and every one of those units gets warned about on a good day.
///
/// ## Per FIELD, not per unit (§3.1)
///
/// ~~A user who typed a UV must keep the device's OV and OT.~~ 🔵 The original
/// reason for per-field resolution left with layer ① (2026-08-25), but the rule
/// itself stays, because the two surviving layers still disagree field by
/// field: a power bank reports no `0x2B` at all and takes its OT from the table
/// while having no OV/UV to take, and a unit whose `0x2B` has not yet arrived
/// resolves nothing while the table can still answer. Hence [ResolvedThreshold]
/// carries its own [ThresholdSource] — one badge per row on screen, not one per
/// unit.
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

  /// The quantity this kind judges, out of [s], or null when this frame said
  /// nothing about it.
  ///
  /// 🔑 **One extractor, three readers** (P3). The state machine advances on
  /// it, the detail page's event banner prints it, and the notification body
  /// quotes it — and if any two of those disagreed about which field OV reads,
  /// the user would be shown a number that is not the one that woke them up.
  /// It lives on the enum rather than in the evaluator because the evaluator is
  /// no longer the only caller.
  ///
  /// ⚠️ **Null means "this frame did not mention it", never "it is fine".** A
  /// `0x21` temperature frame carries no PVLT, so both voltage kinds read null
  /// on it several times a second; a caller that treated that as a cleared
  /// breach would let any interleaved selector reset a real one.
  double? readingIn(TelemetrySample s) => switch (this) {
        AlertKind.overVoltage || AlertKind.underVoltage => s.pvlt,
        AlertKind.overTemperature => s.temperatureC?.toDouble(),
      };

  /// Is [reading] past [limit] in the direction this kind cares about?
  ///
  /// 🔵 **INCLUSIVE — design 0098, owner ruling 2026-11-09** (「>=15V警示 或
  /// 小於等於11.5V」, and 「大於等於」 for 80 °C): OV `reading >= limit`, UV
  /// `reading <= limit`, OT `reading >= limit`. ~~Strict `>` / `<`~~ before.
  ///
  /// 🔑 **The ONE comparison.** `AlertEvaluator` (the notification) and
  /// `readingBreachesThreshold` (the dashboard's advisory line) both call this,
  /// so design 0080 §3.8's "the screen and the notification must agree at the
  /// boundary" is structural rather than two hand-kept copies.
  bool breaches(double reading, double limit) =>
      this == AlertKind.underVoltage ? reading <= limit : reading >= limit;
}

/// The notification id for one (unit, kind) — design 0080 §3.5.2.
///
/// 🔴 **It must be the same integer tomorrow, and on the next launch.** That is
/// the entire de-duplication mechanism: the OS replaces a notification whose id
/// it already has, so "remind me again in 15 minutes" updates one row instead
/// of stacking a second, and a phone showing an alert from before a restart
/// gets it UPDATED rather than doubled.
///
/// ⚠️ Hence FNV-1a over the text rather than [Object.hash] or [String.hashCode]:
/// Dart makes no promise that those are stable across runs or across
/// implementations, and the failure they would produce is silent — a slowly
/// growing pile of notifications about one battery, on the one device nobody
/// tests restarts on.
///
/// Masked to 31 bits: Android's id is a Java `int`, and a negative one is legal
/// but pointlessly hard to read in a bug report.
int alertNotificationId(String deviceId, AlertKind kind) {
  var hash = 0x811c9dc5;
  for (final unit in '$deviceId#${kind.name}'.codeUnits) {
    hash = (hash ^ unit) * 0x01000193;
    hash &= 0xffffffff; // Dart ints are 64-bit; keep the FNV-32 arithmetic
  }
  return hash & 0x7fffffff;
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
  // 🔵 **`user` removed 2026-08-25 (FB-100).** ~~Layer ① — the user set this
  // for this unit.~~ The thresholds are read-only now, so there is no source
  // that could produce it; the `saved_devices.alert_ov/uv/ot` columns survive
  // the removal DORMANT (see [SavedDevice.alertOv]) and nothing reads them.

  // 🔵 **`device` removed 2026-11-09 (design 0098).** ~~Layer ② — the unit
  // itself reported it in `0x2B`.~~ `0x2B` is the unit's protection setting,
  // not a warning threshold, and nothing reads it any more.

  /// Layer ③ — the app's own table, [kAppAlertThresholds]. Since design 0098
  /// the only source a value can have.
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
/// resolution ~~stops before layer ① is consulted~~ stops before any layer is
/// consulted (2026-08-25: there is no layer ① left to stop before — the gate
/// itself is unchanged), so all three fields come back
/// [ThresholdSource.none] even when there is something to say. The owner ruled
/// out the back door that suggests itself, and it is named here because it WILL
/// look like an obvious improvement to somebody later:
///
///   * the unit **did report a `0x2B`** — the normal look of new hardware, and
///     tempting because layer ② is per-unit evidence that needs no table. Still
///     no warning: we would be comparing a number we can read against a
///     quantity we cannot name. The power bank is the standing proof that
///     "voltage" is not one quantity across classes — PVLT there is a ~3.7 V
///     cell — so an unrecognised class makes 12.0 V neither a limit nor an
///     error, just an uninterpretable pair of digits;
///   * ~~the **user typed a threshold themselves**. Same answer, and it is the
///     harder one to accept, because layer ① normally wins everything.~~ 🔵
///     Moot since 2026-08-25 — there is no user layer to let through. The
///     ruling that removed it did not weaken this gate; it removed the only
///     back door that was ever hard to refuse.
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

  /// A device-type byte arrived and this build does not recognise it.
  ///
  /// 🔵 **§7.5.7: a persisted class does NOT rescue this** (~~"and no persisted
  /// class stood in for it either"~~). An unrecognised byte is the unit telling
  /// us it is something we cannot name, and that statement is newer than any
  /// record of an earlier session.
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

/// One row of [kAppAlertThresholds] (design 0098).
class CategoryAlertDefaults {
  const CategoryAlertDefaults({this.ov, this.uv, this.ot});

  /// Volts; null means this category gets no over-voltage default.
  final double? ov;

  /// Volts; null means this category gets no under-voltage default.
  final double? uv;

  /// Degrees Celsius.
  final double? ot;
}

/// The app's warning thresholds — design 0098, owner ruling 2026-11-09.
///
/// 🔑 **The app's numbers, by ruling — not measurements, not the unit's.**
/// Until 2026-11-09 this was design 0080's FALLBACK table (layer ③), filled
/// with the most common `0x2B` per category and outranked by the unit's own
/// `0x2B`. Design 0098 inverted that: `0x2B` is the unit's internal protection
/// setting and is not read here at all, and these rows are what the app warns
/// on, for every unit of the class.
///
/// | class          | OV        | UV        | OT        |
/// |----------------|-----------|-----------|-----------|
/// | smartBattery   | ≥ 15.0 V  | ≤ 11.5 V  | ≥ 80 °C   |
/// | supercapacitor | ≥ 15.0 V  | ≤ 11.5 V  | ≥ 80 °C   |
/// | powerBank      | —         | —         | ≥ 50 °C   |
///
/// ~~The previous table, keyed on [DeclaredCategory]: car battery 15.0 / 12.0 /
/// 80, motorcycle battery 15.0 / 11.0 / 80, capacitor 14.8 / 11.5 / 100.~~ The
/// capacitor's 100 °C was the class-blind `b6 + 60` decode that the vendor
/// engineering app's own screen refutes (`TelemetryDecoder.warnOtFor`).
///
/// Keyed on the WIRE's [ProductClass]: the bike/car split was the only reason
/// the declaration was ever consulted, and with one battery row it has no
/// question left to answer. [ProductClass.unknown] has no row by design — see
/// [AlertsDisabledReason].
const Map<ProductClass, CategoryAlertDefaults> kAppAlertThresholds =
    <ProductClass, CategoryAlertDefaults>{
  ProductClass.smartBattery: CategoryAlertDefaults(ov: 15.0, uv: 11.5, ot: 80),
  ProductClass.supercapacitor:
      CategoryAlertDefaults(ov: 15.0, uv: 11.5, ot: 80),
  // 🔴 No `ov` / `uv` — see [kPowerBankWatchesTemperatureOnly].
  ProductClass.powerBank: CategoryAlertDefaults(ot: kPowerBankOtDefaultC),
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
/// and nothing more. ~~This is why it resolves as [ThresholdSource.appDefault]
/// and never as `ThresholdSource.device`, and why §3.2.2 requires the screen to
/// say "App 預設" beside it~~ — 🔵 since design 0098 every threshold is the
/// app's, and the per-row source badge was removed by ruling (Q3, 2026-11-09).
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

/// The app's row for [wireClass] (design 0098). Null for
/// [ProductClass.unknown], which [resolveThresholds] never asks about — it
/// returns at the device-level gate first (§7.5.6 C-2).
///
/// ~~`categoryDefaultsFor({wireClass, category})`~~ — renamed and narrowed
/// 2026-11-09. Its `category` parameter existed only to pick the bike row
/// (UV 11.0) over the car row (UV 12.0); design 0098 gives both the same UV, so
/// the declaration has nothing left to decide.
CategoryAlertDefaults? appThresholdsFor(ProductClass wireClass) =>
    kAppAlertThresholds[wireClass];

/// Resolve all three thresholds for ONE unit, per field, per design 0080 §3.1.
///
/// 🔵 **2026-08-25 (FB-100): the three `userOv`/`userUv`/`userOt` parameters are
/// gone.** ~~[userOv] / [userUv] / [userOt] are layer ①: what the owner typed
/// for this unit (`saved_devices.alert_ov/uv/ot`, P2).~~ The thresholds are
/// read-only; the columns are still in schema v22 and are simply never read
/// (see [SavedDevice.alertOv] for why they were left rather than dropped).
///
/// [reported] is the live sample, read for ONE thing: its `deviceType`, the
/// freshest evidence of the class (below). 🔵 **2026-11-09 (design 0098):**
/// ~~it was layer ②, the unit's own `0x2B`~~ — its `warnOv` / `warnUv` /
/// `warnOt` are never read here; `0x2B` is a protection parameter.
///
/// ~~[category] is what the owner declared (design 0066)… a tie-breaker…~~ 🔵
/// Removed 2026-11-09: with one battery row there is no tie to break, so the
/// declaration plays no part in alerts at all.
///
/// [wireClass] is what the WIRE says this unit is, defaulting to
/// [ProductClass.unknown] so an unclassified unit needs no special call site.
/// Callers holding a live sample may leave it alone (the sample's `deviceType`
/// wins anyway); callers resolving an OFFLINE saved device pass the persisted
/// `SavedDevice.productClass`, which is the only evidence available with no
/// link open.
/// 🔵 **It stands in only where there is NO live byte** (§7.5.7). A byte that
/// arrived and was not recognised overrules it outright — see the gate in the
/// body and [AlertsDisabledReason.deviceTypeUnrecognised].
///
/// It decides everything (design 0098), in this order:
///
///   1. **whether the unit is watched at all** — [ProductClass.unknown] returns
///      [AlertThresholds.unwatched] before any layer is even looked at
///      (§7.5.6 C-2, no exceptions — see [AlertsDisabledReason]);
///   2. **whether voltage is watched** — see
///      [kPowerBankWatchesTemperatureOnly] (§7.5.1.1 A);
///   3. **which row applies** — [appThresholdsFor].
///      ~~and whether layer ③ may speak at all: a declaration the wire
///      CONTRADICTS supplies nothing (§7.5.1.1 B)~~ 🔴 that check is gone, not
///      relaxed. It was a guard against the declaration selecting a wrong row,
///      and the declaration no longer selects rows — since design 0098 it is
///      not read here at all.
///
/// Returns [ThresholdSource.none] with a null value for any field none of the
/// layers could answer. That field is then not evaluated at all (layer ④).
AlertThresholds resolveThresholds({
  TelemetrySample? reported,
  ProductClass wireClass = ProductClass.unknown,
}) {
  // 🔵 §7.5.7 (third ruling of 2026-08-22) — the raw byte is kept, not just the
  // class it maps to, because the two ways of arriving at [ProductClass.unknown]
  // are NOT the same fact and the enum cannot tell them apart:
  //
  //   * an UNRECOGNISED byte is EVIDENCE. The unit in front of us is saying
  //     "I am something", and this build cannot name it. That statement is
  //     newer than anything a previous session wrote down, so it OUTRANKS the
  //     persisted class — a firmware bump that changes the byte is exactly the
  //     case where the old record is the wrong answer, and it is also what a
  //     new hardware generation looks like (`0x18` read as unknown for a full
  //     day in 2026-08);
  //   * an ABSENT byte is NO EVIDENCE at all. The `0x10` has not arrived on
  //     this link, or there is no link. Nothing has been contradicted, so the
  //     persisted class stands in — which is what keeps an offline saved
  //     device resolvable, and what stops every connect flashing "無法提供警告"
  //     during its first frames.
  //
  // ~~`final wire = live == ProductClass.unknown ? wireClass : live;`~~ 🔴 that
  // single line was the gap: it let case one fall through to case two, so a
  // device whose byte we no longer recognise kept being evaluated on the
  // strength of an old record.
  final liveByte = reported?.deviceType;
  final live = ProductClass.fromDeviceType(liveByte);

  // 🔴 §7.5.6 C-2 + §7.5.7 — the device-level gate, and it is deliberately the
  // FIRST thing after the class is known. Everything below this line interprets
  // numbers in the light of what the unit is; if that is not known, there is
  // nothing to interpret them in the light of. Placing the check here rather
  // than folding it into `pick` is what makes "no exceptions" structural: a
  // later edit cannot let a user value through by accident, because by then the
  // function has already returned.
  if (liveByte != null && live == ProductClass.unknown) {
    // Evidence beats the record: no `wireClass` fallback on this branch, by
    // ruling, even when the persisted class is a perfectly good one.
    return const AlertThresholds.unwatched(
        AlertsDisabledReason.deviceTypeUnrecognised);
  }

  // No byte yet ⇒ the persisted class is the only evidence there is.
  final wire = liveByte == null ? wireClass : live;
  if (wire == ProductClass.unknown) {
    // Only reachable with no byte AND no persisted class, so the reason is
    // always the transient one — see [AlertsDisabledReason] for why the UI must
    // not conflate it with the durable case above.
    return const AlertThresholds.unwatched(
        AlertsDisabledReason.deviceTypePending);
  }

  // §7.5.1.1 A — the suppression reads the wire. See
  // [kPowerBankWatchesTemperatureOnly] for why this is not `category`.
  final voltageMuted =
      kPowerBankWatchesTemperatureOnly && wire == ProductClass.powerBank;

  // Design 0098 — the app's row for the wire's class, and nothing else.
  // 🔴 `reported?.warnOv` / `warnUv` / `warnOt` are deliberately NOT read: `0x2B`
  // is the unit's protection setting (ruling 2026-11-09). A test pins this —
  // a unit reporting `402c2814` (OV 16.0) still resolves OV 15.0.
  final row = appThresholdsFor(wire);

  ResolvedThreshold pick(double? value) => value == null
      ? ResolvedThreshold.unavailable
      : ResolvedThreshold(value, ThresholdSource.appDefault);

  return AlertThresholds(
    ov: voltageMuted ? ResolvedThreshold.unavailable : pick(row?.ov),
    uv: voltageMuted ? ResolvedThreshold.unavailable : pick(row?.uv),
    ot: pick(row?.ot),
  );
}

// ---------------------------------------------------------------------------
// Value formatting — one pair of formatters for the screen AND the notification
// ---------------------------------------------------------------------------
//
// 🔵 **P3 moved these down from `ui/alerts/alert_settings_page.dart`.** They
// were a UI concern while only the settings screen printed a threshold; the
// notification body prints the same two quantities beside each other
// (「目前 10.82 V，門檻 11.00 V」) and is built on the telemetry path, with no
// widget in sight. Keeping a second copy up there is how the row and the alarm
// end up disagreeing in the last digit about the same number.

/// Two decimals, matching how every other voltage on this app's screens is
/// rendered.
String formatVolts(double v) => v.toStringAsFixed(2);

/// 🔴 **Always °C, whatever `TempUnit` the user picked, and this is a known
/// deviation worth stating.** The thresholds are defined in °C (design 0098),
/// and the settings screen shows a limit and
/// the live reading side by side — converting one and not the other would be a
/// defect, and converting both would make the value the user TYPES a converted
/// quantity that has to survive a round trip through a byte-resolution field.
/// Design 0080 does not rule on it; the mockup is in °C throughout, and this
/// follows the mockup rather than inventing a rule.
String formatCelsius(double v) => v.toStringAsFixed(0);
