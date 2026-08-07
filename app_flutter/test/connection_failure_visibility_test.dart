// T-new-6b — FB-53's asset, on the screen that inherited it.
//
// `give_up_visibility_test.dart` derives every `lastError` the controller can
// produce FROM THE CONTROLLER'S OWN SOURCE and fails if any of them lands
// nowhere on the dashboard's disconnected state. Design 0046 gives a SECOND
// screen the same job — [DeviceDetailPage] is where the list's one-word badge
// leads — so the same guarantee has to hold there, and by the same means.
//
// 🔴 WHY THE SOURCE SCAN IS COPIED RATHER THAN A LIST OF CODES.
// A hand-written list is the thing that failed. `_gaveUpCodes` WAS a
// hand-written list of what the controller produces, it was written correct, and
// it went stale the moment somebody added a code — which is how `bluetooth_off`
// spent a release setting `lastError` to a value no screen had a branch for. A
// second hand-written list here would go stale the same way and would then agree
// with the first, which is worse than not testing it.
//
// ⚠️ This file does NOT replace `give_up_visibility_test.dart` and must not be
// used as an excuse to weaken it (design 0046 plan §4.3 R-2): that file covers
// the dashboard's own empty state, which design 0046 leaves in place.
//
// CLEAN-ROOM: expectations derive from this project's own source and field
// captures.
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
import 'package:open_smart_batt/ui/devices/device_detail_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'give_up_visibility_test.dart' show controllerErrorCodes;

/// No radio, and it claims to be holding DEV-A so the page's per-device gate
/// (`connectedDeviceId == deviceId`) is satisfied.
class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  @override
  String? get connectedDeviceId => 'DEV-A';

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

/// A controller whose `lastError` / stall latch a test can simply state — the
/// same device `give_up_visibility_test.dart` uses, for the same reason.
class _ErrorConn extends ConnectionController {
  _ErrorConn(super.ble, {required super.settings});

  String? error;
  bool stalledLatch = false;

  @override
  String? get lastError => error;

  @override
  bool get isSetupStalled => stalledLatch;

  void setError(String? e) {
    error = e;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late _FakeBle ble;
  late AppServices services;
  late _ErrorConn conn;

  Future<void> boot(WidgetTester tester) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _FakeBle();
      services = await AppServices.create(appDatabase: db, ble: ble);
      await services.devices.saveNew('DEV-A', 'Cap #1', name: 'RCE-SCAP_II');
    });
    conn = _ErrorConn(ble, settings: services.settings);
    addTearDown(() {
      conn.dispose();
      return tester.runAsync(services.dispose);
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(
              value: services.settings),
          ChangeNotifierProvider<DeviceController>.value(
              value: services.devices),
          ChangeNotifierProvider<ConnectionController>.value(value: conn),
          ChangeNotifierProvider<TelemetryController>.value(
              value: services.telemetry),
          // The page reports its own visibility to the GNSS gate (design 0046
          // Step 8c), so the controller has to be reachable from it.
          ChangeNotifierProvider<GpsSpeedController>.value(
              value: services.speed),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const DeviceDetailPage(deviceId: 'DEV-A'),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('every code the controller sets is on the detail page too',
      (tester) async {
    await boot(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    final codes = controllerErrorCodes();
    // The scan is only as good as its ability to find anything at all.
    expect(codes, containsAll(<String>{
      'reconnect_exhausted',
      'autoconnect_timeout',
      'gatt_setup_stalled',
      'permission_denied',
      'bluetooth_off',
      'bluetooth_unauthorized',
      'device_stale',
      'device_unreachable',
      'connect_failed',
    }));

    // The floor: the idle copy is what the page shows before anything has been
    // attempted, so a code still on it is a code that reported nothing.
    conn.setError(null);
    await tester.pump();
    expect(find.text(l10n.disconnectedTitle), findsOneWidget);

    for (final code in codes) {
      conn.setError(code);
      await tester.pump();
      expect(find.text(l10n.disconnectedTitle), findsNothing,
          reason: '`$code` reaches `lastError` and falls through every branch, '
              'so the page reports the failure with the same words it showed '
              'before the attempt — FB-53, again, one screen along');
      // …and it says something, rather than merely not saying the wrong thing:
      // the advice card is the part carrying the way out.
      expect(find.text(l10n.disconnectedStalledRetry), findsOneWidget,
          reason: '`$code` renders no advice card, so there is nothing to act '
              'on');
    }
  });

  testWidgets('and the three refusals carry their own instruction',
      (tester) async {
    // The remedy is the phone, not the device. The standing hint is three
    // instructions that cannot work with the radio down, and its last one sends
    // the user to a scan that fails for the same reason.
    await boot(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    const expected = <String, String>{
      'bluetooth_off': 'Bluetooth is off — turn it on and try again',
      'bluetooth_unauthorized':
          'This app is not allowed to use Bluetooth. Enable it in Settings',
      'permission_denied':
          'Bluetooth permission is missing. Grant it in Settings',
    };
    for (final entry in expected.entries) {
      conn.setError(entry.key);
      await tester.pump();
      expect(find.text(entry.value), findsOneWidget,
          reason: 'the remedy is the phone, and it has to be named');
      expect(find.text(l10n.disconnectedGaveUpHint), findsNothing);
      expect(find.text(l10n.disconnectedGaveUpRadioHint), findsOneWidget);
      expect(find.text(l10n.disconnectedGaveUpBody), findsNothing,
          reason: '"several attempts went by" is false — nothing was '
              'attempted, the connect was refused before it began');
    }
  });

  testWidgets('a device-side give-up keeps the device-side hint',
      (tester) async {
    await boot(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    for (final code in [
      'device_unreachable',
      'device_stale',
      'connect_failed',
      'reconnect_exhausted',
      'autoconnect_timeout',
    ]) {
      conn.setError(code);
      await tester.pump();
      expect(find.text(l10n.disconnectedGaveUpHint), findsOneWidget,
          reason: '`$code` is about the device, not the radio');
    }
  });

  testWidgets('another unit\'s failure is not shown under this one\'s name',
      (tester) async {
    // Design 0046 §6 R-3. `lastError` is one slot belonging to whichever unit
    // the controller last worked on, and this page is reached by tapping ANY
    // row. Attributing that slot to the row the user merely opened would put
    // one device's failure under another's name — the FB-41/FB-42 shape, in the
    // UI rather than in the history table.
    await boot(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    conn.setError('device_unreachable');
    await tester.pump();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(
              value: services.settings),
          ChangeNotifierProvider<DeviceController>.value(
              value: services.devices),
          ChangeNotifierProvider<ConnectionController>.value(value: conn),
          ChangeNotifierProvider<TelemetryController>.value(
              value: services.telemetry),
          // The page reports its own visibility to the GNSS gate (design 0046
          // Step 8c), so the controller has to be reachable from it.
          ChangeNotifierProvider<GpsSpeedController>.value(
              value: services.speed),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          // A DIFFERENT unit — the controller is still holding DEV-A's failure.
          home: const DeviceDetailPage(deviceId: 'DEV-B'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text(l10n.disconnectedTitle), findsOneWidget,
        reason: 'DEV-B has attempted nothing, so it reports nothing');
    expect(find.text(l10n.devicesConnectFailedUnreachable), findsNothing);
  });
}
