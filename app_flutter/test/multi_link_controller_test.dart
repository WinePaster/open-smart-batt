// design 0103 — the multi-link experiment's controller, exercised by injection
// (the compile-time flag is off in `flutter test`; `AppServices.create` takes
// `multiLinkBuild: true` and a factory for the secondary BleService fakes).
//
// What is pinned here, by ruling:
//   D6  at most 3 links, primary included; power banks / demo ids never adopted
//   —   hand-off: a secondary is released BEFORE the primary connects to it
//   D1  power bank as primary ⇒ the others pause, and resume when it is gone
//   D5  slow-writer demotion: ≥ 500 ms with ≥ 2 links; never with one;
//       third demotion leaves the unit out; never while the primary is just
//       as slow (2026.11.16/006)
//   D7  notification line counts every live link
//   D2  prompt only for a power bank, only while other links are live
//   §3.6 / FB-41  two links interleaving samples never cross-attribute
//   004 only units seen nearby (scan or live link) take a slot; an absent held
//       unit gives its slot back after the presence window
//   2026.11.19/004  secondaries alone (no primary) are "connected" for the
//       status pill and the screen wakelock, like the monitor already was
//   2026.11.19/007  nobody is adopted until a presence scan has run its
//       window (a connect stops the scan)
import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/config/app_config.dart';
import 'package:open_smart_batt/config/multi_link_config.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/main.dart' show connectionPillPresentation;
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/accent_theme.dart';
import 'package:open_smart_batt/theme/app_theme.dart' show AppSemantics;
import 'package:open_smart_batt/ui/util/export_header.dart';
import 'package:open_smart_batt/ui/util/report_bundle.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_settle.dart';

/// The primary link: driven by hand, never touches a radio.
class _FakePrimary extends BleService {
  _FakePrimary({this.adapterOn = false, this.lateAdapter = false});

  final bool adapterOn;

  /// 2026.11.20/004: the radio reports nothing until [emitAdapter] — iOS at a
  /// cold start, where the state is `unknown` for a moment.
  final bool lateAdapter;
  final _adapterOut = StreamController<BluetoothAdapterState>.broadcast();
  void emitAdapter(BluetoothAdapterState s) => _adapterOut.add(s);
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _teleOut = StreamController<TelemetrySample>.broadcast();
  final _scanOut = StreamController<List<DiscoveredDevice>>.broadcast();
  String? connectedId;

  /// The primary's own D5 window mean (2026.11.16/006 phone-slow guard).
  int? avg;
  @override
  int? get recentWriteAvgMs => avg;

  /// What a scan finds: [startScan] reports exactly these ids.
  Set<String> nearby = <String>{};
  int scans = 0;

  @override
  String? get connectedDeviceId => connectedId;
  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<TelemetrySample> get telemetry => _teleOut.stream;
  @override
  Stream<BluetoothAdapterState> get adapterState => lateAdapter
      ? _adapterOut.stream
      : adapterOn
          ? Stream<BluetoothAdapterState>.value(BluetoothAdapterState.on)
          : const Stream<BluetoothAdapterState>.empty();
  final _scanningOut = StreamController<bool>.broadcast();
  @override
  Stream<bool> get scanning => _scanningOut.stream;
  @override
  bool get isScanning => false;
  @override
  Stream<List<DiscoveredDevice>> get scanResults => _scanOut.stream;

  /// Opt-in (2026.11.19/007): a scan that reports `scanning` true, delivers
  /// [nearby] at once, and stays open until [finishScan] — the real radio's
  /// shape. Off, a scan is the instantaneous list the older tests assume.
  bool realisticScan = false;

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)}) async {
    scans++;
    if (realisticScan) _scanningOut.add(true);
    emitScan(nearby);
  }

  void finishScan() => _scanningOut.add(false);

  void emitLink(BleLinkState s) => _linkOut.add(s);

  /// Opt-in: make [disconnect] behave like the real service's teardown order
  /// — `disconnecting`, then the handle is cleared (so `connectedDeviceId`
  /// already reads null), then [inTeardownWindow] runs, and only after that
  /// does the `disconnected` state reach listeners. 2026.11.13/016.
  bool realisticDisconnect = false;
  Future<void> Function()? inTeardownWindow;

  /// design 0106 Phase 3: what the PRIMARY was asked to connect (the personal
  /// group's power bank goes through here). Off unless a test opts in.
  bool acceptConnects = false;
  final List<String> primaryConnects = <String>[];

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    primaryConnects.add(deviceId);
    if (!acceptConnects) return;
    connectedId = deviceId;
    emitLink(BleLinkState.connecting);
    emitLink(BleLinkState.ready);
  }

  @override
  Future<void> disconnect() async {
    if (!realisticDisconnect || connectedId == null) return;
    emitLink(BleLinkState.disconnecting);
    await Future<void>.delayed(Duration.zero);
    connectedId = null;
    await inTeardownWindow?.call();
    emitLink(BleLinkState.disconnected);
  }

  void emitScan(Iterable<String> ids) => _scanOut.add([
        for (final id in ids) DiscoveredDevice(id: id, name: id, rssi: -60),
      ]);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _teleOut.close();
    await _scanOut.close();
    await _scanningOut.close();
    await super.dispose();
  }
}

/// One secondary link. Records what the controller asked of it.
class _FakeSecondary extends BleService {
  _FakeSecondary(this.log, this.all) {
    all.add(this);
  }

  final List<String> log;
  final List<_FakeSecondary> all;
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _teleOut = StreamController<TelemetrySample>.broadcast();
  final _pktOut = StreamController<BlePacketEvent>.broadcast();
  final _diagOut = StreamController<String>.broadcast();

  String? id;
  bool paused = false;
  int? avg;
  int resets = 0;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<TelemetrySample> get telemetry => _teleOut.stream;
  @override
  Stream<BlePacketEvent> get packets => _pktOut.stream;
  @override
  Stream<String> get diagnostics => _diagOut.stream;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    id = deviceId;
    log.add('connect $deviceId');
    _linkOut.add(BleLinkState.connecting);
    _linkOut.add(BleLinkState.ready);
  }

  @override
  Future<void> disconnect() async {
    log.add('disconnect $id');
    _linkOut.add(BleLinkState.disconnected);
  }

  @override
  bool pausePolling({required String reason}) {
    if (paused) return false;
    paused = true;
    log.add('pause $id $reason');
    return true;
  }

  @override
  void resumePolling() {
    if (!paused) return;
    paused = false;
    log.add('resume $id');
  }

  @override
  int? get recentWriteAvgMs => avg;

  @override
  void resetWriteWindow() => resets++;

  void sample(TelemetrySample s) => _teleOut.add(s.copyWith(deviceId: id));

  /// The unit went out of range on its own (no `disconnect` asked for).
  void drop() => _linkOut.add(BleLinkState.disconnected);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _teleOut.close();
    await _pktOut.close();
    await _diagOut.close();
    await super.dispose();
  }
}

/// The services the running test built; [_settle] waits on their database.
AppServices? _settleTarget;

/// Database work done (support/db_settle.dart `settleServices`), not a fixed
/// 20 ms sleep — root repo docs/knowledges/flutter-test-db-timing.md (the
/// personal-group test lost it on CI run 44104916877).
Future<void> _settle() async {
  final s = _settleTarget;
  if (s == null) {
    await Future<void>.delayed(Duration.zero);
    return;
  }
  await settleServices(s);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late Directory markers;
  late _FakePrimary primary;
  late List<String> log;
  late List<_FakeSecondary> secondaries;
  late AppServices s;
  late DateTime now;

  _FakeSecondary sec(String id) => secondaries.lastWhere((b) => b.id == id);

  /// [nearby] is what a scan has already found before the switch turns on;
  /// null means every saved unit, which is what the tests written before
  /// 2026.11.12/004 assume.
  Future<MultiLinkController> boot(List<SavedDevice> devices,
      {bool enable = true,
      String? primaryId,
      Set<String>? nearby,
      bool adapterOn = false,
      bool autoReconnect = true}) async {
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    primary = _FakePrimary(adapterOn: adapterOn);
    s = await AppServices.create(
      appDatabase: db,
      ble: primary,
      multiLinkBuild: true,
      multiLinkBleFactory: () => _FakeSecondary(log, secondaries),
      multiLinkClock: () => now,
    );
    _settleTarget = s;
    for (final d in devices) {
      await s.devices.save(d);
    }
    final seen = nearby ?? {for (final d in devices) d.id};
    if (seen.isNotEmpty) {
      primary.emitScan(seen);
      await _settle();
    }
    await s.settings.setRawPacketLog(true);
    if (!autoReconnect) await s.settings.setAutoReconnect(false);
    if (primaryId != null) {
      primary.connectedId = primaryId;
      primary.emitLink(BleLinkState.ready);
      await _settle();
    }
    final ml = s.multiLink!;
    if (enable) await ml.setEnabled(true);
    await _settle();
    return ml;
  }

  setUp(() {
    markers = Directory.systemTemp.createTempSync('osb_ml');
    AckMarker.debugDirectoryOverride = markers;
    log = <String>[];
    secondaries = <_FakeSecondary>[];
    now = DateTime(2026, 11, 13, 12);
  });

  tearDown(() async {
    _settleTarget = null;
    await s.pending.drain();
    await s.dispose();
    AckMarker.debugDirectoryOverride = null;
    markers.deleteSync(recursive: true);
  });

  SavedDevice bat(String id) =>
      SavedDevice(id: id, alias: id, productClass: ProductClass.smartBattery);
  SavedDevice pb(String id) =>
      SavedDevice(id: id, alias: id, productClass: ProductClass.powerBank);

  test('D6: at most 3 links; power banks and demo units are never adopted',
      () async {
    final ml = await boot([
      bat('A'),
      pb('PB'),
      bat('B'),
      const SavedDevice(id: 'demo:battery', alias: 'demo'),
      bat('C'),
      bat('D'),
    ]);
    expect(ml.heldIds, {'A', 'B', 'C'});
    expect(ml.onlineIds, {'A', 'B', 'C'});
    expect(s.connection.isOnlineFor('B'), isTrue);
    expect(s.connection.isOnlineFor('D'), isFalse);
    expect(s.connection.isOnlineFor('PB'), isFalse);
  });

  test('D6: a primary link takes one slot of the three', () async {
    final ml =
        await boot([bat('A'), bat('B'), bat('C'), bat('D')], primaryId: 'A');
    expect(ml.heldIds, {'B', 'C'});
    expect(s.connection.isOnlineFor('A'), isTrue, reason: 'primary');
    expect(ml.isOnlineFor('A'), isFalse, reason: 'never also a secondary');
  });

  test('hand-off: a secondary is released before the primary connects to it',
      () async {
    final ml = await boot([bat('A'), bat('B')]);
    expect(ml.heldIds, {'A', 'B'});
    await ml.beforePrimaryConnect('B');
    expect(log, contains('disconnect B'));
    expect(ml.heldIds.contains('B'), isFalse);
  });

  // 2026.11.12/001: the primary still names the OLD unit while it tears that
  // one down, and a reconcile in that window used to adopt the target again —
  // a second Dart link on the one physical connection, whose release then
  // cancelled the primary's fresh connection (4 of 4 taps, 3.8–5.0 s each).
  test('hand-off: the target is not re-adopted while the primary still names '
      'the old unit', () async {
    final ml = await boot([bat('A'), bat('B')], primaryId: 'A');
    expect(ml.heldIds, {'B'});
    await ml.beforePrimaryConnect('B');
    // The primary starts dropping A; it has not named B yet.
    primary.emitLink(BleLinkState.disconnecting);
    await _settle();
    expect(ml.heldIds.contains('B'), isFalse,
        reason: 'the target belongs to the primary from beforePrimaryConnect');
    expect(log.where((e) => e == 'connect B'), hasLength(1),
        reason: 'only the original secondary ever connected to B');
    // The primary lands on B: A becomes the secondary, B stays out.
    primary.connectedId = 'B';
    primary.emitLink(BleLinkState.ready);
    await _settle();
    expect(ml.heldIds, {'A'});
    expect(log.where((e) => e == 'connect B'), hasLength(1));
  });

  test('hand-off: once landed, a later hand-off back makes the old target a '
      'candidate again', () async {
    final ml = await boot([bat('A'), bat('B')], primaryId: 'A');
    await ml.beforePrimaryConnect('B');
    primary.connectedId = 'B';
    primary.emitLink(BleLinkState.ready);
    await _settle();
    expect(ml.heldIds, {'A'});
    await ml.beforePrimaryConnect('A');
    primary.connectedId = 'A';
    primary.emitLink(BleLinkState.ready);
    await _settle();
    expect(ml.heldIds, {'B'}, reason: 'B is no longer the hand-off target');
  });

  test('D1: a power bank as primary pauses the others; they resume after',
      () async {
    final ml = await boot([bat('A'), bat('B'), pb('PB')]);
    await ml.beforePrimaryConnect('PB');
    expect(log, containsAll(['pause A power-bank', 'pause B power-bank']));
    primary.connectedId = 'PB';
    primary.emitLink(BleLinkState.ready);
    await _settle();
    expect(ml.heldIds, {'A', 'B'}, reason: 'paused, not dropped');
    // Leaving the page disconnects the power bank (D1) …
    primary.connectedId = null;
    primary.emitLink(BleLinkState.disconnected);
    await _settle();
    expect(log, containsAll(['resume A', 'resume B']));
    expect(sec('A').paused, isFalse);
  });

  test('D1: no new links while a power bank holds the primary', () async {
    final ml = await boot([bat('A'), pb('PB')]);
    await ml.beforePrimaryConnect('PB');
    primary.connectedId = 'PB';
    primary.emitLink(BleLinkState.ready);
    await _settle();
    await s.devices.save(bat('B'));
    await _settle();
    expect(ml.heldIds, {'A'});
  });

  test('D5: a slow writer is demoted when another link is online', () async {
    final ml = await boot([bat('A'), bat('B')]);
    sec('A').avg = 600;
    sec('B').avg = 120;
    ml.checkDemotions();
    expect(log, contains('pause A slow-writer'));
    expect(log.where((l) => l.startsWith('pause B')), isEmpty);
    expect(ml.isPausedFor('A'), isTrue);
    await s.pending.drain();
    final events = await s.logRepo.queryLog();
    expect(
        events.any((e) =>
            (e.note ?? '').startsWith('link demoted') && e.deviceId == 'A'),
        isTrue);
  });

  group('2026.11.16/006: a slow phone is not a slow unit', () {
    Future<List<String>> skipNotes() async {
      await s.pending.drain();
      final events = await s.logRepo.queryLog();
      return [
        for (final e in events)
          if ((e.note ?? '').startsWith('link demote skipped')) e.note!,
      ];
    }

    test('the primary just as slow ⇒ nobody is demoted, logged once',
        () async {
      final ml = await boot([bat('P'), bat('A')], primaryId: 'P');
      primary.avg = 900;
      sec('A').avg = 600;
      ml.checkDemotions();
      ml.checkDemotions();
      expect(log.where((l) => l.contains('slow-writer')), isEmpty);
      expect(ml.isPausedFor('A'), isFalse);
      final notes = await skipNotes();
      expect(notes, hasLength(1), reason: 'deduped across evaluations');
      expect(notes.single, contains('reason=phone-slow'));
      expect(notes.single, contains('primaryAvg=900'));
    });

    test('the primary fast ⇒ the slow secondary is still demoted', () async {
      final ml = await boot([bat('P'), bat('A')], primaryId: 'P');
      primary.avg = 120;
      sec('A').avg = 600;
      ml.checkDemotions();
      expect(log, contains('pause A slow-writer'));
      expect(await skipNotes(), isEmpty);
    });

    test('the primary window not full yet ⇒ the 0103 rule as before',
        () async {
      final ml = await boot([bat('P'), bat('A')], primaryId: 'P');
      primary.avg = null;
      sec('A').avg = 600;
      ml.checkDemotions();
      expect(log, contains('pause A slow-writer'));
    });

    test('the switch turns the primary\'s window on, and off again', () async {
      final ml = await boot([bat('P'), bat('A')], primaryId: 'P');
      expect(primary.trackWriteWindow, isTrue);
      await ml.setEnabled(false);
      expect(primary.trackWriteWindow, isFalse);
    });
  });

  test('D5 ⑥: never demoted when it is the only link online', () async {
    final ml = await boot([bat('A')]);
    sec('A').avg = 900;
    ml.checkDemotions();
    expect(log.where((l) => l.contains('slow-writer')), isEmpty);
  });

  test('D5: below 500 ms or before the window fills, nothing happens',
      () async {
    final ml = await boot([bat('A'), bat('B')]);
    sec('A').avg = 499;
    sec('B').avg = null;
    ml.checkDemotions();
    expect(log.where((l) => l.contains('slow-writer')), isEmpty);
  });

  test('D5 ⑤: the third demotion leaves the unit out for the session',
      () async {
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    primary = _FakePrimary();
    s = await AppServices.create(
      appDatabase: db,
      ble: primary,
      multiLinkBuild: true,
      multiLinkBleFactory: () => _FakeSecondary(log, secondaries),
    );
    _settleTarget = s;
    await s.devices.save(bat('A'));
    await s.devices.save(bat('B'));
    // A short retry so three rounds fit in a test.
    final ml = MultiLinkController(
      clock: () => now,
      connection: s.connection,
      devices: s.devices,
      telemetry: s.telemetry,
      settings: s.settings,
      bleFactory: () => _FakeSecondary(log, secondaries),
      demoteRetryAfter: const Duration(milliseconds: 10),
    );
    // Seen by a scan (2026.11.12/004: only units in range are adopted).
    primary.emitScan({'A', 'B'});
    await _settle();
    await ml.setEnabled(true);
    await _settle();
    for (var round = 1; round <= 3; round++) {
      sec('A').avg = 700;
      ml.checkDemotions();
      // Not the database: the controller's own 10 ms retry timer has to run.
      // A timer due later than it fires after it (Dart orders timers by
      // deadline), so this does not depend on machine speed.
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    expect(ml.heldIds.contains('A'), isFalse);
    expect(log, contains('disconnect A'));
    expect(sec('A').resets, 2, reason: 'window reset on each retry');
    ml.dispose();
  });

  test('§3.6 / FB-41: two links interleaving samples never cross-attribute',
      () async {
    final ml = await boot([bat('A'), bat('B')]);
    expect(ml.onlineIds, {'A', 'B'});
    final t0 = DateTime(2026, 11, 11, 12);
    for (var i = 0; i < 6; i++) {
      final t = t0.add(Duration(seconds: i));
      sec('A').sample(TelemetrySample(timestamp: t, pvlt: 13.1));
      sec('B').sample(TelemetrySample(timestamp: t, pvlt: 12.2));
    }
    await _settle();
    s.telemetry.flushPendingHistory();
    await s.pending.drain();
    final a = await s.historyRepo.querySamples(deviceId: 'A');
    final b = await s.historyRepo.querySamples(deviceId: 'B');
    expect(a, isNotEmpty);
    expect(b, isNotEmpty);
    expect(a.every((r) => r.pvlt == 13.1), isTrue, reason: 'A holds only A');
    expect(b.every((r) => r.pvlt == 12.2), isTrue, reason: 'B holds only B');
    // And the cards read the right link.
    expect(ml.telemetryFor('A')!.pvlt, 13.1);
    expect(ml.telemetryFor('B')!.pvlt, 12.2);
  });

  test('a unit that turns out to be a power bank is let go', () async {
    final ml = await boot([bat('A'), bat('B')]);
    sec('A').sample(TelemetrySample(timestamp: DateTime.now(), deviceType: 0x22));
    await _settle();
    expect(ml.heldIds.contains('A'), isFalse);
  });

  test('D7: the reading line counts every live link, primary included',
      () async {
    final ml = await boot([bat('P'), bat('A'), bat('B')], primaryId: 'P');
    ml.setBodyFormat((n, r) => '監看中 $n 台 · $r');
    final body =
        ml.notificationBody(TelemetrySample(timestamp: DateTime.now(), pvlt: 12.5));
    expect(body, startsWith('監看中 3 台 · 12.50 V'));
  });

  test('D7: no secondary up ⇒ the primary keeps its own line', () async {
    final ml = await boot([bat('A')], enable: false);
    expect(ml.notificationBody(TelemetrySample(timestamp: DateTime.now())),
        isNull);
  });

  test('D2: prompt only for a power bank, only while other links are live',
      () async {
    final ml = await boot([bat('A'), pb('PB')]);
    expect(ml.shouldPromptForPowerBank('PB'), isTrue);
    expect(ml.shouldPromptForPowerBank('A'), isFalse);
    await ml.skipPowerBankPromptFromNowOn();
    expect(ml.shouldPromptForPowerBank('PB'), isFalse);
  });

  test('D2 / G4: a lone power bank gets no prompt', () async {
    final ml = await boot([pb('PB')]);
    expect(ml.shouldPromptForPowerBank('PB'), isFalse);
  });

  group('2026.11.19/004: secondaries alone count as connected', () {
    test('two secondaries, no primary: pill CONNECTED, screen held on',
        () async {
      final ml = await boot([bat('A'), bat('B')]);
      final conn = s.connection;
      expect(ml.onlineIds, {'A', 'B'});
      expect(conn.linkState, BleLinkState.disconnected);
      expect(conn.isOnline, isFalse, reason: 'isOnline is the primary alone');
      expect(conn.isAnyOnline, isTrue);
      final (_, color, label) = connectionPillPresentation(conn);
      expect(label, 'CONNECTED');
      expect(color, AppSemantics.good);

      expect(conn.keepsScreenAwake, isFalse, reason: 'setting off by default');
      await s.settings.setKeepScreenAwake(true);
      expect(conn.keepsScreenAwake, isTrue);
    });

    test('the pill hears the edge, not every sample; OFFLINE once all drop',
        () async {
      await boot([bat('A')], enable: false);
      final conn = s.connection;
      final ml = s.multiLink!;
      var notified = 0;
      conn.addListener(() => notified++);

      await ml.setEnabled(true);
      await _settle();
      expect(conn.isAnyOnline, isTrue);
      expect(notified, greaterThan(0), reason: 'none → some is an edge');

      notified = 0;
      for (var i = 0; i < 5; i++) {
        sec('A').sample(TelemetrySample(timestamp: now, pvlt: 12.8));
      }
      await _settle();
      expect(notified, 0, reason: 'samples are not edges');

      await s.settings.setAutoReconnect(false);
      sec('A').drop();
      await _settle();
      expect(conn.isAnyOnline, isFalse);
      expect(notified, greaterThan(0), reason: 'some → none is an edge');
      expect(connectionPillPresentation(conn).$3, 'OFFLINE');
    });

    test('no multi-link: unchanged — the primary alone decides', () async {
      await boot([bat('A')], enable: false);
      final conn = s.connection;
      expect(conn.isAnyOnline, isFalse);
      expect(connectionPillPresentation(conn).$3, 'OFFLINE');
      primary.connectedId = 'A';
      primary.emitLink(BleLinkState.ready);
      await _settle();
      expect(conn.isAnyOnline, isTrue);
      expect(connectionPillPresentation(conn).$3, 'CONNECTED');
    });
  });

  test('switch off releases every secondary; the switch persists', () async {
    final ml = await boot([bat('A'), bat('B')]);
    await ml.setEnabled(false);
    await _settle();
    expect(ml.heldIds, isEmpty);
    expect(log, containsAll(['disconnect A', 'disconnect B']));
    expect(File('${markers.path}/multilink_experiment_on').existsSync(), isFalse);
    await ml.setEnabled(true);
    expect(File('${markers.path}/multilink_experiment_on').existsSync(), isTrue);
  });

  test('a user-disconnected primary is not adopted behind their back',
      () async {
    final ml = await boot([bat('A'), bat('B')], primaryId: 'A');
    primary.connectedId = null;
    primary.emitLink(BleLinkState.disconnected);
    await _settle();
    expect(ml.heldIds, {'B'});
  });

  // 2026.11.13/016: on Android a user disconnect was followed 10 ms later by
  // the same unit coming back as a secondary. `_released` is written only by
  // the primary-changed listener; these drive the real `disconnect()` and let
  // a reconcile land between "the handle is gone" and "the state event
  // arrives".
  group('016: a user disconnect stays a disconnect', () {
    Future<MultiLinkController> bootReal() async {
      final ml = await boot([bat('A'), bat('B')], primaryId: 'A');
      primary.realisticDisconnect = true;
      expect(ml.heldIds, {'B'});
      return ml;
    }

    test('plain disconnect', () async {
      final ml = await bootReal();
      await s.connection.disconnect();
      await _settle();
      expect(ml.heldIds, {'B'});
      expect(log, isNot(contains('connect A')));
    });

    test('a presence tick lands in the teardown window', () async {
      final ml = await bootReal();
      primary.inTeardownWindow = () async => ml.presenceTick();
      await s.connection.disconnect();
      await _settle();
      expect(ml.heldIds, {'B'});
      expect(log, isNot(contains('connect A')));
    });

    test('a saved-device update lands in the teardown window', () async {
      final ml = await bootReal();
      primary.inTeardownWindow = () => s.devices.touch('A', lastSeen: now);
      await s.connection.disconnect();
      await _settle();
      expect(ml.heldIds, {'B'});
      expect(log, isNot(contains('connect A')));
    });

    test('a scan result lands in the teardown window', () async {
      final ml = await bootReal();
      primary.inTeardownWindow = () async {
        primary.emitScan({'A', 'B'});
        await _settle();
      };
      await s.connection.disconnect();
      await _settle();
      expect(ml.heldIds, {'B'});
      expect(log, isNot(contains('connect A')));
    });
  });

  // design 0106 Phase 3 — the owner's example: car A = a + b, car B = c + d,
  // the personal group = power bank e. All five in range unless a test says
  // otherwise.
  group('0106: auto-connect by vehicle', () {
    late VehicleController vehicles;
    late String carA;
    late String carB;

    Future<MultiLinkController> bootCars(
        {Set<String>? nearby, bool autoReconnect = true}) async {
      final ml = await boot(
          [bat('a'), bat('b'), bat('c'), bat('d'), pb('e')],
          nearby: nearby,
          adapterOn: true,
          autoReconnect: autoReconnect);
      primary.realisticDisconnect = true;
      primary.acceptConnects = true;
      vehicles = s.vehicles;
      carA = (await vehicles.createCar('A')).id;
      await vehicles.setDevices(carA, ['a', 'b']);
      carB = (await vehicles.createCar('B')).id;
      await vehicles.setDevices(carB, ['c', 'd']);
      await vehicles.setDevices(VehicleRepo.personalId, ['e']);
      await _settle();
      return ml;
    }

    Future<List<String>> notes() async {
      await s.pending.drain();
      return [for (final e in await s.logRepo.queryLog()) e.note ?? ''];
    }

    test('the first car becomes current; only its units are connected',
        () async {
      final ml = await bootCars();
      expect(vehicles.current?.id, carA);
      // Before the first car existed the 0103 rule had taken a, b, c; the
      // car let c go and never touches d.
      expect(ml.heldIds, {'a', 'b'});
      expect(log, contains('disconnect c'));
      expect(log, isNot(contains('connect d')));
    });

    test('A → B: a and b released as vehicle-switch, c and d connected',
        () async {
      final ml = await bootCars();
      await vehicles.select(carB, source: 'home');
      await _settle();
      expect(ml.heldIds, {'c', 'd'});
      expect(log, containsAll(['disconnect a', 'disconnect b']));
      final n = await notes();
      for (final id in ['a', 'b']) {
        expect(
            n.contains('multilink: release id=${shortDeviceHash(id)} '
                'reason=vehicle-switch'),
            isTrue,
            reason: id);
      }
      // design 0106 Phase 5: where the switch came from.
      expect(n, contains('vehicle: switch car1→car2 source=home'));
    });

    // design 0106 Phase 5: the export header's `vehicle:` value.
    test('Phase 5: vehicle header names the group by position, never by name',
        () async {
      final ml = await bootCars();
      await vehicles.rename(carA, 'ABC-1234');
      await _settle();
      expect(ml.vehicleHeaderValue, 'current=car1/2 devices=2');
      await vehicles.select(VehicleRepo.personalId);
      await _settle();
      expect(ml.vehicleHeaderValue, 'current=personal/2 devices=1');
      expect(ml.vehicleHeaderValue, isNot(contains('ABC')));
      await ml.setEnabled(false);
      await _settle();
      expect(ml.vehicleHeaderValue, isNull, reason: 'no line while off');
    });

    test('personal: every secondary goes, e connects as the PRIMARY', () async {
      final ml = await bootCars();
      await vehicles.select(VehicleRepo.personalId);
      await _settle();
      expect(ml.heldIds, isEmpty);
      expect(primary.primaryConnects, ['e']);
      expect(s.connection.connectedDeviceId, 'e');
      expect(vehicles.personal?.lastPowerBankId, 'e',
          reason: 'PQ2: the one connected becomes the default');
    });

    test('personal → A: e let go (not as the user\'s release), a and b back',
        () async {
      final ml = await bootCars();
      await vehicles.select(VehicleRepo.personalId);
      await _settle();
      await vehicles.select(carA);
      await _settle();
      expect(s.connection.connectedDeviceId, isNull);
      expect(ml.heldIds, {'a', 'b'});
      // Back to personal: e must be connectable again — it was never put in
      // `_released` by the switch.
      primary.primaryConnects.clear();
      await vehicles.select(VehicleRepo.personalId);
      await _settle();
      expect(primary.primaryConnects, ['e']);
    });

    test('Q3: A selected but a, b absent ⇒ nothing connected, still A',
        () async {
      final ml = await bootCars(nearby: {'c', 'd', 'e'});
      expect(vehicles.current?.id, carA);
      expect(ml.heldIds, isEmpty);
      ml.presenceTick();
      await _settle();
      expect(ml.heldIds, isEmpty);
      expect(vehicles.current?.id, carA, reason: 'no switching behind the back');
    });

    test('2026.11.15/003: a car member comes online ⇒ the car\'s other units '
        'are taken as present (no scan in the background)', () async {
      final ml = await bootCars(nearby: {'c', 'd', 'e'});
      expect(ml.heldIds, isEmpty);
      s.connection.setDetailVisible(true); // no presence scan either
      primary.connectedId = 'a';
      primary.emitLink(BleLinkState.ready);
      await _settle();
      expect(ml.heldIds, {'b'}, reason: 'only car A; B\'s units untouched');
    });

    // 2026-11-18 user report: 自動重連 off, the home tab still connected the
    // car battery. Off ⇒ only the user's own pick in the home picker connects
    // a group, once; nothing else (first car, device page, retries) does.
    group('2026-11-18: 自動重連 off', () {
      test('creating the first car connects nothing', () async {
        final ml = await bootCars(autoReconnect: false);
        expect(vehicles.current?.id, carA);
        expect(ml.heldIds, isEmpty);
        expect(log.where((e) => e.startsWith('connect')), isEmpty);
      });

      test('picking a car in the home picker connects its units once',
          () async {
        final ml = await bootCars(autoReconnect: false);
        await vehicles.select(carB, source: 'home');
        await _settle();
        expect(ml.heldIds, {'c', 'd'});
        // One of them drops: let go, not retried — not even by a later tick.
        sec('c').drop();
        await _settle();
        expect(ml.heldIds, {'d'});
        now = now.add(MultiLinkConfig.presenceScanEvery);
        ml.presenceTick();
        await _settle();
        expect(ml.heldIds, {'d'});
        expect(log.where((e) => e == 'connect c'), hasLength(1));
        expect(
            await notes(),
            contains('multilink: release id=${shortDeviceHash('c')} '
                'reason=auto-off'));
      });

      test('a switch from the device page is not a pick: nothing connects',
          () async {
        final ml = await bootCars(autoReconnect: false);
        await vehicles.select(carB, source: 'device-page');
        await _settle();
        expect(ml.heldIds, isEmpty);
      });

      test('a pick does not linger: units that turn up later stay down',
          () async {
        final ml = await bootCars(nearby: const {}, autoReconnect: false);
        await vehicles.select(carB, source: 'home');
        await _settle();
        expect(ml.heldIds, isEmpty, reason: 'c and d not in range');
        now = now.add(MultiLinkConfig.presenceWindow +
            const Duration(seconds: 1));
        primary.nearby = {'c', 'd'};
        ml.presenceTick();
        await _settle();
        expect(ml.heldIds, isEmpty);
      });

      test('personal: the home pick connects the power bank; nothing else does',
          () async {
        final ml = await bootCars(autoReconnect: false);
        await vehicles.select(VehicleRepo.personalId);
        await _settle();
        now = now.add(const Duration(minutes: 1));
        ml.presenceTick();
        await _settle();
        expect(primary.primaryConnects, isEmpty,
            reason: 'no source, and the 30 s retry is not the user');
        await vehicles.select(carA, source: 'home');
        await _settle();
        await vehicles.select(VehicleRepo.personalId, source: 'home');
        await _settle();
        expect(primary.primaryConnects, ['e']);
      });
    });

    test('Q4: a non-member primary stays on switch, goes when its page closes',
        () async {
      final ml = await bootCars();
      primary.connectedId = 'c';
      primary.emitLink(BleLinkState.ready);
      await _settle();
      expect(s.connection.connectedDeviceId, 'c');
      expect(ml.heldIds, {'a', 'b'});
      ml.onDetailClosed('c');
      await _settle();
      expect(s.connection.connectedDeviceId, isNull);
      final n = await notes();
      expect(n.any((x) => x.contains('release-primary') &&
          x.contains('reason=vehicle-switch')), isTrue);
    });

    test('V1: a unit the user disconnected comes back after B → A', () async {
      final ml = await bootCars();
      // The user takes a as the primary, then disconnects it.
      await ml.beforePrimaryConnect('a');
      primary.connectedId = 'a';
      primary.emitLink(BleLinkState.ready);
      await _settle();
      await s.connection.disconnect();
      await _settle();
      expect(ml.heldIds, {'b'}, reason: 'a is released by the user');
      await vehicles.select(carB);
      await _settle();
      await vehicles.select(carA);
      await _settle();
      expect(ml.heldIds, {'a', 'b'});
    });

    test('a power bank primary is let go when a car is picked', () async {
      final ml = await bootCars();
      await vehicles.select(VehicleRepo.personalId);
      await _settle();
      expect(s.connection.connectedDeviceId, 'e');
      await vehicles.select(carB);
      await _settle();
      expect(s.connection.connectedDeviceId, isNull);
      expect(ml.heldIds, {'c', 'd'});
    });

    test('forgetting a member: the car follows and its link goes', () async {
      final ml = await bootCars();
      await s.devices.remove('a');
      await s.pending.drain();
      await _settle();
      expect(vehicles.vehicleFor(carA)?.deviceIds, ['b']);
      expect(ml.heldIds, {'b'});
    });

    test('switch off: picking a vehicle changes nothing at all', () async {
      final ml = await bootCars();
      await ml.setEnabled(false);
      await _settle();
      log.clear();
      await vehicles.select(carB);
      await vehicles.select(VehicleRepo.personalId);
      await _settle();
      expect(ml.heldIds, isEmpty);
      expect(log, isEmpty);
      expect(primary.primaryConnects, isEmpty);
    });

    test('no car ⇒ the 0103 rule exactly (the personal row alone is inert)',
        () async {
      final ml = await boot([bat('a'), bat('b'), bat('c'), pb('e')]);
      final v = s.vehicles;
      final id = (await v.createCar('A')).id;
      await v.delete(id);
      await _settle();
      expect(v.hasCars, isFalse);
      expect(ml.activeVehicle, isNull);
      expect(ml.heldIds, {'a', 'b', 'c'},
          reason: 'all three batteries, never the power bank — 0103 as before');
    });
  });

  // 2026.11.12/004: twelve saved units, and the three slots went to the three
  // most recently SEEN — none of them in range — while the two units in front
  // of the dealer waited for him to tap them (≈ 1 min 26 s).
  group('2026-11-18: 自動重連 off (no vehicle)', () {
    test('saved units in range are not adopted, and not scanned for',
        () async {
      final ml = await boot([bat('A'), bat('B')],
          nearby: const {}, adapterOn: true, autoReconnect: false);
      expect(primary.scans, 0, reason: 'nothing the user asked for to find');
      primary.emitScan({'A', 'B'});
      await _settle();
      ml.presenceTick();
      await _settle();
      expect(ml.heldIds, isEmpty);
      expect(log.where((e) => e.startsWith('connect')), isEmpty);
    });

    test('a link up when the setting goes off stays; when it drops it is let '
        'go, not retried', () async {
      final ml = await boot([bat('A'), bat('B')]);
      expect(ml.heldIds, {'A', 'B'});
      await s.settings.setAutoReconnect(false);
      await _settle();
      expect(ml.heldIds, {'A', 'B'}, reason: 'not cut from under the user');
      sec('A').drop();
      await _settle();
      now = now.add(const Duration(minutes: 1));
      ml.presenceTick();
      await _settle();
      expect(ml.heldIds, {'B'});
      expect(log.where((e) => e == 'connect A'), hasLength(1));
    });

    test('turning it back on resumes the 0103 rule', () async {
      final ml = await boot([bat('A')], autoReconnect: false);
      expect(ml.heldIds, isEmpty);
      await s.settings.setAutoReconnect(true);
      ml.presenceTick();
      await _settle();
      expect(ml.heldIds, {'A'});
    });
  });

  // design 0107: simple mode (AppMode.advanced) withholds multi-link and
  // vehicles — effective off, the stored switch untouched, restored on return.
  group('0107: simple mode holds multi-link off', () {
    Future<List<String>> notes() async {
      await s.pending.drain();
      return [for (final e in await s.logRepo.queryLog()) e.note ?? ''];
    }

    test('a launch in simple mode: no scan, no adoption; the switch stays on',
        () async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      // Stored before the app starts: switch on, mode simple, a unit saved.
      await SettingsRepo(db.db)
          .saveSettings(AppSettings.defaults.copyWith(mode: AppMode.advanced));
      await AckMarker(MultiLinkConfig.enabledMarker).markAcknowledged();
      primary = _FakePrimary(adapterOn: true)..nearby = {'A'};
      s = await AppServices.create(
        appDatabase: db,
        ble: primary,
        multiLinkBuild: true,
        multiLinkBleFactory: () => _FakeSecondary(log, secondaries),
        multiLinkClock: () => now,
      );
      _settleTarget = s;
      final ml = s.multiLink!;
      await s.devices.save(bat('A'));
      primary.emitScan({'A'});
      await _settle();
      now = now.add(MultiLinkConfig.presenceScanEvery);
      ml.presenceTick();
      await _settle();
      expect(s.settings.mode, AppMode.advanced);
      expect(ml.enabled, isTrue, reason: 'the stored switch is untouched');
      expect(ml.active, isFalse);
      expect(primary.scans, 0, reason: 'no switch-on scan, no presence scan');
      expect(ml.heldIds, isEmpty);
      expect(log.where((e) => e.startsWith('connect')), isEmpty);
    });

    test('personal → simple: every secondary goes, the primary stays',
        () async {
      final ml = await boot([bat('P'), bat('A'), bat('B')], primaryId: 'P');
      expect(ml.heldIds, {'A', 'B'});
      await s.settings.setMode(AppMode.advanced);
      await _settle();
      expect(ml.heldIds, isEmpty);
      expect(ml.active, isFalse);
      expect(s.connection.connectedDeviceId, 'P', reason: 'primary untouched');
      final n = await notes();
      for (final id in ['A', 'B']) {
        expect(
            n,
            contains('multilink: release id=${shortDeviceHash(id)} '
                'reason=simple-mode'),
            reason: id);
      }
      // Later ticks adopt nothing.
      now = now.add(MultiLinkConfig.presenceScanEvery);
      ml.presenceTick();
      await _settle();
      expect(ml.heldIds, isEmpty);
    });

    test('simple → personal: secondaries come back', () async {
      final ml = await boot([bat('A'), bat('B')]);
      primary.acceptConnects = true;
      await s.settings.setMode(AppMode.advanced);
      await _settle();
      expect(ml.heldIds, isEmpty);
      // 2026.11.22/002: the switch into simple mode, with nothing connected,
      // takes the last-used unit as the primary (one unit, never both).
      expect(primary.primaryConnects, hasLength(1));
      final first = primary.primaryConnects.single;
      await s.settings.setMode(AppMode.personal);
      await _settle();
      expect(ml.active, isTrue);
      expect(ml.heldIds, {'A', 'B'}.difference({first}),
          reason: 'the other unit comes back as a secondary');
    });

    test('export header lines and the vehicle go with the mode', () async {
      final ml = await boot([bat('a'), bat('b')]);
      final car = (await s.vehicles.createCar('A')).id;
      await s.vehicles.setDevices(car, ['a', 'b']);
      await _settle();
      expect(ml.exportHeaderValue, isNotNull);
      expect(ml.vehicleHeaderValue, isNotNull);
      expect(ml.activeVehicle, isNotNull);
      await s.settings.setMode(AppMode.advanced);
      await _settle();
      expect(ml.exportHeaderValue, isNull);
      expect(ml.vehicleHeaderValue, isNull);
      expect(ml.activeVehicle, isNull);
      expect(s.vehicles.current?.id, car, reason: 'the pick is kept');
    });

    test('a power bank holding the others paused: simple mode clears it',
        () async {
      final ml = await boot([bat('A'), bat('B'), pb('PB')]);
      await ml.beforePrimaryConnect('PB');
      primary.connectedId = 'PB';
      primary.emitLink(BleLinkState.ready);
      await _settle();
      expect(ml.heldIds, {'A', 'B'}, reason: 'paused, not dropped');
      await s.settings.setMode(AppMode.advanced);
      await _settle();
      expect(ml.heldIds, isEmpty);
      expect(ml.shouldPromptForPowerBank('PB'), isFalse);
    });
  });

  // design 0107 §9 (2026-11-20, 何先生): a launch in simple mode connects the
  // last-used unit as the primary — the launch connect used to be multi-link's.
  group('0107 §9: a launch in simple mode connects the last-used unit', () {
    Future<List<String>> notes() async {
      await s.pending.drain();
      return [for (final e in await s.logRepo.queryLog()) e.note ?? ''];
    }

    /// Stored before the app starts: switch on, [mode], units saved in
    /// [saved] order (first = most recently used), [nearby] in range.
    Future<MultiLinkController> launch(List<String> saved,
        {AppMode mode = AppMode.advanced,
        Set<String> nearby = const {},
        bool auto = true,
        bool switchOn = true}) async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      await SettingsRepo(db.db).saveSettings(AppSettings.defaults
          .copyWith(mode: mode, autoReconnect: auto, rawPacketLog: true));
      final repo = DeviceRepo(db.db);
      final t0 = DateTime(2026, 11, 20, 7);
      for (var i = 0; i < saved.length; i++) {
        await repo.upsertSavedDevice(
            bat(saved[i]).copyWith(lastSeen: t0.subtract(Duration(hours: i))));
      }
      if (switchOn) {
        await AckMarker(MultiLinkConfig.enabledMarker).markAcknowledged();
      } else {
        await AckMarker(MultiLinkConfig.enabledMarker).clear();
      }
      primary = _FakePrimary(adapterOn: true)
        ..nearby = nearby
        ..acceptConnects = true;
      s = await AppServices.create(
        appDatabase: db,
        ble: primary,
        multiLinkBuild: true,
        multiLinkBleFactory: () => _FakeSecondary(log, secondaries),
        multiLinkClock: () => now,
      );
      _settleTarget = s;
      await _settle();
      return s.multiLink!;
    }

    test('in range: the last-used unit only, as the primary', () async {
      final ml = await launch(['A', 'B'], nearby: {'A', 'B'});
      expect(primary.primaryConnects, ['A']);
      expect(s.connection.connectedDeviceId, 'A');
      expect(ml.heldIds, isEmpty, reason: 'no secondaries in simple mode');
      expect(await notes(),
          contains('multilink: simple-launch connect id=${shortDeviceHash('A')}'));
    });

    test('out of range: scans, gives up after the window, never another unit',
        () async {
      final ml = await launch(['A', 'B'], nearby: {'B'});
      expect(primary.scans, greaterThan(0));
      expect(primary.primaryConnects, isEmpty);
      now = now.add(ml.launchWindow);
      ml.simpleLaunchTick();
      await _settle();
      expect(primary.primaryConnects, isEmpty, reason: 'B is not the last used');
      expect(await notes(),
          contains('multilink: simple-launch not-seen id=${shortDeviceHash('A')}'));
      // Done: later ticks do nothing even once A shows up.
      primary.emitScan({'A'});
      await _settle();
      ml.simpleLaunchTick();
      await _settle();
      expect(primary.primaryConnects, isEmpty);
    });

    test('heard later inside the window: connects then', () async {
      final ml = await launch(['A'], nearby: {});
      expect(primary.primaryConnects, isEmpty);
      now = now.add(const Duration(seconds: 10));
      primary.emitScan({'A'});
      await _settle();
      ml.simpleLaunchTick();
      await _settle();
      expect(primary.primaryConnects, ['A']);
    });

    test('自動連線 off: nothing connects', () async {
      await launch(['A'], nearby: {'A'}, auto: false);
      expect(primary.primaryConnects, isEmpty);
      expect(await notes(), contains('multilink: simple-launch auto-off'));
    });

    test('personal mode: multi-link as before, not this path', () async {
      final ml = await launch(['A', 'B'], mode: AppMode.personal, nearby: {'A', 'B'});
      expect(primary.primaryConnects, isEmpty);
      expect(ml.heldIds, {'A', 'B'});
      expect((await notes()).where((n) => n.contains('simple-launch')), isEmpty);
    });

    // 🔴 2026.11.22/002 inverted this test. It used to pin "switch off ⇒
    // nothing" — and that was the field bug: the reporter had switched it off,
    // and the row is greyed out in simple mode, so nothing told him why.
    test('switch off: connects all the same (2026.11.22/002)', () async {
      await launch(['A'], nearby: {'A'}, switchOn: false);
      expect(primary.primaryConnects, ['A']);
      expect(await notes(),
          contains('multilink: simple-launch connect id=${shortDeviceHash('A')}'));
    });

    test('personal → simple: one look, and the switch is logged', () async {
      final ml = await launch(['A', 'B'],
          mode: AppMode.personal, nearby: {'A', 'B'}, switchOn: false);
      expect(primary.primaryConnects, isEmpty, reason: 'personal, switch off');
      await s.settings.setMode(AppMode.advanced);
      await _settle();
      expect(primary.primaryConnects, ['A']);
      final n = await notes();
      expect(n, contains('app mode: personal → advanced'));
      expect(
          n,
          contains('multilink: simple-launch connect '
              'id=${shortDeviceHash('A')} via=mode-switch'));
      await s.settings.setMode(AppMode.personal);
      await _settle();
      expect(await notes(), contains('app mode: advanced → personal'));
      expect(ml.enabled, isFalse, reason: 'the switch is not touched');
    });

    test('back in the foreground with nothing connected: one more look',
        () async {
      final ml = await launch(['A'], nearby: {});
      now = now.add(ml.launchWindow);
      ml.simpleLaunchTick();
      await _settle();
      expect(primary.primaryConnects, isEmpty, reason: 'the launch gave up');
      s.connection.logAppLifecycle('paused');
      await _settle();
      s.connection.logAppLifecycle('resumed');
      await _settle();
      primary.emitScan({'A'});
      await _settle();
      ml.simpleLaunchTick();
      await _settle();
      expect(primary.primaryConnects, ['A']);
      expect(
          await notes(),
          contains('multilink: simple-launch connect '
              'id=${shortDeviceHash('A')} via=resume'));
    });

    test('a unit the user let go is not brought back by a resume', () async {
      final ml = await launch(['A'], nearby: {'A'});
      expect(primary.primaryConnects, ['A']);
      primary.realisticDisconnect = true;
      await s.connection.disconnect();
      await _settle();
      s.connection.logAppLifecycle('paused');
      await _settle();
      s.connection.logAppLifecycle('resumed');
      await _settle();
      ml.simpleLaunchTick();
      await _settle();
      expect(primary.primaryConnects, ['A'], reason: 'no second connect');
      expect(
          await notes(),
          contains('multilink: simple-launch released '
              'id=${shortDeviceHash('A')} via=resume'));
    });

    test('personal mode: a resume arms nothing', () async {
      await launch(['A'], mode: AppMode.personal, nearby: {'A'}, switchOn: false);
      s.connection.logAppLifecycle('paused');
      await _settle();
      s.connection.logAppLifecycle('resumed');
      await _settle();
      expect(primary.primaryConnects, isEmpty);
      expect((await notes()).where((n) => n.contains('simple-launch')), isEmpty);
    });
  });

  // 2026.11.20/004 (何先生, iOS, personal mode): at a cold start the presence
  // scan ran before the radio was on, was skipped without a word, and still
  // counted — the first real scan came 60.002 s after the launch.
  group('2026.11.20/004: the cold-start presence scan waits for the radio', () {
    Future<List<String>> notes() async {
      await s.pending.drain();
      return [for (final e in await s.logRepo.queryLog()) e.note ?? ''];
    }

    Future<MultiLinkController> coldStart(List<String> saved,
        {Set<String> nearby = const {}}) async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      await SettingsRepo(db.db)
          .saveSettings(AppSettings.defaults.copyWith(rawPacketLog: true));
      final repo = DeviceRepo(db.db);
      for (final id in saved) {
        await repo.upsertSavedDevice(bat(id));
      }
      await AckMarker(MultiLinkConfig.enabledMarker).markAcknowledged();
      primary = _FakePrimary(lateAdapter: true)..nearby = nearby;
      s = await AppServices.create(
        appDatabase: db,
        ble: primary,
        multiLinkBuild: true,
        multiLinkBleFactory: () => _FakeSecondary(log, secondaries),
        multiLinkClock: () => now,
      );
      _settleTarget = s;
      await _settle();
      return s.multiLink!;
    }

    test('scans the moment the radio is on, and adopts both', () async {
      final ml = await coldStart(['A', 'B'], nearby: {'A', 'B'});
      expect(primary.scans, 0, reason: 'radio not on yet');
      expect(await notes(),
          contains('multilink: presence scan waits: adapter=unknown'));
      primary.emitAdapter(BluetoothAdapterState.on);
      await _settle();
      expect(primary.scans, 1);
      expect(ml.heldIds, {'A', 'B'});
    });

    test('a scan the radio did not allow does not use up the minute',
        () async {
      final ml = await coldStart(['A'], nearby: {'A'});
      ml.presenceTick(); // the 10 s tick, radio still not on
      await _settle();
      expect(primary.scans, 0);
      primary.emitAdapter(BluetoothAdapterState.on);
      await _settle();
      ml.presenceTick(); // same instant: no 60 s wait was stamped
      await _settle();
      expect(primary.scans, greaterThan(0));
      expect(ml.heldIds, {'A'});
    });

    test('back in the foreground: scans at once', () async {
      final ml = await coldStart(['A'], nearby: {});
      s.connection.logAppLifecycle('paused');
      primary.emitAdapter(BluetoothAdapterState.on);
      await _settle();
      expect(primary.scans, 0, reason: 'in the background');
      primary.nearby = {'A'};
      s.connection.logAppLifecycle('resumed');
      await _settle();
      expect(primary.scans, 1);
      expect(ml.heldIds, {'A'});
    });
  });

  test('004: only units seen nearby take a slot', () async {
    final ml = await boot(
        [bat('A'), bat('B'), bat('C'), bat('D'), bat('E')],
        nearby: {'D', 'E'});
    expect(ml.heldIds, {'D', 'E'});
  });

  test('004: an absent held unit gives its slot back after the window', () async {
    final ml = await boot([bat('A'), bat('B'), bat('C'), bat('D')],
        nearby: {'A', 'B', 'C'});
    expect(ml.heldIds, {'A', 'B', 'C'});
    // C goes out of range: its link drops and it never comes back.
    await sec('C').disconnect();
    await _settle();
    // Inside the window it keeps its slot (a brief drop must not cost it).
    now = now.add(MultiLinkConfig.presenceWindow);
    ml.presenceTick();
    await _settle();
    expect(ml.heldIds, contains('C'));
    // Past the window it is let go …
    now = now.add(const Duration(seconds: 1));
    ml.presenceTick();
    await _settle();
    expect(ml.heldIds.contains('C'), isFalse);
    expect(log, contains('disconnect C'));
    // … and a unit a scan finds takes the slot.
    primary.emitScan({'D'});
    await _settle();
    expect(ml.heldIds, {'A', 'B', 'D'});
  });

  test('004: a live secondary stays a candidate without being scanned again',
      () async {
    final ml = await boot([bat('A'), bat('B')], nearby: {'A', 'B'});
    expect(ml.heldIds, {'A', 'B'});
    // Connected units do not advertise; samples are their presence.
    now = now.add(const Duration(minutes: 30));
    ml.presenceTick();
    await _settle();
    expect(ml.heldIds, {'A', 'B'});
  });

  test('004: a hand-off keeps the old primary eligible as a secondary',
      () async {
    final ml = await boot([bat('A'), bat('B')], nearby: {'B'}, primaryId: 'A');
    expect(ml.heldIds, {'B'});
    // A has been the primary for an hour; no scan has seen it (connected).
    now = now.add(const Duration(hours: 1));
    await ml.beforePrimaryConnect('B');
    primary.connectedId = 'B';
    primary.emitLink(BleLinkState.ready);
    await _settle();
    expect(ml.heldIds, {'A'});
  });

  group('2026.11.15/003: units live beside the primary come back with it', () {
    // Walk away from the car: both links drop; the secondary is released
    // after the presence window; no scan runs in the background. Come back:
    // the primary reconnects on its own — the secondary must follow.
    Future<MultiLinkController> walkAwayAndBack(
        {required Set<String> nearby}) async {
      final ml = await boot([bat('A'), bat('B'), bat('C')],
          nearby: nearby, primaryId: 'A');
      primary.emitLink(BleLinkState.disconnected); // radio drop: id kept
      for (final b in secondaries.where((b) => b.id != null).toList()) {
        await b.disconnect();
      }
      await _settle();
      now = now.add(MultiLinkConfig.presenceWindow + const Duration(seconds: 1));
      ml.presenceTick();
      await _settle();
      expect(ml.heldIds, isEmpty, reason: 'released while away');
      now = now.add(const Duration(hours: 1));
      primary.emitLink(BleLinkState.ready); // back, primary reconnects
      await _settle();
      return ml;
    }

    test('a unit that was live beside it is taken as present again', () async {
      final ml = await walkAwayAndBack(nearby: {'B'});
      expect(ml.heldIds, {'B'});
      await s.pending.drain();
      final notes = [for (final e in await s.logRepo.queryLog()) e.note ?? ''];
      expect(
          notes,
          contains('multilink: companions back with=${shortDeviceHash('A')} '
              'ids=${shortDeviceHash('B')}'));
    });

    test('a unit never live beside it is not', () async {
      // C is saved but was never seen, so it was never a companion of A.
      final ml = await walkAwayAndBack(nearby: {'B'});
      expect(ml.heldIds.contains('C'), isFalse);
    });

    test('a companion that really is not there gives its slot back after '
        'the window, as before', () async {
      final ml = await walkAwayAndBack(nearby: {'B'});
      await sec('B').disconnect(); // B is not actually in range
      await _settle();
      now = now.add(MultiLinkConfig.presenceWindow + const Duration(seconds: 1));
      ml.presenceTick();
      await _settle();
      expect(ml.heldIds, isEmpty);
    });
  });

  test('004: with a slot free and a unit unaccounted for, the controller scans',
      () async {
    final ml = await boot([bat('A'), bat('B'), bat('C')],
        nearby: const {}, adapterOn: true);
    expect(primary.scans, 1, reason: 'switch-on looks for nearby units');
    expect(ml.heldIds, isEmpty, reason: 'nothing in range yet');
    // Rate-limited: another tick inside presenceScanEvery does not rescan.
    primary.nearby = {'B'};
    ml.presenceTick();
    await _settle();
    expect(primary.scans, 1);
    now = now.add(MultiLinkConfig.presenceScanEvery);
    ml.presenceTick();
    await _settle();
    expect(primary.scans, 2);
    expect(ml.heldIds, {'B'});
  });

  group('2026.11.19/007: a presence scan runs its window before anyone is '
      'adopted', () {
    test('the first unit heard waits; both are adopted when the scan ends',
        () async {
      final ml = await boot([bat('A'), bat('B')],
          nearby: const {}, adapterOn: true, enable: false);
      primary.realisticScan = true;
      primary.nearby = {'A'};
      await ml.setEnabled(true);
      await _settle();
      expect(primary.scans, 1);
      expect(s.connection.isPresenceScanning, isTrue);
      expect(ml.heldIds, isEmpty,
          reason: 'adopting A now would stop the scan before B is heard');
      expect(log.where((l) => l.startsWith('connect')), isEmpty);

      primary.emitScan({'A', 'B'});
      await _settle();
      expect(ml.heldIds, isEmpty);

      primary.finishScan();
      await _settle();
      expect(s.connection.isPresenceScanning, isFalse);
      expect(ml.heldIds, {'A', 'B'});
      expect(log, containsAll(['connect A', 'connect B']));
    });

    test('a scan that is not a presence scan does not hold adoption',
        () async {
      final ml = await boot([bat('A')],
          nearby: const {}, adapterOn: true, enable: false);
      primary.realisticScan = true;
      // The devices tab's own scan (startScan, not startPresenceScan).
      await s.connection.startScan();
      primary.emitScan({'A'});
      await _settle();
      expect(s.connection.isScanning, isTrue);
      expect(s.connection.isPresenceScanning, isFalse);
      await ml.setEnabled(true);
      await _settle();
      expect(ml.heldIds, {'A'});
    });
  });

  group('2026.11.20/003: the log says why a unit in range holds no link', () {
    Future<List<String>> holds() async {
      await s.pending.drain();
      // queryLog is newest first; oldest first reads as a timeline.
      return [
        for (final e in (await s.logRepo.queryLog()).reversed)
          if ((e.note ?? '').startsWith('multilink: hold')) e.note!
      ];
    }

    String h(String id) => shortDeviceHash(id);

    test('自動連線 off: auto-off, logged once however often it reconciles',
        () async {
      await boot([bat('A')], autoReconnect: false);
      primary.emitScan({'A'});
      await _settle();
      s.multiLink!.presenceTick();
      await _settle();
      expect(await holds(), ['multilink: hold ${h('A')}=auto-off']);
    });

    test('a presence scan holds both, then none once they are adopted',
        () async {
      final ml = await boot([bat('A'), bat('B')],
          nearby: const {}, adapterOn: true, enable: false);
      primary.realisticScan = true;
      primary.nearby = {'A'};
      await ml.setEnabled(true);
      await _settle();
      primary.emitScan({'A', 'B'});
      await _settle();
      primary.finishScan();
      await _settle();
      expect(ml.heldIds, {'A', 'B'});
      final n = await holds();
      expect(n.first, contains('${h('A')}=presence-scan'));
      expect(n, contains('multilink: hold ${h('A')}=presence-scan,'
          '${h('B')}=presence-scan'));
      expect(n.last, 'multilink: hold none');
    });

    test('a unit the user let go: released', () async {
      final ml = await boot([bat('A')]);
      expect(ml.heldIds, {'A'});
      await ml.releaseByUser('A');
      await _settle();
      expect(await holds(), ['multilink: hold ${h('A')}=released']);
    });

    test('the switch off says nothing', () async {
      await boot([bat('A')], enable: false);
      primary.emitScan({'A'});
      await _settle();
      expect(await holds(), isEmpty);
    });
  });

  test('004: no presence scan in the background or behind a device page',
      () async {
    await boot([bat('A')], nearby: const {}, adapterOn: true);
    final before = primary.scans;
    s.connection.setDetailVisible(true);
    now = now.add(const Duration(minutes: 5));
    s.multiLink!.presenceTick();
    await _settle();
    expect(primary.scans, before);
  });

  test('§3.6: export header carries the line only while the switch is on',
      () async {
    final ml = await boot([bat('A')]);
    List<String> header(String? v) => exportHeaderLines(
          title: 't',
          exportedAt: DateTime(2026),
          appBuild: 'x',
          platform: 'p',
          edition: AppEdition.community,
          scope: 'all',
          layout: '-',
          home: '-',
          mode: AppMode.personal,
          themeMode: AppThemeMode.dark,
          accent: AccentTheme.amber,
          speedDetection: false,
          gMeter: false,
          resolution: ExportResolution.none,
          multiLink: v,
          devices: const [],
        );
    expect(header(ml.exportHeaderValue), contains('multilink: on max=3'));
    await ml.setEnabled(false);
    expect(ml.exportHeaderValue, isNull);
    expect(header(ml.exportHeaderValue).any((l) => l.startsWith('multilink')),
        isFalse);
  });

  // design 0106 Phase 5: the `vehicle:` line rides with `multilink:` — and
  // reaches the problem report's note.txt as well.
  test('0106 Phase 5: export header and report note carry vehicle:',
      () async {
    await boot([bat('A')]); // the file's tearDown disposes the services
    List<String> header(String? v) => exportHeaderLines(
          title: 't',
          exportedAt: DateTime(2026),
          appBuild: 'x',
          platform: 'p',
          edition: AppEdition.community,
          scope: 'all',
          layout: '-',
          home: '-',
          mode: AppMode.personal,
          themeMode: AppThemeMode.dark,
          accent: AccentTheme.amber,
          speedDetection: false,
          gMeter: false,
          resolution: ExportResolution.none,
          multiLink: v == null ? null : 'on max=3',
          vehicle: v,
          devices: const [],
        );
    expect(header('current=car1/2 devices=2'),
        contains('vehicle: current=car1/2 devices=2'));
    expect(header(null).any((l) => l.startsWith('vehicle')), isFalse);
    String? note(String? v) => reportNoteText(
          note: 'it drops',
          appName: 'OSB',
          appBuild: 'x',
          platform: 'p',
          edition: AppEdition.community,
          scope: 'all',
          at: DateTime(2026),
          vehicle: v,
        );
    expect(note('current=personal/1 devices=1'),
        contains('# vehicle: current=personal/1 devices=1'));
    expect(note(null), isNot(contains('vehicle')));
  });
}
