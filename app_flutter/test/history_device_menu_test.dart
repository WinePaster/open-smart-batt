// The History screen's device picker — GEOMETRY, at three widths.
//
// THE REPORT THIS PINS DOWN. 2026-08-20: tapping the device picker on the
// History tab 「跑版」. Measured, the menu came up at `32 .. screen width` on a
// 320 pt phone, a 360 pt phone and a 411 pt phone alike: 40 pt wider than the
// control that opened it, flush against the right edge of the screen, 15 pt
// outside the card it belongs to while inset 17 pt from that card on the left.
//
// It was not our arithmetic. `DropdownButton` inflates the button rect by
// `EdgeInsetsDirectional.only(start: 16, end: 24)` (`_kUnalignedMenuMargin`,
// `material/dropdown.dart`) before it positions the menu, then clamps the
// result onto the screen — and this card, at a 15 pt page margin, sits exactly
// where that inflation overruns. Nothing about the defect was conditional, so
// nothing about this test is either: the same assertions run at every width.
//
// WHAT IS ACTUALLY LOCKED DOWN here is the pair of properties the fix rests on
// — the menu starts where the row starts, and it is as wide as the row — not
// the pixel values themselves, which are free to move when the card's padding
// does. The containment assertions are the ones that would have caught the
// original report.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:open_smart_batt/ui/widgets/industrial_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// BleService stub: nothing here reaches the plugin channel.
class _StubBle extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;
  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
  @override
  String? get connectedDeviceId => null;

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  const cap = 'DEV-CAP';
  const bank = 'DEV-PB';

  // Long enough to ellipsise in the narrow case, which is where a menu that
  // sizes itself to its widest child would have grown out of the card.
  const capName = '車庫那台超級電容模組';
  const bankName = '行動電源';

  late AppServices services;

  Future<void> boot(WidgetTester tester) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      services = await AppServices.create(appDatabase: db, ble: _StubBle());
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(services.dispose);
    });
  }

  /// Two named units with history, [bankName] the more recently seen — so the
  /// screen opens on it and [capName] is the one waiting in the menu.
  Future<void> seed(WidgetTester tester) async {
    final now = DateTime.now();
    await tester.runAsync(() async {
      await services.devices.save(SavedDevice(
        id: cap,
        alias: capName,
        lastSeen: now.subtract(const Duration(days: 2)),
      ));
      await services.devices
          .save(SavedDevice(id: bank, alias: bankName, lastSeen: now));
      await services.historyRepo.insertSample(
        TelemetrySample(
            timestamp: now.subtract(const Duration(minutes: 5)), pvlt: 13.5),
        deviceId: cap,
      );
      await services.historyRepo.insertSample(
        TelemetrySample(
            timestamp: now.subtract(const Duration(minutes: 4)), pvlt: 3.9),
        deviceId: bank,
      );
    });
  }

  Future<void> pumpHistory(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppServices>.value(value: services),
          Provider<BleService>.value(value: services.ble),
          ChangeNotifierProvider<SettingsController>.value(
              value: services.settings),
          ChangeNotifierProvider<DeviceController>.value(
              value: services.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: services.connection),
          ChangeNotifierProvider<TelemetryController>.value(
              value: services.telemetry),
          ChangeNotifierProvider<GForceController>.value(
              value: services.gforce),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const Scaffold(body: HistoryScreen()),
        ),
      ),
    );
    // Two chained reads — the option list, then the data for whichever unit
    // that list caused to be selected. Both need the real event loop.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    await tester.pump();
  }

  /// The rect of a menu row, found through the label only that row carries.
  ///
  /// The nearest [SizedBox] above the label IS the row's width box, which is
  /// what the panel takes its width from — so this measures the menu, not just
  /// the text inside it.
  Rect menuRowRect(WidgetTester tester, String label) => tester.getRect(
        find
            .ancestor(of: find.text(label), matching: find.byType(SizedBox))
            .first,
      );

  // 320 is the narrowest phone we have ever had a report from; 411 is the
  // widest common Android. The defect was identical at all three, which is
  // the point — one width would have proved nothing about the other two.
  for (final width in <double>[320, 360, 411]) {
    group('${width.toInt()} pt', () {
      testWidgets('the open menu stays inside the card that opened it',
          (t) async {
        t.view.physicalSize = Size(width * 3, 800 * 3);
        t.view.devicePixelRatio = 3.0;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);

        await boot(t);
        await seed(t);
        await pumpHistory(t);

        final anchor = find.byType(MenuAnchor);
        expect(anchor, findsOneWidget);
        final Rect card = t.getRect(
          find.ancestor(of: anchor, matching: find.byType(IndustrialCard)).first,
        );
        final Rect row = t.getRect(anchor);

        await t.tap(anchor);
        await t.pumpAndSettle();

        final Rect menu = menuRowRect(t, capName);

        // The two properties the fix rests on.
        expect(menu.left, row.left,
            reason: 'the menu starts where the row that opened it starts');
        expect(menu.width, row.width,
            reason: 'and it is exactly as wide — never wider');

        // The report, negated. Each of these failed before the swap: the old
        // menu ran from 32 to the screen edge whatever the card did.
        expect(menu.left, greaterThanOrEqualTo(card.left));
        expect(menu.right, lessThanOrEqualTo(card.right));
        expect(menu.right, lessThan(width),
            reason: 'never flush against the edge of the screen');

        // And it drops BELOW the row rather than sitting on top of it, which
        // is the other half of what made the old one read as broken.
        expect(menu.top, greaterThanOrEqualTo(row.bottom));
      });

      testWidgets('a long name ellipsises instead of widening the menu',
          (t) async {
        t.view.physicalSize = Size(width * 3, 800 * 3);
        t.view.devicePixelRatio = 3.0;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);

        await boot(t);
        final now = DateTime.now();
        await t.runAsync(() async {
          await services.devices.save(SavedDevice(
            id: cap,
            alias: '這是一個長到不可能塞得下的裝置名稱用來確認選單不會被撐開',
            lastSeen: now.subtract(const Duration(days: 2)),
          ));
          await services.devices
              .save(SavedDevice(id: bank, alias: bankName, lastSeen: now));
          await services.historyRepo.insertSample(
            TelemetrySample(
                timestamp: now.subtract(const Duration(minutes: 5)),
                pvlt: 13.5),
            deviceId: cap,
          );
          await services.historyRepo.insertSample(
            TelemetrySample(
                timestamp: now.subtract(const Duration(minutes: 4)), pvlt: 3.9),
            deviceId: bank,
          );
        });
        await pumpHistory(t);

        final anchor = find.byType(MenuAnchor);
        final Rect row = t.getRect(anchor);
        await t.tap(anchor);
        await t.pumpAndSettle();

        expect(
          menuRowRect(t, '這是一個長到不可能塞得下的裝置名稱用來確認選單不會被撐開').width,
          row.width,
        );
        // No `expect` for the overflow itself: a row that overflowed would
        // have thrown a RenderFlex error, and the binding fails the test on a
        // caught exception whether or not anyone asserts on it.
      });

      testWidgets('picking the other unit rescopes the screen', (t) async {
        t.view.physicalSize = Size(width * 3, 800 * 3);
        t.view.devicePixelRatio = 3.0;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);

        await boot(t);
        await seed(t);
        await pumpHistory(t);

        // Closed, the bar shows the unit it opened on and nothing else.
        expect(find.text(bankName), findsOneWidget);
        expect(find.text(capName), findsNothing);

        await t.tap(find.byType(MenuAnchor));
        await t.pumpAndSettle();
        // Open: both units, and the current one marked.
        expect(find.text(capName), findsOneWidget);
        expect(find.byIcon(Icons.check), findsOneWidget);

        // NOT `pumpAndSettle`: re-scoping puts the screen into its loading
        // state, and the spinner there schedules frames forever.
        await t.tap(find.text(capName));
        await t.pump();
        await t.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await t.pump();
        await t.pump(const Duration(milliseconds: 400)); // menu closes

        // The menu closed and the bar now names the other unit.
        expect(find.text(bankName), findsNothing);
        expect(find.text(capName), findsOneWidget);
      });
    });
  }

  // Width-independent, so it runs once.
  testWidgets('a second tap on the row closes the menu', (t) async {
    // `consumeOutsideTap` is on, so the dismissing tap cannot fall through to
    // the chart card underneath. The risk that creates is the opposite one:
    // if the anchor counted as "outside", this tap would close the menu and
    // then the row's own onTap would reopen it, and the menu would look stuck
    // open. It does not — MenuAnchor keeps the anchor inside its tap region —
    // and this is the test that would notice if that ever changed.
    await boot(t);
    await seed(t);
    await pumpHistory(t);

    await t.tap(find.byType(MenuAnchor));
    await t.pumpAndSettle();
    expect(find.text(capName), findsOneWidget, reason: 'open');

    await t.tap(find.byType(MenuAnchor));
    await t.pumpAndSettle();
    expect(find.text(capName), findsNothing, reason: 'closed, and stayed shut');
    expect(find.text(bankName), findsOneWidget,
        reason: 'the bar still names the unit it was scoped to');
  });
}
