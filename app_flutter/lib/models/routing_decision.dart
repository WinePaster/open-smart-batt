/// OpenSmartBatt — dashboard routing decision (design 0025).
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
const Duration kClassPendingGrace = Duration(milliseconds: 300);

/// How long [RoutingDecision.pending] must last before the placeholder stops
/// saying "identifying" and starts offering a way out.
///
/// ⚠️ **PROVISIONAL.** Nobody has measured `ready` → first `0x10` on real
/// hardware; the interval does not appear anywhere in the corpus. Design 0025
/// T0 emits a `class-resolve:` line carrying exactly that number so the next
/// round of field logs can replace this guess with a measurement. Until then
/// this is deliberately generous — being slow to offer an escape hatch is a
/// far cheaper error than showing one over a link that was about to resolve.
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
  /// enum is exhaustive, so the compiler will name each site that must choose.
  /// (design 0025 §7 Q3.)
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
  ///   this: design 0001 §3.1, still intact.
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
