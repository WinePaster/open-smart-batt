/// OpenSmartBatt — the display-module vocabulary (design 0034 §4).
///
/// PURE Dart, and that is load-bearing rather than tidy. These enum NAMES are
/// WIRE VALUES: `watchfaces.dart` prints them into every export preamble's
/// `modules=` list, and `home_layout.dart` encodes them into
/// `settings.home_layout`. A vocabulary that two persisted formats depend on
/// belongs beside the other storage shapes (`display_layout.dart`,
/// `saved_device.dart`), not inside a file that also builds widgets.
///
/// 📦 Moved out of `ui/dashboard/display_modules.dart` by design 0046 Step 6,
/// which needs the enum from a pure-Dart model. That file `export`s it straight
/// back, so every existing import still resolves and no call site changed. What
/// stayed there is the per-class REGISTRY ([DisplayModules]) — "which modules
/// does this class have" — which genuinely needs `AppLocalizations`.
library;

import 'app_settings.dart';

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

  /// The live trend chart ([TrendChartCard]). Available whenever
  /// [DisplayModules.chartTracks] is non-empty — a chart with no tracks is
  /// worse than no chart.
  ///
  /// ⚠️ Placeable only since design 0040 (design 0034 Phase 1). Before it the
  /// chart was a MODE of the readouts card, so no watchface listed it and the
  /// export preamble's `modules=` never contained `chart`. Comparing `modules=`
  /// across that boundary needs the same care as the `usb` → `energyPath`
  /// rename below, but the blast radius is ONE face:
  ///
  ///  * `face=diagnostic` gained `chart`, so the same face name reports a
  ///    different set of cards before and after this build;
  ///  * `face=standard` and `face=compact` are UNCHANGED for every class —
  ///    Q1 was reversed on review and `standard` kept its pre-0040 list
  ///    verbatim, so a `standard` capture from before and after this build is
  ///    directly comparable.
  ///
  /// Storage is unaffected — `DisplayLayout` stores only the face slug, never a
  /// module name.
  chart,

  /// Per-cell DVOL bars. Pack classes only, and data-gated: a power bank does
  /// not stream DVOL at all.
  cells,

  /// The power-bank energy-path row ([PowerPathRow], design 0035): one line
  /// answering which way energy moves, through which port, on what protocol, at
  /// what voltage/current. Power bank only.
  ///
  /// ⚠️ Renamed from `usb` (design 0035 Q4). The export preamble's `modules=`
  /// list therefore reads `energyPath` where captures before this build read
  /// `usb` — the two name the SAME registry slot. The analysis side must map
  /// old `usb` → new `energyPath` when comparing `modules=` across builds
  /// (design 0035 §5.3 / R4); storage is unaffected, `DisplayLayout` stores only
  /// the face slug, never a module name.
  energyPath,

  /// GPS speed ([SpeedCard], design 0042). 🔴 **The first module in this
  /// registry that is not device data.** Everything above decodes a BLE frame
  /// from the unit on the other end of the link; this one reads the PHONE's own
  /// GNSS receiver, which has three consequences worth stating where the
  /// registry can be read:
  ///
  ///  * **Every class offers it**, and that is not laziness — it is the point.
  ///    A capacitor "has no current readout" is a fact about the hardware; the
  ///    phone's speed is the same fact on all four, so a per-class column here
  ///    would be inventing a distinction that does not exist.
  ///  * 🔑 **`modules=speed` in an export preamble is NOT evidence about the
  ///    device.** The analysis side has to know this before it reads a capture,
  ///    or a speed reading will end up in a chain of reasoning about a battery.
  ///    Written into `docs/feedback-index/conventions.md` as well as here.
  ///  * **It is not `dataGated`**, and it must not be moved there to express
  ///    the master switch. `dataGated` means "this module is WAITING FOR DATA"
  ///    — a card in that state says so on screen, which for a feature the user
  ///    switched off would be a lie, and would blur the one distinction the two
  ///    condition kinds exist to keep apart. The switch is handled a level up,
  ///    in `renderedModules`: with it off this module is dropped from whatever
  ///    face named it, so no card is built and the GNSS gate's first condition
  ///    never opens (design 0042 §3.9, revised 2026-08-07; moved from the FACE
  ///    layer to the MODULE layer by design 0045's ruling (iv), because `riding`
  ///    can now be kept alive by the G meter alone).
  ///
  /// Only [Watchface.riding] lists it, so design 0034's G4 holds literally: a
  /// user who never opens Settings sees no change.
  speed,

  /// The G meter ([GForceCard], design 0045): longitudinal and lateral G in
  /// VEHICLE coordinates, plus a ball and a peak hold.
  ///
  /// The second module that is not device data, and it carries all three of
  /// [speed]'s consequences — every class offers it, `modules=gForce` in an
  /// export is not evidence about the battery, and it is NOT `dataGated`.
  ///
  /// 🔴 It has a fourth of its own: availability needs a CALIBRATION, not just
  /// a switch. Until the mount has been calibrated the app does not know which
  /// way the phone is pointing, so there are no axes to report — and design
  /// 0045 G1 forbids inventing them. That is a runtime state, not a class gate,
  /// which is why it is absent from `dataGated` for the same reason `speed` is:
  /// `dataGated` means "waiting for data", a card in that state says so on
  /// screen, and "you have not calibrated yet" is not something a dashboard
  /// card is allowed to say (design 0045 Q8 — the card simply is not there).
  /// `renderedModules` drops it instead.
  gForce;

  /// Whether this module reads the PHONE rather than the connected unit.
  ///
  /// 🔑 An exhaustive switch, deliberately, and NOT a set literal or an
  /// `== speed || == gForce` chain. Adding a value to this enum then becomes a
  /// COMPILE error here rather than a silent `false`, and the places that
  /// branch on it are places where a wrong answer is invisible:
  ///
  ///  * the home editor offers per-DEVICE tiles for every module a class has,
  ///    so a phone module that slipped through would be offered as
  ///    `G meter · <battery name>` — a card bound to a unit that has nothing to
  ///    do with it;
  ///  * `renderedModules` filters exactly this set against its availability.
  ///
  /// Before design 0045 the first of those was a hardcoded
  /// `m != DisplayModule.speed`, which is precisely the shape that lets the
  /// NEXT module through unnoticed. That has happened four times in this
  /// project already, always in a caller no test looked at.
  bool get isPhoneModule => switch (this) {
        DisplayModule.gaugeVoltage ||
        DisplayModule.gaugeSoc ||
        DisplayModule.readouts ||
        DisplayModule.chart ||
        DisplayModule.cells ||
        DisplayModule.energyPath =>
          false,
        DisplayModule.speed || DisplayModule.gForce => true,
      };
}

/// Whether a phone module has anything to show right now.
///
/// 🔑 THE shared fact, and deliberately the only shared thing between the two
/// surfaces that draw modules.
///
/// "Is this phone module available" is a statement about the PHONE — its
/// switches and its calibration — not about where the module is being drawn.
/// The watchface surface and the home surface each resolve their own layout
/// (`renderedModules` / `HomeLayout.renderedFor`), and both ask this. Keeping
/// the fact in one place and the surfaces separate is what stops the two from
/// drifting into disagreeing about whether the GNSS stream may open.
///
///  * `speed` needs its master switch (design 0042 §3.9). This is link 1 of the
///    privacy chain: no module ⇒ no card ⇒ no `setFaceWantsSpeed` ⇒ no stream.
///  * `gForce` needs its switch AND a valid calibration (design 0045 Q8): until
///    the mount is calibrated there are no axes, and a card that cannot name a
///    direction is not shown at all.
///
/// A device module is never asked — callers consult this only for modules the
/// enum says belong to the phone.
///
/// Lives in the model layer, not beside the watchfaces, so the PURE home-layout
/// resolver can reach it without importing Flutter.
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
