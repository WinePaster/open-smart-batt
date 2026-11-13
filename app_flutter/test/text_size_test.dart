// Two-level text size (owner ruling 2026-11-13): 大 / Large (default) is
// today's rendering, 小 / Small is the OS font size with no app-side bump.
//
// What this file pins:
//   1. Large is the default — for a new install AND for an upgraded database
//      (schema v27 adds `settings.text_size`, NULL for every old row).
//   2. Small yields EXACTLY the OS scale; Large yields OS × 1.15.
//   3. `AppTheme.userTextScale` divides out the factor actually in force, so
//      it reads 1.0 under BOTH sizes when the OS scale is 1.0. Dividing by the
//      Large constant under Small would read the missing 15 % as the user
//      having shrunk their system font.
//   4. The choice persists, including across an unrelated settings save
//      (`saveSettings` is INSERT OR REPLACE of the whole row).
//   5. Key screens build without a layout overflow under both sizes, at the
//      default and an enlarged OS text scale, in both UI languages.
//
// ⚠️ (5) is a smoke check, not a layout proof: the test font's glyph metrics
// are not the device fonts', so truncation that only shows at 1.0× on a real
// phone cannot be seen here. Real-device checking is still required.
//
// CLEAN-ROOM: expectations derive from this project's own source.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/demo/demo.dart';
import 'package:open_smart_batt/main.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/devices/device_detail_page.dart';
import 'package:open_smart_batt/ui/settings/settings_screen.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The v11 settings shape, written out BY HAND for the reason
/// `schema_v19_test` gives: sharing `_createStatements` with the code under
/// test would make the migration test pass whatever the migration did. v11
/// rather than v26 because the `if (from < N)` chain runs the whole way up, so
/// this proves "every phone that ever had this app comes up Large".
const String _v11History = '''
  CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL, pvlt REAL, svlt REAL, ampere REAL,
    temperature INTEGER, dvol1 REAL, dvol2 REAL, dvol3 REAL, dvol4 REAL,
    soh INTEGER, mode INTEGER, twf INTEGER, serial TEXT, soc INTEGER,
    device_id TEXT, samples INTEGER, app_build TEXT
  )''';

const String _v11SavedDevices = '''
  CREATE TABLE saved_devices (
    id TEXT PRIMARY KEY,
    alias TEXT NOT NULL DEFAULT '',
    name TEXT NOT NULL DEFAULT '',
    last_seen INTEGER,
    last_value REAL,
    stale INTEGER NOT NULL DEFAULT 0,
    product_class TEXT NOT NULL DEFAULT 'unknown',
    display_layout TEXT,
    mac TEXT,
    serial TEXT
  )''';

const String _v11Settings = '''
  CREATE TABLE settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    auto_reconnect INTEGER NOT NULL DEFAULT 1,
    poll_interval_ms INTEGER NOT NULL DEFAULT 1000,
    background_keep_alive INTEGER NOT NULL DEFAULT 0,
    background_monitoring INTEGER NOT NULL DEFAULT 1,
    dark_theme INTEGER NOT NULL DEFAULT 1,
    theme_mode TEXT,
    lang TEXT NOT NULL DEFAULT 'zhHant',
    retention TEXT NOT NULL DEFAULT 'forever',
    temp_unit TEXT NOT NULL DEFAULT 'celsius',
    auto_log INTEGER NOT NULL DEFAULT 1,
    raw_packet_log INTEGER NOT NULL DEFAULT 0,
    log_max_bytes INTEGER
  )''';

const String _v11DiagLog = '''
  CREATE TABLE diag_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL, direction TEXT NOT NULL, hex TEXT NOT NULL,
    note TEXT, device_id TEXT, session_id INTEGER, app_build TEXT
  )''';

Future<Set<String>> _columnsOf(Database db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return {for (final row in info) row['name'] as String};
}

/// Inert BLE with a link stream, so a demo unit can be "connected" the way
/// `demo_ui_test` does it. Never reaches the flutter_blue_plus platform.
class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  String? connectedId;

  @override
  String? get connectedDeviceId => connectedId;
  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<List<DiscoveredDevice>> get scanResults =>
      const Stream<List<DiscoveredDevice>>.empty();
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      Stream<BluetoothAdapterState>.value(BluetoothAdapterState.on);
  @override
  Stream<TelemetrySample> get telemetry =>
      const Stream<TelemetrySample>.empty();
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
  @override
  Future<bool> ensurePermissions() async => true;
  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 15),
  }) async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<void> connect(
    String deviceId, {
    Duration? timeout,
    bool autoConnect = false,
  }) async {
    connectedId = deviceId;
    _linkOut.add(BleLinkState.connecting);
    _linkOut.add(BleLinkState.connected);
    _linkOut.add(BleLinkState.ready);
  }

  @override
  Future<void> disconnect() async {
    connectedId = null;
    _linkOut.add(BleLinkState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  // -------------------------------------------------------------------------
  // 1–2. The model and the factor.
  // -------------------------------------------------------------------------
  group('the setting', () {
    test('defaults to Large, for a new install and for any old/odd row', () {
      expect(AppSettings.defaults.textSize, AppTextSize.large);
      // Pre-v27 row (no column), NULL, an unknown name (downgrade after a
      // future third size) and a wrong type all read Large — never throw.
      for (final m in <Map<String, Object?>>[
        {},
        {'text_size': null},
        {'text_size': 'huge'},
        {'text_size': ''},
        {'text_size': 1},
      ]) {
        expect(
          AppSettings.fromMap(m).textSize,
          AppTextSize.large,
          reason: '$m',
        );
      }
    });

    test('round-trips through toMap/fromMap by name', () {
      final s = AppSettings.defaults.copyWith(textSize: AppTextSize.small);
      expect(s.toMap()['text_size'], 'small');
      expect(AppSettings.fromMap(s.toMap()).textSize, AppTextSize.small);
      // Large is written too — the row is INSERT OR REPLACE'd whole.
      expect(AppSettings.defaults.toMap()['text_size'], 'large');
    });

    test('Large is exactly the pre-setting bump, Small is no bump', () {
      expect(AppTheme.appTextScaleFor(AppTextSize.large), 1.15);
      expect(
        AppTheme.appTextScaleFor(AppTextSize.large),
        AppTheme.baseTextScale,
      );
      expect(AppTheme.appTextScaleFor(AppTextSize.small), 1.0);
    });

    test('Small yields exactly the OS scaler; Large yields OS × 1.15', () {
      for (final os in [0.85, 1.0, 1.3, 2.0]) {
        final osScaler = TextScaler.linear(os);
        final small = AppTheme.applyAppTextScale(osScaler, AppTextSize.small);
        final large = AppTheme.applyAppTextScale(osScaler, AppTextSize.large);
        expect(small.scale(1), os, reason: 'Small at OS $os');
        expect(small.scale(20), osScaler.scale(20), reason: 'Small at OS $os');
        expect(
          large.scale(1),
          closeTo(os * 1.15, 1e-12),
          reason: 'Large at OS $os',
        );
      }
    });

    test('Small passes a non-linear OS scaler through untouched', () {
      // Android 14+ scales large fonts less than small ones. "Same size as
      // the OS" taken literally means not flattening that curve.
      const os = _CurveScaler();
      final small = AppTheme.applyAppTextScale(os, AppTextSize.small);
      expect(identical(small, os), isTrue);
      expect(small.scale(40), os.scale(40));
      // Large keeps the pre-setting behaviour: linear from scale(1).
      final large = AppTheme.applyAppTextScale(os, AppTextSize.large);
      expect(large.scale(40), closeTo(40 * os.scale(1) * 1.15, 1e-9));
    });
  });

  // -------------------------------------------------------------------------
  // 3. userTextScale divides out the factor in force.
  // -------------------------------------------------------------------------
  group('AppTheme.userTextScale', () {
    /// Exactly what `main.dart`'s builder installs, minus the app.
    Future<BuildContext> host(
      WidgetTester tester,
      AppTextSize size,
      double os,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: AppTextScaleScope(
            factor: AppTheme.appTextScaleFor(size),
            child: MediaQuery(
              data: MediaQueryData(
                textScaler: AppTheme.applyAppTextScale(
                  TextScaler.linear(os),
                  size,
                ),
              ),
              child: Builder(
                builder: (c) {
                  ctx = c;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      return ctx;
    }

    for (final size in AppTextSize.values) {
      testWidgets('is 1.0 under ${size.name} when the OS scale is 1.0', (
        tester,
      ) async {
        final ctx = await host(tester, size, 1.0);
        expect(AppTheme.userTextScale(ctx), closeTo(1.0, 1e-12));
      });

      testWidgets('is the OS scale under ${size.name} when it is enlarged', (
        tester,
      ) async {
        final ctx = await host(tester, size, 1.3);
        expect(AppTheme.userTextScale(ctx), closeTo(1.3, 1e-12));
      });
    }

    testWidgets('the dial does not change size between Large and Small', (
      tester,
    ) async {
      // 390 pt screen card: the gauge must read "user left the font alone"
      // under Small too, not "user shrank the font".
      const available = 390.0 - 60;
      final large = AppTheme.gaugeDiameter(
        await host(tester, AppTextSize.large, 1.0),
        available,
      );
      final small = AppTheme.gaugeDiameter(
        await host(tester, AppTextSize.small, 1.0),
        available,
      );
      expect(small, large);
      final large13 = AppTheme.gaugeDiameter(
        await host(tester, AppTextSize.large, 1.3),
        available,
      );
      final small13 = AppTheme.gaugeDiameter(
        await host(tester, AppTextSize.small, 1.3),
        available,
      );
      expect(small13, closeTo(large13, 1e-9));
    });

    testWidgets('without a scope it falls back to the Large factor', (
      tester,
    ) async {
      // Screen-level widget tests pump with `osScale * baseTextScale` and no
      // scope; they must keep describing the pre-setting world.
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              textScaler: TextScaler.linear(AppTheme.baseTextScale),
            ),
            child: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(AppTextScaleScope.factorOf(ctx), AppTheme.baseTextScale);
      expect(AppTheme.userTextScale(ctx), closeTo(1.0, 1e-12));
    });
  });

  // -------------------------------------------------------------------------
  // 1, 4. Schema v27 and persistence.
  // -------------------------------------------------------------------------
  group('schema v27: settings.text_size', () {
    Future<AppDatabase> upgradeFromV11(String tag) async {
      final dir = await Directory.systemTemp.createTemp('osb_$tag');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'v11.db');
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 11,
          onCreate: (db, _) async {
            await db.execute(_v11History);
            await db.execute(_v11SavedDevices);
            await db.execute(_v11Settings);
            await db.execute(_v11DiagLog);
            await db.execute(
              'CREATE INDEX idx_history_ts ON history (timestamp)',
            );
            await db.execute(
              'CREATE INDEX idx_history_device ON history (device_id)',
            );
            await db.execute(
              'CREATE INDEX idx_diag_log_device ON diag_log (device_id)',
            );
          },
        ),
      );
      await legacy.insert('settings', {
        'id': 1,
        'theme_mode': 'dark',
        'poll_interval_ms': 500,
      });
      await legacy.close();
      final upgraded = await AppDatabase.open(
        path: path,
        factory: databaseFactoryFfi,
      );
      addTearDown(upgraded.close);
      return upgraded;
    }

    Future<AppDatabase> freshDatabase(String tag) async {
      final dir = await Directory.systemTemp.createTemp('osb_$tag');
      addTearDown(() => dir.delete(recursive: true));
      final db = await AppDatabase.open(
        path: p.join(dir.path, 'fresh.db'),
        factory: databaseFactoryFfi,
      );
      addTearDown(db.close);
      return db;
    }

    test('an upgraded database comes up Large, with the column NULL', () async {
      final db = await upgradeFromV11('v27_upgrade');
      expect(await _columnsOf(db.db, 'settings'), contains('text_size'));
      final row = (await db.db.query('settings', limit: 1)).single;
      expect(
        row['text_size'],
        isNull,
        reason: 'no DEFAULT: an upgrade must not invent a choice',
      );
      final info = (await db.db.rawQuery(
        'PRAGMA table_info(settings)',
      )).firstWhere((r) => r['name'] == 'text_size');
      expect(info['dflt_value'], isNull);
      final s = await SettingsRepo(db.db).loadSettings();
      expect(s.textSize, AppTextSize.large);
      // A real row, not a fall-through to defaults.
      expect(s.themeMode, AppThemeMode.dark);
      expect(s.pollIntervalMs, 500);
    });

    test('fresh and upgraded settings tables have the same columns', () async {
      final upgraded = await upgradeFromV11('v27_parity');
      final fresh = await freshDatabase('v27_parity_new');
      expect(
        await _columnsOf(upgraded.db, 'settings'),
        await _columnsOf(fresh.db, 'settings'),
      );
      expect(Db.schemaVersion, greaterThanOrEqualTo(27));
    });

    test('Small persists, and survives an unrelated settings save', () async {
      final db = await freshDatabase('v27_roundtrip');
      final repo = SettingsRepo(db.db);
      expect((await repo.loadSettings()).textSize, AppTextSize.large);
      final controller = SettingsController(repo);
      await controller.load();
      expect(controller.textSize, AppTextSize.large);
      await controller.setTextSize(AppTextSize.small);
      expect(controller.textSize, AppTextSize.small);
      expect((await repo.loadSettings()).textSize, AppTextSize.small);
      // INSERT OR REPLACE: a column missing from toMap() would be wiped here.
      await controller.setPollIntervalMs(2000);
      final after = await repo.loadSettings();
      expect(after.textSize, AppTextSize.small);
      expect(after.pollIntervalMs, 2000);
      final row = (await db.db.query('settings', limit: 1)).single;
      expect(row['text_size'], 'small');
      // And back.
      await controller.setTextSize(AppTextSize.large);
      expect((await repo.loadSettings()).textSize, AppTextSize.large);
    });
  });

  // -------------------------------------------------------------------------
  // 2, 5. The real app shell.
  // -------------------------------------------------------------------------
  group('the app shell', () {
    late _FakeBle ble;

    Future<AppServices> makeServices(
      WidgetTester tester, {
      AppTextSize? size,
      AppLang? lang,
    }) async {
      late final AppServices s;
      await tester.runAsync(() async {
        // The one-time disclaimer is a modal: left up, it swallows every tap
        // and the walk below would measure the home page behind a barrier.
        final markerDir = await Directory.systemTemp.createTemp(
          'osb_text_size_ack',
        );
        AckMarker.debugDirectoryOverride = markerDir;
        addTearDown(() {
          AckMarker.debugDirectoryOverride = null;
          markerDir.deleteSync(recursive: true);
        });
        await kDisclaimerAck.markAcknowledged();
        // A file per call, not `inMemoryDatabasePath`: sqflite hands back the
        // SAME instance for the same path, and the matrix opens two apps in
        // one test while the first one's disposal may still be in flight.
        final dbDir = await Directory.systemTemp.createTemp('osb_text_size_db');
        addTearDown(() => dbDir.delete(recursive: true));
        final db = await AppDatabase.open(
          path: p.join(dbDir.path, 'app.db'),
          factory: databaseFactoryFfi,
        );
        // Saved units of every class, so the home grid has tiles to lay out.
        final devices = DeviceRepo(db.db);
        await devices.upsertSavedDevice(
          SavedDevice(
            id: 'AA:BB:CC:DD:EE:01',
            alias: '機車電池 Motorcycle battery',
            name: 'RCE-BATT',
            lastSeen: DateTime.utc(2026, 11, 13, 8),
            lastValue: 13.21,
            productClass: ProductClass.smartBattery,
          ),
        );
        await devices.upsertSavedDevice(
          SavedDevice(
            id: 'AA:BB:CC:DD:EE:02',
            alias: '汽車電容 Car capacitor',
            name: 'RCE-CAP',
            lastSeen: DateTime.utc(2026, 11, 13, 8),
            lastValue: 14.02,
            productClass: ProductClass.supercapacitor,
          ),
        );
        await devices.upsertSavedDevice(
          SavedDevice(
            id: 'AA:BB:CC:DD:EE:03',
            alias: '行動電源 Power bank',
            name: 'RSPB',
            lastSeen: DateTime.utc(2026, 11, 13, 8),
            lastValue: 3.91,
            lastSoc: 76,
            productClass: ProductClass.powerBank,
          ),
        );
        ble = _FakeBle();
        s = await AppServices.create(appDatabase: db, ble: ble);
        if (size != null) await s.settings.setTextSize(size);
        if (lang != null) await s.settings.setLang(lang);
        await s.pending.drain();
      });
      return s;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    double appScale(WidgetTester tester) => MediaQuery.textScalerOf(
      tester.element(find.byType(RootShell)),
    ).scale(1);

    testWidgets('defaults to OS × 1.15, switches to the OS scale, persists', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      // Layout overflows are the matrix's business (below), where they are
      // compared Large-vs-Small; here they would only re-flag the pre-existing
      // test-font ones. Anything else still fails this test.
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.exceptionAsString().contains(' overflowed by ')) return;
        previous?.call(d);
      };
      addTearDown(() => FlutterError.onError = previous);
      final s = await makeServices(tester);
      await tester.pumpWidget(OpenSmartBattApp(services: s));
      await settle(tester);

      expect(s.settings.textSize, AppTextSize.large);
      expect(appScale(tester), closeTo(1.3 * 1.15, 1e-9));
      expect(
        AppTheme.userTextScale(tester.element(find.byType(RootShell))),
        closeTo(1.3, 1e-9),
      );

      // Through the real Settings row, not the controller.
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await settle(tester);
      final row = find.byKey(const ValueKey('settings-text-size'));
      await tester.ensureVisible(row);
      await settle(tester);
      await tester.tap(find.descendant(of: row, matching: find.text('小')));
      await settle(tester);

      expect(s.settings.textSize, AppTextSize.small);
      expect(appScale(tester), closeTo(1.3, 1e-9));
      expect(
        AppTheme.userTextScale(tester.element(find.byType(RootShell))),
        closeTo(1.3, 1e-9),
      );
      late AppSettings stored;
      await tester.runAsync(() async {
        stored = await s.settingsRepo.loadSettings();
      });
      expect(stored.textSize, AppTextSize.small);
      expect(tester.takeException(), isNull);
    });

    // The overflow matrix.
    //
    // Each cell walks the real shell through the screens most likely to be
    // cramped by a text-size change — the home grid (three saved units, then a
    // live demo unit), the device list, the whole Settings list, and the
    // device detail dashboard of both demo units — once under LARGE and once
    // under SMALL, and collects every layout overflow on the way.
    //
    // 🔴 Why a DIFFERENTIAL and not "zero overflows". Under the test font,
    // Large — i.e. today's build, before this setting existed — already
    // overflows in a few places (e.g. the 3-segment Language row and the
    // 4-segment retention row on a 320 pt screen): the test font draws every
    // glyph a full em wide, about twice a real UI font for Latin text. Those
    // are pre-existing and cannot be told apart from real defects here. What
    // this setting must guarantee is narrower and fully checkable:
    //   (a) Small introduces NO overflow that Large does not already have, and
    //       none of Large's gets worse under Small;
    //   (b) the new Text-size row itself never overflows, in any cell.
    // Real-device checking is still required for everything else.
    for (final lang in [AppLang.zhHant, AppLang.en]) {
      for (final os in [1.0, 1.3]) {
        for (final width in [375.0, 320.0]) {
          testWidgets('Small adds no overflow over Large: '
              '${lang.name} OS×$os ${width.toInt()}pt', (tester) async {
            tester.view.physicalSize = Size(width, 1600);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            tester.platformDispatcher.textScaleFactorTestValue = os;
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );

            final large = await _walk(
              tester,
              makeServices,
              settle,
              appScale,
              AppTextSize.large,
              lang,
              os,
            );
            final small = await _walk(
              tester,
              makeServices,
              settle,
              appScale,
              AppTextSize.small,
              lang,
              os,
            );

            final label = lang == AppLang.en ? 'Text size' : '字體大小';
            final newRow = [
              for (final o in [...large, ...small])
                if (o.texts.contains(label)) o,
            ];
            expect(
              newRow,
              isEmpty,
              reason: 'the Text-size row overflowed: $newRow',
            );

            final worse = <String>[];
            for (final o in small) {
              double? base;
              for (final l in large) {
                if (l.stage == o.stage && l.key == o.key) {
                  if (base == null || l.px > base) base = l.px;
                }
              }
              if (base == null || o.px > base + 0.5) {
                worse.add('$o (Large: ${base ?? 'none'})');
              }
            }
            expect(
              worse,
              isEmpty,
              reason:
                  'Small overflowed where Large did not, or worse.\n'
                  'Large: $large\nSmall: $small',
            );
          });
        }
      }
    }
  });
}

/// One layout overflow seen during [_walk].
class _Overflow {
  _Overflow(this.stage, this.texts, this.px);

  /// Which step of the walk it happened in.
  final String stage;

  /// The strings drawn inside the overflowing widget — its identity across
  /// the Large and Small runs (line numbers and render ids differ).
  final List<String> texts;

  /// The largest overflow, in logical pixels.
  final double px;

  String get key => texts.take(4).join(' | ');

  @override
  String toString() => '[$stage] ${px.toStringAsFixed(1)} px in <$key>';
}

typedef _MakeServices =
    Future<AppServices> Function(
      WidgetTester tester, {
      AppTextSize? size,
      AppLang? lang,
    });

/// Pump the real shell under [size] and walk the key screens, returning every
/// overflow outside the root brand app bar.
///
/// ⚠️ The root brand app bar is set aside: its actions ("Full screen" + the
/// connection pill) are Latin text, and under the test font the bar overflows
/// under LARGE as well — today's build — in ways that do not even move
/// monotonically with the text size (its title gets whatever the actions
/// leave). It is a test-font artifact this file cannot tell apart from a real
/// defect, it is not caused by the text size, and it is left to the
/// real-device check.
Future<List<_Overflow>> _walk(
  WidgetTester tester,
  _MakeServices makeServices,
  Future<void> Function(WidgetTester) settle,
  double Function(WidgetTester) appScale,
  AppTextSize size,
  AppLang lang,
  double os,
) async {
  final found = <_Overflow>[];
  var stage = 'start';
  final previous = FlutterError.onError;
  final overflowPx = RegExp(r'overflowed by ([\d.]+) pixels');
  FlutterError.onError = (d) {
    final px = [
      for (final m in overflowPx.allMatches(d.exceptionAsString()))
        double.parse(m.group(1)!),
    ];
    if (px.isEmpty) {
      previous?.call(d); // not a layout overflow: let it fail the test
      return;
    }
    if (_inBrandAppBar(d)) return;
    px.sort();
    found.add(_Overflow(stage, _textsUnder(d), px.last));
  };
  try {
    final s = await makeServices(tester, size: size, lang: lang);
    stage = 'home, idle';
    await tester.pumpWidget(OpenSmartBattApp(services: s));
    await settle(tester);
    expect(
      appScale(tester),
      closeTo(os * AppTheme.appTextScaleFor(size), 1e-9),
    );

    stage = 'home, demo battery live';
    await tester.runAsync(() => s.connection.connect(DemoKind.battery.id));
    await settle(tester);

    stage = 'devices tab';
    await tester.tap(find.byIcon(Icons.list_alt_outlined));
    await settle(tester);

    stage = 'settings';
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await settle(tester);
    // Walk the whole Settings list to its end, so every row is built and laid
    // out at least once under BOTH sizes. A fixed number of drags would reach
    // further down the shorter Small list than the longer Large one, and the
    // comparison would then flag rows Large simply never built.
    final settingsList = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    for (var i = 0; i < 200; i++) {
      final pos = settingsList.position;
      if (pos.pixels >= pos.maxScrollExtent) {
        // Rows below can still grow once async content lands — settle and
        // look again before calling it the end.
        await settle(tester);
        if (pos.pixels >= pos.maxScrollExtent) break;
      }
      pos.jumpTo((pos.pixels + 300).clamp(0.0, pos.maxScrollExtent));
      await tester.pump();
    }
    expect(
      settingsList.position.pixels,
      settingsList.position.maxScrollExtent,
      reason: 'the Settings walk did not reach the end of the list',
    );

    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    for (final kind in DemoKind.values) {
      stage = 'device detail, ${kind.name}';
      await tester.runAsync(() => s.connection.connect(kind.id));
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => DeviceDetailPage(deviceId: kind.id),
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(DeviceDetailPage), findsOneWidget);
      nav.pop();
      await settle(tester);
    }

    stage = 'teardown';
    await tester.runAsync(s.connection.disconnect);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  } finally {
    FlutterError.onError = previous;
  }
  return found;
}

/// Whether an overflow report comes from inside the root brand app bar
/// (`_BrandAppBar` in `main.dart`). Matched through the overflowing widget's
/// element ancestry rather than a file/line, so it survives edits to
/// `main.dart`.
bool _inBrandAppBar(FlutterErrorDetails d) {
  for (final node
      in d.informationCollector?.call() ?? const <DiagnosticsNode>[]) {
    if (node is! DiagnosticsDebugCreator) continue;
    final creator = node.value;
    if (creator is! DebugCreator) continue;
    var found = false;
    creator.element.visitAncestorElements((e) {
      found = e.widget.runtimeType.toString() == '_BrandAppBar';
      return !found;
    });
    return found;
  }
  return false;
}

/// The strings drawn inside the widget an overflow report blames — so a
/// failure names the row ("Text size", "Language", …) instead of a line number.
List<String> _textsUnder(FlutterErrorDetails d) {
  final out = <String>[];
  for (final node
      in d.informationCollector?.call() ?? const <DiagnosticsNode>[]) {
    if (node is! DiagnosticsDebugCreator) continue;
    final creator = node.value;
    if (creator is! DebugCreator) continue;
    void visit(Element e) {
      final w = e.widget;
      if (w is Text && w.data != null) out.add(w.data!);
      e.visitChildren(visit);
    }

    visit(creator.element);
  }
  return out;
}

/// A non-linear scaler shaped like Android 14's: full factor for small text,
/// less for large text.
class _CurveScaler extends TextScaler {
  const _CurveScaler();

  @override
  double scale(double fontSize) =>
      fontSize <= 14 ? fontSize * 1.3 : 14 * 1.3 + (fontSize - 14) * 1.1;

  @override
  double get textScaleFactor => 1.3;

  @override
  TextScaler clamp({double minScaleFactor = 0, double maxScaleFactor = 1e9}) =>
      this;

  @override
  bool operator ==(Object other) => other is _CurveScaler;

  @override
  int get hashCode => 7;
}
