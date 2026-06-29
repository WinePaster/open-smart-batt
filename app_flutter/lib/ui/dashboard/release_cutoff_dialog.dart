/// Open-RCE-Batt — release cut-off auth dialog (mockup 解除斷電 flow).
///
/// The documented-safe action is `switchMode(release=0x06)` paired with an auth
/// frame built from per-device runtime inputs: a `cb` derived from the dealer
/// code (selector 0x27) and a `pwSum` = 16-bit checksum of the cut-off password
/// (PROTOCOL.md). Those values are redacted/unknown and must be entered by the
/// user, so this dialog collects them and derives [AuthCredentials] locally.
///
/// SAFETY: only release (mode 0x06) is sent by callers of this dialog; we never
/// auto-send other mode codes. The copy reproduces the mockup's "do not re-lock"
/// warning.
library;

import 'package:flutter/material.dart';

import '../../protocol/protocol.dart';
import '../../theme/app_theme.dart';

/// Prompt for the dealer code + cut-off password, returning the derived
/// [AuthCredentials] on confirm, or null on cancel/dismiss.
///
/// [initialDealerCode] pre-fills the dealer-code field from live telemetry
/// (selector 0x27) when available.
Future<AuthCredentials?> showReleaseCutOffDialog(
  BuildContext context, {
  String? initialDealerCode,
}) {
  return showDialog<AuthCredentials>(
    context: context,
    barrierColor: const Color(0xD904060A), // mockup rgba(4,6,10,.85)
    builder: (_) => _ReleaseDialog(initialDealerCode: initialDealerCode ?? ''),
  );
}

class _ReleaseDialog extends StatefulWidget {
  const _ReleaseDialog({required this.initialDealerCode});

  final String initialDealerCode;

  @override
  State<_ReleaseDialog> createState() => _ReleaseDialogState();
}

class _ReleaseDialogState extends State<_ReleaseDialog> {
  late final TextEditingController _dealer =
      TextEditingController(text: widget.initialDealerCode);
  final TextEditingController _password = TextEditingController();

  @override
  void dispose() {
    _dealer.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _dealer.text.trim().isNotEmpty && _password.text.isNotEmpty;

  void _submit() {
    if (!_canSubmit) return;
    final cb = CommandBuilder.cbFromFieldCb(_dealer.text.trim());
    final pwSum = CommandBuilder.passwordChecksum(_password.text);
    Navigator.of(context).pop(AuthCredentials(cb: cb, pwSum: pwSum));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(26),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '解除斷電',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                '輸入斷電密碼以解除。系統將以記錄到的代理碼推導驗證值，並送出唯一已知安全的「解除」指令。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.6,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 15),
              TextField(
                controller: _dealer,
                style: const TextStyle(fontSize: 14, color: AppColors.text),
                cursorColor: AppColors.amber,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '代理碼 (Dealer code)',
                  isDense: true,
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _password,
                style: const TextStyle(fontSize: 14, color: AppColors.text),
                cursorColor: AppColors.amber,
                obscureText: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: '斷電密碼',
                  isDense: true,
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
              const SizedBox(height: 14),
              const _WarnBox(
                text: '解除斷電後請勿重新上鎖；電容本身過壓／低壓／過溫保護仍持續有效。',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _Btn(
                      label: '取消',
                      filled: false,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _Btn(
                      label: '確認解除',
                      filled: true,
                      onTap: _canSubmit ? _submit : null,
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

/// Amber warning box (mockup `.warnbox`).
class _WarnBox extends StatelessWidget {
  const _WarnBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.07),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 15, color: AppColors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                color: AppColors.amber,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({required this.label, required this.filled, this.onTap});

  final String label;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled
              ? (enabled ? AppColors.amber : AppColors.amber.withValues(alpha: 0.4))
              : AppColors.panel2,
          border: Border.all(
            color: filled ? Colors.transparent : AppColors.line,
          ),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: filled ? AppColors.onAmber : AppColors.muted,
          ),
        ),
      ),
    );
  }
}
