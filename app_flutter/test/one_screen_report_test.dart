// T65-6 — the one-screen report's layout survived being shared (design 0065
// §3.4.0 / §6 R1).
//
// Three screens rendered the SAME six-widget tree, verbatim, down to the
// padding values: the detail page's offline body, `UnidentifiedView` and
// `ClassPendingView`. Design 0065 has to change that tree — it appends this
// unit's history underneath — so the three copies became one
// [OneScreenReport].
//
// 🔴 WHAT THIS FILE CATCHES, and why it is worth its length.
//
// The layout language of a full-page failure report is two properties acting
// together: `minHeight: constraints.maxHeight` (it fills the screen) and
// `MainAxisAlignment.center` (it sits in the middle of what it fills). Append
// anything to that same centred column and the centring starts dividing the
// space between the report and the appendix — the pulsing glyph is shoved
// upward and the page reads as BROKEN rather than as "the report, and then
// something else". Nothing throws, nothing logs, and no text assertion moves;
// only the geometry does. So the geometry is what is asserted here.
//
// Two halves:
//   * `below == null` must be the pre-0065 layout — one screen, centred. A
//     shell that dropped the `minHeight` would leave the report hugging the top
//     of the page, and every existing text-finding test would still pass.
//   * `below != null` must keep the report at one full screen and centred
//     WITHIN THAT SCREEN, with the appendix beneath it. This is the half that
//     `minHeight` being left on the outer column would break, and it is the
//     regression R1 is about.
//
// CLEAN-ROOM: expectations derive from this project's own source.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/class_pending_view.dart';
import 'package:open_smart_batt/ui/dashboard/unidentified_view.dart';
import 'package:open_smart_batt/ui/devices/device_detail_page.dart';
import 'package:open_smart_batt/ui/widgets/one_screen_report.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// No radio. Reports itself as holding nothing, so the detail page's
/// `live` gate (`isOnline && connectedDeviceId == deviceId`) is false and the
/// offline body is what gets drawn.
class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

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

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

/// A `ClassPendingView` that has already timed out shows its full report —
/// glyph, title, body and the retry button — which is the widest version of
/// the layout and therefore the one worth measuring.
///
/// `pendingFor` is stated rather than produced: the real one is wall-clock
/// against a link that has to reach `ready`, and this file is measuring
/// geometry, not the timing rules `waiting_states_test.dart` already covers.
class _StalledConn extends ConnectionController {
  _StalledConn(super.ble, {required super.settings});

  @override
  Duration? get pendingFor =>
      kClassPendingTimeout + const Duration(seconds: 1);

  @override
  bool get isSetupStalled => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  const viewport = Size(400, 800);

  /// The report's own painted box — the `ConstrainedBox` that carries
  /// `minHeight: constraints.maxHeight`, found through the `Padding` that is
  /// only ever used by [OneScreenReport].
  Rect reportBox(WidgetTester tester) {
    final padding = find.descendant(
      of: find.byType(OneScreenReport),
      matching: find.byWidgetPredicate((w) =>
          w is Padding &&
          w.padding == const EdgeInsets.fromLTRB(24, 24, 24, 30)),
    );
    expect(padding, findsOneWidget,
        reason: 'the report half no longer carries its own padded box — '
            'OneScreenReport was restructured');
    // The parent of that Padding is the ConstrainedBox under test.
    return tester.getRect(padding);
  }

  /// The centred column inside the report half.
  Rect reportColumn(WidgetTester tester) {
    final col = find.descendant(
      of: find.byType(OneScreenReport),
      matching: find.byWidgetPredicate(
          (w) => w is Column && w.mainAxisAlignment == MainAxisAlignment.center),
    );
    expect(col, findsWidgets);
    return tester.getRect(col.first);
  }

  /// The two assertions that ARE the layout language, applied to whatever
  /// [OneScreenReport] is currently on screen.
  ///
  /// [screenTop] is where the report's screen begins — 0 for a bare body, or
  /// the app bar's height on the detail page.
  void expectOneScreenAndCentred(WidgetTester tester,
      {required double screenTop, required double screenBottom}) {
    final box = reportBox(tester);
    final available = screenBottom - screenTop;
    // 1. It fills the screen. `minHeight: constraints.maxHeight` is the only
    //    thing that makes this true; delete it and the box shrink-wraps its
    //    content, which on a short report is a few hundred pixels.
    expect(box.height, closeTo(available, 0.5),
        reason: 'the report no longer fills one screen — the minHeight moved '
            'off the report half (design 0065 §3.4.0)');
    expect(box.top, closeTo(screenTop, 0.5));
    // 2. It is centred INSIDE that screen. The padding is asymmetric (24 top,
    //    30 bottom), so the exact centre of the inner column sits 3 px above
    //    the box's own centre — computed rather than eyeballed so this stays a
    //    statement about the layout and not about one screenshot.
    final col = reportColumn(tester);
    final expectedCentre = box.top + 24 + (box.height - 24 - 30) / 2;
    expect(col.center.dy, closeTo(expectedCentre, 1.0),
        reason: 'the report is no longer centred in its screen — the appendix '
            'is sharing the centring with it, which is what makes the pulsing '
            'glyph ride up (design 0065 §6 R1)');
  }

  Future<void> pump(WidgetTester tester, Widget child,
      {List<SingleChildWidget> extra = const []}) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: child,
    );
    // MultiProvider asserts a non-empty list, and the shell's own tests need no
    // providers at all — that is the point of testing it in isolation.
    await tester.pumpWidget(
        extra.isEmpty ? app : MultiProvider(providers: extra, child: app));
    await tester.pump();
    // The three screens now carry design 0065's history block, which queries on
    // mount. Real database IO cannot settle under the fake clock, so it is
    // drained here rather than left as a pending timer at teardown.
    if (extra.isNotEmpty) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  // -------------------------------------------------------------------------
  // The shell itself, in isolation — the arithmetic, with no screen around it.
  // -------------------------------------------------------------------------
  group('OneScreenReport', () {
    testWidgets('below: null — one screen, centred', (tester) async {
      await pump(
        tester,
        const Scaffold(
          body: OneScreenReport(report: [Text('report body')]),
        ),
      );
      expectOneScreenAndCentred(tester, screenTop: 0, screenBottom: 800);
    });

    testWidgets(
        '🔴 below: something — the report KEEPS its full screen and its '
        'centring, and the appendix goes underneath', (tester) async {
      await pump(
        tester,
        const Scaffold(
          body: OneScreenReport(
            report: [Text('report body')],
            below: SizedBox(height: 500, child: Text('appendix')),
          ),
        ),
      );
      // Unchanged from the null case: this is the whole point of the split.
      expectOneScreenAndCentred(tester, screenTop: 0, screenBottom: 800);
      // …and the appendix begins exactly where the report's screen ends, i.e.
      // below the fold, reachable only by scrolling.
      final box = reportBox(tester);
      final appendix = tester.getRect(find.text('appendix'));
      expect(appendix.top, greaterThanOrEqualTo(box.bottom - 0.5),
          reason: 'the appendix has been pulled INTO the report screen, which '
              'means it is sharing the centring with it');
    });

    testWidgets('the appendix is scrollable into view, not clipped away',
        (tester) async {
      await pump(
        tester,
        const Scaffold(
          body: OneScreenReport(
            report: [Text('report body')],
            below: SizedBox(height: 500, child: Text('appendix')),
          ),
        ),
      );
      await tester.drag(
          find.byType(OneScreenReport), const Offset(0, -600));
      await tester.pump();
      expect(find.text('appendix'), findsOneWidget);
      expect(tester.getRect(find.text('appendix')).top, lessThan(800));
    });
  });

  // -------------------------------------------------------------------------
  // …and the three real screens that inherited it. Testing only the shell in
  // isolation would pass while any one of the three had been converted wrongly
  // — which is exactly the "swap three copies, miss one" failure the shared
  // shell exists to prevent.
  // -------------------------------------------------------------------------
  group('the three screens that share it', () {
    late _FakeBle ble;
    late AppServices services;

    Future<void> boot(WidgetTester tester) async {
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        ble = _FakeBle();
        services = await AppServices.create(appDatabase: db, ble: ble);
        await services.devices.saveNew('DEV-A', 'Cap #1', name: 'RCE-SCAP_II');
      });
      addTearDown(() => tester.runAsync(services.dispose));
    }

    testWidgets('UnidentifiedView', (tester) async {
      await boot(tester);
      await pump(
        tester,
        const Scaffold(body: UnidentifiedView(deviceId: 'DEV-A')),
        // design 0065 mounts the history block under this report, so the
        // providers it reads have to be here too.
        extra: [
          ChangeNotifierProvider<ConnectionController>.value(
              value: services.connection),
          ChangeNotifierProvider<SettingsController>.value(
              value: services.settings),
          ChangeNotifierProvider<DeviceController>.value(
              value: services.devices),
          ChangeNotifierProvider<TelemetryController>.value(
              value: services.telemetry),
        ],
      );
      expect(find.byType(OneScreenReport), findsOneWidget);
      expectOneScreenAndCentred(tester, screenTop: 0, screenBottom: 800);
    });

    testWidgets('ClassPendingView (stalled — its widest report)',
        (tester) async {
      await boot(tester);
      final conn = _StalledConn(ble, settings: services.settings);
      addTearDown(conn.dispose);
      await pump(
        tester,
        const Scaffold(body: ClassPendingView(deviceId: 'DEV-A')),
        extra: [
          ChangeNotifierProvider<ConnectionController>.value(value: conn),
          ChangeNotifierProvider<TelemetryController>.value(
              value: services.telemetry),
          ChangeNotifierProvider<SettingsController>.value(
              value: services.settings),
          ChangeNotifierProvider<DeviceController>.value(
              value: services.devices),
        ],
      );
      expect(find.byType(OneScreenReport), findsOneWidget);
      expectOneScreenAndCentred(tester, screenTop: 0, screenBottom: 800);
    });

    testWidgets('the detail page offline body', (tester) async {
      await boot(tester);
      await pump(
        tester,
        const DeviceDetailPage(deviceId: 'DEV-A'),
        extra: [
          ChangeNotifierProvider<SettingsController>.value(
              value: services.settings),
          ChangeNotifierProvider<DeviceController>.value(
              value: services.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: services.connection),
          ChangeNotifierProvider<TelemetryController>.value(
              value: services.telemetry),
          ChangeNotifierProvider<GForceController>.value(
              value: services.gforce),
          ChangeNotifierProvider<GpsSpeedController>.value(
              value: services.speed),
        ],
      );
      expect(find.byType(OneScreenReport), findsOneWidget);
      // The page has an app bar, so the report's screen starts below it.
      final appBarBottom = tester.getRect(find.byType(AppBar)).bottom;
      expectOneScreenAndCentred(tester,
          screenTop: appBarBottom, screenBottom: 800);
    });
  });
}
