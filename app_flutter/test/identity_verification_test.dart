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

class _StubBle extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  String? _connected;
  int disconnectCalls = 0;

  /// What `connect` throws, if anything.
  Object? connectError;

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
    _connected = deviceId;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _connected = null;
  }

  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

TelemetrySample _sample({String? mac}) => TelemetrySample(
      timestamp: DateTime.utc(2026, 8, 17, 12),
      pvlt: 12.8,
      mac: mac,
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
}
