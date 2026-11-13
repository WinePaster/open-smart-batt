// design 0105 P5 — the other pages, sheets and dialogs in landscape (owner
// ruling 2026-11-13, option ii: 其餘頁沿用置中欄並補上 maxWidth).
//
// What this file pins:
//   1. `LandscapeMaxWidth`: in portrait the child gets exactly the incoming
//      constraints at the origin (today's layout); in landscape it is capped
//      at 560 and centred.
//   2. Devices, History and Settings are centred at ≤ 560 in every
//      landscape window and full width in portrait.
//   3. A rotation — and full screen in landscape — keeps every page's state
//      (the shell moves its pages with a GlobalKey instead of rebuilding them).
//   4. The two sheets that could not scroll now can: the demo picker fits a
//      phone on its side.
//   5. Every dialog and sheet that can be opened on its own: at 844×390 —
//      and, for the five with a text field, with a 200 dp keyboard up — no
//      overflow that a 360 dp portrait phone does not already have.
//
// CLEAN-ROOM: expectations derive from this project's own source and docs.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/main.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/alerts/alert_consent_dialog.dart';
import 'package:open_smart_batt/ui/dashboard/release_cutoff_dialog.dart';
import 'package:open_smart_batt/ui/demo/demo_ui.dart';
import 'package:open_smart_batt/ui/devices/alias_dialog.dart';
import 'package:open_smart_batt/ui/devices/declared_model_dialog.dart';
import 'package:open_smart_batt/ui/devices/devices_page.dart';
import 'package:open_smart_batt/ui/diagnostics/capture_wizard.dart';
import 'package:open_smart_batt/ui/history/custom_range_sheet.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:open_smart_batt/ui/home/home_editor_tutorial.dart';
import 'package:open_smart_batt/ui/home/home_page.dart';
import 'package:open_smart_batt/ui/settings/g_meter_consent_dialog.dart';
import 'package:open_smart_batt/ui/settings/measurement_explainer.dart';
import 'package:open_smart_batt/ui/settings/report_problem.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:open_smart_batt/ui/settings/speed_consent_dialog.dart';
import 'package:open_smart_batt/ui/util/orientation_policy.dart';
import 'package:open_smart_batt/ui/widgets/landscape_max_width.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/landscape_harness.dart';

Future<void> _tapTab(WidgetTester t, IconData icon) async {
  await t.tap(find.byIcon(icon).first);
  await settleHarness(t);
}

/// Every dialog/sheet opener this file drives, by name. `keyboard` marks the
/// five with a text field (0105 §3.2 #11).
final _openers = <(String, bool, Future<Object?> Function(BuildContext))>[
  ('disclaimer', false, showCommunityDisclaimer),
  ('demo picker', false, showDemoPicker),
  ('G consent', false, showGMeterConsentDialog),
  ('speed consent', false, showSpeedDetectionConsentDialog),
  ('alerts consent', false, showAlertsConsentDialog),
  ('speed explainer', false, showSpeedMeasurementExplainer),
  ('G explainer', false, showGForceMeasurementExplainer),
  ('editor tutorial', false, showHomeEditorTutorial),
  ('report problem', false, (c) => reportProblem(c)),
  (
    'capture wizard',
    false,
    (c) => showCaptureWizard(
      c,
      marks: CaptureMark.values.take(6).toList(),
      labelFor: (m) => m.name,
    ),
  ),
  (
    'custom range',
    false,
    (c) => showCustomRangeSheet(
      c,
      firstData: DateTime(2026, 10, 1),
      lastData: DateTime(2026, 11, 13),
    ),
  ),
  ('alias', true, (c) => showAliasDialog(c, initial: 'My battery')),
  ('declared model', true, (c) => showDeclaredModelDialog(c)),
  ('release cut-off', true, (c) => showReleaseCutOffDialog(c)),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUp(OrientationPolicy.debugReset);
  tearDown(OrientationPolicy.debugReset);

  group('1. LandscapeMaxWidth', () {
    Future<Rect> childRect(WidgetTester t, Size window) async {
      setWindow(t, window);
      await t.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: LandscapeMaxWidth(child: SizedBox.expand(key: Key('c'))),
        ),
      );
      return t.getRect(find.byKey(const Key('c')));
    }

    testWidgets('portrait: the incoming constraints, at the origin', (t) async {
      for (final w in [const Size(390, 844), const Size(800, 1280)]) {
        expect(await childRect(t, w), Offset.zero & w);
      }
    });

    testWidgets('landscape: 560, centred', (t) async {
      for (final w in [Win.unit1024.size, Win.unit1280.size]) {
        final r = await childRect(t, w);
        expect(r.width, 560);
        expect(r.height, w.height);
        expect(r.left, (w.width - 560) / 2);
      }
    });

    testWidgets('narrower than the cap: untouched', (t) async {
      final r = await childRect(t, const Size(500, 400));
      expect(r, Offset.zero & const Size(500, 400));
    });
  });

  group('2. devices / history / settings are centred columns', () {
    for (final win in Win.all) {
      testWidgets('$win', (t) async {
        setWindow(t, win.size);
        collectOverflows();
        final s = await makeHarnessServices(t);
        await pumpShell(t, s);
        for (final (icon, page) in [
          (Icons.list_alt_outlined, DevicesPage),
          (Icons.history_outlined, HistoryScreen),
          (Icons.settings_outlined, SettingsScreen),
        ]) {
          await _tapTab(t, icon);
          final r = t.getRect(find.byType(page));
          final slot = t.getRect(
            find.ancestor(
              of: find.byType(page),
              matching: find.byType(LandscapeMaxWidth),
            ),
          );
          if (win == Win.portrait) {
            expect(r, slot, reason: '$page fills its slot in portrait');
            expect(r.width, win.size.width);
          } else {
            expect(r.width, lessThanOrEqualTo(560), reason: '$page');
            expect(
              (r.left - slot.left) - (slot.right - r.right),
              closeTo(0, 0.01),
              reason: '$page centred',
            );
          }
        }
      });
    }
  });

  group('3. state survives a rotation and full screen', () {
    testWidgets('portrait → 1280×720 → portrait keeps the pages', (t) async {
      setWindow(t, Win.portrait.size);
      final s = await makeHarnessServices(t);
      await pumpShell(t, s);
      await _tapTab(t, Icons.list_alt_outlined);
      final devices = t.state(find.byType(DevicesPage, skipOffstage: false));
      final settingsScroll = t.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(SettingsScreen, skipOffstage: false),
              matching: find.byType(Scrollable, skipOffstage: false),
              skipOffstage: false,
            )
            .first,
      );
      for (final w in [Win.unit1280.size, Win.phoneLandscape.size]) {
        t.view.physicalSize = w;
        await settleHarness(t);
        expect(find.byType(NavigationRail), findsOneWidget);
        expect(
          identical(
            t.state(find.byType(DevicesPage, skipOffstage: false)),
            devices,
          ),
          isTrue,
        );
        expect(
          identical(
            t.state<ScrollableState>(
              find
                  .descendant(
                    of: find.byType(SettingsScreen, skipOffstage: false),
                    matching: find.byType(Scrollable, skipOffstage: false),
                    skipOffstage: false,
                  )
                  .first,
            ),
            settingsScroll,
          ),
          isTrue,
        );
        t.view.physicalSize = Win.portrait.size;
        await settleHarness(t);
        expect(
          identical(
            t.state(find.byType(DevicesPage, skipOffstage: false)),
            devices,
          ),
          isTrue,
        );
      }
    });

    testWidgets('full screen in landscape keeps the pages', (t) async {
      setWindow(t, Win.unit1280.size);
      final s = await makeHarnessServices(t);
      await pumpShell(t, s);
      final devices = t.state(find.byType(DevicesPage, skipOffstage: false));
      await t.tap(find.byIcon(Icons.fullscreen));
      await settleHarness(t);
      expect(find.byType(NavigationRail), findsNothing);
      await t.tap(find.byIcon(Icons.fullscreen_exit));
      await settleHarness(t);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(
        identical(
          t.state(find.byType(DevicesPage, skipOffstage: false)),
          devices,
        ),
        isTrue,
      );
    });
  });

  group('4. the demo picker fits a phone on its side', () {
    for (final lang in [AppLang.zhHant, AppLang.en]) {
      for (final os in [1.0, 1.3]) {
        testWidgets('844×390 ${lang.name} OS×$os', (t) async {
          setWindow(t, Win.phoneLandscape.size, os: os);
          final seen = collectOverflows();
          final s = await makeHarnessServices(t, lang: lang);
          await pumpShell(t, s);
          final ctx = t.element(find.byType(HomePage));
          unawaited(showDemoPicker(ctx));
          await settleHarness(t);
          expect(find.byType(BottomSheet), findsOneWidget);
          expect(seen, isEmpty);
          Navigator.of(ctx).pop();
          await settleHarness(t);
        });
      }
    }
  });

  group('5. dialogs and sheets at 844×390', () {
    for (final lang in [AppLang.zhHant, AppLang.en]) {
      for (final os in [1.0, 1.3]) {
        testWidgets('${lang.name} OS×$os', (t) async {
          Future<Map<String, List<SeenOverflow>>> run(
            Size size,
            double keyboard,
          ) async {
            setWindow(t, size, os: os);
            final seen = collectOverflows();
            final s = await makeHarnessServices(t, lang: lang);
            await t.pumpWidget(const SizedBox());
            await pumpShell(t, s);
            final out = <String, List<SeenOverflow>>{};
            for (final (name, hasField, open) in _openers) {
              final ctx = t.element(find.byType(HomePage));
              final kb = hasField ? keyboard : 0.0;
              t.view.viewInsets = FakeViewPadding(bottom: kb);
              seen.clear();
              unawaited(open(ctx));
              await settleHarness(t);
              expect(
                find.byType(Dialog).evaluate().isNotEmpty ||
                    find.byType(AlertDialog).evaluate().isNotEmpty ||
                    find.byType(BottomSheet).evaluate().isNotEmpty,
                isTrue,
                reason: '$name did not open',
              );
              out[name] = [
                for (final o in seen)
                  if (!o.inBrandBar) o,
              ];
              Navigator.of(ctx).pop();
              await settleHarness(t);
              t.view.resetViewInsets();
              await settleHarness(t);
            }
            await t.runAsync(() => s.pending.drain());
            await t.pumpWidget(const SizedBox());
            await settleHarness(t);
            return out;
          }

          // Portrait baseline with a typical portrait keyboard; landscape with
          // a landscape one (≈ 200 dp leaves 190 dp of a 390 dp window).
          final base = await run(const Size(360, 800), 300);
          final land = await run(Win.phoneLandscape.size, 200);
          String key(SeenOverflow o) => o.texts.take(4).join('|');
          final worse = <String>[];
          for (final MapEntry(key: name, value: list) in land.entries) {
            for (final o in list) {
              final b = (base[name] ?? const <SeenOverflow>[]).where(
                (x) => key(x) == key(o),
              );
              final worst = b.isEmpty
                  ? null
                  : b.map((x) => x.px).reduce((a, c) => a > c ? a : c);
              if (worst == null || o.px > worst + 0.5) {
                worse.add('$name: $o');
              }
            }
          }
          expect(worse, isEmpty, reason: 'portrait baseline: $base');
        });
      }
    }
  });
}
