// design 0068 (C) — is the unit that answered the unit we were asked for?
//
// WHY THIS EXISTS. On iOS a saved id can be rebound to another unit advertising
// the same name, and same-name units are not hypothetical: two capacitors both
// advertise `RCE-SCAP_II`, and `2026.08.14/004` §5 S1 is a wire-level capture of
// this app connecting to the wrong one of them — three times, reaching `ready`
// each time, with nothing on screen to say so. `saved_device.dart` names the
// cost in its own comment: "silent, and indistinguishable afterwards".
//
// The check cannot happen before the connection, and that is the finding design
// 0068 rests on rather than an implementation shortcut: iOS hands an app no MAC
// at scan time, and the advertisement itself carries no identity at all — no
// serial, no address, a name that does not distinguish two units, and five
// bytes of live measurement that change while you watch them (two captures, six
// units, `docs/knowledges/advertisement-payload.md`). `0x38` is the first moment
// identity exists.
//
// What is pinned here is the whole contract: mismatch reports and drops, match
// is silent, and a unit whose record has never seen a `0x38` is left alone —
// the last one being the case a naive implementation gets wrong, because "we do
// not know this unit's address" is not "this is the wrong unit".
//
// CLEAN-ROOM: expectations derive from our own source and our own captures.
import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show
        BluetoothAdapterState,
        ErrorPlatform,
        FbpErrorCode,
        FlutterBluePlusException;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The two capacitors of `2026.08.14/004`, by their real advertised name.
const _savedId = 'SAVED-UNIT';
const _savedMac = 'FE:78:27:73:00:01';
const _otherMac = '95:02:64:73:00:02';

/// The SECOND unit, as its own saved record — FB-88 is a two-unit story and the
/// old fixtures only ever had one. `_otherMac` above was the address of an
/// impostor answering under `_savedId`; this is a unit the user owns, taps, and
/// switches to.
const _otherId = 'OTHER-UNIT';

/// One link, the way [BleService] holds one: keyed by device id, owning its own
/// path to the telemetry stream, and — the part that matters here — STILL ABLE
/// TO SEND after it has been displaced.
///
/// 🔴 FB-88 / design 0078 §6 T1. The stub this file used to have modelled a
/// single link and a single `emitTelemetry`, so the one situation the defect
/// lives in — "the connect to B has been issued, and A's link is still pushing
/// frames out while it tears down" — could not even be WRITTEN, let alone
/// asserted. That is why I1–I6 / B1–B5 / F1–F2 covered the identity guard
/// thoroughly and still missed a regression that misfired on a third of all
/// device switches in the field. The double is the fix's first deliverable, not
/// its last.
class _StubLink {
  _StubLink(this._out, this.deviceId);

  final StreamController<TelemetrySample> _out;

  /// The BLE remote id this link belongs to.
  final String deviceId;

  /// True once a later `connect` displaced this link. It is deliberately NOT
  /// the same thing as "silent": `BleService._setSoleLink` drops the previous
  /// link from its map and tears it down asynchronously, and the platform keeps
  /// delivering that link's notifications for the length of the teardown —
  /// 49 ms and 3,240 ms in the two `2026.08.18/008` captures.
  bool tearingDown = false;

  /// Publish a frame as this link, stamped the way the real service stamps it
  /// (`ble_service.dart`, `_onNotify`): the sample goes out carrying the id of
  /// the link it came off, and nothing else changes.
  void emit(TelemetrySample s) => _out.add(s.copyWith(deviceId: deviceId));
}

class _StubBle extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  /// Every link this stub has ever built, oldest first — displaced ones
  /// INCLUDED, because those are the ones with something to say.
  final List<_StubLink> links = <_StubLink>[];

  String? _connected;
  int disconnectCalls = 0;

  /// What `connect` throws, if anything.
  Object? connectError;

  /// Reproduce the real service's ORDERING of a switch.
  ///
  /// `BleService.connect` awaits the platform disconnect of the previous link
  /// before it re-points `_current`, and `connectedDeviceId` reads `_current` —
  /// so throughout the teardown window the service still answers with the OLD
  /// unit's id. Off by default so the existing fixtures keep their simple
  /// shape; T2b turns it on, because that ordering is the entire reason the
  /// gate compares against the controller's own target and not against this.
  bool holdConnectedIdDuringTeardown = false;

  /// The oldest surviving link for [id] — i.e. the one being torn down when a
  /// switch is in progress, which is the one the tests want to speak as.
  _StubLink linkFor(String id) => links.firstWhere((l) => l.deviceId == id);

  /// The most recently installed link, if any.
  _StubLink? get currentLink => links.isEmpty ? null : links.last;

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<BlePacketEvent> get packets => const Stream<BlePacketEvent>.empty();

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  String? get connectedDeviceId => _connected;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    final e = connectError;
    if (e != null) throw e;
    // Mirrors `BleService._setSoleLink`: whatever was there is displaced and
    // torn down, and NOT silenced — see [_StubLink.tearingDown]. The displaced
    // link stays in [links] for exactly the reason the real one stays alive on
    // the platform side for a while: it is still a source of frames.
    for (final l in links) {
      l.tearingDown = true;
    }
    final displaced = links.isNotEmpty;
    links.add(_StubLink(_telemetryOut, deviceId));
    if (holdConnectedIdDuringTeardown && displaced) return;
    _connected = deviceId;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    for (final l in links) {
      l.tearingDown = true;
    }
    _connected = null;
  }

  /// Publish a frame that does NOT say which link it came from.
  ///
  /// Kept exactly as it was, and used by I1–I6 on purpose: an unstamped sample
  /// is what every hand-built test double produces, and design 0078 G2 says
  /// those must pass the gate untouched. So these tests are also the coverage
  /// for the null-passthrough half of the gate.
  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);

  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

TelemetrySample _sample({String? mac, int? deviceType}) => TelemetrySample(
      timestamp: DateTime.utc(2026, 8, 17, 12),
      pvlt: 12.8,
      mac: mac,
      deviceType: deviceType,
      twfRaw: 0x00,
    );

void main() {
  sqfliteFfiInit();

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
    await services.devices.saveNew(_savedId, '浪久電容', name: 'RCE-SCAP_II');
  });

  tearDown(() async => services.dispose());

  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await services.pending.drain();
  }

  /// Teach the saved record the address the real unit reports, the way a
  /// previous connection would have: `setIdentity` off a `0x38`.
  Future<void> learnMac(String mac) async {
    await services.devices.setIdentity(_savedId, mac: mac);
  }

  test('I1: the address matches ⇒ nothing happens', () async {
    await learnMac(_savedMac);
    final conn = services.connection;
    await conn.connect(_savedId);
    ble.emitTelemetry(_sample(mac: _savedMac));
    await settle();

    expect(conn.lastErrorFor(_savedId), isNull);
    expect(ble.disconnectCalls, 0, reason: 'the right unit answered');
    expect(conn.liveMac, _savedMac);
  });

  test('I2: a different address ⇒ wrong_device, and the link is dropped',
      () async {
    await learnMac(_savedMac);
    final conn = services.connection;
    await conn.connect(_savedId);
    ble.emitTelemetry(_sample(mac: _otherMac));
    await settle();

    expect(conn.lastErrorFor(_savedId), 'wrong_device',
        reason: 'filed under the unit the user asked for (FB-87 ①)');
    expect(ble.disconnectCalls, 1,
        reason: 'staying connected to the wrong machine is the FB-25 harm');
  });

  test('I2b: the drop must not be undone by auto-reconnect', () async {
    await learnMac(_savedMac);
    final conn = services.connection;
    await conn.connect(_savedId);
    ble.emitTelemetry(_sample(mac: _otherMac));
    await settle();

    // `disconnect()` — not `_ble.disconnect()` — is what makes this true: it
    // sets the manual-disconnect flag and clears the desired id, so neither the
    // backoff ladder nor the iOS autoConnect hand-off can pull the very unit we
    // just rejected straight back up.
    expect(conn.connectedDeviceId, isNull);
    expect(conn.lastErrorFor(_savedId), 'wrong_device',
        reason: 'the report has to survive the disconnect it caused');
  });

  test('I3: no stored address ⇒ nothing to check, and nothing is claimed',
      () async {
    final conn = services.connection;
    await conn.connect(_savedId);
    ble.emitTelemetry(_sample(mac: _otherMac));
    await settle();

    expect(conn.lastErrorFor(_savedId), isNull,
        reason: 'a FIRST connect has no yardstick — it is learning one');
    expect(ble.disconnectCalls, 0);
  });

  test('I4: the mismatch is reported once, not once per sample', () async {
    await learnMac(_savedMac);
    final conn = services.connection;
    await conn.connect(_savedId);
    for (var i = 0; i < 5; i++) {
      ble.emitTelemetry(_sample(mac: _otherMac));
    }
    await settle();

    expect(ble.disconnectCalls, 1,
        reason: 'telemetry arrives at ~5 Hz; the answer cannot change '
            'within one link');
  });

  test('I5: a sample without 0x38 says nothing either way', () async {
    await learnMac(_savedMac);
    final conn = services.connection;
    await conn.connect(_savedId);
    ble.emitTelemetry(_sample());
    await settle();

    expect(conn.lastErrorFor(_savedId), isNull);
    expect(ble.disconnectCalls, 0,
        reason: 'the selector is not on every frame — absence is not a '
            'mismatch');
  });

  // ---------------------------------------------------------------------------
  // design 0068 (B) — WHEN a rebind is allowed to happen at all.
  //
  // The old trigger was "the saved id is not in the current scan", and the field
  // capture is what condemns it: a saved unit drops out of a scan because it is
  // out of range or because WE are connected to it (a peripheral does not
  // advertise while connected), neither of which says anything about its id.
  //
  // 🔴 Note what these replace: nothing. The controller-level trigger had NO
  // test before this file — the suite covered `rebindSavedDeviceId` as a pure
  // function and mocked `connectToSaved` everywhere else, so the decision that
  // actually connected to the wrong machine was the one nobody was holding.
  // ---------------------------------------------------------------------------
  group('B: the rebind trigger', () {
    const saved = SavedDevice(
      id: 'UUID-SAVED',
      alias: '浪久電容',
      name: 'RCE-SCAP_II',
    );
    const twinVisible = {'UUID-TWIN': 'RCE-SCAP_II'};

    /// What iOS answers for an id it has never heard of.
    Object unknownId() => PlatformException(
        code: 'connect',
        message: ConnectionController.unknownPeripheralMessage,
        details: saved.id);

    test('B1: iOS says it does not know the id ⇒ rebind', () {
      expect(
        ConnectionController.rebindTargetFor(
          device: saved,
          error: unknownId(),
          candidates: twinVisible,
          savedNames: const [],
          isIOS: true,
        ),
        'UUID-TWIN',
      );
    });

    test('B2: a TIMEOUT does not rebind — this is the whole change', () {
      // `2026.08.14/004` §5 S1 in one line: the unit was there, we had just been
      // connected to it, and the old code rebound to a different capacitor.
      expect(
        ConnectionController.rebindTargetFor(
          device: saved,
          error: FlutterBluePlusException(
              ErrorPlatform.fbp, 'connect', FbpErrorCode.timeout.index, 'to'),
          candidates: twinVisible,
          savedNames: const [],
          isIOS: true,
        ),
        isNull,
      );
    });

    test('B3: two SAVED units share the name ⇒ never rebind', () {
      expect(
        ConnectionController.rebindTargetFor(
          device: saved,
          error: unknownId(),
          candidates: twinVisible,
          savedNames: const ['RCE-SCAP_II'],
          isIOS: true,
        ),
        isNull,
        reason: 'the user owns two units this cannot tell apart',
      );
    });

    test('B4: Android never rebinds', () {
      expect(
        ConnectionController.rebindTargetFor(
          device: saved,
          error: unknownId(),
          candidates: twinVisible,
          savedNames: const [],
          isIOS: false,
        ),
        isNull,
      );
    });

    test('B5: the plugin message is pinned verbatim', () {
      // ⚠️ FB-44 says a human-readable description is not an API, and this is
      // the exception — `FbpErrorCode` has no member for "unknown peripheral"
      // (flutter_blue_plus 1.36.8). The debt is paid by failing LOUDLY: if a
      // plugin upgrade rewords this, the assertion below goes red instead of
      // rebinding silently ceasing to work.
      expect(ConnectionController.unknownPeripheralMessage,
          'Peripheral not found');
      expect(
          ConnectionController.isUnknownPeripheralError(PlatformException(
              code: 'connect', message: 'Peripheral not found')),
          isTrue);
      expect(
          ConnectionController.isUnknownPeripheralError(
              PlatformException(code: 'connect', message: 'some other trouble')),
          isFalse);
      expect(
          ConnectionController.isUnknownPeripheralError(
              PlatformException(code: 'writeCharacteristic', message: 'Peripheral not found')),
          isFalse,
          reason: 'the code names the operation; only connect is this one');
    });
  });

  // ---------------------------------------------------------------------------
  // FB-87 — the failure has two names once a rebind has happened.
  // ---------------------------------------------------------------------------
  test('F1: a rebound connect that fails is readable under the SAVED id',
      () async {
    final conn = services.connection;
    ble.connectError = Exception('nope');
    await expectLater(
        conn.connect('UUID-DIALLED', requestedId: _savedId), throwsException);

    expect(conn.lastErrorFor(_savedId), isNotNull,
        reason: 'the saved id is what every screen is keyed by (FB-87 ①)');
    expect(conn.lastErrorFor('UUID-DIALLED'), isNotNull,
        reason: 'and the dialled id still answers — one attempt, two names');
    expect(conn.lastErrorFor('SOMEBODY-ELSE'), isNull,
        reason: 'and nobody else does');
  });

  test('F2: forgetDevice drops that unit\'s failure (FB-87 ②)', () async {
    final conn = services.connection;
    ble.connectError = Exception('nope');
    await expectLater(conn.connect(_savedId), throwsException);
    expect(conn.lastErrorFor(_savedId), isNotNull);

    conn.forgetDevice(_savedId);
    expect(conn.lastErrorFor(_savedId), isNull);
    expect(conn.lastErrorUnattributed, isNull,
        reason: 'the dashboard placeholder reads this one, and the record it '
            'was about is being deleted');
  });

  test('I6: case and padding differences are not mismatches', () async {
    await learnMac(_savedMac.toLowerCase());
    final conn = services.connection;
    await conn.connect(_savedId);
    ble.emitTelemetry(_sample(mac: ' $_savedMac '));
    await settle();

    expect(conn.lastErrorFor(_savedId), isNull,
        reason: '0x38 is ASCII text, and the two sides reach us by '
            'different routes');
    expect(ble.disconnectCalls, 0);
  });

  // ---------------------------------------------------------------------------
  // FB-88 / design 0078 — a frame now says WHICH LINK it came off, and a
  // consumer refuses one that is not its own.
  //
  // THE DEFECT, in one sentence: tapping unit B while unit A is connected
  // swaps the identity yardstick to B's synchronously and tears A's link down
  // asynchronously, so A's next frame is measured against B's address, fails,
  // and a healthy link is dropped as `wrong_device` — filed against the unit
  // the user just asked for. Two of six device switches in `2026.08.18/008`,
  // one of them 20 ms after the tap, which is less time than a BLE connect plus
  // service discovery plus a `0x38` read physically takes.
  //
  // 🔴 WHAT MUST NOT BE LOST WHILE FIXING IT: the guard itself. It is FB-25's
  // fix, and FB-25 is "silently connected to the wrong machine". T4 is the line
  // in the sand — remove the guard and T4 goes red.
  // ---------------------------------------------------------------------------
  group('FB-88 — frames carry the id of the link that sent them', () {
    /// The unit the user switches TO: their own second device, with its own
    /// saved record and its own learned address.
    Future<void> saveOther() async {
      await services.devices.saveNew(_otherId, '車用電池', name: 'RCE-BATT');
      await services.devices.setIdentity(_otherId, mac: _otherMac);
    }

    test('T1: the double can hold a torn-down link that is still sending',
        () async {
      final conn = services.connection;
      await conn.connect(_savedId);
      await conn.connect(_otherId);

      // Both links exist at once, which is the situation the old single-link
      // double could not express — and therefore could not test.
      expect(ble.links.length, 2);
      expect(ble.linkFor(_savedId).tearingDown, isTrue,
          reason: 'the switch displaced it');
      expect(ble.currentLink?.deviceId, _otherId);
      expect(ble.currentLink?.tearingDown, isFalse);

      // And the displaced one is still a source of frames — the whole premise.
      ble.linkFor(_savedId).emit(_sample(mac: _savedMac));
      await settle();
    });

    test('T1b: the real transport always stamps — the price of letting null '
        'through', () async {
      // G2 lets an unstamped sample past the gate, because 45 test files build
      // samples by hand and dropping theirs would break them in BEHAVIOUR
      // rather than at compile time. That leniency is only safe while the REAL
      // path is stamped without exception, so this pins the exception count at
      // zero instead of trusting it: one forgotten branch in `BleService` and
      // the entire guard is silently bypassed for every frame it publishes.
      final src = File('lib/ble/ble_service.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .toList();
      final emits = src.where((l) => l.contains('_telemetry.add(')).toList();
      expect(emits, hasLength(1),
          reason: 'one publish site is what makes "always stamped" checkable; '
              'a second one is a new hole, not a new line');
      expect(emits.single, contains('deviceId: link.deviceId'),
          reason: 'the sample leaves the transport carrying the link it came '
              'off, or FB-88 is back');

      // …and the stamp has to survive the hand-written copyWith it goes
      // through, which is a real failure mode in this model: every field is
      // copied by hand and a missed line is invisible.
      final stamped = _sample(mac: _savedMac).copyWith(deviceId: 'DEV-X');
      expect(stamped.deviceId, 'DEV-X');
      expect(stamped.mac, _savedMac, reason: 'and nothing else moved');
      expect(_sample(mac: _savedMac).deviceId, isNull,
          reason: 'unstamped is the default — that is what G2 is about');
    });

    test('T2: a straggler from the OLD link is not the new unit answering '
        'wrongly', () async {
      await saveOther();
      await learnMac(_savedMac);
      final conn = services.connection;

      await conn.connect(_savedId);
      ble.linkFor(_savedId).emit(_sample(mac: _savedMac));
      await settle();
      expect(conn.lastErrorFor(_savedId), isNull, reason: 'A is healthy');

      // The user taps B. The yardstick becomes B's straight away; A's link has
      // not finished tearing down and sends one more frame.
      await conn.connect(_otherId);
      ble.linkFor(_savedId).emit(_sample(mac: _savedMac));
      await settle();

      expect(conn.lastErrorFor(_otherId), isNull,
          reason: 'THE regression: B was blamed for a frame A sent');
      expect(conn.lastErrorFor(_savedId), isNull);
      expect(ble.disconnectCalls, 0,
          reason: 'and a healthy link was dropped for it');
      expect(conn.identityVerdict, IdentityVerdict.unchecked,
          reason: 'B has not said its address yet — that is not a verdict');
    });

    test('T2b: G3 compares against the TARGET, not against the link the '
        'transport still reports', () async {
      // The ordering this turns on is the real one, and it is why
      // `_ble.connectedDeviceId` cannot be the yardstick: while the platform
      // disconnect of A is still being awaited, the service answers "A" — so a
      // gate asking the transport whose link this is would be told "A's frame,
      // A's link, carry on", let it through, and the misfire would survive the
      // fix untouched. `_desiredDeviceId` says B from the instant of the tap.
      ble.holdConnectedIdDuringTeardown = true;
      await saveOther();
      await learnMac(_savedMac);
      final conn = services.connection;

      await conn.connect(_savedId);
      await conn.connect(_otherId);
      expect(ble.connectedDeviceId, _savedId,
          reason: 'mid-teardown, the transport still reports the old unit');

      ble.linkFor(_savedId).emit(_sample(mac: _savedMac));
      await settle();

      expect(conn.lastErrorFor(_otherId), isNull);
      expect(ble.disconnectCalls, 0);
    });

    test('T8: G3 fails OPEN — a frame with no target to compare against is '
        'treated exactly as it was before', () async {
      // [disconnect] clears the desired id, so a frame still in flight after
      // one has nothing to be measured against. Letting it through is not
      // sloppiness: design 0078 changes behaviour INSIDE the switch window and
      // nowhere else, and refusing a frame because we cannot place it would be
      // the same kind of guess the guard exists to stop. Fail-closed here would
      // also silently swallow every late frame on the manual-disconnect path.
      await learnMac(_savedMac);
      final conn = services.connection;
      await conn.connect(_savedId);
      await conn.disconnect();

      ble.linkFor(_savedId).emit(_sample(mac: _savedMac));
      await settle();

      expect(conn.liveMac, _savedMac,
          reason: 'consumed, exactly as an unstamped frame would have been');
      expect(conn.lastErrorFor(_savedId), isNull);
    });

    test('T3: and the five consumers ahead of the identity check do not see it '
        'either', () async {
      await saveOther();
      final conn = services.connection;
      await conn.connect(_savedId);
      await conn.connect(_otherId);

      // A's straggler carries a device-type byte and an address. Before design
      // 0078 both were consumed — the class resolver and `liveMac` sit ABOVE
      // the identity check, so they were fed even in the runs that ended in a
      // `wrong_device` drop.
      ble.linkFor(_savedId).emit(_sample(mac: _savedMac, deviceType: 0x22));
      await settle();

      expect(conn.packLabel, ProductClass.unknown,
          reason: 'A\'s class byte is not B\'s class');
      expect(conn.liveMac, isNull,
          reason: 'liveMac is "the address of the unit we are looking at"');

      // The control: the SAME assertions must move the moment B itself speaks,
      // or this test would pass with the gate rejecting everything.
      ble.linkFor(_otherId).emit(_sample(mac: _otherMac, deviceType: 0x22));
      await settle();
      expect(conn.packLabel, ProductClass.powerBank);
      expect(conn.liveMac, _otherMac);
    });

    test('T4: a genuinely wrong machine is still caught — FB-25 is untouched',
        () async {
      // The id we dialled is the one we wanted; the unit behind it is not. That
      // is FB-25 exactly, and it is the case the new gate must NOT swallow: the
      // frame IS from the current link, so it reaches the guard, and the guard
      // answers.
      await learnMac(_savedMac);
      final conn = services.connection;
      await conn.connect(_savedId);
      ble.linkFor(_savedId).emit(_sample(mac: _otherMac));
      await settle();

      expect(conn.lastErrorFor(_savedId), 'wrong_device',
          reason: 'staying connected to the wrong machine is the FB-25 harm');
      expect(ble.disconnectCalls, 1);
      expect(conn.identityVerdict, IdentityVerdict.mismatch);
    });

    test('T5: reconnecting to the SAME unit behaves exactly as before',
        () async {
      // Not a device switch: `_expectedMac` does not change, and the field data
      // agrees — three same-target reconnects in `2026.08.18/008`, zero
      // misfires. A frame from the displaced link is still this unit's frame,
      // so it must be consumed, not dropped.
      await learnMac(_savedMac);
      final conn = services.connection;
      await conn.connect(_savedId);
      await conn.connect(_savedId);
      expect(ble.links.length, 2, reason: 'two links, one unit');

      ble.linkFor(_savedId).emit(_sample(mac: _savedMac));
      await settle();

      expect(conn.lastErrorFor(_savedId), isNull);
      expect(ble.disconnectCalls, 0);
      expect(conn.liveMac, _savedMac,
          reason: 'the frame was consumed, not filtered away');
      expect(conn.identityVerdict, IdentityVerdict.verified);
    });

    test('T5b: and the guard still fires on the displaced link of the same unit',
        () async {
      // The mirror of T5: same id, wrong address. Whatever the gate does about
      // WHICH LINK a frame came off must not become an excuse to skip WHICH
      // UNIT answered.
      await learnMac(_savedMac);
      final conn = services.connection;
      await conn.connect(_savedId);
      await conn.connect(_savedId);
      ble.linkFor(_savedId).emit(_sample(mac: _otherMac));
      await settle();

      expect(conn.lastErrorFor(_savedId), 'wrong_device');
      expect(ble.disconnectCalls, 1);
    });

    test('T6: after a real mismatch nothing rescues the link but the user '
        '(Q3 — unchanged on purpose)', () async {
      await learnMac(_savedMac);
      final conn = services.connection;
      await conn.connect(_savedId);
      ble.linkFor(_savedId).emit(_sample(mac: _otherMac));
      await settle();
      await settle();

      // `disconnect()` — not `_ble.disconnect()` — sets the manual flag and
      // clears the desired id, so neither the backoff ladder nor the iOS
      // autoConnect hand-off pulls the rejected unit straight back up. Design
      // 0078 Q3 keeps this: refusing to auto-reconnect to a machine we believe
      // is the wrong one is the correct behaviour, and once the misfire is gone
      // the only links reaching it are genuinely wrong ones.
      expect(conn.connectedDeviceId, isNull);
      expect(conn.lastErrorFor(_savedId), 'wrong_device');
      expect(ble.disconnectCalls, 1, reason: 'no ladder, no second attempt');

      // The user taps connect again — the one path that does clear it.
      await conn.connect(_savedId);
      expect(conn.lastErrorFor(_savedId), isNull);
      expect(conn.identityVerdict, IdentityVerdict.unchecked,
          reason: 'a fresh link has not been verified yet, and "not yet" is '
              'not "no"');
      ble.linkFor(_savedId).emit(_sample(mac: _savedMac));
      await settle();
      expect(conn.identityVerdict, IdentityVerdict.verified);
    });

    // -------------------------------------------------------------------------
    // design 0078 Q4 — "verified" and "never asked" stop being the same value.
    // Added here rather than in FB-93 because both features read these same few
    // lines, and FB-93 (design 0077 Q1) is the consumer.
    // -------------------------------------------------------------------------
    test('Q4: an unverifiable link is NOT reported as a verified one',
        () async {
      final conn = services.connection;
      // No stored address: a first connect has nothing to measure against.
      await conn.connect(_savedId);
      ble.linkFor(_savedId).emit(_sample(mac: _otherMac));
      await settle();

      expect(conn.lastErrorFor(_savedId), isNull, reason: 'nothing to claim');
      expect(conn.identityVerdict, IdentityVerdict.unchecked,
          reason: 'the old bool said `false` here AND on a real match — which '
              'is why nothing downstream could act on verification');
    });

    test('Q4: a frame with no 0x38 leaves the verdict alone', () async {
      await learnMac(_savedMac);
      final conn = services.connection;
      await conn.connect(_savedId);
      ble.linkFor(_savedId).emit(_sample());
      await settle();
      expect(conn.identityVerdict, IdentityVerdict.unchecked,
          reason: 'the selector is not on every frame');

      ble.linkFor(_savedId).emit(_sample(mac: _savedMac));
      await settle();
      expect(conn.identityVerdict, IdentityVerdict.verified);
    });

    // -------------------------------------------------------------------------
    // The same gate, in the other consumer of the same stream.
    // -------------------------------------------------------------------------
    test('T7: history/dashboard state does not take the old unit\'s reading '
        'either', () async {
      await saveOther();
      final conn = services.connection;
      final tel = services.telemetry;

      await conn.connect(_savedId);
      ble.emitLink(BleLinkState.ready);
      await settle();
      await conn.connect(_otherId);
      ble.emitLink(BleLinkState.ready);
      await settle();

      ble.linkFor(_otherId).emit(TelemetrySample(
          timestamp: DateTime.utc(2026, 8, 18, 12), pvlt: 13.5, twfRaw: 0x00));
      await settle();
      expect(tel.sample.pvlt, 13.5, reason: 'B is the unit being recorded');

      // A's teardown straggler. Attribution here is the recording SESSION
      // (design 0078 Q6 leaves that alone), so without the gate this reading
      // would be shown as B's and folded into B's history second.
      ble.linkFor(_savedId).emit(TelemetrySample(
          timestamp: DateTime.utc(2026, 8, 18, 12), pvlt: 9.9, twfRaw: 0x00));
      await settle();
      expect(tel.sample.pvlt, 13.5,
          reason: 'A collapsing to 9.9 V is not B\'s reading');
    });
  });
}
