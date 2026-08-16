/// OpenSmartBatt — the G meter card (design 0045 §3.6).
///
/// A ball with a dot on it, and three numbers. Up is acceleration, down is
/// braking, left and right are cornering — the racing convention, and the one
/// the mock-up the owner approved uses.
///
/// ## This card has ONE state
///
/// Design 0045 Q8 removed the "not calibrated" placeholder that an earlier
/// draft put here. There is no greyed-out version, no "calibrate me" card, no
/// waiting state: either the G meter is available and this draws, or the module
/// is not laid out at all and nothing occupies the space. `renderedModules`
/// makes that decision, once, for the whole page.
///
/// 🔴 The cost of that is recorded in design 0045 R1 rather than softened: a
/// user who turns the switch on and never calibrates sees NOTHING on the
/// dashboard and no hint that a step is missing. All of the guidance lives in
/// Settings, where the switch is — which is why turning the switch on runs
/// straight into the wizard rather than merely writing a flag.
///
/// ## Two clocks, deliberately
///
/// The numbers update no faster than [GForceConfig.readoutThrottle] (200 ms);
/// the dot redraws with them. Design 0045 G3's rule is about DIGITS: a number
/// flickering ten times a second is worse than no number, while a graphic
/// sliding smoothly is not the same complaint. The trail is what buys the dot
/// its smoothness back without speeding the digits up.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial_card.dart';

/// Longitudinal / lateral G with a ball, a peak hold and a tap to zero it.
class GForceCard extends StatefulWidget {
  const GForceCard({super.key});

  @override
  State<GForceCard> createState() => _GForceCardState();
}

class _GForceCardState extends State<GForceCard> {
  /// Captured rather than read in [dispose] — by then this element is detached
  /// and `context.read` is no longer legal. Same shape as `SpeedCard`.
  GForceController? _g;

  /// Recent dots, oldest first. Held by the WIDGET rather than the controller:
  /// it is a presentation detail with no meaning outside this card, and putting
  /// it in the controller would make the trail survive the card being unmounted.
  final List<Offset> _trail = <Offset>[];
  static const int _trailLength = 8;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _g = context.read<GForceController>();
    _setFaceWantsGForce(true);
  }

  @override
  void dispose() {
    _setFaceWantsGForce(false);
    super.dispose();
  }

  /// Deferred to the end of the frame for `SpeedCard`'s reason: the setter
  /// notifies listeners, and both call sites run inside build/teardown, where
  /// notifying would mark widgets dirty while they are being built.
  void _setFaceWantsGForce(bool v) {
    final g = _g;
    if (g == null) return;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => g.setFaceWantsGForce(v));
  }

  @override
  Widget build(BuildContext context) {
    final g = context.watch<GForceController>();
    final r = g.reading ?? GForceReading.zero;

    final dot = Offset(-r.latG, -r.longG);
    if (_trail.isEmpty || _trail.last != dot) {
      _trail.add(dot);
      if (_trail.length > _trailLength) _trail.removeAt(0);
    }

    return GForceCardBody(
      reading: r,
      trail: List<Offset>.of(_trail),
      onResetPeak: () {
        _trail.clear();
        g.resetPeak();
      },
    );
  }
}

/// The card's BODY, given a reading — no controller and no accelerometer.
///
/// Split out of [GForceCard] by design 0051 §5.2, for [SpeedCardBody]'s exact
/// reason: mounting the real card calls `setFaceWantsGForce(true)` in
/// `didChangeDependencies`, so the home editor cannot show what this card looks
/// like without starting the sensor. It mounts this instead.
class GForceCardBody extends StatelessWidget {
  const GForceCardBody({
    super.key,
    required this.reading,
    required this.trail,
    this.onResetPeak,
  });

  final GForceReading reading;

  /// Recent dots, oldest first, already in screen sense.
  final List<Offset> trail;

  /// Null in the preview — there is no peak to reset in a layout editor, and
  /// a tap target that did nothing would read as a broken control.
  final VoidCallback? onResetPeak;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final r = reading;
    final dot = Offset(-r.latG, -r.longG);

    return IndustrialCard(
      heading: l10n.gForceCardHeading,
      headingIcon: Icons.adjust,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            // A gutter, because three Expandeds share an edge and `−0.42+0.18`
            // with no gap between them reads as one number.
            spacing: 8,
            children: [
              Expanded(
                child: _GReadout(
                  label: l10n.gForceLongLabel,
                  value: r.longG,
                  // The word, not a sign alone: "−0.42 brake" reads at a
                  // glance on a moving bike; "−0.42" needs a moment's thought.
                  note: r.longG == 0
                      ? null
                      : (r.isBraking ? l10n.gForceBrake : l10n.gForceAccel),
                ),
              ),
              Expanded(
                child: _GReadout(
                  label: l10n.gForceLatLabel,
                  value: r.latG,
                  note: r.latG == 0
                      ? null
                      : (r.isLeft ? l10n.gForceLeft : l10n.gForceRight),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onResetPeak,
                  child: _GReadout(
                    label: l10n.gForcePeakLabel,
                    value: r.peakG,
                    // Always positive, so no sign — a peak has no direction,
                    // it is the worst of both axes combined.
                    signed: false,
                    emphasised: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.gForceResetPeakHint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: context.colors.muted),
          ),
          const SizedBox(height: 10),
          Center(
            child: LayoutBuilder(
              builder: (context, c) {
                final size = math.min(c.maxWidth, 190.0);
                return SizedBox(
                  width: size,
                  height: size,
                  child: CustomPaint(
                    painter: GForceBallPainter(
                      dot: dot,
                      trail: trail,
                      ring: context.colors.line2,
                      grid: context.colors.line,
                      dotColor: context.accent.accent,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One number, its label and an optional direction word.
class _GReadout extends StatelessWidget {
  const _GReadout({
    required this.label,
    required this.value,
    this.note,
    this.signed = true,
    this.emphasised = false,
  });

  final String label;
  final double value;
  final String? note;

  /// Whether to print a leading `+` on positive values. Design 0044 §3.3's
  /// rule, borrowed: an always-signed number cannot be misread as a magnitude.
  final bool signed;

  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = signed
        ? '${value >= 0 ? '+' : '−'}${value.abs().toStringAsFixed(2)}'
        : value.toStringAsFixed(2);
    return Column(
      children: [
        Text(
          label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 0.6,
            fontWeight: FontWeight.w700,
            color: colors.muted,
          ),
        ),
        const SizedBox(height: 2),
        // 🔴 Never wraps. Three of these share the card's width, so in a 1x1
        // home tile each gets roughly a third of ~220 px — not enough for
        // `+0.00` at 22 px, and the default behaviour is to break the number
        // ACROSS TWO LINES: `+0.` above `00`. Reported from the field on
        // v0.7.8 (2026-08-07) as「這排版實在是」, and it is worse than ugly —
        // a G reading split over two lines is briefly readable as a different
        // number.
        //
        // scaleDown rather than a smaller font: at full width (the riding
        // watchface, where this card was designed) nothing changes at all,
        // and the shrinking is proportional to how little room there actually
        // is. `home_editor_page.dart` lets the user set any tile to 1x1, so
        // "just make the default full width" would not have been enough.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            text,
            maxLines: 1,
            softWrap: false,
            style: AppTextStyles.mono(context).copyWith(
              fontSize: 22,
              height: 1.1,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: emphasised ? context.accent.accent : colors.text,
            ),
          ),
        ),
        Text(
          // The unit is on every row rather than once in the heading: this card
          // is read at a glance, and `g` is the only thing that says these are
          // not metres per second squared.
          note == null ? 'g' : 'g · ${note!}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10, color: colors.muted),
        ),
      ],
    );
  }
}

/// The ball: rings at 0.5 g and 1.0 g, crosshairs, a fading trail, and the dot.
///
/// Context-free, following `pvlt_gauge.dart`: no localization lookup and no
/// theme lookup happen in here — every colour arrives as a parameter. A painter
/// that read the theme could not be exercised without a full widget tree.
class GForceBallPainter extends CustomPainter {
  const GForceBallPainter({
    required this.dot,
    required this.trail,
    required this.ring,
    required this.grid,
    required this.dotColor,
    this.fullScaleG = 1.0,
  });

  /// Where the dot goes, in g, ALREADY converted to screen sense: x positive is
  /// to the right of the screen, y positive is DOWN. The card does that
  /// conversion (`-latG`, `-longG`) so the painter has no opinion about which
  /// way a corner leans.
  final Offset dot;

  /// Older dots, oldest first.
  final List<Offset> trail;

  final Color ring, grid, dotColor;

  /// g at the outer ring.
  final double fullScaleG;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2 - 2;
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = ring;
    canvas.drawCircle(c, r, ringPaint);
    canvas.drawCircle(c, r / 2, ringPaint..color = grid);
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), ringPaint);
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), ringPaint);

    Offset place(Offset g) {
      final scaled = Offset(
        g.dx / fullScaleG * r,
        g.dy / fullScaleG * r,
      );
      // Clamp to the ring rather than letting a big reading leave the card. A
      // dot pinned at the edge still says "more than full scale", which is the
      // honest rendering; a dot outside the circle says nothing at all.
      final d = scaled.distance;
      return c + (d > r ? scaled * (r / d) : scaled);
    }

    for (var i = 0; i < trail.length; i++) {
      final fade = (i + 1) / (trail.length + 1);
      canvas.drawCircle(
        place(trail[i]),
        2.5,
        Paint()..color = dotColor.withValues(alpha: 0.25 * fade),
      );
    }
    canvas.drawCircle(place(dot), 5, Paint()..color = dotColor);
  }

  @override
  bool shouldRepaint(GForceBallPainter old) =>
      old.dot != dot ||
      old.trail.length != trail.length ||
      old.ring != ring ||
      old.grid != grid ||
      old.dotColor != dotColor;
}
