// FB-86 — the connection error AND the stall latch are facts about ONE unit,
// and the API says so.
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
// 🔁 THE SAME TREATMENT, TWICE. The first pass scoped `lastError` and left
// `isSetupStalled` global — one line further down the very same gate — so A's
// stall went on blocking B's page after A's error had stopped doing so. That is
// why the guards below are written over a MAP of accessors rather than over one
// name: the next singular field to be scoped joins the table, and until it does
// the table says out loud which ones are still global.
//
// The gate's own behaviour — B connects while A's failure or stall stands — is
// A33/A34/A36 in `detail_auto_connect_test.dart`, where the gate list lives.
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

  void emitLink(BleLinkState s) => _linkOut.add(s);

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

  group('E3 — the stall latch is one unit\'s too', () {
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

    /// One connection that reaches `connected` and leaves without `ready` —
    /// FB-52's silent setup, which is what the latch counts.
    Future<void> silentSetup() async {
      ble.emitLink(BleLinkState.connecting);
      await Future<void>.delayed(Duration.zero);
      ble.emitLink(BleLinkState.connected);
      await Future<void>.delayed(Duration.zero);
      ble.emitLink(BleLinkState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    test('🔴 FB-86 second half: A\'s stall is not B\'s stall', () async {
      final conn = services.connection;
      await conn.connect('DEV-A');
      for (var i = 0; i < ConnectionController.maxSetupFailures; i++) {
        await silentSetup();
      }

      expect(conn.isSetupStalledUnattributed, isTrue,
          reason: 'three silent connections is the latch, by definition');
      expect(conn.isSetupStalledFor('DEV-A'), isTrue);
      expect(conn.setupFailuresFor('DEV-A'),
          ConnectionController.maxSetupFailures);

      expect(conn.isSetupStalledFor('DEV-B'), isFalse,
          reason: 'THE SECOND HALF OF FB-86 — this is what went on blocking '
              'B\'s automatic connect after A\'s error had stopped');
      expect(conn.setupFailuresFor('DEV-B'), 0,
          reason: 'the count and the latch are one pair; taking the number '
              'from another unit would print "3 attempts" under this name');
    });

    test('a stall is never radio-level — there is no every-unit case', () {
      // The one place the two halves differ, and it is deliberate: an error can
      // be about the phone, a stall cannot. Nothing has connected yet here, so
      // no unit is stalled — including the caller with no unit at all.
      final conn = services.connection;
      for (final id in <String?>['DEV-A', null]) {
        expect(conn.isSetupStalledFor(id), isFalse);
      }
    });
  });

  group('E5 — design 0087: the unreachable run is a latch, not a last error', () {
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

    /// One attempt that never reaches the link. `StateError` classifies as
    /// `connect_failed` off iOS — one of the three codes 0087 §3.4 counts.
    Future<void> failToReach(ConnectionController conn, String id) async {
      ble.failWith = StateError('GATT 133');
      await expectLater(conn.connect(id), throwsA(isA<StateError>()));
    }

    test('🔴 the defect: repeated attempts used to accumulate into nothing',
        () async {
      final conn = services.connection;
      await failToReach(conn, 'DEV-A');
      await failToReach(conn, 'DEV-A');
      expect(conn.isUnreachableRunFor('DEV-A'), isFalse,
          reason: 'two is not a run');
      expect(conn.reachFailuresFor('DEV-A'), 2);

      await failToReach(conn, 'DEV-A');
      expect(conn.isUnreachableRunFor('DEV-A'), isTrue,
          reason: 'THE WHOLE OF FB-58 — before 0087 this stayed at zero '
              'forever, because the setup counter only moves for an attempt '
              'that got as far as `connected`');
    });

    test('🔑 retrying the SAME unit does not wipe the run', () async {
      // This is what `lastError` alone could never do: `connect()` clears the
      // error every time, so the give-up card vanished under the user's thumb.
      final conn = services.connection;
      for (var i = 0; i < ConnectionController.maxReachFailures; i++) {
        await failToReach(conn, 'DEV-A');
      }
      expect(conn.isUnreachableRunFor('DEV-A'), isTrue);
      await failToReach(conn, 'DEV-A'); // a fourth manual retry
      expect(conn.isUnreachableRunFor('DEV-A'), isTrue,
          reason: 'the latch survives the retry that cleared lastError');
    });

    test('switching unit clears it — the run belonged to that unit', () async {
      final conn = services.connection;
      for (var i = 0; i < ConnectionController.maxReachFailures; i++) {
        await failToReach(conn, 'DEV-A');
      }
      expect(conn.isUnreachableRunFor('DEV-A'), isTrue);

      ble.failWith = null;
      await conn.connect('DEV-B');
      expect(conn.isUnreachableRunFor('DEV-A'), isFalse);
      expect(conn.isUnreachableRunFor('DEV-B'), isFalse);
    });

    test('⛔ a radio refusal never latches it (§3.4)', () async {
      final conn = services.connection;
      ble.emitAdapter(BluetoothAdapterState.off);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      for (var i = 0; i < ConnectionController.maxReachFailures + 2; i++) {
        await conn.connect('DEV-A'); // refusals RETURN, they do not throw
      }
      expect(conn.isUnreachableRunFor('DEV-A'), isFalse,
          reason: 'the card says "check it is nearby and powered" — three '
              'things nobody can do with the radio off');
      expect(conn.reachFailuresFor('DEV-A'), 0);
    });

    test('the run is one unit\'s, like every other failure fact (FB-86)',
        () async {
      final conn = services.connection;
      for (var i = 0; i < ConnectionController.maxReachFailures; i++) {
        await failToReach(conn, 'DEV-A');
      }
      expect(conn.isUnreachableRunFor('DEV-B'), isFalse);
      expect(conn.reachFailuresFor('DEV-B'), 0);
    });
  });


  group('E4 — forgetting attribution cannot be cheap', () {
    /// Every per-unit fact the controller holds, and the bare read that used to
    /// be available for it.
    ///
    /// 🔴 A TABLE, not two assertions, because FB-86 happened TWICE: the first
    /// pass scoped `lastError` and left `isSetupStalled` global one line away in
    /// the same gate. The next field to be scoped is a row here; a field that
    /// is still global is visibly absent.
    const scoped = <String, String>{
      'lastError': r'(?<!AutoConnectSkipNotice)\.lastError\b(?!For|Unattributed)',
      'isSetupStalled': r'\.isSetupStalled\b(?!For|Unattributed)',
      'setupFailures': r'\.setupFailures\b(?!For|Unattributed)',
    };

    test('nothing in lib/ reads any of them unattributed by accident', () {
      // The bare getters are gone, so none of this compiles today; the guard is
      // against them coming BACK. Re-adding one is a one-line change and every
      // consumer written afterwards would inherit the FB-86 defect by default.
      //
      // ⚠️ `AutoConnectSkipNotice.lastError` is a different thing wearing the
      // same word — it names WHICH GATE refused and carries no code — so it is
      // excluded by name rather than by loosening the pattern.
      final sources = libSourcesWithoutComments();
      scoped.forEach((name, pattern) {
        final bare = RegExp(pattern);
        final offenders = <String>[
          for (final e in sources.entries)
            if (bare.hasMatch(e.value)) e.key,
        ];
        expect(offenders, isEmpty,
            reason: 'an unattributed read of `$name` is what FB-86 was, both '
                'times: ask for it with the id of the unit being drawn');
      });
    });

    test('the escape hatches have exactly the call sites that were ruled', () {
      // 🔴 THE POINT OF THIS FILE. The `…Unattributed` accessors are legitimate
      // for a caller that is not about a unit:
      //
      //   * `lastErrorUnattributed` — the device list's snackbar, reporting the
      //     connect the user just asked for, whose target may have been REBOUND
      //     to another id; and the dashboard's empty state;
      //   * `isSetupStalledUnattributed` / `setupFailuresUnattributed` — the
      //     dashboard's empty state only. It is the app's own idle screen, not a
      //     page about a unit, so it has no id to pass.
      //
      // Anything drawn PER UNIT has an id in hand and must pass it. A new file
      // appearing here is not automatically wrong; it is automatically a
      // DECISION, to be made here rather than in passing.
      const allowed = <String, Set<String>>{
        'lastErrorUnattributed': {
          'lib/state/connection_controller.dart', // the declaration itself
          'lib/ui/dashboard/disconnected_state.dart',
          'lib/ui/devices/devices_page.dart',
        },
        'isSetupStalledUnattributed': {
          'lib/state/connection_controller.dart',
          'lib/ui/dashboard/disconnected_state.dart',
        },
        'setupFailuresUnattributed': {
          'lib/state/connection_controller.dart',
          'lib/ui/dashboard/disconnected_state.dart',
        },
      };
      final sources = libSourcesWithoutComments();
      allowed.forEach((accessor, files) {
        final found = <String>{
          for (final e in sources.entries)
            if (e.value.contains(accessor)) e.key,
        };
        expect(found, files,
            reason: 'every OTHER screen is about one unit — FB-86 is what the '
                'consumer that reached for `$accessor` instead did twice');
      });
    });
  });
}
