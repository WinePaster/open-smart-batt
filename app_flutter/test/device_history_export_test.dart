// T65-7 … T65-10 — where an export started on a device's detail page goes.
//
// 🔴 THIS IS THE ONE PART OF DESIGN 0065 THAT CAN PRODUCE WRONG DATA. Every
// other way the feature can fail is visible: a block in the wrong place, a
// chart that will not draw, an empty state that reads badly. This one produces
// a FILE — correct-looking, correctly named, and about the wrong unit — which
// the person who made it then sends to somebody else. The owner ruled on it in
// six words: 「只能是該詳情的那個裝置，不管是不是連線他。」
//
// The four tests are one enclosure and every side of it is load-bearing:
//
//   T65-7   connected to another unit  → still this page's unit
//   T65-8   connected to nothing       → still this page's unit, NOT everything
//   T65-9   the user cannot walk around it in the sheet
//   T65-10  and the two existing surfaces are untouched
//
// Drop any one and the enclosure has a gap. T65-9 is the least obvious and the
// easiest to lose: adding the `deviceId` override without touching the sheet
// leaves an "All devices" row rendered unconditionally, one tap away.
//
// CLEAN-ROOM: expectations derive from this project's own source and captures.
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
import 'package:open_smart_batt/ui/util/export_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _StubBle extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  String? connected;

  @override
  String? get connectedDeviceId => connected;

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

  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);
  void emitLink(BleLinkState s) => _linkOut.add(s);

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

  // The page's unit and the unit on the link. Distinct serials and distinct
  // classes, because those are the two things that reach the FILENAME.
  const pageUnit = 'DEV-PAGE';
  const linkUnit = 'DEV-LINK';

  late AppServices services;
  late _StubBle ble;

  Future<void> boot(WidgetTester tester) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _StubBle();
      services = await AppServices.create(appDatabase: db, ble: ble);
      // Both saved, with the identity fragments an export would print.
      await services.devices.saveNew(pageUnit, 'Front capacitor',
          productClass: ProductClass.supercapacitor);
      await services.devices.saveNew(linkUnit, 'Rear battery',
          productClass: ProductClass.smartBattery);
      await services.devices.setIdentity(pageUnit, serial: 'PAGE1234');
      await services.devices.setIdentity(linkUnit, serial: 'LINK9999');
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(services.dispose);
    });
  }

  Future<void> connectTo(WidgetTester tester, String id) async {
    ble.connected = id;
    await tester.runAsync(() async {
      ble.emitLink(BleLinkState.ready);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
  }

  /// Pump a button that calls [chooseExportScope] the way the detail page's
  /// block does, and hand back whatever the sheet resolved to.
  ///
  /// Driving `chooseExportScope` directly — rather than tapping the real chip —
  /// is deliberate: the thing under test is WHICH UNIT the returned target
  /// names, and routing that through a share sheet would need a platform
  /// channel to answer a question the target already answers.
  Future<ExportTarget?> openSheetAndTapThisDevice(
    WidgetTester tester, {
    required String? deviceId,
    bool tapAllDevices = false,
  }) async {
    ExportTarget? result;
    var opened = false;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppServices>.value(value: services),
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
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () async {
                    opened = true;
                    result = await chooseExportScope(
                      context,
                      offerSession: false,
                      offerGranularity: true,
                      since: DateTime(2026, 8, 16),
                      deviceId: deviceId,
                    );
                  },
                  child: const Text('export'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('export'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    if (tapAllDevices) {
      await tester.tap(find.text(l10n.exportScopeAllDevices));
    } else {
      await tester.tap(find.textContaining(RegExp(r'^This device')));
    }
    await tester.pumpAndSettle();
    return result;
  }

  // ==========================================================================
  group('🔴 the detail page exports the unit whose page it is', () {
    testWidgets(
        'T65-7 — connected to another unit, the file is still THIS unit',
        (tester) async {
      // CATCHES: the `deviceId` override being ignored or dropped, and
      // separately `_targetFor`'s `isLive` being hard-wired to true. The first
      // exports the wrong ROWS; the second exports the right rows under the
      // wrong NAME — the connected unit's class and serial stamped onto this
      // unit's filename, which `deviceClassFor`'s own doc calls "FB-41 with a
      // different column". Both files look perfectly ordinary to whoever
      // receives them.
      await boot(tester);
      await connectTo(tester, linkUnit);
      expect(services.telemetry.recordingDeviceId, linkUnit,
          reason: 'the premise: the LINK holds the other unit');

      final target =
          await openSheetAndTapThisDevice(tester, deviceId: pageUnit);

      expect(target, isNotNull);
      expect(target!.scope, ExportScope.currentDevice);
      expect(target.deviceId, pageUnit, reason: 'the rows');
      expect(target.ident, 'PAGE1234', reason: 'the filename identity');
      expect(target.classSlug, 'capacitor', reason: 'the filename class');
      // …and no fragment of the connected unit reached any of it.
      expect(target.ident, isNot(contains('LINK')));
      expect(target.classSlug, isNot('battery'));
    });

    testWidgets(
        '🔴 T65-7b — an UNSAVED page unit inherits NOTHING from the link',
        (tester) async {
      // 🔴 The version of T65-7 that actually catches a wrong `isLive`.
      //
      // With both units saved, the stored serial and stored class win over the
      // live ones, so hard-wiring `isLive: true` is INVISIBLE — the ladder in
      // `exportDeviceIdent` / `deviceClassFor` masks it. The case where it
      // shows is the one design 0055 made ordinary: connect, look, export,
      // never name it. Then the live rung is the only rung, and a wrong
      // `isLive` writes the CONNECTED unit's serial and class into THIS unit's
      // filename — which is `deviceClassFor`'s "FB-41 with a different column",
      // in the one place the recipient of the file would read it.
      await boot(tester);
      const unsaved = 'DEV-UNSAVED';
      expect(services.devices.deviceFor(unsaved), isNull);

      await connectTo(tester, linkUnit);
      // Give the LINK a live identity to leak: a serial off the wire and a
      // device-type byte the resolver turns into a class.
      await tester.runAsync(() async {
        ble.emitTelemetry(TelemetrySample(
          timestamp: DateTime.now(),
          deviceType: 0x02,
          serial: 'LIVE5678',
          dealerCode: '12',
          pvlt: 12.6,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();

      final target = await openSheetAndTapThisDevice(tester, deviceId: unsaved);

      expect(target!.deviceId, unsaved);
      expect(target.ident, isNot(contains('LIVE')),
          reason: "the link's serial must not name this unit's file");
      expect(target.ident, isNot(contains('LINK')));
      expect(target.classSlug, 'unknown',
          reason: 'nothing knows what this unit is, and the unit on the link '
              'cannot answer for it — an honest `unknown` beats a confident '
              'wrong class');
    });

    testWidgets(
        '🔴 T65-8 — OFFLINE it is still this unit, never "all devices"',
        (tester) async {
      // CATCHES: the override falling through to `export_scope.dart`'s offline
      // branch, which returns an all-devices target. This is not a corner case
      // and that is the point: design 0065 Q4 puts the export button on a block
      // that is shown OFFLINE on purpose, because offline is when a dealer
      // wants a unit's records — the car is elsewhere, the battery is out. So
      // the "whole database instead of one unit" path would be the DEFAULT one
      // for the feature's main use, not a rare miss.
      await boot(tester);
      expect(services.telemetry.recordingDeviceId, isNull,
          reason: 'the premise: nothing is connected');

      final target =
          await openSheetAndTapThisDevice(tester, deviceId: pageUnit);

      expect(target, isNotNull);
      expect(target!.scope, ExportScope.currentDevice,
          reason: 'NOT ExportScope.allDevices');
      expect(target.deviceId, pageUnit);
      // The identity survives with no link at all: the saved record and design
      // 0057's cache are the rungs above the live one, which is the whole of
      // FB-68's fix and the reason an offline export is still identifiable.
      expect(target.ident, 'PAGE1234');
      expect(target.classSlug, 'capacitor');
    });

    testWidgets(
        '🔴 T65-9 — and the sheet gives the user no way around it',
        (tester) async {
      // CATCHES: adding the `deviceId` override and stopping there. The
      // all-devices row is rendered UNCONDITIONALLY in the sheet, so a pinned
      // export would still be one tap away from the whole database — the
      // ruling broken by the user rather than by the code, which is not a
      // distinction the resulting file records.
      await boot(tester);
      await connectTo(tester, linkUnit);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      // Open the sheet the pinned way and look at what it offers.
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<AppServices>.value(value: services),
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
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => chooseExportScope(
                      context,
                      offerSession: false,
                      offerGranularity: true,
                      deviceId: pageUnit,
                    ),
                    child: const Text('export'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('export'));
      await tester.pumpAndSettle();

      expect(find.text(l10n.exportScopeAllDevices), findsNothing,
          reason: 'a pinned export must not offer an unpinned option');
      // The sheet still earns its existence: the granularity choice is a 60×
      // difference in file size (design 0061 T4c), and it is still offered.
      expect(find.text(l10n.exportResolutionMinute), findsOneWidget);
      expect(find.text(l10n.exportResolutionSecond), findsOneWidget);
      // …and this unit is nameable in it.
      expect(find.textContaining('Front capacitor'), findsOneWidget);
    });
  });

  // ==========================================================================
  group('T65-10 — the two existing surfaces are untouched', () {
    testWidgets('with no override, the scope is still the connected unit',
        (tester) async {
      // CATCHES: the override being implemented as "always use some id", which
      // would quietly redefine what the History tab and Settings export. The
      // ruling adds a path; it changes no existing one — neither of those
      // screens has a concept of "the unit you are looking at", so keying off
      // the connected unit is the right default there and stays.
      await boot(tester);
      await connectTo(tester, linkUnit);

      final target = await openSheetAndTapThisDevice(tester, deviceId: null);

      expect(target!.deviceId, linkUnit,
          reason: 'unchanged: the connected unit');
      expect(target.ident, 'LINK9999');
      expect(target.classSlug, 'battery');
    });

    testWidgets('and with no override the all-devices row is still offered',
        (tester) async {
      await boot(tester);
      await connectTo(tester, linkUnit);

      final target = await openSheetAndTapThisDevice(tester,
          deviceId: null, tapAllDevices: true);

      expect(target!.scope, ExportScope.allDevices,
          reason: 'the History tab is the only entrance to a whole-database '
              'export, and design 0065 §3.6.1 keeps it that way on purpose');
    });

    testWidgets('offline with no override still falls back to all devices',
        (tester) async {
      // The control for T65-8: the fallback it forbids for a pinned export is
      // still exactly what an UNPINNED offline export does, so T65-8 is
      // pinning the override and not some incidental change of behaviour.
      await boot(tester);
      final target = await openSheetAndTapThisDevice(tester,
          deviceId: null, tapAllDevices: true);
      expect(target!.scope, ExportScope.allDevices);
      expect(target.deviceId, isNull);
    });
  });
}
