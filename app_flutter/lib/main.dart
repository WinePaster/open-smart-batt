import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ble/ble.dart';
import 'data/data.dart';
import 'models/models.dart';
import 'state/state.dart';
import 'theme/app_theme.dart';
import 'ui/dashboard/dashboard_page.dart';
import 'ui/devices/device_list_sheet.dart';
import 'ui/history/history_screen.dart';
import 'ui/settings/settings_screen.dart';
import 'ui/util/update_check.dart';

/// Public project page (shown in the community disclaimer + Settings → About).
const String kProjectUrl = 'https://github.com/WinePaster/open-smart-batt';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Portrait-locked (mockup: 直式鎖定).
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Composition root: open DB, build repos + BLE service, wire controllers.
  final services = await AppServices.create();

  // Capture runtime errors into the diagnostic log so users can export them
  // from the phone alone (Settings → 診斷 → 匯出診斷日誌), no PC needed.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    services.logRepo
        .insertLog(LogEntry.event('FlutterError: ${details.exceptionAsString()}'))
        .ignore();
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    services.logRepo.insertLog(LogEntry.event('Uncaught: $error')).ignore();
    return true;
  };

  runApp(OpenRceBattApp(services: services));
}

/// Root app. Provides the state controllers via [MultiProvider] and owns the
/// [AppServices] lifecycle (disposed when the app is torn down).
class OpenRceBattApp extends StatefulWidget {
  const OpenRceBattApp({super.key, required this.services});

  final AppServices services;

  @override
  State<OpenRceBattApp> createState() => _OpenRceBattAppState();
}

class _OpenRceBattAppState extends State<OpenRceBattApp> {
  @override
  void dispose() {
    // Fire-and-forget teardown of streams / BLE link / DB on app exit.
    widget.services.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return MultiProvider(
      providers: [
        // Services the UI may read directly (history/log/CSV export, raw BLE).
        Provider<BleService>.value(value: s.ble),
        Provider<HistoryRepo>.value(value: s.historyRepo),
        Provider<DeviceRepo>.value(value: s.deviceRepo),
        Provider<SettingsRepo>.value(value: s.settingsRepo),
        Provider<LogRepo>.value(value: s.logRepo),
        // Controllers (lifecycle owned by AppServices, hence .value).
        ChangeNotifierProvider<SettingsController>.value(value: s.settings),
        ChangeNotifierProvider<DeviceController>.value(value: s.devices),
        ChangeNotifierProvider<ConnectionController>.value(value: s.connection),
        ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
      ],
      // Rebuild MaterialApp when the theme preference changes.
      child: Consumer<SettingsController>(
        builder: (context, settings, _) => MaterialApp(
          title: 'OpenSmartBatt',
          debugShowCheckedModeBanner: false,
          // Real light / dark themes (DEFAULT light); `auto` follows the OS.
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: _themeModeOf(settings.themeMode),
          // i18n wiring -------------------------------------------------------
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: _localeOf(settings.lang), // null => follow device locale
          // -------------------------------------------------------------------
          home: const RootShell(),
          // Global font bump (×1.15) on top of the user's system text scale.
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(mq.textScaler.scale(1) * 1.15),
              ),
              child: child!,
            );
          },
        ),
      ),
    );
  }

  /// Maps the persisted [AppThemeMode] to Flutter's [ThemeMode].
  static ThemeMode _themeModeOf(AppThemeMode m) => switch (m) {
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
        AppThemeMode.auto => ThemeMode.system,
      };

  /// Maps the persisted [AppLang] to a [Locale]. `null` => follow the device
  /// locale (resolved against [AppLocalizations.supportedLocales]).
  static Locale? _localeOf(AppLang lang) => switch (lang) {
        AppLang.system => null,
        AppLang.zhHant => const Locale('zh'), // zh-Hant (only Chinese shipped)
        AppLang.en => const Locale('en'),
      };
}

// ---------------------------------------------------------------------------
// Root shell: brand app bar + bottom nav (Dashboard / History / Settings) and
// the one-time community disclaimer gate.
// ---------------------------------------------------------------------------

/// The three bottom-nav destinations (mockup: 儀表板 / 歷史 / 設定).
enum _Tab { dashboard, history, settings }

/// Top-level navigation shell. Replaces the placeholder home: hosts the three
/// screens in an [IndexedStack] (state preserved across tab switches) and shows
/// the startup community disclaimer once on first launch.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  _Tab _tab = _Tab.dashboard;
  int _historyEpoch = 0; // bumped on each switch to 歷史 to force a reload

  @override
  void initState() {
    super.initState();
    // After first frame: disclaimer (once) then a silent GitHub update check.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startup());
  }

  Future<void> _startup() async {
    await _maybeShowDisclaimer();
    if (!mounted) return;
    // On-launch update check: Android only. iOS updates arrive via TestFlight /
    // the App Store; GitHub releases carry only the Android APK, so an in-app
    // GitHub update prompt on iOS would point at an APK the user cannot install.
    if (Platform.isAndroid) {
      await runUpdateCheck(context, manual: false);
    }
  }

  Future<void> _maybeShowDisclaimer() async {
    if (await Disclaimer.acknowledged()) return;
    if (!mounted) return;
    await showCommunityDisclaimer(context);
    await Disclaimer.markAcknowledged();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: const _BrandAppBar(),
      // The AppBar already insets the top (status bar / notch / Dynamic Island)
      // and the NavigationBar insets the bottom (home indicator); guard the
      // body's horizontal edges too (top: false / bottom: false avoid double
      // padding). No-op on Android, where these insets are 0.
      body: SafeArea(
        top: false,
        bottom: false,
        child: IndexedStack(
          index: _tab.index,
          children: [
            const DashboardPage(),
            // Re-keyed on each switch to 歷史 so it reloads the latest records.
            HistoryScreen(key: ValueKey(_historyEpoch)),
            const SettingsScreen(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: context.colors.panel,
          indicatorColor: AppColors.amber.withValues(alpha: 0.16),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 10,
              letterSpacing: 1,
              fontWeight: FontWeight.w600,
              color: states.contains(WidgetState.selected)
                  ? AppColors.amber
                  : context.colors.muted,
            ),
          ),
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? AppColors.amber
                  : context.colors.muted,
            ),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _tab.index,
          onDestinationSelected: (i) => setState(() {
            _tab = _Tab.values[i];
            if (_tab == _Tab.history) _historyEpoch++;
          }),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.speed_outlined),
              selectedIcon: const Icon(Icons.speed),
              label: l10n.navDashboard,
            ),
            NavigationDestination(
              icon: const Icon(Icons.history_outlined),
              selectedIcon: const Icon(Icons.history),
              label: l10n.navHistory,
            ),
            NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              selectedIcon: const Icon(Icons.settings),
              label: l10n.navSettings,
            ),
          ],
        ),
      ),
    );
  }
}

/// App bar showing the brand mark + a live connection-state pill (mockup
/// `.appbar` / `.conn`). Tapping the pill is wired by the device-list screen;
/// here it surfaces the current link state.
class _BrandAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _BrandAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(58);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      titleSpacing: 16,
      toolbarHeight: 58,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: context.colors.panel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.amber, width: 1.4),
            ),
            child: const Icon(Icons.bolt, size: 18, color: AppColors.amber),
          ),
          const SizedBox(width: 10),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'OPEN-RCE-BATT',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: context.colors.text,
                ),
              ),
              Text(
                'CAPACITOR MONITOR',
                style: TextStyle(
                  fontSize: 8.5,
                  letterSpacing: 2,
                  color: context.colors.muted,
                ),
              ),
            ],
          ),
        ],
      ),
      actions: const [
        Padding(
          padding: EdgeInsets.only(right: 14),
          child: Center(child: _ConnectionPill()),
        ),
      ],
    );
  }
}

/// Compact connection indicator (mockup `.conn` pill). Green when the link is
/// ready, amber while connecting, danger-red otherwise.
class _ConnectionPill extends StatelessWidget {
  const _ConnectionPill();

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final (Color color, String label) = switch (conn.linkState) {
      BleLinkState.ready => (AppColors.good, 'CONNECTED'),
      BleLinkState.connecting ||
      BleLinkState.connected =>
        (AppColors.amber, 'CONNECTING'),
      BleLinkState.disconnecting => (AppColors.amber, 'CLOSING'),
      BleLinkState.disconnected => (AppColors.danger, 'OFFLINE'),
    };
    return InkWell(
      onTap: () => showDeviceListSheet(context),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: context.colors.panel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.colors.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bluetooth, size: 13, color: color),
            const SizedBox(width: 6),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.5,
                color: context.colors.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Community disclaimer (mockup startup `.modal` / `.sheet`).
// ---------------------------------------------------------------------------

/// Persists whether the user has acknowledged the startup disclaimer. Stored as
/// a marker file in the app-support dir (this is OUR own state, not the
/// vendor's). Versioned so a future material change to the text can re-prompt.
class Disclaimer {
  Disclaimer._();

  static const String _markerName = 'disclaimer_ack_v1';

  static Future<File> _marker() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_markerName');
  }

  static Future<bool> acknowledged() async {
    try {
      return (await _marker()).exists();
    } catch (_) {
      // If we can't read the marker, fall back to showing the notice.
      return false;
    }
  }

  static Future<void> markAcknowledged() async {
    try {
      await (await _marker()).writeAsString(DateTime.now().toIso8601String());
    } catch (_) {
      // Best-effort; worst case the notice shows again next launch.
    }
  }
}

/// Shows the one-time community disclaimer: non-official / non-commercial
/// notice, GitHub link, and the do-not-re-lock safety warning. Reusable from
/// Settings → 版權與免責聲明 (`重看開場聲明`).
Future<void> showCommunityDisclaimer(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: const Color(0xD904060A),
    builder: (_) => const _DisclaimerDialog(),
  );
}

class _DisclaimerDialog extends StatelessWidget {
  const _DisclaimerDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: context.colors.panel2,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.amber, width: 1.4),
                ),
                child: const Icon(Icons.bolt, size: 30, color: AppColors.amber),
              ),
              const SizedBox(height: 14),
              Text(
                'OPEN-RCE-BATT',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                  color: context.colors.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.disclaimerCommunityEdition,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 10,
                  letterSpacing: 3,
                  color: AppColors.amber,
                ),
              ),
              const SizedBox(height: 16),
              const _DisclaimerBody(),
              const SizedBox(height: 12),
              const _DoNotRelockWarning(),
              const SizedBox(height: 12),
              _GitHubButton(),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      l10n.disclaimerAcknowledgeButton,
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
        ),
      ),
    );
  }
}

class _DisclaimerBody extends StatelessWidget {
  const _DisclaimerBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = TextStyle(
      fontSize: 12,
      height: 1.7,
      color: context.colors.muted,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.disclaimerBodyPara1, style: muted),
        const SizedBox(height: 9),
        Text(l10n.disclaimerBodyPara2, style: muted),
      ],
    );
  }
}

/// The "do not re-lock" safety warning (mockup `.warnbox`).
class _DoNotRelockWarning extends StatelessWidget {
  const _DoNotRelockWarning();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 15, color: AppColors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              AppLocalizations.of(context).disclaimerDoNotRelock,
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

/// GitHub link row (mockup `.ghbtn`). Opens the project URL in the external
/// browser; falls back to copying the link if no browser can handle it.
class _GitHubButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () async {
          final l10n = AppLocalizations.of(context);
          final messenger = ScaffoldMessenger.of(context);
          final uri = Uri.parse(kProjectUrl);
          var opened = false;
          try {
            opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
          } catch (_) {
            opened = false;
          }
          if (!opened) {
            await Clipboard.setData(const ClipboardData(text: kProjectUrl));
            messenger.showSnackBar(
              SnackBar(
                duration: const Duration(milliseconds: 1600),
                content: Text(l10n.commonOpenBrowserFailed(kProjectUrl)),
              ),
            );
          }
        },
        icon: const Icon(Icons.open_in_new, size: 16),
        label: Text(
          AppLocalizations.of(context).disclaimerViewGithub,
          style: const TextStyle(fontSize: 12.5),
        ),
      ),
    );
  }
}
