// FB-109 — the brand name on the FIRST LINE of every exported file, asserted
// from the CALL SITES.
//
// ---------------------------------------------------------------------------
// What was wrong, and why nothing went red
// ---------------------------------------------------------------------------
//
// design 0092 extracted the brand strings into an injected [AppConfig]. Two of
// the replacements landed inside SINGLE-quoted Dart literals as `'\$appName …'`
// — an ESCAPED dollar, so no interpolation ever happened. Every diagnostic log
// and every "export all data" CSV shipped since v0.7.40 opens with the literal
// line `# $appName diagnostic log`. 🔑 The wiring around it was COMPLETE:
// `settings_screen.dart` reads `appName` before its awaits, uses it correctly
// for the share-sheet subject, and even threads it through `_logHeader`'s
// parameter list. Only the last word was written as a literal — which is why
// neither `flutter analyze` (a legal string, no unused variable) nor any
// existing test noticed.
//
// A third site, `history_csv_export.dart`, was never extracted at all and said
// `OpenSmartBatt` outright: it is not among the 22 sites design 0092 §1.5
// enumerated, so nothing was looking for it.
//
// 🔴 THE REASON THE SUITE STAYED GREEN IS THE POINT OF THIS FILE, AND IT IS THE
// THIRD TIME.
//
//   * design 0070 / `csv_declared_block_0070_test.dart`, in its own words:
//     "the bug was a CALL SITE forgetting an argument — no test at this level
//     could have caught it." Both CSV call sites omitted `devices:`, so every
//     exported CSV claimed `declared: count=0` for three releases.
//   * FB-109 (this file): both call sites passed a WRONG argument. Ten test
//     files exercise `exportHeaderLines`, and every one of them passes `title:`
//     itself — so all ten test the FORMATTER and none of them the call sites.
//   * `direction_followups_test.dart` X5 is the shape that survives both: it
//     derives the call-site list by grepping `lib/` and then asserts something
//     about each file, rather than trusting a hand-written list. It had even
//     already enumerated these exact three sites — it just asserted
//     `ampereColumn:` rather than `title:`.
//
// ⚠️ AND THE OBVIOUS ASSERTION WOULD HAVE MISSED IT TOO. `app_config_test.dart`
// T4's shape was "the source does not contain 'OpenSmartBatt'" — which
// `'\$appName …'` satisfies perfectly while being wrong. So every assertion
// here is an EQUALITY against the injected name, never an absence. (T4 itself
// has been repaired in place — its hand-written four-file list is now derived
// from `lib/`, which is the half that missed `history_csv_export.dart`.)
//
// The three tests below drive the real widgets: they tap the buttons a user
// taps, let the export write a real file through a stubbed temp dir, and read
// back the first line the recipient will see.
//
// ⚠️ MECHANICS, learned the hard way while writing this: real file and
// directory I/O must never happen in the `testWidgets` body — the fake-async
// zone never completes it and the test hangs until the 10-minute shell timeout,
// with no error. Every `File`/`Directory` await here is inside
// `tester.runAsync`, and every wait loop advances the FAKE clock
// (`pump(duration)`) as well as the real one.
//
// CLEAN-ROOM: expectations derive from this project's own source.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/config/app_config.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:open_smart_batt/ui/util/export_scope.dart';
import 'package:open_smart_batt/ui/util/history_csv_export.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The branding injected for every test here. Deliberately NOT `OpenSmartBatt`
/// and deliberately not a superstring of it: an assertion against a name that
/// contains the default cannot tell injection from a surviving literal.
const AppConfig _injected = AppConfig(
  appName: 'BrandUnderTest',
  edition: AppEdition.pro,
  projectUrl: 'https://example.invalid/pro',
  updateRepo: null,
);

/// Inert BleService — the exports under test never touch the link.
class _FakeBleService extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late Directory tmp;
  late AppServices services;

  /// Paths handed to the platform share sheet, in order.
  final shared = <String>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('osb-brand-header');
    shared.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // `exportTempFile` asks path_provider where to write. Without this the
    // export dies on a MissingPluginException and the test would "pass" by
    // never producing a file at all.
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getTemporaryDirectory' ? tmp.path : null,
    );
    // share_plus. Any non-empty string other than the plugin's own
    // `…/unavailable` reads back as `ShareResultStatus.success`.
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/share'),
      (call) async {
        final args = call.arguments;
        if (args is Map) {
          for (final p in (args['paths'] as List?) ?? const []) {
            shared.add(p as String);
          }
        }
        return 'com.example.test';
      },
    );
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'), null);
    await services.dispose();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<void> boot(WidgetTester tester) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      services =
          await AppServices.create(appDatabase: db, ble: _FakeBleService());
      // One history row, so the CSV paths do not take their "nothing to
      // export" branch — which deletes the file before anyone can read it.
      await services.historyRepo.insertSample(TelemetrySample(
        timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
        pvlt: 13.1,
        svlt: 13.1,
        temperatureC: 25,
      ));
      // One diagnostic-log row, for the same reason on the `.log` path.
      await services.logRepo.insertLog(LogEntry(
        timestamp: DateTime.now(),
        direction: LogDirection.rx,
        hex: 'b81901040000ccff',
      ));
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
    });
  }

  /// Let the export's real awaits (file IO, sqflite) run while still advancing
  /// the widget clock. BOTH halves are required — see the file header.
  Future<void> settle(WidgetTester tester,
      {int rounds = 80, bool untilShared = false}) async {
    for (var i = 0; i < rounds; i++) {
      if (untilShared && shared.isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await tester.pump();
  }

  /// The first preamble line of the file most recently handed to the share
  /// sheet — i.e. exactly what the recipient opens the file on.
  Future<String> firstSharedLine(WidgetTester tester) async {
    expect(shared, isNotEmpty, reason: 'nothing reached the share sheet');
    late String line;
    await tester.runAsync(() async {
      final f = File(shared.last);
      expect(f.existsSync(), isTrue, reason: '${f.path} was never written');
      line = (await f.readAsLines()).first;
    });
    return line;
  }

  /// Everything an assertion has to say about one exported preamble line.
  void expectBranded(String line, String tail) {
    // 🔴 EQUALITY, not "does not contain OpenSmartBatt" — see the file header.
    expect(line, '# ${_injected.appName} $tail');
    expect(line, isNot(contains(r'$appName')),
        reason: 'the escaped-dollar regression FB-109 was filed for');
    expect(line, isNot(contains('OpenSmartBatt')),
        reason: 'a hard-coded brand survived injection');
  }

  Widget host(Widget home) => AppConfigScope(
        config: _injected,
        child: MultiProvider(
          providers: [
            Provider<AppServices>.value(value: services),
            Provider<BleService>.value(value: services.ble),
            Provider<HistoryRepo>.value(value: services.historyRepo),
            Provider<DeviceRepo>.value(value: services.deviceRepo),
            Provider<SettingsRepo>.value(value: services.settingsRepo),
            Provider<LogRepo>.value(value: services.logRepo),
            ChangeNotifierProvider<SettingsController>.value(
                value: services.settings),
            ChangeNotifierProvider<DeviceController>.value(
                value: services.devices),
            ChangeNotifierProvider<ConnectionController>.value(
                value: services.connection),
            ChangeNotifierProvider<TelemetryController>.value(
                value: services.telemetry),
            ChangeNotifierProvider<AlertController>.value(
                value: services.alerts),
            ChangeNotifierProvider<GForceController>.value(
                value: services.gforce),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: home,
          ),
        ),
      );

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(const Scaffold(body: SettingsScreen())));
    await tester.pump();
    // The Data card measures the history table when it mounts (design 0061
    // T8c) — a real query, which cannot progress inside the fake-async zone.
    await settle(tester, rounds: 10);
  }

  testWidgets(
      'FB-109 (1) — Settings → export all data (CSV) names the injected build',
      (tester) async {
    await boot(tester);
    await pumpSettings(tester);

    await tester.scrollUntilVisible(find.text('Export all data (CSV)'), 200);
    await tester.tap(find.text('Export all data (CSV)'));
    await settle(tester, rounds: 20);
    // The scope sheet. "All devices" is the option that exists whether or not
    // anything is on the link.
    expect(find.text('Export scope'), findsOneWidget);
    await tester.tap(find.text('All devices'));
    await settle(tester, untilShared: true);

    expectBranded(await firstSharedLine(tester), 'history export');
  });

  testWidgets(
      'FB-109 (2) — Settings → export diagnostic log names the injected build',
      (tester) async {
    await boot(tester);
    await pumpSettings(tester);

    await tester.scrollUntilVisible(
        find.text('Export diagnostic log (.log)'), 200);
    await tester.tap(find.text('Export diagnostic log (.log)'));
    await settle(tester, rounds: 20);
    // Raw packet logging is OFF by default, so the "what this file will and
    // will not contain" dialog comes first (FB-32).
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Export anyway'));
    // Nothing on the link and no granularity choice on this path, so
    // `chooseExportScope` resolves to all-devices without showing a sheet.
    await settle(tester, untilShared: true);

    expectBranded(await firstSharedLine(tester), 'diagnostic log');
  });

  testWidgets(
      'FB-109 (3) — the History / detail CSV path, the 23rd hard-coded site',
      (tester) async {
    await boot(tester);

    // 🔑 `history_csv_export.dart` is NOT reachable from Settings — it is the
    // History tab's and the device detail page's export, and it is the one site
    // design 0092 never touched. Driven through its public entry point from a
    // context that carries the scope, which is exactly how both surfaces call
    // it.
    late BuildContext ctx;
    await tester.pumpWidget(host(Scaffold(
      body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      }),
    )));
    await tester.pump();

    unawaited(exportHistoryCsv(
      ctx,
      target: const ExportTarget(scope: ExportScope.allDevices, layout: '-'),
      since: null,
      until: null,
      window: 'all',
    ));
    await settle(tester, untilShared: true);

    expectBranded(await firstSharedLine(tester), 'history export');
  });
}
