// design 0105 P1 — one orientation policy (owner ruling 2026-11-13:
// Q2 = B「手機僅設定開啟才橫式」, Q3 = A「最短邊 ≥ 600 dp 自動＋設定」).
//
// What this file pins:
//   1. The decision: landscape is allowed when the window's shortest side is
//      ≥ 600 dp OR 「允許橫式畫面」 is on; otherwise portrait, as before.
//   2. `apply` sends only when the set changes (it runs on every rotation).
//   3. A full-screen chart page holds landscape; `apply` does not override the
//      hold; leaving restores TO THE POLICY (never a hard-coded portrait) —
//      and only when the last of nested holds is released.
//   4. Nothing in lib/ but the policy calls `setPreferredOrientations`.
//   5. Schema v28: `settings.allow_landscape`, off for an upgraded install,
//      same columns fresh vs upgraded, persists across an unrelated save.
//   6. The real shell forwards the Settings switch to the platform.
//
// CLEAN-ROOM: expectations derive from this project's own source and docs.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/ui/util/orientation_policy.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/landscape_harness.dart';

List<String> _names(List<DeviceOrientation> os) => [
  for (final o in os) o.toString(),
];

/// Record every orientation request from here to the end of the test.
List<List<String>> _recordOrientations(WidgetTester t) {
  final calls = <List<String>>[];
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        calls.add(List<String>.from(call.arguments as List));
      }
      return null;
    },
  );
  addTearDown(
    () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

/// The v27 settings table, by hand (sharing `_createStatements` would make the
/// migration test pass whatever the migration did — `schema_v19_test`'s
/// reason). Only the settings table matters to v28; the rest of a real v27
/// database is created by the chain from v1 in `freshDatabase`, so this test
/// upgrades a v27-shaped settings table inside an otherwise-current file.
Future<AppDatabase> _upgradeFromV27(String tag) async {
  final dir = await Directory.systemTemp.createTemp('osb_$tag');
  addTearDown(() => dir.delete(recursive: true));
  final path = p.join(dir.path, 'v27.db');
  // Build a current database, then roll its settings table and user_version
  // back to the v27 shape: same columns minus `allow_landscape`.
  final current = await AppDatabase.open(
    path: path,
    factory: databaseFactoryFfi,
  );
  final cols = [
    for (final r in await current.db.rawQuery('PRAGMA table_info(settings)'))
      r['name'] as String,
  ]..remove('allow_landscape');
  await current.db.execute('ALTER TABLE settings RENAME TO settings_old');
  final info = await current.db.rawQuery('PRAGMA table_info(settings_old)');
  final defs = [
    for (final r in info)
      if (r['name'] != 'allow_landscape')
        [
          r['name'],
          r['type'],
          if (r['pk'] == 1) 'PRIMARY KEY',
          if (r['notnull'] == 1) 'NOT NULL',
          if (r['dflt_value'] != null) 'DEFAULT ${r['dflt_value']}',
        ].join(' '),
  ];
  await current.db.execute('CREATE TABLE settings (${defs.join(', ')})');
  await current.db.execute('DROP TABLE settings_old');
  await current.db.insert('settings', {
    'id': 1,
    'theme_mode': 'dark',
    'poll_interval_ms': 500,
  });
  await current.db.execute('PRAGMA user_version = 27');
  await current.close();
  expect(cols, isNot(contains('allow_landscape')));
  final upgraded = await AppDatabase.open(
    path: path,
    factory: databaseFactoryFfi,
  );
  addTearDown(upgraded.close);
  return upgraded;
}

Future<AppDatabase> _fresh(String tag) async {
  final dir = await Directory.systemTemp.createTemp('osb_$tag');
  addTearDown(() => dir.delete(recursive: true));
  final db = await AppDatabase.open(
    path: p.join(dir.path, 'fresh.db'),
    factory: databaseFactoryFfi,
  );
  addTearDown(db.close);
  return db;
}

Future<Set<String>> _columnsOf(Database db, String table) async => {
  for (final r in await db.rawQuery('PRAGMA table_info($table)'))
    r['name'] as String,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUp(OrientationPolicy.debugReset);
  tearDown(OrientationPolicy.debugReset);

  group('1. the decision', () {
    test('phones stay portrait unless the user asks (Q2 = B)', () {
      for (final side in [320.0, 360.0, 390.0, 430.0, 480.0, 599.9]) {
        expect(
          OrientationPolicy.orientationsFor(
            shortestSide: side,
            userAllowsLandscape: false,
          ),
          OrientationPolicy.portraitOnly,
          reason: 'shortest side $side, setting off',
        );
        expect(
          OrientationPolicy.orientationsFor(
            shortestSide: side,
            userAllowsLandscape: true,
          ),
          OrientationPolicy.any,
          reason: 'shortest side $side, setting on',
        );
      }
    });

    test('a window ≥ 600 dp on its shortest side allows landscape by itself '
        '(Q3 = A)', () {
      for (final side in [600.0, 720.0, 768.0, 1080.0]) {
        for (final allow in [false, true]) {
          expect(
            OrientationPolicy.landscapeAllowed(
              shortestSide: side,
              userAllowsLandscape: allow,
            ),
            isTrue,
            reason: 'shortest side $side, setting $allow',
          );
        }
      }
    });

    test('"any" keeps both portraits; landscapeOnly has no portrait', () {
      expect(
        OrientationPolicy.any,
        containsAll(OrientationPolicy.portraitOnly),
      );
      expect(
        OrientationPolicy.any,
        containsAll(OrientationPolicy.landscapeOnly),
      );
      expect(
        OrientationPolicy.landscapeOnly.any(
          (o) => o.toString().contains('portrait'),
        ),
        isFalse,
      );
    });

    testWidgets('currentShortestSide reads the window, in dp', (t) async {
      t.view.physicalSize = const Size(2532, 1170);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      expect(OrientationPolicy.currentShortestSide(), closeTo(390, 1e-9));
      expect(OrientationPolicy.current, OrientationPolicy.portraitOnly);
      t.view.physicalSize = const Size(1280, 720);
      t.view.devicePixelRatio = 1;
      expect(OrientationPolicy.current, OrientationPolicy.any);
    });
  });

  group('2–3. applying it', () {
    testWidgets('apply sends once per change, not once per call', (t) async {
      setWindow(t, Win.portrait.size);
      final calls = _recordOrientations(t);
      await OrientationPolicy.apply();
      await OrientationPolicy.apply();
      await OrientationPolicy.apply(userAllowsLandscape: false);
      expect(calls, [_names(OrientationPolicy.portraitOnly)]);
      await OrientationPolicy.apply(userAllowsLandscape: true);
      expect(calls.last, _names(OrientationPolicy.any));
      // A rotation: same shortest side, nothing to resend.
      t.view.physicalSize = Win.phoneLandscape.size;
      await OrientationPolicy.apply();
      expect(calls.length, 2);
      await OrientationPolicy.apply(userAllowsLandscape: false);
      expect(calls.last, _names(OrientationPolicy.portraitOnly));
      expect(calls.length, 3);
    });

    testWidgets('a full-screen hold wins over apply, and leaving restores the '
        'policy as it stands THEN', (t) async {
      setWindow(t, Win.portrait.size);
      final calls = _recordOrientations(t);
      await OrientationPolicy.apply();
      await OrientationPolicy.enterFullScreenLandscape();
      expect(calls.last, _names(OrientationPolicy.landscapeOnly));
      // The user flips the setting while the chart is open: recorded, not sent.
      await OrientationPolicy.apply(userAllowsLandscape: true);
      expect(calls.last, _names(OrientationPolicy.landscapeOnly));
      await OrientationPolicy.exitFullScreenLandscape();
      expect(calls.last, _names(OrientationPolicy.any));
    });

    testWidgets('nested holds: only the last to leave restores', (t) async {
      setWindow(t, Win.portrait.size);
      final calls = _recordOrientations(t);
      await OrientationPolicy.enterFullScreenLandscape();
      await OrientationPolicy.enterFullScreenLandscape();
      await OrientationPolicy.exitFullScreenLandscape();
      expect(calls.last, _names(OrientationPolicy.landscapeOnly));
      await OrientationPolicy.exitFullScreenLandscape();
      expect(calls.last, _names(OrientationPolicy.portraitOnly));
      // An unbalanced extra exit is harmless: it restores again, no underflow.
      await OrientationPolicy.exitFullScreenLandscape();
      expect(calls.last, _names(OrientationPolicy.portraitOnly));
      await OrientationPolicy.enterFullScreenLandscape();
      expect(calls.last, _names(OrientationPolicy.landscapeOnly));
    });

    for (final (win, allow, expected) in [
      (Win.portrait, false, OrientationPolicy.portraitOnly),
      (Win.phoneLandscape, false, OrientationPolicy.portraitOnly),
      (Win.phoneLandscape, true, OrientationPolicy.any),
      (Win.unit853, false, OrientationPolicy.portraitOnly),
      (Win.unit1024, false, OrientationPolicy.any),
      (Win.unit1280, false, OrientationPolicy.any),
      (Win.unit1920, false, OrientationPolicy.any),
    ]) {
      testWidgets('leaving a chart at $win, setting $allow, restores '
          '${expected == OrientationPolicy.any ? 'any' : 'portrait'}', (
        t,
      ) async {
        setWindow(t, win.size);
        final calls = _recordOrientations(t);
        await OrientationPolicy.apply(userAllowsLandscape: allow);
        await OrientationPolicy.enterFullScreenLandscape();
        await OrientationPolicy.exitFullScreenLandscape();
        expect(calls.last, _names(expected));
      });
    }
  });

  test(
    '4. nothing in lib/ but the policy talks to setPreferredOrientations',
    () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.endsWith('orientation_policy.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final code = lines[i].split('//').first;
          if (code.contains('setPreferredOrientations')) {
            offenders.add('${f.path}:${i + 1}');
          }
        }
      }
      expect(offenders, isEmpty);
    },
  );

  group('5. schema v28: settings.allow_landscape', () {
    test('an upgraded database comes up with the switch off', () async {
      final db = await _upgradeFromV27('v28_upgrade');
      expect(await _columnsOf(db.db, 'settings'), contains('allow_landscape'));
      final row = (await db.db.query('settings', limit: 1)).single;
      expect(row['allow_landscape'], 0);
      final s = await SettingsRepo(db.db).loadSettings();
      expect(s.allowLandscape, isFalse);
      // A real row, not a fall-through to defaults.
      expect(s.themeMode, AppThemeMode.dark);
      expect(s.pollIntervalMs, 500);
    });

    test('fresh and upgraded settings tables have the same columns', () async {
      final upgraded = await _upgradeFromV27('v28_parity');
      final fresh = await _fresh('v28_parity_new');
      expect(
        await _columnsOf(upgraded.db, 'settings'),
        await _columnsOf(fresh.db, 'settings'),
      );
      final v = (await upgraded.db.rawQuery('PRAGMA user_version')).single;
      expect(v['user_version'], Db.schemaVersion);
    });

    test('model: default off; old/odd rows read off; round-trips', () {
      expect(AppSettings.defaults.allowLandscape, isFalse);
      for (final m in <Map<String, Object?>>[
        {},
        {'allow_landscape': null},
        {'allow_landscape': 0},
        {'allow_landscape': 'yes'},
      ]) {
        expect(AppSettings.fromMap(m).allowLandscape, isFalse, reason: '$m');
      }
      final on = AppSettings.defaults.copyWith(allowLandscape: true);
      expect(on.toMap()['allow_landscape'], 1);
      expect(AppSettings.fromMap(on.toMap()).allowLandscape, isTrue);
      expect(AppSettings.defaults.toMap()['allow_landscape'], 0);
    });

    test('persists, and survives an unrelated settings save', () async {
      final db = await _fresh('v28_roundtrip');
      final repo = SettingsRepo(db.db);
      final c = SettingsController(repo);
      await c.load();
      expect(c.allowLandscape, isFalse);
      await c.setAllowLandscape(true);
      expect((await repo.loadSettings()).allowLandscape, isTrue);
      await c.setPollIntervalMs(2000);
      final after = await repo.loadSettings();
      expect(after.allowLandscape, isTrue);
      expect(after.pollIntervalMs, 2000);
      await c.setAllowLandscape(false);
      expect((await repo.loadSettings()).allowLandscape, isFalse);
    });
  });

  group('6. the real shell', () {
    testWidgets('a phone boots portrait; the Settings switch turns landscape '
        'on and off', (t) async {
      setWindow(t, Win.portrait.size);
      final calls = _recordOrientations(t);
      final s = await makeHarnessServices(t);
      await pumpShell(t, s);
      expect(calls.last, _names(OrientationPolicy.portraitOnly));

      await t.tap(find.byIcon(Icons.settings_outlined));
      await settleHarness(t);
      final row = find.byKey(const ValueKey('settings-allow-landscape'));
      await t.ensureVisible(row);
      await settleHarness(t);
      await t.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await settleHarness(t);
      expect(s.settings.allowLandscape, isTrue);
      expect(calls.last, _names(OrientationPolicy.any));

      await t.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await settleHarness(t);
      expect(s.settings.allowLandscape, isFalse);
      expect(calls.last, _names(OrientationPolicy.portraitOnly));
    });

    testWidgets('a stored "on" is applied at start-up', (t) async {
      setWindow(t, Win.portrait.size);
      final calls = _recordOrientations(t);
      final s = await makeHarnessServices(t, allowLandscape: true);
      await pumpShell(t, s);
      expect(calls.last, _names(OrientationPolicy.any));
    });

    testWidgets('a wide window allows landscape with the switch off', (
      t,
    ) async {
      setWindow(t, Win.unit1280.size);
      final calls = _recordOrientations(t);
      final s = await makeHarnessServices(t);
      await pumpShell(t, s);
      expect(s.settings.allowLandscape, isFalse);
      expect(calls.last, _names(OrientationPolicy.any));
    });
  });
}
