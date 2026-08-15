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
      expect(Watchface.riding.slug, 'riding');
    });

    test('a build that predates riding reads it as the default, not a crash',
        () {
      // The downgrade direction of design 0034's zero-migration claim, and the
      // reason design 0042 needed no schema change for the face itself: a
      // `riding` slug written by this build lands on `defaults` in an older
      // one, through the same path an unknown slug has always taken.
      expect(Watchface.fromSlug('riding'), Watchface.riding);
      expect(Watchface.fromSlug('a-face-from-2027'), isNull);
      expect(DisplayLayout.decode('{"face":"a-face-from-2027"}'),
          DisplayLayout.defaults);
    });

    test('the default encodes the FIXED face and knows it is the default', () {
      // 🔴 Was `standard` until design 0051 (2026-08-09). The picker is gone
      // and `effectiveWatchface` resolves everything to `fixed`, so the default
      // is the face that is actually drawn — a default naming a face nobody
      // renders would be a second answer to "what does this device show".
      expect(DisplayLayout.defaults.watchface, Watchface.fixed);
      expect(DisplayLayout.defaults.isDefault, isTrue);
      expect(const DisplayLayout(watchface: Watchface.compact).isDefault,
          isFalse);
      // The SKELETON, which the ruling kept: every retired slug still
      // round-trips, so a row written by v0.7.10 is read back unchanged and no
      // migration is needed. It simply does not reach the screen.
      for (final f in Watchface.values) {
        expect(DisplayLayout.decode(DisplayLayout(watchface: f).encode()),
            DisplayLayout(watchface: f));
      }
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
        // 🔴 `?? packFallback`, not `?? {}`. A watchface is only ever laid out
        // inside a shell that routing already decided is a pack, and the class
        // it is handed has been through `packShellClass` — which maps an
        // unusable label to `unknown` on purpose. So `unknown` HERE means "a
        // pack we cannot label", and its card set is the fallback. Design 0050
        // D3 ("no class ⇒ no cards") is enforced on the home surface, which is
        // the only place a device can genuinely have no class.
        final available =
            (DisplayModules.forClass(cls) ?? DisplayModules.packFallback)
                .modules;
        for (final face in Watchface.values) {
          for (final m in watchfaceModules(cls, face)) {
            expect(available, contains(m),
                reason: '$cls / ${face.slug} lists $m, which that class lacks');
          }
        }
      }
    });

    test('a power bank has no DVOL card on any face, and packs have no '
        'energy-path card', () {
      for (final face in Watchface.values) {
        expect(watchfaceModules(ProductClass.powerBank, face),
            isNot(contains(DisplayModule.cells)));
        for (final pack in [
          ProductClass.smartBattery,
          ProductClass.supercapacitor,
          ProductClass.unknown,
        ]) {
          expect(watchfaceModules(pack, face),
              isNot(contains(DisplayModule.energyPath)));
        }
      }
    });

    test("the class's own card rides EVERY face, compact included "
        '(design 0035 Q2, generalised by design 0041)', () {
      // The energy-path row is the answer to "which way is it charging" — not
      // an optional detail — so it stays on all three faces. Design 0041 gave
      // the pack's per-cell card the same status for the same reason, so this
      // now reads as one rule instead of two opposite ones.
      for (final face in Watchface.values) {
        expect(watchfaceModules(ProductClass.powerBank, face),
            contains(DisplayModule.energyPath),
            reason: '${face.slug} must keep the energy-path row');
      }
      // 🔴 REVERSED 2026-08-05 (design 0041 Q1). This asserted the OPPOSITE —
      // "a pack compact still drops its extra card" — and that is precisely
      // what made `standard` and `compact` render identically on a pack with no
      // DVOL: `cells` was the only difference between them, and `cells` is the
      // one module a pack declares dataGated. The difference now sits on the
      // readouts grid, which never vanishes. See T2b, which is the general form
      // of this and the thing that stops it recurring on a fourth class.
      // 🔴 The class's own card is now DERIVED, not assumed to be `cells`.
      //
      // Design 0050 D5 took `cells` away from the capacitor, so that class has
      // no own card at all — a state this loop could not previously express.
      // Asking the registry keeps the assertion true for the next class that
      // gains or loses one, which is the whole point of T2b existing.
      for (final pack in [
        ProductClass.smartBattery,
        ProductClass.supercapacitor,
        ProductClass.unknown,
      ]) {
        final entry =
            DisplayModules.forClass(pack) ?? DisplayModules.packFallback;
        if (entry.has(DisplayModule.cells)) {
          expect(watchfaceModules(pack, Watchface.compact),
              contains(DisplayModule.cells),
              reason: "$pack compact keeps the class's own card");
        } else {
          expect(watchfaceModules(pack, Watchface.compact),
              isNot(contains(DisplayModule.cells)),
              reason: '$pack has no own card, so no face may name one');
        }
        expect(watchfaceModules(pack, Watchface.compact),
            isNot(contains(DisplayModule.readouts)),
            reason: '$pack compact is what drops the numbers grid');
      }
      expect(watchfaceModules(ProductClass.powerBank, Watchface.compact),
          isNot(contains(DisplayModule.readouts)),
          reason: 'the same rule, unchanged from design 0040 Q2');
    });

    // T2b (design 0041 §3.2) — the guard T2 could not be.
    //
    // T2 pins that the three faces return DIFFERENT LISTS. That is not enough,
    // and v0.7.4 proved it: a pack's `standard` and `compact` differed only by
    // `cells`, `cells` is dataGated, and a unit that never sends 0x24 rendered
    // the two faces as the same page with T2 green throughout.
    //
    // So: for every class and every PAIR of faces, the set-difference of their
    // modules must contain at least one module that is NOT dataGated — i.e. at
    // least one card that is guaranteed to be on the page to tell them apart.
    //
    // ⚠️ Sets, not lists, and that is deliberate: two faces differing only in
    // ORDER have no card to lose, so the difference between them can be erased
    // by absent data. Do not "simplify" this into a list comparison, and do not
    // delete it as a duplicate of T2 — T2 pins the lists, T2b pins that a
    // difference can actually be SEEN.
    // 🔴 T2b IS RETIRED by design 0051, and this is what replaces it.
    //
    // T2b asserted that every PAIR of faces differed by a card that cannot
    // vanish, because a face that renders as a copy of another face made the
    // picker offer three entries and deliver two screens (v0.7.2, from the
    // field). Owner ruling 2026-08-09 removed the picker, so nobody can land on
    // the wrong one of a pair — and it took both phone modules off `riding`,
    // which legitimately makes `riding` and `compact` the same list.
    //
    // Keeping T2b would mean putting a card back on `riding` that the ruling
    // took off it. What survives is the half of T2b that was never about
    // choosing: the ONE face that is drawn must have something on it that no
    // data gate can take away, or a unit that never sends 0x24 renders a page
    // with nothing but an instrument.
    test('the drawn face always has a non-data-gated card besides the gauge',
        () {
      for (final cls in ProductClass.values) {
        final dataGated =
            (DisplayModules.forClass(cls)?.dataGated ?? const <DisplayModule>{});
        final drawn = watchfaceModules(cls, Watchface.fixed).toSet();
        expect(drawn.difference(dataGated).length, greaterThanOrEqualTo(3),
            reason: '\$cls: the fixed face collapses to \${drawn.difference(dataGated)} '
                'on a unit that sends no gated data');
      }
    });

    // REWRITTEN 2026-08-05 (design 0034 Phase 1, implemented by design 0040).
    // This used to assert the chart was placeable on NO face, because it was
    // still a mode of the readouts card behind an unpersisted header toggle.
    // Phase 1 landed and the toggle is gone, so "no face at all" would now mean
    // the chart is unreachable by anyone — hence the assertion still exists,
    // but it names the ONE face that carries it.
    test('the chart is on the drawn face, and still not on the retired ones',
        () {
      for (final cls in ProductClass.values) {
        // Q4: an unclassified unit is drawn with the standard face whatever is
        // stored, but watchfaceModules itself answers per (class, face) — the
        // Q4 remap happens in effectiveWatchface, tested separately below.
        // 🔴 The FIXED face is the only page there is since design 0051, so
        // dropping the chart from it removes the live curve from the product.
        expect(watchfaceModules(cls, Watchface.fixed),
            contains(DisplayModule.chart));
        expect(watchfaceModules(cls, Watchface.diagnostic),
            contains(DisplayModule.chart),
            reason: 'retired but still parsed — the list is what an old '
                '`face=diagnostic modules=…` capture meant');
        // ⚠️ design 0040 Q1 was PROPOSED as "standard gets the chart, last",
        // implemented, and then REVERSED by the owner. The accepted cost is
        // that a user who never opens Settings has no live chart at all — they
        // used to reach it from the readouts card's own header toggle. This
        // assertion is that ruling, not an artefact of the old behaviour.
        expect(watchfaceModules(cls, Watchface.standard),
            isNot(contains(DisplayModule.chart)),
            reason: 'standard must stay byte-for-byte the pre-0040 list (G4)');
        expect(watchfaceModules(cls, Watchface.compact),
            isNot(contains(DisplayModule.chart)),
            reason: 'compact is the one-screenful face; a stack of tracks is '
                'the first thing it drops');
      }
    });

    test('EVERY unit is drawn with the fixed face, whatever is stored', () {
      // 📦 Was design 0034 Q4: an unclassified unit kept `standard` while every
      // other class honoured the stored choice. Q4's argument was that a screen
      // asking the user what the device is must not ALSO be rearranged under
      // them "by a preference carried over from another unit" — and design 0051
      // removed preferences. With nothing to carry over there is nothing to
      // protect against, and the special case collapses into the general one.
      for (final cls in ProductClass.values) {
        for (final f in Watchface.values) {
          expect(effectiveWatchface(cls, f), Watchface.fixed,
              reason: '\${cls.name} / \${f.slug}');
        }
      }
      // …and the stored value is NOT rewritten, which is what makes this a
      // rendering decision rather than a migration.
      expect(const DisplayLayout(watchface: Watchface.compact).watchface,
          Watchface.compact);
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
      // parallel branches would collide; this pins the current head. v10 added
      // display_layout (the migration above); v11 added saved_devices.mac /
      // serial (design 0027); v12 added nine columns at once — four on history
      // (speed/accel for design 0042+0044, g_long/g_lat reserved for 0045) and
      // five on settings (speed_detection/speed_unit for 0042, plus home_layout
      // reserved for design 0046 and g_meter_enabled/g_calibration for 0045).
      // v13 added settings.background_monitoring_ios (design 0047 Phase 1 —
      // its own default-off column; see ios_background_setting_test.dart).
      // That number is the one this line exists for: v12 was claimed by two
      // plans at once, and the collision was settled by merging them, so the
      // constant and the migration body have to move together.
      // v14 was data-only (log_max_bytes 20 MB → 100 MB). v15 added the
      // `device_facts` TABLE (design 0057) — the first new table since the
      // original schema, and a pure addition: no existing column moves, so
      // everything asserted above still reads back identically.
      // v16 added the `autoconnect_arm` TABLE (design 0060 / FB-67) — the same
      // shape of change as v15 and for the same kind of reason: a new fact that
      // has to survive, added without touching anything that already exists, so
      // every assertion above is unaffected. Its own migration is checked in
      // `autoconnect_arm_persistence_test.dart`, fresh schema against upgraded.
      // v17 added `history.bucket_s` (design 0061 / FB-71) — this one DOES touch
      // an existing table, but only by appending a column with a NOT NULL
      // DEFAULT, so every column asserted above keeps its name, type and value.
      // Its own migration is checked in `schema_v17_test.dart`.
      // v18 added `settings.app_mode` (design 0063) — a nullable column with NO
      // default on a table this test does not read, so again nothing above
      // moves. Its own migration is checked in `schema_v18_test.dart`.
      // Bump this in lockstep with Db.schemaVersion.
      expect(Db.schemaVersion, 18);
    });
  });
}
