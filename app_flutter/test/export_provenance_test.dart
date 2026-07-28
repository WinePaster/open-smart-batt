// design 0009 — export provenance + completeness (FB-10 / FB-11 / FB-12).
//
// The 2026-07-28 field report could only be dated by noticing its CSV was
// missing two columns, and it silently lost its last 37 seconds of data. Three
// things must therefore hold, and each is easy to regress:
//
//   1. an export states which build/platform/scope produced it, and how much
//      data it actually contains,
//   2. "nothing to export" is decided by the ROW COUNT — with a preamble the
//      text is never empty, so the old `contains('\n')` check silently passed,
//   3. leaving the foreground persists the minute in progress.
import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Minimal BleService stub: the controller only needs the three streams and a
/// connected id for attribution.
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
  String? get connectedDeviceId => 'STUB-DEV';

  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);
  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('exportHeaderLines (pure)', () {
    final at = DateTime.utc(2026, 7, 28, 18, 11, 54);

    test('renders build, platform and scope', () {
      final lines = exportHeaderLines(
        title: 'OpenSmartBatt history export',
        exportedAt: at,
        appBuild: '0.6.8+26072812',
        platform: 'ios 18.5',
        scope: 'device=battery/1206',
      );
      expect(lines.first, 'OpenSmartBatt history export');
      expect(lines, contains('exported: ${at.toIso8601String()}'));
      expect(lines, contains('scope: device=battery/1206'));
      expect(lines, contains('app: 0.6.8+26072812  platform: ios 18.5'));
    });

    test('omits connections entirely when absent, rather than rendering blank', () {
      // A trailing `connections=` reads as a bug, not as "not applicable".
      final lines = exportHeaderLines(
        title: 't',
        exportedAt: at,
        appBuild: 'b',
        platform: 'p',
        scope: 'all devices',
      );
      expect(lines.any((l) => l.contains('connections')), isFalse);
    });

    test('keeps the diagnostic-log header shape byte-for-byte', () {
      // The log preamble predates this refactor (design 0006 §3.6); recipients
      // and our own triage scripts read it, so the shared helper must not have
      // changed it.
      final lines = exportHeaderLines(
        title: 'OpenSmartBatt diagnostic log',
        exportedAt: at,
        appBuild: '0.6.8+26072812',
        platform: 'android 15',
        scope: 'device=capacitor/7809 session=3',
        connections: 2,
      );
      expect(lines, <String>[
        'OpenSmartBatt diagnostic log',
        'exported: ${at.toIso8601String()}',
        'scope: device=capacitor/7809 session=3  connections=2',
        'app: 0.6.8+26072812  platform: android 15',
      ]);
    });
  });

  group('resolveBuildInfo', () {
    test('degrades to "unknown" instead of throwing', () async {
      // No plugin channel in a unit test. Neither an export nor recording may
      // fail because a version label could not be resolved. (Lives in
      // state/build_info.dart since design 0010 — it is resolved once at
      // startup and stamped on rows, not looked up per export.)
      final env = await resolveBuildInfo();
      expect(env.build, kUnknownEnv);
      expect(env.platform, isNotEmpty);
    });
  });

  group('CSV preamble + row count', () {
    late AppDatabase appDb;
    setUp(() async {
      appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
    });
    tearDown(() async => appDb.close());

    TelemetrySample sampleAt(int ms) => TelemetrySample(
          timestamp: DateTime.fromMillisecondsSinceEpoch(ms),
          pvlt: 12.5,
        );

    test('preamble precedes the column header and every line is commented',
        () async {
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(sampleAt(60000), deviceId: 'AA', samples: 900);
      final out = await repo.exportCsv(header: const ['title', 'app: x']);
      final lines = out.text.split(RegExp(r'\r?\n'));

      final headerEnd = lines.indexWhere((l) => !l.startsWith('#'));
      expect(headerEnd, greaterThan(0), reason: 'a preamble must be present');
      expect(lines.take(headerEnd).every((l) => l.startsWith('# ')), isTrue);
      expect(lines[headerEnd], HistoryRepo.csvColumns.join(','),
          reason: 'the column header must survive intact, just moved down');
    });

    test('summary reports rows, range and device count', () async {
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(sampleAt(60000), deviceId: 'AA', samples: 900);
      await repo.insertSample(sampleAt(120000), deviceId: 'BB', samples: 237);
      final out = await repo.exportCsv(header: const ['t']);
      final summary =
          out.text.split(RegExp(r'\r?\n')).firstWhere((l) => l.contains('rows:'));

      expect(summary, contains('rows: 2'));
      expect(summary, contains('devices: 2'));
      expect(
        summary,
        contains(DateTime.fromMillisecondsSinceEpoch(60000).toIso8601String()),
        reason: 'the range must start at the OLDEST row',
      );
    });

    test('unattributed rows are flagged in the summary, not counted as a device',
        () async {
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(sampleAt(60000), deviceId: 'AA');
      await repo.insertSample(sampleAt(120000)); // pre-0006 row, no device
      final out = await repo.exportCsv(header: const ['t']);
      final summary =
          out.text.split(RegExp(r'\r?\n')).firstWhere((l) => l.contains('rows:'));
      expect(summary, contains('devices: 1'));
      expect(summary, contains('+unattributed'));
    });

    test('rows == 0 is how an empty export is detected', () async {
      // THE regression this guards: with a preamble the text is never empty and
      // never lacks a newline, so both old emptiness checks would pass and the
      // user would be handed a file containing only a header.
      final repo = HistoryRepo(appDb.db);
      final out = await repo.exportCsv(header: const ['title']);
      expect(out.rows, 0);
      expect(out.text, contains('\n'),
          reason: 'the old !contains("\\n") check would now be wrong');
      expect(out.text.trim(), isNotEmpty,
          reason: 'the old trim().isEmpty check would now be wrong too');
    });

    test('no header means no preamble — the pre-0009 shape is unchanged', () async {
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(sampleAt(60000));
      final out = await repo.exportCsv();
      expect(out.text.startsWith(HistoryRepo.csvColumns.join(',')), isTrue);
    });

    test('samples is appended after the 0006 columns and round-trips', () async {
      // Pinned by POSITION RELATIVE to what came before, not by "is last" —
      // later designs append further columns (0010 added app_build), and this
      // test should only fail if an existing column actually moved.
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(sampleAt(60000), deviceId: 'AA', samples: 237);
      final cols = HistoryRepo.csvColumns;
      expect(cols.indexOf('samples'), cols.indexOf('device') + 1);
      final out = await repo.exportCsv();
      final lines = out.text.split(RegExp(r'\r?\n'));
      expect(lines[1].split(',')[cols.indexOf('samples')], '237');
    });
  });

  group('schema v6 migration (v5 → v6)', () {
    test('adds samples, leaves pre-v6 rows null and readable', () async {
      // A real file: an in-memory DB is discarded on close, so the upgrade path
      // would never see the v5 data.
      final dir = await Directory.systemTemp.createTemp('osb_v6');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'v5.db');
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 5,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL, pvlt REAL, svlt REAL, ampere REAL,
                temperature INTEGER, dvol1 REAL, dvol2 REAL, dvol3 REAL,
                dvol4 REAL, soh INTEGER, mode INTEGER, twf INTEGER,
                serial TEXT, soc INTEGER, device_id TEXT
              )''');
            await db.execute('''
              CREATE TABLE diag_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL, direction TEXT NOT NULL,
                hex TEXT NOT NULL, note TEXT, device_id TEXT, session_id INTEGER
              )''');
            await db.execute('''
              CREATE TABLE saved_devices (
                id TEXT PRIMARY KEY, alias TEXT, name TEXT NOT NULL DEFAULT '',
                stale INTEGER NOT NULL DEFAULT 0,
                product_class TEXT NOT NULL DEFAULT 'unknown'
              )''');
            await db.execute(
                'CREATE TABLE settings (id INTEGER PRIMARY KEY, theme_mode TEXT)');
          },
        ),
      );
      await legacy.insert('history', {
        'timestamp': 60000,
        'pvlt': 12.5,
        'device_id': 'AA',
      });
      await legacy.close();

      final upgraded =
          await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      addTearDown(upgraded.close);
      final rows = await upgraded.db.query('history');

      expect(rows, hasLength(1), reason: 'the upgrade must not drop data');
      expect(rows.single['pvlt'], 12.5);
      expect(rows.single['samples'], isNull,
          reason: 'a pre-v6 row does not know its count — leave it blank');
    });
  });

  group('flushPendingHistory (FB-11)', () {
    test('persists the minute in progress, tagged with its sample count',
        () async {
      final ble = _StubBle();
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final services = await AppServices.create(appDatabase: db, ble: ble);
      addTearDown(() async {
        await services.dispose();
      });

      // Recording is unconditional since design 0011 — no switch to turn on.
      ble.emitLink(BleLinkState.ready);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Three snapshots inside one minute, then the app leaves the foreground
      // without any disconnect — the 2026-07-28 shape exactly.
      final minute = DateTime(2026, 7, 28, 15, 51);
      for (var i = 0; i < 3; i++) {
        ble.emitTelemetry(TelemetrySample(
          timestamp: minute.add(Duration(seconds: i)),
          pvlt: 12.0 + i,
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await services.historyRepo.count(), 0,
          reason: 'nothing is written until the bucket closes');

      services.telemetry.flushPendingHistory();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final rows = await services.historyRepo.querySamples();
      expect(rows, hasLength(1));
      expect(rows.single.pvlt, closeTo(13.0, 1e-9),
          reason: 'the row carries the average of the three snapshots');

      final raw = await db.db.query('history');
      expect(raw.single['samples'], 3,
          reason: 'the count is what makes a truncated minute recognisable');
    });

    test('is a no-op when no minute is open', () async {
      final ble = _StubBle();
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final services = await AppServices.create(appDatabase: db, ble: ble);
      addTearDown(() async {
        await services.dispose();
      });

      services.telemetry.flushPendingHistory();
      services.telemetry.flushPendingHistory();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await services.historyRepo.count(), 0);
    });
  });
}
