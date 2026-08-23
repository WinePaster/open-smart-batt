// Card SHELL × card VIEW (design 0054).
//
// ## What this file is guarding, in one sentence
//
// Design 0041 shipped three watchfaces whose module LISTS differed, whose tests
// were all green, and which rendered CHARACTER FOR CHARACTER identically on a
// phone without DVOL — because the only difference between them was a
// data-gated card. The user's words were「換了都一樣」. Every assertion below
// exists so that a style choice which changes nothing cannot pass.
//
//  T-V1 — rich data: each pair of views a card declares must RENDER differently.
//  T-V2 — 🔴 the same pair on EMPTY data. This is the real remedy: 0041's defect
//         only appeared where data was missing, and a test that only ever ran a
//         full fixture would have been green there too. The assertion is
//         "either the renderings differ, or both are waiting tiles" — and the
//         second arm is ASSERTED, not assumed, or the test decays to always-true.
//  T-V3 — an unknown shell / view falls back and KEEPS THE TILE. The opposite of
//         the rule for an unknown module, which drops it.
//  T-V4 — a view slug from another card's vocabulary is not an error and not a
//         crash. This is the executable proof that view names are module-scoped.
//  T-S1 — no two shells share a token bundle, and none of their differences is
//         parked on something a given data state might not draw.
//  F1–F5 — the information floors, one guard each.
//
// ## Why the fingerprint is (text, fontSize, y) and not `find.text`
//
// `grid` and `big` print THE SAME STRINGS. Their difference is entirely size
// and position, so a set of texts compares equal for both and a test built on
// `find.text` would be green on a defect. Design 0041 §6 T8 already established
// "compare the y coordinate, not the existence" for ordering defects; the font
// size is what this case adds.
//
// CLEAN-ROOM: expectations derive from this project's own source and design
// docs.
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
import 'package:open_smart_batt/ui/dashboard/dashboard_cards.dart';
import 'package:open_smart_batt/ui/dashboard/pvlt_gauge.dart';
import 'package:open_smart_batt/ui/dashboard/readout_grid.dart';
import 'package:open_smart_batt/ui/dashboard/readouts_card.dart';
import 'package:open_smart_batt/ui/dashboard/watchfaces.dart';
import 'package:open_smart_batt/ui/home/home_editor_page.dart';
import 'package:open_smart_batt/ui/home/home_preview.dart';
import 'package:open_smart_batt/ui/home/home_tiles.dart';
import 'package:open_smart_batt/ui/widgets/industrial_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<TelemetrySample> get telemetry =>
      const Stream<TelemetrySample>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

final DateTime kNow = DateTime(2026, 8, 9, 19, 50);

/// A sample with NOTHING in it — the state design 0041's defect hid in.
final TelemetrySample kEmptySample = TelemetrySample(timestamp: kNow);

CardTelemetry teleOf(TelemetrySample s) => StaticCardTelemetry(
      sample: s,
      trend: LiveTrendBuffer(),
      tempUnit: TempUnit.celsius,
    );

/// Walk an [InlineSpan] tree, merging styles down, and hand every non-empty run
/// of text to [emit] with the style actually in force for it.
///
/// 🔴 Necessary rather than fastidious. `Text.rich` puts the caller's span
/// UNDER a root span carrying the inherited `DefaultTextStyle`, so reading
/// `richText.text.style?.fontSize` reports 14 for the gauge's 50 px value —
/// which would have made every fingerprint in this file agree on size and left
/// the whole comparison resting on the y coordinate alone.
void _visitSpans(
    InlineSpan span, TextStyle? inherited, void Function(String, TextStyle?) emit) {
  if (span is! TextSpan) return;
  final style =
      inherited == null ? span.style : inherited.merge(span.style);
  final text = span.text;
  if (text != null && text.isNotEmpty) emit(text, style);
  for (final child in span.children ?? const <InlineSpan>[]) {
    _visitSpans(child, style, emit);
  }
}

bool _isIconGlyph(TextStyle? s) => s?.fontFamily == 'MaterialIcons';

/// The rendering's fingerprint: every text run as `(text, fontSize, y)`.
///
/// The y is the top of the `RichText` the run belongs to, which is what design
/// 0041 §6 T8 established for ordering defects. The font size is what design
/// 0054 adds, because `grid` and `big` print THE SAME STRINGS and differ only in
/// weight and position.
List<String> fingerprint(WidgetTester tester, Finder root) {
  final finder = find.descendant(of: root, matching: find.byType(RichText));
  final n = finder.evaluate().length;
  final out = <String>[];
  for (var i = 0; i < n; i++) {
    final w = tester.widget<RichText>(finder.at(i));
    final y = tester.getTopLeft(finder.at(i)).dy;
    _visitSpans(w.text, null, (text, style) {
      out.add('$text|${style?.fontSize?.toStringAsFixed(2)}'
          '|${y.toStringAsFixed(1)}');
    });
  }
  out.sort();
  return out;
}

/// The text a human reads under [root] — icon glyphs excluded.
Set<String> readableTexts(WidgetTester tester, Finder root) {
  final finder = find.descendant(of: root, matching: find.byType(RichText));
  final out = <String>{};
  for (final w in tester.widgetList<RichText>(finder)) {
    _visitSpans(w.text, null, (text, style) {
      if (!_isIconGlyph(style)) out.add(text);
    });
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  Future<void> pumpCard(
    WidgetTester tester, {
    required DisplayModule module,
    required ProductClass cls,
    required CardTelemetry tele,
    String? view,
    CardShell shell = CardShell.standard,
  }) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 360,
              child: Builder(
                builder: (c) => CardStyleScope(
                  shell: shell,
                  // `home`: this file is design 0054, and the shell + view
                  // vocabularies it pins are delivered by the HOME grid's own
                  // `CardStyleScope` (placed two lines up).
                  child: dashboardCardFor(c, module,
                          shellClass: cls,
                          surface: CardSurface.home,
                          tele: tele,
                          view: view) ??
                      const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The three (card, view-pair) combinations Phase 1 ships.
  const pairs = <(String, DisplayModule, ProductClass, String, String)>[
    ('readouts', DisplayModule.readouts, ProductClass.smartBattery, 'grid',
        'big'),
    ('gaugeVoltage', DisplayModule.gaugeVoltage, ProductClass.smartBattery,
        'dial', 'numeric'),
    ('gaugeSoc', DisplayModule.gaugeSoc, ProductClass.powerBank, 'dial',
        'numeric'),
  ];

  // =========================================================================
  // T-V1 — with data, two views of one card must not render alike
  // =========================================================================
  group('T-V1: every declared view pair renders differently (rich data)', () {
    for (final (name, module, cls, a, b) in pairs) {
      testWidgets('$name: $a ≠ $b', (tester) async {
        final tele = teleOf(cls == ProductClass.powerBank
            ? previewPowerBankSample(kNow)
            : previewPackSample(kNow));

        await pumpCard(
            tester, module: module, cls: cls, tele: tele, view: a);
        final fa = fingerprint(tester, find.byType(IndustrialCard));
        await pumpCard(
            tester, module: module, cls: cls, tele: tele, view: b);
        final fb = fingerprint(tester, find.byType(IndustrialCard));

        expect(fa, isNotEmpty, reason: 'nothing rendered — vacuous otherwise');
        expect(fa, isNot(equals(fb)),
            reason: 'design 0041: a choice that renders identically is a '
                'choice that changed nothing');
      });
    }
  });

  // =========================================================================
  // T-V2 — 🔴 the same pairs on EMPTY data
  // =========================================================================
  group('T-V2: the pairs still differ where there is no data', () {
    for (final (name, module, cls, a, b) in pairs) {
      testWidgets('$name: $a ≠ $b with every value null', (tester) async {
        final tele = teleOf(kEmptySample);
        await pumpCard(
            tester, module: module, cls: cls, tele: tele, view: a);
        final fa = fingerprint(tester, find.byType(IndustrialCard));
        await pumpCard(
            tester, module: module, cls: cls, tele: tele, view: b);
        final fb = fingerprint(tester, find.byType(IndustrialCard));

        expect(fa, isNotEmpty);
        expect(fa, isNot(equals(fb)),
            reason: 'this is the state design 0041 hid in: every card was a '
                'placeholder, so every face looked the same');
      });
    }
  });

  testWidgets(
      'T-V2 second arm: OFFLINE, both views are the waiting tile — asserted',
      (tester) async {
    // 🔴 The arm that would otherwise make T-V2 pass vacuously. A module tile
    // whose unit is not connected is a `HomeWaitingTile`, which takes NO view,
    // so the two renderings are identical BY DESIGN. The test states that
    // outcome rather than tolerating it: if a view ever started reaching the
    // waiting tile, this expectation is what notices.
    late final AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      s = await AppServices.create(appDatabase: db, ble: _FakeBle());
      await s.devices
          .saveNew('DEV-A', 'unit A', productClass: ProductClass.smartBattery);
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => s.pending.drain());
      await s.dispose();
    });

    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<void> pumpTile(String? view) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<BleService>.value(value: s.ble),
            ChangeNotifierProvider<SettingsController>.value(value: s.settings),
            ChangeNotifierProvider<DeviceController>.value(value: s.devices),
            ChangeNotifierProvider<ConnectionController>.value(
                value: s.connection),
            ChangeNotifierProvider<TelemetryController>.value(
                value: s.telemetry),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: SizedBox(
                width: 360,
                child: HomeTileView(
                  tile: HomeTile.module(DisplayModule.readouts,
                      deviceId: 'DEV-A', view: view),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pumpTile(null);
    expect(find.byType(HomeWaitingTile), findsOneWidget,
        reason: 'offline module tiles are the waiting state');
    final fa = fingerprint(tester, find.byType(IndustrialCard));

    await pumpTile('big');
    expect(find.byType(HomeWaitingTile), findsOneWidget,
        reason: '🔴 THE SECOND ARM. A view must not reach the waiting tile — '
            'a big-number `--` dresses the honesty floor up as decoration');
    expect(fingerprint(tester, find.byType(IndustrialCard)), equals(fa));
  });

  // =========================================================================
  // T-V3 / T-V4 — fallback, and the scoped name space
  // =========================================================================
  group('T-V3: unknown shell / view falls back and never drops a tile', () {
    test('unknown slugs decode to the defaults, tile count unchanged', () {
      const stored = '{"tiles":['
          '{"kind":"module","module":"readouts","span":"full",'
          '"shell":"chrome","view":"hologram"},'
          '{"kind":"deviceCard","device":"AA:BB","span":"half",'
          '"shell":"nope"},'
          '{"kind":"empty","span":"half"}'
          ']}';
      final back = HomeLayout.decode(stored);
      expect(back, isNotNull);
      expect(back!.tiles, hasLength(3),
          reason: '🔴 the opposite of the unknown-MODULE rule. A module is '
              'content; a shell and a view are only presentation, so losing '
              'one must never cost the card.');
      expect(back.tiles[0].shell, CardShell.standard);
      expect(back.tiles[0].view, isNull);
      expect(back.tiles[1].shell, CardShell.standard);
    });

    test('an unknown MODULE still drops its tile — the rules stay opposite',
        () {
      const stored = '{"tiles":['
          '{"kind":"module","module":"teleporter","span":"full"},'
          '{"kind":"module","module":"readouts","span":"full"}]}';
      expect(HomeLayout.decode(stored)!.tiles, hasLength(1));
    });

    test('known slugs survive the round trip', () {
      const tiles = [
        HomeTile.module(DisplayModule.readouts,
            deviceId: 'AA:BB', shell: CardShell.minimal, view: 'big'),
        HomeTile.module(DisplayModule.gaugeSoc,
            deviceId: 'AA:BB', span: HomeSpan.half, shell: CardShell.dense,
            view: 'numeric'),
        HomeTile.device('AA:BB', span: HomeSpan.half, shell: CardShell.dense),
      ];
      final back = HomeLayout.decode(const HomeLayout(tiles).encode());
      // 🔵 design 0084 S1 seats every `half` in a column on the way back in, so
      // the expectation is the seated list. `==` still covers shell, view AND
      // column, so this is still not just a shape comparison.
      expect(back!.tiles, equals(HomeLayout.withDerivedColumns(tiles)),
          reason: 'the `==` covers shell and view, so this is not just a '
              'shape comparison');
    });

    test('a default is stored as ABSENCE, both axes', () {
      // Written the awkward way on purpose: a tile CONSTRUCTED with the default
      // spelled out. `withStyle` and `fromJson` both normalise, so only direct
      // construction can produce this — and storage must still say the same
      // thing either way, or one layout would read as two.
      const t = HomeTile.module(DisplayModule.readouts, view: 'grid');
      final json = t.toJson();
      expect(json.containsKey('shell'), isFalse);
      expect(json.containsKey('view'), isFalse,
          reason: '`grid` is the readouts default, so it round-trips as null '
              '— an empty value written into every row would have to be told '
              'apart from never set');
      expect(exportHomeValue(const HomeLayout([t])), 'tiles=readouts',
          reason: 'and the export preamble agrees with storage');
      expect(
          const HomeTile.module(DisplayModule.readouts)
              .withStyle(shell: CardShell.standard, view: 'grid')
              .view,
          isNull,
          reason: 'the editor path normalises at the point of choice');
    });

    test('a span toggle carries the style through', () {
      // The defect this pins: `copyWith` is how every drag and span change is
      // applied, so a version that dropped the two new fields would reset a
      // card's appearance every time it was moved.
      const t = HomeTile.module(DisplayModule.readouts,
          shell: CardShell.dense, view: 'big');
      final moved = t.copyWith(span: HomeSpan.half);
      expect(moved.shell, CardShell.dense);
      expect(moved.view, 'big');
    });
  });

  group('T-V4: a view name means nothing outside its own module', () {
    test('`analog` on a readouts tile is not an error and not a lost card', () {
      const stored = '{"tiles":[{"kind":"module","module":"readouts",'
          '"span":"full","view":"analog"}]}';
      final back = HomeLayout.decode(stored);
      expect(back!.tiles, hasLength(1));
      expect(back.tiles.single.view, isNull,
          reason: 'the readouts vocabulary has no such word, so the card draws '
              'its default — this is the executable proof that view slugs are '
              'module-scoped rather than a global enum');
    });

    test('each module declares its own vocabulary, and most declare none', () {
      expect(cardViewSlugs(DisplayModule.readouts), ['grid', 'big']);
      expect(cardViewSlugs(DisplayModule.gaugeVoltage), ['dial', 'numeric']);
      expect(cardViewSlugs(DisplayModule.gaugeSoc), ['dial', 'numeric']);
      expect(cardViewSlugs(DisplayModule.clock), ['digital']);
      // Rulings, not gaps — design 0054 §2. `chart`/`cells` would recreate an
      // existing card or lose a comparison; `energyPath` would re-enter design
      // 0041's cut through a side door; `speed` would multiply with five states.
      for (final m in [
        DisplayModule.chart,
        DisplayModule.cells,
        DisplayModule.energyPath,
        DisplayModule.speed,
        DisplayModule.gForce,
      ]) {
        expect(cardViewSlugs(m), isEmpty, reason: '$m declares no views');
      }
    });

    test('the default is the first declared slug', () {
      expect(defaultCardView(DisplayModule.readouts), 'grid');
      expect(defaultCardView(DisplayModule.gaugeVoltage), 'dial');
      expect(defaultCardView(DisplayModule.chart), isNull);
    });
  });

  // =========================================================================
  // T-S1 — the shells
  // =========================================================================
  group('T-S1: no two shells are the same set of tokens', () {
    test('pairwise distinct', () {
      for (final a in CardShell.values) {
        for (final b in CardShell.values) {
          if (a == b) continue;
          expect(a.tokens, isNot(equals(b.tokens)), reason: '$a vs $b');
        }
      }
    });

    test('🔴 minimal and dense differ on the FRAME and the FILL', () {
      // The pair most at risk of converging: both drop the corner ticks, and if
      // the rest of their difference were spacing they would read as one shell
      // at two text sizes. Frame and fill are drawn in every data state, on
      // every card, so this difference can never fail to appear.
      final m = CardShell.minimal.tokens;
      final d = CardShell.dense.tokens;
      expect(m.bordered, isFalse);
      expect(d.bordered, isTrue);
      expect(m.filled, isFalse);
      expect(d.filled, isTrue);
    });

    test('no shell parks its difference on the heading', () {
      // The gauge cards and the device card have NO heading, so a shell whose
      // only distinguishing token were a heading treatment would be a no-op on
      // three of the nine cards — design 0041's shape exactly.
      for (final a in CardShell.values) {
        for (final b in CardShell.values) {
          if (a == b) continue;
          final ta = a.tokens;
          final tb = b.tokens;
          final headingOnly = ta.headingRule != tb.headingRule &&
              ta.bordered == tb.bordered &&
              ta.filled == tb.filled &&
              ta.underlined == tb.underlined &&
              ta.cornerTicks == tb.cornerTicks &&
              ta.radius == tb.radius &&
              ta.padScaleH == tb.padScaleH &&
              ta.padScaleV == tb.padScaleV &&
              ta.valueScale == tb.valueScale;
          expect(headingOnly, isFalse, reason: '$a vs $b');
        }
      }
    });

    testWidgets('the three shells render a card three different ways',
        (tester) async {
      final tele = teleOf(previewPackSample(kNow));
      final seen = <CardShell, List<String>>{};
      for (final s in CardShell.values) {
        await pumpCard(tester,
            module: DisplayModule.readouts,
            cls: ProductClass.smartBattery,
            tele: tele,
            shell: s);
        seen[s] = fingerprint(tester, find.byType(IndustrialCard));
      }
      // `standard` and `minimal` share their type sizes, so the difference has
      // to show up as GEOMETRY — which the y coordinate in the fingerprint is
      // there to catch.
      expect(seen[CardShell.standard], isNot(equals(seen[CardShell.minimal])));
      expect(seen[CardShell.standard], isNot(equals(seen[CardShell.dense])));
      expect(seen[CardShell.minimal], isNot(equals(seen[CardShell.dense])));
    });

    testWidgets('🔴 a card OUTSIDE a scope is standard, always', (tester) async {
      // The reason this is not a `ThemeData` extension. 11 of the ~26
      // `IndustrialCard` call sites are in settings / history / the calibration
      // wizard, and none of them may change because a home tile did.
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: SizedBox(
            width: 360,
            child: IndustrialCard(child: Text('settings row')),
          ),
        ),
      ));
      final ctx = tester.element(find.text('settings row'));
      expect(ctx.cardShell, CardShell.standard);
    });
  });

  // =========================================================================
  // The information floors (design 0054 §4.5)
  // =========================================================================
  group('F1 identity: a view never leaves a card unnameable', () {
    testWidgets('readouts keeps its heading in `big`', (tester) async {
      await pumpCard(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: teleOf(previewPackSample(kNow)),
          view: 'big');
      expect(find.text('LIVE READINGS'), findsOneWidget);
    });

    testWidgets('🔴 a gauge has NO heading, so `numeric` keeps its caption',
        (tester) async {
      // The correction design 0054 makes to the old floor, which said "the
      // heading always survives". Two of the nine cards have never had one:
      // `dashboardCardFor` passes only `child:` for both gauges. Their identity
      // is the caption, and this is the assertion that says so.
      await pumpCard(tester,
          module: DisplayModule.gaugeVoltage,
          cls: ProductClass.smartBattery,
          tele: teleOf(previewPackSample(kNow)),
          view: 'numeric');
      expect(find.byType(CardHeading), findsNothing,
          reason: 'a gauge card has no heading in EITHER view');
      expect(find.byType(PvltNumeric), findsOneWidget);
      // The caption and the SOH sub-line both survive the loss of the dial.
      expect(find.textContaining('Primary Voltage'), findsOneWidget);
    });

    testWidgets('the power bank keeps its direction sub-line', (tester) async {
      await pumpCard(tester,
          module: DisplayModule.gaugeSoc,
          cls: ProductClass.powerBank,
          tele: teleOf(previewPowerBankSample(kNow)),
          view: 'numeric');
      // 100 % discharging: the caption promises a charge STATE, and the
      // numeric view is not allowed to be the one rendering that promises
      // nothing.
      expect(find.textContaining('State of Charge'), findsOneWidget);
      expect(find.text('DISCHARGING'), findsOneWidget);
    });
  });

  group('F2 honesty: `--` is never filled in by a view', () {
    testWidgets('the hero of an empty readouts card is still `--`',
        (tester) async {
      await pumpCard(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: teleOf(kEmptySample),
          view: 'big');
      expect(find.textContaining('--'), findsWidgets);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('so is an empty numeric gauge', (tester) async {
      await pumpCard(tester,
          module: DisplayModule.gaugeVoltage,
          cls: ProductClass.smartBattery,
          tele: teleOf(kEmptySample),
          view: 'numeric');
      expect(find.textContaining('--'), findsWidgets);
    });
  });

  group('F4 emphasis: `big` gives up nothing at all', () {
    testWidgets('every item printed by `grid` is printed by `big`',
        (tester) async {
      // The floor F4 names: a view may print less only if it buys emphasis.
      // This one buys emphasis while printing everything, so the strongest
      // available assertion is set equality on the values.
      final tele = teleOf(previewPackSample(kNow));
      // Icon glyphs excluded: they restate the label beside them, and the hero
      // line drops them for the DEMOTED items only. Nothing a reader gets from
      // them is unavailable in words.
      Set<String> texts() =>
          readableTexts(tester, find.byType(IndustrialCard));
      await pumpCard(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: tele,
          view: 'grid');
      final inGrid = texts();
      await pumpCard(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: tele,
          view: 'big');
      final inBig = texts();
      expect(inBig, containsAll(inGrid),
          reason: 'the tail is DEMOTED, not dropped — a user who cannot see '
              'what they gave up cannot judge the choice');
    });

    testWidgets('and the hero really is the emphasis', (tester) async {
      await pumpCard(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: teleOf(previewPackSample(kNow)),
          view: 'big');
      final sizes = <double>[];
      for (final w in tester.widgetList<RichText>(find.descendant(
          of: find.byType(ReadoutHero), matching: find.byType(RichText)))) {
        _visitSpans(w.text, null, (_, style) {
          if (!_isIconGlyph(style) && style?.fontSize != null) {
            sizes.add(style!.fontSize!);
          }
        });
      }
      expect(sizes.reduce((a, b) => a > b ? a : b), greaterThanOrEqualTo(50),
          reason: 'the promoted item is at gauge size — otherwise this view is '
              'only a shorter card, which is the defect F4 names');
    });

    testWidgets('a badge is never dropped by the hero layout', (tester) async {
      // FB-47: a bare `-0.43 A` was read as a defect, and the word beside it is
      // what makes the minus a direction. A view that dropped the pill would be
      // changing what a number MEANS, which S-R1 forbids.
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(
          body: SizedBox(
            width: 360,
            child: ReadoutsCard(
              view: ReadoutsView.big,
              items: [
                Readout(
                    icon: Icons.thermostat, label: 'temp', value: '41', unit: 'C'),
                Readout(
                    icon: Icons.bolt,
                    label: 'current',
                    value: '-0.43',
                    unit: 'A',
                    badge: 'CHARGING'),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.byType(ReadoutBadgePill), findsOneWidget);
    });
  });

  group('F5 presentation only: a view decides nothing about the data', () {
    testWidgets('the class gate still refuses, whatever the view says',
        (tester) async {
      // A power bank has no voltage gauge and a pack has no SOC ring. Those are
      // registry decisions upstream of the view, and asking for a view must not
      // conjure a card the class does not have.
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(builder: (c) {
            expect(
                dashboardCardFor(c, DisplayModule.gaugeVoltage,
                    shellClass: ProductClass.powerBank,
                    surface: CardSurface.home,
                    tele: teleOf(previewPowerBankSample(kNow)),
                    view: 'numeric'),
                isNull);
            expect(
                dashboardCardFor(c, DisplayModule.gaugeSoc,
                    shellClass: ProductClass.smartBattery,
                    surface: CardSurface.home,
                    tele: teleOf(previewPackSample(kNow)),
                    view: 'numeric'),
                isNull);
            return const SizedBox();
          }),
        ),
      ));
      await tester.pump();
    });

    testWidgets('a data-gated item stays gated in `big`', (tester) async {
      // `current` is hidden when it has not arrived (the data gate inside
      // `dashboardCardFor`). The hero layout must not resurrect it, and must not
      // hide one that IS there.
      //
      // 🔴 The pack tile prints the MAGNITUDE with a direction badge since
      // design 0056, so the presence check is on `12.5` and on the badge. The
      // BADGE is the load-bearing half here: F4 says a view may not print less,
      // and `big` demoting the current would now drop a word as well as a
      // number.
      final withCurrent = teleOf(TelemetrySample(
          timestamp: kNow, temperatureC: 41, svlt: 13.9, current: -12.5));
      await pumpCard(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: withCurrent,
          view: 'big');
      expect(find.textContaining('12.5'), findsOneWidget);
      expect(find.text('DISCHARGING'), findsOneWidget);

      await pumpCard(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: teleOf(TelemetrySample(
              timestamp: kNow, temperatureC: 41, svlt: 13.9)),
          view: 'big');
      expect(find.text('MAIN CURRENT'), findsNothing);
    });
  });

  // =========================================================================
  // The export preamble (design 0054 Q3)
  // =========================================================================
  group('the export header carries both axes, defaults omitted', () {
    test('tagged suffixes, in the ruled order', () {
      final v = exportHomeValue(HomeLayout(const [
        HomeTile.module(DisplayModule.readouts,
            deviceId: 'AA:BB',
            span: HomeSpan.half,
            shell: CardShell.minimal,
            view: 'big'),
        HomeTile.module(DisplayModule.gaugeVoltage, deviceId: 'AA:BB'),
        HomeTile.device('CC:DD', shell: CardShell.dense),
      ]));
      expect(v,
          'tiles=readouts@d1:half:vbig:sminimal,gaugeVoltage@d1,deviceCard@d2:sdense');
    });

    test('🔴 it still matches the alphabet the ingest side is protected by',
        () {
      // `export_layout_header_test.dart` pins this to `[A-Za-z0-9@,:]` — no
      // `=`. That is why the suffix is `:vbig` and not `:view=big`
      // (design 0054 Q3): widening a guard for a nicer syntax is not a trade
      // this line gets to make.
      final v = exportHomeValue(HomeLayout(const [
        HomeTile.module(DisplayModule.gaugeSoc,
            deviceId: 'AA:BB', shell: CardShell.dense, view: 'numeric'),
      ]));
      expect(v, matches(RegExp(r'^tiles=[A-Za-z0-9@,:]+$')));
      expect(v.contains(': '), isFalse);
    });

    test('the addDevice tile carries a shell too', () {
      // It is a card like any other, and the shell vocabulary is global. This
      // asserts the export line does not quietly special-case it.
      expect(
        exportHomeValue(HomeLayout(const [
          HomeTile(kind: HomeTileKind.addDevice, shell: CardShell.minimal),
        ])),
        'tiles=addDevice:sminimal',
      );
    });

    test('a default-styled grid produces the byte-identical old line', () {
      // The compatibility claim, made executable: nothing changes for the
      // overwhelming majority of captures.
      expect(
        exportHomeValue(HomeLayout(const [
          HomeTile.module(DisplayModule.speed, span: HomeSpan.half),
          HomeTile.device('AA:BB'),
        ])),
        'tiles=speed:half,deviceCard@d1',
      );
    });
  });

  // =========================================================================
  // The editor (design 0054 §7)
  // =========================================================================
  group('the editor is the only place a style is chosen', () {
    Future<AppServices> boot(WidgetTester tester,
        {required List<HomeTile> tiles}) async {
      late final AppServices s;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
            path: inMemoryDatabasePath, factory: databaseFactoryFfi);
        s = await AppServices.create(appDatabase: db, ble: _FakeBle());
        await s.devices.saveNew('DEV-A', 'unit A',
            productClass: ProductClass.smartBattery);
        await s.settings.setHomeLayout(HomeLayout(tiles).encode());
      });
      return s;
    }

    Future<void> pumpEditor(WidgetTester tester, AppServices s) async {
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<BleService>.value(value: s.ble),
            ChangeNotifierProvider<SettingsController>.value(value: s.settings),
            ChangeNotifierProvider<DeviceController>.value(value: s.devices),
            ChangeNotifierProvider<ConnectionController>.value(
                value: s.connection),
            ChangeNotifierProvider<TelemetryController>.value(
                value: s.telemetry),
            ChangeNotifierProvider<GForceController>.value(value: s.gforce),
            ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const HomeEditorPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> teardown(WidgetTester tester, AppServices s) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => s.pending.drain());
      await s.dispose();
    }

    testWidgets('tapping a card body opens the appearance sheet, and choosing '
        'a shell persists', (tester) async {
      final s = await boot(tester, tiles: const [
        HomeTile.module(DisplayModule.readouts, deviceId: 'DEV-A'),
        HomeTile.device('DEV-A'),
      ]);
      addTearDown(() => teardown(tester, s));
      await pumpEditor(tester, s);

      // The gesture that was idle before design 0054: the card body is an
      // `AbsorbPointer`, which claims the hit and passes nothing to the card.
      await tester.tap(find.text('LIVE READINGS').first, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Card appearance'), findsOneWidget);
      expect(find.text('FRAME'), findsOneWidget);

      await tester.tap(find.text('Minimal'));
      await tester.pump();
      // A real await, not a fake-clock settle: the write goes through sqflite,
      // whose lock timer would otherwise be reported as a pending timer.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));

      final stored = HomeLayout.decode(s.settings.homeLayout)!;
      expect(stored.tiles.first.shell, CardShell.minimal);
      expect(stored.tiles[1].shell, CardShell.standard,
          reason: 'one card was styled, not the page');
    });

    testWidgets('the view row lists exactly this card\'s own vocabulary',
        (tester) async {
      final s = await boot(tester, tiles: const [
        HomeTile.module(DisplayModule.readouts, deviceId: 'DEV-A'),
        HomeTile.device('DEV-A'),
      ]);
      addTearDown(() => teardown(tester, s));
      await pumpEditor(tester, s);

      await tester.tap(find.text('LIVE READINGS').first, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('CONTENT'), findsOneWidget);
      expect(find.text('Grid'), findsOneWidget);
      expect(find.text('Big number'), findsOneWidget);
      // 🔴 Mechanism ① of design 0054 §1.1: another card's words are not on
      // this screen, so they cannot be chosen. The defect design 0041 shipped —
      // an option that exists and does nothing — is structurally impossible on
      // this axis.
      expect(find.text('Dial'), findsNothing);
      expect(find.text('Numbers'), findsNothing);

      await tester.tap(find.text('Big number'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(HomeLayout.decode(s.settings.homeLayout)!.tiles.first.view, 'big');
    });

    testWidgets('a card with fewer than two views gets no view row',
        (tester) async {
      // A control with one option is worse than no control. The device card
      // declares no views at all; the clock declares exactly one.
      final s = await boot(tester, tiles: const [
        HomeTile.device('DEV-A'),
        HomeTile.module(DisplayModule.readouts, deviceId: 'DEV-A'),
      ]);
      addTearDown(() => teardown(tester, s));
      await pumpEditor(tester, s);

      // The editor draws SAMPLE data (design 0051 §5), so the alias on screen
      // is the preview's, not the saved unit's.
      await tester.tap(find.text(kPreviewAlias).first, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Card appearance'), findsOneWidget);
      expect(find.text('FRAME'), findsOneWidget);
      expect(find.text('CONTENT'), findsNothing);
    });

    testWidgets('"apply frame to every card" is SHELL only', (tester) async {
      final s = await boot(tester, tiles: const [
        HomeTile.module(DisplayModule.readouts,
            deviceId: 'DEV-A', view: 'big'),
        HomeTile.device('DEV-A'),
        HomeTile.module(DisplayModule.gaugeVoltage, deviceId: 'DEV-A'),
      ]);
      addTearDown(() => teardown(tester, s));
      await pumpEditor(tester, s);

      await tester.tap(find.text('LIVE READINGS').first, warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Compact'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.tap(find.text('Apply frame to every card'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));

      final stored = HomeLayout.decode(s.settings.homeLayout)!;
      for (final t in stored.tiles) {
        expect(t.shell, CardShell.dense);
      }
      // The view did NOT travel: `big` means something on the readouts card and
      // nothing on the other two, so there is no "apply to all" to perform.
      expect(stored.tiles[0].view, 'big');
      expect(stored.tiles[2].view, isNull);
    });

    testWidgets('S-R4: the HOME page grows no style control', (tester) async {
      // Design 0040 removed the readouts card's own mode toggle, and design
      // 0054 must not put one back under another name. The check is the same one
      // `readouts_card.dart` describes: the slot exists, and nothing uses it.
      expect(
        const IndustrialCard(child: SizedBox()).headingTrailing,
        isNull,
      );
      final tele = teleOf(previewPackSample(kNow));
      await pumpCard(tester,
          module: DisplayModule.readouts,
          cls: ProductClass.smartBattery,
          tele: tele,
          view: 'big');
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(SegmentedButton<Object?>), findsNothing);
    });
  });
}
