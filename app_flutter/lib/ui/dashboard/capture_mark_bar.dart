/// OpenSmartBatt — capture state marking bar.
///
/// The bar exists because several registers cannot be resolved from passive
/// captures at all: nothing in the stream distinguishes Type-A from Type-C, or
/// charging from standby. Someone has to say which is which, and the only
/// person who knows is the user holding the device.
///
/// It sits on the dashboard rather than in Settings on purpose. The differential
/// scripts we ask people to run switch state every few seconds; a control that
/// costs a trip to another screen per switch does not get used.
///
/// Visible ONLY while raw packet logging is on. That gate is the design's main
/// defence against silent failure: a mark with no packets beside it correlates
/// with nothing, and a user who taps a button believing their ground truth was
/// captured — when it was not — produces mislabelled data, which is worse than
/// no data.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'capture_mark_labels.dart';

/// Collapsible strip of state marks for the connected unit.
class CaptureMarkBar extends StatefulWidget {
  const CaptureMarkBar({super.key});

  @override
  State<CaptureMarkBar> createState() => _CaptureMarkBarState();
}

class _CaptureMarkBarState extends State<CaptureMarkBar> {
  bool _open = false;

  Future<void> _tap(BuildContext context, CaptureMark m) async {
    final l10n = AppLocalizations.of(context);
    final conn = context.read<ConnectionController>();
    final messenger = ScaffoldMessenger.of(context);
    final label = captureMarkLabel(l10n, m);

    String? note;
    if (m == CaptureMark.note) {
      note = await _askNote(context);
      if (note == null || note.isEmpty) return;
    }
    conn.markCaptureState(m, label, note: note);
    messenger.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 1400),
      content: Text(l10n.captureMarkSaved(note ?? label)),
    ));
  }

  Future<String?> _askNote(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.captureMarkNote),
        content: TextField(
          controller: controller,
          autofocus: true,
          // Bounded: this text is exported verbatim, and a long free-text field
          // invites personal details into a file the user will share.
          maxLength: 40,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final logging =
        context.select<SettingsController, bool>((s) => s.rawPacketLog);
    if (!logging) return const SizedBox.shrink();
    final online = context.select<ConnectionController, bool>((c) => c.isOnline);
    if (!online) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    final cls =
        context.select<ConnectionController, ProductClass>((c) => c.packLabel);
    final marks = CaptureMark.forClass(cls);

    return Container(
      margin: const EdgeInsets.fromLTRB(15, 0, 15, 12),
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(13, 11, 11, 11),
              child: Row(
                children: [
                  const Icon(Icons.bookmark_add_outlined,
                      size: 16, color: AppColors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.captureMarkHeading,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: colors.text),
                    ),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 18, color: colors.muted),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 0, 13, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.captureMarkSub,
                    style: TextStyle(
                        fontSize: 10.5, height: 1.6, color: colors.muted),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final m in marks)
                        _MarkChip(
                          label: captureMarkLabel(l10n, m),
                          onTap: () => _tap(context, m),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MarkChip extends StatelessWidget {
  const _MarkChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: colors.panel2,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 11.5, color: colors.text)),
      ),
    );
  }
}
