// FB-86 — the connection error is a fact about ONE unit, and the type says so.
//
// The defect: `ConnectionController` held the error as a bare `String?` and
// every consumer decided for itself whether to check who it belonged to. Two of
// the three did — the failure card passed `mine ? conn.lastError : null`, the
// row badge made `isCurrentDevice` a required parameter — and the third, the
// automatic-connect gate added three hundred lines away in the same file, did
// not. So a failed connect to A blocked B's page from ever trying, while B's own
// failure card was correctly suppressed: the user saw a clean "not connected"
// on a page that had deliberately made no attempt.
//
// 🔑 WHAT IS UNDER TEST HERE IS NOT "the gate now checks". A fourth consumer
// would forget again. What is under test is that forgetting is no longer
// POSSIBLE cheaply:
//
//   * the unattributed `lastError` getter is GONE (a compile error, pinned in
//     spirit by every call site in this suite having had to change);
//   * [ConnectionController.lastErrorFor] will not answer without an id;
//   * the one escape hatch left, `lastErrorUnattributed`, has its `lib/` call
//     sites pinned to an allowlist BELOW — which is the guard FB-86 did not
//     have, and the reason this file exists rather than one more assertion in
//     `detail_auto_connect_test.dart`.
//
// The gate's own behaviour — B connects while A's failure stands — is A33/A34
// in `detail_auto_connect_test.dart`, where the rest of the gate list lives.
//
// CLEAN-ROOM: expectations derive from this project's own source.
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'dart:async';

/// BleService stub whose connect can be made to fail on demand, with a drivable
/// adapter so the radio-level half can be reached too.
class _StubBle extends BleService {
  final _adapterOut = StreamController<BluetoothAdapterState>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  /// Thrown by [connect] when set. Null ⇒ the connect succeeds.
  Object? failWith;

  int connectCalls = 0;

  @override
  Stream<BluetoothAdapterState> get adapterState => _adapterOut.stream;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();

  @override
  Stream<BlePacketEvent> get packets => const Stream<BlePacketEvent>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    connectCalls++;
    final f = failWith;
    if (f != null) throw f;
  }

  @override
  Future<void> disconnect() async {}

  void emitAdapter(BluetoothAdapterState s) => _adapterOut.add(s);

  @override
  Future<void> dispose() async {
    await _adapterOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

/// `lib/`'s dart sources with comment lines removed.
///
/// Stripped for `give_up_visibility_test.dart`'s reason and one more: the doc
/// comments in this codebase NAME the accessors they warn about, and a guard
/// that counted prose would go red for a sentence explaining itself.
Map<String, String> libSourcesWithoutComments() {
  final dir = Directory('lib');
  expect(dir.existsSync(), isTrue,
      reason: 'lib/ is the input to this guard; if the layout moved, point '
          'this at the new path rather than deleting the test');
  final out = <String, String>{};
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    out[f.path] = f
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
  }
  expect(out, isNotEmpty);
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('E1 — the value knows whose it is', () {
    test('a unit\'s error answers for that unit and no other', () {
      const e = ConnectionError('device_unreachable', deviceId: 'DEV-A');
      expect(e.codeFor('DEV-A'), 'device_unreachable');
      expect(e.codeFor('DEV-B'), isNull);
      // A caller with no unit in hand is not a licence to see it either: that
      // caller is exactly the one that used to read the bare getter.
      expect(e.codeFor(null), isNull);
    });

    test('a RADIO error belongs to no unit, so it answers for all of them', () {
      // Not a loophole — the opposite. A radio that is off is equally true of
      // every device on the list, and filing it under whichever unit happened
      // to be the connect target would hide it from every other unit's page.
      for (final code in radioLevelErrorCodes) {
        final e = ConnectionError(code, deviceId: null);
        expect(e.codeFor('DEV-A'), code);
        expect(e.codeFor('DEV-B'), code);
        expect(e.codeFor(null), code,
            reason: 'the dashboard\'s empty state has no unit and must still '
                'be able to say the radio is off');
      }
    });
  });

  group('E2 — the live controller files it under the unit it happened to', () {
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
      ble.emitAdapter(BluetoothAdapterState.on);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    tearDown(() async => services.dispose());

    test('🔴 FB-86: A\'s failed connect is not B\'s error', () async {
      final conn = services.connection;
      ble.failWith = StateError('GATT 133');

      await expectLater(conn.connect('DEV-A'), throwsA(isA<StateError>()));

      // The host is not iOS, so the residual classifies as `connect_failed` —
      // which code it is does not matter here, only whose it is.
      final code = conn.lastErrorFor('DEV-A');
      expect(code, isNotNull,
          reason: 'the unit that was dialled owns the failure');
      expect(conn.lastErrorFor('DEV-B'), isNull,
          reason: 'THE WHOLE OF FB-86 — this is what blocked B\'s automatic '
              'connect while B\'s own failure card was correctly suppressed');
      expect(conn.lastErrorUnattributed, code,
          reason: 'the escape hatch still reports the attempt that was made; '
              'it is the per-unit question that has an answer now');
    });

    test('a radio refusal is every unit\'s, because the radio is', () async {
      final conn = services.connection;
      ble.emitAdapter(BluetoothAdapterState.off);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await conn.connect('DEV-A'); // refusals RETURN, they do not throw

      expect(ble.connectCalls, 0);
      for (final id in <String?>['DEV-A', 'DEV-B', null]) {
        expect(conn.lastErrorFor(id), 'bluetooth_off',
            reason: 'a radio that is off is not a fact about DEV-A');
      }
    });

    test('clearing stays GLOBAL — a fresh connect elsewhere ends the old '
        'failure', () async {
      final conn = services.connection;
      ble.failWith = StateError('GATT 133');
      await expectLater(conn.connect('DEV-A'), throwsA(isA<StateError>()));
      expect(conn.lastErrorFor('DEV-A'), isNotNull);

      ble.failWith = null;
      await conn.connect('DEV-B');

      expect(conn.lastErrorFor('DEV-A'), isNull,
          reason: 'recording is per-unit, clearing is not: the user has moved '
              'on, and a failure they can no longer act on must not be kept '
              'alive under another unit\'s name');
      expect(conn.lastErrorUnattributed, isNull);
    });
  });

  group('E3 — forgetting attribution cannot be cheap', () {
    test('nothing in lib/ reads a bare `lastError`', () {
      // The getter is gone, so this cannot compile today; the guard is against
      // it coming BACK. Re-adding it is a one-line change and every consumer
      // written afterwards would inherit the FB-86 defect by default.
      final offenders = <String>[];
      // The enum member `AutoConnectSkipNotice.lastError` is a different thing
      // wearing the same word — it names WHICH GATE refused, and carries no
      // code. Excluded by name rather than by loosening the pattern.
      final bare =
          RegExp(r'(?<!AutoConnectSkipNotice)\.lastError\b(?!For|Unattributed)');
      libSourcesWithoutComments().forEach((path, src) {
        if (bare.hasMatch(src)) offenders.add(path);
      });
      expect(offenders, isEmpty,
          reason: 'an unattributed read of the connection error is what FB-86 '
              'was: use `lastErrorFor(<the unit being drawn>)`');
    });

    test('the escape hatch has exactly the two call sites that were ruled', () {
      // 🔴 THE POINT OF THIS FILE. `lastErrorUnattributed` is legitimate for a
      // caller reporting the attempt the app just made — the device list's
      // snackbar, whose target may have been rebound to another id, and the
      // dashboard's empty state, which is about no unit at all. Anything drawn
      // PER UNIT has an id in hand and must pass it.
      //
      // A third file appearing here is not automatically wrong; it is
      // automatically a DECISION, to be made here rather than in passing.
      const allowed = <String>{
        // The declaration itself.
        'lib/state/connection_controller.dart',
        'lib/ui/dashboard/disconnected_state.dart',
        'lib/ui/devices/devices_page.dart',
      };
      final found = <String>{};
      libSourcesWithoutComments().forEach((path, src) {
        if (src.contains('lastErrorUnattributed')) found.add(path);
      });
      expect(found, allowed,
          reason: 'every OTHER screen is about one unit and must ask '
              '`lastErrorFor(that unit)` — FB-86 is what the third consumer '
              'reading this getter did to the second');
    });
  });
}
