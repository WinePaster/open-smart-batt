/// OpenSmartBatt — dashboard routing decision: the four-state answer to "which
/// layout, if any, may be drawn for the unit on the other end of this link?".
///
/// PURE Dart (no Flutter imports) so the routing rule is unit-testable without
/// a BLE stack or a widget tree.
///
/// ## Why this exists
///
/// Routing used to be a bool:
///
/// ```dart
/// return isPowerBank ? const PowerBankView() : const PackView();
/// ```
///
/// [ProductClass] has FOUR meaningful states for routing, so a bool silently
/// collapsed "we do not know yet" into "it is a pack" — and the pack layout
/// leads with a 12 V PVLT gauge. A power bank caught in that window had its
/// SINGLE-CELL voltage (3.79 V in the 2026-07-31 field report) drawn as a pack
/// terminal voltage, on a gauge whose own formula — `trunc((PVLT − 8.0) × 3.5)`
/// clamped to 0..28, PROTOCOL.md §8 — pins the needle at zero for any such
/// value. The screen was not merely unstyled; it was stating a false number.
///
/// FB-43's first fix (`7a0965c`) attacked this by finding a BETTER GUESS — seed
/// routing from the class stored for the device. That is correct as far as it
/// goes, and it stays. But it cannot help a unit with no stored class, which is
/// exactly what the field screenshot showed. What was missing was not a better
/// guess: it was the OPTION NOT TO GUESS.
library;

import 'product_class.dart';

/// How long [RoutingDecision.pending] must last before the placeholder is drawn
/// at all.
///
/// `0x10` answers the ordinary 1 Hz `#` poll (PROTOCOL.md §2), so a healthy
/// link resolves in about a second and the placeholder would otherwise be a
/// flash on every single connect. Suppressing it below this threshold costs
/// nothing: the pack layout is not drawn during the grace period either, so no
/// wrong number is ever shown — the area is simply empty.
///
/// Which value to use was settled as a product call, not by the distribution —
/// and it is worth recording that the distribution was ASKED first and declined
/// to answer.
///
/// A 36-connection sample once made 500 ms look strictly better: its slowest
/// `ready` → first `0x10` interval was 0.301 s, so 300 ms let roughly 1
/// connection in 36 flash the placeholder and 500 ms covered every one of them.
/// A later batch of 21 connections broke that reading. Its slowest interval is
/// **43.9 s** — same link, no disconnect, keep-alive writes timing out
/// underneath — so both thresholds score identically on it (1 of 21), and no
/// value in the hundreds of milliseconds would have changed that. The "0 of 36"
/// was a property of that sample, not of the constant.
///
/// 500 ms it is, chosen because the flash is the more annoying of the two
/// failure modes, not because the data prefers it. What the data does say is
/// where the real tail lives: see [kClassPendingTimeout].
const Duration kClassPendingGrace = Duration(milliseconds: 500);

/// How long [RoutingDecision.pending] must last before the placeholder stops
/// saying "identifying" and starts offering a way out.
///
/// Measured, not guessed — and deliberately far above the typical case. On
/// recent builds `ready` → first `0x10` is fast: across 21 connections from a
/// single day of field logs, p50 is 0.061 s and p90 0.120 s — the typical case
/// fits a hundred times over inside this timeout.
/// Six seconds is kept anyway, for two things those percentiles hide:
///
/// * The tail is real, not theoretical, and it is not an artefact of old
///   builds. The same 21-connection sample contains a **43.9 s** interval on a
///   current build, over a link that never disconnected — the keep-alive writes
///   were timing out and recovering underneath it the whole time. An older
///   build has a verified 54 s sample, and two connections elsewhere in the
///   corpus reached `ready` and then never received `0x10` at all. Two
///   independent samples an order of magnitude past this timeout is not a tail
///   anyone should trim toward.
/// * This is a DISPLAY timeout, not a give-up — a byte arriving afterwards
///   still overrides everything. So the two errors cost very different
///   amounts: offering an escape hatch over a link that was about to resolve
///   alarms the user for nothing, while offering it late only means a few
///   more seconds of "identifying".
const Duration kClassPendingTimeout = Duration(seconds: 6);

/// What the dashboard should draw for the current link.
enum RoutingDecision {
  /// Confirmed power bank (device-type `0x22`, or a stored class that can only
  /// have come from one — see the seed premise in `routing_seed_test.dart`).
  powerBank,

  /// A confirmed pack: [ProductClass.smartBattery] or
  /// [ProductClass.supercapacitor].
  ///
  /// Deliberately ONE state, not two: both share the pack shell today. When
  /// they are split, add `battery` / `capacitor` here — every `switch` on this
  /// enum is exhaustive, so the compiler will name each site that must choose
  /// rather than letting one of them default silently. Leaving that room open
  /// costs nothing today, which is why it is left open rather than pre-built.
  pack,

  /// No device-type byte has arrived yet and no stored class covers the gap.
  /// Nothing may be drawn that depends on the class — see [RoutingDecision].
  ///
  /// Normally brief: `0x10` rides the ordinary 1 Hz `#` keep-alive (PROTOCOL.md
  /// §2), not just the opening burst, so it usually lands within a second or
  /// two. It is UNBOUNDED when the write path is broken — the app keeps
  /// receiving telemetry while none of its polls get out (PROTOCOL.md §10.2),
  /// which is precisely the state that looks healthy and is not.
  pending,

  /// The unit answered with a device-type byte this build does not recognise.
  ///
  /// NOT the same as [pending], and the difference is the whole point of
  /// [PackClassResolver.sawDeviceType]: this is a resting state the user
  /// resolves by picking a class, so it must reach the normal pack shell with
  /// its "未分類（請指定）" chip rather than sit behind a placeholder.
  unclassified;

  /// The routing rule, in one place.
  ///
  /// * [resolved] — the class from the wire byte, else the saved-record seed
  ///   (`ConnectionController.resolvedClass`). A user's GUESS is never part of
  ///   this — the invariant that a layout is chosen by wire-derived facts and
  ///   by nothing else has held since the routing rule was first written, and
  ///   the seed is admissible only because a stored class is itself
  ///   wire-derived.
  /// * [sawDeviceType] — whether a byte arrived at all, recognised or not.
  static RoutingDecision from({
    required ProductClass resolved,
    required bool sawDeviceType,
  }) {
    switch (resolved) {
      case ProductClass.powerBank:
        return RoutingDecision.powerBank;
      case ProductClass.smartBattery:
      case ProductClass.supercapacitor:
        return RoutingDecision.pack;
      case ProductClass.unknown:
        // The one place the two "unknown"s are told apart.
        return sawDeviceType
            ? RoutingDecision.unclassified
            : RoutingDecision.pending;
    }
  }

  /// True while the class is genuinely undetermined — the only state in which
  /// the dashboard withholds a layout.
  bool get isPending => this == RoutingDecision.pending;
}
