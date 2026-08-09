/// OpenSmartBatt — the display-module registry (design 0034 Phase 0).
///
/// One place that answers "what does the dashboard show for THIS product
/// class". Before this file the answer was six separate `packLabel` comparisons
/// scattered through [PackScaffold] (`pack_view.dart`): the gauge's SOH
/// sub-line, the current track, the capacitor-only SVLT track, the chart
/// footnote, the current readout and the SOH readout. Six places to read before
/// you could state one fact, and — the reason it matters — six places for a
/// seventh class-conditional to be added to five of them.
///
/// This is a DECLARATION layer only. It changes nothing on screen: every entry
/// below reproduces, value for value, what the views already drew on
/// 2026-08-04. Customisable layouts (design 0034 Phase 3+) are built on top of
/// it later; getting the declaration right first is what stops that work from
/// having to be done twice.
///
/// ## Two kinds of condition, kept apart (design 0034 §12.3 #2)
///
/// * **Class conditions** are static: "a capacitor never shows current" is true
///   for the whole life of the app and is decided here.
/// * **Data conditions** flip during a session: `tele.current != null`,
///   `tele.dvol != null || tele.dvolPending`. Those stay where they are
///   evaluated — in the view, against live telemetry. The registry only
///   DECLARES that a module has one ([DisplayModules.dataGated]), because that
///   is the difference between "you may not choose this module" (class) and
///   "this module is waiting for data" (data).
///
/// ## Key: [ProductClass], not [RoutingDecision]
///
/// Design 0034 §12.3 #1 asked for `RoutingDecision`. It cannot be the key:
/// `RoutingDecision.pack` is deliberately ONE state covering both a battery
/// and a capacitor (see its own doc comment), and telling those two apart is
/// the entire job of this table. `ProductClass` has exactly the four states
/// §4's table needs — battery, capacitor, power bank, and unclassified — and it
/// is also the value the views already branch on (`ConnectionController
/// .packLabel`), so keying on it keeps the move behaviour-preserving.
library;

import 'package:flutter/foundation.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/live_trend_buffer.dart';

// The vocabulary itself lives in `models/display_module.dart` (design 0046
// Step 6 — the names are wire values two persisted formats depend on). Exported
// from here so every pre-existing `import 'display_modules.dart'` still sees
// [DisplayModule] and nothing had to be rewritten.
export '../../models/display_module.dart';

/// Resolves the gauge's SOH sub-line for a class, given the live bucket.
///
/// A function rather than a `bool`, because the per-class difference is
/// CONTENT, not just presence (design 0034 §12.3 #2). `null` bucket is not the
/// same question as "this class has no SOH": the former renders "SOH --" while
/// waiting, the latter renders nothing, ever.
typedef SohGaugeLine = String Function(AppLocalizations l10n, int? bucket);

/// Resolves a per-class string from the localizations.
typedef DisplayText = String Function(AppLocalizations l10n);

/// What one product class shows.
///
/// Every field is a CLASS condition or per-class CONTENT. Nothing here is
/// allowed to depend on telemetry — see the library doc comment.
@immutable
class DisplayModules {
  const DisplayModules({
    required this.extra,
    required this.dataGated,
    required this.chartTracks,
    required this.sohGaugeLine,
    required this.showsCurrentReadout,
    required this.showsSohReadout,
    required this.chartFootnote,
  });

  /// 🔴 The modules EVERY class offers (design 0050 D1, 「通用」).
  ///
  /// Declared once rather than repeated in each class entry, because repeated
  /// is how one of them gets forgotten. `speed`, `gForce` and `clock` are here
  /// for a different reason from the other two: they do not read the device at
  /// all (`HomeTile.module(m)` with `deviceId == null`), so they are available
  /// to every class precisely because they are irrelevant to all of them.
  ///
  /// The MODULE is common; its CONTENT is not. A capacitor's readouts grid has
  /// no current cell and a power bank's chart plots SOC — see the per-class
  /// fields below. `clock` is the one member whose content is the same on all
  /// four, because it is not about the device at all (design 0052).
  static const Set<DisplayModule> common = {
    DisplayModule.readouts,
    DisplayModule.chart,
    DisplayModule.speed,
    DisplayModule.gForce,
    DisplayModule.clock,
  };

  /// What this class adds on top of [common]. A module in neither is not
  /// "greyed out", it does not exist for this class (design 0034 §4.3).
  final Set<DisplayModule> extra;

  /// Everything this class offers.
  Set<DisplayModule> get modules => {...common, ...extra};

  /// Subset of [modules] whose PRESENCE also depends on live data, so the view
  /// keeps a runtime check. Declaring the condition here and evaluating it
  /// there is the split design 0034 §12.3 #2 asked for.
  final Set<DisplayModule> dataGated;

  /// Which series the chart plots, in the order the view lists them.
  final Set<TrendField> chartTracks;

  /// Gauge sub-line, or `null` when the class has no SOH to report.
  final SohGaugeLine? sohGaugeLine;

  /// Whether the readouts grid carries a current cell. CLASS-gated, not
  /// data-driven: a capacitor DOES stream `0x2E`, pinned at a constant 0.0 A,
  /// and a permanent real-looking zero is worse than an absent row. The
  /// `current != null` data check stays in the view.
  final bool showsCurrentReadout;

  /// Whether the readouts grid carries an SOH cell. Same shape as
  /// [showsCurrentReadout]: class gate here, `sohBucket != null` in the view.
  final bool showsSohReadout;

  /// Note under the chart explaining a series a viewer might expect but will
  /// not find. Belongs to the chart module and travels with it (§5.2).
  final DisplayText? chartFootnote;

  bool has(DisplayModule m) => common.contains(m) || extra.contains(m);

  bool isDataGated(DisplayModule m) => dataGated.contains(m);

  bool hasTrack(TrendField f) => chartTracks.contains(f);

  // -------------------------------------------------------------------------
  // The table (design 0034 §4).
  // -------------------------------------------------------------------------

  /// Smart battery: everything a pack has.
  static const DisplayModules battery = DisplayModules(
    extra: {DisplayModule.gaugeVoltage, DisplayModule.cells},
    dataGated: {DisplayModule.cells},
    chartTracks: {TrendField.current, TrendField.pvlt, TrendField.temperature},
    sohGaugeLine: _sohGaugeLine,
    showsCurrentReadout: true,
    showsSohReadout: true,
    chartFootnote: null,
  );

  /// Super-capacitor: no current anywhere, no SOH anywhere, **no per-series
  /// voltages**, and one chart track MORE than a battery — the secondary
  /// voltage.
  ///
  /// The extra track is the entry most easily lost in a refactor: a capacitor
  /// is the class with FEWER readouts but MORE chart tracks, so "capacitor =
  /// battery minus things" is wrong.
  ///
  /// 🔴 `cells` REMOVED 2026-08-08 (design 0050 D5), on the owner's statement:
  /// 「電容沒有分串電壓」/「超級電容有的叫做 SVLT」. What a capacitor reports is
  /// the stack voltage SVLT (`0x37`), which this class already carries as a
  /// chart track (below) and as a readout (`dashboard_cards.dart`).
  ///
  /// ⚠️ The evidence trail does NOT close, and design 0050 §5 says so rather
  /// than implying otherwise: the protocol notes class `0x24` (DVOL) as `pack`
  /// with no PER-CLASS breakdown, and that same table was wrong in exactly this
  /// way once (`0x25`, corrected 2026-08-05 after somebody counted). A frame
  /// count over pro's `research/` app logs finds **zero** `0x24` on every
  /// class including the battery, so that corpus cannot settle it either way.
  /// This entry rests on the owner's knowledge of the hardware. If a capacitor
  /// capture ever shows DVOL, reopen it — and count per class first.
  static const DisplayModules capacitor = DisplayModules(
    extra: {DisplayModule.gaugeVoltage},
    dataGated: <DisplayModule>{},
    chartTracks: {
      TrendField.pvlt,
      TrendField.svlt,
      TrendField.temperature,
    },
    // Never sends 0x96, so an SOH line could only ever read "SOH --", which a
    // user reads as "the app failed to fetch it".
    sohGaugeLine: null,
    showsCurrentReadout: false,
    showsSohReadout: false,
    chartFootnote: _capacitorChartFootnote,
  );

  /// Power bank: a different shell entirely ([PowerBankView]) — SOC ring,
  /// energy-path row, no DVOL, no protection controls.
  static const DisplayModules powerBank = DisplayModules(
    extra: {DisplayModule.gaugeSoc, DisplayModule.energyPath},
    // The SOC ring renders whether or not a value has arrived (a missing SOC
    // shows as `--`). The energy-path row is likewise unconditional: before its
    // first `0x4B` it shows "waiting for device" rather than disappearing
    // (design 0035 §4.6 / §5.2), so it is a WAITING state, not a data gate —
    // hence still absent from dataGated.
    dataGated: <DisplayModule>{},
    chartTracks: {TrendField.current, TrendField.svlt, TrendField.soc},
    // The gauge sub-line here is the single-cell voltage, not SOH; it is not a
    // class variant of the pack shell's line, so it is not modelled as one.
    sohGaugeLine: null,
    showsCurrentReadout: true,
    showsSohReadout: false,
    chartFootnote: null,
  );

  /// The generic PACK entry, used by [forPackShell] and by nothing else.
  ///
  /// 🔴 RENAMED from `unclassified` 2026-08-08 (design 0050 D2). Under the old
  /// name it did two unrelated jobs, and one of them was a guess: it was what
  /// [forClass] handed back for [ProductClass.unknown], so a device whose class
  /// nobody had established was offered the battery's entire card set. That is
  /// the shape of FB-43 — see `class_pending_view.dart` — and design 0050 D3
  /// removes it: **no class now means no class-specific cards at all**, which
  /// [forClass] expresses by returning null.
  ///
  /// What remains is the OTHER job, which is not a guess and is preserved
  /// verbatim: a stray `powerBank` LABEL can reach the pack shell (routing goes
  /// by the device-type byte, the shell picks its body from the cosmetic
  /// label), and it has always drawn these readouts there. See [forPackShell].
  ///
  /// ⚠️ Identical to [battery] field for field, and that is a BYPRODUCT, not a
  /// decision. Every gate in the pack shell is written `!= supercapacitor`, so
  /// a labelless pack falls on the same side of all six of them. It does NOT
  /// mean "a labelless pack is a battery" — the day one gate is written
  /// `== smartBattery` instead, this entry stops matching, which is exactly why
  /// it is declared separately rather than aliased to [battery].
  /// (design 0034 §12.3 #1, pinned in `display_modules_test.dart`.)
  static const DisplayModules packFallback = DisplayModules(
    extra: {DisplayModule.gaugeVoltage, DisplayModule.cells},
    dataGated: {DisplayModule.cells},
    chartTracks: {TrendField.current, TrendField.pvlt, TrendField.temperature},
    sohGaugeLine: _sohGaugeLine,
    showsCurrentReadout: true,
    showsSohReadout: true,
    chartFootnote: null,
  );

  /// The registry entry for a class, or **null when there is no class**.
  ///
  /// 🔴 Nullable on purpose (design 0050 D3). Returning a set of cards for
  /// [ProductClass.unknown] is a guess about hardware nobody has identified,
  /// and this app has shipped that mistake once already (FB-43: a power bank's
  /// single-cell 3.79 V drawn as a pack's terminal voltage). Null makes every
  /// call site answer the question instead of inheriting an answer.
  static DisplayModules? forClass(ProductClass c) => switch (c) {
        ProductClass.smartBattery => battery,
        ProductClass.supercapacitor => capacitor,
        ProductClass.powerBank => powerBank,
        ProductClass.unknown => null,
      };

  /// The class the pack shell BEHAVES as, for a given cosmetic label.
  ///
  /// Split out of [forPackShell] because design 0034 Phase 5 needs the class
  /// itself (to look up a watchface), not just its registry entry — and having
  /// two expressions of the same quirk is exactly how they would drift.
  static ProductClass packShellClass(ProductClass label) =>
      label == ProductClass.powerBank ? ProductClass.unknown : label;

  /// The lookup [PackScaffold] uses, which is NOT [forClass].
  ///
  /// A `powerBank` LABEL can reach the pack shell: routing is decided by the
  /// device-type byte while the shell picks its body from the cosmetic label,
  /// and `pack_view.dart` sends a stray `powerBank` label to the
  /// [PackControls] fallback alongside `unknown`. It has therefore always drawn
  /// the unclassified readouts there, never [PowerBankView]'s — that view is a
  /// different widget the pack route never builds. Mapping it to [powerBank]
  /// here would put an SOC-only entry inside a voltage-gauge shell and silently
  /// change the screen, so the quirk is preserved verbatim and pinned by test.
  /// 🔴 Non-null, unlike [forClass]: the pack shell only ever runs for a pack,
  /// so "no class" cannot reach here — and a stray `powerBank` label falls to
  /// [packFallback] rather than to nothing.
  static DisplayModules forPackShell(ProductClass label) =>
      forClass(packShellClass(label)) ?? packFallback;
}

/// Gauge SOH sub-line for the classes that have one.
String _sohGaugeLine(AppLocalizations l10n, int? bucket) => bucket == null
    ? l10n.gaugeSohUnknown
    : l10n.gaugeSohValue(bucket, _sohLabel(l10n, bucket));

/// SOH bucket → localized health label (Good / Fair / Degraded).
String _sohLabel(AppLocalizations l10n, int soh) {
  if (soh >= 80) return l10n.gaugeSohLabelGood;
  if (soh >= 50) return l10n.gaugeSohLabelFair;
  return l10n.gaugeSohLabelDegraded;
}

/// "Current is not shown: this class reports a constant 0 A."
String _capacitorChartFootnote(AppLocalizations l10n) =>
    l10n.capacitorChartNoCurrentNote;
