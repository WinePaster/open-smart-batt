// Design 0080 P2 — the per-device alert settings: model round trips, the one
// threshold lookup, and the four screen states.
//
// WHAT THIS FILE IS PROTECTING, stated once because every group below is an
// instance of it: **the difference between "we have no limit" and "we do not
// know the limit yet" is the whole feature.** Three separate mechanisms exist to
// keep those apart — NULL rather than a sentinel in the columns, the two values
// of `AlertsDisabledReason`, and the source badge on each row — and each of them
// fails silently. A screen that collapses them still renders; a database that
// collapses them still loads; nothing goes red until a user is either warned
// about a healthy battery or not warned about a dying one.
//
// CLEAN-ROOM: expectations derive from this project's own source and design 0080.
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
import 'package:open_smart_batt/ui/alerts/alert_settings_page.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:open_smart_batt/ui/util/alert_thresholds_lookup.dart';
import 'package:open_smart_batt/ui/widgets/industrial.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _unitA = 'AA:BB:CC:DD:EE:01';
const String _unitB = 'AA:BB:CC:DD:EE:02';

/// Inert BleService — mirrors `dashboard_split_test.dart`'s, so the two files
/// cannot drift into driving the controllers differently.
class _FakeBleService extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  void emit(TelemetrySample s) => _telemetryOut.add(s);

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

TelemetrySample _sample({
  int? deviceType,
  double? pvlt,
  int? temperatureC,
  double? warnOv,
  double? warnUv,
  double? warnOt,
}) =>
    TelemetrySample(
      timestamp: DateTime.utc(2026, 8, 22, 14, 32),
      deviceType: deviceType,
      pvlt: pvlt,
      temperatureC: temperatureC,
      warnOv: warnOv,
      warnUv: warnUv,
      warnOt: warnOt,
      mode: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  // =========================================================================
  // Model round trips
  // =========================================================================
  // 🔵 **2026-08-25 (FB-100): `alert_ov/uv/ot` are DORMANT, not dropped.** The
  // ruling made the thresholds read-only, so nothing writes or reads these
  // three any more — but ruling Q2 was "直接更新成讀取值", i.e. change what the
  // screen resolves, not what schema v22 holds. The columns therefore stay, and
  // so do the round-trip tests below: a column nothing reads is still a column
  // a later migration can corrupt, and re-proving `null != 0` costs nothing.
  group('SavedDevice: the alert columns survive a round trip', () {
    test('🔴 null stays null — it is never a 0 on the way through', () {
      const d = SavedDevice(id: _unitA, alias: 'a');
      final back = SavedDevice.fromMap(d.toMap());
      expect(back.alertOv, isNull);
      expect(back.alertUv, isNull);
      expect(back.alertOt, isNull);
      expect(back.alertMutedUntilMs, isNull);
      // The switch is the ONE of the five that is not a question — see the
      // field. Off by default here would leave the first person to enable the
      // feature with silence from every unit they own.
      expect(back.alertEnabled, isTrue);
      expect(back, d);
    });

    test('values survive, and `==` sees all five', () {
      const d = SavedDevice(
        id: _unitA,
        alias: 'a',
        alertEnabled: false,
        alertOv: 15.5,
        alertUv: 12.4,
        alertOt: 70,
        alertMutedUntilMs: 1755303600000,
      );
      expect(SavedDevice.fromMap(d.toMap()), d);
      for (final other in <SavedDevice>[
        d.copyWith(alertEnabled: true),
        d.copyWith(alertOv: 15.6),
        d.copyWith(clearAlertUv: true),
        d.copyWith(clearAlertOt: true),
        d.copyWith(clearAlertMutedUntil: true),
      ]) {
        expect(other == d, isFalse, reason: '$other compared equal to $d');
      }
    });

    test('🔴 `clearX` clears ONE field and leaves the others (§3.1 per field)',
        () {
      // The 「還原」 button's whole mechanism. Without the flags, `copyWith`
      // cannot express "back to not answered" at all, and the only way to
      // restore one row would be to rewrite all three.
      const d = SavedDevice(
        id: _unitA,
        alias: 'a',
        alertOv: 15.5,
        alertUv: 12.4,
        alertOt: 70,
      );
      final restored = d.copyWith(clearAlertUv: true);
      expect(restored.alertUv, isNull);
      expect(restored.alertOv, 15.5);
      expect(restored.alertOt, 70);
    });

    test('a pre-v22 row (no alert columns at all) reads as "not answered"', () {
      final back = SavedDevice.fromMap(const {'id': _unitA, 'alias': 'a'});
      expect(back.alertEnabled, isTrue);
      expect(back.alertOv, isNull);
      expect(back.alertMutedUntilMs, isNull);
    });

    test('isMutedAt takes the caller\'s clock, not its own', () {
      final until = DateTime.utc(2026, 8, 22, 15, 4);
      final d = SavedDevice(
        id: _unitA,
        alias: 'a',
        alertMutedUntilMs: until.millisecondsSinceEpoch,
      );
      expect(d.isMutedAt(until.subtract(const Duration(minutes: 1))), isTrue);
      expect(d.isMutedAt(until.add(const Duration(minutes: 1))), isFalse);
      expect(const SavedDevice(id: _unitA, alias: 'a').isMutedAt(until),
          isFalse);
    });
  });

  group('AppSettings: the four global parameters', () {
    test('🔴 the master switch defaults OFF (Q4), on a fresh object and a row',
        () {
      expect(AppSettings.defaults.alertsEnabled, isFalse);
      // An empty map is a pre-v22 row: `== 1`, not `!= 0`, is what makes this
      // false rather than true.
      expect(AppSettings.fromMap(const {}).alertsEnabled, isFalse);
    });

    test('round trip', () {
      final s = AppSettings.defaults.copyWith(
        alertsEnabled: true,
        alertSustainSec: 9,
        alertRepeatMin: 30,
        alertMaxPerEvent: 1,
      );
      final back = AppSettings.fromMap(s.toMap());
      expect(back.alertsEnabled, isTrue);
      expect(back.alertSustainSec, 9);
      expect(back.alertRepeatMin, 30);
      expect(back.alertMaxPerEvent, 1);
    });

    test('an absent parameter falls back to the shipped tuning', () {
      final back = AppSettings.fromMap(const {});
      expect(back.alertSustainSec, 5);
      expect(back.alertRepeatMin, 15);
      expect(back.alertMaxPerEvent, 3);
    });
  });

  // =========================================================================
  // The lookup — design 0079 §0.3's defect, at the level it is actually fixed
  // =========================================================================
  group('alertThresholdsFor: the thresholds follow the DEVICE', () {
    late DeviceController devices;

    Future<void> boot(WidgetTester tester, List<SavedDevice> seed) async {
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        addTearDown(db.close);
        final repo = DeviceRepo(db.db);
        for (final d in seed) {
          await repo.upsertSavedDevice(d);
        }
        devices = DeviceController(repo);
        await devices.load();
      });
    }

    testWidgets('🔴 B\'s live 0x2B is NOT applied to A\'s page', (tester) async {
      // The whole of design 0079 §0.3 in one assertion. Before P2 the history
      // list read `tele.warnOv` — whoever is on the link — so A's stored rows
      // were judged against B's limits.
      await boot(tester, const [
        SavedDevice(id: _unitA, alias: 'A', productClass: ProductClass.smartBattery),
        SavedDevice(id: _unitB, alias: 'B', productClass: ProductClass.smartBattery),
      ]);
      final t = alertThresholdsFor(
        devices,
        _unitA,
        liveSample: _sample(deviceType: 0x02, warnOv: 15.0, warnUv: 12.0, warnOt: 80),
        liveDeviceId: _unitB,
      );
      expect(t.ov.isSet, isFalse,
          reason: 'that 15.0 belongs to unit B and to nothing else');
      expect(t.uv.isSet, isFalse);
    });

    testWidgets('…and IS applied to B\'s own page', (tester) async {
      await boot(tester, const [
        SavedDevice(id: _unitB, alias: 'B', productClass: ProductClass.smartBattery),
      ]);
      final t = alertThresholdsFor(
        devices,
        _unitB,
        liveSample: _sample(deviceType: 0x02, warnOv: 15.0, warnUv: 12.0, warnOt: 80),
        liveDeviceId: _unitB,
      );
      expect(t.ov.value, 15.0);
      expect(t.ov.source, ThresholdSource.device);
    });

    testWidgets('🔴 a stored alert_uv is IGNORED — the wire wins (FB-100)',
        (tester) async {
      // 🔵 **2026-08-25 — this test was inverted, not deleted.** ~~'the user\'s
      // value outranks the wire, per FIELD'~~ asserted `t.uv.value == 12.4`.
      // The same fixture now has to prove the opposite, because that is exactly
      // what ruling Q2 promises the field: a phone that already has a custom
      // number in v22 shows the DEVICE's on the next launch, with no migration
      // and no prompt.
      await boot(tester, const [
        SavedDevice(
          id: _unitB,
          alias: 'B',
          productClass: ProductClass.smartBattery,
          alertUv: 12.4,
        ),
      ]);
      final t = alertThresholdsFor(
        devices,
        _unitB,
        liveSample: _sample(deviceType: 0x02, warnOv: 15.0, warnUv: 11.0, warnOt: 80),
        liveDeviceId: _unitB,
      );
      expect(t.uv.value, 11.0, reason: 'the unit\'s own 0x2B, not the 12.4');
      expect(t.uv.source, ThresholdSource.device);
      expect(t.ov.source, ThresholdSource.device);
      expect(t.ot.source, ThresholdSource.device);
    });

    testWidgets('an OFFLINE saved unit still resolves from ~~① and~~ ③',
        (tester) async {
      // The case the old `live` gate could only answer with silence. Nothing
      // here needs a radio: the class table is on disk.
      // 🔵 2026-08-25 (FB-100) — the stored 11.8 below is deliberately left in
      // the fixture and deliberately not expected: offline is precisely where a
      // dormant column would be most tempting to fall back on, and the point is
      // that it is not consulted even there.
      await boot(tester, const [
        SavedDevice(
          id: _unitA,
          alias: 'A',
          productClass: ProductClass.supercapacitor,
          alertUv: 11.8,
        ),
      ]);
      final t = alertThresholdsFor(devices, _unitA);
      expect(t.uv.value, 11.5, reason: 'the capacitor row, not the stored 11.8');
      expect(t.uv.source, ThresholdSource.appDefault);
      expect(t.ov.value, 14.8);
      expect(t.ov.source, ThresholdSource.appDefault);
    });

    testWidgets('🔴 alertWireClassFor agrees with resolveThresholds',
        (tester) async {
      // The parity check the lookup's own doc promises. Two independent
      // statements of §7.5.7's rule ("an unrecognised byte outranks the record;
      // an absent one lets it stand in") that no compiler relates to each other.
      await boot(tester, const [
        SavedDevice(id: _unitA, alias: 'A', productClass: ProductClass.smartBattery),
      ]);
      for (final byte in <int?>[null, 0x02, 0x17, 0x22, 0x31]) {
        final live = byte == null ? null : _sample(deviceType: byte);
        final cls = alertWireClassFor(devices, _unitA,
            liveSample: live, liveDeviceId: _unitA);
        final t = alertThresholdsFor(devices, _unitA,
            liveSample: live, liveDeviceId: _unitA);
        final unwatched = t.disabledReason != AlertsDisabledReason.none;
        expect(cls == ProductClass.unknown, unwatched,
            reason: 'byte $byte: the class the screen draws rows from and the '
                'class the resolution gated on must be the same class');
      }
    });

    testWidgets('a power bank is watched for heat and never for voltage',
        (tester) async {
      await boot(tester, const [
        SavedDevice(id: _unitA, alias: 'A', productClass: ProductClass.powerBank),
      ]);
      final t = alertThresholdsFor(devices, _unitA);
      expect(t.ot.value, kPowerBankOtDefaultC);
      expect(t.ot.source, ThresholdSource.appDefault);
      expect(t.ov.isSet, isFalse);
      expect(t.uv.isSet, isFalse);
      expect(alertVoltageWatched(alertWireClassFor(devices, _unitA)), isFalse);
    });
  });

  // =========================================================================
  // The screen
  // =========================================================================
  group('the alert settings screen', () {
    late AppServices services;
    late _FakeBleService ble;

    Future<void> boot(WidgetTester tester, List<SavedDevice> seed) async {
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        ble = _FakeBleService();
        services = await AppServices.create(appDatabase: db, ble: ble);
        for (final d in seed) {
          await services.devices.save(d);
        }
      });
    }

    Future<void> pump(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            // `promptAndSaveDevice` (design 0055) reaches for these, and the
            // unsaved entry row's tap runs it.
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
            // design 0080 P3: the page's 「本次連線不再提醒」 switch reads it,
            // and the settings card's permission row does too.
            ChangeNotifierProvider<AlertController>.value(
                value: services.alerts),
            ChangeNotifierProvider<GForceController>.value(value: services.gforce),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: child,
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> feed(WidgetTester tester, TelemetrySample s) async {
      await tester.runAsync(() async {
        ble.emit(s);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
    }

    tearDown(() async => services.dispose());

    testWidgets('state A — every row comes from the device', (tester) async {
      await boot(tester, const [
        SavedDevice(
            id: _unitA, alias: '阿福的機車', productClass: ProductClass.smartBattery),
      ]);
      await pump(tester, const AlertSettingsPage(deviceId: _unitA));
      await feed(
          tester,
          _sample(
              deviceType: 0x02,
              pvlt: 13.31,
              temperatureC: 34,
              warnOv: 15.0,
              warnUv: 11.0,
              warnOt: 80));

      expect(find.text('Device'), findsNWidgets(3),
          reason: 'a unit that reported 0x2B answers all three fields itself');
      expect(find.text('15.00 V'), findsOneWidget);
      expect(find.text('11.00 V'), findsOneWidget);
      expect(find.text('80 °C'), findsOneWidget);
      expect(find.text('Custom'), findsNothing);
      // …and none of the two "no warnings" screens.
      expect(find.textContaining('not recognised'), findsNothing);
      expect(find.textContaining('Still identifying'), findsNothing);
    });

    // 🔵 **2026-08-25 (FB-100): state B is gone, and the two tests that drew it
    // are replaced by one that proves it CANNOT be drawn.** ~~'state B — one
    // custom row, and ONLY one'~~ and ~~'state B — 還原 puts ONE field back to
    // "not answered"~~' both depended on a screen that offered an edit. The
    // fixture below keeps the stored 12.4 that used to produce state B, which
    // is the whole point: the row it once accented now shows the device's own
    // 11.0, with no 「自訂」, no 「還原」 and nothing to tap.
    testWidgets('🔴 a stored value draws NO custom row and offers no edit',
        (tester) async {
      await boot(tester, const [
        SavedDevice(
          id: _unitA,
          alias: '阿福的機車',
          productClass: ProductClass.smartBattery,
          alertOv: 15.5,
          alertUv: 12.4,
        ),
      ]);
      await pump(tester, const AlertSettingsPage(deviceId: _unitA));
      await feed(
          tester,
          _sample(
              deviceType: 0x02,
              pvlt: 12.62,
              temperatureC: 31,
              warnOv: 15.0,
              warnUv: 11.0,
              warnOt: 80));

      expect(find.text('Custom'), findsNothing);
      expect(find.text('Device'), findsNWidgets(3),
          reason: 'all three rows come from the wire now');
      expect(find.text('12.40 V'), findsNothing, reason: 'the stored value');
      expect(find.text('11.00 V'), findsOneWidget, reason: 'the device\'s own');
      expect(find.text('15.00 V'), findsOneWidget,
          reason: 'the OV row shows the wire\'s 15.0, not the stored 15.5');
      expect(find.byTooltip('Restore'), findsNothing);
      // §6.2's 「離目前讀數過近」 notice went with the values that could be too
      // near — 12.62 against a device-reported 11.0 is hardware, not a mistake.
      expect(find.textContaining('only 0.22 V'), findsNothing);

      // …and the row is not a control: tapping where the edit used to be opens
      // nothing. Asserted by tapping rather than by counting `InkWell`s, since
      // the page has other legitimate ones (the switch rows) and a count would
      // pass for the wrong reason the moment one of those moved.
      await tester.tap(find.text('11.00 V'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('11.00 V'), findsOneWidget, reason: 'still on the page');
    });

    testWidgets('the read-only note says the device is never changed',
        (tester) async {
      // 🔑 The half of FB-100 that is not a deletion. The dealer read the
      // editable rows as the app writing the hardware's protection points, and
      // nothing on this screen had ever said otherwise — a full l10n sweep
      // found zero strings on the subject.
      await boot(tester, const [
        SavedDevice(
          id: _unitA,
          alias: 'A',
          productClass: ProductClass.smartBattery,
        ),
      ]);
      await pump(tester, const AlertSettingsPage(deviceId: _unitA));
      await feed(tester,
          _sample(deviceType: 0x02, warnOv: 15.0, warnUv: 11.0, warnOt: 80));

      expect(find.textContaining('never changes the device'), findsOneWidget);
    });

    testWidgets('🔴 state C — an unrecognised device type disables the page',
        (tester) async {
      // §7.5.6 C-2, "no exceptions". Note the unit below DOES report a full
      // 0x2B: the back door the ruling named, shut. (🔵 It also carries a
      // stored `alertUv`, which was the second back door until 2026-08-25 and
      // is now simply unread — see FB-100.)
      await boot(tester, const [
        SavedDevice(
          id: _unitA,
          alias: '未命名裝置',
          productClass: ProductClass.smartBattery,
          alertUv: 12.4,
        ),
      ]);
      await pump(tester, const AlertSettingsPage(deviceId: _unitA));
      await feed(
          tester,
          _sample(
              deviceType: 0x31,
              pvlt: 13.0,
              warnOv: 15.0,
              warnUv: 11.0,
              warnOt: 80));

      expect(find.textContaining('not recognised, so no warnings'),
          findsOneWidget);
      // The byte itself, because it is the actionable part — a user reading it
      // into a report is how 0x18 got mapped in a day.
      expect(find.textContaining('0x31'), findsOneWidget);
      // 🔑 The reassurance is not decoration: this is the only screen in the app
      // that says "unrecognised", and without it a user cannot tell whether we
      // have given up on their device entirely.
      expect(find.textContaining('Live monitoring, history and export'),
          findsOneWidget);
      // No threshold row survived — not the reported 15.00, not the typed 12.40.
      expect(find.text('15.00 V'), findsNothing);
      expect(find.text('12.40 V'), findsNothing);
      expect(find.text('Custom'), findsNothing);
      // The switch is drawn and dead, rather than hidden.
      final sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.onChanged, isNull);
    });

    testWidgets('🔴 pending is NOT state C — the transient must not shout',
        (tester) async {
      // Landmine 2 / §7.5.6 C-3. Every connection passes through "no 0x10 yet",
      // so a screen that borrowed state C's words would raise a false alarm
      // about the alarms on every single connect.
      await boot(tester, const [
        SavedDevice(id: _unitA, alias: 'A'), // no persisted class
      ]);
      await pump(tester, const AlertSettingsPage(deviceId: _unitA));
      await feed(tester, _sample(pvlt: 13.0)); // a frame, but no device type

      expect(find.textContaining('not recognised'), findsNothing,
          reason: 'this is "we have not been told yet", not "we cannot name it"');
      expect(find.textContaining('Still identifying'), findsOneWidget);
      // And nothing is disabled: the per-device switch is still the user's.
      final sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.onChanged, isNotNull);
    });

    testWidgets('🔴 state D — a power bank shows ONE row, not three greyed ones',
        (tester) async {
      // §3.2.2 verbatim: 「不是顯示成灰色停用 —— 那會讓使用者以為是自己少設了
      // 什麼」. So the assertion is an ABSENCE, and it has to be an absence of the
      // ROW rather than of a value.
      await boot(tester, const [
        SavedDevice(id: _unitA, alias: 'RSPB-01', productClass: ProductClass.powerBank),
      ]);
      await pump(tester, const AlertSettingsPage(deviceId: _unitA));
      await feed(tester, _sample(deviceType: 0x22, temperatureC: 31));

      expect(find.text('Over-temperature'), findsOneWidget);
      expect(find.text('Over-voltage'), findsNothing);
      expect(find.text('Under-voltage'), findsNothing);
      // 50 °C is the one number in the table nobody measured — the badge is
      // required to say so (§3.2.2).
      expect(find.text('App default'), findsOneWidget);
      expect(find.text('50 °C'), findsOneWidget);
      expect(find.textContaining('Why is there no voltage warning'),
          findsOneWidget);
    });

    testWidgets('an offline unit says "known once connected", not "no basis"',
        (tester) async {
      // §7.5.2's known gap. `0x2B` is persisted nowhere, so an offline unit's
      // factory limits are UNKNOWN — and the alternative (caching the last
      // triple against the id) is what the design refused, because a stale
      // factory limit is indistinguishable from a live one on screen.
      await boot(tester, const [
        SavedDevice(id: _unitA, alias: 'A', productClass: ProductClass.smartBattery),
      ]);
      await pump(tester, const AlertSettingsPage(deviceId: _unitA));

      expect(find.textContaining('only readable while connected'),
          findsOneWidget);
      expect(find.text('No basis'), findsNothing);
      expect(find.text('Known once connected'), findsWidgets);
    });

    testWidgets('muting for an hour writes an INSTANT, and it persists',
        (tester) async {
      await boot(tester, const [
        SavedDevice(id: _unitA, alias: 'A', productClass: ProductClass.supercapacitor),
      ]);
      await pump(tester, const AlertSettingsPage(deviceId: _unitA));

      final before = DateTime.now();
      await tester.tap(find.text('Off'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();

      final saved = services.devices.deviceFor(_unitA)!;
      expect(saved.alertMutedUntilMs, isNotNull);
      final until = saved.alertMutedUntil!;
      // Roughly an hour out — asserted as a window rather than an equality
      // because the clock moved between the tap and here.
      expect(until.isAfter(before.add(const Duration(minutes: 59))), isTrue);
      expect(until.isBefore(before.add(const Duration(minutes: 61))), isTrue);
      expect(saved.isMutedAt(DateTime.now()), isTrue);
      expect(find.text('Resume'), findsOneWidget);
    });

    testWidgets(
        '🔴 "not again this connection" is memory only — it never reaches the row',
        (tester) async {
      // The asymmetry in §3.4 is the design: an hour is a promise about
      // wall-clock time, a connection is a promise about a link. Persisting the
      // second one is the single change that would make it wrong.
      await boot(tester, const [
        SavedDevice(id: _unitA, alias: 'A', productClass: ProductClass.supercapacitor),
      ]);
      await pump(tester, const AlertSettingsPage(deviceId: _unitA));

      await tester.tap(find.byType(Switch).last);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();

      final saved = services.devices.deviceFor(_unitA)!;
      expect(saved.alertMutedUntilMs, isNull);
      expect(saved.alertEnabled, isTrue,
          reason: 'the session mute is not the per-device switch either');
    });

    testWidgets('the entry row on an UNSAVED unit does not open the screen',
        (tester) async {
      // §3.6.3. Layer ①, the switch and the mute are all `saved_devices`
      // columns, so there is nowhere to write — but the row still shows, because
      // a feature that is invisible for unsaved units is one the user cannot
      // discover they are missing.
      await boot(tester, const []);
      await pump(
          tester,
          const Scaffold(
              body: SingleChildScrollView(
                  child: AlertSettingsEntry(deviceId: _unitA))));

      expect(find.textContaining('Save this device first'), findsOneWidget);
      await tester.tap(find.byType(AlertSettingsEntry));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
      // The route's own transition — a dialog is a route, and one pump only
      // pushes it.
      await tester.pump(const Duration(milliseconds: 400));

      // What the tap opened is design 0055's naming prompt, NOT this feature's
      // screen — the one control on that screen that could be honoured is the
      // one it does not have.
      expect(find.byType(AlertSettingsPage), findsNothing);
      expect(find.text('Skip'), findsOneWidget);

      // Declining is a real answer (`promptAndSaveDevice`'s own rule), so it is
      // exercised rather than left hanging: nothing is written, and the entry
      // row still says the same thing.
      await tester.tap(find.text('Skip'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(services.devices.isSaved(_unitA), isFalse);
      expect(find.textContaining('Save this device first'), findsOneWidget);
    });
  });

  // =========================================================================
  // §3.8 — one threshold source, and the advisory line reads it
  // =========================================================================
  group('the advisory line follows the resolved thresholds', () {
    late AppServices services;
    late _FakeBleService ble;

    Future<void> boot(WidgetTester tester, List<SavedDevice> seed) async {
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        ble = _FakeBleService();
        services = await AppServices.create(appDatabase: db, ble: ble);
        for (final d in seed) {
          await services.devices.save(d);
        }
      });
    }

    Future<void> pump(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            // `promptAndSaveDevice` (design 0055) reaches for these, and the
            // unsaved entry row's tap runs it.
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
            // design 0080 P3: the page's 「本次連線不再提醒」 switch reads it,
            // and the settings card's permission row does too.
            ChangeNotifierProvider<AlertController>.value(
                value: services.alerts),
            ChangeNotifierProvider<GForceController>.value(value: services.gforce),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(body: SingleChildScrollView(child: child)),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> feed(WidgetTester tester, TelemetrySample s) async {
      await tester.runAsync(() async {
        ble.emit(s);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
    }

    tearDown(() async => services.dispose());

    // 🔵 **2026-08-25 (FB-100): both of this group's user-value tests are
    // replaced.** ~~'a user-set UV changes the advisory line — layer ② no
    // longer decides'~~ and ~~'…and restoring that field puts the line away
    // again'~~ drove the advisory line from a stored `alert_uv`, which nothing
    // reads any more. The property they were really protecting — the line and
    // the alarm read ONE resolver, this repo's three-times-logged "one fact,
    // two sources" failure aimed at an alarm — is kept below, driven from the
    // table instead of from the owner.
    testWidgets('🔴 a stored alert_uv no longer moves the advisory line',
        (tester) async {
      // Same fixture as the deleted test: 12.6 V sits inside the device's own
      // 11.0 V limit and below the stored 12.8. Before FB-100 the stored value
      // won and the line appeared; now the wire wins and it must not.
      await boot(tester, const [
        SavedDevice(
          id: _unitA,
          alias: 'A',
          productClass: ProductClass.smartBattery,
          alertUv: 12.8,
        ),
      ]);
      await pump(tester, const BatteryControls(deviceId: _unitA));
      await feed(
          tester,
          _sample(
              deviceType: 0x02,
              pvlt: 12.6,
              temperatureC: 30,
              warnOv: 15.0,
              warnUv: 11.0,
              warnOt: 80));

      expect(find.textContaining('outside the warning range'), findsNothing,
          reason: "the unit's own 11.0 V decides, and 12.6 does not breach it");
    });

    testWidgets('🔴 the line still follows the RESOLVER, not warnUv directly',
        (tester) async {
      // The property the two deleted tests existed for, restated with the
      // layers that are left. A capacitor reporting NO 0x2B resolves UV 11.5
      // off the table (§3.2.1), so 11.2 V is a breach — and a screen reading
      // `TelemetrySample.warnUv` directly would find null and say nothing.
      await boot(tester, const [
        SavedDevice(
          id: _unitA,
          alias: 'A',
          productClass: ProductClass.supercapacitor,
        ),
      ]);
      await pump(tester, const BatteryControls(deviceId: _unitA));
      await feed(tester,
          _sample(deviceType: 0x17, pvlt: 11.2, temperatureC: 30));

      expect(find.textContaining('outside the warning range'), findsOneWidget,
          reason: 'layer ③ answered where layer ② could not');
    });

    testWidgets(
        '🔴 an unidentified unit gets no advisory line, whatever it reported',
        (tester) async {
      // §7.5.6 C-2 reaching the dashboard: 12.6 V is neither a breach nor a
      // reassurance on hardware we cannot name — it is an uninterpretable pair
      // of digits.
      await boot(tester, const [
        SavedDevice(id: _unitA, alias: 'A'),
      ]);
      await pump(tester, const BatteryControls(deviceId: _unitA));
      await feed(
          tester,
          _sample(
              deviceType: 0x31,
              pvlt: 9.0,
              warnOv: 15.0,
              warnUv: 11.0,
              warnOt: 80));

      expect(find.textContaining('outside the warning range'), findsNothing);
    });
  });

  // =========================================================================
  // The Settings tab card
  // =========================================================================
  group('settings: the global half', () {
    late AppServices services;

    Future<void> boot(WidgetTester tester, {AlertNotifier? notifier}) async {
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        services = await AppServices.create(
          appDatabase: db,
          ble: _FakeBleService(),
          alertNotifier: notifier,
        );
      });
    }

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<AppServices>.value(value: services),
            Provider<BleService>.value(value: services.ble),
            Provider<HistoryRepo>.value(value: services.historyRepo),
            Provider<DeviceRepo>.value(value: services.deviceRepo),
            Provider<SettingsRepo>.value(value: services.settingsRepo),
            Provider<LogRepo>.value(value: services.logRepo),
            ChangeNotifierProvider<SettingsController>.value(
                value: services.settings),
            ChangeNotifierProvider<DeviceController>.value(
                value: services.devices),
            ChangeNotifierProvider<ConnectionController>.value(
                value: services.connection),
            ChangeNotifierProvider<TelemetryController>.value(
                value: services.telemetry),
            // design 0080 P3: the page's 「本次連線不再提醒」 switch reads it,
            // and the settings card's permission row does too.
            ChangeNotifierProvider<AlertController>.value(
                value: services.alerts),
            ChangeNotifierProvider<GForceController>.value(value: services.gforce),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pump();
      // 🔴 The Data card measures what history occupies when it mounts (design
      // 0061 T8c) — a real database query. Started inside the fake-async zone it
      // can never progress, and the test would then fail on a pending timer that
      // has nothing to do with warnings. Same drain as
      // `device_info_slot_test.dart`.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    tearDown(() async => services.dispose());

    testWidgets('the card exists, off, with the shipped tuning', (tester) async {
      await boot(tester);
      await pump(tester);
      await tester.scrollUntilVisible(
          find.text('Enable warning notifications'), 200);

      // 🔴 Q4: OFF out of the box, and the switch on screen agrees with the
      // stored value rather than merely defaulting to the same picture.
      expect(services.settings.alertsEnabled, isFalse);
      final row = find.ancestor(
        of: find.text('Enable warning notifications'),
        matching: find.byType(SettingsRow),
      );
      expect(row, findsOneWidget);
      final sw = find.descendant(of: row, matching: find.byType(Switch));
      expect(tester.widget<Switch>(sw).value, isFalse);

      // The shipped tuning, §3.3.
      expect(find.text('5 s'), findsOneWidget);
      expect(find.text('15 min'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      // And it is a real switch, not a picture of one.
      //
      // 🔵 **P3 put a door in front of it** (§3.7.3): turning it ON now runs
      // the one-time explainer and then the permission request, so the tap
      // alone no longer writes. Turning it off still does — the asymmetry is
      // the point of an opt-in, and it is asserted below.
      await tester.tap(sw);
      await tester.pumpAndSettle();
      expect(find.text('Turn on warning notifications'), findsOneWidget,
          reason: 'ruling Q4 ships it off; this dialog is the only way past');
      expect(services.settings.alertsEnabled, isFalse,
          reason: 'nothing is written until the user says yes');
      await tester.tap(find.text('Turn on'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pumpAndSettle();
      expect(services.settings.alertsEnabled, isTrue);
    });

    testWidgets('🔴 cancelling the explainer writes nothing and asks nothing',
        (tester) async {
      // The difference between an opt-in and a formality. On iOS the OS prompt
      // is one-shot, so an accidental tap must not spend it.
      await boot(tester);
      await pump(tester);
      await tester.scrollUntilVisible(
          find.text('Enable warning notifications'), 200);
      await tester.tap(find.descendant(
        of: find.ancestor(
          of: find.text('Enable warning notifications'),
          matching: find.byType(SettingsRow),
        ),
        matching: find.byType(Switch),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(services.settings.alertsEnabled, isFalse);
      expect(services.alerts.permission, AlertPermission.unknown,
          reason: 'the OS was never asked, so there is nothing to report');
    });

    testWidgets(
        '🔴 §6.2 — a refused permission is RED with a way out, never silent',
        (tester) async {
      // Design 0008 §3.4 is the logged precedent: a denied permission left the
      // watch running and only hid the notification, so what the user
      // experienced was "I turned it on and nothing arrives" with nothing on
      // any screen to explain it.
      await boot(tester, notifier: NoopAlertNotifier()..permission = AlertPermission.denied);
      await pump(tester);
      await tester.scrollUntilVisible(
          find.text('Enable warning notifications'), 200);
      await tester.tap(find.descendant(
        of: find.ancestor(
          of: find.text('Enable warning notifications'),
          matching: find.byType(SettingsRow),
        ),
        matching: find.byType(Switch),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn on'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pumpAndSettle();

      // Enabled anyway — refusing to enable would trade a silent failure for a
      // dead end (design 0008 §3.4).
      expect(services.settings.alertsEnabled, isTrue);
      await tester.scrollUntilVisible(
          find.text('Refused — nothing will reach your phone'), 200);
      expect(find.text('Open settings'), findsOneWidget);
      // …and it says what is still working, so "refused" does not read as
      // "the feature is dead".
      expect(
          find.textContaining('still appear on the device screen'), findsOneWidget);
    });

    testWidgets('🔴 the capability card says what it can and cannot do (§6.1)',
        (tester) async {
      // The red line, asserted from BOTH sides: the honest sentence has to be
      // there, and the four forbidden claims have to not be. A test that only
      // checked for the presence would pass on a screen that also promised
      // 24-hour monitoring right underneath.
      await boot(tester);
      await pump(tester);
      await tester.scrollUntilVisible(
          find.text('What this feature can do'), 200);

      expect(find.textContaining('only happens while the app is CONNECTED'),
          findsOneWidget);
      expect(find.textContaining('Nothing is checked after the link drops'),
          findsOneWidget);
      for (final forbidden in const [
        '24-hour',
        '24 hour',
        'always connected',
        'offline',
      ]) {
        expect(find.textContaining(forbidden), findsNothing,
            reason: '§6.1 forbids "$forbidden" anywhere in this feature\'s copy');
      }
    });

    testWidgets('a stepper writes through and persists', (tester) async {
      await boot(tester);
      await pump(tester);
      await tester.scrollUntilVisible(find.text('5 s'), 200);

      await tester.tap(find.byTooltip('Increase').first);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
      expect(services.settings.alertSustainSec, 6);

      final reloaded = await tester
          .runAsync(() => SettingsRepo(services.appDb.db).loadSettings());
      expect(reloaded!.alertSustainSec, 6);
    });
  });
}
