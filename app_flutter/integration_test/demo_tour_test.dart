// design 0097 P5 — a tour of the demo mode on a simulator or phone.
//
// Runs the REAL app (real BleService — the demo link never touches the radio,
// so this works on a simulator with no Bluetooth) and walks the path an App
// Store reviewer takes: scan tab → demo entry → battery → dashboard → history
// → capacitor → end demo.
//
// At each stop it prints `SHOT <name>` and holds still for [_hold], so a
// screenshot taken from outside lands on a settled screen:
//
//   flutter test integration_test/demo_tour_test.dart -d <simulator> |
//     while read -r l; do echo "$l"; case "$l" in *"SHOT "*)
//       xcrun simctl io booted screenshot "${l##*SHOT }.png";; esac; done
//
// Store screenshots come from here (design 0097 Q5: the banner stays in).
// `--dart-define=OSB_TOUR_LANG=en` for the English set (a host environment
// variable does not reach an app running on a simulator).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/demo/demo.dart';
import 'package:open_smart_batt/main.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const Duration _hold = Duration(milliseconds: 2500);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  /// Let real time pass while frames keep being drawn.
  Future<void> wait(WidgetTester tester, Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await wait(tester, const Duration(milliseconds: 600));
    // ignore: avoid_print
    print('SHOT $name');
    await wait(tester, _hold);
  }

  Future<void> tapFirst(WidgetTester tester, Finder f) async {
    await tester.tap(f.first);
    await wait(tester, const Duration(milliseconds: 500));
  }

  testWidgets('demo tour', (tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('osb_tour_');
      final db = await AppDatabase.open(
          path: '${dir.path}/app.db', factory: databaseFactoryFfi);
      services = await AppServices.create(appDatabase: db, ble: BleService());
      await services.settings.setLang(
          const String.fromEnvironment('OSB_TOUR_LANG') == 'en'
              ? AppLang.en
              : AppLang.zhHant);
    });

    await tester.pumpWidget(OpenSmartBattApp(services: services));
    await wait(tester, const Duration(seconds: 2));
    // The first-launch disclaimer, if this install has not acknowledged it.
    final ack = find.byType(ElevatedButton);
    if (ack.evaluate().isNotEmpty) await tapFirst(tester, ack);
    await shot(tester, '01-home');

    await tapFirst(tester, find.byIcon(Icons.list_alt_outlined));
    await shot(tester, '02-scan-entry');

    await tapFirst(tester, find.byKey(const ValueKey('demo-entry')));
    await shot(tester, '03-picker');

    await tapFirst(
        tester, find.byKey(ValueKey('demo-pick-${DemoKind.battery.id}')));
    await wait(tester, const Duration(seconds: 4));
    await shot(tester, '04-battery-dashboard');

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await shot(tester, '05-battery-dashboard-lower');

    // The detail page's own back arrow (Material AppBar).
    await tester.tap(find.byType(BackButton).first);
    await wait(tester, const Duration(milliseconds: 600));
    await tapFirst(tester, find.byIcon(Icons.history_outlined));
    await wait(tester, const Duration(seconds: 2));
    await shot(tester, '06-history');

    await tapFirst(tester, find.byKey(const ValueKey('demo-end')));
    await tapFirst(tester, find.byIcon(Icons.list_alt_outlined));
    await tapFirst(tester, find.byKey(const ValueKey('demo-entry')));
    await tapFirst(
        tester, find.byKey(ValueKey('demo-pick-${DemoKind.capacitor.id}')));
    await wait(tester, const Duration(seconds: 4));
    await shot(tester, '07-capacitor-dashboard');

    await tapFirst(tester, find.byKey(const ValueKey('demo-end')));
    await shot(tester, '08-ended');
    expect(find.byKey(const ValueKey('demo-banner')), findsNothing);
  });
}
