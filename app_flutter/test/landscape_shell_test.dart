// design 0105 P2 — the landscape shell (owner ruling 2026-11-13, option ii).
//
// What this file pins:
//   1. Portrait is today's shell: bottom NavigationBar, brand bar with the
//      mark and name, no rail — at the phone size AND for a tablet upright.
//   2. A landscape window ≥ 600 wide gets a left NavigationRail and no bottom
//      bar; the brand bar sits to the right of the rail without the mark.
//   3. A phone on its side (844×390) — with 「允許橫式畫面」 on OR off, since
//      layout follows the window's shape — also moves the connection pill and
//      the full-screen button into the rail, and has no top bar.
//   4. The rail reads the same `_visibleTabs` as the bottom bar: advanced mode
//      has three destinations and each one opens the page it names.
//   5. Full screen hides the rail too, and every exit still works.
//   6. The rail never overflows: 大／小 × OS 1.0／1.3 × every landscape size.
//
// CLEAN-ROOM: expectations derive from this project's own source and docs.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/devices/devices_page.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:open_smart_batt/ui/home/home_page.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:open_smart_batt/ui/util/orientation_policy.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/landscape_harness.dart';

final _rail = find.byType(NavigationRail);
final _bottomBar = find.byType(NavigationBar);
final _brandName = find.text('OPENSMARTBATT');
final _railPill = find.byKey(const ValueKey('rail-connection-pill'));
final _railFullscreen = find.byKey(const ValueKey('rail-fullscreen'));

/// Whether [page] is the IndexedStack child on screen.
bool _onScreen(WidgetTester t, Type page) {
  final f = find.byType(page);
  if (f.evaluate().isEmpty) return false;
  return f.hitTestable().evaluate().isNotEmpty ||
      t.getRect(f).overlaps(Offset.zero & t.view.physicalSize);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUp(OrientationPolicy.debugReset);
  tearDown(OrientationPolicy.debugReset);

  group('1. portrait is today', () {
    for (final size in [Win.portrait.size, const Size(800, 1280)]) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()}: bottom bar, '
          'full brand bar, no rail', (t) async {
        setWindow(t, size);
        final s = await makeHarnessServices(t);
        await pumpShell(t, s);
        expect(_bottomBar, findsOneWidget);
        expect(_rail, findsNothing);
        expect(_brandName, findsOneWidget);
        expect(_railPill, findsNothing);
      });
    }
  });

  group('2. wide landscape: rail + brand bar beside it', () {
    for (final win in [Win.unit853, Win.unit1024, Win.unit1280, Win.unit1920]) {
      testWidgets('$win', (t) async {
        setWindow(t, win.size);
        final s = await makeHarnessServices(t);
        await pumpShell(t, s);
        expect(_rail, findsOneWidget);
        expect(_bottomBar, findsNothing);
        // The bar is there (pill + full screen), the mark moved to the rail.
        expect(
          find.text('CONNECTED').evaluate().isNotEmpty ||
              find.text('OFFLINE').evaluate().isNotEmpty,
          isTrue,
        );
        expect(_brandName, findsNothing);
        expect(_railPill, findsNothing);
        expect(
          find.byIcon(Icons.bolt),
          findsOneWidget,
          reason: 'the mark sits at the top of the rail',
        );
        // Rail is on the LEFT and spans the height.
        final r = t.getRect(_rail);
        expect(r.left, 0);
        expect(r.height, win.size.height);
        // The pages lie to its right.
        expect(
          t.getRect(find.byType(HomePage)).left,
          greaterThanOrEqualTo(r.right),
        );
      });
    }
  });

  group('3. a phone on its side: everything in the rail', () {
    for (final allow in [false, true]) {
      testWidgets('844×390, 「允許橫式畫面」 ${allow ? 'on' : 'off'}', (t) async {
        setWindow(t, Win.phoneLandscape.size);
        // A real phone on its side: Android status bar on top, gesture bar
        // below (the emulator check that found the full-screen button below
        // the fold had both).
        t.view.padding = const FakeViewPadding(top: 24, bottom: 16);
        addTearDown(t.view.resetPadding);
        final s = await makeHarnessServices(t, allowLandscape: allow);
        await pumpShell(t, s);
        expect(_rail, findsOneWidget);
        expect(_bottomBar, findsNothing);
        expect(
          find.byType(AppBar),
          findsNothing,
          reason: 'no top bar: height is what a phone on its side lacks',
        );
        expect(_railPill, findsOneWidget);
        expect(_railFullscreen, findsOneWidget);
        // The pill says what the bar's pill says.
        expect(
          find.descendant(of: _railPill, matching: find.text('OFFLINE')),
          findsOneWidget,
        );
        // The content starts right under the status bar: no top bar.
        expect(t.getRect(find.byType(HomePage)).top, 24);
        // Everything in the rail fits the window at the default font — the
        // full-screen button is 主頁's only way in and must not sit below the
        // fold (measured on an 844×390 emulator: with the brand mark it did).
        expect(
          find.byIcon(Icons.bolt),
          findsNothing,
          reason: 'no brand mark in the compact rail',
        );
        expect(
          t.getRect(_railFullscreen).bottom,
          lessThanOrEqualTo(Win.phoneLandscape.size.height - 16),
        );
        expect(t.getRect(_railPill).top, greaterThanOrEqualTo(24));
        // 🔴 …and they stay visible whatever the font: the pill and the
        // full-screen button are PINNED, only the tabs scroll between them.
        // Asserted structurally because the test font's line height is
        // shorter than a device CJK font's — on the emulator the unpinned
        // button was below the fold while this geometry check still passed.
        final rail = t.widget<NavigationRail>(_rail);
        expect(rail.leadingAtTop, isTrue);
        expect(rail.trailingAtBottom, isTrue);
        expect(rail.scrollable, isTrue);
        // FB-70's floor on the moved control.
        final b = t.getSize(_railFullscreen);
        expect(b.width, greaterThanOrEqualTo(40));
        expect(b.height, greaterThanOrEqualTo(40));
        // The setting changed the orientation request, not the layout.
        expect(
          OrientationPolicy.current,
          allow ? OrientationPolicy.any : OrientationPolicy.portraitOnly,
        );
      });
    }

    testWidgets('the rail pill goes where the bar pill goes', (t) async {
      setWindow(t, Win.phoneLandscape.size);
      final s = await makeHarnessServices(t);
      await pumpShell(t, s);
      await t.tap(_railPill);
      await settleHarness(t);
      // Nothing linked ⇒ the devices list (`_openConnectionTarget`).
      expect(_onScreen(t, DevicesPage), isTrue);
    });

    testWidgets('full screen is offered on 主頁 only', (t) async {
      setWindow(t, Win.phoneLandscape.size);
      final s = await makeHarnessServices(t);
      await pumpShell(t, s);
      expect(_railFullscreen, findsOneWidget);
      await t.tap(find.byIcon(Icons.settings_outlined));
      await settleHarness(t);
      expect(_railFullscreen, findsNothing);
    });
  });

  group('4. one list of tabs', () {
    for (final mode in AppMode.values) {
      testWidgets('${mode.name}: every rail destination opens its page', (
        t,
      ) async {
        setWindow(t, Win.unit1280.size);
        final s = await makeHarnessServices(t);
        await t.runAsync(() => s.settings.setMode(mode));
        await pumpShell(t, s);
        final rail = t.widget<NavigationRail>(_rail);
        final pages = [
          if (mode == AppMode.personal) (Icons.dashboard_outlined, HomePage),
          (Icons.list_alt_outlined, DevicesPage),
          (Icons.history_outlined, HistoryScreen),
          (Icons.settings_outlined, SettingsScreen),
        ];
        expect(rail.destinations.length, pages.length);
        // Advanced mode lands on 裝置, the first tab that exists.
        expect(rail.selectedIndex, 0);
        for (final (i, (icon, page)) in pages.reversed.indexed) {
          final f = find.descendant(of: _rail, matching: find.byIcon(icon));
          if (f.evaluate().isNotEmpty) {
            await t.tap(f);
            await settleHarness(t);
          }
          expect(
            t.widget<NavigationRail>(_rail).selectedIndex,
            pages.length - 1 - i,
          );
          expect(_onScreen(t, page), isTrue, reason: '$page');
        }
      });
    }

    testWidgets('rotating keeps the tab: bar → rail → bar', (t) async {
      setWindow(t, Win.portrait.size);
      final s = await makeHarnessServices(t);
      await pumpShell(t, s);
      await t.tap(find.byIcon(Icons.history_outlined));
      await settleHarness(t);
      t.view.physicalSize = Win.unit1280.size;
      await settleHarness(t);
      expect(t.widget<NavigationRail>(_rail).selectedIndex, 2);
      expect(_onScreen(t, HistoryScreen), isTrue);
      t.view.physicalSize = Win.portrait.size;
      await settleHarness(t);
      expect(t.widget<NavigationBar>(_bottomBar).selectedIndex, 2);
    });
  });

  group('5. full screen hides the rail too', () {
    for (final win in [Win.phoneLandscape, Win.unit1280]) {
      testWidgets('$win', (t) async {
        setWindow(t, win.size);
        final s = await makeHarnessServices(t);
        await pumpShell(t, s);
        final enter = win == Win.phoneLandscape
            ? _railFullscreen
            : find.byIcon(Icons.fullscreen);
        await t.tap(enter);
        await settleHarness(t);
        expect(_rail, findsNothing);
        expect(find.byType(AppBar), findsNothing);
        expect(_bottomBar, findsNothing);
        // Exit route 2 (the persistent button) brings the rail back.
        await t.tap(find.byIcon(Icons.fullscreen_exit));
        await settleHarness(t);
        expect(_rail, findsOneWidget);
      });
    }
  });

  group('6. the rail never overflows', () {
    for (final win in [Win.phoneLandscape, Win.unit853, Win.unit1024]) {
      for (final size in AppTextSize.values) {
        for (final os in [1.0, 1.3, 2.0]) {
          for (final lang in [AppLang.zhHant, AppLang.en]) {
            testWidgets('$win ${size.name} OS×$os ${lang.name}', (t) async {
              setWindow(t, win.size, os: os);
              final seen = collectOverflows();
              final s = await makeHarnessServices(t, size: size, lang: lang);
              await pumpShell(t, s);
              await t.tap(find.byIcon(Icons.settings_outlined));
              await settleHarness(t);
              final inRail = <SeenOverflow>[];
              for (final o in seen) {
                if (o.texts.any(_railTexts.contains)) inRail.add(o);
              }
              expect(inRail, isEmpty);
              // And the rail itself was laid out within the window.
              expect(
                t.getRect(_rail).bottom,
                lessThanOrEqualTo(win.size.height),
              );
            });
          }
        }
      }
    }
  });
}

const _railTexts = {
  '主頁', '裝置', '歷史', '設定', 'Home', 'Devices', 'History', 'Settings', //
  'OFFLINE', 'CONNECTED', 'CONNECTING', '全螢幕', 'Full screen',
};
