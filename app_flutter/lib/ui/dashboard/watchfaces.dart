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

import '../../models/models.dart';
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
