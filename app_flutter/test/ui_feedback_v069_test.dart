// v0.6.9 field feedback — capability gating gaps + last-seen semantics.
//
// Two of the five items reported after v0.6.9 were behavioural, and both are
// the kind that reappear the moment someone adds a new surface:
//
//   * design 0007 hid the capacitor's meaningless 0.0 A current on the
//     dashboard, but the SAME data was still shown on the History screen, and
//     the gauge's SOH sub-line rendered "SOH --" forever on a unit that has no
//     SOH register at all. Gating has to hold on every surface, not one.
//   * `last_seen` was stamped only at BleLinkState.ready, so it recorded when
//     we CONNECTED. A unit monitored for six hours reported "last seen 6 hours
//     ago" the instant it dropped.

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/connection_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase appDb;
  setUp(() async {
    appDb = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async => appDb.close());

  group('history rows carry their device (so the UI can gate by class)', () {
    test('querySamplesWithDevice pairs each row with its unit', () async {
      final repo = HistoryRepo(appDb.db);
      await repo.insertSample(
        TelemetrySample(
            timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
            pvlt: 13.7,
            current: 0.0),
        deviceId: 'CAP',
      );
      await repo.insertSample(
        TelemetrySample(
            timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
            pvlt: 12.4,
            current: 1.5),
        deviceId: 'BATT',
      );
      await repo.insertSample(TelemetrySample(
          timestamp: DateTime.fromMillisecondsSinceEpoch(3000), current: 0.0));

      final rows = await repo.querySamplesWithDevice();
      // Newest-first: the unattributed row was inserted with the LATEST
      // timestamp, so it leads — and it keeps a null device rather than being
      // attributed to whichever unit happened to be connected.
      expect(rows.map((r) => r.deviceId), [null, 'BATT', 'CAP']);
      // The reading itself is untouched — the UI decides what to render. The
      // repo must not start editing data on the UI's behalf.
      expect(rows.firstWhere((r) => r.deviceId == 'CAP').sample.current, 0.0);
    });

    test('TelemetrySample still has no device id of its own', () {
      // Guard the boundary the fix was written to respect: attribution belongs
      // to the row, not to the model of what the device reported.
      final map = TelemetrySample(
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        pvlt: 12.0,
      ).toMap();
      expect(map.containsKey('device_id'), isFalse);
    });
  });

  group('last-seen means last ALIVE, not last connected', () {
    test('the throttle interval is coarser than the telemetry rate', () {
      // Telemetry lands at ~5 Hz. Writing every frame would be ~18k DB updates
      // an hour for a field rendered as "x minutes ago".
      expect(ConnectionController.lastSeenInterval,
          greaterThanOrEqualTo(const Duration(seconds: 30)));
      expect(ConnectionController.lastSeenInterval,
          lessThanOrEqualTo(const Duration(minutes: 5)));
    });

    test('touch moves the stored timestamp forward', () async {
      final repo = DeviceRepo(appDb.db);
      await repo.upsertSavedDevice(SavedDevice(
        id: 'AA',
        alias: 'pack',
        name: 'RCE',
        lastSeen: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.touch('AA',
          lastSeen: DateTime.fromMillisecondsSinceEpoch(999000));
      final back = (await repo.getDevice('AA'))!;
      expect(back.lastSeen!.millisecondsSinceEpoch, 999000);
    });
  });
}
