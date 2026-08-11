/// OpenSmartBatt — alias-naming dialog (mockup `.aliasdlg` / `.adlg`).
///
/// Shown after connecting a freshly-discovered device ("儲存裝置") so the user
/// can give it a memorable alias for quick reconnect, and reused as the rename
/// editor behind the saved-device pencil. Returns the chosen alias, or null if
/// the user skips/cancels.
library;

import 'package:flutter/material.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// Prompt for a device alias.
///
///   * [initial] pre-fills the field (rename flow).
///   * [isRename] swaps the copy/labels between "save new" and "rename".
///
/// Resolves to the trimmed alias on save, or null on skip/dismiss.
Future<String?> showAliasDialog(
  BuildContext context, {
  String initial = '',
  bool isRename = false,
}) {
  return showDialog<String>(
    context: context,
    barrierColor: const Color(0xD904060A), // mockup rgba(4,6,10,.85)
    // 🔴 Explicitly false — it DEFAULTS TO TRUE, and the default was the second
    // silent way to lose a save (found 2026-08-11 while analysing FB batch
    // `08.11/005`, a third independent「無法儲存裝置」report).
    //
    // Tapping the barrier pops with null, and null is how every caller spells
    // "the user declined": no record, no message, nothing on screen changes.
    // That is the same dead end the empty-field bug produced, reached by a
    // gesture nobody thinks of as an answer.
    //
    // And it is the gesture this dialog invites: the field is `autofocus: true`,
    // so the keyboard is up the moment it opens, and tapping outside a field to
    // dismiss a keyboard is a reflex. On a 375 pt-wide phone — the reporter's
    // iPhone X — there is barely anywhere else to put that tap.
    //
    // The app's other two dialogs already pass false (`main.dart:660`,
    // `capture_wizard.dart:47`); this one being open was an omission, not a
    // decision. Closing it costs nothing: 儲存 and 跳過 are both one tap away,
    // and on Android the back button still cancels — an explicit gesture, not
    // a stray one.
    barrierDismissible: false,
    builder: (_) => _AliasDialog(initial: initial, isRename: isRename),
  );
}

class _AliasDialog extends StatefulWidget {
  const _AliasDialog({required this.initial, required this.isRename});

  final String initial;
  final bool isRename;

  @override
  State<_AliasDialog> createState() => _AliasDialogState();
}

class _AliasDialogState extends State<_AliasDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 🔴 An empty field returns '' — NOT null (2026-08-11, reported on v0.7.12
  /// and v0.7.13 as「儲存裝置後沒反應」, and almost certainly the same thing a
  /// dealer described the same day as「新儲存的也不會顯示」).
  ///
  /// This used to pop `null` when the field was blank, and every caller reads
  /// null as "the user declined" — so pressing 儲存 without typing did exactly
  /// what pressing 跳過 does: closed the dialog, saved nothing, said nothing.
  /// The button is filled amber and looks perfectly live, so there was no clue
  /// at all; the user believes the unit is saved and then cannot find it in the
  /// list or open its page, because it never existed.
  ///
  /// The two buttons now mean two different things, which is the least a pair of
  /// buttons can be asked to do:
  ///   * 跳過 / 取消 → null → nothing is written;
  ///   * 儲存 → the text, empty or not → the record is written.
  ///
  /// An empty alias was ALWAYS a supported value — the list has rendered it as
  /// 未命名裝置 since design 0046 (`devices_page.dart`), and the pencil renames
  /// it. The only thing missing was a way to produce one.
  void _submit() => Navigator.of(context).pop(_ctrl.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title =
        widget.isRename ? l10n.devicesAliasRenameTitle : l10n.devicesAliasSaveTitle;
    final body =
        widget.isRename ? l10n.devicesAliasRenameBody : l10n.devicesAliasSaveBody;
    final saveLabel =
        widget.isRename ? l10n.devicesAliasSave : l10n.devicesAliasSaveAlias;
    final cancelLabel = widget.isRename ? l10n.commonCancel : l10n.devicesAliasSkip;
    // Suggestion chips (mockup `.achips`).
    final suggestions = [
      l10n.devicesAliasSuggestion1,
      l10n.devicesAliasSuggestion2,
      l10n.devicesAliasSuggestion3,
    ];

    return Dialog(
      insetPadding: const EdgeInsets.all(26),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: context.colors.text,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                body,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.6,
                  color: context.colors.muted,
                ),
              ),
              const SizedBox(height: 15),
              TextField(
                controller: _ctrl,
                autofocus: true,
                style: TextStyle(fontSize: 14, color: context.colors.text),
                cursorColor: AppColors.amber,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: l10n.devicesAliasHint,
                  isDense: true,
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final s in suggestions)
                    _Chip(label: s, onTap: () => _ctrl.text = s),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _DialogButton(
                      label: cancelLabel,
                      filled: false,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _DialogButton(
                      label: saveLabel,
                      filled: true,
                      onTap: _submit,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Suggestion chip (mockup `.achip`).
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: context.colors.panel2,
          border: Border.all(color: context.colors.line),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11, color: context.colors.muted),
        ),
      ),
    );
  }
}

/// Dialog action button (mockup `.adlg .arow button`).
class _DialogButton extends StatelessWidget {
  const _DialogButton({
    required this.label,
    required this.filled,
    required this.onTap,
  });

  final String label;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? AppColors.amber : context.colors.panel2,
          border: Border.all(
            color: filled ? Colors.transparent : context.colors.line,
          ),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: filled ? AppColors.onAmber : context.colors.muted,
          ),
        ),
      ),
    );
  }
}
