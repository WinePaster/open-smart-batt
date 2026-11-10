// design 0100 P3/P4 — Settings → 「回報問題」, driven through the real screen.
//
// The flow is tapped the way a user taps it, the zip it hands to the (stubbed)
// share sheet is unzipped, and the members are read back. What has to hold:
//
//   R1  one zip: the CSV, the log and note.txt, under their stand-alone names,
//       with the injected brand and the report subject;
//   R2  🔴 FB-68 by construction: both files state the SAME scope and layout,
//       because one ExportTarget wrote them both;
//   R3  the dialog says the right thing about the log (FB-32 off / FB-37 on);
//   R4  "turn on recording" CANCELS, as the stand-alone export does (FB-32);
//   R5  cancel shares nothing;
//   R6  a demo unit is refused (design 0097).
//
// ⚠️ MECHANICS (same as `export_brand_header_test.dart`): every real file or
// sqflite await runs inside `tester.runAsync`, and every wait advances the
// fake clock as well as the real one, or the test hangs with no error.
//
// CLEAN-ROOM: expectations derive from this project's own source.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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
import 'package:open_smart_batt/ui/settings/report_problem.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:open_smart_batt/ui/util/report_bundle.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Not `OpenSmartBatt`, so a surviving literal cannot pass for injection.
const AppConfig _injected = AppConfig(
  appName: 'BrandUnderTest',
  edition: AppEdition.pro,
  projectUrl: 'https://example.invalid/pro',
  updateRepo: null,
);

/// Inert BleService — nothing here touches the link.
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
  late AppLocalizations l10n;
  final shared = <String>[];
  final subjects = <String>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('osb-report');
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
    shared.clear();
    subjects.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getTemporaryDirectory' ? tmp.path : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/share'),
      (call) async {
        final args = call.arguments;
        if (args is Map) {
          for (final p in (args['paths'] as List?) ?? const []) {
            shared.add(p as String);
          }
          final subject = args['subject'];
          if (subject is String) subjects.add(subject);
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

  Future<void> boot(WidgetTester tester, {bool rawLog = false}) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      services =
          await AppServices.create(appDatabase: db, ble: _FakeBleService());
      // One row in each table, so neither file takes its "nothing" branch.
      await services.historyRepo.insertSample(TelemetrySample(
        timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
        pvlt: 13.1,
        svlt: 13.1,
        temperatureC: 25,
      ));
      await services.logRepo.insertLog(LogEntry(
        timestamp: DateTime.now(),
        direction: LogDirection.rx,
        hex: 'b81901040000ccff',
      ));
      if (rawLog) await services.settings.setRawPacketLog(true);
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
    });
  }

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

  Future<void> openReportDialog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(const Scaffold(body: SettingsScreen())));
    await tester.pump();
    await settle(tester, rounds: 10);
    final row = find.byKey(const ValueKey('settings-report'));
    await tester.scrollUntilVisible(row, 200);
    await tester.tap(row);
    await settle(tester, rounds: 10);
    expect(find.text(l10n.reportDialogTitle), findsWidgets);
  }

  /// member name → text, for the zip most recently shared.
  Future<Map<String, String>> sharedZip(WidgetTester tester) async {
    expect(shared, hasLength(1), reason: 'exactly one file reaches the share');
    expect(shared.single, endsWith('.zip'));
    late Map<String, String> out;
    await tester.runAsync(() async {
      final bytes = await File(shared.single).readAsBytes();
      out = {
        for (final f in ZipDecoder().decodeBytes(bytes))
          if (f.isFile) f.name: utf8.decode(f.content as List<int>),
      };
    });
    return out;
  }

  /// The value of preamble key [key] (`# key: value`) in [text].
  String header(String text, String key) => text
      .split('\n')
      .firstWhere((l) => l.startsWith('# $key:'),
          orElse: () => fail('no `# $key:` line'))
      .substring('# $key:'.length)
      .trim();

  testWidgets('R1/R2 — one zip, three members, one scope and one layout',
      (tester) async {
    await boot(tester);
    await openReportDialog(tester);

    await tester.enterText(
        find.byKey(const ValueKey('report-note')), 'Car would not start, 7am');
    await tester.tap(find.byKey(const ValueKey('report-send')));
    // Nothing on the link and no granularity choice ⇒ chooseExportScope
    // resolves to all devices without a sheet.
    await settle(tester, untilShared: true);

    final files = await sharedZip(tester);
    final csv = files.entries.singleWhere((e) => e.key.endsWith('.csv'));
    final log = files.entries.singleWhere((e) => e.key.endsWith('.log'));
    expect(files.keys.toSet(), {csv.key, log.key, kReportNoteFileName});
    expect(csv.key, startsWith('opensmartbatt-history-'));
    expect(log.key, startsWith('opensmartbatt-'));
    expect(shared.single.split('/').last, startsWith('opensmartbatt-report-'));
    // The stand-alone exports' first lines, with the injected brand.
    expect(csv.value.split('\n').first, '# BrandUnderTest history export');
    expect(log.value.split('\n').first, '# BrandUnderTest diagnostic log');
    expect(files[kReportNoteFileName], contains('Car would not start, 7am'));
    expect(header(files[kReportNoteFileName]!, 'edition'), 'pro');
    expect(subjects.single, 'BrandUnderTest problem report');

    // 🔴 FB-68. The log's scope line carries `  connections=N` after the
    // scope, which the CSV's does not — the scope itself must match.
    String scopeOf(String t) => header(t, 'scope').split('  ').first;
    expect(scopeOf(log.value), scopeOf(csv.value));
    expect(header(log.value, 'layout'), header(csv.value, 'layout'));
    expect(header(files[kReportNoteFileName]!, 'scope'), scopeOf(csv.value));
  });

  testWidgets('a blank note ⇒ no note.txt', (tester) async {
    await boot(tester);
    await openReportDialog(tester);
    await tester.tap(find.byKey(const ValueKey('report-send')));
    await settle(tester, untilShared: true);
    expect((await sharedZip(tester)).keys,
        isNot(contains(kReportNoteFileName)));
  });

  testWidgets('R3 — log OFF: the FB-32 warning and the enable button',
      (tester) async {
    await boot(tester);
    await openReportDialog(tester);
    expect(find.text(l10n.rawLogOffDialogTitle), findsOneWidget);
    expect(find.text(l10n.rawLogContentsDialogTitle), findsNothing);
    expect(find.byKey(const ValueKey('report-enable-logging')), findsOneWidget);
  });

  testWidgets('R3 — log ON: the FB-37 address disclosure, no enable button',
      (tester) async {
    await boot(tester, rawLog: true);
    await openReportDialog(tester);
    expect(find.text(l10n.rawLogContentsDialogTitle), findsOneWidget);
    expect(find.text(l10n.rawLogOffDialogTitle), findsNothing);
    expect(find.byKey(const ValueKey('report-enable-logging')), findsNothing);
  });

  testWidgets('R4 — "turn on recording" turns it on and shares nothing',
      (tester) async {
    await boot(tester);
    await openReportDialog(tester);
    await tester.tap(find.byKey(const ValueKey('report-enable-logging')));
    await settle(tester, rounds: 30);
    expect(services.settings.rawPacketLog, isTrue);
    expect(shared, isEmpty);
    expect(find.text(l10n.rawLogEnabledSnack), findsOneWidget);
  });

  testWidgets('R5 — cancel shares nothing', (tester) async {
    await boot(tester);
    await openReportDialog(tester);
    await tester.tap(find.text(l10n.commonCancel));
    await settle(tester, rounds: 30);
    expect(shared, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('R6 — a demo unit is refused (design 0097)', (tester) async {
    await boot(tester);
    late BuildContext ctx;
    await tester.pumpWidget(host(Scaffold(
      body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      }),
    )));
    await tester.pump();
    unawaited(reportProblem(ctx, deviceId: 'DEMO-BATTERY'));
    await settle(tester, rounds: 10);
    await tester.tap(find.byKey(const ValueKey('report-send')));
    await settle(tester, rounds: 20);
    // A pinned export may still show its sheet; take the unit it offers.
    final thisDevice = find.textContaining(RegExp(r'^This device'));
    if (thisDevice.evaluate().isNotEmpty) {
      await tester.tap(thisDevice.first);
      await settle(tester, rounds: 20);
    }
    expect(find.text(l10n.reportDemoRefused), findsOneWidget);
    expect(shared, isEmpty);
  });
}
