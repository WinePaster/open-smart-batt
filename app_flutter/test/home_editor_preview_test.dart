// The home editor draws SAMPLE DATA, and mounts no sensor (design 0051 §5/§6).
//
// Owner ruling 2026-08-09:「請堅持編輯主頁就是假資料 … 只有回到主頁才是真實
// 資料」and「不用放提示文字：示範」.
//
// Two invariants, and neither is cosmetic:
//
//  T-editor-1 — 🔴 THE GNSS / ACCELEROMETER HOLE. Before this change, `speed`
//    and `gForce` tiles were counted LIVE in the editor (they read the phone,
//    not a device), so the real `SpeedCard` / `GForceCard` mounted and their
//    `didChangeDependencies` opened the receivers. The editor is a PUSHED
//    route while the shell's tab is still `home`, so all three of design
//    0042's gate conditions were satisfied: arranging your home page ran your
//    GPS. It shipped, and no test looked at it.
//
//    This test opens conditions 2 and 3 by hand (`setAppResumed`,
//    `setDashboardVisible`) so that condition 1 — "a speed card is mounted" —
//    is the ONLY thing left deciding. Without that the assertion would pass
//    vacuously in any widget test, which is exactly how the hole survived.
//
//    Design 0052 adds `clock` to the same group for a much smaller reason: it
//    arms a one-minute timer rather than a sensor. The RULE is identical — the
//    editor mounts extracted bodies, never live cards — and keeping the third
//    case beside the two is what stops "phone modules are previewed" from
//    being remembered as "SENSOR modules are previewed".
//
//  T-editor-2 — every `DisplayModule` renders a real card body here, never the
//    waiting tile. The failure it guards is a CALLER defect of the kind
//    `display_module.dart` names: a module added to the enum and forgotten in
//    the preview would silently degrade to "heading + `--`", and the whole
//    point of the ruling is that the editor must show heights that differ.
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
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
import 'package:open_smart_batt/ui/dashboard/clock_card.dart';
import 'package:open_smart_batt/ui/dashboard/display_modules.dart';
import 'package:open_smart_batt/ui/dashboard/g_force_card.dart';
import 'package:open_smart_batt/ui/dashboard/speed_card.dart';
import 'package:open_smart_batt/ui/home/home_editor_page.dart';
import 'package:open_smart_batt/ui/home/home_editor_tutorial.dart';
import 'package:open_smart_batt/ui/home/home_preview.dart';
import 'package:open_smart_batt/ui/home/home_tiles.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;
}

/// A valid, right-handed, orthonormal calibration — the identity is fine as
/// stored content; what matters is that it decodes, so the G meter is
/// AVAILABLE and its tile survives `renderedFor`.
const String kCalibration = '{"m":[1,0,0,0,1,0,0,0,1],"at":1754524800000}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  // design 0053: the editor opens a tutorial dialog on the first visit. These
  // tests are about what the editor DRAWS, so the marker is pre-set — a modal
  // barrier over the grid would make every assertion below about a covered
  // screen. The dialog has its own test file.
  late Directory markerDir;
  setUp(() async {
    markerDir = await Directory.systemTemp.createTemp('osb_ack');
    AckMarker.debugDirectoryOverride = markerDir;
    await kHomeEditorTutorialAck.markAcknowledged();
  });
  tearDown(() {
    AckMarker.debugDirectoryOverride = null;
    if (markerDir.existsSync()) markerDir.deleteSync(recursive: true);
  });

  Future<AppServices> boot(
    WidgetTester tester, {
    required List<HomeTile> tiles,
    ProductClass cls = ProductClass.smartBattery,
  }) async {
    late final AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      s = await AppServices.create(appDatabase: db, ble: _FakeBle());
      // A class is required since design 0050 D4 — the resolver drops every
      // tile belonging to an unidentified unit, and the editor edits the
      // resolved list.
      await s.devices.saveNew('DEV-A', 'unit A', productClass: cls);
      // Both phone switches ON, with a calibration, so both phone tiles are
      // AVAILABLE. Anything less and "no speed card was mounted" would be true
      // because the tile was filtered out, not because the editor previews it.
      await s.settings.setSpeedDetection(true);
      await s.settings.setGMeterEnabled(true);
      await s.settings.setGCalibration(kCalibration);
      await s.settings.setHomeLayout(HomeLayout(tiles).encode());
    });
    return s;
  }

  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => s.pending.drain());
    await s.dispose();
  }

  Future<void> pumpEditor(WidgetTester tester, AppServices s) async {
    tester.view.physicalSize = const Size(900, 4000);
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
          home: const HomeEditorPage(),
        ),
      ),
    );
    await tester.pump();
    // Post-frame callbacks are how `SpeedCard` / `GForceCard` report
    // themselves to their controllers, so the assertions below must run AFTER
    // one has had the chance to fire. Pumping only once would make T-editor-1
    // pass on a race rather than on the design.
    await tester.pump(const Duration(milliseconds: 50));
  }

  // =========================================================================
  // T-editor-1 — no sensor is started by opening the editor
  // =========================================================================
  group('T-editor-1: the editor mounts no phone card and starts no sensor', () {
    testWidgets('speed and G tiles draw, and neither receiver opens',
        (tester) async {
      final s = await boot(tester, tiles: const [
        HomeTile.module(DisplayModule.speed),
        HomeTile.module(DisplayModule.gForce),
        HomeTile.device('DEV-A'),
      ]);
      addTearDown(() => teardown(tester, s));

      // 🔴 Open gate conditions 2 and 3 BEFORE pumping, so condition 1 is the
      // only one left. Without this the test proves nothing: `streaming` is
      // false in a bare widget test whatever the cards do.
      s.speed.setAppResumed(true);
      s.speed.setDashboardVisible(true);
      s.gforce.setAppResumed(true);
      s.gforce.setDashboardVisible(true);
      expect(s.gforce.available, isTrue,
          reason: 'otherwise the G tile is filtered out and this is vacuous');

      await pumpEditor(tester, s);

      // The tiles ARE on the page — the preview draws them.
      expect(find.text(kPreviewAlias), findsOneWidget);
      expect(find.byType(SpeedCardBody), findsOneWidget);
      expect(find.byType(GForceCardBody), findsOneWidget);

      // …and not one live card, so not one open receiver.
      expect(find.byType(SpeedCard), findsNothing,
          reason: 'mounting a SpeedCard is design 0042 gate condition 1');
      expect(find.byType(GForceCard), findsNothing);
      expect(s.speed.streaming, isFalse,
          reason: 'arranging a home page must not run the GNSS receiver');
      expect(s.gforce.streaming, isFalse);
      expect(s.speed.permission, SpeedPermissionState.notRequested,
          reason: 'and the OS was never asked, because nothing asked it');
    });

    testWidgets('the drag ghost is a chip, so a drag cannot mount a second one',
        (tester) async {
      // Before design 0051 the ghost was a whole `HomeTileView`, so dragging a
      // speed tile mounted a SECOND `SpeedCard` — two widgets pushing one
      // uncounted boolean gate, which is how a release could leave the stream
      // open. The ghost draws a name now and has no card in it at all.
      final s = await boot(tester, tiles: const [
        HomeTile.module(DisplayModule.speed),
        HomeTile.device('DEV-A'),
      ]);
      addTearDown(() => teardown(tester, s));
      s.speed.setAppResumed(true);
      s.speed.setDashboardVisible(true);
      await pumpEditor(tester, s);

      final handle = find.byIcon(Icons.drag_indicator).first;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(const Offset(0, 160));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(SpeedCard), findsNothing);
      expect(s.speed.streaming, isFalse);
      // Exactly one preview body: the cell's. The ghost adds none.
      expect(find.byType(SpeedCardBody), findsOneWidget);

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
      expect(s.speed.streaming, isFalse);
    });

    testWidgets('🔴 the clock previews a FIXED time and arms no timer',
        (tester) async {
      // design 0052 §7. The clock is the one card whose real value is always
      // available, which makes it the one card somebody would be tempted to
      // let run here — and a single live tile among eight sampled ones makes
      // the other eight look broken rather than sampled. Owner ruling
      // 2026-08-09:「請堅持編輯主頁就是假資料」.
      //
      // There is no「示範」label on it either:「不用放提示文字：示範」.
      final s = await boot(tester, tiles: const [
        HomeTile.module(DisplayModule.clock),
        HomeTile.device('DEV-A'),
      ]);
      addTearDown(() => teardown(tester, s));
      await pumpEditor(tester, s);

      // The BODY, never the live card — the same seam that keeps `SpeedCard`
      // out, for a smaller reason (a wasted rebuild, not a receiver).
      expect(find.byType(ClockCardBody), findsOneWidget);
      expect(find.byType(ClockCard), findsNothing,
          reason: 'mounting a ClockCard arms a one-minute timer');
      // The mockup's own 19:50, rendered as `7:50 PM` because the test host
      // reports 12-hour (`alwaysUse24HourFormat` is false on the default test
      // view). That the FORMAT follows the platform rather than the app is
      // pinned in `clock_card_test.dart`; what matters here is the INSTANT.
      expect(find.text('7:50'), findsOneWidget);
      expect(find.text('PM'), findsOneWidget);

      // …and ten minutes later it still reads the same time, because nothing
      // is ticking. If a timer HAD been armed, `flutter_test` would also fail
      // this test at teardown with "A Timer is still pending".
      await tester.pump(const Duration(minutes: 10));
      expect(find.text('7:50'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // =========================================================================
  // T-editor-2 — every module has sample data
  // =========================================================================
  //
  // Swept over the ENUM, not over a hand-written list, for the reason
  // `display_module.dart` gives: a hardcoded inventory is how the next member
  // slips past, and that has happened four times in this project.
  group('T-editor-2: every module draws a real card body, never `--`', () {
    for (final cls in [ProductClass.smartBattery, ProductClass.powerBank]) {
      for (final m in DisplayModule.values) {
        // `forClass` decides what a class HAS; a module it does not have is
        // legitimately absent, and the editor's add-menu never offers it. Only
        // the modules a class can actually place are swept.
        testWidgets('${cls.name} / ${m.name}', (tester) async {
          final entry = DisplayModules.forClass(cls);
          final placeable = m.isPhoneModule || (entry?.has(m) ?? false);
          if (!placeable) return;
          final s = await boot(
            tester,
            cls: cls,
            tiles: [
              HomeTile.module(m, deviceId: m.isPhoneModule ? null : 'DEV-A'),
              const HomeTile.device('DEV-A'),
            ],
          );
          addTearDown(() => teardown(tester, s));
          await pumpEditor(tester, s);

          expect(find.byType(HomeWaitingTile), findsNothing,
              reason: '${m.name} has no sample data in `home_preview.dart`, so '
                  'the editor shows it as an unidentifiable `--` box — which '
                  'is the whole defect the 2026-08-09 ruling was about');
        });
      }
    }

    testWidgets('and the sample values are the layout-stressing ones',
        (tester) async {
      // Spot-checked rather than exhaustively pinned: what matters is that the
      // numbers stayed EXTREME. A preview of tidy two-digit values invites a
      // layout that just fits, and the first real reading then overflows it —
      // the failure `narrow_tile_layout_test.dart` and
      // `value_text_scaling_test.dart` already exist for.
      final s = await boot(tester, tiles: const [
        HomeTile.module(DisplayModule.readouts, deviceId: 'DEV-A'),
        HomeTile.device('DEV-A'),
      ]);
      addTearDown(() => teardown(tester, s));
      await pumpEditor(tester, s);

      // Four readouts is the pack grid's tallest state (2x2), and −128.4 is
      // the widest number it can be asked to print.
      // `findRichText`, because a readout tile composes value + unit into ONE
      // `Text.rich` (`readout_grid.dart`), so the plain text carries the unit.
      //
      // 🔴 MAGNITUDE, not the signed number, since design 0056: the sample is
      // still −128.4 and the tile now prints `128.4 A` with a DISCHARGING
      // badge. That is MORE layout stress, not less — the widest number plus
      // the longest direction word, on the tallest grid — which is why the
      // preview sample was left alone.
      expect(find.text('128.4 A', findRichText: true), findsOneWidget);
      expect(find.text('-128.4 A', findRichText: true), findsNothing);
      expect(find.text('DISCHARGING'), findsOneWidget);
      expect(find.text('41 °C', findRichText: true), findsOneWidget);
      expect(find.text('45 %', findRichText: true), findsOneWidget);
      // The device tile: an alias long enough to ellipsis, over a 4-significant
      // -figure voltage.
      expect(find.text(kPreviewAlias), findsOneWidget);
      expect(find.text('13.87'), findsOneWidget);
    });

    testWidgets('a power bank previews its OWN cards, not a battery\'s',
        (tester) async {
      // design 0051 §5.4. The class follows the tile's device, because the
      // readouts grid and the trend chart carry different content per class —
      // faking everything as a battery would show the wrong card to exactly
      // the people who need to see the right one.
      final s = await boot(
        tester,
        cls: ProductClass.powerBank,
        tiles: const [
          HomeTile.module(DisplayModule.energyPath, deviceId: 'DEV-A'),
          HomeTile.device('DEV-A'),
        ],
      );
      addTearDown(() => teardown(tester, s));
      await pumpEditor(tester, s);

      expect(find.byType(HomeWaitingTile), findsNothing);
      // The widest branch of the energy-path row: a port badge, a PD badge,
      // the direction and both readings. `flagsContradicted` would suppress
      // every badge, which is why the sample's b7 is 0x22 and not 0x00.
      expect(find.text('Type-C'), findsOneWidget);
      expect(find.text('PD'), findsOneWidget);
      expect(find.text('9.05 V'), findsOneWidget);
      expect(find.text('2.72 A'), findsOneWidget);
      // …and the device tile reads SOC, because its class says so.
      expect(find.text('100'), findsOneWidget);
    });
  });

  // =========================================================================
  // T-editor-3 — the sample data must not overflow the layout it is previewing
  // =========================================================================
  //
  // The values in `home_preview.dart` are chosen to be the WIDEST plausible
  // rendering, which is the point — but a preview that overflows its own tile
  // draws the striped RenderFlex bar and teaches the user nothing except that
  // the app is broken. This is the check that keeps "extreme" from becoming
  // "impossible": every module, at HALF width, on a 320 dp phone.
  //
  // A layout overflow is a thrown assertion in a widget test, so the test body
  // needs no expectation beyond pumping — but one is written anyway, because a
  // silent no-op test is worse than none.
  group('T-editor-3: no sample value overflows a 1x1 tile on a small phone',
      () {
    for (final m in DisplayModule.values) {
      testWidgets(m.name, (tester) async {
        final entry = DisplayModules.forClass(ProductClass.smartBattery);
        if (!m.isPhoneModule && !(entry?.has(m) ?? false)) return;
        final s = await boot(tester, tiles: [
          HomeTile.module(m,
              deviceId: m.isPhoneModule ? null : 'DEV-A',
              span: HomeSpan.half),
          const HomeTile.device('DEV-A', span: HomeSpan.half),
        ]);
        addTearDown(() => teardown(tester, s));
        tester.view.physicalSize = const Size(320, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              Provider<BleService>.value(value: s.ble),
              ChangeNotifierProvider<SettingsController>.value(
                  value: s.settings),
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
        expect(find.byType(HomeWaitingTile), findsNothing);
      });
    }
  });
}
