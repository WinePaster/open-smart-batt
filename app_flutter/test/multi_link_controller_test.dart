// design 0103 — the multi-link experiment's controller, exercised by injection
// (the compile-time flag is off in `flutter test`; `AppServices.create` takes
// `multiLinkBuild: true` and a factory for the secondary BleService fakes).
//
// What is pinned here, by ruling:
//   D6  at most 3 links, primary included; power banks / demo ids never adopted
//   —   hand-off: a secondary is released BEFORE the primary connects to it
//   D1  power bank as primary ⇒ the others pause, and resume when it is gone
//   D5  slow-writer demotion: ≥ 500 ms with ≥ 2 links; never with one;
//       third demotion leaves the unit out
//   D7  notification line counts every live link
//   D2  prompt only for a power bank, only while other links are live
//   §3.6 / FB-41  two links interleaving samples never cross-attribute
//   004 only units seen nearby (scan or live link) take a slot; an absent held
//       unit gives its slot back after the presence window
import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/config/app_config.dart';
import 'package:open_smart_batt/config/multi_link_config.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/accent_theme.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The primary link: driven by hand, never touches a radio.
class _FakePrimary extends BleService {
  _FakePrimary({this.adapterOn = false});

  final bool adapterOn;
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _teleOut = StreamController<TelemetrySample>.broadcast();
  final _scanOut = StreamController<List<DiscoveredDevice>>.broadcast();
  String? connectedId;

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
  Stream<BluetoothAdapterState> get adapterState => adapterOn
      ? Stream<BluetoothAdapterState>.value(BluetoothAdapterState.on)
      : const Stream<BluetoothAdapterState>.empty();
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
  @override
  Stream<List<DiscoveredDevice>> get scanResults => _scanOut.stream;

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)}) async {
    scans++;
    emitScan(nearby);
  }

  void emitLink(BleLinkState s) => _linkOut.add(s);

  void emitScan(Iterable<String> ids) => _scanOut.add([
        for (final id in ids) DiscoveredDevice(id: id, name: id, rssi: -60),
      ]);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _teleOut.close();
    await _scanOut.close();
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

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _teleOut.close();
    await _pktOut.close();
    await _diagOut.close();
    await super.dispose();
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

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
      bool adapterOn = false}) async {
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
    for (final d in devices) {
      await s.devices.save(d);
    }
    final seen = nearby ?? {for (final d in devices) d.id};
    if (seen.isNotEmpty) {
      primary.emitScan(seen);
      await _settle();
    }
    await s.settings.setRawPacketLog(true);
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
      await _settle();
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

  // 2026.11.12/004: twelve saved units, and the three slots went to the three
  // most recently SEEN — none of them in range — while the two units in front
  // of the dealer waited for him to tap them (≈ 1 min 26 s).
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
}
