// Per-device state: the two singleton assumptions that fail SILENTLY.
//
// Six of the singletons in the BLE/state layer break LOUDLY if a second link
// ever exists — a shared frame reassembler splices two byte streams, a shared
// keep-alive tick counter means some unit never gets asked for the thirteen
// selectors only `!#` produces. Those announce themselves.
//
// Two do not, and they are the ones pinned here:
//
//   * the history bucket. It stores one averaged row per minute. The old code
//     kept ONE bucket and closed it whenever the recording unit changed
//     mid-minute — which, once two units interleave, is true on nearly every
//     sample. One row a minute becomes one row a SAMPLE. The controller's own
//     note puts a full minute near 900 samples, so that is ~900x the writes,
//     with no error and nothing on screen. The only witness is the `samples`
//     column reading 1 on every row.
//
//   * log attribution. `_onPacket` stamped rows with whichever unit was
//     "current" rather than the unit the packet came from. That is FB-41/FB-42
//     exactly — a line went out under another unit's device/session pair and
//     the export minted a section header for a connection that never happened —
//     and those two were only just fixed in v0.6.13.
//
// Neither can happen today (one link at a time), which is the point: these
// tests hold the structure in place while it is still cheap, by feeding the
// controller two device ids directly. Behaviour with a single unit is unchanged
// and is covered by the existing suites.
//
// CLEAN-ROOM: expectations derive from our own source and our own field
// captures.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// BleService stub whose telemetry / packet / link streams a test can drive.
/// Nothing below reaches the plugin channel.
class _StubBle extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _packetsOut = StreamController<BlePacketEvent>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BlePacketEvent> get packets => _packetsOut.stream;

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
  void emitPacket(BlePacketEvent e) => _packetsOut.add(e);
  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _packetsOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('SessionContext holds one session PER UNIT', () {
    test('each unit keeps its own connection number', () {
      final s = SessionContext();
      s.begin('AA');
      final a = s.sessionId;
      s.begin('BB');
      final b = s.sessionId;

      expect(a, isNot(b));
      // The whole point: A's number is still retrievable while B is current.
      // Reading "the current session" for one of A's rows is what FB-41 was.
      expect(s.sessionIdFor('AA'), a);
      expect(s.sessionIdFor('BB'), b);
    });

    test('a unit that never had a session has no number to lend', () {
      final s = SessionContext();
      s.begin('AA');
      expect(s.sessionIdFor('CC'), isNull);
      expect(s.sessionIdFor(null), isNull,
          reason: '"no unit" is not a unit whose session can be looked up');
    });

    test('end() closes the current unit only', () {
      final s = SessionContext();
      s.begin('AA');
      final a = s.sessionId;
      s.begin('BB');
      s.end(); // ends BB, the current one
      expect(s.deviceId, isNull);
      expect(s.sessionId, isNull);
      expect(s.sessionIdFor('AA'), a,
          reason: "one unit dropping must not close another unit's session");
      expect(s.sessionIdFor('BB'), isNull);
    });
  });

  group('history buckets are keyed by unit', () {
    late AppDatabase db;
    late AppServices services;
    late _StubBle ble;

    setUp(() async {
      db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _StubBle();
      services = await AppServices.create(appDatabase: db, ble: ble);
    });

    tearDown(() async => services.dispose());

    TelemetrySample at(DateTime t, double v) =>
        TelemetrySample(timestamp: t, pvlt: v, twfRaw: 0x00);

    test('two units interleaved inside one minute yield TWO rows, not one per '
        'sample', () async {
      final session = services.connection.session;
      final tele = services.telemetry;
      final minute = DateTime.utc(2026, 8, 3, 12, 30);

      // Six samples alternating between two units, all inside one minute — the
      // round-robin shape multi-device sampling would produce.
      for (var i = 0; i < 3; i++) {
        session.begin('AA');
        ble.emitTelemetry(at(minute.add(Duration(seconds: i * 2)), 13.0));
        await Future<void>.delayed(Duration.zero);
        session.begin('BB');
        ble.emitTelemetry(at(minute.add(Duration(seconds: i * 2 + 1)), 12.0));
        await Future<void>.delayed(Duration.zero);
      }

      tele.flushPendingHistory();
      await services.pending.drain();

      final rows = await services.historyRepo.querySamplesWithDevice();
      expect(rows.length, 2,
          reason: 'one row per unit per minute — the shared bucket produced '
              'six, one per sample');

      final byDevice = {for (final r in rows) r.deviceId: r.sample};
      expect(byDevice.keys, containsAll(<String>['AA', 'BB']));
      // Each row averages only its own unit's readings. A row that mixed them
      // would land at 12.5.
      expect(byDevice['AA']!.pvlt, closeTo(13.0, 1e-9));
      expect(byDevice['BB']!.pvlt, closeTo(12.0, 1e-9));
    });

    test('the samples column counts each unit honestly', () async {
      // `samples` is the field that would have reported the degradation: three
      // samples folded per unit must read 3, not 1.
      final session = services.connection.session;
      final minute = DateTime.utc(2026, 8, 3, 12, 31);

      for (var i = 0; i < 3; i++) {
        session.begin('AA');
        ble.emitTelemetry(at(minute.add(Duration(seconds: i * 2)), 13.0));
        await Future<void>.delayed(Duration.zero);
        session.begin('BB');
        ble.emitTelemetry(at(minute.add(Duration(seconds: i * 2 + 1)), 12.0));
        await Future<void>.delayed(Duration.zero);
      }
      services.telemetry.flushPendingHistory();
      await services.pending.drain();

      final raw = await db.db.query('history', columns: ['device_id',
        'samples']);
      final byDevice = {
        for (final r in raw) r['device_id'] as String?: r['samples'] as int?
      };
      expect(byDevice['AA'], 3);
      expect(byDevice['BB'], 3);
    });

    test('a minute rollover still closes that unit\'s bucket, and only it',
        () async {
      final session = services.connection.session;
      final t0 = DateTime.utc(2026, 8, 3, 12, 40);

      session.begin('AA');
      ble.emitTelemetry(at(t0, 13.0));
      await Future<void>.delayed(Duration.zero);
      session.begin('BB');
      ble.emitTelemetry(at(t0, 12.0));
      await Future<void>.delayed(Duration.zero);

      // AA crosses into the next minute; BB does not.
      session.begin('AA');
      ble.emitTelemetry(at(t0.add(const Duration(minutes: 1)), 13.4));
      await Future<void>.delayed(Duration.zero);
      await services.pending.drain();

      var rows = await services.historyRepo.querySamplesWithDevice();
      expect(rows.length, 1, reason: "only AA's first minute has closed");
      expect(rows.single.deviceId, 'AA');

      services.telemetry.flushPendingHistory();
      await services.pending.drain();
      rows = await services.historyRepo.querySamplesWithDevice();
      expect(rows.length, 3, reason: "AA's second minute and BB's first follow");
    });

    test('a disconnect flushes every open bucket, not just the current one',
        () async {
      // The partial minute a unit loses because a different unit happened to be
      // current is exactly the loss `flushPendingHistory` exists to prevent.
      final session = services.connection.session;
      final minute = DateTime.utc(2026, 8, 3, 12, 50);

      session.begin('AA');
      ble.emitTelemetry(at(minute, 13.0));
      await Future<void>.delayed(Duration.zero);
      session.begin('BB');
      ble.emitTelemetry(at(minute, 12.0));
      await Future<void>.delayed(Duration.zero);

      ble.emitLink(BleLinkState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await services.pending.drain();

      final rows = await services.historyRepo.querySamplesWithDevice();
      expect(rows.map((r) => r.deviceId).toSet(), {'AA', 'BB'});
    });
  });

  group('log rows are attributed to the unit the packet came from', () {
    late AppDatabase db;
    late AppServices services;
    late _StubBle ble;

    setUp(() async {
      db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _StubBle();
      services = await AppServices.create(appDatabase: db, ble: ble);
      await services.settings.setRawPacketLog(true);
    });

    tearDown(() async => services.dispose());

    test("a packet naming its own link is NOT filed under whoever is current",
        () async {
      final session = services.connection.session;
      session.begin('AA');
      final aSession = session.sessionId;
      session.begin('BB');
      final bSession = session.sessionId;

      // BB is current; a frame arrives from AA. This is the FB-41 shape: under
      // the old code the row went out as device=BB, session=BB's number.
      ble.emitPacket(BlePacketEvent(LogDirection.rx, const [0xB8, 0x19],
          deviceId: 'AA'));
      ble.emitPacket(BlePacketEvent(LogDirection.rx, const [0xB8, 0x21],
          deviceId: 'BB'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await services.pending.drain();

      final rows = await services.logRepo.queryLog();
      final a = rows.firstWhere((e) => e.deviceId == 'AA');
      final b = rows.firstWhere((e) => e.deviceId == 'BB');
      expect(a.sessionId, aSession,
          reason: "AA's row must carry AA's connection number");
      expect(b.sessionId, bSession);
      expect(a.sessionId, isNot(b.sessionId));
    });

    test('a per-unit export no longer swallows the other unit as its own',
        () async {
      // The consequence of the above, at the surface the user sees: an export
      // scoped to AA must contain AA's frame and report BB's as excluded — not
      // silently absorb BB's row into AA's section.
      final session = services.connection.session;
      session.begin('AA');
      session.begin('BB');

      ble.emitPacket(BlePacketEvent(LogDirection.rx, const [0xB8, 0x19],
          deviceId: 'AA'));
      ble.emitPacket(BlePacketEvent(LogDirection.rx, const [0xB8, 0x21],
          deviceId: 'BB'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await services.pending.drain();

      final out = await services.logRepo
          .exportLog(deviceId: 'AA', header: const ['scope: AA']);
      expect(out, contains('rows: 1'));
      expect(out, contains('excluded: 1 rows from other devices'));
    });

    test('an event with no link to name keeps the ambient attribution',
        () async {
      // Scan-time and service-level lines have no device of their own; they
      // must behave exactly as before rather than become unattributed.
      final session = services.connection.session;
      session.begin('AA');

      ble.emitPacket(
          BlePacketEvent(LogDirection.event, const [], note: 'GATT dump'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await services.pending.drain();

      final row = (await services.logRepo.queryLog())
          .firstWhere((e) => e.note == 'GATT dump');
      expect(row.deviceId, 'AA');
      expect(row.sessionId, session.sessionId);
    });
  });

  // ---------------------------------------------------------------------------
  // The 0x38 MAC is the CONNECTED unit's address (design 0055 §7 Q2).
  //
  // It exists in memory at all because `setIdentity` writes to a SAVED record
  // and no-ops otherwise, which left the one device that most needs an identity
  // on screen — the unsaved one the user just tapped — with nothing to show. On
  // iOS it is the only real MAC obtainable: the platform id is an
  // install-scoped NSUUID.
  //
  // Which makes it exactly the kind of value FB-41/FB-42 were about, so what is
  // pinned here is that it dies with its link rather than lingering as a "last
  // known" under the next unit's name.
  // ---------------------------------------------------------------------------
  group('liveMac belongs to one link', () {
    late AppDatabase db;
    late AppServices services;
    late _StubBle ble;

    setUp(() async {
      db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _StubBle();
      services = await AppServices.create(appDatabase: db, ble: ble);
    });

    tearDown(() async => services.dispose());

    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await services.pending.drain();
    }

    test('0x38 fills it in, and a disconnect empties it', () async {
      final conn = services.connection;
      expect(conn.liveMac, isNull, reason: 'nothing has said one yet');

      services.connection.session.begin('AA');
      ble.emitTelemetry(TelemetrySample(
        timestamp: DateTime.utc(2026, 8, 11, 12),
        pvlt: 12.8,
        mac: '34:14:B5:B4:70:93',
        twfRaw: 0x00,
      ));
      await settle();
      expect(conn.liveMac, '34:14:B5:B4:70:93');

      ble.emitLink(BleLinkState.disconnected);
      await settle();
      expect(conn.liveMac, isNull,
          reason: 'a MAC that outlives its link ends up under the next '
              "unit's name — FB-41's mistake with a different field");
    });

    test('a sample with no MAC does not erase the one we have', () async {
      // 0x38 is not on every frame. Clearing on absence would make the subtitle
      // flicker between the address and "no advertised name" at frame rate.
      final conn = services.connection;
      services.connection.session.begin('AA');
      ble.emitTelemetry(TelemetrySample(
        timestamp: DateTime.utc(2026, 8, 11, 12),
        mac: '34:14:B5:B4:70:93',
        twfRaw: 0x00,
      ));
      await settle();
      ble.emitTelemetry(TelemetrySample(
        timestamp: DateTime.utc(2026, 8, 11, 12, 0, 1),
        pvlt: 12.8,
        twfRaw: 0x00,
      ));
      await settle();
      expect(conn.liveMac, '34:14:B5:B4:70:93');
    });
  });
}
