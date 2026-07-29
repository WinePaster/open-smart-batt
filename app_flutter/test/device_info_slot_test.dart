// The closed-side device-info panel slot (design 0003 injection seam).
//
// THE DEFECT THIS PINS DOWN. `bootstrap()` accepted a `deviceInfoPanelBuilder`
// and `OpenSmartBattApp` stored it in a field — and nothing ever read it. A
// closed build could inject a panel, see no error, and never see the panel
// either. The doc comment on `bootstrap` promised a capability that did not
// exist.
//
// The parser half of the seam WAS live (BleService/TelemetryDecoder take a
// MetadataParser); only the UI half was dead. So these tests assert the slot
// renders what it is given, and renders nothing when it is given nothing.
//
// The open build must stay identical to before the slot existed: the default is
// null, so the settings screen composes exactly as it did.
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
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService (mirrors dashboard_split_test.dart) so this runs headless.
class _FakeBleService extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(sqfliteFfiInit);

  Future<AppServices> makeServices(WidgetTester tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      services = await AppServices.create(
        appDatabase: appDb,
        ble: _FakeBleService(),
      );
    });
    return services;
  }

  Future<void> pumpSettings(
    WidgetTester tester,
    AppServices s, {
    WidgetBuilder? panel,
  }) async {
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
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: SettingsScreen(deviceInfoPanelBuilder: panel)),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('an injected panel is actually rendered', (tester) async {
    final s = await makeServices(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await s.dispose();
    });

    // The whole point: before this wiring, this expectation failed.
    await pumpSettings(tester, s, panel: (_) => const Text('CLOSED PANEL'));
    expect(find.text('CLOSED PANEL'), findsOneWidget);
  });

  testWidgets('the open build (null builder) renders no slot', (tester) async {
    final s = await makeServices(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await s.dispose();
    });

    await pumpSettings(tester, s);
    expect(find.text('CLOSED PANEL'), findsNothing);
  });

  testWidgets('the builder gets a context that resolves l10n and providers',
      (tester) async {
    final s = await makeServices(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await s.dispose();
    });

    // A closed panel will want localizations AND the controllers (it renders
    // per-device metadata). If the slot were built outside those scopes it
    // would throw here rather than at some closed user's runtime.
    String? locale;
    TelemetryController? tele;
    await pumpSettings(tester, s, panel: (context) {
      locale = AppLocalizations.of(context).navSettings;
      tele = context.read<TelemetryController>();
      return const SizedBox.shrink();
    });
    expect(locale, isNotNull);
    expect(tele, isNotNull);
  });

  testWidgets('the slot scrolls with the settings list', (tester) async {
    final s = await makeServices(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await s.dispose();
    });

    // Not a floating overlay: a tall closed panel must push the cards below it
    // down, not cover them.
    await pumpSettings(tester, s, panel: (_) => const Text('CLOSED PANEL'));
    expect(
      find.ancestor(
        of: find.text('CLOSED PANEL'),
        matching: find.byType(ListView),
      ),
      findsOneWidget,
    );
  });
}
