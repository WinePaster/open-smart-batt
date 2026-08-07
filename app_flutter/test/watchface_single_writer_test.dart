// T-new-7 — `display_layout` has exactly ONE writer in the UI.
//
// Design 0046 R20 moved the watchface picker from Settings onto the device's own
// page, and kept a row in Settings pointing at it. The failure mode that makes
// this worth a test is not the move; it is the temptation to leave the old
// control working "so nobody is stranded". Two screens writing one column is the
// double-knob problem R18 had just finished removing from the multi-device
// switch — and here the second knob would be the OLD one, the one people
// already know, which makes it worse rather than better.
//
// Three assertions, deliberately at three different levels:
//   1. SOURCE — only one file under `lib/ui/**` calls `setDisplayLayout(`.
//      A source scan is the only form that catches a THIRD writer being added
//      somewhere neither of the widget tests below happens to look.
//   2. RENDER — Settings shows no `SegmentedControl<Watchface>`.
//   3. NAVIGATION — the Settings row is still there and is still a link, so the
//      path that shipped in v0.6.17 leads somewhere instead of nowhere.
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
import 'dart:io';

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
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:open_smart_batt/ui/widgets/industrial.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBleService extends BleService {
  @override
  String? get connectedDeviceId => 'DEV-A';

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('exactly one UI file writes display_layout', () {
    final dir = Directory('lib/ui');
    expect(dir.existsSync(), isTrue,
        reason: 'lib/ui is the input to this test; if it moved, point this at '
            'the new path rather than deleting the test');
    final writers = <String>[
      for (final f in dir.listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') &&
            f.readAsStringSync().contains('setDisplayLayout('))
          f.path,
    ];
    expect(writers, hasLength(1),
        reason: 'design 0046 T-new-7: the watchface has ONE editor. Found: '
            '$writers');
    expect(writers.single, endsWith('watchface_sheet.dart'));
  });

  testWidgets('Settings has no picker, only a link', (tester) async {
    late final AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      s = await AppServices.create(appDatabase: db, ble: _FakeBleService());
      await s.devices.saveNew('DEV-A', 'unit A');
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => s.pending.drain());
      await s.dispose();
    });

    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var opened = 0;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppServices>.value(value: s),
          Provider<BleService>.value(value: s.ble),
          Provider<HistoryRepo>.value(value: s.historyRepo),
          Provider<DeviceRepo>.value(value: s.deviceRepo),
          Provider<SettingsRepo>.value(value: s.settingsRepo),
          Provider<LogRepo>.value(value: s.logRepo),
          ChangeNotifierProvider<SettingsController>.value(value: s.settings),
          ChangeNotifierProvider<DeviceController>.value(value: s.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: s.connection),
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
          ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: SettingsScreen(onOpenDevices: () => opened++),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Watchface'), 60,
        scrollable: find.byType(Scrollable).first);
    await tester.pump();

    // 2 — no second editor.
    expect(find.byType(SegmentedControl<Watchface>), findsNothing);
    expect(find.text('Standard'), findsNothing);
    expect(find.text('Diagnostic'), findsNothing);
    expect(find.text('Restore default display'), findsNothing);

    // 3 — the shipped path still leads somewhere.
    expect(find.text('Watchface'), findsOneWidget);
    await tester.tap(find.text('Watchface'));
    await tester.pump();
    expect(opened, 1,
        reason: 'v0.6.17 shipped "設定 → 錶盤"; a user who learned that path '
            'must find out where it went, not find nothing');
    expect(s.devices.layoutFor('DEV-A'), DisplayLayout.defaults,
        reason: 'and the signpost writes nothing of its own');
  });
}
