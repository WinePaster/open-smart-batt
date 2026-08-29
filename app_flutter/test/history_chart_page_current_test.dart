// FB-101 / design 0085 S3 — the LANDSCAPE shell obeys the same gate.
//
// 🔴 **Because the two shells share a painter, not a policy.** The embedded
// card and this page draw through one `history_chart_core.dart` (design 0081
// S2, so that FB-74 / design 0065 §6 R5 cannot recur), but each owns its own
// toggle, its own series state and its own placement of the refusal sentence.
// A gate honoured in the card and forgotten here is exactly the "two surfaces,
// one unit, two answers" shape the shared core exists to prevent — and it would
// be invisible in the card's own tests.
//
// So this file pins the page's wiring only: that the class REACHES it, that the
// toggle is live or dead for the same three cases, and that the refusal is
// worded from the same two strings. What the painter then does with a series is
// `history_chart_current_series_test.dart`'s job and is not repeated.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/l10n/app_localizations_en.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_chart_core.dart';
import 'package:open_smart_batt/ui/history/history_chart_page.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  final _telemetry = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetry.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<void> dispose() async {
    await _telemetry.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  final en = AppLocalizationsEn();
  late AppDatabase db;
  late _FakeBle ble;
  late TelemetryController tele;

  setUp(() async {
    db = await AppDatabase.open(
        path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    ble = _FakeBle();
    tele = TelemetryController(
      ble,
      settings: SettingsController(SettingsRepo(db.db)),
      history: HistoryRepo(db.db),
      logs: LogRepo(db.db),
      session: SessionContext(),
    );
  });

  tearDown(() async {
    await tele.pendingWrites.drain();
    tele.dispose();
    await ble.dispose();
    await db.close();
  });

  final from = DateTime(2026, 8, 27, 9, 0);
  final to = from.add(const Duration(minutes: 30));

  /// Thirty minutes of a unit crossing zero, one row a minute.
  Future<void> seed() async {
    for (var i = 0; i < 30; i++) {
      await db.db.insert(Db.tableHistory, <String, Object?>{
        'timestamp': from.add(Duration(minutes: i)).millisecondsSinceEpoch,
        'pvlt': 13.2 + i * 0.01,
        'ampere': -4.0 + i * 0.3,
        'temperature': 30,
        'mode': ReportedStatus.normal,
        'device_id': 'AA',
        'samples': 1,
        'bucket_s': 1,
      });
    }
  }

  /// ⚠️ **`runAsync` + `pump`, and neither alone.** Two separate traps here,
  /// both of which present as a test that simply never finishes:
  ///
  ///  * the page's queries are REAL sqflite I/O, and a `testWidgets` body runs
  ///    in a fake-async zone where those futures never complete — only
  ///    [WidgetTester.runAsync] lets the real event loop turn;
  ///  * ⛔ `pumpAndSettle` is unusable regardless, because a
  ///    [CircularProgressIndicator] is on screen while a window is in flight
  ///    and an indefinite animation never settles.
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 5; i++) {
      await t.pump();
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await t.pump();
    }
  }

  Future<void> open(WidgetTester t, ProductClass? cls,
      {String? deviceId = 'AA'}) async {
    await t.pumpWidget(ChangeNotifierProvider<TelemetryController>.value(
      value: tele,
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: HistoryChartPage(
          deviceId: deviceId,
          deviceClass: cls,
          title: 'Unit',
          tempUnit: TempUnit.celsius,
          dataFrom: from,
          dataTo: to,
        ),
      ),
    ));
    await settle(t);
  }

  // 🔵 design 0089 S6 — the switch is the label AND the icon, one `InkWell`.
  // Finding it by the icon and tapping THAT would still pass if the label were
  // left outside the tap target, which is the whole defect FB-103 was about; so
  // the finder is the enclosing widget and the tests below tap the LABEL.
  final toggle = find.ancestor(
      of: find.byIcon(Icons.swap_vert), matching: find.byType(InkWell));

  /// Whether the pair is pressable — the successor to `IconButton.onPressed`.
  bool canSwitch(WidgetTester t) => t.widget<InkWell>(toggle).onTap != null;

  /// Tap the WORDS, not the icon.
  Future<void> tapLabel(WidgetTester t, String label) =>
      t.tap(find.text(label), warnIfMissed: false);

  HistoryTrendPainter painterOf(WidgetTester t) => t
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((c) => c.painter)
      .whereType<HistoryTrendPainter>()
      .single;

  testWidgets('a battery may switch, and the class reaches the painter',
      (t) async {
    await t.runAsync(seed);
    await open(t, ProductClass.smartBattery);

    expect(canSwitch(t), isTrue);
    // 🔴 The label is INSIDE the tap target. Without this, a refactor that put
    // the words beside the button instead of within it would still pass every
    // assertion below — and that arrangement is precisely FB-103.
    expect(
        find.descendant(of: toggle, matching: find.text(en.historyLegendVoltage)),
        findsOneWidget);
    expect(painterOf(t).series, HistoryChartSeries.voltage);
    // 🔴 The shell has no legend row, so the bar has to name the quantity —
    // current reuses voltage's colour and the axis numbers do not say which.
    expect(find.text(en.historyLegendVoltage), findsOneWidget);

    // 🔴 The LABEL, not the icon. Before 0089 this tap did nothing.
    await tapLabel(t, en.historyLegendVoltage);
    await settle(t);

    expect(painterOf(t).series, HistoryChartSeries.current);
    expect(find.text(en.historyLegendCurrent), findsOneWidget);
    // 🔑 …and the label that is now showing is itself pressable, so the way
    // back is the same gesture as the way in.
    expect(canSwitch(t), isTrue);
    expect(painterOf(t).currentDirectionLabel,
        en.dashboardTrackCurrentDirectionKey);
  });

  testWidgets('a power bank is labelled with its own, opposite key', (t) async {
    await t.runAsync(seed);
    await open(t, ProductClass.powerBank);
    await tapLabel(t, en.historyLegendVoltage);
    await settle(t);

    expect(painterOf(t).currentDirectionLabel,
        en.powerBankTrackCurrentDirectionKey);
    expect(painterOf(t).currentDirectionLabel,
        isNot(en.dashboardTrackCurrentDirectionKey));
  });

  testWidgets('a super-capacitor: dead toggle, and the reason on screen',
      (t) async {
    await t.runAsync(seed);
    await open(t, ProductClass.supercapacitor);

    expect(canSwitch(t), isFalse);
    expect(find.text(en.capacitorChartNoCurrentNote), findsOneWidget);
    await tapLabel(t, en.historyLegendVoltage);
    await settle(t);
    expect(painterOf(t).series, HistoryChartSeries.voltage);
  });

  testWidgets('「全部裝置」: dead toggle, and the sentence blames the scope',
      (t) async {
    // ⚠️ The class travels WITH the id — a page holding a class for a scope it
    // is not filtered to would plot the mixed-family average outright.
    await t.runAsync(seed);
    await open(t, null, deviceId: null);

    expect(canSwitch(t), isFalse);
    expect(find.text(en.historyChartAllDevicesNoCurrentNote), findsOneWidget);
    expect(find.text(en.capacitorChartNoCurrentNote), findsNothing);
    await tapLabel(t, en.historyLegendVoltage);
    await settle(t);
    expect(painterOf(t).series, HistoryChartSeries.voltage);
  });

  testWidgets('nothing is explained when nothing is refused', (t) async {
    await t.runAsync(seed);
    await open(t, ProductClass.smartBattery);
    expect(find.text(en.capacitorChartNoCurrentNote), findsNothing);
    expect(find.text(en.historyChartAllDevicesNoCurrentNote), findsNothing);
  });
}
