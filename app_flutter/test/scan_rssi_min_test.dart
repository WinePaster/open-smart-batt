// 「搜尋訊號門檻」— schema v30 `settings.scan_rssi_min`.
//
// 何先生 request 2026-11-15; owner ruling: it filters the 搜尋裝置 list ONLY,
// default 不限制 (no limit), user-adjustable, remembered. The page's drawing is
// pinned in `devices_page_test.dart` (group 'scan RSSI threshold').
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/config/app_config.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/devices/scan_list_filter.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';

Future<Set<String>> _columnsOf(Database db, String table) async => {
      for (final r in await db.rawQuery('PRAGMA table_info($table)'))
        r['name'] as String,
    };

void main() {
  setUpAll(sqfliteFfiInit);

  Future<String> tempPath(String tag) async {
    final dir = await Directory.systemTemp.createTemp('osb_v30_$tag');
    addTearDown(() => dir.delete(recursive: true));
    return p.join(dir.path, 'db.sqlite');
  }

  group('model', () {
    test('default is no limit, and a new install stores NULL', () {
      expect(AppSettings.defaults.scanRssiMin, isNull);
      final m = AppSettings.defaults.toMap();
      expect(m.containsKey('scan_rssi_min'), isTrue,
          reason: 'INSERT OR REPLACE: a column missing from toMap erases '
              'itself on the next unrelated save');
      expect(m['scan_rssi_min'], isNull);
    });

    test('every offered value round-trips', () {
      for (final v in AppSettings.scanRssiMinOptions) {
        final back = AppSettings.fromMap(
            AppSettings.defaults.copyWith(scanRssiMin: v).toMap());
        expect(back.scanRssiMin, v);
      }
    });

    test('pre-v30 rows and unreadable values read as no limit', () {
      expect(AppSettings.fromMap(const {}).scanRssiMin, isNull);
      for (final junk in <Object?>[null, -81, 0, 'x', -200]) {
        expect(AppSettings.fromMap({'scan_rssi_min': junk}).scanRssiMin,
            isNull, reason: '$junk');
      }
    });

    test('copyWith keeps it; clearScanRssiMin is the way back to no limit', () {
      final set = AppSettings.defaults.copyWith(scanRssiMin: -75);
      expect(set.copyWith(pollIntervalMs: 500).scanRssiMin, -75);
      expect(set.copyWith(clearScanRssiMin: true).scanRssiMin, isNull);
    });
  });

  group('migration 29 → 30', () {
    /// A v29 file: a current database with `scan_rssi_min` rebuilt away and
    /// `user_version = 29`, holding a settings row with real choices in it.
    Future<String> v29(String tag) async {
      final path = await tempPath(tag);
      final db = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      await db.db.execute('ALTER TABLE settings RENAME TO settings_old');
      final info = await db.db.rawQuery('PRAGMA table_info(settings_old)');
      final defs = [
        for (final r in info)
          if (r['name'] != 'scan_rssi_min')
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
          {'id': Db.settingsRowId, 'theme_mode': 'dark', 'poll_interval_ms': 500});
      expect(await _columnsOf(db.db, 'settings'), isNot(contains('scan_rssi_min')));
      await db.db.execute('PRAGMA user_version = 29');
      await db.close();
      return path;
    }

    test('adds the column as NULL and keeps every other choice', () async {
      final up = await AppDatabase.open(
          path: await v29('up'), factory: databaseFactoryFfi);
      addTearDown(up.close);
      final v = (await up.db.rawQuery('PRAGMA user_version')).single;
      expect(v['user_version'], Db.schemaVersion);
      expect(Db.schemaVersion, greaterThanOrEqualTo(30));
      final row = (await up.db.query('settings')).single;
      expect(row.containsKey('scan_rssi_min'), isTrue);
      expect(row['scan_rssi_min'], isNull);
      final s = await SettingsRepo(up.db).loadSettings();
      expect(s.scanRssiMin, isNull);
      expect(s.themeMode, AppThemeMode.dark);
      expect(s.pollIntervalMs, 500);
    });

    test('upgraded and fresh settings tables match', () async {
      final up = await AppDatabase.open(
          path: await v29('parity'), factory: databaseFactoryFfi);
      addTearDown(up.close);
      final nu = await AppDatabase.open(
          path: await tempPath('fresh'), factory: databaseFactoryFfi);
      addTearDown(nu.close);
      expect(await _columnsOf(up.db, 'settings'),
          await _columnsOf(nu.db, 'settings'));
    });

    test('a rolled-back file that still has the column upgrades anyway',
        () async {
      final path = await tempPath('rolled');
      final db = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      await db.db.execute('PRAGMA user_version = 29');
      await db.close();
      final again =
          await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      addTearDown(again.close);
      expect(await _columnsOf(again.db, 'settings'), contains('scan_rssi_min'));
    });
  });

  test('the choice is remembered across a restart, and 不限制 too', () async {
    final path = await tempPath('persist');
    final db1 = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    final c1 = SettingsController(SettingsRepo(db1.db));
    await c1.load();
    await c1.setScanRssiMin(-70);
    // An unrelated save must not erase it (INSERT OR REPLACE).
    await c1.setKeepScreenAwake(true);
    await db1.close();

    final db2 = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    final c2 = SettingsController(SettingsRepo(db2.db));
    await c2.load();
    expect(c2.scanRssiMin, -70);
    await c2.setScanRssiMin(null);
    await db2.close();

    final db3 = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
    addTearDown(db3.close);
    final c3 = SettingsController(SettingsRepo(db3.db));
    await c3.load();
    expect(c3.scanRssiMin, isNull);
  });

  group('filter (scan list only)', () {
    const vStrong = DiscoveredDevice(id: 'a', name: 'A', rssi: -60, isVendor: true);
    const vEdge = DiscoveredDevice(id: 'b', name: 'B', rssi: -80, isVendor: true);
    const vWeak = DiscoveredDevice(id: 'c', name: 'C', rssi: -92, isVendor: true);
    const oStrong = DiscoveredDevice(id: 'd', name: 'D', rssi: -50);
    const oWeak = DiscoveredDevice(id: 'e', name: 'E', rssi: -99);
    const all = [vStrong, vEdge, vWeak, oStrong, oWeak];

    test('no limit: only the vendor toggle acts', () {
      final v = filterScanList(nearby: all, showAll: false, rssiMin: null);
      expect(v.shown, [vStrong, vEdge, vWeak]);
      expect(v.nonVendorHidden, 2);
      expect(v.weakHidden, 0);
    });

    test('-80 keeps -80 and hides weaker; counts never overlap', () {
      final v = filterScanList(nearby: all, showAll: false, rssiMin: -80);
      expect(v.shown, [vStrong, vEdge]);
      // Non-RCE that PASS the threshold — what 顯示全部 would reveal.
      expect(v.nonVendorHidden, 1);
      // RCE that the threshold hides — what relaxing it would reveal. The
      // weak non-RCE row is in neither count.
      expect(v.weakHidden, 1);
    });

    test('show all + threshold: weak non-RCE rows count as weak', () {
      final v = filterScanList(nearby: all, showAll: true, rssiMin: -80);
      expect(v.shown, [vStrong, vEdge, oStrong]);
      expect(v.nonVendorHidden, 0);
      expect(v.weakHidden, 2);
    });
  });

  group('diagnostic log header', () {
    List<String> header({String? scanRssiMin}) => exportHeaderLines(
          title: 'OpenSmartBatt diagnostic log',
          exportedAt: DateTime.utc(2026, 11, 15),
          appBuild: '0.7.51+1',
          platform: 'android 16',
          edition: AppEdition.community,
          scope: 'all devices',
          layout: 'face=standard modules=-',
          home: 'tiles=auto',
          mode: AppMode.personal,
          themeMode: AppThemeMode.light,
          accent: AccentTheme.amber,
          speedDetection: false,
          gMeter: false,
          resolution: ExportResolution.none,
          rawPacketLog: false,
          scanRssiMin: scanRssiMin,
          devices: const [],
        );

    test('states off and a value; absent when not passed (CSV)', () {
      expect(header(scanRssiMin: 'off'), contains('scan rssi min: off'));
      expect(header(scanRssiMin: '-80'), contains('scan rssi min: -80'));
      expect(header().where((l) => l.startsWith('scan rssi min:')), isEmpty);
    });
  });
}
