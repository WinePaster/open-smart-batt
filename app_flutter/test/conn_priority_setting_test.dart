// 連線節奏 — owner ruling 2026-11-16: the connection-priority switch from the
// `test/conn-priority` side build goes into main, default 預設 (ask nothing).
// Owner ruling 2026-11-17 (feedback 2026.11.17/002): remember it — schema v31
// `settings.conn_priority`.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState, ConnectionPriority;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/settings/conn_priority.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
  int applied = 0;
  @override
  Future<void> applyConnectionPriorityNow() async => applied++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  tearDown(() {
    BleService.connectionPriority = null;
    debugShowConnectionPriorityRow = null;
  });

  test('default is 預設 (null), and the options start with it', () {
    expect(BleService.connectionPriority, isNull);
    expect(AppSettings.defaults.linkPace, isNull);
    expect(connectionPriorityOptions.first, isNull);
    expect(connectionPriorityOptions, contains(LinkPace.lowPower));
  });

  test('every LinkPace maps to the plugin priority of the same name', () {
    expect(BleService.priorityFor(null), isNull);
    for (final v in LinkPace.values) {
      expect(BleService.priorityFor(v)!.name, v.name);
    }
  });

  group('model (schema v31)', () {
    test('a new install stores NULL, and toMap always carries the column', () {
      final m = AppSettings.defaults.toMap();
      expect(m.containsKey('conn_priority'), isTrue,
          reason: 'INSERT OR REPLACE: a column missing from toMap erases '
              'itself on the next unrelated save');
      expect(m['conn_priority'], isNull);
    });

    test('every choice round-trips; clearLinkPace goes back to 預設', () {
      for (final v in LinkPace.values) {
        final set = AppSettings.defaults.copyWith(linkPace: v);
        expect(AppSettings.fromMap(set.toMap()).linkPace, v);
        expect(set.copyWith(pollIntervalMs: 500).linkPace, v);
        expect(set.copyWith(clearLinkPace: true).linkPace, isNull);
      }
    });

    test('pre-v31 rows and unknown names read as 預設', () {
      expect(AppSettings.fromMap(const {}).linkPace, isNull);
      for (final junk in <Object?>[null, '', 'LowPower', 'x', 1]) {
        expect(AppSettings.fromMap({'conn_priority': junk}).linkPace, isNull,
            reason: '$junk');
      }
    });
  });

  Future<String> tempPath(String tag) async {
    final dir = await Directory.systemTemp.createTemp('osb_v31_$tag');
    addTearDown(() => dir.delete(recursive: true));
    return p.join(dir.path, 'db.sqlite');
  }

  Future<Set<String>> columnsOf(Database db) async => {
        for (final r in await db.rawQuery('PRAGMA table_info(settings)'))
          r['name'] as String,
      };

  test('migration 30 → 31 adds the column as NULL and keeps other choices',
      () async {
    final path = await tempPath('up');
    final db = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    await db.db.execute('ALTER TABLE settings RENAME TO settings_old');
    final info = await db.db.rawQuery('PRAGMA table_info(settings_old)');
    final defs = [
      for (final r in info)
        if (r['name'] != 'conn_priority')
          [
            r['name'],
            r['type'],
            if (r['pk'] == 1) 'PRIMARY KEY',
            if (r['notnull'] == 1) 'NOT NULL',
            if (r['dflt_value'] != null) 'DEFAULT ${r['dflt_value']}',
          ].join(' '),
    ];
    await db.db.execute('CREATE TABLE settings (${defs.join(', ')})');
    await db.db.execute('DROP TABLE settings_old');
    await db.db.insert('settings',
        {'id': Db.settingsRowId, 'theme_mode': 'dark', 'scan_rssi_min': -75});
    await db.db.execute('PRAGMA user_version = 30');
    await db.close();

    final up = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    addTearDown(up.close);
    expect((await up.db.rawQuery('PRAGMA user_version')).single['user_version'],
        Db.schemaVersion);
    final row = (await up.db.query('settings')).single;
    expect(row.containsKey('conn_priority'), isTrue);
    expect(row['conn_priority'], isNull);
    final s = await SettingsRepo(up.db).loadSettings();
    expect(s.linkPace, isNull);
    expect(s.themeMode, AppThemeMode.dark);
    expect(s.scanRssiMin, -75);

    final fresh = await AppDatabase.open(
        path: await tempPath('fresh'), factory: databaseFactoryFfi);
    addTearDown(fresh.close);
    expect(await columnsOf(up.db), await columnsOf(fresh.db));
  });

  test('a rolled-back file that still has the column upgrades anyway',
      () async {
    final path = await tempPath('rolled');
    final db = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    await db.db.execute('PRAGMA user_version = 30');
    await db.close();
    final again = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    addTearDown(again.close);
    expect(await columnsOf(again.db), contains('conn_priority'));
  });

  test('the choice survives a restart and is in force before the first link',
      () async {
    final path = await tempPath('persist');
    final db1 = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    final s1 = await AppServices.create(appDatabase: db1, ble: _FakeBle());
    await s1.settings.setLinkPace(LinkPace.lowPower);
    await s1.dispose();
    BleService.connectionPriority = null;

    final db2 = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    final s2 = await AppServices.create(appDatabase: db2, ble: _FakeBle());
    addTearDown(s2.dispose);
    expect(s2.settings.linkPace, LinkPace.lowPower);
    expect(BleService.connectionPriority, ConnectionPriority.lowPower);
  });

  Future<(AppServices, _FakeBle)> boot(WidgetTester tester) async {
    late AppServices s;
    final ble = _FakeBle();
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      s = await AppServices.create(appDatabase: db, ble: ble);
    });
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<AppServices>.value(value: s),
        Provider<BleService>.value(value: s.ble),
        Provider<LogRepo>.value(value: s.logRepo),
        ChangeNotifierProvider<SettingsController>.value(value: s.settings),
        ChangeNotifierProvider<DeviceController>.value(value: s.devices),
        ChangeNotifierProvider<ConnectionController>.value(
            value: s.connection),
        ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
        ChangeNotifierProvider<AlertController>.value(value: s.alerts),
        ChangeNotifierProvider<GForceController>.value(value: s.gforce),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(body: SettingsScreen()),
      ),
    ));
    await tester.pump();
    return (s, ble);
  }

  Future<void> teardown(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(const SizedBox());
    // The row stores the choice in the background (like every settings row);
    // one more query queues behind that write, so the DB is not closed under
    // it.
    await tester.runAsync(() => s.appDb.db.rawQuery('SELECT 1'));
    await tester.runAsync(s.dispose);
  }

  testWidgets('the row is absent off Android', (tester) async {
    debugShowConnectionPriorityRow = false;
    final (s, _) = await boot(tester);
    expect(find.textContaining('Link pace'), findsNothing);
    await teardown(tester, s);
  });

  testWidgets('picking 放慢 sets it, stores it, applies it now, row says so',
      (tester) async {
    debugShowConnectionPriorityRow = true;
    final (s, ble) = await boot(tester);
    final row = find.text('Link pace: Default');
    await tester.scrollUntilVisible(row, 200);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Slower (if it keeps dropping)'));
    await tester.pumpAndSettle();

    expect(BleService.connectionPriority, ConnectionPriority.lowPower);
    expect(s.settings.linkPace, LinkPace.lowPower, reason: 'remembered');
    expect(ble.applied, 1, reason: 'the live link is asked at once');
    expect(find.text('Link pace: Slower (if it keeps dropping)'),
        findsOneWidget);
    expect(find.text('Set to "Slower (if it keeps dropping)" and saved.'),
        findsOneWidget);
    await teardown(tester, s);
  });
}
