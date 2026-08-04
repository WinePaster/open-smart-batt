// Per-device dashboard layout: storage, decoding discipline, migration
// (design 0034 Phase 3, tests T3 / T4 / T9 / T11).
//
// The invariant everything here defends is design 0034 G4: a user who never
// opens the setting must see the screen they saw yesterday. That is not a UI
// property — it is decided in three places BELOW the UI, and each of them can
// break it silently:
//
//   * the migration (a v9 row must come out of v10 with no layout at all),
//   * the decoder (garbage must become the default, not an exception on the
//     dashboard's build path),
//   * the binding (the layout must follow the DEVICE, which is the whole point
//     of Q3 — a setting that leaked across units would change a screen the
//     user never touched).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/device_controller.dart';
import 'package:open_smart_batt/ui/dashboard/display_modules.dart';
import 'package:open_smart_batt/ui/dashboard/watchfaces.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  // =========================================================================
  // The model: slugs are a wire format, and unknown content is a default
  // =========================================================================
  group('DisplayLayout encoding', () {
    test('every watchface round-trips through its stored JSON', () {
      for (final f in Watchface.values) {
        final layout = DisplayLayout(watchface: f);
        expect(DisplayLayout.decode(layout.encode()), layout);
      }
    });

    test('the slug is the enum name, so adding a face cannot renumber others',
        () {
      // Contrast an ordinal: inserting a face in the middle of the enum would
      // silently repoint every stored value. These strings are in databases and
      // in exported files, so they are a wire format.
      expect(Watchface.standard.slug, 'standard');
      expect(Watchface.compact.slug, 'compact');
      expect(Watchface.diagnostic.slug, 'diagnostic');
    });

    test('the default encodes the standard face and knows it is the default',
        () {
      expect(DisplayLayout.defaults.watchface, Watchface.standard);
      expect(DisplayLayout.defaults.isDefault, isTrue);
      expect(const DisplayLayout(watchface: Watchface.compact).isDefault,
          isFalse);
    });

    test('unknown keys are ignored, so interface C can add them without a '
        'migration', () {
      // Design 0034 §3: the reason this column holds JSON rather than a slug is
      // that the editor (Phase 7) must be able to add `primary` /
      // `complications` / `span` WITHOUT a schema change. A build that predates
      // those keys has to read past them, not fall over.
      final decoded = DisplayLayout.decode(
        '{"face":"compact","primary":"gaugeVoltage","complications":['
        '{"module":"readouts","span":"half"}]}',
      );
      expect(decoded.watchface, Watchface.compact);
    });
  });

  // T4 — a stored value this build cannot use must degrade silently.
  group('T4: unusable stored content falls back, and never throws', () {
    // Precedent: AppSettings._normaliseLogMaxBytes, where an unknown budget
    // lands on the default rather than leaving the segmented control blank.
    // This path is on the dashboard's build, so an exception here is a black
    // screen on the app's main page.
    const cases = <String, Object?>{
      'null column (pre-v10 row, or never customised)': null,
      'empty string': '',
      'not JSON at all': 'compact',
      'JSON, but not an object': '["compact"]',
      'JSON object, no face key': '{"primary":"readouts"}',
      'face is not a string': '{"face":7}',
      'retired or hand-typed slug': '{"face":"racing-stripes"}',
      'truncated write': '{"face":"comp',
      'wrong type entirely': 42,
    };

    cases.forEach((name, stored) {
      test('$name → defaults', () {
        expect(DisplayLayout.decode(stored), DisplayLayout.defaults);
      });
    });

    test('a bad row reaches the dashboard as the DEFAULT screen, not an error',
        () async {
      // End-to-end through the repo: the hand-edited database of §9 T4.
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      addTearDown(db.close);
      final repo = DeviceRepo(db.db);
      await repo.upsertSavedDevice(
          const SavedDevice(id: 'AA', alias: 'a', productClass: ProductClass.smartBattery));
      await db.db.update(
        Db.tableSavedDevices,
        {'display_layout': '{"face":"nope"}'},
        where: 'id = ?',
        whereArgs: ['AA'],
      );

      final device = await repo.getDevice('AA');
      expect(device!.displayLayout, DisplayLayout.defaults);
      // And the rest of the row is untouched — the fallback is scoped to the
      // one column, not "reset this device".
      expect(device.alias, 'a');
      expect(device.productClass, ProductClass.smartBattery);
    });
  });

  // T3 — rejection happens in the API layer, not in the widget that draws it.
  group('T3: an unusable layout is refused below the UI', () {
    test('an invalid slug can never become a Watchface', () {
      expect(Watchface.fromSlug('standard'), Watchface.standard);
      expect(Watchface.fromSlug('Standard'), isNull, reason: 'case matters');
      expect(Watchface.fromSlug('gaugeVoltage'), isNull);
      expect(Watchface.fromSlug(''), isNull);
      expect(Watchface.fromSlug(null), isNull);
    });

    test('no face can name a module its class does not have', () {
      // Design 0034 §4.3: an unavailable module is not "greyed out", it does
      // not exist for that class. Enforced structurally rather than by a UI
      // filter, so there is no code path — API or widget — that could offer it.
      for (final cls in ProductClass.values) {
        final available = DisplayModules.forClass(cls).modules;
        for (final face in Watchface.values) {
          for (final m in watchfaceModules(cls, face)) {
            expect(available, contains(m),
                reason: '$cls / ${face.slug} lists $m, which that class lacks');
          }
        }
      }
    });

    test('a power bank has no DVOL card on any face, and packs have no USB '
        'card', () {
      for (final face in Watchface.values) {
        expect(watchfaceModules(ProductClass.powerBank, face),
            isNot(contains(DisplayModule.cells)));
        for (final pack in [
          ProductClass.smartBattery,
          ProductClass.supercapacitor,
          ProductClass.unknown,
        ]) {
          expect(watchfaceModules(pack, face),
              isNot(contains(DisplayModule.usb)));
        }
      }
    });

    test('the chart is not placeable while Phase 1 is locked', () {
      // It is still a MODE of the readouts card (`_ModeToggle`), and that mode
      // is not persisted. Offering it as an orderable card would advertise
      // control the user does not have.
      for (final cls in ProductClass.values) {
        for (final face in Watchface.values) {
          expect(watchfaceModules(cls, face),
              isNot(contains(DisplayModule.chart)));
        }
      }
    });

    test('an unclassified unit is drawn with the standard face whatever is '
        'stored (Q4)', () {
      for (final f in Watchface.values) {
        expect(effectiveWatchface(ProductClass.unknown, f), Watchface.standard);
      }
      // Every other class honours the stored choice.
      for (final cls in [
        ProductClass.smartBattery,
        ProductClass.supercapacitor,
        ProductClass.powerBank,
      ]) {
        for (final f in Watchface.values) {
          expect(effectiveWatchface(cls, f), f);
        }
      }
    });
  });

  // =========================================================================
  // Persistence + the Q3 binding
  // =========================================================================
  group('DeviceRepo / DeviceController: the layout belongs to the device', () {
    late AppDatabase db;
    late DeviceRepo repo;
    late DeviceController devices;

    setUp(() async {
      db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      repo = DeviceRepo(db.db);
      devices = DeviceController(repo);
      await repo.upsertSavedDevice(const SavedDevice(id: 'AA', alias: 'cap'));
      await repo.upsertSavedDevice(const SavedDevice(id: 'BB', alias: 'batt'));
      await devices.load();
    });
    tearDown(() async => db.close());

    test('a saved device starts on the default layout', () {
      expect(devices.layoutFor('AA'), DisplayLayout.defaults);
    });

    test('changing one device leaves the other alone — THE point of Q3',
        () async {
      await devices.setDisplayLayout(
          'AA', const DisplayLayout(watchface: Watchface.diagnostic));
      expect(devices.layoutFor('AA').watchface, Watchface.diagnostic);
      expect(devices.layoutFor('BB'), DisplayLayout.defaults,
          reason: 'a dealer with one unit under investigation must not have '
              'every other unit rearranged');
    });

    test('switching devices switches layouts (the binding, read back)',
        () async {
      await devices.setDisplayLayout(
          'AA', const DisplayLayout(watchface: Watchface.compact));
      await devices.setDisplayLayout(
          'BB', const DisplayLayout(watchface: Watchface.diagnostic));
      // Read through a fresh controller: this must come off the DATABASE, not
      // out of a cache that happens to still be warm.
      final reloaded = DeviceController(DeviceRepo(db.db));
      await reloaded.load();
      expect(reloaded.layoutFor('AA').watchface, Watchface.compact);
      expect(reloaded.layoutFor('BB').watchface, Watchface.diagnostic);
    });

    test('an unsaved device reads as default and is not silently saved',
        () async {
      expect(devices.layoutFor('ZZ'), DisplayLayout.defaults);
      expect(devices.layoutFor(null), DisplayLayout.defaults);
      await devices.setDisplayLayout(
          'ZZ', const DisplayLayout(watchface: Watchface.compact));
      expect(devices.isSaved('ZZ'), isFalse,
          reason: 'a device the user declined to name must not appear in the '
              'saved list as a side effect of a display setting');
      expect(await repo.getDevice('ZZ'), isNull);
    });

    // T9 — restore defaults.
    test('T9: restoring defaults returns the row to its pre-customised state',
        () async {
      await devices.setDisplayLayout(
          'AA', const DisplayLayout(watchface: Watchface.diagnostic));
      await devices.setDisplayLayout('AA', DisplayLayout.defaults);
      expect(devices.layoutFor('AA'), DisplayLayout.defaults);
      // Stored as NULL, not as '{"face":"standard"}': the column has to keep
      // saying "never customised", which is what the Phase 7 editor will read.
      final row = await db.db
          .query(Db.tableSavedDevices, where: 'id = ?', whereArgs: ['AA']);
      expect(row.single['display_layout'], isNull);
    });

    test('the default is written as NULL on upsert too', () async {
      await repo.upsertSavedDevice(const SavedDevice(id: 'CC', alias: 'c'));
      final row = await db.db
          .query(Db.tableSavedDevices, where: 'id = ?', whereArgs: ['CC']);
      expect(row.single['display_layout'], isNull);
    });

    test('a non-default layout survives an upsert of the whole row', () async {
      const layout = DisplayLayout(watchface: Watchface.compact);
      await repo.upsertSavedDevice(
          const SavedDevice(id: 'AA', alias: 'cap', displayLayout: layout));
      expect((await repo.getDevice('AA'))!.displayLayout, layout);
    });

    test('setProductClass does not disturb the layout, and vice versa',
        () async {
      await devices.setDisplayLayout(
          'AA', const DisplayLayout(watchface: Watchface.compact));
      await devices.setProductClass('AA', ProductClass.supercapacitor);
      final d = await repo.getDevice('AA');
      expect(d!.displayLayout.watchface, Watchface.compact);
      expect(d.productClass, ProductClass.supercapacitor);
    });
  });

  // =========================================================================
  // T11 — the migration
  // =========================================================================
  group('T11: schema v9 → v10', () {
    test('adds display_layout, keeps every existing value, and old rows get '
        'the default', () async {
      // A real file: an in-memory DB is discarded on close, so the upgrade path
      // would never see the v9 data (same reason as the v6 test).
      final dir = await Directory.systemTemp.createTemp('osb_v10');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'v9.db');

      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 9,
          onCreate: (db, _) async {
            // The v9 saved_devices shape, written out by hand rather than
            // reused from _createStatements — a test that shares the DDL it is
            // verifying would pass no matter what the migration did.
            await db.execute('''
              CREATE TABLE saved_devices (
                id TEXT PRIMARY KEY,
                alias TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL DEFAULT '',
                last_seen INTEGER,
                last_value REAL,
                stale INTEGER NOT NULL DEFAULT 0,
                product_class TEXT NOT NULL DEFAULT 'unknown'
              )''');
            await db.execute('''
              CREATE TABLE history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL, pvlt REAL, svlt REAL, ampere REAL,
                temperature INTEGER, dvol1 REAL, dvol2 REAL, dvol3 REAL,
                dvol4 REAL, soh INTEGER, mode INTEGER, twf INTEGER,
                serial TEXT, soc INTEGER, device_id TEXT, samples INTEGER,
                app_build TEXT
              )''');
            await db.execute('''
              CREATE TABLE diag_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL, direction TEXT NOT NULL,
                hex TEXT NOT NULL, note TEXT, device_id TEXT,
                session_id INTEGER, app_build TEXT
              )''');
            await db.execute(
                'CREATE TABLE settings (id INTEGER PRIMARY KEY, theme_mode TEXT)');
          },
        ),
      );
      await legacy.insert('saved_devices', {
        'id': 'AA:BB',
        'alias': '電容 #1（前車）',
        'name': 'RCE-SCAP_II',
        'last_seen': 1754200000000,
        'last_value': 13.4,
        'stale': 0,
        'product_class': 'supercapacitor',
      });
      await legacy.insert('history', {'timestamp': 60000, 'pvlt': 12.5});
      await legacy.close();

      final upgraded =
          await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      addTearDown(upgraded.close);

      final rows = await upgraded.db.query('saved_devices');
      expect(rows, hasLength(1), reason: 'the upgrade must not drop data');
      expect(rows.single['display_layout'], isNull,
          reason: 'a pre-v10 row never chose a layout; NULL says so, and a '
              'written-in default would claim it did');

      // Every pre-existing column survives, value for value. A migration that
      // rebuilt the table instead of ALTERing it would pass a "column exists"
      // check and quietly lose the alias.
      final device = SavedDevice.fromMap(rows.single);
      expect(device.id, 'AA:BB');
      expect(device.alias, '電容 #1（前車）');
      expect(device.name, 'RCE-SCAP_II');
      expect(device.lastValue, 13.4);
      expect(device.productClass, ProductClass.supercapacitor);
      expect(device.displayLayout, DisplayLayout.defaults,
          reason: 'G4: an upgraded user sees exactly the screen they had');

      // The other tables are not collateral damage.
      expect(await upgraded.db.query('history'), hasLength(1));

      // And the upgraded column is writable — an ALTER that landed with the
      // wrong type would only show up here.
      await DeviceRepo(upgraded.db).setDisplayLayout(
          'AA:BB', const DisplayLayout(watchface: Watchface.diagnostic));
      expect(
        (await DeviceRepo(upgraded.db).getDevice('AA:BB'))!.displayLayout.watchface,
        Watchface.diagnostic,
      );
    });

    test('the version constant and the migration branch agree', () {
      // The registry in Db.schemaVersion's doc comment is the only place two
      // parallel branches would collide; this pins the number the migration
      // above was written against.
      expect(Db.schemaVersion, 10);
    });
  });
}
