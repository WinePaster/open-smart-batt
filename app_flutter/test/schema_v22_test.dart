// Schema v22 — design 0080 P2's nine alert columns across two tables.
//
// WHY THIS FILE EXISTS, and it is a fourth reason. `schema_v18/19_test` guard a
// SETTING (a wrong one is visible and reversible). `schema_v20_test` guards
// columns nothing displays (a defect only surfaces in the corpus, months on).
// `schema_v21_test` guards a one-shot data REWRITE. This one guards the
// distinction between **NULL and a number on a column that decides whether an
// alarm fires** — which is invisible on the phone, permanent, and wrong in the
// direction users notice.
//
// Concretely: `resolveThresholds()` ranks the owner's value ABOVE the unit's own
// `0x2B` (design 0080 §3.1). So a migration that helpfully seeded `alert_ov`
// from the category table would not merely be untidy — it would state that every
// existing owner typed that number, layer ② could never be reached again, and
// the third-generation capacitor that leaves the factory at OV 16.0 V would be
// warned about at 14.8 for the rest of its life. There is no second pass that
// fixes that, because from the app's point of view nothing is wrong.
//
// Four things are asserted, and each is a way this goes wrong:
//
//   * 🔴 **The three thresholds arrive NULL**, on old rows and on new ones, with
//     no DEFAULT on the column — the state `WHERE alert_uv IS NULL` has to be
//     able to count.
//   * 🔴 **`alerts_enabled` arrives 0** — Q4. A DEFAULT of 1 grants every
//     upgrading phone a notification feature nobody consented to, and on iOS the
//     permission it would then request is one-shot.
//   * 🔴 **The three tuning parameters DO take their defaults** — the opposite
//     call on the same question, because 5 s / 15 min / 3 is what the feature
//     ships with rather than something a user was asked.
//   * 🔴 **Nothing was seeded from `product_class` / `declared_category`.** The
//     standing rule since v20, restated because this is the first migration
//     where seeding would have looked like a favour.
//
// The v21 schema below is written out BY HAND, same discipline as
// `schema_v11/v17/v20/v21`: a fixture that borrows `_createStatements` from the
// code under test passes whatever that code does, including the bug.
//
// CLEAN-ROOM: expectations derive from this project's own source and design docs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The v21 shape — what a phone running v0.7.25 … v0.7.28 has on disk.
const List<String> _v21Schema = <String>[
  '''
  CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    pvlt REAL, svlt REAL, ampere REAL, temperature INTEGER,
    dvol1 REAL, dvol2 REAL, dvol3 REAL, dvol4 REAL,
    soh INTEGER, mode INTEGER, twf INTEGER, serial TEXT, soc INTEGER,
    device_id TEXT, samples INTEGER, app_build TEXT,
    speed REAL, accel REAL, g_long REAL, g_lat REAL,
    bucket_s INTEGER NOT NULL DEFAULT 60
  )''',
  'CREATE INDEX idx_history_ts ON history (timestamp)',
  'CREATE INDEX idx_history_device ON history (device_id)',
  'CREATE INDEX idx_history_device_ts ON history (device_id, timestamp)',
  '''
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
    serial TEXT,
    declared_category TEXT,
    declared_model TEXT,
    declared_region TEXT,
    declared_label TEXT,
    declared_capacity TEXT,
    declared_note TEXT,
    declared_at INTEGER,
    declared_retrofit INTEGER
  )''',
  '''
  CREATE TABLE settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    auto_reconnect INTEGER NOT NULL DEFAULT 1,
    poll_interval_ms INTEGER NOT NULL DEFAULT 1000,
    background_keep_alive INTEGER NOT NULL DEFAULT 0,
    background_monitoring INTEGER NOT NULL DEFAULT 1,
    background_monitoring_ios INTEGER NOT NULL DEFAULT 0,
    dark_theme INTEGER NOT NULL DEFAULT 1,
    theme_mode TEXT,
    lang TEXT NOT NULL DEFAULT 'zhHant',
    temp_unit TEXT NOT NULL DEFAULT 'celsius',
    auto_log INTEGER NOT NULL DEFAULT 1,
    raw_packet_log INTEGER NOT NULL DEFAULT 0,
    retention TEXT NOT NULL DEFAULT 'forever',
    log_max_bytes INTEGER NOT NULL DEFAULT ${20 * 1024 * 1024},
    speed_detection INTEGER NOT NULL DEFAULT 0,
    speed_unit TEXT NOT NULL DEFAULT 'kmh',
    home_layout TEXT,
    g_meter_enabled INTEGER NOT NULL DEFAULT 0,
    g_calibration TEXT,
    app_mode TEXT,
    accent_theme TEXT
  )''',
  '''
  CREATE TABLE diag_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    direction TEXT NOT NULL,
    hex TEXT NOT NULL,
    note TEXT,
    device_id TEXT,
    session_id INTEGER,
    app_build TEXT
  )''',
  'CREATE INDEX idx_diag_log_ts ON diag_log (timestamp)',
  'CREATE INDEX idx_diag_log_device ON diag_log (device_id)',
  '''
  CREATE TABLE device_facts (
    id TEXT PRIMARY KEY,
    name TEXT,
    product_class TEXT,
    mac TEXT,
    serial TEXT,
    first_seen INTEGER NOT NULL,
    last_seen INTEGER NOT NULL
  )''',
  'CREATE INDEX idx_device_facts_mac ON device_facts (mac)',
  '''
  CREATE TABLE autoconnect_arm (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    device_id TEXT NOT NULL,
    armed_at INTEGER NOT NULL,
    app_build TEXT,
    session_id INTEGER
  )''',
];

/// Two units and one settings row, seeded into every fixture below.
///
/// The battery carries a full design 0066 declaration — it is the row a
/// well-meant "seed the thresholds from the category" would have written to.
const String _batteryId = 'AA:BB:CC:DD:EE:01';
const String _bankId = 'AA:BB:CC:DD:EE:02';

Future<Map<String, Object?>> _columnInfo(
    dynamic db, String table, String column) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return info
      .cast<Map<String, Object?>>()
      .firstWhere((r) => r['name'] == column);
}

Future<Set<String>> _columnsOf(dynamic db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return {for (final row in info) row['name'] as String};
}

Future<Map<String, Object?>> _rowOf(dynamic db, String id) async =>
    (await db.query('saved_devices', where: 'id = ?', whereArgs: [id])).single;

void main() {
  setUpAll(sqfliteFfiInit);

  /// Build a real v21 file on disk, seed it, then open it with the current app
  /// so the 21 → 22 branch actually runs.
  Future<AppDatabase> upgradeFromV21(String tag) async {
    final dir = await Directory.systemTemp.createTemp('osb_$tag');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'v21.db');
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 21,
        onCreate: (db, _) async {
          for (final stmt in _v21Schema) {
            await db.execute(stmt);
          }
        },
      ),
    );
    await legacy.insert('saved_devices', {
      'id': _batteryId,
      'alias': '阿福的機車',
      'name': 'RCE_9a',
      'last_seen': 1755300000000,
      'last_value': 13.31,
      'stale': 0,
      'product_class': 'smart_battery',
      'declared_category': 'motorcycle-battery',
      'declared_at': 1755300000000,
    });
    await legacy.insert('saved_devices', {
      'id': _bankId,
      'alias': 'RSPB-01',
      'name': 'RCE_RSPB-01',
      'stale': 0,
      'product_class': 'power_bank',
    });
    await legacy.insert('settings', {
      'id': 1,
      'lang': 'zhHant',
      'retention': 'forever',
    });
    await legacy.close();
    final upgraded =
        await AppDatabase.open(path: path, factory: databaseFactoryFfi);
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

  group('v21 → v22: the columns exist with the right emptiness', () {
    test('🔴 the three thresholds and the mute are NULL with no DEFAULT',
        () async {
      final db = await upgradeFromV21('v22_null');
      final cols = await _columnsOf(db.db, 'saved_devices');
      for (final c in ['alert_ov', 'alert_uv', 'alert_ot', 'alert_muted_until']) {
        expect(cols, contains(c));
        final info = await _columnInfo(db.db, 'saved_devices', c);
        expect(info['dflt_value'], isNull,
            reason: '$c: a DEFAULT states that the owner answered — and layer ① '
                'outranks the unit\'s own 0x2B, so that answer would be '
                'permanent (design 0080 §3.6.1)');
        expect(info['notnull'], 0);
      }
    });

    test('🔴 an existing row upgrades with alert_* NULL, not 0', () async {
      // The sentinel trap in one assertion: `0` is a real threshold as far as
      // every comparison in the app is concerned, and `IS NULL` stops counting
      // the people who never answered.
      final db = await upgradeFromV21('v22_row');
      final row = await _rowOf(db.db, _batteryId);
      expect(row['alert_ov'], isNull);
      expect(row['alert_uv'], isNull);
      expect(row['alert_ot'], isNull);
      expect(row['alert_muted_until'], isNull);
      expect(row['alert_ov'], isNot(0));
      expect(row['alert_uv'], isNot(0));
    });

    test('alert_enabled is ON for an upgraded row — subordinate, not consent',
        () async {
      final db = await upgradeFromV21('v22_devsw');
      expect((await _rowOf(db.db, _batteryId))['alert_enabled'], 1);
      final info = await _columnInfo(db.db, 'saved_devices', 'alert_enabled');
      expect(info['notnull'], 1);
      expect(info['dflt_value'], '1');
    });
  });

  group('v21 → v22: the global switch and its parameters', () {
    test('🔴 alerts_enabled upgrades to 0 — Q4', () async {
      final db = await upgradeFromV21('v22_master');
      final row = (await db.db.query('settings')).single;
      expect(row['alerts_enabled'], 0,
          reason: 'a DEFAULT of 1 grants an interruption nobody consented to, '
              'and asks a one-shot iOS permission on their behalf');
      final loaded = await SettingsRepo(db.db).loadSettings();
      expect(loaded.alertsEnabled, isFalse);
    });

    test('the three parameters take the shipped defaults', () async {
      // The opposite call from the thresholds, on purpose: 5 s / 15 min / 3 is
      // the tuning the feature ships with, not an answer anyone gave, so a NULL
      // here would mean "this build does not know how long to debounce for".
      final db = await upgradeFromV21('v22_params');
      final row = (await db.db.query('settings')).single;
      expect(row['alert_sustain_sec'], 5);
      expect(row['alert_repeat_min'], 15);
      expect(row['alert_max_per_event'], 3);
      final loaded = await SettingsRepo(db.db).loadSettings();
      expect(loaded.alertSustainSec, 5);
      expect(loaded.alertRepeatMin, 15);
      expect(loaded.alertMaxPerEvent, 3);
    });

    test('🔴 a fresh install agrees with an upgraded one on the switch',
        () async {
      // v13's lesson: the two paths are written separately, so "new installs are
      // off" and "upgrades are off" are two facts, not one.
      final fresh = await freshDatabase('v22_fresh_master');
      expect((await SettingsRepo(fresh.db).loadSettings()).alertsEnabled,
          isFalse);
      expect(AppSettings.defaults.alertsEnabled, isFalse);
    });
  });

  group('v21 → v22: nothing was invented', () {
    test('🔴 no threshold was seeded from product_class or the declaration',
        () async {
      // The temptation this migration had to refuse. The battery below declares
      // `motorcycle-battery`, for which `kCategoryDefaults` has a full row —
      // writing it in would have looked helpful on every screen and would have
      // made the unit's own 0x2B unreachable forever.
      final db = await upgradeFromV21('v22_noseed');
      final row = await _rowOf(db.db, _batteryId);
      expect(row['product_class'], 'smart_battery');
      expect(row['declared_category'], 'motorcycle-battery');
      expect(row['alert_ov'], isNull);
      expect(row['alert_uv'], isNull);
      expect(row['alert_ot'], isNull);

      // …and read back through the model, the resolution still reaches layer ②.
      final saved = (await DeviceRepo(db.db).getDevice(_batteryId))!;
      expect(saved.alertOv, isNull);
      final t = resolveThresholds(
        userOv: saved.alertOv,
        userUv: saved.alertUv,
        userOt: saved.alertOt,
        reported: TelemetrySample(
          timestamp: DateTime.utc(2026, 8, 22),
          deviceType: 0x02,
          warnOv: 15.0,
          warnUv: 11.0,
          warnOt: 80,
        ),
        category: saved.declared.category,
        wireClass: saved.productClass,
      );
      expect(t.ov.source, ThresholdSource.device,
          reason: 'a seeded default would have made this ThresholdSource.user, '
              'permanently, on every phone in the field');
      expect(t.ov.value, 15.0);
    });

    test('the power bank row is untouched too', () async {
      final db = await upgradeFromV21('v22_bank');
      final row = await _rowOf(db.db, _bankId);
      expect(row['product_class'], 'power_bank');
      expect(row['alert_ot'], isNull,
          reason: 'the 50 °C is layer ③, computed at read time — persisting it '
              'would turn an app default into the owner\'s own answer');
    });

    test('running the upgrade twice changes nothing', () async {
      final db = await upgradeFromV21('v22_twice');
      final before = await _rowOf(db.db, _batteryId);
      await db.close();
      final again =
          await AppDatabase.open(path: db.db.path, factory: databaseFactoryFfi);
      addTearDown(again.close);
      expect(await _rowOf(again.db, _batteryId), before);
    });
  });

  group('the write path', () {
    test('🔴 a cleared threshold goes back to NULL, not to 0', () async {
      // `DeviceRepo.setAlertSettings` writes all five columns including the
      // nulls — the 「還原」 button's entire mechanism. Skip the nulls and a value
      // could be set but never taken back.
      final db = await upgradeFromV21('v22_write');
      final repo = DeviceRepo(db.db);
      await repo.setAlertSettings(_batteryId,
          enabled: true, ov: null, uv: 12.4, ot: null, mutedUntilMs: null);
      expect((await _rowOf(db.db, _batteryId))['alert_uv'], 12.4);

      await repo.setAlertSettings(_batteryId,
          enabled: true, ov: null, uv: null, ot: null, mutedUntilMs: null);
      final row = await _rowOf(db.db, _batteryId);
      expect(row['alert_uv'], isNull);
      expect(row['alert_uv'], isNot(0));
    });

    test('🔴 an unrelated upsert does not erase the alert columns', () async {
      // `upsertSavedDevice` is INSERT OR REPLACE of the WHOLE row, so a column
      // missing from `SavedDevice.toMap` is not merely unsaved — it is erased at
      // some later, unrelated moment. Here: the user mutes for an hour, then
      // renames the device.
      final db = await upgradeFromV21('v22_upsert');
      final repo = DeviceRepo(db.db);
      const muteAt = 1755303600000;
      await repo.setAlertSettings(_batteryId,
          enabled: false, ov: 15.5, uv: 12.4, ot: 70, mutedUntilMs: muteAt);
      final saved = (await repo.getDevice(_batteryId))!;
      await repo.upsertSavedDevice(saved.copyWith(alias: '新名字'));

      final back = (await repo.getDevice(_batteryId))!;
      expect(back.alias, '新名字');
      expect(back.alertEnabled, isFalse);
      expect(back.alertOv, 15.5);
      expect(back.alertUv, 12.4);
      expect(back.alertOt, 70);
      expect(back.alertMutedUntilMs, muteAt);
    });

    test('🔴 an unrelated settings write does not erase the four globals',
        () async {
      // The same trap on the settings row — and that row is REPLACEd on every
      // single preference change, so it is the likelier of the two to bite.
      final db = await upgradeFromV21('v22_settings_write');
      final repo = SettingsRepo(db.db);
      await repo.saveSettings(AppSettings.defaults.copyWith(
        alertsEnabled: true,
        alertSustainSec: 9,
        alertRepeatMin: 30,
        alertMaxPerEvent: 1,
      ));
      final after = (await repo.loadSettings()).copyWith(rawPacketLog: true);
      await repo.saveSettings(after);

      final back = await repo.loadSettings();
      expect(back.rawPacketLog, isTrue);
      expect(back.alertsEnabled, isTrue);
      expect(back.alertSustainSec, 9);
      expect(back.alertRepeatMin, 30);
      expect(back.alertMaxPerEvent, 1);
    });

    test('an out-of-range stored parameter is clamped, never zero', () async {
      // A hand-edited row, or a downgrade past a build with a wider range. A
      // sustain of 0 would make every single-frame blip a warning — the exact
      // thing the debounce exists to stop.
      final db = await upgradeFromV21('v22_clamp');
      await db.db.update(
          'settings', {'alert_sustain_sec': 0, 'alert_max_per_event': 999});
      final back = await SettingsRepo(db.db).loadSettings();
      expect(back.alertSustainSec, AppSettings.alertSustainMinSec);
      expect(back.alertMaxPerEvent, AppSettings.alertMaxPerEventMax);
    });
  });

  group('a fresh database and an upgraded one are the same schema', () {
    test('saved_devices and settings: identical columns', () async {
      // `_createStatements` and the `_onUpgrade` chain are two independent
      // descriptions of one schema that no compiler relates to each other, and
      // every migration this project has shipped had to touch both.
      final upgraded = await upgradeFromV21('v22_parity');
      final fresh = await freshDatabase('v22_parity_new');
      expect(await _columnsOf(upgraded.db, 'saved_devices'),
          await _columnsOf(fresh.db, 'saved_devices'));
      expect(await _columnsOf(upgraded.db, 'settings'),
          await _columnsOf(fresh.db, 'settings'));
    });

    test('both report schema version 22', () async {
      final upgraded = await upgradeFromV22Ver();
      final fresh = await freshDatabase('v22_ver_new');
      for (final db in <AppDatabase>[upgraded, fresh]) {
        final v = (await db.db.rawQuery('PRAGMA user_version')).single;
        expect(v['user_version'], Db.schemaVersion);
        // The current EXACT pin, inherited from `schema_v21_test.dart` — which
        // is now a floor. Move it again when v23 lands; the registry in
        // `Db.schemaVersion`'s doc comment is the arbiter, and this line is what
        // makes two branches claiming one number collide here rather than on a
        // user's phone.
        expect(Db.schemaVersion, 22);
      }
    });
  });
}

/// Named so the closure above reads as a sentence; same fixture.
Future<AppDatabase> upgradeFromV22Ver() async {
  final dir = await Directory.systemTemp.createTemp('osb_v22_ver');
  addTearDown(() => dir.delete(recursive: true));
  final path = p.join(dir.path, 'v21.db');
  final legacy = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 21,
      onCreate: (db, _) async {
        for (final stmt in _v21Schema) {
          await db.execute(stmt);
        }
      },
    ),
  );
  await legacy.close();
  final upgraded =
      await AppDatabase.open(path: path, factory: databaseFactoryFfi);
  addTearDown(upgraded.close);
  return upgraded;
}
