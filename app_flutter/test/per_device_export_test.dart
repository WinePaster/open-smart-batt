// Per-device log/history attribution + identifiable exports.
//
// Covers the three things that can silently go wrong:
//   1. the v4→v5 migration (real users upgrade in place; losing or
//      mis-attributing their rows is unrecoverable),
//   2. scoping (a "this device" export must not leak another unit's rows, and
//      must not silently swallow the legacy unattributed ones either),
//   3. filenames (the raw device id is a MAC on Android — it must NEVER reach
//      a filename that gets shared).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/ui/util/export_naming.dart';
import 'package:open_smart_batt/ui/util/export_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase appDb;
  setUp(() async {
    appDb = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async => appDb.close());

  TelemetrySample sampleAt(int ms, {double? pvlt, int? soc}) => TelemetrySample(
        timestamp: DateTime.fromMillisecondsSinceEpoch(ms),
        pvlt: pvlt ?? 12.5,
        socPercent: soc,
      );

  group('schema v5 migration (v4 → v5)', () {
    // Builds the PRE-0006 schema by hand, fills it, then reopens at the current
    // version so the real _onUpgrade path runs.
    test('keeps old rows and leaves them unattributed', () async {
      // A real file, not `:memory:` — an in-memory DB is discarded on close, so
      // the upgrade path would never see the v4 data.
      final dir = await Directory.systemTemp.createTemp('osb_migrate');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'v4.db');
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL, pvlt REAL, svlt REAL, ampere REAL,
                temperature INTEGER, dvol1 REAL, dvol2 REAL, dvol3 REAL,
                dvol4 REAL, soh INTEGER, mode INTEGER, twf INTEGER, serial TEXT
              )''');
            await db.execute('''
              CREATE TABLE diag_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL, direction TEXT NOT NULL,
                hex TEXT NOT NULL, note TEXT
              )''');
            await db.execute('''
              CREATE TABLE saved_devices (
                id TEXT PRIMARY KEY, alias TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL DEFAULT '', last_seen INTEGER,
                last_value REAL, stale INTEGER NOT NULL DEFAULT 0,
                product_class TEXT NOT NULL DEFAULT 'unknown'
              )''');
            await db.execute('''
              CREATE TABLE settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                auto_reconnect INTEGER NOT NULL DEFAULT 1,
                poll_interval_ms INTEGER NOT NULL DEFAULT 1000,
                background_keep_alive INTEGER NOT NULL DEFAULT 0,
                dark_theme INTEGER NOT NULL DEFAULT 1, theme_mode TEXT,
                lang TEXT NOT NULL DEFAULT 'zhHant',
                temp_unit TEXT NOT NULL DEFAULT 'celsius',
                auto_log INTEGER NOT NULL DEFAULT 1,
                raw_packet_log INTEGER NOT NULL DEFAULT 0,
                log_max_bytes INTEGER NOT NULL DEFAULT ${5 * 1024 * 1024}
              )''');
          },
        ),
      );
      await legacy.insert('history', {'timestamp': 1000, 'pvlt': 12.1});
      await legacy.insert('diag_log', {
        'timestamp': 1000,
        'direction': 'rx',
        'hex': 'b820',
      });
      await legacy.close();

      final migrated =
          await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      addTearDown(migrated.close);

      final hist = await migrated.db.query('history');
      final logs = await migrated.db.query('diag_log');
      expect(hist, hasLength(1), reason: 'migration must not drop rows');
      expect(logs, hasLength(1));
      // Pre-v5 rows belong to an unknown unit — claiming otherwise would lie.
      expect(hist.single['device_id'], isNull);
      expect(hist.single['soc'], isNull);
      expect(logs.single['device_id'], isNull);
      expect(logs.single['session_id'], isNull);
      // Old values survive untouched.
      expect(hist.single['pvlt'], 12.1);
    });
  });

  group('HistoryRepo device scoping', () {
    test('scoped query returns only that unit; unscoped returns everything',
        () async {
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(sampleAt(1000), deviceId: 'AA');
      await repo.insertSample(sampleAt(2000), deviceId: 'BB');
      await repo.insertSample(sampleAt(3000)); // legacy / no device

      expect(await repo.querySamples(deviceId: 'AA'), hasLength(1));
      expect(await repo.querySamples(), hasLength(3));
      expect(await repo.distinctDeviceIds(), ['AA', 'BB']);
    });

    test('soc round-trips through the DB (was decoded but never stored)',
        () async {
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(sampleAt(1000, soc: 87), deviceId: 'AA');
      final back = await repo.querySamples();
      expect(back.single.socPercent, 87);
    });

    test('CSV appends soc + device without moving existing columns', () async {
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(sampleAt(1000, soc: 87), deviceId: 'AA');
      final csv = (await repo.exportCsv(labelFor: (id) => 'pack-$id')).text;
      // The csv package emits CRLF; compare on logical lines.
      final lines = csv.split(RegExp(r'\r?\n'));
      // The pre-0006 header must be a prefix of the new one.
      expect(
        lines.first.startsWith(
            'timestamp,pvlt,svlt,ampere,temperature,dvol1,dvol2,dvol3,dvol4,'
            'soh,mode,twf,serial'),
        isTrue,
      );
      // …and every later column is appended after it, never inserted:
      // `soc`/`device` (0006), `samples` (0009), `app_build` (0010).
      expect(lines.first, contains('serial,soc,device'));
      expect(HistoryRepo.csvColumns.sublist(0, 15), <String>[
        'timestamp', 'pvlt', 'svlt', 'ampere', 'temperature',
        'dvol1', 'dvol2', 'dvol3', 'dvol4',
        'soh', 'mode', 'twf', 'serial', 'soc', 'device',
      ]);
      expect(lines[1], contains('87'));
      expect(lines[1], contains('pack-AA'));
      // The raw id must not leak into the CSV when a label was supplied.
      expect(lines[1].contains(',AA,'), isFalse);
    });

    test('a capacitor exports no current — it cannot measure one', () async {
      // The unit streams 0x2E pinned at 0.0 A even though it has no current
      // sensor — the register's presence says nothing. The dashboard
      // hides that readout; exporting "0.0" would tell the recipient the pack
      // is drawing no current, which the device never claimed.
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(
        TelemetrySample(
            timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
            pvlt: 13.7,
            current: 0.0),
        deviceId: 'CAP',
      );
      await repo.insertSample(
        TelemetrySample(
            timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
            pvlt: 12.6,
            current: 1.5),
        deviceId: 'BATT',
      );

      final csv = (await repo.exportCsv(
        // Second granularity: the two fixture rows are 1 s apart, so a
        // per-minute export would file both under the same minute and this
        // test's row lookup — by exact ISO timestamp — would have nothing to
        // find. The rule being pinned (a capacitor's current cell is blank) is
        // per row and holds on both paths; the raw path is the one that can
        // address a single row.
        granularity: HistoryGranularity.second,
        classFor: (id) => id == 'CAP'
            ? ProductClass.supercapacitor
            : ProductClass.smartBattery,
      )).text;
      final lines = csv.split(RegExp(r'\r?\n'));
      // Rows are keyed by their timestamp, rendered in LOCAL time by the export.
      final capRow = lines.firstWhere((l) => l.startsWith(
          DateTime.fromMillisecondsSinceEpoch(1000).toIso8601String()));
      final battRow = lines.firstWhere((l) => l.startsWith(
          DateTime.fromMillisecondsSinceEpoch(2000).toIso8601String()));

      expect(battRow.split(',')[3], '1.5', reason: 'battery keeps its reading');
      // 'null' is this exporter's empty cell (same as the dvol columns).
      expect(capRow.split(',')[3], 'null',
          reason: 'capacitor current cell must be empty, not 0.0');
      // Only that one cell changes — the rest of the row is untouched.
      expect(capRow.split(',')[1], '13.7');
    });

    test('an unattributed row keeps its current (class unknown)', () async {
      // Pre-0006 rows have no device id, so we cannot know the class — editing
      // their data on a guess would be worse than leaving it.
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(TelemetrySample(
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000), current: 0.0));
      final csv = (await repo.exportCsv(
          classFor: (_) => ProductClass.supercapacitor)).text;
      expect(csv.split(RegExp(r'\r?\n'))[1].split(',')[3], '0.0');
    });

    test('unattributed rows get an empty device cell, never a guess', () async {
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(sampleAt(1000));
      final csv = (await repo.exportCsv(labelFor: (id) => 'pack-$id')).text;
      expect(csv.split(RegExp(r'\r?\n'))[1], isNot(contains('pack-')));
    });
  });


  // ---------------------------------------------------------------------------
  // The class that gates the current column has to work for a unit nobody named.
  //
  // A super-capacitor streams a permanent 0.0 A it cannot measure, so the export
  // blanks that column — and it decided whether to by reading the SAVED record
  // alone. That was safe only while "connected but not saved" was a dead end.
  // Design 0055 made it an ordinary way to use the app: connect, look, export,
  // never name it. On that path the class read `unknown`, the column was not
  // blanked, and the file stated 0.0 A as a measurement.
  // ---------------------------------------------------------------------------
  group('deviceClassFor: the live unit still has a class', () {
    late DeviceController devices;

    setUp(() async {
      devices = DeviceController(DeviceRepo(appDb.db));
      await devices.load();
    });

    test('a SAVED unit reads its stored class (unchanged)', () async {
      await devices.saveNew('CAP', 'Cap #1',
          productClass: ProductClass.supercapacitor);
      expect(deviceClassFor(devices, 'CAP'), ProductClass.supercapacitor);
    });

    test('an UNSAVED unit on the link takes the class off the wire', () {
      expect(deviceClassFor(devices, 'CAP'), ProductClass.unknown,
          reason: 'nothing stored, and no live pair offered');
      expect(
        deviceClassFor(devices, 'CAP',
            liveDeviceId: 'CAP', liveClass: ProductClass.supercapacitor),
        ProductClass.supercapacitor,
        reason: 'this is the unit on the link; the wire already said what it is',
      );
    });

    test('🔴 another unit on the link lends NOTHING', () {
      // The guard that keeps this from becoming FB-41 in a new column: the live
      // class describes ONE link, and applying it to a different unit's stored
      // rows would relabel history that was recorded from other hardware.
      expect(
        deviceClassFor(devices, 'OTHER',
            liveDeviceId: 'CAP', liveClass: ProductClass.supercapacitor),
        ProductClass.unknown,
      );
    });

    test('a stored class wins over the live one', () async {
      // Same precedence as `currentDeviceTarget`. Both are wire-derived, so this
      // is about having ONE answer rather than about trusting one more.
      await devices.saveNew('CAP', 'Cap #1',
          productClass: ProductClass.supercapacitor);
      expect(
        deviceClassFor(devices, 'CAP',
            liveDeviceId: 'CAP', liveClass: ProductClass.smartBattery),
        ProductClass.supercapacitor,
      );
    });

    test('an unattributed row (null id) stays unknown', () {
      expect(
        deviceClassFor(devices, null,
            liveDeviceId: 'CAP', liveClass: ProductClass.supercapacitor),
        ProductClass.unknown,
        reason: 'pre-0006 rows have no unit to be about — guessing is worse '
            'than leaving them alone',
      );
    });
  });

  group('LogRepo device/session scoping', () {
    test('filters by device and by session, and reports the max session id',
        () async {
      final repo = LogRepo(appDb.db);
      await repo.insertLog(LogEntry.event('a', deviceId: 'AA', sessionId: 1));
      await repo.insertLog(LogEntry.event('b', deviceId: 'AA', sessionId: 2));
      await repo.insertLog(LogEntry.event('c', deviceId: 'BB', sessionId: 3));
      await repo.insertLog(LogEntry.event('scan')); // outside a connection

      expect(await repo.queryLog(deviceId: 'AA'), hasLength(2));
      expect(await repo.queryLog(deviceId: 'AA', sessionId: 2), hasLength(1));
      expect(await repo.queryLog(), hasLength(4));
      expect(await repo.lastSessionId(), 3);
      expect(await repo.sessionCount(deviceId: 'AA'), 2);
    });

    test('export header is commented out so the line format is unchanged',
        () async {
      final repo = LogRepo(appDb.db);
      await repo.insertLog(LogEntry.event('hello', deviceId: 'AA'));
      final out = await repo.exportLog(header: const ['scope: device=AA']);
      final lines = out.split('\n');
      expect(lines.first, '# scope: device=AA');
      expect(lines.last, endsWith('EVT  # hello'));
    });

    test('a mixed export is separated per device and per connection', () async {
      // Without this, an all-devices export is ambiguous line by line: the rows
      // know their unit, the text did not. Exactly the problem that made the
      // TWF correlation in the pre-0006 logs unusable.
      final repo = LogRepo(appDb.db);
      await repo.insertLog(LogEntry.event('scan start')); // no connection yet
      await repo.insertLog(LogEntry.event('a1', deviceId: 'AA', sessionId: 1));
      await repo.insertLog(LogEntry.event('a2', deviceId: 'AA', sessionId: 1));
      await repo.insertLog(LogEntry.event('a3', deviceId: 'AA', sessionId: 2));
      await repo.insertLog(LogEntry.event('b1', deviceId: 'BB', sessionId: 3));

      final out = await repo.exportLog(
        labelFor: (id) => id == 'AA' ? 'front-cap' : 'rear-batt',
      );
      final separators =
          out.split('\n').where((l) => l.startsWith('# ----')).toList();
      expect(separators, [
        '# ---- device=unattributed ----',
        '# ---- device=front-cap session=1 ----',
        '# ---- device=front-cap session=2 ----',
        '# ---- device=rear-batt session=3 ----',
      ]);
      // Consecutive rows of the same unit+session share one separator.
      expect(out.split('\n').where((l) => l.endsWith('# a2')), hasLength(1));
    });

    test('an unlabelled device is hashed, never printed raw', () async {
      // The id is a MAC address on Android and this text gets shared.
      final repo = LogRepo(appDb.db);
      await repo
          .insertLog(LogEntry.event('x', deviceId: 'AA:BB:CC:DD:EE:FF', sessionId: 1));
      final out = await repo.exportLog();
      expect(out, isNot(contains('AA:BB:CC')));
      expect(out, contains(shortDeviceHash('AA:BB:CC:DD:EE:FF')));
    });
  });

  group('SessionContext', () {
    test('allocates a new id per connection and clears on disconnect', () {
      final s = SessionContext();
      s.begin('AA');
      expect(s.sessionId, 1);
      expect(s.deviceId, 'AA');
      s.end();
      expect(s.deviceId, isNull);
      expect(s.sessionId, isNull);
      s.begin('BB');
      expect(s.sessionId, 2);
    });

    test('re-entering the same device mid-session does not split it', () {
      final s = SessionContext()..begin('AA');
      s.begin('AA');
      expect(s.sessionId, 1);
    });

    test('seed keeps ids monotonic across restarts', () {
      final s = SessionContext()..seed(7);
      s.begin('AA');
      expect(s.sessionId, 8);
    });

    test('seed(null) on a fresh install starts at 1', () {
      final s = SessionContext()..seed(null);
      s.begin('AA');
      expect(s.sessionId, 1);
    });
  });

  group('export naming', () {
    test('prefers serial, then alias, then a hash — never the raw id', () {
      expect(
        deviceIdentFragment(serial: '12061F0A', alias: 'front', deviceId: 'AA'),
        '12061F0A',
      );
      expect(deviceIdentFragment(alias: 'front car', deviceId: 'AA'),
          'front-car');
      // A CJK-only alias sanitises to nothing → fall back to the hash, NOT the
      // device id (which is a MAC address on Android).
      final cjk = deviceIdentFragment(alias: '前車電容', deviceId: 'AA:BB:CC');
      expect(cjk, isNot(contains('AA')));
      expect(cjk, shortDeviceHash('AA:BB:CC'));
      expect(cjk, hasLength(8));
    });

    test('hash is stable and differs per device', () {
      expect(shortDeviceHash('AA'), shortDeviceHash('AA'));
      expect(shortDeviceHash('AA'), isNot(shortDeviceHash('BB')));
    });

    test('sanitise strips separators and caps the length', () {
      expect(sanitizeIdent('a/b\\c:d'), 'a-b-c-d');
      expect(sanitizeIdent('--lead and trail--'), 'lead-and-trail');
      expect(sanitizeIdent('x' * 40), hasLength(kMaxIdentLength));
      expect(sanitizeIdent('。。。'), '');
    });

    test('class slug is locale-independent', () {
      expect(productClassSlug(ProductClass.powerBank), 'powerbank');
      expect(productClassSlug(ProductClass.supercapacitor), 'capacitor');
      expect(productClassSlug(ProductClass.smartBattery), 'battery');
      expect(productClassSlug(null), 'unknown');
    });

    test('filename carries class + identity, and collapses when absent', () {
      expect(
        exportFileName(
          base: 'opensmartbatt',
          classSlug: 'battery',
          ident: '1206',
          stamp: '20260727-113000',
          extension: 'log',
        ),
        'opensmartbatt-battery-1206-20260727-113000.log',
      );
      // All-devices export keeps the pre-0006 name so existing recipients and
      // any tooling built on it keep working.
      expect(
        exportFileName(
          base: 'opensmartbatt-history',
          stamp: '20260727-113000',
          extension: 'csv',
        ),
        'opensmartbatt-history-20260727-113000.csv',
      );
    });
  });

  // The sheet is on-screen text, not a filename: it must agree with the device
  // filter sitting right above it, which shows the name the user chose.
  group('export scope sheet label', () {
    test('leads with the name and keeps the serial as confirmation', () {
      expect(
        exportScopeDeviceLabel(name: '阿明的機車', ident: '12061F0A'),
        '阿明的機車 · 12061F0A',
      );
    });

    test('unnamed unit reads exactly as before (identity fragment alone)', () {
      expect(exportScopeDeviceLabel(name: '', ident: '12061F0A'), '12061F0A');
      expect(exportScopeDeviceLabel(ident: '12061F0A'), '12061F0A');
      // Never named AND never connected long enough for a serial: the caller
      // passes the hash as the fragment, and it must survive to the sheet.
      expect(exportScopeDeviceLabel(name: '  ', ident: 'a3f1c2d4'), 'a3f1c2d4');
    });

    test('never prints the same string twice', () {
      expect(exportScopeDeviceLabel(name: '1206', ident: '1206'), '1206');
      expect(exportScopeDeviceLabel(name: 'front', ident: ''), 'front');
      expect(exportScopeDeviceLabel(name: 'front'), 'front');
    });
  });
}
