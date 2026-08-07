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
/// Historical note: until design 0040 (2026-08-05) [DisplayModule.chart] was
/// absent from every list below, because the chart was still a MODE of the
/// readouts card behind a header toggle whose state was not persisted —
/// listing it would have advertised an ordering the user could not control.
/// Design 0034 Phase 1 has now landed: the chart is [TrendChartCard], the
/// toggle is gone, and the chart is placed by these lists like any other card.
///
/// That unlock is also what fixed the defect design 0040 was written for. With
/// the chart withheld, a power bank had exactly two placeable cards after the
/// always-present energy-path row (design 0035 Q2), so `standard` and `compact`
/// returned IDENTICAL lists — three menu entries, two outcomes. The owner's
/// field report on v0.7.2 was literally "I tapped through all three and they
/// are all the same". [watchfaceModules] is now pairwise different on EVERY
/// product class, and that is pinned by test T2 rather than left to review.
///
/// ## A LIST that differs is not a PAGE that differs (design 0041)
///
/// Design 0040 fixed the power bank and the same complaint came straight back
/// on a pack, on v0.7.4. The lists there were never equal — `standard` was
/// `[gauge, readouts, cells]` against `compact`'s `[gauge, readouts]` — but the
/// ONLY difference was `cells`, and `cells` is the one module a pack declares
/// `dataGated`. A unit that never sends `0x24` draws no DVOL card, so `standard`
/// rendered as `[gauge, readouts]`: byte-identical to `compact`, with T2 green.
///
/// The fix is not "make `cells` always draw" — a permanent empty card is the
/// same mistake as a permanent `--`. It is to move the difference onto a card
/// that CANNOT vanish. Hence `compact` is now `[gauge, extra]` for every class,
/// and the thing it drops is the readouts grid, which every class renders
/// unconditionally. The rule is one sentence again: **compact drops the numbers
/// grid and keeps the instrument plus the class's own card.**
///
/// Test T2b is the general form of that lesson and is the reason this cannot
/// recur on a third class: for every class and every PAIR of faces, the
/// set-difference of their modules must contain something that is NOT
/// `dataGated`. T2 pins the lists; T2b pins that a difference can actually be
/// SEEN. Do not delete it as a duplicate of T2 — it is not.
///
/// ## 🔴 The chart is on `diagnostic` ONLY, and that costs something real
///
/// Design 0040 Q1 first proposed `standard` = the old three cards PLUS the
/// chart appended last, so that removing the toggle would not take the live
/// curve away from anybody. That was implemented, reviewed, and **REVERSED by
/// the owner** on 2026-08-05. The chart is now reachable from `diagnostic` and
/// nowhere else.
///
/// The cost was put to the owner in these terms and accepted: **a user who
/// never opens Settings loses the live chart.** Before this build they could
/// reach it from the readouts card's own header toggle, without knowing that a
/// watchface setting exists; now they cannot reach it at all until they go into
/// Settings and pick `diagnostic`. That is a capability removed from the
/// default install, not merely a card relocated, and it is written down here so
/// that a later reader finds a decision rather than an accident. The
/// compensation is that `standard` is byte-for-byte the pre-0040 list again, so
/// design 0034's G4 holds LITERALLY — which is what test T1 pins, in its
/// original strict form.
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

/// The ordered cards a [Watchface] draws for a product class, top to bottom.
///
/// The protection card is not included — see the library comment.
List<DisplayModule> watchfaceModules(ProductClass cls, Watchface face) {
  final gauge = cls == ProductClass.powerBank
      ? DisplayModule.gaugeSoc
      : DisplayModule.gaugeVoltage;
  // The class's own "extra" card: per-cell voltages on a pack, the energy-path
  // row on a power bank. Reading it off the registry rather than writing it
  // out per class is what keeps §4.3 true by construction.
  final isPowerBank = cls == ProductClass.powerBank;
  final extra =
      isPowerBank ? DisplayModule.energyPath : DisplayModule.cells;
  switch (face) {
    // Card for card, in order, exactly what the dashboard drew before design
    // 0034 existed — and still exactly that after Phase 1. This IS the
    // implementation of G4 ("a user who never opens the setting sees no
    // change"), which is why it is written as the first case and pinned by test
    // T1 rather than left implicit.
    //
    // ⚠️ No `chart` here, by ruling. Design 0040 Q1 proposed appending it; the
    // owner reversed that on review, knowing it means the live curve is
    // unreachable without a trip to Settings. See the library comment — the
    // cost is recorded there, not softened.
    case Watchface.standard:
      return [gauge, DisplayModule.readouts, extra];
    // One screenful, no scrolling: the fewest cards that still answer the
    // question this class is usually asked.
    //
    // The instrument plus the class's own card — the SAME shape for every
    // class, which is what design 0041 Q1 bought. What it drops is the numbers
    // grid, and that choice is load-bearing rather than cosmetic: the grid is
    // the only card here every class renders unconditionally, so it is the only
    // place a difference from `standard` is guaranteed to be visible. A pack
    // used to do the opposite (drop `cells`, keep the numbers) and that is
    // exactly how `standard` and `compact` collapsed into the same page on a
    // unit with no DVOL — see the library comment.
    //
    // The reason it keeps `extra` rather than the numbers is design 0035 Q2's,
    // now applied to both classes: the energy-path row "IS the answer to which
    // way it is charging", and that argument gets STRONGER as the layout gets
    // shorter. The per-cell card is the pack's equivalent.
    //
    // Costs, both accepted knowingly (design 0040 Q2/R3, design 0041 Q1/R3+R4):
    // compact shows NO temperature on any class, and on a pack that never sends
    // DVOL it renders as the gauge alone (plus the always-appended control
    // card). Anyone who wants temperature has two other faces.
    case Watchface.compact:
      return [gauge, extra];
    // The CHART FIRST, then detail, instrument last (design 0041 Q4).
    //
    // Design 0034 put the numbers grid at the top here, on the reasoning that
    // this face exists for someone gathering a report and the chart was third
    // in that list of things to screenshot. Design 0040 Q1 then made this the
    // ONLY face carrying the chart, which invalidated the premise: "turn on
    // diagnostic" became the instruction for anyone who wants a live curve at
    // all, so most people arriving here arrived FOR the curve and had to scroll
    // past two cards to reach it.
    //
    // The instrument still goes last — it is the one thing readable at a glance,
    // so it loses least by being at the bottom.
    //
    // ⚠️ Known cost: for the first few seconds of a connection the chart has no
    // points and renders its own waiting label, so the TOP of this page is a
    // waiting card. Accepted: it resolves in seconds, and it is an honest
    // waiting state rather than a permanent placeholder.
    case Watchface.diagnostic:
      return [DisplayModule.chart, DisplayModule.readouts, extra, gauge];
    // design 0042 §3.3: `compact`'s shell with a speed card on top. Speed
    // first because on a moving vehicle it is the only reading that has to be
    // legible at a glance; the device's state is what you look at when you
    // stop.
    //
    // Why the SAME shell rather than a fourth arrangement: `extra` is here for
    // design 0035 Q2's reason, and that reason gets STRONGER as the page gets
    // shorter — the energy-path row IS the answer to which way it is charging,
    // and the per-cell card is the pack's equivalent. Dropping the numbers grid
    // is what makes room for a 52 pt speed without scrolling.
    //
    // ⚠️ This function is PURE and stays that way. Neither master switch is
    // consulted here: T1/T2/T2b and the export preamble all read this, and a
    // face whose composition depended on a setting would make `modules=` in a
    // capture mean different things on different phones. The switches are
    // applied one level up, in [renderedModules].
    //
    // Design 0045 Q1 (a) put `gForce` second: speed stays at the top because it
    // is the reading that has to be legible at a glance, and the ball sits
    // directly under it because the two are read together — "what was I doing
    // when the current spiked" is one question.
    case Watchface.riding:
      return [DisplayModule.speed, DisplayModule.gForce, gauge, extra];
  }
}

/// Whether a PHONE module ([DisplayModule.isPhoneModule]) can draw right now.
///
/// The two phone modules have different availability conditions and they are
/// written out here, once:
///
///  * `speed` needs the GPS master switch. Nothing else — the card has its own
///    honest states for "no permission" and "no fix yet" and must NOT vanish
///    for those (design 0034 §4.3).
///  * `gForce` needs its switch AND a valid calibration. Design 0045 Q8: until
///    the mount is calibrated there are no axes, and a card that cannot name a
///    direction is not shown at all.
///
/// A device module is never asked; [renderedModules] only consults this for
/// modules the enum says belong to the phone.
bool phoneModuleAvailable(
  DisplayModule m,
  AppSettings s, {
  required bool gForceAvailable,
}) =>
    switch (m) {
      DisplayModule.speed => s.speedDetection,
      DisplayModule.gForce => gForceAvailable,
      _ => true,
    };

/// Whether [Watchface.riding] is available at all.
///
/// 🔑 ONE decision point, used in THREE places — the watchface picker asks it
/// before listing the option, [renderedWatchface] asks it before drawing the
/// face, and [renderedModules] is built on it. Splitting those into separate
/// conditions is what produced the defect this function is written to prevent:
/// with only the picker guarded, a user who selected `riding` and then switched
/// speed detection off kept a stored `riding` that rendered as `[gauge, extra]`
/// — byte for byte `compact`. Test T2b would have stayed green throughout,
/// because it reasons about module LISTS and the collapse happens below them.
///
/// ⚠️ There is a FOURTH caller of the old one-argument version that must NOT
/// use this: the home editor asked `ridingSelectable` when deciding whether to
/// offer a SPEED tile on the home grid. That is a different question wearing
/// the same predicate, and once this became "speed OR G" it would have offered
/// a speed tile — which mounts a `SpeedCard`, which opens the GNSS gate — to
/// someone who only ever turned the G meter on. It now asks
/// `phoneModuleAvailable(speed, …)` instead.
///
/// Design 0041 §1.1 is the same defect on `standard`/`compact`, reported from
/// the field as "I tapped through all three and they are all the same". Owner
/// ruling of 2026-08-07: fix it structurally rather than accept it as a
/// self-inflicted transient state — a face that renders as a copy of another
/// face is a bad layout, and design 0034 G2 says a bad layout must be
/// unreachable, not merely unusual.
///
/// Design 0045 Q3 widened it to "speed on **or** G available": `riding` falls
/// back only when EVERY card that distinguishes it is gone. "G on but not yet
/// calibrated" does not count — otherwise picking `riding` would land on the
/// collapsed layout this function exists to make unreachable.
bool ridingSelectable(AppSettings s, {required bool gForceAvailable}) =>
    s.speedDetection || gForceAvailable;

/// The face actually DRAWN, given the stored one, the class and the settings.
///
/// Two rejections in order, and they are different questions:
///
///  1. [effectiveWatchface] — an inapplicable CONTEXT (design 0034 Q4: an
///     unclassified unit keeps `standard`, because its screen is already asking
///     the user what the device is).
///  2. `riding` with NOTHING to put on it — an unavailable FACE.
///
/// Non-destructive: the stored slug is not rewritten, so the face returns by
/// itself when a switch goes back on.
///
/// ⚠️ Callers that are about to draw want [renderedModules], not this. This
/// answers which face; that answers what is on it, and after design 0045 the
/// second question has an answer the first cannot give.
Watchface renderedWatchface(
  ProductClass cls,
  Watchface stored,
  AppSettings settings, {
  required bool gForceAvailable,
}) {
  final face = effectiveWatchface(cls, stored);
  if (face == Watchface.riding &&
      !ridingSelectable(settings, gForceAvailable: gForceAvailable)) {
    return Watchface.standard;
  }
  return face;
}

/// 🔑 The cards actually DRAWN: the resolved face, minus any phone module that
/// is switched off or unavailable. **Every render path reads this.**
///
/// ## Why this layer grew a second job (owner ruling, 2026-08-07)
///
/// Until design 0045 the resolution layer answered one question — which FACE —
/// and that was enough, because `riding` had exactly one phone module on it.
/// With the switch off the whole face fell back to `standard`, so `speed` was
/// never laid out, and THAT is what made design 0042's privacy chain
/// structural: no module ⇒ no card ⇒ no GNSS ⇒ no rows. The chain is spelled
/// out in `gps_speed_controller.dart`, which has no `speedDetection` condition
/// of its own precisely because it does not need one.
///
/// Design 0045 Q3 puts a SECOND phone module on the same face and lets EITHER
/// one keep it alive. That breaks the face-level answer: with speed off and the
/// G meter available, `riding` is drawn, and a face-only resolution would have
/// laid out `speed` — mounting a `SpeedCard`, opening the GNSS stream, and
/// landing speed rows for a user who never saw the location consent dialog.
/// Not a test failure: an actual leak.
///
/// The fix is NOT a second gate in `dashboardCardFor` (`settings.speedDetection
/// ? SpeedCard() : null`). That is the duplicate decision point the 2026-08-07
/// ruling removed, and it would put the privacy guarantee back into a check
/// somebody can forget. It is to widen THIS layer's output from a `Watchface`
/// to a `List<DisplayModule>`: still one decision point, asked once, now
/// answering the question that actually determines what gets built.
///
/// ## What the four states look like
///
/// | speed | G available | `riding` renders          |
/// |-------|-------------|---------------------------|
/// | on    | no          | `[speed, gauge, extra]`   |
/// | off   | yes         | `[gForce, gauge, extra]`  |
/// | on    | yes         | `[speed, gForce, gauge, extra]` |
/// | off   | no          | not selectable → `standard` |
///
/// Each of the first three differs from `compact` (`[gauge, extra]`) by
/// something visible, which is the T2b property; the fourth never happens.
///
/// ⚠️ The export preamble deliberately does NOT come through here — see
/// [exportLayoutValue].
List<DisplayModule> renderedModules(
  ProductClass cls,
  Watchface stored,
  AppSettings settings, {
  required bool gForceAvailable,
}) {
  final face = renderedWatchface(cls, stored, settings,
      gForceAvailable: gForceAvailable);
  return [
    for (final m in watchfaceModules(cls, face))
      if (!m.isPhoneModule ||
          phoneModuleAvailable(m, settings, gForceAvailable: gForceAvailable))
        m,
  ];
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
///
/// ## 🔑 DECLARED is not RENDERED, and the preamble says both
///
/// This value comes from the PURE [watchfaceModules], never from
/// [renderedModules], so a capture can name cards the screenshot beside it does
/// not show. There are two ways that happens and the reader needs to be able to
/// tell them apart — which is why the preamble carries three lines, not one:
///
///  1. **The face fell back.** `layout: face=riding modules=speed,gForce,…`
///     next to `speed detection: off` AND `g meter: off` means the stored face
///     was `riding`, nothing on it was available, and `standard` was drawn.
///  2. **The face drew, minus a card.** The same `layout:` line next to
///     `speed detection: off` and `g meter: on` means `riding` DID draw — as
///     `[gForce, gauge, extra]`, with no speed card. `g meter: on` with no
///     `g_long`/`g_lat` values in the CSV narrows it further: the switch was on
///     but the mount was not calibrated, so the G card was not drawn either
///     (design 0045 Q8).
///
/// Filtering this line by what rendered would collapse both cases into "the
/// cards you can see", and with them the evidence for WHY. The rule is the same
/// one design 0034 §8 started from: the preamble records the configuration, the
/// switch lines record what the configuration was allowed to do, and reading
/// them together is how a screenshot becomes evidence.
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

/// Machine-readable summary of the HOME grid, for the export preamble
/// (design 0046 Step 10 / §9 Q-A).
///
/// Design 0034 §8 made the watchface line required because "our problem-reading
/// runs on screenshots": a customisable dashboard makes "there is no charge
/// reading on screen" mean either "the data never came" or "that card is not on
/// their page". 🔑 That argument is STRONGER here than it was there, because
/// since design 0046 R3 the home grid is the DEFAULT ENTRY POINT — so most
/// screenshots we are sent are now screenshots of this page.
///
/// It obeys the same six constraints as [exportLayoutValue], for the same
/// reasons: its own line, in the OPTIONAL MIDDLE so `layout:` stays last; no
/// `: ` in the value (the analysis recipes read it with a greedy
/// `sed 's/.*: //'`); never localized; one line; emitted unconditionally,
/// default included — if only a customised grid were written, a missing line
/// would mean both "they kept the default" and "an older build wrote this",
/// which is the FB-32 ambiguity.
///
/// 🔴 Device ids are NOT written. They are replaced by per-export ordinals
/// (`d1`, `d2`, …) assigned in order of first appearance. That is enough to see
/// that two tiles name the SAME unit — the only thing a reader needs from them
/// — while design 0027 §3.1's rule (a raw device id never reaches an exported
/// file; on Android it is the MAC) is kept without adding a second hashing
/// scheme beside `# devices:`.
///
/// `tiles=auto` means the user has never customised it, so what they saw is
/// whatever [HomeLayout.defaultFor] produced for the devices listed above.
String exportHomeValue(HomeLayout? layout) {
  if (layout == null) return 'tiles=auto';
  final ordinals = <String, String>{};
  String token(String id) =>
      ordinals.putIfAbsent(id, () => 'd${ordinals.length + 1}');
  // `:half` is appended for half-width tiles and omitted for full-width ones.
  //
  // Without it two genuinely different pages produce the same `home:` line: a
  // column of full-width cards and a two-up grid of the same modules read
  // identically, while the difference decides how many cards fit on one screen
  // — which is exactly what this line exists to reconstruct from a screenshot
  // (the reason design 0046 Step 10 gave for adding it at all).
  //
  // Omitting the common case keeps the line short and keeps the grammar
  // additive: a reader that does not know `:half` still parses the module name.
  String span(HomeTile t) => t.span == HomeSpan.half ? ':half' : '';
  final parts = <String>[
    for (final t in layout.tiles)
      switch (t.kind) {
        HomeTileKind.addDevice => 'addDevice${span(t)}',
        HomeTileKind.deviceCard => 'deviceCard@${token(t.deviceId!)}${span(t)}',
        HomeTileKind.module => t.deviceId == null
            ? '${t.module!.name}${span(t)}'
            : '${t.module!.name}@${token(t.deviceId!)}${span(t)}',
      },
  ];
  return 'tiles=${parts.join(',')}';
}

/// [exportHomeValue] for whatever the home grid is at this instant.
///
/// Reads with `context.read` for [currentExportLayoutValue]'s reason: every
/// caller is an export handler responding to a tap, and must capture this
/// BEFORE its first `await`.
String currentExportHomeValue(BuildContext context) =>
    exportHomeValue(
        HomeLayout.decode(context.read<SettingsController>().homeLayout));
