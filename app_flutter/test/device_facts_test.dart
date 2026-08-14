// design 0057 — a unit's own facts survive not being named, and go NOWHERE
// near routing.
//
// The defect. `saved_devices` mixes two unrelated things: what the USER decided
// (alias, layout) and what the DEVICE said (advertised name, `0x10` class,
// `0x38` MAC, serial). Its only entrance is the naming dialog, so declining to
// name a unit discarded the facts it had just reported along with the name it
// never got. The visible cost was an export stating a falsehood: a
// super-capacitor streams a permanent 0.0 A it cannot measure, the CSV blanks
// that column by asking `deviceClassFor`, and for an unnamed unit that answered
// `unknown` — so the file said the pack was drawing no current. Commit 66eb8e9
// half-fixed it by consulting the LIVE link; connect, look, disconnect, export
// and the zero came straight back.
//
// The boundary. This cache is read ONLY on the way back out of storage —
// history labels, export identity, whether `ampere` is a measurement. It never
// decides what the NEXT connection draws, because the owner's rule for a
// deleted device is「就是當一個陌生的裝置重新開始」and a cached class would
// quietly break it. T57-3 and T57-4 below are that boundary, and they are the
// most important tests in this file.
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
import 'package:open_smart_batt/ui/dashboard/class_pending_view.dart';
import 'package:open_smart_batt/ui/dashboard/dashboard_page.dart';
import 'package:open_smart_batt/ui/dashboard/pack_view.dart';
import 'package:open_smart_batt/ui/util/export_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// No radio: the test drives link transitions and telemetry directly, and says
/// which id/name the "connected" unit has.
class _StubBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  String? held;
  String advertised = '';

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

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
  String? get connectedDeviceId => held;

  @override
  String get connectedDeviceName => advertised;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {}

  @override
  Future<void> disconnect() async {}

  void emitLink(BleLinkState s) => _linkOut.add(s);
  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _telemetryOut.close();
    await super.dispose();
  }
}

/// Let the fire-and-forget writes land. `record()` is a transaction plus a
/// reload, so a microtask hop is not enough.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

/// The `ampere` cell of a one-row CSV export.
///
/// Parsed rather than substring-matched: `contains('0.0')` also matches the
/// `00.000` inside the ISO timestamp, which makes the assertion pass for a
/// blanked column and a filled one alike — it did, on the first run of this
/// file.
String ampereCell(String csv) {
  final lines = csv.trim().split(RegExp(r'\r?\n'));
  final header = lines.first.split(',');
  final row = lines.last.split(',');
  return row[header.indexOf('ampere')];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  Future<AppServices> makeServices(_StubBle ble) async {
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    return AppServices.create(appDatabase: db, ble: ble);
  }

  TelemetrySample sampleWith({
    int? deviceType,
    String? mac,
    String? serial,
    String? dealerCode,
    double? current,
    DateTime? at,
  }) =>
      TelemetrySample(
        timestamp: at ?? DateTime.utc(2026, 8, 11, 12),
        pvlt: 13.2,
        current: current,
        deviceType: deviceType,
        mac: mac,
        serial: serial,
        dealerCode: dealerCode,
      );

  /// Connect [id], let it report [deviceType] (and optionally a MAC/serial),
  /// then drop the link — the "connect, look, never name it" path design 0055
  /// made ordinary.
  Future<void> connectAndLeave(
    AppServices s,
    _StubBle ble,
    String id, {
    int? deviceType,
    String name = '',
    String? mac,
    String? serial,
    String? dealerCode,
    double? current,
  }) async {
    ble.held = id;
    ble.advertised = name;
    await s.connection.connect(id);
    ble.emitLink(BleLinkState.ready);
    await settle();
    ble.emitTelemetry(sampleWith(
      deviceType: deviceType,
      mac: mac,
      serial: serial,
      dealerCode: dealerCode,
      current: current,
    ));
    await settle();
    ble.emitLink(BleLinkState.disconnected);
    ble.held = null;
    ble.advertised = '';
    await settle();
  }

  // =========================================================================
  // The write path
  // =========================================================================
  group('what a unit says is kept whether or not it is named', () {
    test('an UNSAVED unit now leaves a row behind (it used to leave nothing)',
        () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      await connectAndLeave(s, ble, 'CAP',
          deviceType: kSuperCapacitorDeviceType,
          name: 'RCE-SCAP_II',
          mac: 'AA:BB:CC:DD:EE:FF');

      expect(s.devices.deviceFor('CAP'), isNull,
          reason: 'nobody named it — the saved list must stay empty (0055 §5)');
      final f = s.facts.factFor('CAP');
      expect(f, isNotNull, reason: 'the facts it reported are what 0057 keeps');
      expect(f!.productClass, ProductClass.supercapacitor);
      expect(f.name, 'RCE-SCAP_II');
      expect(f.mac, 'AA:BB:CC:DD:EE:FF');
    });

    test('a SAVED unit behaves exactly as before, and is cached as well',
        () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);
      await s.devices.saveNew('BATT', '前車電瓶');

      await connectAndLeave(s, ble, 'BATT',
          deviceType: kSmartBatteryDeviceType, name: 'RCE-CarBatt');

      expect(s.devices.deviceFor('BATT')!.productClass,
          ProductClass.smartBattery,
          reason: 'the pre-0057 write onto the saved record is untouched');
      expect(s.facts.factFor('BATT')!.productClass, ProductClass.smartBattery,
          reason: '0057 §4.2: the same facts, additionally cached');
    });

    test('T57-7: a frame without 0x38 does not blank a known MAC', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      ble.held = 'CAP';
      ble.advertised = 'RCE-SCAP_II';
      await s.connection.connect('CAP');
      ble.emitLink(BleLinkState.ready);
      await settle();
      ble.emitTelemetry(sampleWith(mac: 'AA:BB:CC:DD:EE:FF'));
      await settle();
      expect(s.facts.factFor('CAP')!.mac, 'AA:BB:CC:DD:EE:FF');

      // 0x38 is not on every frame; the next one carries the class instead.
      ble.emitTelemetry(sampleWith(deviceType: kSuperCapacitorDeviceType));
      await settle();

      final f = s.facts.factFor('CAP')!;
      expect(f.mac, 'AA:BB:CC:DD:EE:FF',
          reason: 'absence of a value is not an observation of NULL (§4.1)');
      expect(f.productClass, ProductClass.supercapacitor);
    });

    test('the user\'s manual class pick never reaches the cache', () async {
      // A table called `device_facts` that stores a guess would be read back
      // later as an observation. `_persistFacts` takes the wire byte only.
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      ble.held = 'CAP';
      await s.connection.connect('CAP');
      ble.emitLink(BleLinkState.ready);
      await settle();
      s.connection.setPackLabelOverride(ProductClass.smartBattery);
      ble.emitTelemetry(sampleWith());
      await settle();

      expect(s.connection.packLabel, ProductClass.smartBattery,
          reason: 'it does drive the cosmetic chip');
      expect(s.facts.factFor('CAP')?.productClass, ProductClass.unknown,
          reason: 'but nothing said this on the wire');
    });
  });

  // =========================================================================
  // 🔴 The boundary: routing may not read this table
  // =========================================================================
  group('🔴 routing never reads device_facts', () {
    /// The premise of T57-3: a capacitor is known to `device_facts` under an id
    /// that has NO saved record — precisely what "connected once, never named"
    /// (or "named, then deleted") leaves behind.
    Future<AppServices> withCachedCapacitor(_StubBle ble) async {
      final s = await makeServices(ble);
      await s.facts.record('CAP',
          name: 'RCE-SCAP_II',
          productClass: ProductClass.supercapacitor,
          mac: 'AA:BB:CC:DD:EE:FF');
      expect(s.facts.factFor('CAP')!.productClass, ProductClass.supercapacitor,
          reason: 'the premise: the cache DOES know this unit');
      expect(s.devices.deviceFor('CAP'), isNull,
          reason: 'the premise: nothing is saved for it');
      return s;
    }

    test('T57-3: the seed stays unknown and the link stays pending', () async {
      final ble = _StubBle();
      final s = await withCachedCapacitor(ble);
      addTearDown(s.dispose);

      ble.held = 'CAP';
      await s.connection.connect('CAP');
      ble.emitLink(BleLinkState.ready);
      await settle();

      expect(s.connection.resolvedClass, ProductClass.unknown,
          reason: '🔴 design 0057 §3: a cached class may not seed routing — '
              'deleting a device has to mean starting again as a stranger');
      expect(s.connection.routing, RoutingDecision.pending,
          reason: 'no byte yet and nothing STORED to cover the gap');
      expect(s.connection.isPowerBank, isFalse);
    });

    test('T57-3: the same id WITH a saved record does seed — the control',
        () async {
      // Without this the test above passes for the wrong reason (e.g. if the
      // seed lookup were broken outright). Same id, same cache, one difference.
      final ble = _StubBle();
      final s = await withCachedCapacitor(ble);
      addTearDown(s.dispose);
      await s.devices.saveNew('CAP', 'Cap #1',
          productClass: ProductClass.supercapacitor);

      ble.held = 'CAP';
      await s.connection.connect('CAP');
      ble.emitLink(BleLinkState.ready);
      await settle();

      expect(s.connection.resolvedClass, ProductClass.supercapacitor);
      expect(s.connection.routing, RoutingDecision.pack,
          reason: 'FB-43: a SAVED class carries routing until 0x10 lands');
    });

    testWidgets('T57-3: the dashboard still draws ClassPendingView',
        (tester) async {
      late final _StubBle ble;
      late final AppServices s;
      await tester.runAsync(() async {
        ble = _StubBle();
        s = await withCachedCapacitor(ble);
      });
      addTearDown(() => tester.runAsync(s.dispose));

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsController>.value(value: s.settings),
            ChangeNotifierProvider<DeviceController>.value(value: s.devices),
            ChangeNotifierProvider<DeviceFactsController>.value(
                value: s.facts),
            ChangeNotifierProvider<ConnectionController>.value(
                value: s.connection),
            ChangeNotifierProvider<TelemetryController>.value(
                value: s.telemetry),
            ChangeNotifierProvider<GForceController>.value(value: s.gforce),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const Scaffold(body: DashboardRouter()),
          ),
        ),
      );
      await tester.pump();

      // 🔴 Real I/O: a DB round-trip inside fake time never completes.
      await tester.runAsync(() async {
        ble.held = 'CAP';
        await s.connection.connect('CAP');
        ble.emitLink(BleLinkState.ready);
        await settle();
      });
      await tester.pump();

      expect(find.byType(ClassPendingView), findsOneWidget,
          reason: 'the cache knows it is a capacitor; the DASHBOARD must not');
      expect(find.byType(PackView), findsNothing);
    });

    test('T57-4: delete, reconnect — identical to a first connection',
        () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);
      await s.devices.saveNew('CAP', 'Cap #1');
      await connectAndLeave(s, ble, 'CAP',
          deviceType: kSuperCapacitorDeviceType, name: 'RCE-SCAP_II');
      expect(s.devices.deviceFor('CAP')!.productClass,
          ProductClass.supercapacitor);

      await s.devices.remove('CAP');
      expect(s.facts.factFor('CAP')!.productClass, ProductClass.supercapacitor,
          reason: 'Q1: the facts stay — the user deleted a NAME, and the rows '
              'already recorded still have to read back honestly');

      ble.held = 'CAP';
      await s.connection.connect('CAP');
      ble.emitLink(BleLinkState.ready);
      await settle();
      expect(s.connection.resolvedClass, ProductClass.unknown);
      expect(s.connection.routing, RoutingDecision.pending,
          reason: '「我刪掉的話　就是當一個陌生的裝置重新開始不是嗎？」');
    });
  });

  // =========================================================================
  // MAC de-duplication (§4.1.1)
  // =========================================================================
  group('two BLE ids, one machine', () {
    test('T57-9: a fresh id inserts its own row and inherits the known facts',
        () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      // The iOS reinstall shape: same hardware, new NSUUID, same 0x38 MAC.
      await connectAndLeave(s, ble, 'uuid-old',
          deviceType: kSuperCapacitorDeviceType,
          name: 'RCE-SCAP_II',
          mac: 'AA:BB:CC:DD:EE:FF',
          serial: '0000123',
          dealerCode: '01681234');
      final oldSerial = s.facts.factFor('uuid-old')!.serial;
      expect(oldSerial, isNotNull);

      // The new id says only "I am AA:BB:…" — no class byte yet.
      await connectAndLeave(s, ble, 'uuid-new', mac: 'AA:BB:CC:DD:EE:FF');

      final fresh = s.facts.factFor('uuid-new');
      expect(fresh, isNotNull, reason: 'a row of its own, keyed by its own id');
      expect(fresh!.productClass, ProductClass.supercapacitor,
          reason: '§4.1.1 rule 3: the MAC says these are one machine');
      expect(fresh.serial, oldSerial);
      expect(fresh.name, 'RCE-SCAP_II');

      expect(s.facts.factFor('uuid-old'), isNotNull,
          reason: '🔴 the old row is not deleted…');
      expect(s.facts.factFor('uuid-old')!.id, 'uuid-old',
          reason: '…and its id is not rewritten');
    });

    test('T57-10: history under the OLD id still resolves to an identity',
        () async {
      // The entire reason the primary key is the BLE id. Re-keying the old row
      // onto the new id would "fix" the new device by orphaning every row the
      // old one recorded — and those rows are what design 0057 exists to save.
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      // The history row is written by the REAL recording path during the
      // visit, so what the export reads is what a user's phone would hold.
      await connectAndLeave(s, ble, 'uuid-old',
          deviceType: kSuperCapacitorDeviceType,
          name: 'RCE-SCAP_II',
          mac: 'AA:BB:CC:DD:EE:FF',
          current: 0);
      await connectAndLeave(s, ble, 'uuid-new', mac: 'AA:BB:CC:DD:EE:FF');

      expect(deviceClassFor(s.devices, 'uuid-old', facts: s.facts),
          ProductClass.supercapacitor,
          reason: 'the old id is still a known capacitor after de-duplication');
      expect(deviceLabelFor(s.devices, 'uuid-old', facts: s.facts),
          startsWith('RCE-SCAP_II · '));

      final csv = await s.historyRepo.exportCsv(
        deviceId: 'uuid-old',
        classFor: (id) => deviceClassFor(s.devices, id, facts: s.facts),
      );
      expect(csv.rows, 1);
      expect(ampereCell(csv.text), 'null',
          reason: 'the capacitor cannot measure current; the column is blank');
    });

    test('T57-11: reconciliation fills gaps and never overwrites', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      // First seen: a full set of facts.
      await connectAndLeave(s, ble, 'uuid-old',
          deviceType: kSuperCapacitorDeviceType,
          name: 'RCE-SCAP_II',
          mac: 'AA:BB:CC:DD:EE:FF');
      // Second id, same MAC, but it advertises a DIFFERENT name (a firmware
      // rename between the two installs would look exactly like this).
      await connectAndLeave(s, ble, 'uuid-new',
          name: 'RCE-SCAP_III', mac: 'AA:BB:CC:DD:EE:FF');
      // …and a third pass, to prove the two rows do not take turns stamping
      // each other every time either one connects.
      await connectAndLeave(s, ble, 'uuid-old', mac: 'AA:BB:CC:DD:EE:FF');

      expect(s.facts.factFor('uuid-old')!.name, 'RCE-SCAP_II',
          reason: 'it had a name of its own; nothing may overwrite it');
      expect(s.facts.factFor('uuid-new')!.name, 'RCE-SCAP_III',
          reason: 'so did the newer row — the fill is for GAPS only');
      expect(s.facts.factFor('uuid-new')!.productClass,
          ProductClass.supercapacitor,
          reason: 'the class WAS a gap, so it was filled');
    });

    test('a different MAC reconciles nothing', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      await connectAndLeave(s, ble, 'AA',
          deviceType: kSuperCapacitorDeviceType, mac: 'AA:AA:AA:AA:AA:AA');
      await connectAndLeave(s, ble, 'BB', mac: 'BB:BB:BB:BB:BB:BB');

      expect(s.facts.factFor('BB')!.productClass, ProductClass.unknown,
          reason: 'two units in one bag are not one unit');
    });
  });

  // =========================================================================
  // The read path (§4.3)
  // =========================================================================
  group('read-back priority: saved → facts → live → unknown', () {
    late AppDatabase db;
    late DeviceController devices;
    late DeviceFactsController facts;

    setUp(() async {
      db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      devices = DeviceController(DeviceRepo(db.db));
      facts = DeviceFactsController(DeviceFactsRepo(db.db));
      await devices.load();
      await facts.load();
    });
    tearDown(() async => db.close());

    test('T57-5: each rung beats the one below it', () async {
      await facts.record('CAP', productClass: ProductClass.supercapacitor);
      expect(deviceClassFor(devices, 'CAP', facts: facts),
          ProductClass.supercapacitor,
          reason: 'facts beat nothing');
      expect(
        deviceClassFor(devices, 'CAP',
            facts: facts,
            liveDeviceId: 'CAP',
            liveClass: ProductClass.smartBattery),
        ProductClass.supercapacitor,
        reason: 'a stored observation beats re-reading it — one answer',
      );
      await devices.saveNew('CAP', 'Cap #1',
          productClass: ProductClass.smartBattery);
      expect(deviceClassFor(devices, 'CAP', facts: facts),
          ProductClass.smartBattery,
          reason: 'the saved record is the one the user can correct');
    });

    test('🔴 T57-5: the live unit still lends NOTHING to another unit',
        () async {
      // FB-41 in a different column. The cache does not soften this: it is
      // keyed per id, so there is no "the thing that is plugged in" default.
      await facts.record('CAP', productClass: ProductClass.supercapacitor);
      expect(
        deviceClassFor(devices, 'OTHER',
            facts: facts,
            liveDeviceId: 'CAP',
            liveClass: ProductClass.supercapacitor),
        ProductClass.unknown,
      );
      expect(
        deviceClassFor(devices, null,
            facts: facts,
            liveDeviceId: 'CAP',
            liveClass: ProductClass.supercapacitor),
        ProductClass.unknown,
        reason: 'a pre-0006 row is about no unit at all',
      );
    });

    test('T57-6: an unsaved unit shows its advertised name AND a short hash',
        () async {
      await facts.record('CAP', name: 'RCE_RSPB-01');
      final label = deviceLabelFor(devices, 'CAP', facts: facts);
      expect(label, startsWith('RCE_RSPB-01 · '));
      expect(label, isNot('RCE_RSPB-01'),
          reason: 'Q2: two power banks in the 2026-07-29 capture advertise '
              'this same string — the name alone cannot pick one');
      expect(label, contains(shortDeviceHash('CAP')));
      expect(label, isNot(equals(shortDeviceHash('CAP'))),
          reason: 'G1: the bare hash is what the user could not read');
    });

    test('T57-6: two same-model units stay distinguishable', () async {
      await facts.record('AA', name: 'RCE_RSPB-01');
      await facts.record('BB', name: 'RCE_RSPB-01');
      expect(deviceLabelFor(devices, 'AA', facts: facts),
          isNot(deviceLabelFor(devices, 'BB', facts: facts)));
    });

    test("a name the USER wrote carries no hash", () async {
      await devices.saveNew('CAP', '前車電容', name: 'RCE-SCAP_II');
      await facts.record('CAP', name: 'RCE-SCAP_II');
      expect(deviceLabelFor(devices, 'CAP', facts: facts), '前車電容',
          reason: 'they know which unit they meant');
      expect(deviceNameFor(devices, 'CAP', facts: facts), '前車電容');
    });

    test('without a cache every answer is exactly the pre-0057 one', () async {
      await facts.record('CAP',
          name: 'RCE-SCAP_II', productClass: ProductClass.supercapacitor);
      expect(deviceClassFor(devices, 'CAP'), ProductClass.unknown);
      expect(deviceLabelFor(devices, 'CAP'), shortDeviceHash('CAP'));
      expect(deviceNameFor(devices, 'CAP'), '');
    });
  });

  // =========================================================================
  // G2: the export that used to state a fabricated 0.0 A
  // =========================================================================
  group('the exported ampere column', () {
    Future<({String text, int rows})> exportAfterVisit(
      AppServices s,
      _StubBle ble,
      String id,
      int deviceType,
    ) async {
      // Recorded by the real telemetry path, then the link goes away.
      await connectAndLeave(s, ble, id,
          deviceType: deviceType, name: 'RCE', current: 0);
      // 🔴 No live pair: the link is DOWN. Before 0057 this is exactly where
      // 66eb8e9's fix stopped helping.
      return s.historyRepo.exportCsv(
        deviceId: id,
        classFor: (rowId) => deviceClassFor(s.devices, rowId, facts: s.facts),
      );
    }

    test('T57-1: an unsaved capacitor exports a BLANK current, after the link '
        'has gone', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      final out = await exportAfterVisit(s, ble, 'CAP',
          kSuperCapacitorDeviceType);
      expect(out.rows, 1);
      expect(ampereCell(out.text), 'null',
          reason: 'the unit cannot measure current; writing its constant zero '
              'states as fact that the pack was drawing none');
    });

    test('T57-2: an unsaved BATTERY keeps its measured current', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      final out = await exportAfterVisit(s, ble, 'BATT',
          kSmartBatteryDeviceType);
      expect(out.rows, 1);
      expect(ampereCell(out.text), '0.0',
          reason: 'a battery CAN measure current, and 0 A is a real reading — '
              'blanking it would be the mirror-image lie');
    });
  });

  // =========================================================================
  // Q3 + the migration
  // =========================================================================
  group('what survives', () {
    test('T57-12: clearing history leaves the identities alone', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      await connectAndLeave(s, ble, 'CAP',
          deviceType: kSuperCapacitorDeviceType, name: 'RCE-SCAP_II');

      await s.historyRepo.clearHistory();
      await s.facts.load();

      expect(s.facts.factFor('CAP')!.productClass, ProductClass.supercapacitor,
          reason: 'Q3: this table says what the DEVICE said, not what the user '
              'chose to keep');
      expect(deviceLabelFor(s.devices, 'CAP', facts: s.facts),
          startsWith('RCE-SCAP_II · '),
          reason: 'and the label is right again the moment new rows arrive');
    });

    test('T57-8: v15 adds an empty table and changes nothing else', () async {
      final ble = _StubBle();
      final s = await makeServices(ble);
      addTearDown(s.dispose);

      // The schema HEAD, not v15 — this line has always pinned "where the
      // registry currently is", and the head moved to 16 on 2026-08-13 when
      // design 0060 added `autoconnect_arm`, then to 17 on 2026-08-14 when
      // design 0061 added `history.bucket_s`. What T57-8 actually asserts is
      // everything below: `device_facts` still arrives EMPTY and its index is
      // still non-unique, neither of which a later migration may change.
      expect(Db.schemaVersion, 17);
      expect(s.facts.facts, isEmpty,
          reason: 'NO backfill from saved_devices (0048 G2): a pre-v15 unit '
              'was never observed under a knowable instant, and inventing one '
              'is exactly what the rest of this schema refuses to do');

      // The index exists and is deliberately non-unique, so one machine may
      // legitimately own several rows (§4.1.1).
      final idx = await s.appDb.db.rawQuery(
          "SELECT name, \"unique\" FROM pragma_index_list('device_facts')");
      expect(idx.map((r) => r['name']), contains('idx_device_facts_mac'));
      expect(
        idx.firstWhere((r) => r['name'] == 'idx_device_facts_mac')['unique'],
        0,
        reason: 'a UNIQUE index would make the second connection after an iOS '
            'reinstall a constraint violation',
      );
    });
  });
}
