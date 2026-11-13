// design 0105 P3 — the home page in landscape (owner ruling 2026-11-13:
// Q4 = A「照原順序分欄」, Q7 = A「大字體少一欄」).
//
// What this file pins:
//   1. The column rule: clamp(⌊(w + gap) ÷ (330 + gap)⌋, 1, 3), one fewer
//      when the user's own text scale is ≥ 1.1; columns at most 560 wide.
//   2. The split: sections stay in order, column-major, tallest column as
//      short as possible, ties keep earlier columns fuller.
//   3. 🔴 Portrait is today, to the pixel: today's HomePage (a frozen copy
//      from 612fee5) and the new one render identical geometry AND pixels at
//      four portrait sizes, under 大 and 小, OS 1.0 and 1.3.
//   4. The real shell at every 0105 §4.9 window: rail-adjusted column counts
//      for 大／小 × OS 1.0／1.3; order; 560 cap; design 0084 half tiles stay
//      side by side inside one column; two units on a head unit fit one
//      screen.
//   5. No overflow a 360 dp portrait phone does not already have.
//
// CLEAN-ROOM: expectations derive from this project's own source and docs.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/demo/demo.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/home/home_page.dart';
import 'package:open_smart_batt/ui/home/home_tiles.dart';
import 'package:open_smart_batt/ui/util/orientation_policy.dart';
import 'package:open_smart_batt/ui/util/wide_layout.dart';
import 'package:open_smart_batt/ui/widgets/flow_columns.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/landscape_harness.dart';
import 'support/legacy/legacy_home_page.dart';

/// A layout that exercises every section shape: full-width cards, a
/// design-0084 half pair of unequal height, a lone half, and modules of two
/// units.
const _bat = 'AA:BB:CC:DD:EE:01';
const _cap = 'AA:BB:CC:DD:EE:02';
final _layout = HomeLayout([
  const HomeTile.device(_bat),
  const HomeTile.device(_cap),
  const HomeTile.module(DisplayModule.gaugeVoltage, deviceId: _bat),
  const HomeTile.module(
    DisplayModule.readouts,
    deviceId: _bat,
    span: HomeSpan.half,
  ),
  const HomeTile.module(DisplayModule.clock, span: HomeSpan.half),
  const HomeTile.module(DisplayModule.gaugeVoltage, deviceId: _cap),
  const HomeTile.module(
    DisplayModule.readouts,
    deviceId: _cap,
    span: HomeSpan.half,
  ),
  const HomeTile.module(DisplayModule.clock),
]);

/// Every RenderBox under [root]: type, global origin and size.
List<String> _geometry(WidgetTester t, Finder root) {
  final out = <String>[];
  void visit(RenderObject r) {
    if (r is RenderBox && r.hasSize) {
      final o = r.localToGlobal(Offset.zero);
      out.add(
        '${r.runtimeType} '
        '${o.dx.toStringAsFixed(2)},${o.dy.toStringAsFixed(2)} '
        '${r.size.width.toStringAsFixed(2)}×${r.size.height.toStringAsFixed(2)}',
      );
    }
    r.visitChildren(visit);
  }

  visit(t.renderObject(root));
  return out;
}

final _shot = GlobalKey();

/// Pump [page] the way the app does — providers, theme, the text-size
/// builder of `main.dart` — inside a RepaintBoundary to capture.
Future<void> _pumpPage(
  WidgetTester t,
  AppServices s,
  Widget page,
  AppTextSize size,
) async {
  await t.pumpWidget(
    MultiProvider(
      providers: [
        Provider<BleService>.value(value: s.ble),
        ChangeNotifierProvider<SettingsController>.value(value: s.settings),
        ChangeNotifierProvider<DeviceController>.value(value: s.devices),
        ChangeNotifierProvider<ConnectionController>.value(value: s.connection),
        ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
        ChangeNotifierProvider<GForceController>.value(value: s.gforce),
        ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: (context, child) {
          final mq = MediaQuery.of(context);
          return AppTextScaleScope(
            factor: AppTheme.appTextScaleFor(size),
            child: MediaQuery(
              data: mq.copyWith(
                textScaler: AppTheme.applyAppTextScale(mq.textScaler, size),
              ),
              child: child!,
            ),
          );
        },
        home: RepaintBoundary(
          key: _shot,
          child: Scaffold(body: page),
        ),
      ),
    ),
  );
  await settleHarness(t);
}

Future<Uint8List> _pixels(WidgetTester t) async {
  late Uint8List bytes;
  await t.runAsync(() async {
    final img = await captureImage(t.element(find.byKey(_shot)));
    bytes = (await img.toByteData())!.buffer.asUint8List();
    img.dispose();
  });
  return bytes;
}

/// The FlowColumns on screen, or null when the page is single-column.
FlowColumns? _flow(WidgetTester t) {
  final f = find.byType(FlowColumns);
  return f.evaluate().isEmpty ? null : t.widget<FlowColumns>(f);
}

/// Column index of each FlowColumns child, in child order.
List<int> _columnsOfChildren(WidgetTester t) {
  final r = t.renderObject<RenderFlowColumns>(find.byType(FlowColumns));
  final out = <int>[];
  var c = r.firstChild;
  while (c != null) {
    out.add((c.parentData! as FlowColumnsParentData).column);
    c = r.childAfter(c);
  }
  return out;
}

Finder _tile(bool Function(HomeTile) test) =>
    find.byWidgetPredicate((w) => w is HomeTileView && test(w.tile));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUp(OrientationPolicy.debugReset);
  tearDown(OrientationPolicy.debugReset);

  group('1. the column rule', () {
    test('widths → columns (min 330, gap 14, max 3)', () {
      for (final (w, n) in [
        (0.0, 1),
        (329.0, 1),
        (673.0, 1),
        (674.0, 2),
        (733.0, 2),
        (1017.0, 2),
        (1018.0, 3),
        (1169.0, 3),
        (1810.0, 3),
        (5000.0, 3),
      ]) {
        expect(WideLayout.columnsFor(w), n, reason: 'width $w');
      }
    });

    test('large text drops one column, never below one (Q7 = A)', () {
      for (final (w, n) in [(300.0, 1), (733.0, 1), (1169.0, 2), (1810.0, 2)]) {
        expect(WideLayout.columnsFor(w, largeText: true), n, reason: '$w');
      }
      expect(WideLayout.columnsFor(1810, max: 2, largeText: true), 1);
    });

    test('a column is never wider than 560', () {
      expect(WideLayout.maxWidthFor(1), 560);
      expect(WideLayout.maxWidthFor(3), 3 * 560 + 2 * 14);
    });
  });

  group('2. the split', () {
    List<int> p(List<double> h, int n) => RenderFlowColumns.partition(h, n);
    test('in order, tallest column minimised', () {
      expect(p([100, 100, 100, 100], 2), [0, 2]);
      expect(p([120, 120, 226, 226], 2), [0, 2]);
      expect(p([300, 50, 50, 50, 50], 2), [0, 1]);
      expect(p([50, 50, 50, 50, 300], 2), [0, 4]);
      expect(p([120, 120, 260, 260], 3), [0, 2, 3]);
    });
    test('ties keep earlier columns fuller', () {
      expect(p([100, 100, 100], 2), [0, 2]);
      expect(p([100], 3), [0, 1, 1]);
      expect(p([], 3), [0, 0, 0]);
    });
    test('one column is everything', () {
      expect(p([1, 2, 3], 1), [0]);
    });
  });

  group('3. 🔴 portrait is today, to the pixel', () {
    for (final size in [
      const Size(390, 844),
      const Size(360, 800),
      const Size(320, 700),
      const Size(800, 1280),
    ]) {
      for (final text in AppTextSize.values) {
        for (final os in [1.0, 1.3]) {
          testWidgets('${size.width.toInt()}×${size.height.toInt()} '
              '${text.name} OS×$os', (t) async {
            setWindow(t, size, os: os);
            collectOverflows(); // compared, not asserted, here
            final s = await makeHarnessServices(t);
            await t.runAsync(() => s.settings.setHomeLayout(_layout.encode()));
            await _pumpPage(t, s, const LegacyHomePage(), text);
            final before = _geometry(t, find.byType(LegacyHomePage));
            final beforePx = await _pixels(t);
            await _pumpPage(t, s, const HomePage(), text);
            final after = _geometry(t, find.byType(HomePage));
            final afterPx = await _pixels(t);
            expect(find.byType(FlowColumns), findsNothing);
            expect(
              find.byType(LayoutBuilder).evaluate().where((e) {
                // No LayoutBuilder of HomePage's own (cards may have theirs).
                return e.findAncestorWidgetOfExactType<HomeTileView>() == null;
              }),
              isEmpty,
            );
            // Not vacuous: real cards were laid out and painted.
            expect(before.length, greaterThan(100));
            expect(find.byType(HomeTileView), findsWidgets);
            expect(beforePx.toSet().length, greaterThan(2));
            expect(after, before);
            expect(afterPx, beforePx, reason: 'pixels differ');
          });
        }
      }
    }
  });

  group('4. the real shell', () {
    // Expected columns per window, with zh labels (rail ≈ 80 dp wide).
    final table = <(Win, double, int)>[
      (Win.phoneLandscape, 1.0, 2),
      (Win.unit853, 1.0, 2),
      (Win.unit1024, 1.0, 2),
      (Win.unit1280, 1.0, 3),
      (Win.unit1920, 1.0, 3),
      (Win.phoneLandscape, 1.3, 1),
      (Win.unit853, 1.3, 1),
      (Win.unit1024, 1.3, 1),
      (Win.unit1280, 1.3, 2),
      (Win.unit1920, 1.3, 2),
    ];
    for (final (win, os, columns) in table) {
      for (final text in AppTextSize.values) {
        testWidgets('$win OS×$os ${text.name} ⇒ $columns column(s)', (t) async {
          setWindow(t, win.size, os: os);
          collectOverflows(); // section 5's business
          final s = await makeHarnessServices(t, size: text);
          await t.runAsync(() => s.settings.setHomeLayout(_layout.encode()));
          await pumpShell(t, s);
          final flow = _flow(t);
          expect(flow?.columns ?? 1, columns);
          if (flow == null) {
            // Single column: today's tree, 560 cap.
            expect(
              t.getSize(find.byType(ListView).first).width,
              lessThanOrEqualTo(560),
            );
            return;
          }
          // Order: column-major, never backwards.
          final cols = _columnsOfChildren(t);
          for (var i = 1; i < cols.length; i++) {
            expect(cols[i], greaterThanOrEqualTo(cols[i - 1]));
          }
          expect(
            cols.toSet().length,
            greaterThan(1),
            reason: 'more than one column actually used',
          );
          // 560 cap per column.
          final r = t.renderObject<RenderFlowColumns>(find.byType(FlowColumns));
          var c = r.firstChild;
          while (c != null) {
            expect(c.size.width, lessThanOrEqualTo(560 + 1e-6));
            expect(
              c.size.width,
              greaterThanOrEqualTo(WideLayout.columnMinWidth - 1e-6),
            );
            c = r.childAfter(c);
          }
          // design 0084 inside a column: the half pair sits side by side,
          // left of right, both inside one column's band.
          final left = t.getRect(
            _tile(
              (x) => x.deviceId == _bat && x.module == DisplayModule.readouts,
            ),
          );
          final right = t.getRect(
            _tile(
              (x) => x.module == DisplayModule.clock && x.span == HomeSpan.half,
            ),
          );
          expect(left.right, lessThanOrEqualTo(right.left));
          expect(right.left - left.right, closeTo(kHomeColumnGap, 0.01));
          expect(left.width, closeTo(right.width, 0.01));
          // The edit row is still the last thing, under the columns.
          final edit = find.text('編輯版面');
          if (edit.evaluate().isNotEmpty) {
            expect(
              t.getRect(edit).top,
              greaterThan(t.getRect(find.byType(FlowColumns)).bottom - 1),
            );
          }
        });
      }
    }

    testWidgets('two units on a 1280×720 head unit: both cards and both '
        'gauges on the first screen (mock §3 layout A)', (t) async {
      setWindow(t, Win.unit1280.size);
      final s = await makeHarnessServices(t);
      await t.runAsync(
        () => s.settings.setHomeLayout(
          HomeLayout(const [
            HomeTile.device(_bat),
            HomeTile.device(_cap),
            HomeTile.module(DisplayModule.gaugeVoltage, deviceId: _bat),
            HomeTile.module(DisplayModule.gaugeVoltage, deviceId: _cap),
          ]).encode(),
        ),
      );
      await pumpShell(t, s);
      expect(_flow(t)?.columns, 3);
      final screen = Offset.zero & Win.unit1280.size;
      for (final f in [
        _tile((x) => x.kind == HomeTileKind.deviceCard && x.deviceId == _bat),
        _tile((x) => x.kind == HomeTileKind.deviceCard && x.deviceId == _cap),
        _tile(
          (x) => x.deviceId == _bat && x.module == DisplayModule.gaugeVoltage,
        ),
        _tile(
          (x) => x.deviceId == _cap && x.module == DisplayModule.gaugeVoltage,
        ),
      ]) {
        final r = t.getRect(f);
        expect(
          screen.contains(r.topLeft) &&
              screen.contains(r.bottomRight - const Offset(1, 1)),
          isTrue,
          reason: '$r is not fully on screen',
        );
      }
    });

    testWidgets('the default layout for three saved units flows too', (
      t,
    ) async {
      setWindow(t, Win.unit1920.size);
      final s = await makeHarnessServices(t);
      await pumpShell(t, s);
      expect(_flow(t)?.columns, 3);
      expect(find.byType(HomeTileView), findsWidgets);
    });

    testWidgets('a live demo unit (multi-link off) flows without error', (
      t,
    ) async {
      setWindow(t, Win.unit1280.size);
      final s = await makeHarnessServices(t);
      await pumpShell(t, s);
      await t.runAsync(() => s.connection.connect(DemoKind.battery.id));
      await settleHarness(t);
      expect(_flow(t)?.columns, 3);
      expect(t.takeException(), isNull);
      await t.runAsync(s.connection.disconnect);
      await settleHarness(t);
    });
  });

  group('5. no overflow a 360 dp portrait phone does not already have', () {
    for (final text in AppTextSize.values) {
      for (final os in [1.0, 1.3]) {
        for (final lang in [AppLang.zhHant, AppLang.en]) {
          testWidgets('${text.name} OS×$os ${lang.name}', (t) async {
            Future<List<SeenOverflow>> run(Size size) async {
              setWindow(t, size, os: os);
              final seen = collectOverflows();
              final s = await makeHarnessServices(t, size: text, lang: lang);
              await t.runAsync(
                () => s.settings.setHomeLayout(_layout.encode()),
              );
              await t.pumpWidget(const SizedBox());
              await pumpShell(t, s);
              await t.runAsync(() => s.connection.connect(DemoKind.battery.id));
              await settleHarness(t);
              await t.runAsync(s.connection.disconnect);
              await settleHarness(t);
              await t.pumpWidget(const SizedBox());
              await settleHarness(t);
              return [
                for (final o in seen)
                  if (!o.inBrandBar) o,
              ];
            }

            final base = await run(const Size(360, 800));
            String key(SeenOverflow o) => o.texts.take(4).join('|');
            final worse = <String>[];
            for (final win in Win.landscapes) {
              for (final o in await run(win.size)) {
                final b = base.where((x) => key(x) == key(o));
                if (b.isEmpty ||
                    o.px >
                        b.map((x) => x.px).reduce((a, c) => a > c ? a : c) +
                            0.5) {
                  worse.add('$win: $o');
                }
              }
            }
            expect(worse, isEmpty, reason: 'portrait 360 baseline: $base');
          });
        }
      }
    }
  });
}
