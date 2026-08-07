// The home page's stored layout (design 0046 §4.2, T-new-1 and T-new-2).
//
// T-new-1 — the home page NEVER contains the protection card. Design 0034 §6
// made that an invariant enforced structurally: there is no `DisplayModule` for
// the control card, so nothing that names a `DisplayModule` can place one. Home
// tiles name a `DisplayModule`. The test below is therefore a check that the
// STRUCTURE is still the structure — that the vocabulary has not quietly grown
// a member for controls — rather than a check on any rendering path.
//
// T-new-2 — the generated layout is never empty, and unreadable storage falls
// back to it rather than to a blank page. The home page is the app's default
// entry point since design 0046 R3, so "empty" here means "the app opens on a
// blank screen".
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

SavedDevice _dev(String id, {ProductClass cls = ProductClass.smartBattery}) =>
    SavedDevice(id: id, alias: id, productClass: cls);

/// The part of a default layout that is about the DEVICES.
///
/// `defaultFor` also seeds the phone's own modules (speed, G) — see the
/// "the phone's own modules are in the default layout" test for why. The
/// assertions about device tiles below are about device tiles, so they say so
/// rather than counting everything and hoping the total never changes.
List<HomeTile> _deviceTiles(HomeLayout l) => [
      for (final t in l.tiles)
        if (t.module == null || !t.module!.isPhoneModule) t,
    ];

void main() {
  setUpAll(sqfliteFfiInit);

  group('T-new-1: no DisplayModule is the protection card', () {
    test('the vocabulary has no member for controls', () {
      // The names are wire values (they are printed into export preambles), so
      // this is also the list a reader of a capture sees. A member added for
      // the protection card would show up here first.
      final names = [for (final m in DisplayModule.values) m.name];
      expect(names, [
        'gaugeVoltage',
        'gaugeSoc',
        'readouts',
        'chart',
        'cells',
        'energyPath',
        'speed',
        'gForce',
      ]);
      for (final n in names) {
        expect(n.toLowerCase(), isNot(contains('control')));
        expect(n.toLowerCase(), isNot(contains('protect')));
        expect(n.toLowerCase(), isNot(contains('cutoff')));
      }
    });

    test('a module tile can only ever name one of them', () {
      // The type is the enforcement. This asserts the field kept it — a change
      // to `String` would compile everywhere and silently make `'controls'` a
      // placeable tile.
      const tile = HomeTile.module(DisplayModule.readouts, deviceId: 'A');
      expect(tile.module, isA<DisplayModule>());
      expect(DisplayModule.values, contains(tile.module));
    });

    test('an unknown module name decodes to nothing, not to a stray tile', () {
      final layout = HomeLayout.decode(
          '{"tiles":[{"kind":"module","module":"protectionControls",'
          '"span":"full"}]}');
      expect(layout, isNull,
          reason: 'a name outside the vocabulary is dropped; the whole layout '
              'then has no readable tiles, which is "never set"');
    });
  });

  group('T-new-2: the generated layout is never empty', () {
    test('zero devices still gets a tile', () {
      final l = HomeLayout.defaultFor(const []);
      expect(l.tiles, isNotEmpty);
      expect(l.tiles.first.kind, HomeTileKind.addDevice);
      expect(_deviceTiles(l), hasLength(1));
    });

    test('one device gets its card, its instrument and its numbers', () {
      final l = HomeLayout.defaultFor([_dev('A')]);
      final own = _deviceTiles(l);
      expect(own, hasLength(3));
      // 🔴 The card is FIRST and it is not decoration. The two module tiles
      // read live telemetry, so with nothing connected they both render as
      // `_WaitingTile` and the page says `--` twice; this tile reads
      // `saved_devices` and says the unit's name, its last voltage and how
      // long ago. Added 2026-08-07 after the offline page was photographed.
      expect(own[0].kind, HomeTileKind.deviceCard);
      expect(own[1].module, DisplayModule.gaugeVoltage);
      expect(own[2].module, DisplayModule.readouts);
      expect(own.every((t) => t.deviceId == 'A'), isTrue);
    });

    test('🔴 the default layout always has something to say when offline', () {
      // The general form of the rule above, and the one worth keeping: for
      // EVERY device count, at least one tile draws from stored state rather
      // than from a live link. Without it the app's default entry point is
      // blank whenever the unit is out of range, which is most of the time.
      for (final n in [0, 1, 2, 5]) {
        final l = HomeLayout.defaultFor(
            [for (var i = 0; i < n; i++) _dev('D\$i')]);
        final offlineCapable = l.tiles.where((t) =>
            t.kind == HomeTileKind.deviceCard ||
            t.kind == HomeTileKind.addDevice);
        expect(offlineCapable, isNotEmpty, reason: 'with \$n device(s)');
      }
    });

    test('a single power bank gets the SOC ring, not the rail', () {
      // The same rule `watchfaces.dart` applies. Getting it wrong here is FB-43
      // in a new place: a single cell's 3.79 V drawn on a 12 V pack dial.
      final l =
          HomeLayout.defaultFor([_dev('A', cls: ProductClass.powerBank)]);
      final own = _deviceTiles(l);
      expect(own[0].kind, HomeTileKind.deviceCard);
      expect(own[1].module, DisplayModule.gaugeSoc);
    });

    test('N devices get one card each', () {
      for (final n in [2, 3, 5]) {
        final l = HomeLayout.defaultFor(
            [for (var i = 0; i < n; i++) _dev('D$i')]);
        final own = _deviceTiles(l);
        expect(own, hasLength(n));
        expect(own.every((t) => t.kind == HomeTileKind.deviceCard), isTrue);
        expect([for (final t in own) t.deviceId],
            [for (var i = 0; i < n; i++) 'D$i']);
      }
    });

    test('🔴 the phone\'s own modules are in the default layout', () {
      // The field-test defect (2026-08-07): a rider turned speed and the G
      // meter on, went to 主頁, and found neither card. `defaultFor` had only
      // ever produced device tiles — the phone's own measurements existed on
      // the riding watchface and nowhere else, so the switch appeared to do
      // nothing at the surface the app opens on.
      //
      // They go into EVERY branch unconditionally, including the no-devices
      // one. `renderedFor` is what removes the ones whose feature is off, so
      // seeding them here is not a claim that they are available — it is the
      // claim that they are the user's to arrange, which is what the editor
      // then lets them do.
      for (final devices in [
        <SavedDevice>[],
        [_dev('A')],
        [_dev('A'), _dev('B')],
      ]) {
        final modules = {
          for (final t in HomeLayout.defaultFor(devices).tiles)
            if (t.module?.isPhoneModule ?? false) t.module,
        };
        expect(modules, {DisplayModule.speed, DisplayModule.gForce},
            reason: 'with ${devices.length} device(s)');
      }
    });

    test('decode treats four kinds of unusable storage as "never set"', () {
      for (final bad in <Object?>[
        null,
        '',
        'not json at all',
        '[]',
        '{"tiles":[]}',
        '{"tiles":"nope"}',
        '{}',
        '{"tiles":[{"kind":"deviceCard"}]}', // a device card with no device
        '{"tiles":[{"kind":"whatIsThis"}]}',
      ]) {
        expect(HomeLayout.decode(bad), isNull, reason: 'input: $bad');
      }
    });

    test('a readable layout round-trips', () {
      final l = HomeLayout([
        const HomeTile.addDevice(),
        const HomeTile.device('A'),
        const HomeTile.module(DisplayModule.speed, span: HomeSpan.half),
        const HomeTile.module(DisplayModule.gaugeSoc,
            deviceId: 'B', span: HomeSpan.half),
      ]);
      final back = HomeLayout.decode(l.encode());
      expect(back, isNotNull);
      expect(back, l);
    });

    test('a partly-unreadable layout keeps the tiles it can read', () {
      final l = HomeLayout.decode('{"tiles":['
          '{"kind":"module","module":"readouts","span":"full"},'
          '{"kind":"module","module":"fromTheFuture","span":"full"}'
          ']}');
      expect(l, isNotNull);
      expect(l!.tiles, hasLength(1));
      expect(l.tiles.single.module, DisplayModule.readouts);
    });
  });

  group('rows: the flat list packs the way design 0046 §3.3 describes',
      () {
    test('two consecutive halves share a row, a full owns one', () {
      final l = HomeLayout(const [
        HomeTile.module(DisplayModule.speed, span: HomeSpan.half),
        HomeTile.module(DisplayModule.readouts, span: HomeSpan.half),
        HomeTile.device('A'),
        HomeTile.module(DisplayModule.chart, span: HomeSpan.half),
      ]);
      final rows = l.rows;
      expect(rows, hasLength(3));
      expect(rows[0], hasLength(2));
      expect(rows[1], hasLength(1));
      // An orphan half keeps the left of its own row.
      expect(rows[2], hasLength(1));
      expect(rows[2].single.span, HomeSpan.half);
    });
  });

  // ==========================================================================
  // The column has a writer now, and that is the whole reason to test it
  // ==========================================================================
  //
  // 🔴 `SettingsRepo.saveSettings` writes with `ConflictAlgorithm.replace`,
  // which is `INSERT OR REPLACE`: SQLite DELETEs the whole row and inserts a new
  // one. A column missing from `AppSettings.toMap()` therefore does not merely
  // fail to persist — it ERASES ITSELF LATER, the next time the user changes any
  // other setting, at a moment unrelated to whatever wrote it. `home_layout`
  // shipped in design 0042's v12 migration with no writer at all, so it spent a
  // release in exactly that state.
  group('settings.home_layout persists', () {
    Future<SettingsController> boot() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final c = SettingsController(SettingsRepo(db.db));
      await c.load();
      return c;
    }

    test('a stored layout survives an unrelated settings change', () async {
      final c = await boot();
      final encoded = HomeLayout(const [
        HomeTile.device('A'),
        HomeTile.module(DisplayModule.speed, span: HomeSpan.half),
      ]).encode();

      await c.setHomeLayout(encoded);
      expect(c.homeLayout, encoded);

      // The unrelated change. Before `home_layout` joined `toMap()`, THIS is
      // the line that would have wiped it.
      await c.setThemeMode(AppThemeMode.dark);
      await c.load();

      expect(c.homeLayout, encoded);
      expect(HomeLayout.decode(c.homeLayout), isNotNull);
    });

    test('restore-defaults writes NULL, not a snapshot', () async {
      final c = await boot();
      await c.setHomeLayout(HomeLayout.defaultFor([_dev('A')]).encode());
      await c.setHomeLayout(null);
      await c.load();
      expect(c.homeLayout, isNull,
          reason: 'NULL means "generate it from the devices I have", which is '
              'what makes a unit saved next week appear by itself');
    });

    test('a fresh install has none', () async {
      final c = await boot();
      expect(c.homeLayout, isNull);
      expect(c.settings.toMap().containsKey('home_layout'), isTrue,
          reason: 'the key must be PRESENT and null — an absent key is what '
              'INSERT OR REPLACE turns into silent data loss');
    });
  });

  // ---------------------------------------------------------------------------
  // W-1 (2026-08-07 交付一查核): deleting a device used to leave an unremovable
  // empty card. The fix filters the VIEW and leaves storage alone, so these two
  // tests are a pair — either half alone is a different, worse design.
  // ---------------------------------------------------------------------------
  group('W-1: a deleted device leaves no ghost, and no scorched earth', () {
    SavedDevice dev(String id) => SavedDevice(id: id, alias: id, name: id);
    const on = AppSettings.defaults;

    test('a tile whose device is gone is not drawn', () {
      final layout = HomeLayout(const [
        HomeTile.device('DEV-A'),
        HomeTile.device('DEV-B'),
      ]);
      final visible = layout.renderedFor([dev('DEV-A')], on, gForceAvailable: true);
      expect(visible.tiles.map((t) => t.deviceId), ['DEV-A']);
    });

    test('storage is untouched, so the card returns with the device', () {
      final layout = HomeLayout(const [
        HomeTile.device('DEV-A'),
        HomeTile.device('DEV-B'),
      ]);
      // The user's arrangement survives the absence...
      expect(layout.renderedFor([dev('DEV-A')], on, gForceAvailable: true).tiles, hasLength(1));
      // ...and comes back intact when the unit does. This is the half that
      // rules out "prune by rewriting the stored layout": an iOS NSUUID
      // rotation removes and re-adds a device without anybody asking.
      final back = layout.renderedFor([dev('DEV-A'), dev('DEV-B')], on, gForceAvailable: true);
      expect(back.tiles.map((t) => t.deviceId), ['DEV-A', 'DEV-B']);
    });

    test('phone-owned tiles are never pruned AS GHOSTS', () {
      // They answer to their own switch (see the privacy test below), but the
      // device list must never remove them — they belong to the phone, and
      // deleting every unit does not delete the speedometer.
      final layout = HomeLayout(const [
        HomeTile.module(DisplayModule.speed),
        HomeTile.device('DEV-GONE'),
      ]);
      final visible = layout.renderedFor(
          [], on.copyWith(speedDetection: true), gForceAvailable: true);
      expect(visible.tiles.any((t) => t.module == DisplayModule.speed), isTrue,
          reason: 'speed belongs to the phone, not to any unit');
    });

    test('an all-ghost layout falls back to the default, never to empty', () {
      // T-new-2 forbids an empty page outright, and "every card you had names
      // a device you deleted" is a real path to one.
      final layout = HomeLayout(const [HomeTile.device('DEV-GONE')]);
      expect(layout.renderedFor([dev('DEV-NEW')], on, gForceAvailable: true).tiles, isNotEmpty);
      expect(layout.renderedFor([], on, gForceAvailable: true).tiles, isNotEmpty);
    });

    test('🔴 a phone module whose switch is off is not drawn either', () {
      // Link 1 of design 0042's privacy chain, on THIS surface. A stored speed
      // tile with detection off used to mount a SpeedCard, which opens the GNSS
      // stream — while the export preamble said `speed detection: off` and the
      // consent dialog had never been shown.
      const off = AppSettings.defaults;   // speedDetection defaults to false
      final layout = HomeLayout(const [
        HomeTile.module(DisplayModule.speed),
        HomeTile.device('DEV-A'),
      ]);
      final drawn = layout.renderedFor([dev('DEV-A')], off, gForceAvailable: false);
      expect(drawn.tiles.any((t) => t.module == DisplayModule.speed), isFalse,
          reason: 'no module ⇒ no card ⇒ no setFaceWantsSpeed ⇒ no stream');
      expect(drawn.tiles, hasLength(1));
    });

    test('and G needs a calibration, not just its switch', () {
      final layout = HomeLayout(const [
        HomeTile.module(DisplayModule.gForce),
        HomeTile.device('DEV-A'),
      ]);
      // Switch on but no calibration: design 0045 Q8 — a card that cannot name
      // a direction is not shown at all.
      final uncalibrated = layout.renderedFor([dev('DEV-A')],
          AppSettings.defaults.copyWith(gMeterEnabled: true),
          gForceAvailable: false);
      expect(uncalibrated.tiles.any((t) => t.module == DisplayModule.gForce),
          isFalse);
      final ready = layout.renderedFor([dev('DEV-A')],
          AppSettings.defaults.copyWith(gMeterEnabled: true),
          gForceAvailable: true);
      expect(ready.tiles.any((t) => t.module == DisplayModule.gForce), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // 2026-08-07: `visibleFor` shipped with NO caller in `lib/` and the four
  // tests above were green the whole time.
  //
  // The W-1 fix was applied by a script whose first assertion failed; the two
  // call-site edits that followed it in the same script never ran, and the
  // failure was read as "the anchor was wrong" rather than "nothing after it
  // executed". The function, its documentation and its tests all landed. The
  // app never called it, so deleting a device still left an unremovable card.
  //
  // 🔑 This is the same class of defect this project keeps finding in others —
  // the caller is where it breaks — arriving via the one route nobody audits:
  // a fix that tests itself. A unit test cannot notice that nothing uses the
  // unit, so the guard has to be about the wiring.
  // ---------------------------------------------------------------------------
  test('renderedFor is actually wired into both surfaces that draw a layout',
      () {
    for (final f in [
      'lib/ui/home/home_page.dart',
      'lib/ui/home/home_editor_page.dart',
    ]) {
      final src = File(f).readAsStringSync();
      expect(src, contains('.renderedFor('),
          reason: '\$f resolves a stored HomeLayout but never calls the home '
              'surface resolver — a deleted device would leave a card with no '
              'way to remove it, and a speed tile would open the GNSS stream '
              'with detection off');
    }
  });
}
