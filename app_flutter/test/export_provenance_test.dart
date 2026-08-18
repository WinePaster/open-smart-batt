// Export provenance + completeness (FB-10 / FB-11 / FB-12).
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
import 'package:open_smart_batt/theme/accent_theme.dart';
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
    const layout = 'face=standard modules=gaugeVoltage,readouts,cells';

    test('renders build, platform and scope', () {
      final lines = exportHeaderLines(
        title: 'OpenSmartBatt history export',
        exportedAt: at,
        appBuild: '0.6.8+26072812',
        platform: 'ios 18.5',
        scope: 'device=battery/1206',
        layout: layout,
        home: 'tiles=auto',
        // design 0063: a `required` param, so every direct caller has to name it. Personal is today's app.
        mode: AppMode.personal,
        themeMode: AppThemeMode.light,
        accent: AccentTheme.amber,
        speedDetection: false, gMeter: false,
        resolution: ExportResolution.none,
              // design 0070 stage two: the parameter lost its default, so this
        // header has to say what it names. Nothing here declares a unit.
        devices: const [],
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
        layout: layout,
        home: 'tiles=auto',
        // design 0063: a `required` param, so every direct caller has to name it. Personal is today's app.
        mode: AppMode.personal,
        themeMode: AppThemeMode.light,
        accent: AccentTheme.amber,
        speedDetection: false, gMeter: false,
        resolution: ExportResolution.none,
              // design 0070 stage two: the parameter lost its default, so this
        // header has to say what it names. Nothing here declares a unit.
        devices: const [],
      );
      expect(lines.any((l) => l.contains('connections')), isFalse);
    });

    test('keeps the diagnostic-log header shape byte-for-byte', () {
      // The diagnostic log had this preamble before the CSV did, and the shared
      // helper was extracted from it; recipients and our own analysis scripts
      // read the log's exact shape, so the extraction must not have altered a
      // single byte of it.
      //
      // Design 0034 §8 APPENDS one line here. The whole-list equality is kept
      // (not relaxed to a `containsAll`) precisely so that the next change to
      // this preamble has to be written down here too — the four original lines
      // are still asserted verbatim, in position, and the new one is asserted
      // verbatim as the last.
      //
      // Design 0042 §3.9 then added `speed detection:` in the optional middle,
      // and this is the test that made it show up: the equality did its job,
      // the line was written down, and the four original lines are STILL
      // verbatim in position. Do not relax it now either.
      //
      // Design 0046 Step 10 adds `home:`, also in the optional middle and also
      // written down here rather than absorbed by a looser matcher. `layout:`
      // is still last, which is the constraint the ingest scripts depend on.
      //
      // Design 0045 §3.7 adds `g meter:`, immediately after `speed detection:`
      // and for the identical reason — the equality caught it, so it is written
      // down. The two switch lines sit together because they answer the same
      // shape of question about two independent features (Q2), and a reader
      // scanning the middle should find them in one place.
      //
      // Design 0061 T4a (FB-71) adds `resolution:`, and here it is the SINGLE
      // `requested=n/a (no history rows)` form: the diagnostic log has no
      // history rows for a granularity to be about, and it says so rather than
      // omitting the line — a line that appears only when there is something to
      // say makes its absence mean both "nothing" and "an older build wrote
      // this" (FB-32). The equality caught it; it is written down.
      final lines = exportHeaderLines(
        title: 'OpenSmartBatt diagnostic log',
        exportedAt: at,
        appBuild: '0.6.8+26072812',
        platform: 'android 15',
        scope: 'device=capacitor/7809 session=3',
        layout: layout,
        home: 'tiles=auto',
        // design 0063: a `required` param, so every direct caller has to name it. Personal is today's app.
        mode: AppMode.personal,
        themeMode: AppThemeMode.light,
        accent: AccentTheme.amber,
        speedDetection: false, gMeter: false,
        resolution: ExportResolution.none,
        connections: 2,
              // design 0070 stage two: the parameter lost its default, so this
        // header has to say what it names. Nothing here declares a unit.
        devices: const [],
      );
      expect(lines, <String>[
        'OpenSmartBatt diagnostic log',
        'exported: ${at.toIso8601String()}',
        'scope: device=capacitor/7809 session=3  connections=2',
        'app: 0.6.8+26072812  platform: android 15',
        'resolution: requested=n/a (no history rows)',
        // design 0063. Directly above the two switch lines because it is what
        // makes their `off` readable: since 0063 they print the EFFECTIVE
        // value, so `off` means either "the user turned it off" or "advanced
        // mode withheld it", and only this line separates the two. Emitted for
        // `personal` too — FB-32's rule, one more time.
        // design 0066 §3.8. REQUIRED and emitted at zero — an export whose
        // owner has declared nothing still says so, because a block that
        // appeared only when somebody had answered would make its absence mean
        // both "nobody answered" and "an older build wrote this", and this
        // feature exists precisely to count how many people answer.
        'declared: count=0',
        'mode: personal',
        'speed detection: off',
        'g meter: off',
        // design 0064 §3.8 — added when the accent became user-chosen. This is
        // whole-list equality on purpose, so a new header line has to be written
        // in here by hand. Hex AND id: the DB stores the choice, this stores the
        // pixels the reporter's screenshot actually had.
        'theme: light accent=amber F6A821/46D4C8',
        'home: tiles=auto',
        'layout: face=standard modules=gaugeVoltage,readouts,cells',
      ]);
    });

    test('and keeps the CSV header shape byte-for-byte too', () {
      // The twin of the test above, added with the `ampere sign:` lines
      // (design 0056 follow-up, 2026-08-11). The CSV preamble had drifted two
      // lines away from the log's — `window:` (FB-60) and now these — with
      // nothing writing the difference down, so a change to the CSV shape could
      // land with every test still green. It cannot now.
      //
      // Same discipline as the log: whole-list equality, not `containsAll`, so
      // the NEXT line added to a CSV export has to be written here as well.
      //
      // Design 0061 T4a (FB-71) adds the `resolution:` PAIR, right after
      // `window:` because it answers the same shape of question: `requested=`
      // is what was asked for, `contains=` is what the file actually holds.
      // One line could not separate "I asked for seconds and got seconds
      // throughout" from "I asked for seconds and part of this only ever
      // existed as minute averages", and after FB-71 both are ordinary files.
      final lines = exportHeaderLines(
        title: 'OpenSmartBatt history export',
        exportedAt: at,
        appBuild: '0.6.8+26072812',
        platform: 'android 15',
        scope: 'device=battery/7809',
        window: 'all',
        ampereColumn: true,
        layout: layout,
        home: 'tiles=auto',
        // design 0063: a `required` param, so every direct caller has to name it. Personal is today's app.
        mode: AppMode.personal,
        themeMode: AppThemeMode.light,
        accent: AccentTheme.amber,
        speedDetection: false,
        gMeter: false,
        resolution:
            ExportResolution.forCsv(HistoryGranularity.second, const [1, 60]),
              // design 0070 stage two: the parameter lost its default, so this
        // header has to say what it names. Nothing here declares a unit.
        devices: const [],
      );
      expect(lines, <String>[
        'OpenSmartBatt history export',
        'exported: ${at.toIso8601String()}',
        'scope: device=battery/7809',
        'app: 0.6.8+26072812  platform: android 15',
        'window: all',
        'resolution: requested=1s',
        'resolution: contains=1s,60s',
        'ampere sign: battery negative=discharge positive=charge; '
            'power bank positive=discharge (0x4A-0x49)',
        'ampere sign: capacitor rows are blank - that unit cannot measure '
            'current',
        // design 0063 — see the log twin above. Both preambles carry it, in the
        // same place, which is the point of these two byte-for-byte lists.
        // design 0066 §3.8. REQUIRED and emitted at zero — an export whose
        // owner has declared nothing still says so, because a block that
        // appeared only when somebody had answered would make its absence mean
        // both "nobody answered" and "an older build wrote this", and this
        // feature exists precisely to count how many people answer.
        'declared: count=0',
        'mode: personal',
        'speed detection: off',
        'g meter: off',
        // design 0064 §3.8 — added when the accent became user-chosen. This is
        // whole-list equality on purpose, so a new header line has to be written
        // in here by hand. Hex AND id: the DB stores the choice, this stores the
        // pixels the reporter's screenshot actually had.
        'theme: light accent=amber F6A821/46D4C8',
        'home: tiles=auto',
        'layout: face=standard modules=gaugeVoltage,readouts,cells',
      ]);
    });
  });

  group('resolveBuildInfo', () {
    test('degrades to "unknown" instead of throwing', () async {
      // No plugin channel in a unit test. Neither an export nor recording may
      // fail because a version label could not be resolved. (Lives in
      // state/build_info.dart: it is resolved once at startup and stamped on
      // rows, not looked up per export, so the header and the rows cannot
      // disagree.)
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

      // Recording is unconditional — there is no longer a switch to turn on.
      ble.emitLink(BleLinkState.ready);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Three snapshots inside one WINDOW, then the app leaves the foreground
      // without any disconnect — the 2026-07-28 shape exactly. The window
      // became a second on 2026-08-14 (design 0061 T1), so the three snapshots
      // are 200 ms apart rather than 1 s: at ~4.8 Hz that is what "three
      // snapshots of the same moment" looks like on the wire.
      final second = DateTime(2026, 7, 28, 15, 51, 30);
      for (var i = 0; i < 3; i++) {
        ble.emitTelemetry(TelemetrySample(
          timestamp: second.add(Duration(milliseconds: i * 200)),
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
