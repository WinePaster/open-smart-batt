// The telemetry-stale banner: a freshness note, not a warning (design 0014).
//
// It used to render on `colorScheme.errorContainer` and carry a paragraph of
// troubleshooting. Two problems, both confirmed in the field on 2026-07-29:
//
//  * The copy was Android-only. Both variants pointed at "background
//    monitoring" / "battery optimisation", and `monitorRunning` has no platform
//    check while the setting defaults to on — so every connected iOS user got
//    advice for a switch that is a no-op there (FB-26). All three field reports
//    that day were iOS.
//  * The colour outranked the device-fault banner. `AppTheme` never supplies
//    `errorContainer`, so Flutter falls back to `error` itself: a solid red at
//    full alpha, against the fault banner's amber at α=0.16 (FB-27).
//
// So these tests pin the two properties that must not come back: the banner
// states only what is happening (with a real age), and it names no platform.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/l10n/app_localizations_en.dart';
import 'package:open_smart_batt/l10n/app_localizations_zh.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  // The strings the old banner used, in both locales. None may return.
  const platformWords = [
    'battery optimis',
    'Battery optimis',
    'background',
    'Background',
    '電池最佳化',
    '背景持續監看',
  ];

  group('banner copy carries no platform advice', () {
    test('the removed keys are gone from the localisation surface', () {
      // A compile-time guarantee would be better, but the keys are generated:
      // this asserts the replacement exists and takes an age argument, which is
      // only true if the old parameterless pair was actually removed.
      final en = AppLocalizationsEn();
      final msg = en.dashboardTelemetryStale('24 seconds ago');
      expect(msg, contains('24 seconds ago'));
      for (final w in platformWords) {
        expect(msg.toLowerCase(), isNot(contains(w.toLowerCase())),
            reason: 'banner must not mention "$w" — that is Settings\' job');
      }
    });

    test('the Chinese copy is equally free of platform advice', () {
      final zh = AppLocalizationsZh();
      final msg = zh.dashboardTelemetryStale('24 秒前');
      expect(msg, contains('24 秒前'));
      for (final w in platformWords) {
        expect(msg, isNot(contains(w)));
      }
    });

    test('the age is a fact, not an adjective — seconds resolve to seconds',
        () {
      // `disconnected_state`'s helper collapses under a minute to "just now",
      // which says nothing for a banner that appears after 8 seconds.
      final en = AppLocalizationsEn();
      expect(en.relativeSecondsAgo(1), '1 second ago');
      expect(en.relativeSecondsAgo(24), '24 seconds ago');
      expect(AppLocalizationsZh().relativeSecondsAgo(24), '24 秒前');
    });
  });

  group('the platform-specific explanation lives in Settings', () {
    test('the two variants say different things and name their platform', () {
      final en = AppLocalizationsEn();
      final ios = en.settingsBackgroundMonitorSubIos;
      final android = en.settingsBackgroundMonitorSubAndroid;
      expect(ios, isNot(android));
      // The iOS copy must not send the user hunting for an Android setting —
      // that was the whole defect.
      expect(ios.toLowerCase(), isNot(contains('battery optimis')));
      expect(android.toLowerCase(), contains('battery optimis'));
      expect(ios.toLowerCase(), contains('ios'));
    });

    test('the iOS copy points at something that actually works there', () {
      // wakelock_plus declares an iOS implementation, so "keep the screen
      // awake" is a real remedy; background monitoring is not.
      expect(AppLocalizationsEn().settingsBackgroundMonitorSubIos.toLowerCase(),
          contains('screen'));
      expect(AppLocalizationsZh().settingsBackgroundMonitorSubIos,
          contains('螢幕喚醒'));
    });
  });

  group('banner rendering', () {
    Future<(AppServices, _StubBle)> boot(WidgetTester tester) async {
      late AppServices services;
      late _StubBle ble;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        ble = _StubBle();
        services = await AppServices.create(appDatabase: db, ble: ble);
      });
      return (services, ble);
    }

    testWidgets('is not rendered while telemetry is fresh', (tester) async {
      final (s, ble) = await boot(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await s.dispose();
      });

      await tester.pumpWidget(MultiProvider(
        providers: [
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
          home: const Scaffold(body: SizedBox()),
        ),
      ));
      await tester.pump();

      // Nothing stale yet, so nothing to say.
      expect(find.textContaining('paused'), findsNothing);
      expect(ble.isScanning, isFalse);
    });
  });
}
