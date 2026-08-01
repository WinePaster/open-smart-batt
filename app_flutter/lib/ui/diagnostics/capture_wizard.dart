/// OpenSmartBatt — guided capture run.
///
/// Single marks (the dashboard bar) cover a spontaneous observation. This walks
/// someone through the whole differential script instead, and its real value is
/// the one thing an unguided user will not do reliably: **stay in each state
/// long enough**. One field capture's shortest session was 2 seconds, which
/// produced nothing usable. Every step here enforces a minimum dwell before it
/// will advance.
///
/// It also records CLOSED intervals — `mark:` on entry, `mark_end:` on exit — so
/// the analysis side gets a span rather than a start, and writes an explicit
/// `mark: skipped |` line for steps the user passes over. "The user skipped
/// this" and "the data is missing" are different facts, and only one of them is
/// a reason to ask for a re-capture — the same distinction the export headers
/// draw when they count the rows they left out.
///
/// Raw packet logging is switched on for the duration and RESTORED afterwards:
/// marks without packets correlate with nothing, but silently leaving a
/// diagnostic setting on is not ours to do either.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';

/// Minimum time in each state before the run will advance.
///
/// Eight seconds is the telemetry stall threshold and a power bank's poll gap
/// runs to ~8 s, so anything shorter can legitimately contain zero frames of
/// the state being declared. Ten gives one full burst plus margin.
const Duration kCaptureStepDwell = Duration(seconds: 10);

/// Run the guided capture for [marks]. Returns true if it reached the end.
Future<bool> showCaptureWizard(
  BuildContext context, {
  required List<CaptureMark> marks,
  required String Function(CaptureMark) labelFor,
}) async {
  final done = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CaptureWizard(marks: marks, labelFor: labelFor),
  );
  return done ?? false;
}

class _CaptureWizard extends StatefulWidget {
  const _CaptureWizard({required this.marks, required this.labelFor});

  final List<CaptureMark> marks;
  final String Function(CaptureMark) labelFor;

  @override
  State<_CaptureWizard> createState() => _CaptureWizardState();
}

class _CaptureWizardState extends State<_CaptureWizard> {
  int _index = 0;
  int _elapsed = 0;
  Timer? _tick;

  /// The raw-logging setting as we found it, restored on the way out.
  bool? _loggingWasOn;

  ConnectionController get _conn => context.read<ConnectionController>();

  CaptureMark get _current => widget.marks[_index];

  @override
  void initState() {
    super.initState();
    // Deferred: this runs before the first frame, and both calls touch
    // inherited widgets.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final settings = context.read<SettingsController>();
    _loggingWasOn = settings.rawPacketLog;
    if (!settings.rawPacketLog) await settings.setRawPacketLog(true);
    _enterStep();
  }

  void _enterStep() {
    _conn.markCaptureState(_current, widget.labelFor(_current));
    _elapsed = 0;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed++);
    });
    setState(() {});
  }

  void _closeStep() {
    _tick?.cancel();
    _conn.markCaptureEnd(_current);
  }

  void _advanceFrom(int index) {
    if (index + 1 >= widget.marks.length) {
      _finish(completed: true);
      return;
    }
    setState(() => _index = index + 1);
    _enterStep();
  }

  void _next() {
    _closeStep();
    _advanceFrom(_index);
  }

  void _skip() {
    _tick?.cancel();
    // Deliberately NOT a mark_end: the step never really ran, and pretending it
    // did would hand the analysis side an interval containing unrelated data.
    _conn.markCaptureSkipped(_current);
    _advanceFrom(_index);
  }

  Future<void> _finish({required bool completed}) async {
    _tick?.cancel();
    final settings = context.read<SettingsController>();
    final navigator = Navigator.of(context);
    // Restore rather than leave it on: we borrowed the setting, we give it back.
    if (_loggingWasOn == false) await settings.setRawPacketLog(false);
    navigator.pop(completed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    final remaining = kCaptureStepDwell.inSeconds - _elapsed;
    final ready = remaining <= 0;

    return AlertDialog(
      title: Text(
        l10n.captureWizardStep(_index + 1, widget.marks.length),
        style: const TextStyle(fontSize: 15),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.labelFor(_current),
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700, color: colors.text),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(ready ? Icons.check_circle_outline : Icons.timer_outlined,
                  size: 16, color: ready ? AppColors.good : AppColors.amber),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  ready
                      ? l10n.captureWizardHoldDone
                      : l10n.captureWizardHold(remaining),
                  style: TextStyle(fontSize: 12, color: colors.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: (_elapsed / kCaptureStepDwell.inSeconds).clamp(0.0, 1.0),
            minHeight: 3,
            backgroundColor: colors.line,
            color: ready ? AppColors.good : AppColors.amber,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => _finish(completed: false),
          child: Text(l10n.captureWizardAbort),
        ),
        TextButton(
          onPressed: _skip,
          child: Text(l10n.captureWizardSkip),
        ),
        TextButton(
          // Disabled until the dwell is met — this is the whole point of the
          // guided run, so it is enforced rather than suggested.
          onPressed: ready ? _next : null,
          child: Text(l10n.captureWizardNext),
        ),
      ],
    );
  }
}
