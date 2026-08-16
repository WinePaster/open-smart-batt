/// OpenSmartBatt — the calibration wizard (design 0045 §3.2 / §3.5).
///
/// A full-screen route reached ONLY from Settings. Design 0045 §3.5 put it here
/// rather than on the dashboard card and §3.6 then removed the card's
/// placeholder entirely, so this route and the switch beside it carry all of
/// the feature's guidance between them.
///
/// ## Four pages, and the last one is not decoration
///
///  1. **Mount it.** The calibration describes a physical position; saying so
///     first is what stops someone calibrating a phone in their hand.
///  2. **Hold still.** Averages the raw stream to find "up". Any movement fails
///     the window outright — an average of gravity plus walking is not gravity.
///  3. **Pull away straight.** Fixes "forward" from the first sustained launch.
///  4. **Check it.** A LIVE ball, before anything is saved.
///
/// 🔴 Page 4 is the entire mitigation for the one assumption this feature
/// cannot verify from the inside. Design 0045 §3.2 is candid that a launch
/// taken while turning points "forward" the wrong way, and no arithmetic can
/// detect that — the numbers are self-consistent either way. What can detect it
/// is the rider watching whether accelerating pushes the dot straight up. So
/// nothing is written until they have had the chance, and "calibrate again" is
/// one tap away on the same page.
///
/// The result is committed by THIS screen through `SettingsController`, not by
/// the controller that produced it — see `g_force_controller.dart` for why
/// there is exactly one writer of that column.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../dashboard/g_force_card.dart';
import '../widgets/industrial.dart';

/// Push the wizard. Returns true when a calibration was saved.
Future<bool> showGCalibrationWizard(BuildContext context) async {
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => const GCalibrationWizard()),
  );
  return saved ?? false;
}

class GCalibrationWizard extends StatefulWidget {
  const GCalibrationWizard({super.key});

  @override
  State<GCalibrationWizard> createState() => _GCalibrationWizardState();
}

class _GCalibrationWizardState extends State<GCalibrationWizard> {
  GForceController? _g;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _g = context.read<GForceController>();
  }

  @override
  void dispose() {
    // Leaving the page closes the sensor streams whatever state the wizard was
    // in. An abandoned wizard that kept the accelerometer open would be the
    // quietest possible battery leak.
    _g?.cancelCalibration();
    super.dispose();
  }

  void _start() {
    setState(() => _started = true);
    _g!.startCalibration();
  }

  Future<void> _save() async {
    final session = _g!.calibrationSession;
    final result = session?.result;
    if (result == null) return;
    final navigator = Navigator.of(context);
    await context.read<SettingsController>().setGCalibration(result.encode());
    _g!.cancelCalibration();
    navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final g = context.watch<GForceController>();
    final phase = g.calibrationSession?.phase ?? CalibrationPhase.idle;

    return Scaffold(
      backgroundColor: context.colors.bg,
      appBar: AppBar(
        backgroundColor: context.colors.panel,
        title: Text(l10n.gWizardTitle, style: const TextStyle(fontSize: 15)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: !_started
                  ? _Step(
                      icon: Icons.smartphone,
                      title: l10n.gWizardMountTitle,
                      body: l10n.gWizardMountBody,
                      actionLabel: l10n.gWizardStart,
                      onAction: _start,
                    )
                  : switch (phase) {
                      CalibrationPhase.idle ||
                      CalibrationPhase.samplingGravity =>
                        _Step(
                          icon: Icons.pause_circle_outline,
                          title: l10n.gWizardStillTitle,
                          body: l10n.gWizardStillBody,
                          progress:
                              g.calibrationSession?.gravityProgress ?? 0,
                        ),
                      CalibrationPhase.failedMotion => _Step(
                          icon: Icons.error_outline,
                          title: l10n.gWizardMovedTitle,
                          body: l10n.gWizardMovedBody,
                          actionLabel: l10n.gWizardRetry,
                          onAction: _start,
                        ),
                      CalibrationPhase.waitingLaunch => _Step(
                          icon: Icons.moving,
                          title: l10n.gWizardLaunchTitle,
                          body: l10n.gWizardLaunchBody,
                          progress: null,
                          indeterminate: true,
                        ),
                      CalibrationPhase.complete => _DoneStep(
                          onSave: _save,
                          onRetry: _start,
                        ),
                    },
            ),
          ),
        ),
      ),
    );
  }
}

/// One instruction page: a glyph, a heading, a paragraph, at most one button.
class _Step extends StatelessWidget {
  const _Step({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.progress,
    this.indeterminate = false,
  });

  final IconData icon;
  final String title, body;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 0…1 for the still window's ring, or null for no ring.
  final double? progress;
  final bool indeterminate;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return IndustrialCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 6),
          Icon(icon, size: 34, color: context.accent.accent),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: colors.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.6, color: colors.muted),
          ),
          if (progress != null || indeterminate) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: indeterminate ? null : progress,
              backgroundColor: colors.line,
              color: context.accent.accent,
            ),
          ],
          if (actionLabel != null) ...[
            const SizedBox(height: 16),
            TextButton(
              onPressed: onAction,
              child: Text(actionLabel!,
                  style: TextStyle(color: context.accent.accent)),
            ),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// The last page: the live ball, then save or start over.
class _DoneStep extends StatelessWidget {
  const _DoneStep({required this.onSave, required this.onRetry});

  final Future<void> Function() onSave;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    final r = context.watch<GForceController>().previewReading;
    return IndustrialCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 6),
          Text(
            l10n.gWizardDoneTitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: colors.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.gWizardDoneBody,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.6, color: colors.muted),
          ),
          const SizedBox(height: 14),
          Center(
            child: SizedBox(
              width: 180,
              height: 180,
              child: CustomPaint(
                // The SAME painter the card uses, on the same axis convention.
                // A preview drawn by a second implementation could agree with
                // the card today and drift tomorrow, and the whole point of
                // this page is that what it shows is what the rider will see.
                painter: GForceBallPainter(
                  dot: Offset(-(r?.latG ?? 0), -(r?.longG ?? 0)),
                  trail: const [],
                  ring: colors.line2,
                  grid: colors.line,
                  dotColor: context.accent.accent,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton(
                onPressed: onRetry,
                child: Text(l10n.gWizardRecalibrate,
                    style: TextStyle(color: colors.muted)),
              ),
              TextButton(
                onPressed: () => onSave(),
                child: Text(l10n.gWizardSave,
                    style: TextStyle(color: context.accent.accent)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
