/// OpenSmartBatt — the home editor's tutorial dialog (design 0053).
///
/// ## 🔴 This file exists because a ruling was overturned
///
/// Three standing rulings said this screen carries no explanatory text:
///
///  * design 0046 §4.7 R11 — copy is for (1) warnings before an irreversible
///    action and (2) objective limits; "explaining our own implementation" is
///    the third category, and it was the one being cut;
///  * design 0049 G5 / §3.7 — "no instructions anywhere"; the grab handle, the
///    dashed slot and the insertion line ARE the instructions;
///  * `home_editor_page.dart`'s own header said the same thing in a section
///    titled "No instructions anywhere".
///
/// Owner ruling of 2026-08-09 overturns all three FOR THIS SCREEN ONLY
/// (「議題四 請推翻，以我現在的決定為準」). Design 0053 records it; 0049 and
/// 0046 carry dated notes pointing here, with their original text intact.
///
/// What did NOT change, and must not: the floor is still a disabled delete
/// button, not a message. §4.7's ban on a `SnackBar` that explains a control
/// after you press it is untouched — `home_editor_test.dart` still asserts that
/// pressing the dead ✕ produces neither a `SnackBar` nor a dialog. A tutorial
/// you can dismiss and re-summon is a different object from an interruption
/// that fires on a tap.
///
/// ## Every line here is a gesture that exists
///
/// Nothing in this dialog describes long-press, swipe-to-delete, tapping a
/// card, dragging a card off the page, or pinch-to-zoom. None of those are
/// implemented, and a tutorial for a gesture that does nothing is worse than no
/// tutorial — the user concludes the app is broken. Each paragraph's source is
/// named beside it below.
///
/// ## The pictures are drawn, not shipped
///
/// `pubspec.yaml` declares no assets at all (the launcher PNGs are consumed by
/// `flutter_launcher_icons` and never bundled). Adding four images would mean
/// 1x/2x/3x, a light and a dark set, and — because the diagrams would carry
/// Chinese — one set per locale. So the diagrams are `Container`s plus the
/// SAME [IconData] the editor draws, and the dashed slot is the editor's own
/// [DashedBorderPainter]. Same rule as `GForceBallPainter` being shared with
/// the calibration wizard: a picture drawn by a second implementation agrees
/// with the screen today and drifts tomorrow.
library;

import 'package:flutter/material.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../data/ack_marker.dart';
import '../../theme/app_theme.dart';
import '../widgets/dashed_border.dart';

/// "The user has seen the editor tutorial."
///
/// `_v1` is not decoration: if the copy below is materially rewritten, bumping
/// to `_v2` re-prompts everybody without touching any other code.
const AckMarker kHomeEditorTutorialAck =
    AckMarker('home_editor_tutorial_ack_v1');

/// Show it, and persist the checkbox on whichever way the user leaves.
///
/// The returned future completes only after the marker has been written or
/// cleared, so a caller (and a test) can await the whole transaction.
Future<void> showHomeEditorTutorial(BuildContext context) async {
  Future<void>? write;
  await showDialog<void>(
    context: context,
    // Same scrim as the startup disclaimer (`main.dart`), not the bottom
    // sheet's lighter one — this is a dialog, and two dialogs in one app
    // dimming the screen by different amounts is noticeable.
    barrierColor: const Color(0xD904060A),
    builder: (_) => _HomeEditorTutorialDialog(
      onClosed: (dontShowAgain) => write = dontShowAgain
          ? kHomeEditorTutorialAck.markAcknowledged()
          : kHomeEditorTutorialAck.clear(),
    ),
  );
  await write;
}

/// One row of the dialog: a diagram, a bold lead, and a muted body.
///
/// The two type sizes are `measurement_explainer.dart`'s (13.5/w700 lead,
/// 12.5/1.75 muted body) rather than new ones. The app has exactly one way of
/// laying out an explanatory paragraph, and this is not the place to invent a
/// second.
class _Step {
  const _Step({required this.art, required this.lead, required this.body});

  final Widget art;
  final String lead;
  final String body;
}

class _HomeEditorTutorialDialog extends StatefulWidget {
  const _HomeEditorTutorialDialog({required this.onClosed});

  /// Called with the checkbox state on EVERY exit route — the button, the
  /// system back gesture, and a tap on the barrier. Handing this to
  /// `showDialog`'s return value instead would lose the barrier case, where
  /// the route pops without anyone returning a result.
  final ValueChanged<bool> onClosed;

  @override
  State<_HomeEditorTutorialDialog> createState() =>
      _HomeEditorTutorialDialogState();
}

class _HomeEditorTutorialDialogState extends State<_HomeEditorTutorialDialog> {
  /// 🔴 Starts CHECKED (design 0053, ruling M3).
  ///
  /// The default behaviour is therefore "shown once", which is what a tutorial
  /// should do. Unchecking is a real action in the other direction — the marker
  /// is CLEARED, so the dialog returns on the next visit — which is why
  /// [AckMarker.clear] exists. A box that could only ever set the flag would be
  /// decoration in one of its two positions, i.e. a lie.
  bool _dontShowAgain = true;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    final steps = _steps(l10n, colors);

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) widget.onClosed(_dontShowAgain);
      },
      child: Dialog(
        // The startup disclaimer's shell, to the pixel.
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 360,
            // 🔴 The height clamp is load-bearing, not defensive.
            //
            // `AppTheme.baseTextScale` is 1.15 ON TOP of the OS setting, so
            // four illustrated paragraphs are taller than a 360 pt phone before
            // the user has enlarged anything. Without both this and the
            // scroll view below, the Column overflows and Flutter paints the
            // striped bar over the last paragraph.
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    l10n.homeEditTutorialTitle,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: colors.text,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < steps.length; i++)
                        _StepRow(step: steps[i], last: i == steps.length - 1),
                    ],
                  ),
                ),
              ),
              _Footer(
                dontShowAgain: _dontShowAgain,
                onToggle: () =>
                    setState(() => _dontShowAgain = !_dontShowAgain),
                onDone: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // The content. Every claim's source is on the line above it.
  // ---------------------------------------------------------------------------
  List<_Step> _steps(AppLocalizations l10n, AppPalette colors) => [
        // `_EditorCell`: the ONLY `Draggable` is the handle, and the tile body
        // sits inside an `AbsorbPointer`. `_onDragMoved` + `_autoScrollTick`
        // are the edge auto-scroll.
        _Step(
          art: const _GlyphArt(Icons.drag_indicator, color: AppColors.amber),
          lead: l10n.homeEditTutorialDragLead,
          body: l10n.homeEditTutorialDragBody,
        ),
        // `_onDropOnTile` → `HomeGridOps.swap` (each keeps its own span),
        // `_onDropOnLine` → `moveToOwnRow`, `_onDropInSlot` → `moveIntoSlot`
        // (which sets `span: half` — design 0049 §3.3, no shape button first).
        _Step(
          art: _DropTargetsArt(colors: colors),
          lead: l10n.homeEditTutorialDropLead,
          body: l10n.homeEditTutorialDropBody,
        ),
        // The shape `IconButton` (`Icons.crop_16_9` ↔ `Icons.crop_square`) →
        // `HomeGridOps.toggleSpan`, whose `normalise` gives a new half its
        // empty partner.
        _Step(
          art: _SpanArt(colors: colors),
          lead: l10n.homeEditTutorialShapeLead,
          body: l10n.homeEditTutorialShapeBody,
        ),
        // The delete `IconButton` is `onPressed: null` at `canDelete == false`;
        // `_showAddSheet` filters by product class; `_apply` calls `_persist`
        // on every change, and there is no save button anywhere on the page.
        _Step(
          art: const _GlyphArt(Icons.close, color: AppColors.danger),
          lead: l10n.homeEditTutorialManageLead,
          body: l10n.homeEditTutorialManageBody,
        ),
      ];
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.last});

  final _Step step;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border:
            last ? null : Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: _kArtWidth, child: step.art),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.lead,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: colors.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  step.body,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.75,
                    color: colors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The checkbox row and the single full-width button (design 0053, 勾選框方案 1).
///
/// The checkbox sits ABOVE the button and spans the whole width: the finger
/// travelling down to "got it" passes over it, and the hit area is the row
/// rather than the 18 px square — the same 44 pt reasoning design 0049 R3 used
/// to widen the insertion line from a hairline to a band.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.dontShowAgain,
    required this.onToggle,
    required this.onDone,
  });

  final bool dontShowAgain;
  final VoidCallback onToggle;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
              child: Row(
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: dontShowAgain
                          ? AppColors.amber
                          : Colors.transparent,
                      borderRadius:
                          BorderRadius.circular(AppTheme.radiusSm),
                      border: Border.all(
                        color:
                            dontShowAgain ? AppColors.amber : colors.muted,
                        width: 1.6,
                      ),
                    ),
                    child: dontShowAgain
                        ? const Icon(Icons.check,
                            size: 13, color: AppColors.onAmber)
                        : null,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      l10n.homeEditTutorialDontShowAgain,
                      style: TextStyle(fontSize: 12.5, color: colors.muted),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onDone,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  l10n.homeEditTutorialGotIt,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The diagrams. Geometry + the editor's own icons; no image assets.
// ---------------------------------------------------------------------------

const double _kArtWidth = 78;
const double _kArtHeight = 56;

/// A single icon in a framed box — used where the thing being explained IS a
/// control, so the picture is that control's own [IconData] at a legible size.
class _GlyphArt extends StatelessWidget {
  const _GlyphArt(this.icon, {required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => _ArtFrame(
        child: Center(child: Icon(icon, size: 26, color: color)),
      );
}

/// The three drop targets, stacked: a card, the insertion line, and a
/// half-width pair whose right half is the dashed empty slot.
class _DropTargetsArt extends StatelessWidget {
  const _DropTargetsArt({required this.colors});

  final AppPalette colors;

  @override
  Widget build(BuildContext context) => _ArtFrame(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Blk(colors: colors, highlighted: true),
            const SizedBox(height: 3),
            Container(
              height: 2,
              decoration: BoxDecoration(
                color: AppColors.amber,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                Expanded(child: _Blk(colors: colors)),
                const SizedBox(width: 3),
                Expanded(child: _Blk(colors: colors, dashed: true)),
              ],
            ),
          ],
        ),
      );
}

/// Full width above, two halves below — the two states of the shape button.
class _SpanArt extends StatelessWidget {
  const _SpanArt({required this.colors});

  final AppPalette colors;

  @override
  Widget build(BuildContext context) => _ArtFrame(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Blk(colors: colors),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(child: _Blk(colors: colors)),
                const SizedBox(width: 3),
                Expanded(child: _Blk(colors: colors)),
              ],
            ),
          ],
        ),
      );
}

class _ArtFrame extends StatelessWidget {
  const _ArtFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: _kArtHeight,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: colors.panel2,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: colors.line),
      ),
      child: child,
    );
  }
}

/// One card-shaped rectangle inside a diagram.
///
/// [dashed] uses the editor's real [DashedBorderPainter] rather than a second
/// dash pattern — see `dashed_border.dart`.
class _Blk extends StatelessWidget {
  const _Blk({
    required this.colors,
    this.highlighted = false,
    this.dashed = false,
  });

  final AppPalette colors;
  final bool highlighted;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    if (dashed) {
      return CustomPaint(
        painter: DashedBorderPainter(
            color: colors.line2, radius: AppTheme.radiusSm),
        child: const SizedBox(height: 14, width: double.infinity),
      );
    }
    return Container(
      height: 14,
      decoration: BoxDecoration(
        color: highlighted
            ? AppColors.amber.withValues(alpha: 0.18)
            : colors.panel,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border:
            Border.all(color: highlighted ? AppColors.amber : colors.line2),
      ),
    );
  }
}
