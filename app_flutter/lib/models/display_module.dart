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
  ///    condition kinds exist to keep apart. The switch is handled a level up:
  ///    with it off, [Watchface.riding] falls back to `standard`, so `speed` is
  ///    never laid out at all (design 0042 §3.9, revised 2026-08-07).
  ///
  /// Only [Watchface.riding] lists it, so design 0034's G4 holds literally: a
  /// user who never opens Settings sees no change.
  speed,
}
