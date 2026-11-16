// 連線節奏（實驗）— owner ruling 2026-11-16: the connection-priority switch
// from the `test/conn-priority` side build goes into main, default 不要求.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState, ConnectionPriority;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/settings/conn_priority.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
  int applied = 0;
  @override
  Future<void> applyConnectionPriorityNow() async => applied++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  tearDown(() {
    BleService.connectionPriority = null;
    debugShowConnectionPriorityRow = null;
  });

  test('default is 不要求 (null), and the options start with it', () {
    expect(BleService.connectionPriority, isNull);
    expect(connectionPriorityOptions.first, isNull);
    expect(connectionPriorityOptions, contains(ConnectionPriority.lowPower));
  });

  Future<(AppServices, _FakeBle)> boot(WidgetTester tester) async {
    late AppServices s;
    final ble = _FakeBle();
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      s = await AppServices.create(appDatabase: db, ble: ble);
    });
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<AppServices>.value(value: s),
        Provider<BleService>.value(value: s.ble),
        Provider<LogRepo>.value(value: s.logRepo),
        ChangeNotifierProvider<SettingsController>.value(value: s.settings),
        ChangeNotifierProvider<DeviceController>.value(value: s.devices),
        ChangeNotifierProvider<ConnectionController>.value(
            value: s.connection),
        ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
        ChangeNotifierProvider<AlertController>.value(value: s.alerts),
        ChangeNotifierProvider<GForceController>.value(value: s.gforce),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(body: SettingsScreen()),
      ),
    ));
    await tester.pump();
    return (s, ble);
  }

  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(s.dispose);
  }

  testWidgets('the row is absent off Android', (tester) async {
    debugShowConnectionPriorityRow = false;
    final (s, _) = await boot(tester);
    expect(find.textContaining('Link pace'), findsNothing);
    await teardown(tester, s);
  });

  testWidgets('picking 低功耗 sets it, applies it now, and the row says so',
      (tester) async {
    debugShowConnectionPriorityRow = true;
    final (s, ble) = await boot(tester);
    final row = find.text("Link pace (experiment): Don't ask (default)");
    await tester.scrollUntilVisible(row, 200);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Low power (slower)'));
    await tester.pumpAndSettle();

    expect(BleService.connectionPriority, ConnectionPriority.lowPower);
    expect(ble.applied, 1, reason: 'the live link is asked at once');
    expect(find.text('Link pace (experiment): Low power (slower)'),
        findsOneWidget);
    expect(find.textContaining('restarting the app returns'), findsOneWidget);
    await teardown(tester, s);
  });
}
