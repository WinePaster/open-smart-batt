/// OpenSmartBatt — capture state marks.
///
/// A diagnostic log records what the DEVICE said. It has never recorded what
/// the USER was doing, and for several registers that is the only thing that
/// could resolve them: nothing in the stream distinguishes Type-A from Type-C,
/// charging from standby, or one protection state from another. Those fields
/// are unresolvable from passive captures no matter how many arrive.
///
/// A mark is one line the user writes into the log to say what they just did:
///
///     2026-07-29T16:20:03.123 EVT  # mark: pb_out_c_pd | Type-C PD out
///
/// The [code] is a stable ASCII identifier that tooling matches on. It is NEVER
/// translated and NEVER renamed — a hundred community members have to be
/// measuring with the same ruler, which is the whole point of not using free
/// text. The human label beside it follows the app locale and is ignored by
/// tooling.
library;

import 'product_class.dart';

/// A state a user can declare while capturing.
enum CaptureMark {
  // ---- power bank: the six-step differential script -----------------------
  // These correspond 1:1, in order, to the script already handed to testers,
  // so returning captures line up without translation.
  powerBankOutA('pb_out_a', ProductClass.powerBank),
  powerBankOutC5v('pb_out_c_5v', ProductClass.powerBank),
  powerBankOutCPd('pb_out_c_pd', ProductClass.powerBank),
  powerBankOutBoth('pb_out_a_c', ProductClass.powerBank),
  powerBankIn('pb_in', ProductClass.powerBank),
  powerBankIdle('pb_idle', ProductClass.powerBank),

  // ---- pack (battery / capacitor) ----------------------------------------
  // Observation only. Marks for deliberately driving a pack past its
  // over-voltage / over-temperature thresholds were designed and then dropped
  // by owner ruling: the subject is a battery in a vehicle, and FB-22 had just
  // demonstrated how wrong our reading of the protection flags could be.
  // Controlled fault tests are documented and guided directly instead.
  packIdle('pack_idle', ProductClass.smartBattery),
  packCharging('pack_charging', ProductClass.smartBattery),
  packLoad('pack_load', ProductClass.smartBattery),

  // ---- any device ---------------------------------------------------------
  note('note', null);

  const CaptureMark(this.code, this.appliesTo);

  /// Stable log identifier. Tooling matches this; it must never change.
  final String code;

  /// Product class this mark is offered for, or null for every class.
  ///
  /// [ProductClass.smartBattery] here means "a pack" — capacitors share the
  /// same marks, since the states being declared (idle / charging / loaded) are
  /// the same physical situations.
  final ProductClass? appliesTo;

  /// Marks worth offering for [cls]. An unknown class gets the generic ones
  /// only: offering power-bank steps for a unit we have not identified would
  /// invite exactly the mislabelled ground truth marks exist to prevent.
  static List<CaptureMark> forClass(ProductClass cls) => [
        for (final m in CaptureMark.values)
          if (m.appliesTo == null ||
              m.appliesTo == cls ||
              (m.appliesTo == ProductClass.smartBattery &&
                  cls == ProductClass.supercapacitor))
            m,
      ];

  /// The log line body: `mark: <code> | <label>`.
  ///
  /// [label] is display text and may be anything; [note] is the user's optional
  /// free text, which rides in the label position so [code] stays a closed,
  /// enumerable set.
  String logLine(String label, {String? note}) {
    final tail = (note != null && note.isNotEmpty) ? note : label;
    return 'mark: $code | $tail';
  }

  /// Closing line for a mark that had a defined end (used by the guided run).
  String endLogLine() => 'mark_end: $code';

  /// Recorded when a guided step is deliberately passed over, so an analyst can
  /// tell "the user skipped this" from "the data is missing" — the same
  /// distinction the export headers draw when they count what they left out.
  /// Silence is the one answer a capture must never give.
  static String skippedLogLine(CaptureMark m) => 'mark: skipped | ${m.code}';
}
