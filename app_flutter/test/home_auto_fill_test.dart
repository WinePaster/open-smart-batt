// design 0106 §6 (版 1b) — the home grid's auto-fill, auto sizes and
// 一鍵整理. Owner overturned design 0084 Q1 on 2026-11-15 (0106 Q-A1) under
// two conditions this file pins:
//
//  * cards never move when live data changes or a unit connects — placement
//    reads PLAN heights (sample data), never the live card;
//  * a layout the user arranged by hand does not move at all until they tap
//    一鍵整理 (Q-A2) — every layout stored before 版 1b reads back as theirs.
//
// CLEAN-ROOM: expectations derive from this project's own source and design
// docs.
import 'dart:io';

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
import 'package:open_smart_batt/ui/home/home_editor_page.dart';
import 'package:open_smart_batt/ui/home/home_editor_tutorial.dart';
import 'package:open_smart_batt/ui/home/home_page.dart';
import 'package:open_smart_batt/ui/home/home_plan.dart';
import 'package:open_smart_batt/ui/home/home_tiles.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();
}

HomeTile _half(String id, {TileSource col = TileSource.auto,
        HomeColumn? column}) =>
    HomeTile.device(id, span: HomeSpan.half, column: column)
        .withSources(sizeBy: TileSource.user, columnBy: col);

String _sides(List<HomeTile> placed) => placed
    .map((t) => t.span == HomeSpan.full
        ? 'F'
        : (t.column == HomeColumn.right ? 'R' : 'L'))
    .join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Directory markerDir;
  setUp(() async {
    HomePlanCache.clear();
    // The editor's tutorial is opt-out; these tests opt out (as
    // home_editor_test.dart does).
    markerDir = await Directory.systemTemp.createTemp('osb_ack');
    AckMarker.debugDirectoryOverride = markerDir;
    await kHomeEditorTutorialAck.markAcknowledged();
  });
  tearDown(() {
    AckMarker.debugDirectoryOverride = null;
    if (markerDir.existsSync()) markerDir.deleteSync(recursive: true);
  });

  // ===========================================================================
  // HomeLayout.place — the engine, pure
  // ===========================================================================
  group('place: auto-fill', () {
    test('each auto half goes to the shorter column, left on a tie', () {
      final tiles = [_half('A'), _half('B'), _half('C'), _half('D')];
      final h = [300.0, 100.0, 100.0, 100.0];
      // A→L(300) B→R(100) C→R(200) D→R(300)? no: after C, R=200 < L=300 → R.
      expect(_sides(HomeLayout.place(tiles, halfHeight: (i) => h[i])), 'LRRR');
      // Without heights every card counts 1 — plain alternation.
      expect(_sides(HomeLayout.place(tiles)), 'LRLR');
    });

    test('a pinned card stays put and counts towards its column first', () {
      final tiles = [
        _half('A'),
        _half('P', col: TileSource.user, column: HomeColumn.left),
        _half('B'),
      ];
      final h = [100.0, 400.0, 100.0];
      // L starts at 400 (the pinned P), so A and B both go right.
      expect(_sides(HomeLayout.place(tiles, halfHeight: (i) => h[i])), 'RLR');
    });

    test('a full card ends the run; order is never changed', () {
      final tiles = [
        _half('A'),
        _half('B'),
        const HomeTile.device('X'),
        _half('C'),
        _half('D'),
      ];
      final placed = HomeLayout.place(tiles);
      expect(_sides(placed), 'LRFLR');
      expect([for (final t in placed) t.deviceId], ['A', 'B', 'X', 'C', 'D']);
    });

    test('an AUTO half left alone is drawn full; a USER half is not', () {
      final autoAlone = [
        const HomeTile.device('X'),
        const HomeTile.module(DisplayModule.gForce).asAuto,
      ];
      final a = HomeLayout.place(HomeLayout.autoSized(autoAlone));
      expect(a.last.span, HomeSpan.full,
          reason: 'an orphan made by the engine is not a layout anyone chose');
      final userAlone = [const HomeTile.device('X'), _half('A')];
      expect(HomeLayout.place(userAlone).last.span, HomeSpan.half,
          reason: 'a lone 1x1 the user made is drawn as asked (2026-08-08)');
    });

    test('Q-S2: an auto half much taller than at full width is drawn full', () {
      final tiles = HomeLayout.autoSized([
        const HomeTile.device('A').asAuto,
        const HomeTile.device('B').asAuto,
        const HomeTile.device('C').asAuto,
      ]);
      final half = [500.0, 100.0, 100.0];
      final full = [300.0, 90.0, 90.0];
      final placed = HomeLayout.place(tiles,
          halfHeight: (i) => half[i], fullHeight: (i) => full[i]);
      expect(_sides(placed), 'FLR');
    });

    test('Q-S2: narrow ⇒ every AUTO half drawn full, USER halves kept', () {
      final tiles = [
        ...HomeLayout.autoSized([
          const HomeTile.device('A').asAuto,
          const HomeTile.device('B').asAuto,
        ]),
        _half('U1'),
        _half('U2'),
      ];
      expect(_sides(HomeLayout.place(tiles, narrow: true)), 'FFLR');
    });
  });

  // ===========================================================================
  // Auto sizes and the storage contract
  // ===========================================================================
  group('auto size (Q-Z1) and storage', () {
    test('the size table', () {
      HomeSpan s(DisplayModule m) => autoSpanFor(HomeTile.module(m));
      for (final m in [
        DisplayModule.chart,
        DisplayModule.readouts,
        DisplayModule.cells,
        DisplayModule.energyPath,
      ]) {
        expect(s(m), HomeSpan.full, reason: m.name);
      }
      for (final m in [
        DisplayModule.gaugeVoltage,
        DisplayModule.gaugeSoc,
        DisplayModule.speed,
        DisplayModule.gForce,
        DisplayModule.clock,
      ]) {
        expect(s(m), HomeSpan.half, reason: m.name);
      }
      expect(autoSpanFor(const HomeTile.device('A')), HomeSpan.half);
      expect(autoSpanFor(const HomeTile.addDevice()), HomeSpan.full);
    });

    test('🔴 Q-A2: a layout stored before 版 1b reads back as all user-set', () {
      // Exactly what an older build writes: no sizeBy / columnBy keys.
      const legacy = '{"tiles":['
          '{"kind":"module","module":"chart","device":"A","span":"half","column":"right"},'
          '{"kind":"deviceCard","device":"A","span":"full"}]}';
      final l = HomeLayout.decode(legacy)!;
      for (final t in l.tiles) {
        expect(t.sizeBy, TileSource.user);
        expect(t.columnBy, TileSource.user);
      }
      // …and therefore the engine changes nothing: the chart stays a RIGHT
      // half although the auto table would make it full and alone.
      final placed = HomeLayout.place(l.tiles);
      expect(placed.first.span, HomeSpan.half);
      expect(placed.first.column, HomeColumn.right);
    });

    test('auto flags round-trip; spans stay concrete for older builds', () {
      final l = HomeLayout.defaultFor(const [
        SavedDevice(id: 'A', alias: 'a', productClass: ProductClass.smartBattery),
      ]);
      final json = l.encode();
      expect(json, contains('"sizeBy":"auto"'));
      expect(json, contains('"span":"half"'),
          reason: 'an older build ignores sizeBy and must still read a span');
      expect(HomeLayout.decode(json), l);
    });

    test('the generated default: device card and gauge side by side', () {
      final l = HomeLayout.defaultFor(const [
        SavedDevice(id: 'A', alias: 'a', productClass: ProductClass.smartBattery),
      ]);
      expect(
        [for (final t in l.tiles) '${t.module?.name ?? t.kind.name}:${t.span.name}'],
        [
          'deviceCard:half',
          'gaugeVoltage:half',
          'readouts:full',
          'speed:half',
          'gForce:half',
        ],
      );
    });
  });

  // ===========================================================================
  // Editor operations
  // ===========================================================================
  group('editor operations', () {
    test('toggling a size makes it the user\'s; reset hands it back', () {
      final start = HomeLayout.defaultFor(const [
        SavedDevice(id: 'A', alias: 'a', productClass: ProductClass.smartBattery),
      ]).tiles;
      final set = HomeGridOps.setSpan(start, 0, HomeSpan.full);
      expect(set[0].sizeBy, TileSource.user);
      expect(set[0].span, HomeSpan.full);
      final back = HomeGridOps.resetToAuto(set, 0);
      expect(back[0].sizeBy, TileSource.auto);
      expect(back[0].span, HomeSpan.half);
    });

    test('Q-A3: dropping INTO a column pins it; a drop line does not', () {
      final start = HomeLayout.autoSized([
        const HomeTile.device('A').asAuto,
        const HomeTile.device('B').asAuto,
        const HomeTile.device('C').asAuto,
      ]);
      final pinned =
          HomeGridOps.moveTo(start, 2, 0, column: HomeColumn.right, pin: true);
      expect(pinned.first.deviceId, 'C');
      expect(pinned.first.columnBy, TileSource.user);
      final line = HomeGridOps.moveTo(start, 2, 0, column: HomeColumn.left);
      expect(line.first.columnBy, TileSource.auto);
    });

    test('tidy: grouped by device, halves tallest first, phone modules last, '
        'nothing deleted, everything auto', () {
      final tiles = [
        const HomeTile.module(DisplayModule.speed, span: HomeSpan.full),
        const HomeTile.module(DisplayModule.chart, deviceId: 'A',
            span: HomeSpan.half, column: HomeColumn.right),
        const HomeTile.device('B'),
        const HomeTile.module(DisplayModule.gaugeVoltage, deviceId: 'A'),
        const HomeTile.device('A'),
        const HomeTile.device('A'), // a duplicate — kept
      ];
      expect(HomeGridOps.tidyCost(tiles), (6, 1));
      final heights = [10.0, 10.0, 10.0, 80.0, 20.0, 20.0];
      final out = HomeGridOps.tidy(tiles, planHeights: heights);
      expect(out.length, tiles.length, reason: 'tidy never deletes a card');
      expect(
        [for (final t in out) '${t.module?.name ?? t.kind.name}@${t.deviceId}'],
        [
          'deviceCard@A',
          'deviceCard@A',
          'gaugeVoltage@A',
          'chart@A',
          'deviceCard@B',
          'speed@null',
        ],
      );
      expect(out.every((t) => t.sizeBy == TileSource.auto), isTrue);
      expect(out.every((t) => t.columnBy == TileSource.auto), isTrue);
      expect(HomeGridOps.tidyCost(out), (0, 0));
    });
  });

  // ===========================================================================
  // Widgets
  // ===========================================================================
  Future<AppServices> boot(WidgetTester tester, {String? stored}) async {
    late final AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      s = await AppServices.create(appDatabase: db, ble: _FakeBle());
      for (final id in ['DEV-A', 'DEV-B', 'DEV-C']) {
        await s.devices.save(SavedDevice(
            id: id, alias: 'unit $id', productClass: ProductClass.smartBattery));
      }
      if (stored != null) await s.settings.setHomeLayout(stored);
    });
    return s;
  }

  Widget app(AppServices s, Widget home, {double textScale = 1.0}) =>
      MultiProvider(
        providers: [
          Provider<BleService>.value(value: s.ble),
          ChangeNotifierProvider<SettingsController>.value(value: s.settings),
          ChangeNotifierProvider<DeviceController>.value(value: s.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: s.connection),
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
          ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'TW'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: home,
        ),
      );

  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await s.pending.drain();
      await s.dispose();
    });
  }

  void window(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  List<Offset> deviceCardOrigins(WidgetTester tester) => [
        for (final e in find
            .byWidgetPredicate((w) =>
                w is HomeTileView && w.tile.kind == HomeTileKind.deviceCard)
            .evaluate())
          tester.getTopLeft(find.byWidget(e.widget)),
      ];

  // Three engine-owned device cards (auto size ⇒ half, auto column).
  final autoThree = HomeLayout(HomeLayout.autoSized([
    const HomeTile.device('DEV-A').asAuto,
    const HomeTile.device('DEV-B').asAuto,
    const HomeTile.device('DEV-C').asAuto,
  ])).encode();

  testWidgets('🔴 the core test: live changes never move a card',
      (tester) async {
    window(tester, const Size(390, 2000));
    final s = await boot(tester, stored: autoThree);
    addTearDown(() => teardown(tester, s));
    await tester.pumpWidget(app(s, const Scaffold(body: HomePage())));
    await tester.pump(); // plan heights measured offstage
    await tester.pump(); // drawn with them
    // Column and order — not the y offset: a card whose own content changes
    // height (a reading appears) pushes the card under it in the SAME column,
    // which is a column stacking, not a card moving to another place.
    List<double> columnsOf() => [for (final o in deviceCardOrigins(tester)) o.dx];
    final before = columnsOf();
    expect(before.length, 3);
    expect(before.toSet().length, 2, reason: 'sanity: two columns in use');
    final measured = HomePlanCache.length;
    expect(measured, greaterThan(0), reason: 'the plan heights were measured');

    // A unit "comes online" in the only way the home grid can see from here:
    // its saved last reading and last-seen change, which redraws its card.
    await tester.runAsync(() => s.devices
        .touch('DEV-A', lastSeen: DateTime.now(), lastValue: 13.9, lastSoc: 80));
    await tester.pump();
    await tester.pump();
    expect(columnsOf(), before,
        reason: 'design 0084 Q1 condition: a live change must not move a card');
    expect(HomePlanCache.length, measured,
        reason: 'nothing was re-measured — live data is not in the plan key');
  });

  testWidgets('🔴 Q-A2: a hand-made layout draws exactly as stored',
      (tester) async {
    window(tester, const Size(390, 2000));
    // Two cards the user put in the LEFT column, one in the right — no
    // ordering could express it, and the engine must not "balance" it.
    const legacy = '{"tiles":['
        '{"kind":"deviceCard","device":"DEV-A","span":"half","column":"left"},'
        '{"kind":"deviceCard","device":"DEV-B","span":"half","column":"left"},'
        '{"kind":"deviceCard","device":"DEV-C","span":"half","column":"right"}]}';
    final s = await boot(tester, stored: legacy);
    addTearDown(() => teardown(tester, s));
    await tester.pumpWidget(app(s, const Scaffold(body: HomePage())));
    await tester.pump();
    await tester.pump();
    final o = deviceCardOrigins(tester);
    expect(o[0].dx, o[1].dx, reason: 'A and B share the left column');
    expect(o[2].dx, greaterThan(o[0].dx));
    expect(HomePlanCache.length, 0,
        reason: 'a hand-made layout needs no measurement at all');
  });

  // The user's OWN enlargement is what counts (AppTheme.userTextScale divides
  // out the app's 1.15 base): ×1.3 is 1.13 ⇒ 150×1.13 = 170 < 177, still two
  // columns; ×1.6 is 1.39 ⇒ 209 > 177, narrow.
  for (final (scale, narrow) in [(1.0, false), (1.3, false), (1.6, true), (2.0, true)]) {
    testWidgets('text ×$scale on a 390 pt phone ⇒ narrow=$narrow', (tester) async {
      window(tester, const Size(390, 2000));
      final s = await boot(tester, stored: autoThree);
      addTearDown(() => teardown(tester, s));
      await tester.pumpWidget(
          app(s, const Scaffold(body: HomePage()), textScale: scale));
      await tester.pump();
      await tester.pump();
      final o = deviceCardOrigins(tester);
      final xs = o.map((e) => e.dx).toSet();
      if (narrow) {
        expect(xs.length, 1, reason: 'every auto half drawn full');
      } else {
        expect(xs.length, 2, reason: 'two columns');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('一鍵整理: confirm with counts, then undo restores', (tester) async {
    window(tester, const Size(390, 2000));
    const stored = '{"tiles":['
        '{"kind":"deviceCard","device":"DEV-B","span":"full"},'
        '{"kind":"deviceCard","device":"DEV-A","span":"half","column":"right"}]}';
    final s = await boot(tester, stored: stored);
    addTearDown(() => teardown(tester, s));
    await tester.pumpWidget(app(s, const HomeEditorPage()));
    await tester.pump();
    await tester.pump();
    expect(find.text('你設定的'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('home-edit-tidy')));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 張卡的大小、1 張卡的位置'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '一鍵整理'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => s.pending.drain());
    final tidied = HomeLayout.decode(s.settings.settings.homeLayout)!;
    expect(tidied.tiles.every((t) => t.sizeBy == TileSource.auto), isTrue);
    expect(find.text('你設定的'), findsNothing);

    await tester.tap(find.text('復原'));
    await tester.pumpAndSettle();
    // Let the snack bar time out so no timer outlives the test.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await s.pending.drain();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(HomeLayout.decode(s.settings.settings.homeLayout),
        HomeLayout.decode(stored));
  });
}
