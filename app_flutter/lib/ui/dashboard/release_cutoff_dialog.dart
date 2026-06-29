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

/// Result of the release dialog.
///
/// Exactly one path is requested:
///   * [creds] != null  → send mode + auth (normal / "use my code").
///   * [skipAuth] true   → EXPERIMENTAL: send the mode sub-frame ONLY.
class ReleaseRequest {
  const ReleaseRequest({this.creds, this.skipAuth = false});

  /// Derived auth credentials, or null when [skipAuth].
  final AuthCredentials? creds;

  /// Send the mode-only frame, skipping auth entirely (unproven fallback).
  final bool skipAuth;
}

/// Collects how to release: a cut-off password, directly-entered cb/pwSum
/// ("use my code"), or an experimental skip-auth. Returns a [ReleaseRequest]
/// on confirm, or null on cancel/dismiss.
///
/// [initialDealerCode] pre-fills from live telemetry (selector 0x27).
Future<ReleaseRequest?> showReleaseCutOffDialog(
  BuildContext context, {
  String? initialDealerCode,
}) {
  return showDialog<ReleaseRequest>(
    context: context,
    barrierColor: const Color(0xD904060A), // mockup rgba(4,6,10,.85)
    builder: (_) => _ReleaseDialog(initialDealerCode: initialDealerCode ?? ''),
  );
}

enum _AuthMode { password, code }

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
  // "use my code" advanced direct-entry of the two 16-bit auth values.
  late final TextEditingController _cb =
      TextEditingController(text: _prefillCb(widget.initialDealerCode));
  final TextEditingController _pwsum = TextEditingController();

  _AuthMode _mode = _AuthMode.password;
  bool _skipAuth = false;
  String? _error;

  /// Best-effort cb hint from the dealer code's leading 4 digits
  /// (e.g. dealer "01680217" → "168"). User can edit.
  static String _prefillCb(String dealer) {
    final d = dealer.trim();
    if (d.length < 4) return '';
    final n = int.tryParse(d.substring(0, 4));
    return n?.toString() ?? '';
  }

  @override
  void dispose() {
    _dealer.dispose();
    _password.dispose();
    _cb.dispose();
    _pwsum.dispose();
    super.dispose();
  }

  bool get _canSubmit {
    if (_skipAuth) return true;
    if (_mode == _AuthMode.password) {
      return _dealer.text.trim().length >= 8 && _password.text.isNotEmpty;
    }
    return _cb.text.trim().isNotEmpty && _pwsum.text.trim().isNotEmpty;
  }

  void _submit() {
    if (!_canSubmit) return;
    if (_skipAuth) {
      Navigator.of(context).pop(const ReleaseRequest(skipAuth: true));
      return;
    }
    try {
      final AuthCredentials creds;
      if (_mode == _AuthMode.password) {
        creds = AuthCredentials(
          cb: CommandBuilder.cbFromFieldCb(_dealer.text.trim()),
          pwSum: CommandBuilder.passwordChecksum(_password.text),
        );
      } else {
        creds = AuthCredentials(
          cb: CommandBuilder.parseAuthValue(_cb.text),
          pwSum: CommandBuilder.parseAuthValue(_pwsum.text),
        );
      }
      Navigator.of(context).pop(ReleaseRequest(creds: creds));
    } on FormatException {
      setState(() => _error = '驗證值格式錯誤（用十進位或 0x 十六進位）');
    } catch (_) {
      setState(() => _error = '代理碼需至少 8 碼');
    }
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
              Text(
                '解除斷電',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: context.colors.text,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '送出已知安全的「解除」指令(mode 0x06)。可用斷電密碼，或直接輸入你的驗證值。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.6,
                  color: context.colors.muted,
                ),
              ),
              const SizedBox(height: 14),
              // mode segmented control (disabled when skipping auth)
              Opacity(
                opacity: _skipAuth ? 0.4 : 1,
                child: SegmentedButton<_AuthMode>(
                  segments: const [
                    ButtonSegment(value: _AuthMode.password, label: Text('密碼')),
                    ButtonSegment(value: _AuthMode.code, label: Text('進階：我的碼')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: _skipAuth
                      ? null
                      : (s) => setState(() {
                            _mode = s.first;
                            _error = null;
                          }),
                ),
              ),
              const SizedBox(height: 12),
              if (!_skipAuth && _mode == _AuthMode.password) ...[
                TextField(
                  controller: _dealer,
                  style: TextStyle(fontSize: 14, color: context.colors.text),
                  cursorColor: AppColors.amber,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: '代理碼 (Dealer code, 連線時自動帶入)',
                    isDense: true,
                    contentPadding: EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _password,
                  style: TextStyle(fontSize: 14, color: context.colors.text),
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
              ],
              if (!_skipAuth && _mode == _AuthMode.code) ...[
                TextField(
                  controller: _cb,
                  style: TextStyle(fontSize: 14, color: context.colors.text),
                  cursorColor: AppColors.amber,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'cb (代理碼數值, 例 168 或 0xA8)',
                    isDense: true,
                    contentPadding: EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _pwsum,
                  style: TextStyle(fontSize: 14, color: context.colors.text),
                  cursorColor: AppColors.amber,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    labelText: 'pwSum (密碼校驗值, 例 204 或 0xCC)',
                    isDense: true,
                    contentPadding: EdgeInsets.all(12),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              // experimental skip-auth toggle
              InkWell(
                onTap: () => setState(() {
                  _skipAuth = !_skipAuth;
                  _error = null;
                }),
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    Switch(
                      value: _skipAuth,
                      onChanged: (v) => setState(() {
                        _skipAuth = v;
                        _error = null;
                      }),
                    ),
                    Expanded(
                      child: Text(
                        '實驗：只送 mode、跳過驗證（未證實，備案）',
                        style: TextStyle(
                            fontSize: 11.5, color: context.colors.muted),
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(_error!,
                    style: const TextStyle(fontSize: 11, color: AppColors.danger)),
              ],
              const SizedBox(height: 14),
              const _WarnBox(
                text: '解除後請勿重新上鎖；電容本身過壓／低壓／過溫保護仍持續有效。',
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
              ? (enabled
                  ? AppColors.amber
                  : AppColors.amber.withValues(alpha: 0.4))
              : context.colors.panel2,
          border: Border.all(
            color: filled ? Colors.transparent : context.colors.line,
          ),
          borderRadius: BorderRadius.circular(9),
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
