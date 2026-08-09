// T-new-7 — `display_layout` has exactly ZERO writers in the UI.
//
// 🔴 TIGHTENED, not relaxed, by design 0051 (2026-08-09). Design 0046 R20 had
// moved the watchface picker from Settings onto the device's own page and left
// a signpost behind, and the risk this file was written for was a SECOND
// writer appearing. The owner's ruling 「同意拿掉入口」 removes the picker
// entirely, so the bound drops from one to none — the strongest form of the
// same statement, and the one that cannot regress quietly: any new
// `setDisplayLayout(` under `lib/ui/**` now fails this test outright.
//
// What the column is still FOR: it is skeleton (see `display_layout.dart`).
// `DeviceController.setDisplayLayout` and the repo path below it stay, tested,
// so restoring a picker is a UI change rather than a data-layer change. Nothing
// in the interface calls them.
//
// Two assertions, at two levels:
//   1. SOURCE — no file under `lib/ui/**` calls `setDisplayLayout(`.
//   2. RENDER — Settings offers neither a picker nor the old signpost row, and
//      the retired vocabulary is gone with them.
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

  test('NO ui file writes display_layout', () {
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
    expect(writers, isEmpty,
        reason: 'design 0051: the watchface picker is gone, so nothing in the '
            'interface writes this column. Found: $writers');
  });

  testWidgets('Settings offers neither a picker nor a signpost', (tester) async {
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
            body: const SettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pump();
    // The screen rendered — otherwise every absence below is vacuous.
    expect(find.text('Speed detection'), findsOneWidget);

    // No editor, and no row pointing at one either. The signpost went with the
    // picker: a row that said "the watchface moved" in one release and "there
    // is no watchface" in the next is worse than the silence.
    expect(find.byType(SegmentedControl<Watchface>), findsNothing);
    expect(find.text('Watchface'), findsNothing);
    expect(find.text('Standard'), findsNothing);
    expect(find.text('Diagnostic'), findsNothing);
    expect(find.text('Restore default display'), findsNothing);
    expect(s.devices.layoutFor('DEV-A'), DisplayLayout.defaults);
  });
}
