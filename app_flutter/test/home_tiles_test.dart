// T-new-3 — a number on the home page is either LIVE or DATED. Never neither.
//
// A saved device stores two numeric facts and only two: `lastValue` and
// `lastSeen`. Everything else a card could show — current, temperature, per-cell
// voltage — simply does not exist while the unit is not connected, because the
// advertisement carries none of it.
//
// So the home page has exactly one way to be dishonest, and it is cheap to
// build by accident: print `lastValue` large, leave the age off, and the page
// reads as live. FB-43 is that mistake's ancestor — a power bank's single-cell
// 3.79 V rendered on a pack's 12 V dial — and design 0046 §4.7 explicitly
// exempts timestamps from the "say it with navigation, not words" discipline
// for this reason: a timestamp is not an explanation, it is provenance.
//
// CLEAN-ROOM: expectations derive from this project's own source and field
// reports.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'dart:io';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/ui/dashboard/display_modules.dart';
import 'package:open_smart_batt/ui/home/home_tiles.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/home/home_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  String? connectedId;

  @override
  String? get connectedDeviceId => connectedId;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late _FakeBle ble;

  Future<AppServices> boot(WidgetTester tester,
      {required List<SavedDevice> devices}) async {
    late final AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _FakeBle();
      s = await AppServices.create(appDatabase: db, ble: ble);
      for (final d in devices) {
        await s.devices.save(d);
      }
    });
    return s;
  }

  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => s.pending.drain());
    await s.dispose();
  }

  Future<void> pumpHome(WidgetTester tester, AppServices s,
      {VoidCallback? onEdit}) async {
    tester.view.physicalSize = const Size(900, 2400);
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
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
          ChangeNotifierProvider<GpsSpeedController>.value(value: s.speed),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: HomePage(onEdit: onEdit)),
        ),
      ),
    );
    await tester.pump();
  }

  group('T-new-3: an offline device card never shows a number without its age',
      () {
    testWidgets('the value and the age appear together', (tester) async {
      final s = await boot(tester, devices: [
        SavedDevice(
          id: 'A',
          alias: 'Cap #1',
          lastValue: 12.64,
          lastSeen: DateTime.now().subtract(const Duration(minutes: 3)),
        ),
        SavedDevice(
          id: 'B',
          alias: 'Cap #2',
          lastValue: 11.10,
          lastSeen: DateTime.now().subtract(const Duration(days: 2)),
        ),
      ]);
      addTearDown(() => teardown(tester, s));
      await pumpHome(tester, s);

      // Two devices ⇒ one card each (design 0046 §4.6).
      expect(find.text('Cap #1'), findsOneWidget);
      expect(find.text('12.64'), findsOneWidget);
      expect(find.text('3 minutes ago'), findsOneWidget);
      expect(find.text('11.10'), findsOneWidget);
      expect(find.text('2 days ago'), findsOneWidget);

      // Nothing on this page claims to be live.
      expect(find.text('LIVE'), findsNothing,
          reason: 'the LIVE marker is the only thing a connected card carries; '
              'an offline one must not borrow it');
    });

    testWidgets('with no lastSeen the number is withheld too', (tester) async {
      // The stricter of the two honest options: an undated number is the exact
      // shape of the mistake this test exists for, so it is not rendered at all.
      final s = await boot(tester, devices: [
        const SavedDevice(id: 'A', alias: 'Cap #1', lastValue: 12.64),
        const SavedDevice(id: 'B', alias: 'Cap #2', lastValue: 11.10),
      ]);
      addTearDown(() => teardown(tester, s));
      await pumpHome(tester, s);

      expect(find.text('Cap #1'), findsOneWidget);
      expect(find.text('12.64'), findsNothing,
          reason: 'there is no age to put beside it, so there is no honest way '
              'to show it');
      expect(find.text('Never connected'), findsWidgets);
    });

    testWidgets('an offline module tile waits, it does not borrow lastValue',
        (tester) async {
      // A single saved device generates [device card, gauge, readouts]
      // (design 0046 §4.6, card added 2026-08-07). Offline, the two MODULE
      // tiles have nothing to draw: `SavedDevice` stores no temperature and no
      // current, and filling the gauge from `lastValue` without an age would be
      // the same defect one card along.
      //
      // The device card DOES print `lastValue` — with its age, which is the
      // whole distinction this group is about. So the assertion below counts:
      // exactly one place on the page may show that number, and a module tile
      // that started borrowing it would make two.
      final s = await boot(tester, devices: [
        SavedDevice(
          id: 'A',
          alias: 'Cap #1',
          lastValue: 12.64,
          lastSeen: DateTime.now().subtract(const Duration(minutes: 3)),
        ),
      ]);
      addTearDown(() => teardown(tester, s));
      await pumpHome(tester, s);

      expect(find.text('--'), findsWidgets);
      expect(find.text('12.64'), findsOneWidget,
          reason: 'a module tile has no timestamp to carry, so it shows the '
              'waiting state instead of a stored number — only the device '
              'card, which does carry one, may print it');
      expect(find.text('LIVE'), findsNothing);
    });

    testWidgets('a card for a unit that is NOT the connected one still waits',
        (tester) async {
      // FB-41's attribution mistake, moved into the UI: with A connected, B's
      // card must not draw A's telemetry.
      final s = await boot(tester, devices: [
        SavedDevice(
          id: 'A',
          alias: 'Cap #1',
          lastValue: 12.64,
          lastSeen: DateTime.now(),
        ),
        SavedDevice(
          id: 'B',
          alias: 'Cap #2',
          lastValue: 11.10,
          lastSeen: DateTime.now().subtract(const Duration(hours: 2)),
        ),
      ]);
      addTearDown(() => teardown(tester, s));
      ble.connectedId = 'A';
      await pumpHome(tester, s);
      await tester.runAsync(() async {
        ble.emitLink(BleLinkState.ready);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();

      // A is live, B is not — and B still says when it was last seen.
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('2 hours ago'), findsOneWidget);
      expect(find.text('11.10'), findsOneWidget,
          reason: 'B keeps its dated last reading; what it must not do is take '
              "A's live one");
    });
  });

  group('the zero-device home page still has something on it (T-new-2)', () {
    testWidgets('an empty install shows the add-device card', (tester) async {
      final s = await boot(tester, devices: const []);
      addTearDown(() => teardown(tester, s));
      await pumpHome(tester, s);

      expect(find.text('Add your first device'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // 2026-08-07 交付一查核, B-1. A connected power bank rendered its whole
  // default home page as `--`, and 1052 tests were green: home_layout_test
  // covers the model only, and this file had never pumped a live power bank.
  // The decision is now a named function so the branch is reachable at all.
  // ---------------------------------------------------------------------------
  group('B-1: a live power bank draws its own cards, not the unclassified set',
      () {
    test('a real power bank resolves to powerBank, not unknown', () {
      // packShellClass(powerBank) == unknown. displayClass has ALREADY folded a
      // stray powerBank LABEL to unknown, so a second application demotes the
      // real thing. This is the assertion the bug could not have survived.
      expect(DisplayModules.packShellClass(ProductClass.powerBank),
          ProductClass.unknown,
          reason: 'the quirk itself is unchanged — it is the double '
              'application that was wrong');
      expect(homeTileShellClass('DEV-PB', _StubConn(ProductClass.powerBank)),
          ProductClass.powerBank);
    });

    test('a stray powerBank LABEL on the pack route still folds to unknown',
        () {
      // displayClass does that fold itself; the home tile must not undo it and
      // must not repeat it.
      expect(homeTileShellClass('DEV-PACK', _StubConn(ProductClass.unknown)),
          ProductClass.unknown);
    });

    test('the modules a power bank home page asks for actually exist', () {
      // The other half: even with the right class, the default layout is only
      // useful if these two resolve. `defaultFor` gives a lone power bank
      // exactly [gaugeSoc, readouts].
      final mods = DisplayModules.forClass(ProductClass.powerBank).modules;
      expect(mods, contains(DisplayModule.gaugeSoc));
      expect(mods, contains(DisplayModule.energyPath));
      expect(DisplayModules.forClass(ProductClass.unknown).modules,
          isNot(contains(DisplayModule.gaugeSoc)),
          reason: 'this is why the double application showed `--`');
    });
  });

  // ---------------------------------------------------------------------------
  // 2026-08-07 交付一查核, B-2. T-new-3 pins "a number never appears without its
  // age". It did — and the number could still be weeks older than the age
  // beside it, because `last_value` was written once (at saveNew) while
  // `last_seen` advanced every minute. The invariant was satisfied to the
  // letter and the sentence was false.
  //
  // The existing T-new-3 tests could not catch it: they build a SavedDevice by
  // hand with the two fields already agreeing, which is exactly the thing that
  // does not happen in the app.
  // ---------------------------------------------------------------------------
  test('B-2: the stored value travels with the stored age', () {
    // Source-level, because the defect is about WHO writes the pair and WHEN —
    // a widget test that constructs the row cannot see it.
    final src = File('lib/state/connection_controller.dart').readAsStringSync();
    final touchSig = RegExp(r'void _touchLastSeen\([^)]*\)').firstMatch(src);
    expect(touchSig, isNotNull);
    expect(touchSig!.group(0), contains('double? value'),
        reason: 'the throttled last_seen write is the only place that runs '
            'once a minute with a live sample in scope — if it cannot carry '
            'the value, the value cannot stay fresh');

    // And the telemetry-driven call site must actually pass one. A signature
    // that nobody feeds is the same bug with extra steps.
    expect(src, contains('_touchLastSeen(id, value: s.pvlt)'),
        reason: 'the per-frame path must hand over the sample it already has');
  });


  // ---------------------------------------------------------------------------
  // 2026-08-07 0044/0045 查核, B1. The home grid is the THIRD path that can
  // mount a card, and it never went through `renderedModules` — so a stored
  // `speed` tile opened the GNSS stream with 速度偵測 OFF and the consent
  // dialog never shown, while the export preamble said `speed detection: off`.
  //
  // ⚠️ The main agent's own reflexive check (delete the filter inside
  // `renderedModules` ⇒ tests red) could not reach this by construction: this
  // path does not call that function. Recorded because "I verified the fix"
  // and "I verified every path" are different claims.
  // ---------------------------------------------------------------------------
  test('B1: a phone module is only drawable when its own switch says so', () {
    // Source-level, because the leak is about WHICH SURFACES ask the question.
    // A widget test proves one surface; this proves no surface was forgotten.
    // Two surfaces, two resolvers, one shared fact (ruled 2026-08-07: the home
    // grid and the watchface layer stay separate systems). Each surface must
    // reach the screen through ITS resolver — that is where the gate lives.
    final surfaces = <String, String>{
      'lib/ui/home/home_page.dart': '.renderedFor(',
      'lib/ui/home/home_editor_page.dart': '.renderedFor(',
      'lib/ui/dashboard/pack_view.dart': 'renderedModules(',
      'lib/ui/dashboard/power_bank_view.dart': 'renderedModules(',
    };
    for (final e in surfaces.entries) {
      expect(File(e.key).readAsStringSync(), contains(e.value),
          reason: '${e.key} puts modules on screen without asking its '
              'surface resolver — a phone module can reach the screen there '
              'with its switch off, and for `speed` that opens the GNSS '
              'stream with the consent dialog never shown');
    }

    // And the tile widget must NOT re-gate: one decision point per surface.
    expect(File('lib/ui/home/home_tiles.dart').readAsStringSync(),
        isNot(contains('phoneModuleAvailable(')),
        reason: 'the resolver already decided; a second check here is the '
            'duplicate decision point design 0042 W4 removed');

    final callers = <String>[
      'lib/ui/home/home_tiles.dart',
      'lib/ui/dashboard/pack_view.dart',
      'lib/ui/dashboard/power_bank_view.dart',
    ];
    // The list above is only honest if it is complete.
    final grep = Process.runSync('grep',
        ['-rl', 'dashboardCardFor(', 'lib/'], runInShell: false);
    final actual = (grep.stdout as String)
        .trim()
        .split('\n')
        .where((l) => l.isNotEmpty && !l.endsWith('dashboard_cards.dart'))
        .toSet();
    expect(actual, callers.toSet(),
        reason: 'a new caller of dashboardCardFor appeared; add it above and '
            'make sure it gates phone modules');
  });

  // ===========================================================================
  // 🔴 The "edit layout" row — 2026-08-07, from the field.
  //
  // The editor was NOT missing. It was reachable the whole time, from an 18px
  // grey `Icons.tune` beside the connection pill in the app bar. The owner
  // tested the build and reported the feature as absent, which is the only
  // measurement of findability that counts. So the entry point moved to where
  // the thing it edits is: the last row of the grid, after the cards.
  //
  // Both routes still exist and both go to the same place. What these tests pin
  // is that the ROW exists, that it does something, and — the part this project
  // keeps getting wrong — that its caller actually passes a callback.
  // ===========================================================================
  group('the edit-layout row', () {
    testWidgets('it is at the foot of the grid, and it fires', (tester) async {
      final s = await boot(tester, devices: [
        SavedDevice(id: 'A', alias: 'Cap #1', lastValue: 12.6,
            lastSeen: DateTime.now()),
      ]);
      addTearDown(() => teardown(tester, s));

      var taps = 0;
      await pumpHome(tester, s, onEdit: () => taps++);

      final row = find.text('Edit layout');
      expect(row, findsOneWidget);
      await tester.tap(row);
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('and it is absent when there is nothing wired to it',
        (tester) async {
      // Not a decorative distinction: a row that looks tappable and is not is
      // worse than no row. `onEdit` is nullable so the widget can be pumped
      // without a navigator, and this pins that the null case draws nothing
      // rather than a dead control.
      final s = await boot(tester, devices: []);
      addTearDown(() => teardown(tester, s));
      await pumpHome(tester, s);
      expect(find.text('Edit layout'), findsNothing);
    });

    test('🔴 the app actually passes it — the caller, not the callee', () {
      // The failure mode this project repeats (see estimate_wiring_test.dart,
      // and `visibleFor`-with-no-caller before it): the widget is right, the
      // tests of the widget are right, and nothing constructs it with the
      // argument. Derived from source so it cannot rot into a comment.
      final src = File('lib/main.dart').readAsStringSync();
      final at = src.indexOf('HomePage(');
      expect(at, isNonNegative, reason: 'main.dart must build the home page');
      // The whole argument list, found by matching parentheses — a naive
      // indexOf(')') stops at the first nested call and would pass while
      // reading two arguments.
      var depth = 0, end = at;
      for (var i = src.indexOf('(', at); i < src.length; i++) {
        if (src[i] == '(') depth++;
        if (src[i] == ')') {
          depth--;
          if (depth == 0) {
            end = i;
            break;
          }
        }
      }
      expect(end, greaterThan(at));
      final ctor = src.substring(at, end);
      expect(ctor, contains('onEdit:'),
          reason: 'HomePage takes onEdit and main.dart must supply it, or the '
              'row silently disappears again');
    });
  });

  // ===========================================================================
  // 🔴 A lone 1x1 FILLS the row — ruled 2026-08-07 from rendered comparisons.
  // ===========================================================================
  testWidgets('a half tile with no partner fills the row', (tester) async {
    // `HomeLayout.rows` pairs two ADJACENT halves and otherwise emits a row of
    // one. The alternative — the lone tile keeping its half and leaving the
    // rest empty — was built, rendered and rejected: it reads as broken rather
    // than deliberate, and it is the COMMON case, because `speed_detection`
    // defaults off and so the G meter loses its partner on almost every phone.
    //
    // ⚠️ This is the reason the home page cannot show that a tile is 1x1 when
    // it is alone. The editor preview is where that feedback lives now
    // (`home_editor_test.dart`, 'halving a tile halves its preview'), and the
    // two tests must be read together — changing either one alone re-opens
    // 「按了沒反應」.
    final s = await boot(tester, devices: [
      SavedDevice(id: 'A', alias: 'Cap #1', lastValue: 12.6,
          lastSeen: DateTime.now()),
      SavedDevice(id: 'B', alias: 'Cap #2', lastValue: 12.4,
          lastSeen: DateTime.now()),
    ]);
    addTearDown(() => teardown(tester, s));
    await tester.runAsync(() => s.settings.setHomeLayout(
          const HomeLayout([
            HomeTile.device('A', span: HomeSpan.half),
            HomeTile.device('B'),
          ]).encode(),
        ));
    await pumpHome(tester, s);

    final widths = [
      for (var i = 0; i < 2; i++)
        tester.getSize(find.byType(HomeTileView).at(i)).width,
    ];
    expect(widths[1], greaterThan(200), reason: 'sanity: the full tile');
    expect(widths[0], closeTo(widths[1], 1.0),
        reason: 'a lone half must fill its row, not leave a ragged column');
  });
}

/// Minimal stand-in: [homeTileShellClass] reads exactly one getter.
class _StubConn implements ConnectionController {
  _StubConn(this._cls);
  final ProductClass _cls;
  @override
  ProductClass get displayClass => _cls;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
