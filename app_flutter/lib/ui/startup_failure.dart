/// OpenSmartBatt — startup failure screen.
///
/// `bootstrap()` opens the database BEFORE `runApp()`, so anything that goes
/// wrong there (a failed migration, a corrupt file, a downgraded install) used
/// to surface as a blank screen or a silent exit: no message, and no way to
/// export the diagnostic log — that lives in the database that would not open.
///
/// This screen is the fallback. It runs with NO [AppServices]: it must not
/// touch the repos, the BLE service or any controller.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../data/data.dart';
import '../theme/app_theme.dart';

/// Minimal app shown when the composition root could not be built.
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({
    super.key,
    required this.error,
    required this.onRetry,
  });

  /// What [AppServices.create] threw.
  final Object error;

  /// Re-runs `bootstrap()`. Used both by the retry button and after a reset.
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'OpenSmartBatt',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        // The language preference lives in the database that just failed to
        // open, so mirror the app's DEFAULT (AppSettings.lang = zhHant) rather
        // than the device locale — otherwise a user whose phone is in English
        // would suddenly see a different language than the app they know.
        locale: const Locale('zh'),
        home: _StartupFailureScreen(error: error, onRetry: onRetry),
      );
}

class _StartupFailureScreen extends StatefulWidget {
  const _StartupFailureScreen({required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  State<_StartupFailureScreen> createState() => _StartupFailureScreenState();
}

class _StartupFailureScreenState extends State<_StartupFailureScreen> {
  bool _busy = false;

  Future<void> _retry() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.startupResetTitle),
            content: Text(l10n.startupResetBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.commonCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.commonConfirm),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    await AppDatabase.reset();
    await _retry();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final downgrade = widget.error;
    final isDowngrade = downgrade is DatabaseDowngradeException;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  isDowngrade ? Icons.system_update : Icons.error_outline,
                  size: 48,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  isDowngrade
                      ? l10n.startupDowngradeTitle
                      : l10n.startupFailedTitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  isDowngrade
                      ? l10n.startupDowngradeBody(
                          downgrade.storedVersion, downgrade.appVersion)
                      : l10n.startupFailedBody,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 20),
                // Selectable so the user can copy it into a message to us —
                // this screen replaces the diagnostic log they cannot export.
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                  child: SelectableText(
                    '${widget.error}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _retry,
                  child: Text(l10n.startupRetry),
                ),
                // A downgrade deliberately gets NO reset button: the data is
                // intact and the fix is to reinstall the newer build. Offering
                // a wipe here would trade months of history for a mistake the
                // user can simply undo.
                if (!isDowngrade) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : _reset,
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    child: Text(l10n.startupResetDb),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
