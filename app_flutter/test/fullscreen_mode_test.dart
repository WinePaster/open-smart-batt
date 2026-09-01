// Full-screen mode on the home tab (design 0062, FB-76).
//
// The feature is small — hide this app's own AppBar and NavigationBar — but two
// of its properties are the entire reason it needs a suite of its own, and
// neither is visible in a screenshot:
//
//   F3 — the shell's SafeArea flips to `top: true, bottom: true` when the
//        chrome goes away. Those two flags are `false` in the normal state
//        BECAUSE the AppBar and NavigationBar inset the top and bottom
//        themselves (main.dart, the comment above the SafeArea). Take the
//        chrome away without flipping them and the grid runs under the notch
//        and under the home indicator — 🔴 and that bug is INVISIBLE on
//        Android, where both insets are 0. Only a notched iPhone shows it, so
//        it is asserted here rather than left to a review.
//   F4/F5/F6 — the three exit routes, ruled 「三者都做」 (design 0062 Q1). They
//        are three NECESSARY conditions, not three backups: hiding the
//        NavigationBar removes the user's only way to change tabs, and this
//        project has already shipped two controls nobody could find (the home
//        editor button, and FB-70's 14×14 dp rename pencil). F5 therefore
//        MEASURES the exit button's tap target instead of asserting that the
//        widget exists — "it is in the tree" is exactly what was true of the
//        FB-70 pencil.
//
// F8 pins the other half of that ruling: full screen must NOT disturb gate
// condition 3 (design 0042 §3.4). It changes no tab, so the GNSS receiver and
// the G-force stream have to behave exactly as they do in the normal state —
// which matters because this mode exists FOR the riding readouts.
//
// CLEAN-ROOM: assertions derive from this project's own source and design docs.
import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/main.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inert BleService: never reaches the (unsupported) flutter_blue_plus platform.
class _FakeBleService extends BleService {
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  String? get connectedDeviceId => null;

  @override
  String get connectedDeviceName => '';

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 15),
  }) async {}

  @override
  Future<void> stopScan() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  /// Let the real (ffi) database finish whatever the last frame started.
  Future<void> drain(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  Future<AppServices> pumpShell(WidgetTester tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      services = await AppServices.create(
        appDatabase: appDb,
        ble: _FakeBleService(),
      );
    });
    await tester.pumpWidget(OpenSmartBattApp(services: services));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await drain(tester);
    // The one-time community disclaimer lands once its marker-file read
    // resolves, which only happens on the REAL event loop. Dismiss it, or it
    // absorbs every tap aimed at the shell underneath.
    final ack = find.text('我了解，開始使用');
    if (ack.evaluate().isNotEmpty) {
      await tester.tap(ack);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    return services;
  }

  /// The shell's own SafeArea: the innermost one wrapping the IndexedStack.
  /// Scaffold adds none of its own, so this is main.dart's.
  SafeArea shellSafeArea(WidgetTester tester) => tester.widget<SafeArea>(
    find
        .ancestor(
          of: find.byType(IndexedStack),
          matching: find.byType(SafeArea),
        )
        .first,
  );

  /// Tap something while immersive, and wait out the double-tap window.
  ///
  /// 🔑 The wait is a real property of the feature, not test noise. Exit route 3
  /// puts a [GestureDetector.onDoubleTap] above the whole body, so a SINGLE tap
  /// underneath it cannot be resolved until the double-tap timer expires
  /// (~300 ms). That is the price of 「雙擊畫面任一處」 and the owner's ruling paid
  /// it knowingly — but it means every tap inside full-screen mode lands late,
  /// so it is pinned here rather than discovered in the field.
  Future<void> tapWhileImmersive(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> enterFullscreen(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    // Removing 138 px of chrome makes every viewport in the IndexedStack taller
    // — including the offstage Settings list, which builds one more card, whose
    // initState issues a real (ffi) history query. Drain it on the real event
    // loop or its lock timer is still pending at teardown.
    await drain(tester);
  }

  testWidgets('F1: the default state keeps both bars', (tester) async {
    await pumpShell(tester);

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    // The way IN is the app-bar action, and it is the ONLY way in: design 0062
    // Q1 rules out a gesture for ENTERING, so a stray double tap can never
    // remove the chrome the user is currently using.
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit), findsNothing);

    final safe = shellSafeArea(tester);
    expect(safe.top, isFalse);
    expect(
      safe.bottom,
      isFalse,
      reason:
          'both are false BECAUSE the AppBar and NavigationBar inset the '
          'top and bottom themselves',
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('F2: entering full screen removes both bars', (tester) async {
    await pumpShell(tester);
    await enterFullscreen(tester);

    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    // …and the grid is still there. Hiding the chrome must not unmount the
    // page: an IndexedStack child that is rebuilt loses its scroll offset.
    expect(find.byType(IndexedStack), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('F3: SafeArea insets both edges once the chrome is gone', (
    tester,
  ) async {
    await pumpShell(tester);
    await enterFullscreen(tester);

    final safe = shellSafeArea(tester);
    expect(
      safe.top,
      isTrue,
      reason: 'nothing insets the notch / Dynamic Island any more',
    );
    expect(
      safe.bottom,
      isTrue,
      reason: 'nothing insets the home indicator any more',
    );
  });

  testWidgets('F4: the Android back button leaves the mode, not the app', (
    tester,
  ) async {
    await pumpShell(tester);
    await enterFullscreen(tester);
    expect(find.byType(NavigationBar), findsNothing);

    // Exit route 1. `handlePopRoute` is what the platform sends on a back
    // press / back gesture; the shell's PopScope is what decides where it goes.
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(
      find.byType(NavigationBar),
      findsOneWidget,
      reason: 'back exits full screen…',
    );
    // 🔴 …and does NOT pop the shell off the navigator. There is nothing under
    // it; a route that pops here leaves a black screen.
    expect(find.byType(IndexedStack), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('F5: the exit button is present and at least 40x40 dp', (
    tester,
  ) async {
    await pumpShell(tester);
    await enterFullscreen(tester);

    final icon = find.byIcon(Icons.fullscreen_exit);
    expect(icon, findsOneWidget, reason: 'exit route 2 — the only one iOS has');

    // 🔴 MEASURED, not merely found. FB-70 was a fully working rename feature
    // behind a 14×14 dp hit box, and users deleted and re-added devices rather
    // than find it. "The widget is in the tree" was true there too.
    final target = find
        .ancestor(of: icon, matching: find.byType(InkWell))
        .first;
    final size = tester.getSize(target);
    expect(size.width, greaterThanOrEqualTo(40));
    expect(size.height, greaterThanOrEqualTo(40));

    // It carries its own label, so the icon does not have to explain itself.
    expect(find.byType(Tooltip), findsWidgets);

    await tapWhileImmersive(tester, icon);
    expect(find.byType(NavigationBar), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('F6: a double tap leaves the mode', (tester) async {
    await pumpShell(tester);
    await enterFullscreen(tester);

    final centre = tester.getCenter(find.byType(IndexedStack));
    await tester.tapAt(centre);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(centre);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byType(NavigationBar),
      findsOneWidget,
      reason:
          'exit route 3 — the one that is easiest to pass on by word of '
          'mouth to a dealer\'s customer',
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('F7: leaving the home tab leaves full screen', (tester) async {
    await pumpShell(tester);
    await enterFullscreen(tester);
    expect(find.byType(NavigationBar), findsNothing);

    // The add-device tile is reachable while immersive and routes through
    // `_setTab`, which is the single place `_tab` may be written — and the
    // place the reset lives.
    final addTile = find.byIcon(Icons.add_circle_outline);
    expect(
      addTile,
      findsWidgets,
      reason: 'the default home layout carries an add-device tile',
    );
    await tapWhileImmersive(tester, addTile.first);
    await drain(tester);

    expect(
      find.byType(NavigationBar),
      findsOneWidget,
      reason:
          'full screen is a HOME-tab state: every other tab needs its '
          'chrome to be usable at all',
    );
    final safe = shellSafeArea(tester);
    expect(safe.top, isFalse);
    expect(safe.bottom, isFalse);
  });

  testWidgets('F8: full screen does not touch gate condition 3', (
    tester,
  ) async {
    await pumpShell(tester);

    final ctx = tester.element(find.byType(IndexedStack));
    final gps = ctx.read<GpsSpeedController>();
    final gforce = ctx.read<GForceController>();
    final gpsBefore = gps.dashboardVisible;
    final gforceBefore = gforce.dashboardVisible;

    await enterFullscreen(tester);

    // 🔴 Unchanged is the assertion. Condition 3 reads the TAB, and full screen
    // changes no tab — so the GNSS receiver and the accelerometer stream must
    // see exactly what they saw before. Design 0042 G4 makes that gate the
    // whole battery story, and this mode exists for the riding readouts, i.e.
    // precisely when the gate must stay open.
    expect(gps.dashboardVisible, gpsBefore);
    expect(gforce.dashboardVisible, gforceBefore);
    expect(
      gps.dashboardVisible,
      isTrue,
      reason: 'the shell opens on 主頁, so the gate was open to begin with',
    );

    expect(tester.takeException(), isNull);
  });

  // ===========================================================================
  // 🔴 F9 — the entry icon's findability, 2026-08-15, from the field.
  //
  // The owner shipped this feature and then could not find the way in:
  // 「但看不到」. It was there the whole time, as an 18 px `muted` glyph — beside
  // a SECOND 18 px `muted` glyph (`Icons.tune`, the home editor) of identical
  // weight. Two grey twins where one was wanted: nothing in the bar said which.
  //
  // The ruling was to drop `tune` from the app bar and let the survivor grow.
  // `tune` was the right one to lose because the home editor already has a
  // LABELLED entry at the foot of the grid (`_EditLayoutRow`, added 2026-08-07
  // after the same owner reported that editor as missing for the same reason),
  // while full screen has no second route in at all — design 0062 Q1 rules out
  // an entry gesture on purpose.
  //
  // ⚠️ This is the project's THIRD control-nobody-could-find (after the home
  // editor and FB-70's 14×14 dp pencil), so it is measured, not eyeballed:
  // `tune` must be absent from the bar, and the surviving icon must be bigger
  // than the 18 px that failed. Assert the icon SIZE, not just that the widget
  // exists — "it is in the tree" was true every previous time too.
  //
  // 🔵 **FB-108 (2026-09-02) — bigger was not enough either.** 何先生 reported
  // the chart's own full-screen entry as unrecognisable, and the ruling was to
  // fix BOTH doors in one pass: the glyph now travels with the word 「全螢幕」,
  // here as well as on the chart card. That makes this a labelled control
  // rather than an `IconButton`, so what F9 measures changed shape — the
  // assertions below are the same three properties (not `tune`, not 18 px,
  // still the only action) plus the word.
  // ===========================================================================
  testWidgets('F9: the entry is labelled, is not 18 px, and is the only action',
      (tester) async {
    await pumpShell(tester);

    final appBar = find.byType(AppBar);
    expect(appBar, findsOneWidget);

    expect(
      find.descendant(of: appBar, matching: find.byIcon(Icons.tune)),
      findsNothing,
      reason:
          'the home editor is reached from the grid row, not from a grey twin '
          'of the full-screen icon',
    );

    final l10n = AppLocalizations.of(
      tester.element(find.byType(AppBar)),
    );
    final label = find.descendant(
      of: appBar,
      matching: find.text(l10n.fullscreenEnter),
    );
    expect(label, findsOneWidget,
        reason: 'FB-108 — a tooltip needs a long-press on a glyph the user has '
            'not noticed; the word is what makes it a door');

    final icon = tester.widget<Icon>(
      find.descendant(of: appBar, matching: find.byIcon(Icons.fullscreen)),
    );
    expect(
      icon.size,
      greaterThan(18.0),
      reason: '18 px muted is the size the owner could not see',
    );

    // The word has to be part of the button, not a caption beside it — and the
    // whole thing still has to clear FB-70's floor.
    final target =
        find.ancestor(of: label, matching: find.byType(InkWell)).first;
    final size = tester.getSize(target);
    expect(size.width, greaterThanOrEqualTo(40));
    expect(size.height, greaterThanOrEqualTo(40));
    await tester.tap(label);
    await drain(tester);
    expect(find.byType(NavigationBar), findsNothing,
        reason: 'pressing the WORD has to enter full screen');
    await tapWhileImmersive(tester, find.byIcon(Icons.fullscreen_exit));
    await drain(tester);

    // …and it is still the ONE action, so labelling it did not cost the pill:
    // exactly two pressable things in the bar, this and the connection pill.
    expect(
      find.descendant(of: appBar, matching: find.byType(InkWell)),
      findsNWidgets(2),
    );

    expect(tester.takeException(), isNull);
  });
}
