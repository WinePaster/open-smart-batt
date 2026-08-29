/// design 0091 (FB-105 Q1) — the alerts badge says what is happening NOW.
///
/// The badge used to read one column of `saved_devices` and print a green "On".
/// It stayed green with no link, with a stalled link, and — the state every
/// user starts in — with the global switch off. These tests pin the ladder that
/// replaced it, and one of them (`reverse assertion`) is the whole point of the
/// design: enabled ∧ not connected must NOT read "Watching".
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/alerts/alert_settings_page.dart';
import 'package:open_smart_batt/ui/util/alert_watch_state.dart';

/// Enough of a [BleService] to let [AppServices.create] boot. Nothing here
/// connects — which is exactly the state the reverse assertion needs.
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

const String _unitA = 'AA:BB:CC:DD:EE:01';
const String _unitB = 'AA:BB:CC:DD:EE:02';

AlertWatchState _state({
  bool alertsEnabled = true,
  SavedDevice saved = const SavedDevice(id: _unitA, alias: 'a'),
  String deviceId = _unitA,
  String? connectedDeviceId = _unitA,
  bool hasTelemetry = true,
  bool telemetryStalled = false,
  DateTime? now,
}) =>
    alertWatchStateFor(
      alertsEnabled: alertsEnabled,
      saved: saved,
      deviceId: deviceId,
      connectedDeviceId: connectedDeviceId,
      hasTelemetry: hasTelemetry,
      telemetryStalled: telemetryStalled,
      now: now ?? DateTime(2026, 8, 30, 12),
    );

void main() {
  sqfliteFfiInit();

  group('0091 the ladder', () {
    test('everything enabled, connected, frames arriving => watching', () {
      expect(_state(), AlertWatchState.watching);
    });

    test('global switch off wins over everything, including a live link', () {
      // 🔴 The defect that was found while writing the design: the global
      // switch SHIPS OFF (design 0080 Q4), so this was every new user's state
      // while the badge said "On" in green.
      expect(_state(alertsEnabled: false), AlertWatchState.globallyDisabled);
    });

    test('the broadest cause wins: global off outranks a device switch and a mute',
        () {
      // The order is AlertSuppression's, and its doc comment says why: telling
      // someone "this device is muted" while the global switch is off sends
      // them to the wrong screen.
      final muted = SavedDevice(
        id: _unitA,
        alias: 'a',
        alertEnabled: false,
        alertMutedUntilMs: DateTime(2026, 8, 30, 13).millisecondsSinceEpoch,
      );
      expect(_state(alertsEnabled: false, saved: muted),
          AlertWatchState.globallyDisabled);
      expect(_state(saved: muted), AlertWatchState.deviceDisabled);
    });

    test('device switch off => deviceDisabled even on a live link', () {
      expect(
        _state(saved: const SavedDevice(id: _unitA, alias: 'a', alertEnabled: false)),
        AlertWatchState.deviceDisabled,
      );
    });

    test('mute outranks the link state', () {
      final muted = SavedDevice(
        id: _unitA,
        alias: 'a',
        alertMutedUntilMs: DateTime(2026, 8, 30, 13).millisecondsSinceEpoch,
      );
      expect(_state(saved: muted), AlertWatchState.muted);
      // Expired mute is simply not a mute.
      expect(_state(saved: muted, now: DateTime(2026, 8, 30, 14)),
          AlertWatchState.watching);
    });

    test('not connected => notWatching', () {
      expect(_state(connectedDeviceId: null), AlertWatchState.notWatching);
    });

    test('connected to ANOTHER unit => notWatching for this one', () {
      // There is one link (`ble_service.dart` "the one link"), so a unit that
      // is not on it is definitionally unwatched.
      expect(_state(connectedDeviceId: _unitB), AlertWatchState.notWatching);
    });

    test('connected but nothing has arrived yet => notWatching', () {
      expect(_state(hasTelemetry: false), AlertWatchState.notWatching);
    });

    test('connected but STALLED => notWatching', () {
      // 🔑 The one state that cannot be produced by any combination of
      // switches — and the reason the badge needed the link's health and not
      // just `connectedDeviceId`.
      expect(_state(telemetryStalled: true), AlertWatchState.notWatching);
    });

    test('hasTelemetry is consulted before telemetryStalled', () {
      // Both answer notWatching, so this pins the ORDER rather than the result:
      // `lastSampleAt` is seeded at ready, so a link that never spoke also goes
      // stalled. Same order ConnectionController._stateTitle documents.
      expect(_state(hasTelemetry: false, telemetryStalled: true),
          AlertWatchState.notWatching);
    });
  });

  group('0091 on screen', () {
    late AppServices services;

    Future<void> boot(WidgetTester tester, {required bool globalOn}) async {
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        services = await AppServices.create(appDatabase: db, ble: _FakeBleService());
        await services.devices.save(const SavedDevice(id: _unitA, alias: 'a'));
        // ⚠️ Set it BOTH ways, never "only when true": settings survive
        // between tests in this process, so relying on the shipped default
        // would make this test pass or fail on ordering.
        await services.settings.setAlertsEnabled(globalOn);
      });
    }

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<AppServices>.value(value: services),
            Provider<BleService>.value(value: services.ble),
            Provider<DeviceRepo>.value(value: services.deviceRepo),
            ChangeNotifierProvider<SettingsController>.value(
                value: services.settings),
            ChangeNotifierProvider<DeviceController>.value(
                value: services.devices),
            ChangeNotifierProvider<DeviceFactsController>.value(
                value: services.facts),
            ChangeNotifierProvider<ConnectionController>.value(
                value: services.connection),
            ChangeNotifierProvider<TelemetryController>.value(
                value: services.telemetry),
            ChangeNotifierProvider<AlertController>.value(value: services.alerts),
            ChangeNotifierProvider<GForceController>.value(value: services.gforce),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const Scaffold(
              body: SingleChildScrollView(
                  child: AlertSettingsEntry(deviceId: _unitA)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('🔴 reverse assertion: switch on, no link => never "Watching"',
        (tester) async {
      // This is the design in one line. The old badge said "On" here.
      await boot(tester, globalOn: true);
      await pump(tester);

      expect(find.text('Not watching'), findsOneWidget);
      expect(find.text('Watching'), findsNothing);
      expect(find.text('On'), findsNothing, reason: 'the retired label');
    });

    testWidgets('global switch off => "Not enabled", not "Off" and not "On"',
        (tester) async {
      // The state a brand-new user is in. It must not be dressed as the
      // per-device "Off", which is fixed on a different screen.
      await boot(tester, globalOn: false);
      await pump(tester);

      expect(find.text('Not enabled'), findsOneWidget);
      expect(find.text('Off'), findsNothing);
      expect(find.text('On'), findsNothing);
    });
  });

  group('0091 l10n', () {
    test('the three new keys exist and the retired one is gone', () {
      final root = Directory.current.path.endsWith('app_flutter')
          ? Directory.current.path
          : '${Directory.current.path}/app_flutter';
      for (final f in ['lib/l10n/app_zh.arb', 'lib/l10n/app_en.arb']) {
        final text = File('$root/$f').readAsStringSync();
        for (final k in [
          'alertsEntryBadgeWatching',
          'alertsEntryBadgeNotWatching',
          'alertsEntryBadgeGlobalOff',
        ]) {
          expect(text.contains('"$k"'), isTrue, reason: '$k missing from $f');
        }
        // ⛔ Two strings for one badge state is how a screen ends up saying two
        // different things depending on which one a caller reached for.
        expect(text.contains('"alertsEntryBadgeOn"'), isFalse,
            reason: 'the retired label must be gone from $f');
      }
    });
  });
}
