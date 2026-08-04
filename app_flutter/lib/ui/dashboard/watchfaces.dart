/// OpenSmartBatt — what each named watchface is made of (design 0034 Phase 5).
///
/// The companion to `display_modules.dart`. That file answers "which modules
/// does this product class HAVE"; this one answers "in what order does this
/// watchface put them". Keeping the two apart is what makes design 0034 §4.3
/// enforceable by construction: every list below is drawn from the class's own
/// registry entry, so a face physically cannot offer a module the class does
/// not have — a power bank's faces have no DVOL card to leave out.
///
/// ## Only the CARDS that exist today are placeable
///
/// [DisplayModule.chart] is deliberately absent from every face. Design 0034
/// Phase 1 (splitting the chart out of [ReadoutsCard] into a card of its own)
/// is NOT unlocked: the chart is still a mode of the readouts card, toggled by
/// `_ModeToggle`, and that toggle's state is not persisted at all. Listing it
/// as a placeable module would advertise an ordering the user cannot control.
/// It re-enters these lists the day Phase 1 lands, and not before.
///
/// ## The control card is not here, and cannot be
///
/// Design 0034 §6 makes "controls are last, always, and never customisable" an
/// INVARIANT rather than a default. It is enforced structurally: there is no
/// `DisplayModule` for the protection card, so no face can name it, and the
/// pack shell appends it after the loop rather than inside it. A power bank has
/// no control card at all and does not grow an empty one (§6 rule 3).
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/state.dart';
import 'display_modules.dart';

/// The ordered cards a [Watchface] draws for a product class, top to bottom.
///
/// The protection card is not included — see the library comment.
List<DisplayModule> watchfaceModules(ProductClass cls, Watchface face) {
  final gauge = cls == ProductClass.powerBank
      ? DisplayModule.gaugeSoc
      : DisplayModule.gaugeVoltage;
  // The class's own "extra" card: per-cell voltages on a pack, the dual-port
  // status on a power bank. Reading it off the registry rather than writing it
  // out per class is what keeps §4.3 true by construction.
  final extra = cls == ProductClass.powerBank
      ? DisplayModule.usb
      : DisplayModule.cells;
  switch (face) {
    // Card for card, in order, exactly what the dashboard drew before design
    // 0034 existed. This IS the implementation of G4 ("a user who never opens
    // the setting sees no change"), which is why it is written as the first
    // case and pinned by test T1 rather than left implicit.
    case Watchface.standard:
      return [gauge, DisplayModule.readouts, extra];
    // Instrument and numbers, nothing else — the shortest honest page. Drops
    // the extra card rather than shrinking it: a half-height DVOL chart would
    // be a new widget, and this release adds none.
    case Watchface.compact:
      return [gauge, DisplayModule.readouts];
    // Detail first. The numbers grid and the per-cell / port card are what a
    // reporter is asked to screenshot; the instrument is the thing they can
    // read at a glance anyway, so it goes to the bottom rather than away.
    case Watchface.diagnostic:
      return [DisplayModule.readouts, extra, gauge];
  }
}

/// The watchface actually drawn for [cls], given what is stored.
///
/// Design 0034 Q4: an UNCLASSIFIED unit does not get a custom layout. Its
/// screen already asks the user what the device is; rearranging it under a
/// preference carried over from another unit would change the page a user is
/// being asked to interpret. (A `pending` unit never reaches here at all — the
/// router hands it [ClassPendingView], which reads no layout.)
///
/// This is the second half of the T3 discipline: an unusable SLUG is rejected
/// when it is decoded ([DisplayLayout.decode]), and an inapplicable CONTEXT is
/// rejected here. Neither is left to the UI to remember.
Watchface effectiveWatchface(ProductClass cls, Watchface stored) =>
    cls == ProductClass.unknown ? Watchface.standard : stored;

/// Machine-readable summary of the layout in force, for the export preamble
/// (design 0034 §8 / Q7).
///
/// Six hard constraints, all of them load-bearing:
///
///  1. it goes LAST in `exportHeaderLines()`;
///  2. it is emitted UNCONDITIONALLY, default layout included — if only a
///     non-default layout were written, a missing line would mean both "they
///     kept the default" and "an older build wrote this", the exact ambiguity
///     FB-32's `raw packet log: on` exists to avoid;
///  3. it is its own line, never appended to `scope:` or `exported:` — the
///     ingest regexes match those two by prefix and would silently swallow it;
///  4. the VALUE contains no `: ` — collected batches are read with a greedy
///     `sed 's/.*: //'`, which would eat everything up to the last one;
///  5. it is not localized — the person who receives a capture is not the
///     person whose phone exported it (same rule as [exportScopeLabel]);
///  6. one line, never wrapped.
///
/// Q7 ruled the MODULE LIST rather than the face name alone: a face is a
/// definition that can change between releases, so `face=compact` recorded a
/// year ago no longer resolves to what it resolved to then. The names are
/// [DisplayModule] identifiers, not labels.
///
/// The list is what the LAYOUT says, not what happened to render: a face that
/// includes `cells` reports `cells` even on a session where DVOL never
/// arrived. That is the whole point — the reader is trying to tell "the data
/// was missing" apart from "the card was not on the page".
String exportLayoutValue({
  required ProductClass? cls,
  required DisplayLayout? layout,
}) {
  // Nothing connected: no unit's layout was in force, and there is no
  // phone-wide one to fall back on (Q3 bound the setting to the device). Say
  // so with the same `-` this project already uses for an absent ident in
  // `exportScopeLabel`, rather than printing a default nobody chose.
  if (cls == null || layout == null) return 'face=- modules=-';
  final face = effectiveWatchface(cls, layout.watchface);
  final modules = watchfaceModules(cls, face).map((m) => m.name).join(',');
  return 'face=${face.slug} modules=$modules';
}

/// [exportLayoutValue] for whatever is on screen at this instant.
///
/// Reads with `context.read`: every caller is an export handler responding to a
/// tap, not a builder, and must capture this BEFORE its first `await` — by the
/// time the file is written the screen may be gone. Same rule as `labelFor` in
/// the same handlers.
String currentExportLayoutValue(BuildContext context) {
  final conn = context.read<ConnectionController>();
  if (!conn.isOnline) return exportLayoutValue(cls: null, layout: null);
  return exportLayoutValue(cls: conn.displayClass, layout: conn.displayLayout);
}
