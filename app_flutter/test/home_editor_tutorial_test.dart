// The home editor's tutorial dialog (design 0053).
//
// 🔴 This feature exists because a ruling was overturned, and the ruling it
// replaced was ALSO enforced by a test. Design 0049 G5 and design 0046 §4.7 R11
// said the editor carries no explanatory text; the owner overturned that on
// 2026-08-09 for this screen only. What did NOT move is the floor guard — the
// last card is still undeletable via a DEAD BUTTON, never via a message — and
// `home_editor_test.dart` keeps asserting it, narrowed rather than deleted.
//
// The four assertions here that are not decoration:
//
//  * The dialog opens on a first visit and does not open on a second. That is
//    the whole promise of a one-time notice, and it is the half that a marker
//    written at the wrong moment silently breaks.
//  * UNCHECKING the box CLEARS the marker. The box starts checked (ruling M3),
//    so the only way it is not decoration in one of its two positions is if the
//    unchecked state does real work. A "don't show again" that can only ever
//    set a flag is a control that lies about being a toggle.
//  * The ? action re-opens it. The marker is one-way from the user's side
//    otherwise, and design 0053's whole argument for auto-showing is that
//    nothing is lost by dismissing it.
//  * It does not overflow at 1.15× (the app's own base scale, always applied)
//    stacked on a large OS setting, on a 320 pt phone. Four illustrated
//    paragraphs in a fixed-height Column is precisely the shape that ships a
//    striped RenderFlex bar — `narrow_tile_layout_test.dart` was written after
//    that happened on the G card.
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
import 'package:open_smart_batt/ui/home/home_editor_page.dart';
import 'package:open_smart_batt/ui/home/home_editor_tutorial.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late Directory markerDir;
  setUp(() async {
    // A temp dir per test, so "the marker exists" is a fact this test created
    // rather than one left behind by the previous one.
    markerDir = await Directory.systemTemp.createTemp('osb_ack');
    AckMarker.debugDirectoryOverride = markerDir;
  });
  tearDown(() {
    AckMarker.debugDirectoryOverride = null;
    if (markerDir.existsSync()) markerDir.deleteSync(recursive: true);
  });

  bool markerExists() =>
      File('${markerDir.path}/home_editor_tutorial_ack_v1').existsSync();

  Future<AppServices> boot(WidgetTester tester) async {
    late final AppServices s;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      s = await AppServices.create(appDatabase: db, ble: _FakeBle());
      await s.devices.saveNew('DEV-0', 'unit 0',
          productClass: ProductClass.smartBattery);
    });
    return s;
  }

  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => s.pending.drain());
    await s.dispose();
  }

  Future<void> pumpEditor(
    WidgetTester tester,
    AppServices s, {
    Size size = const Size(900, 2400),
    double textScale = AppTheme.baseTextScale,
  }) async {
    tester.view.physicalSize = size;
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
          // The app applies its own 1.15× on top of the OS setting in
          // `main.dart`; a test surface without it would measure a screen no
          // user ever sees.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const HomeEditorPage(),
        ),
      ),
    );
    // Two pumps + a frame budget: the marker read is a Future resolved in
    // `initState`'s post-frame callback, and `showDialog` then has a route
    // transition to run.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('an unacknowledged marker opens it on the first visit',
      (tester) async {
    final s = await boot(tester);
    addTearDown(() => teardown(tester, s));
    expect(markerExists(), isFalse, reason: 'sanity: nothing acknowledged yet');

    await pumpEditor(tester, s);

    expect(find.text('How editing works'), findsOneWidget);
    expect(find.text('Got it'), findsOneWidget);
    expect(find.text("Don't show this again"), findsOneWidget);
  });

  testWidgets('an acknowledged marker keeps it shut', (tester) async {
    final s = await boot(tester);
    addTearDown(() => teardown(tester, s));
    await tester.runAsync(() => kHomeEditorTutorialAck.markAcknowledged());
    expect(markerExists(), isTrue);

    await pumpEditor(tester, s);

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Got it'), findsNothing);
  });

  testWidgets('leaving the box CHECKED writes the marker', (tester) async {
    // The box starts checked (ruling M3), so the default path is "seen once".
    final s = await boot(tester);
    addTearDown(() => teardown(tester, s));
    await pumpEditor(tester, s);
    expect(find.text('Got it'), findsOneWidget);

    await tester.tap(find.text('Got it'));
    await settle(tester);

    expect(find.byType(Dialog), findsNothing, reason: 'it should have closed');
    expect(markerExists(), isTrue);
  });

  testWidgets(
      '🔴 UNCHECKING the box leaves no marker, so it opens again next visit',
      (tester) async {
    // Without this, the checkbox is decoration in one of its two positions —
    // it would look like a choice while only ever having one outcome.
    final s = await boot(tester);
    addTearDown(() => teardown(tester, s));
    await pumpEditor(tester, s);

    await tester.tap(find.text("Don't show this again"));
    await tester.pump();
    await tester.tap(find.text('Got it'));
    await settle(tester);

    expect(markerExists(), isFalse,
        reason: 'the box was unchecked; writing anyway would make it a lie');

    // …and the promise it just made is kept: a FRESH mount of the page reads
    // the marker again and finds nothing, so the dialog returns. Re-mounting
    // rather than re-booting the services — a second `AppServices` here would
    // be disposed twice by the tear-downs, which hangs the runner.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await pumpEditor(tester, s);
    expect(find.text('How editing works'), findsOneWidget);
  });

  testWidgets('🔴 the ? action re-opens it after it has been acknowledged',
      (tester) async {
    // The amber colour is asserted too. The entry point to this page is a MUTED
    // `Icons.tune` on the home grid, and the field result of that was a user
    // reporting the feature did not exist (2026-08-07). A grey help icon would
    // be the same defect one screen further in.
    final s = await boot(tester);
    addTearDown(() => teardown(tester, s));
    await tester.runAsync(() => kHomeEditorTutorialAck.markAcknowledged());
    await pumpEditor(tester, s);
    expect(find.byType(Dialog), findsNothing, reason: 'sanity: it is shut');

    final help = find.byIcon(Icons.help_outline);
    expect(help, findsOneWidget);
    expect(tester.widget<Icon>(help).color, AppColors.amber,
        reason: 'muted is the colour that made the home-page edit entry '
            'invisible to a real user');

    await tester.tap(help);
    await settle(tester);
    expect(find.text('How editing works'), findsOneWidget);
  });

  testWidgets('🔴 it does not overflow at 1.15× × 1.6 on a 320 pt phone',
      (tester) async {
    // 320 × 568 is the smallest screen the app supports, and the scale is the
    // app's own base times a large-but-ordinary OS setting. Four illustrated
    // paragraphs in a Column is the shape that ships a striped bar: the
    // maxHeight clamp plus the SingleChildScrollView are what stop it, and
    // removing either must fail here.
    final s = await boot(tester);
    addTearDown(() => teardown(tester, s));
    await pumpEditor(tester, s,
        size: const Size(320, 568),
        textScale: AppTheme.baseTextScale * 1.6);

    expect(find.text('How editing works'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'a RenderFlex overflow in the tutorial at 320 pt / 1.84×');
    // The button has to remain reachable — a dialog whose only exit is pushed
    // off the bottom is worse than an ugly one.
    expect(find.text('Got it'), findsOneWidget);
    final button = tester.getRect(find.text('Got it'));
    expect(button.bottom, lessThanOrEqualTo(568),
        reason: 'the only way out must be on screen');
  });

  testWidgets('every line describes a gesture the editor really has',
      (tester) async {
    // Design 0053 §4. The failure mode is a tutorial that teaches long-press or
    // swipe-to-delete — neither exists here, and a user who tries one concludes
    // the app is broken rather than that the text was wrong.
    final s = await boot(tester);
    addTearDown(() => teardown(tester, s));
    await pumpEditor(tester, s);

    for (final absent in [
      'long press',
      'long-press',
      'swipe',
      'double tap',
      'double-tap',
      'pinch',
      'tap the card',
      'drag it off',
    ]) {
      expect(find.textContaining(absent, findRichText: true), findsNothing,
          reason: '"$absent" is not implemented in home_editor_page.dart');
    }
    // …and the four things that ARE implemented are all named, so the check
    // above is not vacuous.
    expect(find.textContaining('handle'), findsWidgets);
    expect(find.textContaining('swap places'), findsWidgets);
    expect(find.textContaining('half width'), findsWidgets);
    expect(find.textContaining('no save button'), findsWidgets);
  });
}
