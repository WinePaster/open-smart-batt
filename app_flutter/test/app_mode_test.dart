// Personal / advanced mode (design 0063).
//
// WHAT THIS FEATURE IS. One two-valued setting. `personal` is the app exactly
// as it shipped yesterday — four tabs, opens on the home grid, speed card and G
// meter available. `advanced` removes the home tab from the bottom bar and, with
// it, withdraws the three things that only ever lived there: the speed card, the
// G meter and full-screen mode.
//
// 🔑 WHAT MAKES IT WORTH ITS OWN TEST FILE is that both halves fail silently.
//
//   * Get the DEFAULT wrong and every existing user loses their main screen on
//     the next launch, with nothing they did to explain it and no error to
//     read. There is no message for "a tab you were used to is missing".
//   * Get the effective-value fold wrong and nothing visible breaks at all —
//     the exports simply start saying `g meter: on` beside an empty column, and
//     we find out months later from a capture we can no longer interpret. That
//     is the same defect FB-32 cost three wrong replies to a reporter.
//
// The tests are numbered H1–H10 after `0063-implementation-plan.md` §6, and each
// one names the regression it catches rather than the code it touches.
//
// H1  fresh install and upgrade both land on personal   (also `schema_v18_test`)
// H2  advanced shows three tabs and every one of them opens the right page
// H3  the IndexedStack keeps all four children in BOTH modes
// H4  advanced withdraws the features WITHOUT rewriting the user's switches
// H5  switching mode while on 主頁 moves the user AND closes the sensor gate
// H6  a cold start in advanced mode never renders a `selectedIndex` of -1
// H9  the effective-value rule has no seventh consumer  (grep guard)
// H10 the export preamble states the mode, and states the effective switches
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/main.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/ui/devices/devices_page.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:open_smart_batt/ui/home/home_page.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';
import 'package:open_smart_batt/ui/widgets/industrial.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService — copied from `nav_shell_test.dart`, same reason: these
/// tests are about where a TAP goes, never about establishing a link, and the
/// real implementation would leave a pending timer the fake-async zone in a
/// widget test never advances.
class _FakeBleService extends BleService {
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  String? get connectedDeviceId => null;

  @override
  Future<void> startScan(
      {Duration timeout = const Duration(seconds: 15)}) async {}

  @override
  Future<void> stopScan() async {}
}

/// A settings row with both features switched ON, so that every assertion about
/// advanced mode is about the MODE withdrawing them rather than about them
/// having been off in the first place.
const AppSettings _bothOn = AppSettings(
  speedDetection: true,
  gMeterEnabled: true,
);

List<String> _header(AppSettings s) => exportHeaderLines(
      title: 'OpenSmartBatt history export',
      exportedAt: DateTime.utc(2026, 8, 15, 12, 0),
      appBuild: '0.7.20+26081500',
      platform: 'android 15',
      scope: 'device=battery/1206',
      layout: 'face=standard modules=gaugeVoltage,readouts,cells',
      home: 'tiles=auto',
      mode: s.mode,
      // Exactly what the three call sites in `lib/` pass — the EFFECTIVE
      // values. Passing the stored ones here would make this file agree with a
      // bug rather than catch it.
      speedDetection: s.speedDetectionEffective,
      gMeter: s.gMeterEffective,
      resolution: ExportResolution.none,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  setUp(() {
    // Speed detection ON (H8 needs it) opens the GNSS gate, which asks
    // permission_handler for a status — and there is no plugin behind that
    // channel in a unit test, so the raised `MissingPluginException` fails
    // whichever test happens to be running. Answered `denied` (index 0)
    // because these tests are about the SWITCH and the mode, never about a
    // location fix; a granted status would start a position stream with no
    // platform behind it either.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            (call) async => 0);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            null));
  });

  /// Let the real (ffi) database finish whatever the last frame started.
  Future<void> drain(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  /// Boot the whole app on a real in-memory database, optionally having stored
  /// [mode] BEFORE the first frame.
  ///
  /// 🔑 The mode is written before `pumpWidget`, not after — that is the point
  /// of H6. `_RootShellState.initState` folds the mode into `_tab`, so a test
  /// that switched afterwards would exercise the runtime path (H5) and would
  /// never see the cold-start one, which is the path that can assert.
  Future<AppServices> pumpShell(WidgetTester tester,
      {AppMode mode = AppMode.personal}) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      services = await AppServices.create(
          appDatabase: appDb, ble: _FakeBleService());
      // 🔴 The WHOLE row is rewritten, not just the mode. `inMemoryDatabasePath`
      // is not a fresh database per test in this process — the settings row
      // survives — so anything a previous test switched on is still on. Both
      // failure modes were hit while writing this file: H5 opened with no 主頁
      // because H3 had left `advanced` behind (which looks exactly like the
      // shell ignoring personal mode), and a later test raised a permission
      // plugin exception because H8's `speedDetection: true` had outlived it.
      await services.settings
          .update(AppSettings.defaults.copyWith(mode: mode));
    });
    await tester.pumpWidget(OpenSmartBattApp(services: services));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await drain(tester);
    // The one-time community disclaimer resolves off a marker-file read, i.e.
    // only on a REAL event loop — so it appears the moment the drain above runs
    // one. It absorbs every tap aimed at the navigation bar underneath, which
    // in this file would look exactly like "the destination did nothing".
    final ack = find.text('我了解，開始使用');
    if (ack.evaluate().isNotEmpty) {
      await tester.tap(ack);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    // ⚠️ NO `addTearDown(services.dispose)`, and that is not an oversight:
    // `AppServices.dispose` awaits a write drain and a database close, and an
    // await registered in a tear-down runs OUTSIDE `runAsync` — where the
    // widget-test fake clock never advances, so the whole file hangs with no
    // output at all rather than failing. `nav_shell_test.dart`'s helper leaves
    // it out for the same reason; the in-memory database dies with the process.
    return services;
  }

  List<String> labelsOf(WidgetTester tester) => [
        for (final d in tester
            .widget<NavigationBar>(find.byType(NavigationBar))
            .destinations)
          (d as NavigationDestination).label,
      ];

  group('H1: nobody is moved into advanced mode by an upgrade', () {
    test('a fresh install is personal', () {
      // The constructor default. `schema_v18_test` covers the other half — an
      // upgraded row, whose `app_mode` is NULL — because that one needs a real
      // database to be worth anything.
      expect(AppSettings.defaults.mode, AppMode.personal);
    });

    test('a row with no app_mode at all decodes to personal', () {
      // The pre-v18 shape: the KEY IS ABSENT, which is different from present
      // and null and is what `fromMap` actually meets when a v17 row is read by
      // a build that has not upgraded the file yet.
      expect(AppSettings.fromMap(const <String, Object?>{}).mode,
          AppMode.personal);
      expect(AppSettings.fromMap(const {'app_mode': null}).mode,
          AppMode.personal);
    });

    test('a value this build does not know decodes to personal, not a throw',
        () {
      // A downgrade after some future release adds a third mode. Settings
      // decoding never throws in this file (the standing `_themeModeFromMap`
      // rule): one unreadable cosmetic field must not stop the app starting.
      expect(AppSettings.fromMap(const {'app_mode': 'expert'}).mode,
          AppMode.personal);
      expect(AppSettings.fromMap(const {'app_mode': 7}).mode, AppMode.personal);
    });

    test('personal mode changes NOTHING about the effective values', () {
      // The design's central promise, stated as an assertion: in personal mode
      // the fold is the identity, so "personal == today's app" is mechanical
      // rather than a claim in a doc.
      for (final speed in [false, true]) {
        for (final g in [false, true]) {
          final s = AppSettings(speedDetection: speed, gMeterEnabled: g);
          expect(s.speedDetectionEffective, speed);
          expect(s.gMeterEffective, g);
        }
      }
    });
  });

  group('H4: advanced withdraws the features and keeps the answers', () {
    final advanced = _bothOn.copyWith(mode: AppMode.advanced);

    test('the effective values go false', () {
      expect(advanced.speedDetectionEffective, isFalse);
      expect(advanced.gMeterEffective, isFalse);
    });

    test('🔑 the STORED switches are untouched', () {
      // Design 0063 Q9, and the reason it was ruled that way: somebody who
      // tries advanced mode for ten minutes and comes back must find their own
      // choices where they left them. If a future `setMode` ever "tidies up" by
      // writing the switches false, this is what says no — and the user-visible
      // symptom it prevents (settings that quietly emptied themselves) is one
      // nobody would report as a bug about mode switching.
      expect(advanced.speedDetection, isTrue);
      expect(advanced.gMeterEnabled, isTrue);
      // …and switching back restores the feature with no second write.
      expect(advanced.copyWith(mode: AppMode.personal).speedDetectionEffective,
          isTrue);
      expect(
          advanced.copyWith(mode: AppMode.personal).gMeterEffective, isTrue);
    });

    test('the home grid stops offering the speed card', () {
      // `phoneModuleAvailable` is the single decision point both drawing
      // surfaces share (`display_module.dart`), so this is what keeps the speed
      // card out of a layout the home grid would otherwise still generate —
      // advanced mode hides the tab but leaves the page mounted.
      expect(
        phoneModuleAvailable(DisplayModule.speed, advanced,
            gForceAvailable: false),
        isFalse,
      );
      expect(
        phoneModuleAvailable(DisplayModule.speed, _bothOn,
            gForceAvailable: false),
        isTrue,
      );
    });
  });

  group('H2/H3/H6: the bottom bar in advanced mode', () {
    testWidgets('H6: a cold start lands on 裝置 with no -1 frame',
        (tester) async {
      // 🔴 The assert this file exists to keep away:
      // `NavigationBar`'s constructor requires
      // `0 <= selectedIndex < destinations.length` (Flutter 3.44.4,
      // `material/navigation_bar.dart:123`). Leave `_tab` on `home` while
      // advanced mode has removed that destination and `indexOf` hands it -1 —
      // a hard crash in debug, a bar with nothing highlighted in release.
      //
      // `takeException()` rather than only checking the index, because the
      // failure can happen in a FRAME THAT IS ALREADY GONE by the time the
      // assertions below run: the fold could be done one frame late and every
      // steady-state check would still pass.
      await pumpShell(tester, mode: AppMode.advanced);
      expect(tester.takeException(), isNull);

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 0);
      expect(labelsOf(tester), ['裝置', '歷史', '設定']);
      // Design 0063 Q10 ruled out a separate start-tab setting, so the mode has
      // to imply it — and "the first tab that exists" is what it implies.
      expect(find.byType(DevicesPage), findsOneWidget);
    });

    testWidgets('H2: every destination opens the page it names', (tester) async {
      // 🔑 THE test of this feature, and the one no existing test could catch:
      // the whole suite runs in personal mode, where `_visibleTabs.indexOf` and
      // `_Tab.index` happen to agree. Drop one tab and they part company, so a
      // bar that still mapped position to enum index would send 歷史 → 設定 and
      // 設定 → nothing. Loud symptom, invisible to 1,777 green tests.
      //
      // Every destination is tapped rather than a sample, because an off-by-one
      // is correct at exactly one position.
      await pumpShell(tester, mode: AppMode.advanced);
      // label -> (the page it must show, the ENUM index that page sits at).
      // The second number is written out because it is the whole hazard: the
      // menu positions here are 0/1/2 while the stack indices are 1/2/3, so
      // 設定 is off by one in exactly the direction a `_Tab.values[i]` mapping
      // would silently produce — it would open 歷史 instead.
      const expected = <String, (Type, int)>{
        '裝置': (DevicesPage, 1),
        '歷史': (HistoryScreen, 2),
        '設定': (SettingsScreen, 3),
      };
      for (final entry in expected.entries) {
        await tester.tap(find.text(entry.key));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await drain(tester);
        expect(
          find.descendant(
            of: find.byType(IndexedStack),
            matching: find.byType(entry.value.$1),
          ),
          findsOneWidget,
          reason: 'tapping ${entry.key} must show ${entry.value.$1}',
        );
        final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
        expect(stack.index, entry.value.$2,
            reason: '${entry.key} is at menu position '
                '${labelsOf(tester).indexOf(entry.key)} but stack index '
                '${entry.value.$2} — the two numberings must not be confused');
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('H3: all four pages stay in the IndexedStack, both modes',
        (tester) async {
      // Someone will eventually "tidy up" by dropping the hidden child. Two
      // things break at once and neither announces itself: every later page
      // shifts by one (so `_tab.index` points at the wrong child), and the
      // preserved tab state the stack was chosen FOR is thrown away on every
      // mode switch.
      for (final mode in AppMode.values) {
        await pumpShell(tester, mode: mode);
        final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
        expect(stack.children, hasLength(4), reason: '$mode');
      }
    });

    testWidgets(
        '🔑 H3b: advanced mode empties the home SLOT without shortening the list',
        (tester) async {
      // Owner ruling 2026-08-15, amending design 0063 §3.4. The invariant H3
      // guards (four children, so `_tab.index` keeps pointing where it did) is
      // untouched; what changed is what sits in slot 0.
      //
      // 🔴 Why it is worth a test rather than an optimisation nobody records:
      // `IndexedStack` paints only the selected child, so the offstage grid
      // never repainted and the waste was invisible in every screenshot. It
      // BUILT and LAID OUT — and `home_tiles.dart` watches `TelemetryController`
      // in two places, which notifies per sample. An unreachable page was
      // rebuilding at telemetry rate for as long as the app ran.
      //
      // `skipOffstage: false` on both halves: an IndexedStack keeps unselected
      // pages MOUNTED but offstage, so a finder that skipped them would report
      // "absent" in personal mode too and the test would pass for the wrong
      // reason.
      await pumpShell(tester, mode: AppMode.advanced);

      expect(find.byType(HomePage, skipOffstage: false), findsNothing,
          reason: 'advanced mode must not build a page nobody can reach');
      expect(
          tester.widget<IndexedStack>(find.byType(IndexedStack)).children,
          hasLength(4),
          reason: 'the SLOT stays — shortening the list is what §3.4 forbids, '
              'and it is what would silently repoint every later tab');
    });

    testWidgets('H3c: personal mode still mounts the grid', (tester) async {
      // The other half of H3b, in its own test rather than a second
      // `pumpShell` in the same one. Two shells per test does not work here:
      // the first one's database is closed underneath the second, and advanced
      // mode lands on 裝置, whose scan writes a log line — the failure surfaces
      // as `database_closed` from `ConnectionController.startScan`, nowhere
      // near the thing being asserted.
      await pumpShell(tester, mode: AppMode.personal);
      expect(find.byType(HomePage, skipOffstage: false), findsOneWidget);
    });
  });

  group('H5: switching mode at runtime', () {
    testWidgets('from 主頁 it moves the user and closes the sensor gate',
        (tester) async {
      final services = await pumpShell(tester);
      expect(find.byType(HomePage), findsOneWidget);
      expect(services.speed.dashboardVisible, isTrue);
      expect(services.gforce.dashboardVisible, isTrue);

      await tester.runAsync(() => services.settings.setMode(AppMode.advanced));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await drain(tester);

      expect(tester.takeException(), isNull);
      expect(labelsOf(tester), ['裝置', '歷史', '設定']);
      expect(find.byType(DevicesPage), findsOneWidget);

      // 🔑 The half that a plain `setState(() => _tab = …)` would get wrong,
      // and it would get it wrong SILENTLY: `_setTab` calls
      // `_syncDashboardVisible()` outside its setState closure, so a direct
      // assignment leaves gate condition 3 believing the grid is on screen.
      // With the IndexedStack keeping the speed card mounted, the GNSS receiver
      // would keep running and speed would keep landing in history — for the
      // rest of the session, in the one mode whose point is that it does not.
      // `main.dart` records this exact bypass having shipped once already.
      expect(services.speed.dashboardVisible, isFalse);
      expect(services.gforce.dashboardVisible, isFalse);
    });

    testWidgets('🔑 from FULL SCREEN it also leaves full screen',
        (tester) async {
      // ⚠️ This is the assertion that actually pins "the move goes through
      // `_setTab`", and it was added after the obvious one above turned out not
      // to. Replacing `_setTab(_Tab.devices)` with `setState(() => _tab = …)`
      // leaves the two `dashboardVisible` flags FALSE anyway — a settings write
      // rebuilds the MaterialApp (theme/locale), which re-runs
      // `didChangeDependencies`, which syncs the gate for its own reasons. The
      // defect is real and the test was passing over it.
      //
      // `_immersive` has no such second writer. It is cleared in `_setTab` and
      // nowhere else, so the bypass shows up here as a user stuck with no app
      // bar and no navigation bar on a tab that is not the grid — and, in
      // advanced mode, no way back to the grid that would explain it. Full
      // screen is a 主頁 state (design 0062 §7.1-7) and advanced mode has no
      // 主頁 (design 0063 Q3), so leaving it is a requirement, not a courtesy.
      final services = await pumpShell(tester);
      await tester.tap(find.byIcon(Icons.fullscreen));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(NavigationBar), findsNothing,
          reason: 'precondition: we are actually in full screen');

      await tester.runAsync(() => services.settings.setMode(AppMode.advanced));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await drain(tester);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(labelsOf(tester), ['裝置', '歷史', '設定']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching back restores 主頁 as a destination', (tester) async {
      // P6: the way out has to exist. Settings is present in both modes, so a
      // user who cannot find the home tab can always get it back — and this
      // says the bar really does grow again rather than needing a restart.
      final services = await pumpShell(tester, mode: AppMode.advanced);
      await tester.runAsync(() => services.settings.setMode(AppMode.personal));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await drain(tester);

      expect(labelsOf(tester), ['主頁', '裝置', '歷史', '設定']);
      // The user is NOT dragged to 主頁: they were reading 裝置 and asked for a
      // menu change, not for a page change. Only the -1 case forces a move.
      expect(find.byType(DevicesPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('H7/H8: the two switches in advanced mode', () {
    /// Open 設定 and hand back the row containing [label].
    Future<Finder> settingsRow(WidgetTester tester, String label) async {
      await tester.tap(find.text('設定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await drain(tester);
      final row = find.ancestor(
        of: find.text(label),
        matching: find.byType(SettingsRow),
      );
      // Scrolled into view first: `find.descendant(... Switch)` reads the
      // widget from the ELEMENT tree, which a ListView will not have built for
      // an off-screen row — the failure would be "no Switch found", i.e. it
      // would look like the control is missing rather than merely unbuilt.
      await tester.scrollUntilVisible(row, 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();
      return row;
    }

    Switch switchIn(WidgetTester tester, Finder row) => tester.widget<Switch>(
        find.descendant(of: row, matching: find.byType(Switch)));

    testWidgets('H7: both are disabled and SAY WHY', (tester) async {
      // 🔑 "Disabled" and "broken" look the same — on screen and in a test.
      // Design 0063 Q3 asks for a control the user can see is switched off BY
      // THE MODE, so the assertion has to cover the caption as well as the
      // `onChanged`. Half of this (the null) would pass on a row that greyed
      // out silently, which is the outcome the ruling exists to prevent.
      final services = await pumpShell(tester, mode: AppMode.advanced);
      await tester.runAsync(() async {
        await services.settings.setSpeedDetection(true);
        await services.settings.setGMeterEnabled(true);
      });
      await tester.pump();

      for (final label in ['速度偵測', 'G 值錶']) {
        final row = await settingsRow(tester, label);
        expect(switchIn(tester, row).onChanged, isNull, reason: label);
        final sub = tester.widget<SettingsRow>(row).sub;
        expect(sub, isNotNull, reason: label);
        expect(sub, contains('進階'),
            reason: '$label must name the mode that turned it off, not just '
                'go grey — a caption that still describes the feature is how '
                'a withdrawn function becomes an apparent fault');
      }
    });

    testWidgets('H8: they still show the STORED value', (tester) async {
      // Design 0063 Q9's user-visible half. If someone "helpfully" points these
      // at the effective values, a user who tries advanced mode finds both
      // switches off when they come back — their own settings, apparently
      // erased by looking at another screen. Nothing would be logged and no
      // export would disagree; only this test would.
      final services = await pumpShell(tester, mode: AppMode.personal);
      await tester.runAsync(() async {
        await services.settings.setSpeedDetection(true);
        await services.settings.setGMeterEnabled(true);
        await services.settings.setMode(AppMode.advanced);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      for (final label in ['速度偵測', 'G 值錶']) {
        final row = await settingsRow(tester, label);
        expect(switchIn(tester, row).value, isTrue,
            reason: '$label shows what the user said, not what is running');
      }
      // And the model agrees that the feature is nonetheless off.
      expect(services.settings.settings.speedDetectionEffective, isFalse);
      expect(services.settings.settings.gMeterEffective, isFalse);
    });

    testWidgets(
        '🔑 H11: the rows that CONFIGURE those features are gone, not greyed',
        (tester) async {
      // Owner ruling 2026-08-15, 逐字「整組收起來」.
      //
      // 🔴 This is the OPPOSITE rule to H7/H8 above, and the difference is what
      // each row IS. The two switches are the user's own answer, so they stay
      // and grey out (Q9). 速度單位 and 校準車架 are settings FOR a feature that
      // is not running — "km/h or mph" for a readout nothing can produce, and
      // "re-run the wizard" for a card that cannot appear. Greying them out
      // would stack four disabled controls in one card; leaving them live would
      // offer choices with no observable effect.
      //
      // What this test would catch: somebody "simplifying" the two conditions
      // to one rule. Both directions are wrong, and neither shows up in H7/H8 —
      // point the switches at the effective value and H8 goes red, but point
      // THESE at the stored value and nothing else in the suite notices.
      final services = await pumpShell(tester, mode: AppMode.personal);
      await tester.runAsync(() async {
        await services.settings.setSpeedDetection(true);
        await services.settings.setGMeterEnabled(true);
      });
      await tester.pump();

      // Personal mode with both switches on: both dependent rows are there.
      await tester.tap(find.text('設定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await drain(tester);
      expect(find.text('速度單位'), findsOneWidget);
      expect(find.text('校準車架'), findsOneWidget);

      await tester.runAsync(() => services.settings.setMode(AppMode.advanced));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await drain(tester);

      expect(find.text('速度單位'), findsNothing,
          reason: 'a unit for a readout that cannot be produced');
      expect(find.text('校準車架'), findsNothing,
          reason: 'a wizard for a card that cannot appear');
      // …while the switches themselves are still on screen, still saying yes.
      expect(find.text('速度偵測'), findsOneWidget);
      expect(find.text('G 值錶'), findsOneWidget);
      // 🔑 And the stored calibration is untouched — design 0045's promise one
      // level up: hiding the row that re-runs the wizard must not erase what
      // the wizard produced.
      expect(services.settings.settings.gMeterEnabled, isTrue);
      expect(services.settings.settings.speedDetection, isTrue);
    });

    testWidgets('the mode row itself is reachable in both modes', (tester) async {
      // P6: advanced mode keeps 設定 precisely so the way back exists. If this
      // row were ever gated on the mode, the feature would be a one-way door.
      for (final mode in AppMode.values) {
        await pumpShell(tester, mode: mode);
        final row = await settingsRow(tester, '模式');
        expect(
          tester.widget<SegmentedControl<AppMode>>(find.descendant(
              of: row, matching: find.byType(SegmentedControl<AppMode>))),
          isA<SegmentedControl<AppMode>>()
              .having((c) => c.selected, 'selected', mode),
        );
      }
    });
  });

  group('H9: the effective-value rule has no seventh consumer', () {
    test('only the model, the controller and the settings screen read the '
        'stored switches', () {
      // 🔑 A GREP, not a unit test, and deliberately so — the defect it catches
      // is the ADDITION of a reader somewhere else, which by definition no
      // existing test covers. The shape is borrowed from
      // `direction_followups_test.dart` X5, which does the same thing to
      // `exportHeaderLines(`'s call sites.
      //
      // What goes wrong without it: a new export path, a new card, a new
      // notification reads `.speedDetection` because that is the obvious name,
      // and it is right in personal mode — which is every developer's phone and
      // every test — and wrong in advanced mode, where it prints a confident
      // header over an empty column. We would find out from a field capture,
      // months later, and it would look like a data-loss bug rather than a
      // one-line mistake.
      //
      // Three files are allowed, and each has a reason it cannot be folded:
      //   * `app_settings.dart` DEFINES both fields and both folds;
      //   * `settings_controller.dart` passes them through for the screen below;
      //   * `settings_screen.dart` DRAWS the user's own answer, which stays
      //     visible while advanced mode withholds the feature (Q9). The screen
      //     answers "what did I say"; everything else answers "what happened",
      //     and only the second one is the fold.
      final grep = Process.runSync(
        'grep',
        // `\b` so that `speedDetectionEffective` — which legitimately contains
        // `speedDetection` — is not counted as a stored-value read. That
        // subtlety is the whole reason this is a word-boundary regex rather
        // than a plain substring search.
        ['-rnE', r'\.(speedDetection|gMeterEnabled)\b', 'lib/'],
        runInShell: false,
      );
      final readers = (grep.stdout as String)
          .trim()
          .split('\n')
          .where((l) => l.isNotEmpty)
          .map((l) => l.split(':'))
          // `path:line:source`. Doc comments name these fields constantly —
          // several of them precisely to warn the reader off — and a sentence
          // about a field is not a read of it.
          .where((p) => !p.sublist(2).join(':').trimLeft().startsWith('//'))
          .map((p) => p.first)
          .toSet();
      expect(readers, {
        'lib/models/app_settings.dart',
        'lib/state/settings_controller.dart',
        'lib/ui/settings/settings_screen.dart',
      });
    });
  });

  group('H10: the preamble says which app wrote the file', () {
    test('`mode:` is emitted for personal too', () {
      // FB-32's standing rule. A line that appeared only in advanced mode would
      // make its absence mean both "they were in personal mode" and "a build
      // older than this one wrote the file" — and these files are read years
      // later, so the second reading never goes away.
      expect(_header(_bothOn), contains('mode: personal'));
      expect(_header(_bothOn.copyWith(mode: AppMode.advanced)),
          contains('mode: advanced'));
    });

    test('it sits directly above the two switch lines', () {
      // Adjacency is asserted rather than left loose because it is what makes
      // `speed detection: off` readable: since 0063 that `off` has two causes,
      // and `mode:` is the line that separates them. Whoever inserts the next
      // header line has to come here and say where it goes.
      final lines = _header(_bothOn);
      final at = lines.indexOf('mode: personal');
      expect(at, greaterThan(0));
      expect(lines[at + 1], startsWith('speed detection: '));
      expect(lines[at + 2], startsWith('g meter: '));
    });

    test('`layout:` is still the last line', () {
      // T10 constraint 1 (`export_layout_header_test.dart:51`): the ingest
      // scripts anchor on it. A new line in the optional middle must not have
      // moved it, and this is cheap insurance against the next one either.
      expect(_header(_bothOn).last, startsWith('layout: '));
      expect(_header(_bothOn.copyWith(mode: AppMode.advanced)).last,
          startsWith('layout: '));
    });

    test('🔑 in advanced mode both switch lines print off, even though the '
        'user left them on', () {
      // §0.6's failure path, written out: turn the G meter on in personal mode,
      // switch to advanced, export. The stored switch still says `on`; the
      // column cannot contain anything; a header that reported the switch would
      // state the same lie FB-32 was raised to end, arriving by a new route.
      final lines = _header(_bothOn.copyWith(mode: AppMode.advanced));
      expect(lines, contains('speed detection: off'));
      expect(lines, contains('g meter: off'));
      // The control: same settings, personal mode, both on.
      final personal = _header(_bothOn);
      expect(personal, contains('speed detection: on'));
      expect(personal, contains('g meter: on'));
    });

    test('the mode line is machine-stable ASCII, not localized', () {
      // A preamble is read by whoever RECEIVES the file — us, months later, or
      // a script — not by the phone that produced it. Same rule as
      // `exportScopeLabel`.
      for (final m in AppMode.values) {
        final line = _header(AppSettings(mode: m))
            .firstWhere((l) => l.startsWith('mode: '));
        expect(line, 'mode: ${m.name}');
        expect(line.codeUnits, everyElement(lessThan(128)));
      }
    });
  });
}
