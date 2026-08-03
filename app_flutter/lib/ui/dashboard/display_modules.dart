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

/// The display modules a dashboard page is made of (design 0034 §4).
///
/// `big` (§4.1) is deliberately absent: it is a NEW widget scheduled for
/// Phase 6, and this file only describes what exists today.
enum DisplayModule {
  /// Terminal-voltage gauge ([PvltGauge.voltage]). Pack classes only — a power
  /// bank's instrument reads state of charge, not the rail.
  gaugeVoltage,

  /// State-of-charge ring ([PvltGauge.percent]). Power bank only: SOC arrives
  /// on `0x4B` (`Selectors.powerBankCapacity`), whose decoder returns early for
  /// anything else.
  gaugeSoc,

  /// The numbers grid. Always available; its CONTENTS differ per class.
  readouts,

  /// The live trend chart. Available whenever [DisplayModules.chartTracks] is
  /// non-empty — a chart with no tracks is worse than no chart.
  chart,

  /// Per-cell DVOL bars. Pack classes only, and data-gated: a power bank does
  /// not stream DVOL at all.
  cells,

  /// USB dual-port status. Power bank only.
  usb,
}

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
    required this.modules,
    required this.dataGated,
    required this.chartTracks,
    required this.sohGaugeLine,
    required this.showsCurrentReadout,
    required this.showsSohReadout,
    required this.chartFootnote,
  });

  /// Modules this class offers at all. A module missing here is not "greyed
  /// out", it does not exist for this class (design 0034 §4.3).
  final Set<DisplayModule> modules;

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

  bool has(DisplayModule m) => modules.contains(m);

  bool isDataGated(DisplayModule m) => dataGated.contains(m);

  bool hasTrack(TrendField f) => chartTracks.contains(f);

  // -------------------------------------------------------------------------
  // The table (design 0034 §4).
  // -------------------------------------------------------------------------

  /// Smart battery: everything a pack has.
  static const DisplayModules battery = DisplayModules(
    modules: {
      DisplayModule.gaugeVoltage,
      DisplayModule.readouts,
      DisplayModule.chart,
      DisplayModule.cells,
    },
    dataGated: {DisplayModule.cells},
    chartTracks: {TrendField.current, TrendField.pvlt, TrendField.temperature},
    sohGaugeLine: _sohGaugeLine,
    showsCurrentReadout: true,
    showsSohReadout: true,
    chartFootnote: null,
  );

  /// Super-capacitor: no current anywhere, no SOH anywhere, and one track MORE
  /// than a battery — the secondary voltage.
  ///
  /// The extra track is the entry most easily lost in a refactor: a capacitor
  /// is the class with FEWER readouts but MORE chart tracks, so "capacitor =
  /// battery minus things" is wrong.
  static const DisplayModules capacitor = DisplayModules(
    modules: {
      DisplayModule.gaugeVoltage,
      DisplayModule.readouts,
      DisplayModule.chart,
      DisplayModule.cells,
    },
    dataGated: {DisplayModule.cells},
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

  /// Power bank: a different shell entirely ([PowerBankView]) — SOC ring, USB
  /// card, no DVOL, no protection controls.
  static const DisplayModules powerBank = DisplayModules(
    modules: {
      DisplayModule.gaugeSoc,
      DisplayModule.readouts,
      DisplayModule.chart,
      DisplayModule.usb,
    },
    // The SOC ring renders whether or not a value has arrived (a missing SOC
    // shows as `--`), and the USB card is unconditional today, so no module of
    // this class disappears on data.
    dataGated: <DisplayModule>{},
    chartTracks: {TrendField.current, TrendField.svlt, TrendField.soc},
    // The gauge sub-line here is the single-cell voltage, not SOH; it is not a
    // class variant of the pack shell's line, so it is not modelled as one.
    sohGaugeLine: null,
    showsCurrentReadout: true,
    showsSohReadout: false,
    chartFootnote: null,
  );

  /// A pack whose device-type byte has not been read (or is not recognised).
  ///
  /// ⚠️ Identical to [battery] field for field, and that is a BYPRODUCT, not a
  /// decision. Every gate in the pack shell is written `!= supercapacitor`, so
  /// an unclassified pack falls on the same side of all six of them. It does
  /// NOT mean "an unclassified pack is a battery" — the day one gate is written
  /// `== smartBattery` instead, this entry stops matching, which is exactly why
  /// it is declared separately rather than aliased to [battery].
  /// (design 0034 §12.3 #1, pinned in `display_modules_test.dart`.)
  static const DisplayModules unclassified = DisplayModules(
    modules: {
      DisplayModule.gaugeVoltage,
      DisplayModule.readouts,
      DisplayModule.chart,
      DisplayModule.cells,
    },
    dataGated: {DisplayModule.cells},
    chartTracks: {TrendField.current, TrendField.pvlt, TrendField.temperature},
    sohGaugeLine: _sohGaugeLine,
    showsCurrentReadout: true,
    showsSohReadout: true,
    chartFootnote: null,
  );

  /// The registry lookup: one entry per [ProductClass].
  static DisplayModules forClass(ProductClass c) => switch (c) {
        ProductClass.smartBattery => battery,
        ProductClass.supercapacitor => capacitor,
        ProductClass.powerBank => powerBank,
        ProductClass.unknown => unclassified,
      };

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
  static DisplayModules forPackShell(ProductClass label) => forClass(
        label == ProductClass.powerBank ? ProductClass.unknown : label,
      );
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
