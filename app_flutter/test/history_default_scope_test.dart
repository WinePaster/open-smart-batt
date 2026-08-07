// The History screen's device scope, design 0043.
//
// WHAT CHANGED, AND WHY IT WAS NOT A COSMETIC CHOICE. Design 0022 gave the
// screen a device picker sourced from `saved_devices`, with an "all devices"
// entry that was also the default while offline. Both halves were wrong, and
// they were wrong together:
//
//   * "All devices" is not a view, it is an arithmetic error. The chart and the
//     stats aggregate with no device dimension and no class dimension, so
//     unscoped they average a 3.9 V power bank into a 13.5 V capacitor and draw
//     one line at neither. A field screenshot shows exactly that: min 3.72 V,
//     avg 12.19 V, max 14.26 V, where 12.19 V corresponds to no physical unit
//     that phone had ever been connected to.
//
//   * Sourcing the options from `saved_devices` made "all devices" load-bearing
//     anyway. Saving a device is MANUAL — the naming dialog can be cancelled —
//     and deleting a saved record leaves its history rows behind, so units
//     could hold weeks of data with no option to select them. The escape hatch
//     for that was the very entry that could not be read.
//
// Grouping history against itself dissolves both: every showable row belongs to
// exactly one option, so "all devices" has no job left and can go. That
// equivalence is not obvious, so it is asserted directly below ("every showable
// row is reachable") — if it ever fails, the option has to come back.
//
// The rows carrying no device at all are the remaining loose end. They are old:
// attribution did not exist before 2026-07-27 and only covered `ready` until
// 07-29, and one capture is 29 % such rows. They are NOT deleted (a diagnostic
// app must not destroy a dealer's history on upgrade, and for a single-unit
// owner those rows are perfectly good data) — they leave the SCREEN, stay in
// the database, and stay exportable. Nothing in the app mentions them.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// BleService stub: nothing here reaches the plugin channel.
///
/// [connectedDeviceId] is settable because the write guard's two cases differ
/// only in whether the link can name the unit it is connected to.
class _StubBle extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  String? connected;

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  String? get connectedDeviceId => connected;

  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);
  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

/// The one empty-state sentence the screen ever shows when no unit has rows —
/// quoted once so the "same words whatever the database holds" tests cannot
/// drift apart from each other.
const _noDevices = '尚無裝置紀錄。\n連線並命名裝置後就會開始累積。';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  const cap = 'DEV-CAP';
  const bank = 'DEV-PB';
  final t0 = DateTime.utc(2026, 8, 6, 10);

  // ===================== data layer =====================================

  group('the picker is grouped from history, not from saved devices', () {
    late AppDatabase db;
    late HistoryRepo repo;

    Future<void> add(double pvlt, String? dev, int minute) =>
        repo.insertSample(
          TelemetrySample(
              timestamp: t0.add(Duration(minutes: minute)),
              pvlt: pvlt,
              temperatureC: 30),
          deviceId: dev,
        );

    setUp(() async {
      db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      repo = HistoryRepo(db.db);
      await add(14.2, cap, 0);
      await add(13.8, cap, 1);
      await add(12.9, cap, 2);
      await add(4.1, bank, 3);
      await add(3.8, bank, 4);
      await add(3.7, null, 5); // pre-attribution, power-bank-shaped
      await add(14.0, null, 6); // pre-attribution, capacitor-shaped
    });

    tearDown(() async => db.close());

    test('one entry per unit, counted and dated', () async {
      final groups = await repo.deviceGroups();
      final byId = {for (final g in groups) g.deviceId: g};
      expect(byId.keys.toSet(), {cap, bank});
      expect(byId[cap]!.count, 3);
      expect(byId[bank]!.count, 2);
      // lastAt is what orders the units no saved record can order, and what
      // lets an owner tell two ids for one physical unit apart after an iOS
      // reinstall rotates the NSUUID.
      expect(byId[bank]!.lastAt.millisecondsSinceEpoch,
          t0.add(const Duration(minutes: 4)).millisecondsSinceEpoch);
    });

    test('a unit with no device attribution is not an option', () async {
      // Not an "unattributed" entry, not an empty-string entry: absent. There
      // is no place in this app where those rows are named.
      final groups = await repo.deviceGroups();
      expect(groups.map((g) => g.deviceId), isNot(contains(null)));
      expect(groups, hasLength(2));
    });

    test('🔑 every showable row is reachable from some option', () async {
      // THE CONDITION THAT LICENSED REMOVING "ALL DEVICES". If this sum ever
      // falls short, a row exists that the screen would display and that no
      // option selects — reachable from nowhere. Restore the entry rather than
      // relaxing this.
      final groups = await repo.deviceGroups();
      final sum = groups.fold<int>(0, (a, g) => a + g.count);
      expect(await repo.countAttributed(), sum);
      // And the footer reports that number, not the raw table size, so the
      // screen cannot advertise rows it will not show.
      expect(await repo.countAttributed(), 5);
      expect(await repo.count(), 7);
    });

    test('the option list ignores the time range', () async {
      // A list that shrank with the range would make units blink out when the
      // user switched to "today", which reads as data loss. `deviceGroups`
      // takes no `since` at all — this pins the absence of the parameter as a
      // decision, not an oversight.
      final everything = await repo.deviceGroups();
      final today = await repo.aggregate(
          since: t0.add(const Duration(minutes: 4)), attributedOnly: true);
      expect(today.count, lessThan(everything.fold<int>(0, (a, g) => a + g.count)),
          reason: 'the range really does exclude rows');
      expect((await repo.deviceGroups()).length, everything.length,
          reason: 'yet the picker still offers both units');
    });
  });

  group('the screen\'s three queries all drop unattributed rows', () {
    late AppDatabase db;
    late HistoryRepo repo;

    setUp(() async {
      db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      repo = HistoryRepo(db.db);
      Future<void> add(double pvlt, String? dev, int minute) =>
          repo.insertSample(
            TelemetrySample(
                timestamp: t0.add(Duration(minutes: minute)), pvlt: pvlt),
            deviceId: dev,
          );
      await add(14.2, cap, 0);
      await add(4.1, bank, 1);
      await add(3.7, null, 2);
      await add(14.0, null, 3);
    });

    tearDown(() async => db.close());

    test('the stats strip', () async {
      final s = await repo.aggregate(attributedOnly: true);
      expect(s.count, 2);
    });

    test('the chart', () async {
      final buckets =
          await repo.queryBuckets(bucketMs: 60000, attributedOnly: true);
      expect(buckets.fold<int>(0, (a, b) => a + b.count), 2);
    });

    test('the list', () async {
      final rows = await repo.querySamplesWithDevice(attributedOnly: true);
      expect(rows, hasLength(2));
      expect(rows.every((r) => r.deviceId != null), isTrue);
    });

    test('🔴 but the export still carries them', () async {
      // The one guarantee that makes "do not delete, just hide" honest. If the
      // screen's filter ever leaks into this path, those rows become
      // unreachable for real — and only then would deleting them have been the
      // lesser evil.
      final csv = await repo.exportCsv();
      expect(csv.rows, 4);
    });

    test('a per-device export still declares what it left out', () async {
      final csv = await repo.exportCsv(
        deviceId: cap,
        header: const ['t'],
      );
      expect(csv.text, contains('# excluded: 2 unattributed rows'));
    });
  });

  // ===================== write point ====================================

  group('no new row is written without a device (design 0043 §3.1)', () {
    late AppDatabase db;
    late AppServices services;
    late _StubBle ble;

    setUp(() async {
      db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      ble = _StubBle();
      services = await AppServices.create(appDatabase: db, ble: ble);
    });

    tearDown(() async => services.dispose());

    test('a sample with no attribution is dropped, not stored as NULL',
        () async {
      // The link comes up without being able to name the unit, so the session
      // never begins. Today only a stub can arrange this; once two links can be
      // up at once it stops being hypothetical — one unit disconnecting clears
      // the ambient session while the other is still streaming.
      ble.emitLink(BleLinkState.ready);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      ble.emitTelemetry(TelemetrySample(
          timestamp: DateTime.utc(2026, 8, 6, 12), pvlt: 12.5));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      services.telemetry.flushPendingHistory();
      await services.pending.drain();

      expect(await services.historyRepo.count(), 0,
          reason: 'dropped at the source — never queued, never inserted');
      expect(await services.historyRepo.countUnattributed(), 0);
    });

    test('the same sample IS stored once the session names a unit', () async {
      // The control for the test above: it must be the attribution that
      // decides, not something incidental about the stub.
      ble.connected = 'AA';
      ble.emitLink(BleLinkState.ready);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      ble.emitTelemetry(TelemetrySample(
          timestamp: DateTime.utc(2026, 8, 6, 12), pvlt: 12.5));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      services.telemetry.flushPendingHistory();
      await services.pending.drain();

      final rows = await services.historyRepo.querySamplesWithDevice();
      expect(rows, hasLength(1));
      expect(rows.single.deviceId, 'AA');
    });

    test('no NOT NULL constraint was added to do this job', () async {
      // Deliberate: writes go through a background queue, where a constraint
      // violation surfaces as an exception detached from its cause and able to
      // take unrelated writes with it. The repo must still ACCEPT such a row —
      // the guard belongs at the source, and the schema stays untouched so no
      // migration is needed and no existing row becomes illegal.
      await services.historyRepo.insertSample(
        TelemetrySample(timestamp: DateTime.utc(2026, 8, 6, 13), pvlt: 12.0),
      );
      expect(await services.historyRepo.countUnattributed(), 1);
    });
  });

  // ===================== the screen =====================================

  group('History screen', () {
    late AppServices services;

    /// Real database IO cannot advance under the widget tester's fake clock, so
    /// every database touch in this group runs inside [WidgetTester.runAsync].
    Future<void> boot(WidgetTester tester) async {
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        services = await AppServices.create(appDatabase: db, ble: _StubBle());
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(services.dispose);
      });
    }

    Future<void> seed(WidgetTester tester, Future<void> Function() work) =>
        tester.runAsync(work);

    Future<void> addRow(String? deviceId, DateTime at, double pvlt) =>
        services.historyRepo.insertSample(
          TelemetrySample(timestamp: at, pvlt: pvlt),
          deviceId: deviceId,
        );

    Future<void> pumpHistory(WidgetTester tester) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<AppServices>.value(value: services),
            Provider<BleService>.value(value: services.ble),
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
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            home: const Scaffold(body: HistoryScreen()),
          ),
        ),
      );
      // The screen makes two chained reads — the option list, then the data for
      // whichever unit that list caused to be selected. Both need the real
      // event loop; the pumps afterwards render what they produced.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      await tester.pump();
    }

    testWidgets('offline, it opens on the unit seen most recently', (t) async {
      // Design 0022 opened offline on "all devices" on the grounds of "do not
      // guess" — but the picker itself says which unit is being shown, so there
      // is nothing to mislead anyone about, and the alternative was the
      // unreadable averaged line.
      await boot(t);
      final now = DateTime.now();
      await seed(t, () async {
        await services.devices.save(SavedDevice(
            id: cap,
            alias: 'Capacitor',
            lastSeen: now.subtract(const Duration(days: 2))));
        await services.devices.save(
            SavedDevice(id: bank, alias: 'Power bank', lastSeen: now));
        await addRow(cap, now.subtract(const Duration(minutes: 5)), 13.5);
        await addRow(bank, now.subtract(const Duration(minutes: 4)), 3.9);
      });

      await pumpHistory(t);

      expect(services.telemetry.recordingDeviceId, isNull, reason: 'offline');
      expect(find.text('Power bank'), findsOneWidget);
      expect(find.text('Capacitor'), findsNothing,
          reason: 'the other unit lives in the menu, not on the bar');
    });

    testWidgets('the connected unit wins over the most recently seen one',
        (t) async {
      await boot(t);
      final now = DateTime.now();
      await seed(t, () async {
        await services.devices.save(
            SavedDevice(id: bank, alias: 'Power bank', lastSeen: now));
        await services.devices.save(SavedDevice(
            id: cap,
            alias: 'Capacitor',
            lastSeen: now.subtract(const Duration(days: 2))));
        await addRow(cap, now.subtract(const Duration(minutes: 5)), 13.5);
        await addRow(bank, now.subtract(const Duration(minutes: 4)), 3.9);
      });

      services.connection.session.begin(cap);
      await pumpHistory(t);

      expect(find.text('Capacitor'), findsOneWidget);
    });

    testWidgets('🔴 the default is chosen after the options load, not before',
        (t) async {
      // THE REGRESSION LOCK. The seed used to run once, in
      // didChangeDependencies, and give up for good if it found nothing. With
      // the options now behind a database read, a seed on the first frame would
      // find an empty list, select nothing and never retry — a blank screen
      // with no way back. Nothing is connected and no device is saved here, so
      // ONLY a seed that waited for the query can produce a selection.
      await boot(t);
      await seed(t, () async {
        await addRow(
            cap, DateTime.now().subtract(const Duration(minutes: 5)), 13.5);
      });

      await pumpHistory(t);

      expect(find.text(shortDeviceHash(cap)), findsOneWidget);
      expect(find.text(_noDevices), findsNothing);
    });

    testWidgets('a unit whose saved record was deleted keeps its option',
        (t) async {
      // The failure design 0022 accepted: delete the saved record and the rows
      // stayed in the table with no way to select them. A short hash is not
      // pretty; being unable to reach a month of data is worse.
      await boot(t);
      final now = DateTime.now();
      await seed(t, () async {
        await services.devices.save(
            SavedDevice(id: cap, alias: 'Capacitor', lastSeen: now));
        await addRow(cap, now.subtract(const Duration(minutes: 5)), 13.5);
        await services.devices.remove(cap);
      });

      await pumpHistory(t);

      expect(find.text(shortDeviceHash(cap)), findsOneWidget);
    });

    testWidgets('a saved unit with no rows is NOT offered', (t) async {
      // The mirror-image failure of the same choice of source: an option that
      // is guaranteed to show an empty chart when tapped.
      await boot(t);
      final now = DateTime.now();
      await seed(t, () async {
        await services.devices.save(
            SavedDevice(id: cap, alias: 'Capacitor', lastSeen: now));
        await services.devices.save(SavedDevice(
            id: bank,
            alias: 'Never recorded',
            lastSeen: now.subtract(const Duration(days: 1))));
        await addRow(cap, now.subtract(const Duration(minutes: 5)), 13.5);
      });

      await pumpHistory(t);

      expect(find.text('Capacitor'), findsOneWidget);
      expect(find.text('Never recorded'), findsNothing);
    });

    testWidgets('there is no "all devices" option left', (t) async {
      await boot(t);
      final now = DateTime.now();
      await seed(t, () async {
        await services.devices.save(
            SavedDevice(id: cap, alias: 'Capacitor', lastSeen: now));
        await services.devices.save(SavedDevice(
            id: bank,
            alias: 'Power bank',
            lastSeen: now.subtract(const Duration(days: 1))));
        await addRow(cap, now.subtract(const Duration(minutes: 5)), 13.5);
        await addRow(bank, now.subtract(const Duration(minutes: 4)), 3.9);
      });

      await pumpHistory(t);
      // Open the menu: the entry has to be absent from the options themselves,
      // not merely unselected.
      await t.tap(find.byType(DropdownButton<String>));
      await t.pumpAndSettle();
      expect(find.text('全部裝置'), findsNothing);
      expect(find.text('Power bank'), findsWidgets,
          reason: 'the menu did open — otherwise this proves nothing');
    });

    testWidgets('the picker shows even with a single unit', (t) async {
      // It stopped being a switcher: with the view permanently scoped, the bar
      // is how the screen says WHOSE numbers these are, and one unit needs that
      // sentence as much as two do.
      await boot(t);
      final now = DateTime.now();
      await seed(t, () async {
        await services.devices.save(
            SavedDevice(id: cap, alias: 'Capacitor', lastSeen: now));
        await addRow(cap, now.subtract(const Duration(minutes: 5)), 13.5);
      });

      await pumpHistory(t);

      expect(find.byType(DropdownButton<String>), findsOneWidget);
      expect(find.text('Capacitor'), findsOneWidget);
    });

    testWidgets('nothing recorded at all → "no devices"', (t) async {
      await boot(t);
      await pumpHistory(t);
      expect(find.text(_noDevices), findsOneWidget);
      expect(find.byType(DropdownButton<String>), findsNothing);
    });

    testWidgets('🔴 export is reachable in the EMPTY state too', (t) async {
      // 2026-08-07: the two actions were reported as「太擠」on the toolbar line
      // and moved, by owner ruling, to the boundary between the chart and the
      // list.
      //
      // That boundary only exists in one of the FutureBuilder's four branches.
      // Putting them only there would remove export from the empty state —
      // and the owner whose entire history predates attribution sees exactly
      // that state while still having rows worth exporting (see this file's
      // header). The action row is therefore rendered in every branch, and
      // this is the test that says so.
      await boot(t);
      await pumpHistory(t);
      expect(find.text(_noDevices), findsOneWidget,
          reason: 'sanity: this is the empty state');
      expect(find.text('匯出 CSV'), findsOneWidget);
      expect(find.text('警告'), findsOneWidget);
    });

    testWidgets('and exactly once when there is data', (t) async {
      // Two would mean two branches are drawing it at the same time.
      await boot(t);
      await seed(t, () async {
        await addRow('A', DateTime.now().subtract(const Duration(minutes: 5)),
            12.6);
      });
      await pumpHistory(t);
      expect(find.byType(DropdownButton<String>), findsOneWidget);
      expect(find.text('匯出 CSV'), findsOneWidget);
      expect(find.text('警告'), findsOneWidget);
    });

    testWidgets(
        '🔴 and the SAME sentence when the table holds only pre-attribution '
        'rows', (t) async {
      // A real owner: installed before 2026-07-27, upgraded, has not
      // reconnected since. Every row he has carries no device, so his entire
      // history leaves the screen and he is told only "no device records yet".
      // The owner ruled on 2026-08-06 that no extra note is written for this.
      // Pinned here so the decision is visible rather than looking like an
      // oversight — his rows are still in the database and still export.
      await boot(t);
      final now = DateTime.now();
      await seed(t, () async {
        await addRow(null, now.subtract(const Duration(minutes: 5)), 13.5);
        await addRow(null, now.subtract(const Duration(minutes: 4)), 13.4);
      });

      await pumpHistory(t);

      expect(find.text(_noDevices), findsOneWidget);
      expect(find.textContaining('未顯示'), findsNothing,
          reason: 'the 0022 hidden-rows note must be gone');
      await seed(t, () async {
        expect(await services.historyRepo.count(), 2,
            reason: 'hidden from the screen, still on disk');
      });
    });

    testWidgets('an empty range says whose range it is', (t) async {
      // "No records today" was true of the table and false of the view: this
      // unit has none, another may have plenty.
      await boot(t);
      await seed(t, () async {
        await services.devices.save(SavedDevice(
            id: cap, alias: 'Capacitor', lastSeen: DateTime.now()));
        await addRow(
            cap, DateTime.now().subtract(const Duration(days: 30)), 13.5);
      });

      await pumpHistory(t);

      expect(find.text('這台裝置在此範圍內沒有紀錄。'), findsOneWidget);
    });
  });
}
