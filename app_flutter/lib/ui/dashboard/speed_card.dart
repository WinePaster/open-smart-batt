/// OpenSmartBatt — the `speed` card (design 0042 §3.8, Phase D).
///
/// The first card on this dashboard whose number does not come from a device.
/// Everything else here decodes a BLE frame; this reads the PHONE's own GNSS
/// receiver. Two consequences run through the whole file:
///
///  * **G2 applies harder, not less.** A frozen device reading at least came
///    from the device once. A frozen SPEED is the number the rider was doing
///    before the tunnel, and shown plainly it is indistinguishable from the one
///    they are doing now. So every state below is rendered differently on
///    purpose — `holding` carries a "held" badge and a dimmed value, `lost`
///    demotes the number to a footnote with an age beside it — and there is no
///    decay animation, because a needle drifting toward zero pretends to be a
///    measurement of slowing down.
///  * **The card never disappears.** Waiting for a first fix, and a refused
///    permission, are both STATES with words, not absences (design 0034 §4.3).
///    A card that vanishes when the permission is denied teaches the user that
///    the app is broken; one that says "location is off, here is the settings
///    page" teaches them what to do.
///
/// 🔴 There is no coordinate anywhere in this file, and there must never be
/// one (G5). [SpeedEstimate] does not carry one, so this is structural rather
/// than a rule to remember — see `speed_estimator.dart`.
///
/// ## This widget also opens the GNSS gate
///
/// Condition 1 of the three-condition gate (§3.4) is "the effective watchface
/// renders the speed module". That is precisely "this widget is mounted", so it
/// is expressed that way rather than recomputed from the layout: the stream
/// exists while the card is on the page and stops when it leaves. Anything else
/// would be a second derivation of the same fact, free to disagree with the
/// first.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial.dart';

/// Metres per second in the user's chosen unit, rendered without a suffix.
///
/// One decimal below 10 and none above it: at walking pace the first decimal is
/// the difference between moving and stopped, and at road speed it is noise
/// that makes the digits flicker on every sample.
String formatSpeed(double mps, SpeedUnit unit) {
  final v = speedIn(mps, unit);
  return v < 10 ? v.toStringAsFixed(1) : v.round().toString();
}

/// Convert m/s into [unit]. The ONE conversion in the app — the card, the ±
/// line and design 0044's acceleration reading all go through it, so they
/// cannot end up using different constants.
double speedIn(double mps, SpeedUnit unit) =>
    unit == SpeedUnit.mph ? mps * 2.2369362920544 : mps * 3.6;

/// Suffix for [unit]. Not localized: `km/h` and `mph` are the same symbols in
/// both of this app's languages.
String speedUnitLabel(SpeedUnit unit) => unit == SpeedUnit.mph ? 'mph' : 'km/h';

/// Suffix for acceleration: the speed unit, per second (design 0044 §3.3, Q5).
///
/// No preference of its own — it follows the speed setting, so `km/h` becomes
/// `km/h/s` and `mph` becomes `mph/s`. The unit is deliberately NOT m/s²: this
/// app's reader is a rider, not an engineer, and "how many km/h it gains each
/// second" is a sentence they already think in. m/s² lands in history, where
/// the reader IS an engineer.
String accelUnitLabel(SpeedUnit unit) => '${speedUnitLabel(unit)}/s';

/// Acceleration in the user's unit, one decimal, always carrying its sign.
///
/// The sign is explicit because the whole reading is a direction: `1.2` and
/// `-1.2` are launching and braking, and a minus sign that only appears half
/// the time is easy to miss at a glance on a moving vehicle (§3.3). Zero gets
/// no sign — it has no direction — and it is reachable ONLY as a measurement,
/// because a suppressed or warming estimator renders no row at all.
///
/// [displayAccel] runs first: deadband, then quantisation. It is the reason
/// this can disagree with the value written to history, and that disagreement
/// is intended in exactly one direction — the record is the raw one.
String formatAccel(double mps2, SpeedUnit unit) {
  final v = speedIn(displayAccel(mps2), unit);
  final s = v.abs().toStringAsFixed(1);
  // Catches -0.0 and anything that rounds into it: "-0.0" reads as a tiny
  // deceleration that was never measured.
  if (s == '0.0') return '0.0';
  return v > 0 ? '+$s' : '-$s';
}

/// The acceleration to render beside a speed reading, or null for no row.
///
/// A named function rather than a condition inside `build`, for the reason this
/// project has learned three times over: a judgement that only exists inside a
/// widget is a judgement the suite can only reach through a rendered frame, and
/// the defects here have all been in what was passed IN.
///
/// Two independent gates, both required (0044 §3.4):
///   * the SPEED must be live — beside a held or lost speed, an acceleration
///     would be describing a moment the speed itself is no longer describing;
///   * the acceleration must exist — [GpsSpeedController.currentAccel] is null
///     while warming and while suppressed.
///
/// 🔴 There is no third branch that renders `0.0`. "No acceleration reading"
/// and "measured zero acceleration" are different facts and the row's absence
/// is how they are told apart (§3.3).
AccelEstimate? accelReadoutFor(SpeedState speed, AccelEstimate? accel) =>
    speed == SpeedState.live ? accel : null;

/// GPS speed, its signal state, and how much to trust it.
class SpeedCard extends StatefulWidget {
  const SpeedCard({super.key});

  @override
  State<SpeedCard> createState() => _SpeedCardState();
}

class _SpeedCardState extends State<SpeedCard>
    with SingleTickerProviderStateMixin {
  /// Captured rather than read in [dispose]: by then this element is detached
  /// and `context.read` is no longer legal.
  GpsSpeedController? _gps;

  /// Design 0071 §3.7, carried forward unchanged by design 0073 §3.10 — only
  /// the predicate that arms it moved. A vsync [Ticker] rather than [AlignedTicker]: this
  /// reading has no boundary to align to, and — the half that matters — a
  /// `Timer` keeps firing while the app is not drawing, whereas a Ticker
  /// created through [SingleTickerProviderStateMixin] is muted by `TickerMode`
  /// the moment this subtree stops being visible. That is 0042 G4's battery
  /// budget getting the benefit for free.
  ///
  /// 🔴 Built eagerly in [initState] and disposed in [dispose]. `late final … =
  /// createTicker(…)` would be evaluated on first USE, and `devices_page.dart`
  /// has already paid for that mistake once: if the first use is inside
  /// `dispose()` the ticker is created against a deactivated element.
  late final Ticker _ticker;

  /// The string [build] last rendered, and the only thing a frame is allowed to
  /// rebuild for.
  ///
  /// 🔑 Design 0071 §3.7: compute every frame, rebuild only when
  /// [formatSpeed]'s OUTPUT changes. At 3 m/s² the integer digits move ~11
  /// times a second while the ticker fires 60–120 times, so comparing the
  /// formatted string is what turns a per-frame computation back into a handful
  /// of rebuilds. Comparing the double instead would rebuild on every frame,
  /// for pixels that are identical.
  String? _displayText;

  /// The unit the comparison above is made in. Refreshed in [build], where the
  /// `context.select` that owns it lives — a ticker callback is not a place to
  /// read an InheritedWidget.
  SpeedUnit _unit = SpeedUnit.kmh;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onFrame);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gps = context.read<GpsSpeedController>();
    _setFaceWantsSpeed(true);
  }

  @override
  void dispose() {
    // 🔴 R4. `aligned_ticker.dart` carries the same warning for the same
    // reason: a ticker that outlives its State holds a closure over a defunct
    // element and calls `setState` on it for the life of the process.
    _ticker.dispose();
    _setFaceWantsSpeed(false);
    super.dispose();
  }

  /// One frame of the continuous readout.
  ///
  /// Compute every frame; rebuild only when the DIGITS change (§3.7). Then hand
  /// the loop back as soon as the reading stops moving — the horizon has hit
  /// its ceiling, or there is no usable trend — because past that point only a
  /// new sample can move it, and a new sample makes the controller notify,
  /// which rebuilds, which re-arms the ticker. Nothing is missed by stopping.
  void _onFrame(Duration _) {
    final gps = _gps;
    if (gps == null) return;
    final next = gps.displaySpeedMpsNow();
    if (next != null && formatSpeed(next, _unit) != _displayText) {
      // `build` re-reads the value itself, so an empty `setState` is the whole
      // of "draw the next step". The ~90 % of frames whose digits did not move
      // fall through here without touching the element tree, which is the
      // entire point of comparing the formatted string.
      setState(() {});
    }
    if (next == null || !gps.displayTrendActiveNow()) _ticker.stop();
  }

  /// Start or stop the per-frame loop.
  ///
  /// The reading only moves while it is [SpeedState.live] (design 0073 C1) and
  /// while there is an estimator behind it, so that is the only case worth
  /// burning frames on. Called from [build], i.e. on every `notifyListeners` —
  /// one per fix and one per tick.
  void _syncTicker({required bool wants}) {
    if (wants) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  /// Deferred to the end of the frame, and that is not defensive noise:
  /// [GpsSpeedController.setFaceWantsSpeed] notifies its listeners, and both
  /// call sites above run inside the build/teardown phase, where notifying
  /// would mark widgets dirty while they are being built. Post-frame callbacks
  /// fire in registration order, so a card that unmounts and remounts within
  /// one frame still ends on the right value.
  void _setFaceWantsSpeed(bool v) {
    final gps = _gps;
    if (gps == null) return;
    // Safe against a controller torn down before the frame lands:
    // GpsSpeedController checks its own `_disposed` on both the opening and the
    // closing path, so a late callback is a no-op rather than a
    // "used after dispose".
    WidgetsBinding.instance
        .addPostFrameCallback((_) => gps.setFaceWantsSpeed(v));
  }

  @override
  Widget build(BuildContext context) {
    final gps = context.watch<GpsSpeedController>();
    final unit = context.select<SettingsController, SpeedUnit>(
        (s) => s.settings.speedUnit);
    _unit = unit;
    final estimate = gps.current;
    // Read the value HERE rather than caching what the ticker computed: this
    // build may have been triggered by a fix or by the 1 Hz tick, both of which
    // land between frames, and the freshest read is also the correct one. The
    // ticker's only job is to make a build happen at all.
    final display = estimate != null && estimate.state == SpeedState.live
        ? gps.displaySpeedMpsNow()
        : null;
    _syncTicker(wants: display != null);
    _displayText = display == null ? null : formatSpeed(display, unit);
    return IndustrialCard(
      child: SpeedCardBody(
        permission: gps.permission,
        estimate: estimate,
        accel: gps.currentAccel,
        unit: unit,
        displaySpeedMps: display,
        onOpenSystemSettings: gps.openSystemSettings,
      ),
    );
  }
}

/// The card's BODY, given a reading — no controller, no sensor, no provider.
///
/// Split out of [SpeedCard] by design 0051 §5.2. The home editor has to show
/// what this card LOOKS like while nothing is measured, and it is the one card
/// where handing in fake data is not enough: [SpeedCard] opens the GNSS gate in
/// `didChangeDependencies`, so merely mounting it starts the receiver whatever
/// data it is given. The editor therefore mounts THIS instead
/// (`home_preview.dart`), which is the same pixels with no side effect.
///
/// 🔴 Not a copy. A second speed layout for the editor would drift from the
/// real one within a release, and the whole point of previewing a layout is
/// that it is the layout.
class SpeedCardBody extends StatelessWidget {
  const SpeedCardBody({
    super.key,
    required this.permission,
    required this.estimate,
    required this.accel,
    required this.unit,
    this.displaySpeedMps,
    this.onOpenSystemSettings,
  });

  final SpeedPermissionState permission;

  /// The reading, or null for "no fix yet".
  final SpeedEstimate? estimate;

  /// The number to DRAW, or null to draw [SpeedEstimate.vSmoothMps] (design
  /// 0071 §3.6).
  ///
  /// Optional so that every caller which hands in sample data — the home
  /// editor's preview, the watchface previews — keeps working unchanged and
  /// keeps rendering the same pixels: those have no estimator behind them and
  /// nothing to sweep between. Only the live [SpeedCard] passes it.
  ///
  /// It differs from `estimate.vSmoothMps` only DURING a sweep, and only while
  /// the state is [SpeedState.live]; on every sampling instant the two are the
  /// same number (`speed_estimator.dart`, `displaySpeedMpsAt` property 2).
  final double? displaySpeedMps;

  /// The RAW acceleration estimate. [accelReadoutFor] decides whether it is
  /// drawn — deliberately here rather than at the caller, so the editor's
  /// preview obeys the same rule as the live card.
  final AccelEstimate? accel;

  final SpeedUnit unit;

  /// Null in the preview: there is no system settings page to send anyone to
  /// from a layout editor, and a chip that did nothing would be worse.
  final VoidCallback? onOpenSystemSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Permission first: without it every other state is a consequence rather
    // than a cause, and telling the user "waiting for a fix" while the OS is
    // refusing us is the dishonest reading of the same screen.
    switch (permission) {
      case SpeedPermissionState.denied:
        return _MessageState(
          icon: Icons.location_disabled,
          title: l10n.speedCardPermissionDeniedTitle,
          body: l10n.speedCardPermissionDeniedBody,
          actionLabel: l10n.speedCardOpenSystemSettings,
          onAction: onOpenSystemSettings,
        );
      case SpeedPermissionState.permanentlyDenied:
        return _MessageState(
          icon: Icons.location_disabled,
          title: l10n.speedCardPermissionDeniedTitle,
          body: l10n.speedCardPermissionPermanentBody,
          actionLabel: l10n.speedCardOpenSystemSettings,
          onAction: onOpenSystemSettings,
        );
      case SpeedPermissionState.notRequested:
      case SpeedPermissionState.granted:
        break;
    }

    final e = estimate;
    if (e == null) {
      return _MessageState(
        icon: Icons.satellite_alt,
        title: l10n.speedCardWaitingTitle,
        body: l10n.speedCardWaitingBody,
      );
    }
    final shownAccel = accelReadoutFor(e.state, accel);
    // 🔴 `holding` and `lost` are given the frozen value, never the curve.
    // `displaySpeedMpsAt` would answer with `vSmoothMps` for both anyway (its
    // pin 1), so this is belt and braces — but it is the belt that stops a
    // future caller passing a swept value into a state whose whole meaning is
    // "this number is not moving because nobody is measuring it" (0042 G2).
    final live = displaySpeedMps;
    return switch (e.state) {
      SpeedState.live => _Reading(
          estimate: e,
          unit: unit,
          held: false,
          accel: shownAccel,
          speedMps: live ?? e.vSmoothMps),
      SpeedState.holding => _Reading(
          estimate: e,
          unit: unit,
          held: true,
          accel: shownAccel,
          speedMps: e.vSmoothMps),
      SpeedState.lost => _LostState(estimate: e, unit: unit),
    };
  }
}

/// The live / held reading: one big number, and everything else small.
class _Reading extends StatelessWidget {
  const _Reading({
    required this.estimate,
    required this.unit,
    required this.held,
    required this.speedMps,
    this.accel,
  });

  final SpeedEstimate estimate;
  final SpeedUnit unit;

  /// The number in the big digits. Equal to `estimate.vSmoothMps` except while
  /// a live reading is mid-sweep (design 0071) — everything else on this card
  /// (the ±, the quality pill, the held badge) still comes from [estimate],
  /// because they describe the SAMPLE, not the animation.
  final double speedMps;

  /// [SpeedState.holding]: the number is the last one MEASURED, not the current
  /// one. Rendered muted with a badge — the visual difference is the whole
  /// point of the state (G2).
  final bool held;

  /// Design 0044's sub-readout, or null for no row at all. Decided by
  /// [accelReadoutFor]; this widget only draws what it is given.
  final AccelEstimate? accel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    final accuracy = estimate.speedAccuracyMps;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 🔴 The number and its unit scale as ONE group; the quality pill keeps
        // its size and its place on the right.
        //
        // Same field report as `_GReadout`'s number (see there). A 1x1 home
        // tile is ~265 px on a normal phone and ~145 px on a 320 dp one, and
        // 52 px digits + `km/h` + the pill do not fit at three digits — which
        // is not a corner case on a motorbike. Unfixed it is a RenderFlex
        // overflow: the striped bar, drawn across the reading the rider is
        // actually looking at.
        //
        // `Expanded` rather than `Flexible` + `Spacer`: those two would have
        // split the free space evenly between the number and the gap, capping
        // the number at half the row for no reason. Here the pill is the only
        // fixed cost and the group gets everything else — so at full width
        // nothing is scaled at all and the layout is byte-for-byte the old one.
        Row(
          children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      formatSpeed(speedMps, unit),
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 52,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: held ? colors.muted : context.accent.accent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      speedUnitLabel(unit),
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 14,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w600,
                        color: colors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _QualityPill(quality: estimate.quality),
          ],
        ),
        // Design 0044's sub-readout. Absent — not zeroed — whenever there is no
        // measured slope, which is what makes the row's presence meaningful.
        // A sub-readout appearing and disappearing does not move the page the
        // way a whole card would, which is why 0044 Q1 was corrected to (b).
        if (accel != null) ...[
          const SizedBox(height: 8),
          _AccelRow(aMps2: accel!.aMps2, unit: unit),
        ],
        if (held) ...[
          const SizedBox(height: 10),
          _HeldBadge(label: l10n.speedCardHeld),
        ],
        // Omitted entirely when the platform reports no uncertainty — never
        // rendered as `±--`, which reads as a value the app failed to fetch
        // (design 0042 §3.8).
        if (accuracy != null) ...[
          const SizedBox(height: 8),
          Text(
            l10n.speedCardAccuracy(
              speedIn(accuracy, unit).toStringAsFixed(1),
              speedUnitLabel(unit),
            ),
            style: TextStyle(fontSize: 10.5, color: colors.muted),
          ),
        ],
      ],
    );
  }
}

/// The acceleration sub-readout: an arrow, a label, and a signed number
/// (design 0044 §3.3 / Q1 ruling (b)).
///
/// Direction is carried by the ARROW and the SIGN, not by colour. One accent
/// for both directions on purpose: braking is not a fault and launching is not
/// a success, so a green/red pairing would be editorialising — and this
/// project's diagnosis routinely runs on monochrome screenshots, where colour
/// carries nothing at all (same reasoning as [_QualityPill]).
class _AccelRow extends StatelessWidget {
  const _AccelRow({required this.aMps2, required this.unit});

  final double aMps2;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    final shown = displayAccel(aMps2);
    final icon = shown > 0
        ? Icons.trending_up
        : shown < 0
            ? Icons.trending_down
            : Icons.trending_flat;
    // Icon, word, number and unit are one indivisible phrase — "ACCEL +5.0
    // km/h/s" means nothing with a piece missing — so the whole row scales
    // together rather than any part of it being dropped or ellipsised. At the
    // widths this card was designed for nothing scales at all.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Icon(icon, size: 15, color: context.accent.accentSecondary),
          const SizedBox(width: 6),
          Text(
            l10n.speedCardAccelLabel,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(fontSize: 11, color: colors.muted),
          ),
          const SizedBox(width: 6),
          Text(
            formatAccel(aMps2, unit),
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: colors.text,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            accelUnitLabel(unit),
            maxLines: 1,
            softWrap: false,
            style: TextStyle(fontSize: 10.5, color: colors.muted),
          ),
        ],
      ),
    );
  }
}

/// [SpeedState.lost]: the headline is the ABSENCE, and the last known speed is
/// demoted to a footnote carrying its own age.
class _LostState extends StatelessWidget {
  const _LostState({required this.estimate, required this.unit});

  final SpeedEstimate estimate;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    final at = estimate.lastLiveAt;
    final age = at == null ? null : estimate.t.difference(at);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.signal_cellular_off, size: 18, color: colors.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.speedCardNoSignal,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
            ),
            _QualityPill(quality: estimate.quality),
          ],
        ),
        if (age != null) ...[
          const SizedBox(height: 8),
          Text(
            l10n.speedCardLastMeasured(
              formatSpeed(estimate.vSmoothMps, unit),
              speedUnitLabel(unit),
              age.inSeconds < 0 ? 0 : age.inSeconds,
            ),
            style: TextStyle(fontSize: 11, height: 1.5, color: colors.muted),
          ),
        ],
      ],
    );
  }
}

/// The four-level signal indicator (§3.2). Icon AND word, because colour alone
/// is not a reading — and because the screenshots this project's diagnosis runs
/// on are frequently monochrome prints.
class _QualityPill extends StatelessWidget {
  const _QualityPill({required this.quality});

  final SpeedSignalQuality quality;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    // 🔴 Four rungs of one scale, told apart by colour alone (the labels are
    // localised words nobody reads at a glance). Fixed status colours, never
    // the accent — design 0064; this switch was missing from the design's
    // classification list and is why `accent_classification_test.dart` covers
    // it explicitly.
    final (IconData icon, Color color, String label) = switch (quality) {
      SpeedSignalQuality.good => (
          Icons.gps_fixed,
          AppSemantics.good,
          l10n.speedQualityGood
        ),
      SpeedSignalQuality.fair => (
          Icons.gps_not_fixed,
          AppSemantics.event,
          l10n.speedQualityFair
        ),
      SpeedSignalQuality.poor => (
          Icons.gps_not_fixed,
          AppSemantics.warn,
          l10n.speedQualityPoor
        ),
      SpeedSignalQuality.none => (
          Icons.gps_off,
          colors.muted,
          l10n.speedQualityNone
        ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(fontSize: 10, letterSpacing: 0.5, color: color),
        ),
      ],
    );
  }
}

/// "Held" — the mark that makes a frozen number distinguishable from a live one
/// at a glance. G2's whole requirement, in one widget.
class _HeldBadge extends StatelessWidget {
  const _HeldBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        // Same "not live" idiom as the dashboard's stale-telemetry bar, and it
        // shares a card with the GPS quality rungs above — so it is a status
        // tone, not the accent (design 0064). Note the READING itself does
        // follow the accent (`held ? muted : accent` further up): that one is
        // accent-vs-muted, which no theme can collapse.
        decoration: BoxDecoration(
          color: AppSemantics.warn.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.pause_circle_outline,
                size: 12, color: AppSemantics.warn),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                letterSpacing: 0.5,
                fontWeight: FontWeight.w600,
                color: AppSemantics.warn,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A card body that is words rather than a number: waiting, or refused.
class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final action = actionLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: colors.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          body,
          style: TextStyle(fontSize: 11, height: 1.6, color: colors.muted),
        ),
        if (action != null && onAction != null) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip2(
              label: action,
              icon: Icons.settings,
              selected: false,
              onTap: onAction!,
            ),
          ),
        ],
      ],
    );
  }
}
