import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ble/ble.dart';
import 'data/data.dart';
import 'models/models.dart';
import 'protocol/protocol.dart';
import 'state/state.dart';
import 'theme/app_theme.dart';
import 'ui/devices/device_detail_page.dart';
import 'ui/devices/devices_page.dart';
import 'ui/history/history_screen.dart';
import 'ui/home/home_editor_page.dart';
import 'ui/home/home_page.dart';
import 'ui/settings/settings_screen.dart';
import 'ui/startup_failure.dart';
import 'ui/util/update_check.dart';

/// Public project page (shown in the community disclaimer + Settings → About).
const String kProjectUrl = 'https://github.com/WinePaster/open-smart-batt';

/// Open-build entry point: boots with the default no-op metadata seam.
Future<void> main() => bootstrap();

/// Composition-root wrapper. The OPEN build calls this with defaults —
/// [NoopMetadataParser] (decodes no closed selectors) and no device-info panel —
/// so its behaviour is identical to before the seam existed. A CLOSED `main()`
/// (private repo) calls `bootstrap(parser: …, deviceInfoPanelBuilder: …)` to
/// inject its own parser + UI panel without forking this shell.
///
/// - [parser]: device-metadata parser threaded to [BleService] via
///   [AppServices.create]. Open default = [NoopMetadataParser].
/// - [deviceInfoPanelBuilder]: optional closed-side panel builder. Null on the
///   open build (no panel; the open app never reads [DeviceMetadata] content).
Future<void> bootstrap({
  MetadataParser parser = const NoopMetadataParser(),
  WidgetBuilder? deviceInfoPanelBuilder,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  // design 0060 §3.8 (FB-67, Phase 2 "B"): opt into CoreBluetooth state
  // restoration HERE, and nowhere else. See [BleService.enableStateRestoration]
  // for why this is the only line in the app where the option can still take
  // effect — the next thing to touch flutter_blue_plus is
  // `ConnectionController`'s constructor, inside `AppServices.create` below,
  // and that is what builds the CBCentralManager the option is read by.
  //
  // The outcome is held rather than logged: the log lives in a database that is
  // not open yet. It is written a few lines further down, beside `cold-start:`.
  final restoreLine = await configureBleStateRestoration();
  // Portrait-locked (mockup: 直式鎖定).
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Composition root: open DB, build repos + BLE service, wire controllers.
  //
  // This runs BEFORE runApp(), so a failure here (failed migration, corrupt
  // file, downgraded install) would otherwise be a blank screen with no message
  // and no way to export the diagnostic log — it lives in the DB that will not
  // open. Fall back to a screen that says what happened instead.
  final AppServices services;
  try {
    services = await AppServices.create(parser: parser);
  } catch (e) {
    runApp(
      StartupFailureApp(
        error: e,
        onRetry: () => bootstrap(
          parser: parser,
          deviceInfoPanelBuilder: deviceInfoPanelBuilder,
        ),
      ),
    );
    return;
  }

  // design 0060 §3.5 (FB-67): one line per launch, written as soon as there is
  // a database to write it to.
  //
  // 🔑 The value is not only the arm. "This launch was a cold start" was, until
  // this line, recorded nowhere at all — FB-67 had to infer it from four
  // lifecycle lines being ABSENT, which is a reconstruction rather than a fact,
  // and it is the single number design 0060's open questions (Q3–Q5) need from
  // the field. `armed=none` is therefore just as much the point as `armed=…`.
  //
  // In `bootstrap()` and not in [AppServices.create]: no test calls
  // `bootstrap()`, so this cannot alter what any of the 37 suites built on
  // `create()` see in their diagnostic log (design 0060 §6 R4).
  services.logRepo
      .insertLog(
        LogEntry.event(
          formatColdStartLine(
            appBuild: services.appBuild,
            arm: services.restoredArm,
            now: DateTime.now(),
          ),
        ),
      )
      .ignore();
  // …and what state restoration did, from the call made before the DB existed.
  // These two lines together are the ONLY evidence design 0060 Q3 has for
  // "does restoration actually happen in the field, and how often": count
  // `restore:` against `armed=` across a fortnight of captures.
  services.logRepo.insertLog(LogEntry.event(restoreLine)).ignore();

  // Capture runtime errors into the diagnostic log so users can export them
  // from the phone alone (Settings → 診斷 → 匯出診斷日誌), no PC needed.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    services.logRepo
        .insertLog(
          LogEntry.event('FlutterError: ${details.exceptionAsString()}'),
        )
        .ignore();
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    services.logRepo.insertLog(LogEntry.event('Uncaught: $error')).ignore();
    return true;
  };

  runApp(
    OpenSmartBattApp(
      services: services,
      deviceInfoPanelBuilder: deviceInfoPanelBuilder,
    ),
  );
}

/// Turn on CoreBluetooth state restoration and say what happened, without ever
/// being able to stop the app from starting (design 0060 §3.8 / §6).
///
/// 🔴 The `try` is the point. `main.dart:59-71` reserves `StartupFailureApp` for
/// the database failing to open — the one failure that takes the diagnostic log
/// down with it — and a BLE OPTION not being settable is nothing of the kind: on
/// a desktop host, in a test, or on any platform without the plugin, the call
/// simply has nobody to answer it. An app that refuses to launch because an
/// iOS-only optimisation could not be enabled would be a worse bug than the one
/// design 0060 is fixing.
///
/// Returns the line to write once there is a log to write it to. [setOptions] is
/// injectable so both branches are testable; the default is the real call.
@visibleForTesting
Future<String> configureBleStateRestoration({
  Future<void> Function()? setOptions,
}) async {
  try {
    await (setOptions ?? BleService.enableStateRestoration)();
    return 'restore: setOptions(restoreState: true) ok';
  } catch (e) {
    return 'restore: setOptions(restoreState: true) failed=$e';
  }
}

/// Root app. Provides the state controllers via [MultiProvider] and owns the
/// [AppServices] lifecycle (disposed when the app is torn down).
class OpenSmartBattApp extends StatefulWidget {
  const OpenSmartBattApp({
    super.key,
    required this.services,
    this.deviceInfoPanelBuilder,
  });

  final AppServices services;

  /// Closed-side "device info" panel builder, or null on the open build (no
  /// panel). Held here so a closed composition
  /// root can surface it without forking the shell; the open build never sets it.
  final WidgetBuilder? deviceInfoPanelBuilder;

  @override
  State<OpenSmartBattApp> createState() => _OpenSmartBattAppState();
}

class _OpenSmartBattAppState extends State<OpenSmartBattApp>
    with WidgetsBindingObserver {
  /// Debounces `inactive` before it is allowed to close the GNSS gate. See
  /// [SpeedLifecycleGate] — the short version is that a notification banner is
  /// not the user leaving.
  late final SpeedLifecycleGate _speedLifecycle;

  /// The same debounce for the accelerometer streams (design 0045 §3.5, "the
  /// same shape as 0042 §3.4"). A SECOND instance rather than one gate driving
  /// both, because each owns a timer and cancelling one must not cancel the
  /// other's.
  late final SpeedLifecycleGate _gForceLifecycle;

  @override
  void initState() {
    super.initState();
    _speedLifecycle = SpeedLifecycleGate(
      setAppResumed: widget.services.speed.setAppResumed,
    );
    _gForceLifecycle = SpeedLifecycleGate(
      setAppResumed: widget.services.gforce.setAppResumed,
    );
    WidgetsBinding.instance.addObserver(this);
  }

  /// Record foreground/background transitions into the diagnostic log.
  ///
  /// Diagnosing the 2026-07-27 reports took reconstructing "the OS suspended
  /// the app" from a hole in the per-minute frame counts plus the 2× backlog
  /// burst on resume. One line here turns that inference into a fact the log
  /// states outright — and it is the difference between a stall the user can
  /// explain and a "the app randomly stopped updating" report.
  ///
  /// Leaving the foreground also PERSISTS the minute currently being averaged.
  /// A lifecycle event is the right hook precisely because it is the moment
  /// control may be lost; a periodic flush would instead chop a minute into
  /// several rows and destroy the one-row-per-minute meaning. The app may not
  /// get another turn: a suspension that
  /// ends in the OS reclaiming the process produces no disconnect event, and
  /// the partial minute used to die with it — a 2026-07-28 capture lost its
  /// last 37 seconds exactly this way.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.services.connection.logAppLifecycle(state.name);
    // GPS is foreground-only (design 0042 §3.4 / N1). Unlike the BLE link,
    // which design 0039 deliberately keeps alive in the background, a location
    // stream buys nothing while nobody can see the number — and it is the one
    // permission a battery app has to justify.
    //
    // Through [SpeedLifecycleGate] rather than
    // `setAppResumed(state == resumed)`: `inactive` also fires for a
    // notification banner, the app switcher and the system permission dialog
    // this feature's own consent flow raises. See that class for why treating
    // those as "left the foreground" empties the card and probably costs MORE
    // battery than it saves.
    _speedLifecycle.onLifecycle(state);
    // The accelerometer costs far less than GNSS, but G4's rule is about
    // whether screens are counted, not about how much each one costs — and a
    // sensor stream running for a card nobody can see is the same defect either
    // way.
    _gForceLifecycle.onLifecycle(state);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        widget.services.telemetry.flushPendingHistory();
      case AppLifecycleState.resumed:
        // The sentence above is why this branch cannot stay empty: if the OS
        // took the link while we were away it said nothing, so `ready` on
        // resume is a claim. Ask the device, and hold the answer to a deadline
        // (design 0039 §3.1).
        widget.services.connection.onAppResumed();
      case AppLifecycleState.inactive:
        break;
    }
    super.didChangeAppLifecycleState(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Before the services go: its timer's callback drives one of them.
    _speedLifecycle.dispose();
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
        Provider<AppServices>.value(value: s),
        Provider<BleService>.value(value: s.ble),
        Provider<HistoryRepo>.value(value: s.historyRepo),
        Provider<DeviceRepo>.value(value: s.deviceRepo),
        Provider<SettingsRepo>.value(value: s.settingsRepo),
        Provider<LogRepo>.value(value: s.logRepo),
        // Controllers (lifecycle owned by AppServices, hence .value).
        ChangeNotifierProvider<SettingsController>.value(value: s.settings),
        ChangeNotifierProvider<DeviceController>.value(value: s.devices),
        // design 0057. Every consumer looks it up as `DeviceFactsController?`,
        // which provider resolves to null where it is absent — a screen that
        // does not get one falls back to exactly the pre-0057 behaviour rather
        // than throwing, and no test harness has to learn about a table it is
        // not testing.
        ChangeNotifierProvider<DeviceFactsController>.value(value: s.facts),
        ChangeNotifierProvider<ConnectionController>.value(value: s.connection),
        ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
        ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
        ChangeNotifierProvider<GForceController>.value(value: s.gforce),
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
          home: RootShell(
            deviceInfoPanelBuilder: widget.deviceInfoPanelBuilder,
          ),
          // Global font bump on top of the user's system text scale. The factor
          // is [AppTheme.baseTextScale], not a literal, because the dashboard
          // has to divide it back out to tell how much the USER enlarged text
          // (see AppTheme.gaugeDiameter).
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(
                  mq.textScaler.scale(1) * AppTheme.baseTextScale,
                ),
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
// Root shell: brand app bar + bottom nav (Home / Devices / History / Settings)
// and the one-time community disclaimer gate.
// ---------------------------------------------------------------------------

/// The four bottom-nav destinations (design 0046 §3.1: 主頁 / 裝置 / 歷史 / 設定).
///
/// 🔴 `dashboard` is gone as a DESTINATION, not as a screen. Until design 0046
/// the first tab was `_Tab.dashboard` — labelled "裝置" / "Devices" on screen,
/// which is why the owner described the app as opening on "the device page"
/// while the code called it the dashboard. That name now belongs to the LIST
/// ([DevicesPage]); the dashboard itself moved one level down, into the
/// per-device detail page. An upgrading user therefore finds the same word
/// pointing at a different screen, which is a silent semantic swap and belongs
/// in the release note (design 0046 §1.3).
enum _Tab { home, devices, history, settings }

/// Top-level navigation shell. Replaces the placeholder home: hosts the four
/// screens in an [IndexedStack] (state preserved across tab switches) and shows
/// the startup community disclaimer once on first launch.
class RootShell extends StatefulWidget {
  const RootShell({super.key, this.deviceInfoPanelBuilder});

  /// Forwarded to [SettingsScreen]. Null here, and that is the design: it is an
  /// injection point rather than a feature. A build that carries an extra
  /// device-metadata decoder passes a panel in, so the shared front end stays
  /// one codebase and needs no build flag to omit anything.
  final WidgetBuilder? deviceInfoPanelBuilder;

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  // Design 0046 R3, which overturns design 0034 G4 on the owner's ruling: the
  // app opens on the home grid rather than on one device's dashboard.
  _Tab _tab = _Tab.home;
  int _historyEpoch = 0; // bumped on each switch to 歷史 to force a reload

  /// Full-screen mode: hide THIS APP's AppBar and NavigationBar (design 0062,
  /// FB-76). Not the system status bar — the reporter's "headbar / menubar"
  /// was clarified by the owner to mean our own chrome, which is why nothing
  /// here touches [SystemChrome]. Android and iOS therefore behave identically.
  ///
  /// 🔴 Deliberately NOT persisted (design 0062 Q2, ruled 不存). It lives in
  /// this State and nowhere else, so a user who cannot find the way out always
  /// has a fourth exit: kill the app and reopen it. That is also why no DB
  /// migration and no export-header field belong to this feature (Q3 moot).
  bool _immersive = false;

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Hand the monitor notification its localized, non-numeric strings. Here
    // rather than in build(): this is the first place l10n is resolved, and it
    // re-fires when the user switches language. The live reading is formatted
    // by the controller from telemetry, so this runs rarely.
    // Gate condition 3 (design 0042 §3.4). It has to come from HERE and cannot
    // be inferred from the subtree: the four screens live in an IndexedStack,
    // so the home grid — and any speed card inside it — stays MOUNTED while the
    // user reads History or Settings. Without this, "a speed card is on screen"
    // would silently mean "the app is running", and the GNSS receiver would
    // stay up on every tab.
    _syncDashboardVisible();
    final l10n = AppLocalizations.of(context);
    context.read<ConnectionController>().setNotificationStrings(
      title: l10n.monitorNotificationTitle,
      titleConnecting: l10n.monitorNotificationTitleConnecting,
      titleStalled: l10n.monitorNotificationTitleStalled,
      stopLabel: l10n.monitorNotificationStop,
      channelName: l10n.monitorChannelName,
      channelDescription: l10n.monitorChannelDescription,
    );
  }

  /// The ONLY way `_tab` may be written after construction.
  ///
  /// 🔴 It is a single entry point because it was not one, and that cost a
  /// bypass: the stale-telemetry banner's "open Settings" callback used to do
  /// its own `setState(() => _tab = _Tab.settings)`. `setState` does not run
  /// `didChangeDependencies`, so [_syncDashboardVisible] never fired and gate
  /// condition 3 stayed true. With the IndexedStack keeping the speed card
  /// mounted (condition 1) and the app resumed (condition 2), the GNSS receiver
  /// kept running — and speed kept landing — while Settings covered the
  /// dashboard. Design 0042 G4 makes that gate the whole battery story.
  ///
  /// The trigger was not exotic: the banner appears whenever telemetry stalls,
  /// which on a moving bike is whenever BLE hiccups.
  ///
  /// Anything that needs to switch tabs calls this. A second `_tab = …` in this
  /// file is a bug, not a shortcut.
  void _setTab(_Tab next) {
    setState(() {
      _tab = next;
      // Full screen is a HOME-tab state (design 0062 §7.1-7). Leaving the tab
      // leaves the mode: the only reason to hide the nav bar is to see more of
      // the grid, and every other tab needs its own chrome to be usable.
      // Placed here rather than beside each caller for the same reason `_tab`
      // itself is written in one place — see the doc comment above.
      _immersive = false;
      // Re-keyed on each switch to 歷史 so it reloads the latest records.
      if (next == _Tab.history) _historyEpoch++;
    });
    // OUTSIDE the setState closure: this notifies a ChangeNotifier, and doing
    // that inside a state update marks other widgets dirty in the middle of one.
    _syncDashboardVisible();
  }

  /// Gate condition 3's TAB half (design 0042 §3.4, re-scoped by design 0046
  /// Step 8c). Before 0046 the only surface that could carry a speed card was
  /// the dashboard tab; now it is the HOME tab, and the device detail page —
  /// a pushed route this shell does not own — reports itself separately through
  /// [GpsSpeedController.setDetailVisible].
  /// Two entry points, one route: the app-bar action and the row at the foot of
  /// the grid. The row exists because the action alone was not findable —
  /// see [HomePage.onEdit].
  void _openHomeEditor() => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const HomeEditorPage()));

  /// One unit's page, pushed from the shell (home tile, or the pill below).
  ///
  /// The scan does not have to be stopped around this: [DeviceDetailPage]
  /// reports its own visibility and [ConnectionController.setDetailVisible]
  /// pauses the radio off that (W-3, rewired 2026-08-12). It used to be the
  /// pusher's job, which is why this route could only safely be opened from the
  /// devices list.
  void _openDetail(String deviceId, {String fallbackName = ''}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DeviceDetailPage(
            deviceId: deviceId,
            fallbackName: fallbackName,
            onOpenSettings: () => _setTab(_Tab.settings),
          ),
        ),
      );

  /// Where the app-bar connection pill goes (ruled 2026-08-12).
  ///
  /// 🔴 Reported by the owner the same day as the unsaved-device defect:
  /// 「點選右上角的藍牙符號按鈕　就沒作用了」. It was not broken — it did the only
  /// thing it had ever done, `_setTab(devices)`, and the user was ALREADY on the
  /// devices tab. A control whose entire effect is a no-op from the surface a
  /// user most often presses it on is a dead control.
  ///
  /// Design 0046 R2 ruled the pill "switches tab instead of covering the page",
  /// and this does not overturn that: R2 was about not throwing a MODAL SHEET
  /// over the dashboard. A device page is a full route with a back affordance —
  /// the same one every row of the list has pushed since design 0055 — and the
  /// list itself keeps its own bottom-nav tab, so no destination is lost.
  ///
  /// 🔑 Stated as a THREE-way rule on purpose, so FB-49 (multi-device, filed
  /// 2026-08-03, blocked behind FB-20) does not have to re-open this ruling:
  ///
  ///   * nothing linked ⇒ the list, exactly as before;
  ///   * exactly one ⇒ that unit's page;
  ///   * more than one ⇒ the list, because "take me to the one I am connected
  ///     to" has no answer when there are three, and a list is the right answer
  ///     to a plural question.
  ///
  /// Today the middle case is simply `connectedDeviceId != null` — the service
  /// is single-connection (`BleService`: `_links` holds 0 or 1, `connect()`
  /// awaits `disconnect()` first), so there is no third case to write yet.
  ///
  /// `connectedDeviceId`, not `isOnline`: it falls back to `_desiredDeviceId`,
  /// so a link that is connecting or between retries goes there too — and that
  /// is the state where the page is worth the most, because the FB-52 stalled
  /// copy and the FB-53 retry button are on it and nowhere else.
  void _openConnectionTarget() {
    final conn = context.read<ConnectionController>();
    final id = conn.connectedDeviceId;
    if (id == null) {
      _setTab(_Tab.devices);
      return;
    }
    // The advertised name travels with the push: for a unit with no saved
    // record — the one this fix is about — it is the only name there is, and
    // the page cannot look it up (design 0055 §4.2).
    _openDetail(id, fallbackName: conn.connectedDeviceName);
  }

  /// Enter / leave full screen (design 0062).
  ///
  /// Does NOT touch [_syncDashboardVisible]: gate condition 3 reads `_tab`, and
  /// full screen never changes the tab. The GNSS receiver and the G-force
  /// stream therefore behave exactly as they do in the normal state — which is
  /// the point, since this mode exists FOR the riding readouts.
  void _setImmersive(bool value) {
    if (_immersive == value) return;
    setState(() => _immersive = value);
  }

  void _leaveImmersive() => _setImmersive(false);

  /// The three exit routes (design 0062 Q1, ruled 「三者都做」).
  ///
  /// 🔴 They are three NECESSARY conditions, not three backups for one another.
  /// Hiding the NavigationBar takes away the user's only way to change tabs, and
  /// this project has already shipped two controls nobody could find — the home
  /// editor button (see [HomePage.onEdit]) and FB-70's 14×14 dp rename pencil.
  /// A third would be the same mistake with a bigger blast radius, so:
  ///
  ///   1. the Android back button / gesture ([PopScope], below);
  ///   2. a PERSISTENT floating button ([_FullscreenExitButton]) — iOS has no
  ///      back button, so this is the primary exit there. It must not fade out
  ///      after a few seconds: that is exactly how a control becomes invisible;
  ///   3. a double tap anywhere.
  ///
  /// The wrapper is a no-op in the normal state. The double-tap recognizer is
  /// only attached while immersive, so it never sits in the gesture arena above
  /// the grid's own taps when there is nothing to exit from.
  Widget _wrapExits(Widget child) {
    if (!_immersive) return child;
    return PopScope(
      // Route 1. `canPop: false` so the pop is intercepted rather than taking
      // the whole shell off the navigator — there is nothing under it.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveImmersive();
      },
      child: GestureDetector(
        // Route 3. Translucent so the grid underneath still receives taps.
        behavior: HitTestBehavior.translucent,
        onDoubleTap: _leaveImmersive,
        child: child,
      ),
    );
  }

  void _syncDashboardVisible() {
    final home = _tab == _Tab.home;
    context.read<GpsSpeedController>().setDashboardVisible(home);
    // 🔴 BOTH controllers, from the ONE place the tab is written. Design 0046's
    // review found a `_tab` assignment that bypassed this sync and no test
    // noticed, because every test drove the setter rather than the shell —
    // adding a second gated stream doubles the cost of that mistake, so it is
    // wired here rather than beside each caller.
    context.read<GForceController>().setDashboardVisible(home);
  }

  Future<void> _maybeShowDisclaimer() async {
    if (await kDisclaimerAck.acknowledged()) return;
    if (!mounted) return;
    await showCommunityDisclaimer(context);
    await kDisclaimerAck.markAcknowledged();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: _immersive
          ? null
          : _BrandAppBar(
              onOpenConnection: _openConnectionTarget,
              // Only on 主頁, and only there: an "edit" action on top of History
              // or Settings would be an action with no object.
              onEditHome: _tab == _Tab.home ? _openHomeEditor : null,
              // Same rule, same reason (design 0062 §7.1-5): full screen only
              // means anything on the grid.
              onEnterFullscreen: _tab == _Tab.home
                  ? () => _setImmersive(true)
                  : null,
            ),
      // 🔴 `top` / `bottom` FOLLOW `_immersive`, and that is the whole point of
      // this pair (design 0062 §3.2).
      //
      // In the normal state the AppBar already insets the top (status bar /
      // notch / Dynamic Island) and the NavigationBar insets the bottom (home
      // indicator), so guarding them here too would double-pad — hence `false`.
      // Take those two away and the premise is gone: the grid would run under
      // the notch and under the home indicator.
      //
      // ⚠️ That bug is INVISIBLE on Android, where both insets are 0. It only
      // shows on a notched iPhone, which is why `fullscreen_mode_test.dart` F3
      // asserts these two flags directly rather than trusting a screenshot.
      body: SafeArea(
        top: _immersive,
        bottom: _immersive,
        child: _wrapExits(
          Stack(
            children: [
              IndexedStack(
                index: _tab.index,
                children: [
                  HomePage(
                    onOpenDevices: () => _setTab(_Tab.devices),
                    onEdit: _openHomeEditor,
                    onOpenDetail: _openDetail,
                  ),
                  // The dashboard's stale-telemetry banner links to Settings,
                  // and the dashboard now lives inside a route this page pushes
                  // — so the callback is threaded down rather than re-derived
                  // there. Every tab change in this file goes through `_setTab`,
                  // which is the only thing keeping gate condition 3 in step
                  // with what is on screen.
                  DevicesPage(
                    active: _tab == _Tab.devices,
                    onOpenSettings: () => _setTab(_Tab.settings),
                  ),
                  // Re-keyed on each switch to 歷史 so it reloads the latest
                  // records.
                  HistoryScreen(key: ValueKey(_historyEpoch)),
                  SettingsScreen(
                    deviceInfoPanelBuilder: widget.deviceInfoPanelBuilder,
                  ),
                ],
              ),
              // Exit route 2 of 3 (design 0062 Q1). Inside the Stack, not the
              // ListView: a button that scrolls away is a button that is not
              // there when the user panics.
              if (_immersive) _FullscreenExitButton(onPressed: _leaveImmersive),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _immersive
          ? null
          : NavigationBarTheme(
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
                onDestinationSelected: (i) => _setTab(_Tab.values[i]),
                destinations: [
                  NavigationDestination(
                    icon: const Icon(Icons.dashboard_outlined),
                    selectedIcon: const Icon(Icons.dashboard),
                    label: l10n.navHome,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.list_alt_outlined),
                    selectedIcon: const Icon(Icons.list_alt),
                    label: l10n.navDevices,
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

/// Exit route 2 of 3 for full-screen mode (design 0062 Q1).
///
/// 🔴 Three properties of this button are requirements, not styling:
///
///   * **it never fades out.** A control that disappears after N seconds is the
///     same failure this project shipped twice already (home editor button,
///     FB-70's rename pencil), except here it is the ONLY exit an iPhone user
///     has — iOS has no back button;
///   * **its tap target is at least 40×40 dp.** FB-70 was a fully working
///     rename feature behind a 14×14 dp hit box, and users deleted and re-added
///     devices instead of finding it. `fullscreen_mode_test.dart` F5 measures
///     this rather than merely asserting the widget exists;
///   * **it carries a tooltip and a semantics label**, so the icon alone does
///     not have to explain itself.
class _FullscreenExitButton extends StatelessWidget {
  const _FullscreenExitButton({required this.onPressed});

  final VoidCallback onPressed;

  /// Minimum tap target. Named so the test can assert against the same number
  /// the widget is built from, instead of a literal copied into both places.
  static const double kMinTapTarget = 40;

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context).fullscreenExit;
    return Positioned(
      top: 8,
      right: 8,
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          // Translucent rather than opaque: it sits on top of the grid, and the
          // card under it should stay readable.
          color: context.colors.panel.withValues(alpha: 0.72),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: Tooltip(
            message: label,
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              child: const SizedBox(
                width: kMinTapTarget,
                height: kMinTapTarget,
                child: Icon(Icons.fullscreen_exit, size: 22),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// App bar showing the brand mark + a live connection-state pill (mockup
/// `.appbar` / `.conn`). The pill surfaces the current link state; where a tap
/// on it goes is the shell's decision ([_RootShellState._openConnectionTarget]).
class _BrandAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _BrandAppBar({
    required this.onOpenConnection,
    this.onEditHome,
    this.onEnterFullscreen,
  });

  /// Where the connection pill goes — see [_RootShellState._openConnectionTarget]
  /// for the rule and why design 0046 R2 survives it.
  final VoidCallback onOpenConnection;

  /// Open the home editor (design 0046 P3). Null on every tab but 主頁.
  final VoidCallback? onEditHome;

  /// Enter full screen (design 0062). Null on every tab but 主頁, and this is
  /// the ONLY way in — design 0062 Q1 rules out a gesture for entering, so an
  /// accidental double tap can never remove the chrome the user is using.
  final VoidCallback? onEnterFullscreen;

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
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
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
                'OPENSMARTBATT',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: context.colors.text,
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        if (onEnterFullscreen != null)
          IconButton(
            onPressed: onEnterFullscreen,
            iconSize: 18,
            icon: const Icon(Icons.fullscreen),
            color: context.colors.muted,
            tooltip: AppLocalizations.of(context).fullscreenEnter,
          ),
        if (onEditHome != null)
          IconButton(
            onPressed: onEditHome,
            iconSize: 18,
            icon: const Icon(Icons.tune),
            color: context.colors.muted,
          ),
        Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Center(child: _ConnectionPill(onTap: onOpenConnection)),
        ),
      ],
    );
  }
}

/// Compact connection indicator (mockup `.conn` pill). Green when the link is
/// ready, amber while connecting, danger-red otherwise.
class _ConnectionPill extends StatelessWidget {
  const _ConnectionPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final (Color color, String label) = switch (conn.linkState) {
      BleLinkState.ready => (AppColors.good, 'CONNECTED'),
      BleLinkState.connecting ||
      BleLinkState.connected => (AppColors.amber, 'CONNECTING'),
      BleLinkState.disconnecting => (AppColors.amber, 'CLOSING'),
      BleLinkState.disconnected => (AppColors.danger, 'OFFLINE'),
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: context.colors.panel,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
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

/// Whether the user has acknowledged the startup disclaimer.
///
/// The body of this used to live here as a private `Disclaimer` class. Design
/// 0053 needed a second flag of exactly the same shape (the home-editor
/// tutorial), so the mechanism moved to [AckMarker] — a marker file in the
/// app-support dir, versioned so a material change to the text can re-prompt.
/// `data/ack_marker.dart` carries the reasoning for the file, including the
/// settings-table trap it avoids.
const AckMarker kDisclaimerAck = AckMarker('disclaimer_ack_v1');

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
                  borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                  border: Border.all(color: AppColors.amber, width: 1.4),
                ),
                child: const Icon(Icons.bolt, size: 30, color: AppColors.amber),
              ),
              const SizedBox(height: 14),
              Text(
                'OPENSMARTBATT',
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
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 15,
            color: AppColors.amber,
          ),
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
