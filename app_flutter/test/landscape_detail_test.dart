// design 0105 P4 — the device page's live tab in two columns (owner ruling
// 2026-11-13, Q5 = A「保護卡放右欄最後」, Q7 = A「大字體少一欄」).
//
// What this file pins:
//   1. The split rule, including the adaptation for pages without a gauge
//      (the chart takes the gauge's slot on the left).
//   2. 🔴 Portrait is today, to the pixel: the pack and power-bank bodies as
//      they were at 612fee5 (frozen copies) and today's render identical
//      geometry and pixels — live demo telemetry, four portrait sizes, 大/小,
//      OS 1.0/1.3.
//   3. In a wide landscape window: two columns; the protection card is LAST
//      in the RIGHT column with only the warnings entry after it (design 0034
//      §6 as relaxed by 0105 Q5); nothing a face placed follows it; no
//      control in the left column. Large text ⇒ one column again.
//   4. No overflow a 360 dp portrait phone does not already have.
//
// CLEAN-ROOM: expectations derive from this project's own source and docs.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/alerts/alert_settings_page.dart';
import 'package:open_smart_batt/ui/dashboard/detail_columns.dart';
import 'package:open_smart_batt/ui/dashboard/dvol_bars.dart';
import 'package:open_smart_batt/ui/dashboard/pack_view.dart';
import 'package:open_smart_batt/ui/dashboard/power_bank_view.dart';
import 'package:open_smart_batt/ui/dashboard/power_path_row.dart';
import 'package:open_smart_batt/ui/dashboard/readouts_card.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls.dart';
import 'package:open_smart_batt/ui/devices/device_detail_page.dart';
import 'package:open_smart_batt/ui/util/orientation_policy.dart';
import 'package:open_smart_batt/ui/widgets/industrial.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/landscape_harness.dart';
import 'support/legacy/legacy_pack_view.dart';
import 'support/legacy/legacy_power_bank_view.dart';

final _two = find.byKey(const ValueKey('detail-two-columns'));
final _left = find.byKey(const ValueKey('detail-left'));
final _right = find.byKey(const ValueKey('detail-right'));

NavigatorState _nav(WidgetTester t) =>
    t.state<NavigatorState>(find.byType(Navigator).first);

Future<void> _push(WidgetTester t, Widget page) async {
  unawaited(_nav(t).push(MaterialPageRoute<void>(builder: (_) => page)));
  await settleHarness(t);
}

Future<void> _pop(WidgetTester t) async {
  _nav(t).pop();
  await settleHarness(t);
}

List<String> _geometry(WidgetTester t, Finder root) {
  final out = <String>[];
  final base = t.renderObject<RenderBox>(root).localToGlobal(Offset.zero);
  void visit(RenderObject r) {
    if (r is RenderBox && r.hasSize) {
      final o = r.localToGlobal(Offset.zero) - base;
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

Future<Uint8List> _pixels(WidgetTester t, Key k) async {
  late Uint8List bytes;
  await t.runAsync(() async {
    final img = await captureImage(t.element(find.byKey(k)));
    bytes = (await img.toByteData())!.buffer.asUint8List();
    img.dispose();
  });
  return bytes;
}

const _kOld = ValueKey('legacy');
const _kNew = ValueKey('current');

/// Legacy and current, stacked in one route so both render the SAME frame of
/// the same live telemetry; each in its own boundary so each can be captured.
Widget _sideBySide(BuildContext c, Widget legacy, Widget current) => Scaffold(
  body: Stack(
    children: [
      for (final (k, w) in [(_kOld, legacy), (_kNew, current)])
        Positioned.fill(
          child: RepaintBoundary(
            key: k,
            child: ColoredBox(
              color: Theme.of(c).scaffoldBackgroundColor,
              child: w,
            ),
          ),
        ),
    ],
  ),
);

/// The card widgets of a column, in order.
List<Widget> _columnChildren(WidgetTester t, Finder col) =>
    t.widget<Column>(col).children;

bool _isProtection(Widget w) =>
    w is IndustrialCard &&
    (w.child is BatteryControls ||
        w.child is CapacitorControls ||
        w.child is PackControls);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUp(OrientationPolicy.debugReset);
  tearDown(OrientationPolicy.debugReset);

  group('1. the split rule', () {
    const g = DisplayModule.gaugeVoltage;
    const ch = DisplayModule.chart;
    const ro = DisplayModule.readouts;
    const ce = DisplayModule.cells;
    const ep = DisplayModule.energyPath;
    const soc = DisplayModule.gaugeSoc;
    test('with a gauge: exactly 0105 §6 P4', () {
      expect(DetailColumns.rightFor(DetailColumns.packRight, [g, ch, ro, ce]), {
        ce,
        ch,
        ep,
      });
      expect(
        DetailColumns.rightFor(DetailColumns.powerBankRight, [soc, ch, ro, ep]),
        {ep, ro, ch, ce},
      );
    });
    test('without a gauge (the fixed face today): the chart goes left', () {
      expect(
        DetailColumns.rightFor(DetailColumns.packRight, [ch, ro, ce]),
        isNot(contains(ch)),
      );
      final (l, r) = DetailColumns.split([
        (ch, const Text('chart')),
        (ro, const Text('readouts')),
        (ce, const Text('cells')),
        (DisplayModule.speed, null),
      ], DetailColumns.packRight);
      expect([for (final w in l) (w as Text).data], ['chart', 'readouts']);
      expect([for (final w in r) (w as Text).data], ['cells']);
      final (pl, pr) = DetailColumns.split([
        (ch, const Text('chart')),
        (ro, const Text('readouts')),
        (ep, const Text('path')),
      ], DetailColumns.powerBankRight);
      expect([for (final w in pl) (w as Text).data], ['chart']);
      expect([for (final w in pr) (w as Text).data], ['readouts', 'path']);
    });
  });

  // The three saved harness units, with the device-type byte that routes
  // and classifies each.
  final units = <(String, String, int)>[
    ('battery', 'AA:BB:CC:DD:EE:01', kTypeBattery),
    ('capacitor', 'AA:BB:CC:DD:EE:02', kTypeCapacitor),
    ('power bank', 'AA:BB:CC:DD:EE:03', kTypePowerBank),
  ];

  group('2. 🔴 portrait is today, to the pixel', () {
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
            final s = await makeHarnessServices(t, size: text);
            await pumpShell(t, s);
            for (final (name, id, type) in units) {
              await linkWithTelemetry(t, s, id, type);
              final pb = type == kTypePowerBank;
              await _push(
                t,
                Builder(
                  builder: (c) => _sideBySide(
                    c,
                    pb
                        ? LegacyPowerBankView(deviceId: id)
                        : LegacyPackView(deviceId: id),
                    pb ? PowerBankView(deviceId: id) : PackView(deviceId: id),
                  ),
                ),
              );
              expect(
                find.byType(pb ? PowerBankView : PackScaffold),
                findsOneWidget,
                reason: '$name routed',
              );
              final before = _geometry(t, find.byKey(_kOld));
              final after = _geometry(t, find.byKey(_kNew));
              expect(before.length, greaterThan(40), reason: name);
              expect(after, before, reason: '$name geometry');
              final a = await _pixels(t, _kOld);
              final b = await _pixels(t, _kNew);
              expect(a.toSet().length, greaterThan(2), reason: name);
              expect(b, a, reason: '$name pixels');
              expect(_two, findsNothing, reason: name);
              await _pop(t);
              await t.runAsync(s.connection.disconnect);
              await settleHarness(t);
            }
          });
        }
      }
    }
  });

  group('3. two columns, control card last in the right column', () {
    for (final win in Win.landscapes) {
      for (final (name, id, type) in units.take(2)) {
        testWidgets('$win $name', (t) async {
          setWindow(t, win.size);
          collectOverflows(); // section 4's business
          final s = await makeHarnessServices(t);
          await pumpShell(t, s);
          await linkWithTelemetry(t, s, id, type);
          await _push(t, DeviceDetailPage(deviceId: id));
          expect(find.byType(PackScaffold), findsOneWidget);
          expect(_two, findsOneWidget);
          final left = _columnChildren(t, _left);
          final right = _columnChildren(t, _right);
          // Q5 = A: last in the RIGHT column, the warnings entry its one
          // follower, and nothing a face placed comes after it.
          expect(right.last, isA<AlertSettingsEntry>());
          expect(_isProtection(right[right.length - 2]), isTrue);
          expect(right.where(_isProtection).length, 1);
          expect(left.where(_isProtection), isEmpty);
          expect(left.whereType<AlertSettingsEntry>(), isEmpty);
          final protectionTop = t
              .getRect(
                find.descendant(
                  of: _right,
                  matching: find.byWidgetPredicate(_isProtection),
                ),
              )
              .top;
          for (final f in [
            find.descendant(of: _right, matching: find.byType(DvolBars)),
            find.descendant(of: _right, matching: find.byType(TrendChartCard)),
          ]) {
            for (final e in f.evaluate()) {
              final box = e.renderObject! as RenderBox;
              expect(
                box.localToGlobal(Offset.zero).dy,
                lessThan(protectionTop),
              );
            }
          }
          // The battery's cells are on the right, above the controls.
          if (type == kTypeBattery) {
            expect(
              find.descendant(of: _right, matching: find.byType(DvolBars)),
              findsOneWidget,
            );
          }
          // The live reading on the left (chart in the gauge's slot).
          expect(
            find.descendant(of: _left, matching: find.byType(ReadoutsCard)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: _left, matching: find.byType(TrendChartCard)),
            findsOneWidget,
          );
          // The two columns sit side by side.
          expect(t.getRect(_left).right, lessThan(t.getRect(_right).left));
          expect(t.getRect(_left).width, closeTo(t.getRect(_right).width, 1));
          expect(t.getRect(_left).width, lessThanOrEqualTo(560));
          await _pop(t);
          await t.runAsync(s.connection.disconnect);
          await settleHarness(t);
        });
      }

      testWidgets('$win power bank: chart left; energy path and numbers '
          'right; warnings entry last', (t) async {
        setWindow(t, win.size);
        collectOverflows();
        final s = await makeHarnessServices(t);
        await pumpShell(t, s);
        await linkWithTelemetry(t, s, units[2].$2, kTypePowerBank);
        await _push(t, DeviceDetailPage(deviceId: units[2].$2));
        expect(find.byType(PowerBankView), findsOneWidget);
        expect(_two, findsOneWidget);
        final right = _columnChildren(t, _right);
        expect(right.last, isA<AlertSettingsEntry>());
        expect(
          right.where(_isProtection),
          isEmpty,
          reason: 'a power bank grows no control card (0034 §6 rule 3)',
        );
        expect(
          find.descendant(of: _right, matching: find.byType(PowerPathRow)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: _right, matching: find.byType(ReadoutsCard)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: _left, matching: find.byType(TrendChartCard)),
          findsOneWidget,
        );
        await _pop(t);
        await t.runAsync(s.connection.disconnect);
        await settleHarness(t);
      });
    }

    for (final (os, text, two) in [
      (1.0, AppTextSize.small, true),
      (1.3, AppTextSize.large, false),
      (1.3, AppTextSize.small, false),
    ]) {
      testWidgets('1280×720 ${text.name} OS×$os ⇒ ${two ? 'two' : 'one'} '
          'column(s) (Q7)', (t) async {
        setWindow(t, Win.unit1280.size, os: os);
        collectOverflows();
        final s = await makeHarnessServices(t, size: text);
        await pumpShell(t, s);
        await linkWithTelemetry(t, s, units[0].$2, kTypeBattery);
        await _push(t, DeviceDetailPage(deviceId: units[0].$2));
        expect(find.byType(PackScaffold), findsOneWidget);
        expect(_two, two ? findsOneWidget : findsNothing);
        if (!two) {
          // Today's single 560 column.
          final lv = find.descendant(
            of: find.byType(PackScaffold),
            matching: find.byType(ListView),
          );
          expect(t.getSize(lv).width, lessThanOrEqualTo(560));
        }
        await _pop(t);
        await t.runAsync(s.connection.disconnect);
        await settleHarness(t);
      });
    }

    testWidgets('portrait 390×844: the device page stays one column', (
      t,
    ) async {
      setWindow(t, Win.portrait.size);
      collectOverflows();
      final s = await makeHarnessServices(t);
      await pumpShell(t, s);
      await linkWithTelemetry(t, s, units[0].$2, kTypeBattery);
      await _push(t, DeviceDetailPage(deviceId: units[0].$2));
      expect(find.byType(PackScaffold), findsOneWidget);
      expect(_two, findsNothing);
      expect(
        find
            .byType(LayoutBuilder)
            .evaluate()
            .where(
              (e) =>
                  e.widget.runtimeType == LayoutBuilder &&
                  e.findAncestorWidgetOfExactType<PackScaffold>() != null &&
                  e.findAncestorWidgetOfExactType<IndustrialCard>() == null &&
                  e.findAncestorWidgetOfExactType<TrendChartCard>() == null &&
                  e.findAncestorWidgetOfExactType<ReadoutsCard>() == null,
            ),
        isEmpty,
        reason: 'portrait never reaches the two-column builder',
      );
      await _pop(t);
      await t.runAsync(s.connection.disconnect);
      await settleHarness(t);
    });
  });

  group('4. no overflow a 360 dp portrait phone does not already have', () {
    for (final text in AppTextSize.values) {
      for (final os in [1.0, 1.3]) {
        for (final lang in [AppLang.zhHant, AppLang.en]) {
          testWidgets('${text.name} OS×$os ${lang.name}', (t) async {
            Future<List<SeenOverflow>> run(Size size) async {
              setWindow(t, size, os: os);
              final seen = collectOverflows();
              final s = await makeHarnessServices(t, size: text, lang: lang);
              await t.pumpWidget(const SizedBox());
              await pumpShell(t, s);
              for (final (_, id, type) in units) {
                await linkWithTelemetry(t, s, id, type);
                await _push(t, DeviceDetailPage(deviceId: id));
                await _pop(t);
                await t.runAsync(s.connection.disconnect);
                await settleHarness(t);
              }
              await t.runAsync(() => s.pending.drain());
              await t.pumpWidget(const SizedBox());
              await settleHarness(t);
              return [
                for (final o in seen)
                  if (!o.inBrandBar) o,
              ];
            }

            String key(SeenOverflow o) => o.texts.take(4).join('|');
            final base = await run(const Size(360, 800));
            final worse = <String>[];
            for (final win in Win.landscapes) {
              for (final o in await run(win.size)) {
                final b = base.where((x) => key(x) == key(o));
                final worst = b.isEmpty
                    ? null
                    : b.map((x) => x.px).reduce((a, c) => a > c ? a : c);
                if (worst == null || o.px > worst + 0.5) {
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
